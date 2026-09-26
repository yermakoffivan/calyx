// HerdrConnection.swift
// Calyx
//
// Two single-use connection types implementing herdr's wire protocol,
// replacing `HerdrSocketSession` (formerly this file's own request/
// response + push-event multiplexing actor). Measured directly against a
// running herdr 0.8.0 server (protocol 19) at ~/.config/herdr/herdr.sock
// -- every fact below was OBSERVED, not inferred, and supersedes the
// "one persistent multiplexed connection" assumption `HerdrSocketSession`
// was built on:
//
//   1. Every request line needs all three of: a non-empty string "id", a
//      string "method", and "params" as a JSON OBJECT. Omitting `params`,
//      or sending it as `null`, returns
//      {"id":"","error":{"code":"invalid_request",...}} and the server
//      closes the connection. A method with nothing of its own to send
//      still encodes `params` as an empty object (`{}`), never omits the
//      key.
//   2. A request/response connection serves EXACTLY ONE request: send
//      (e.g.) `ping` with valid params -> receive the pong -> the server
//      immediately closes the connection (`recv` returns 0). Sending a
//      SECOND request on that same socket raises a broken-pipe failure.
//      `HerdrOneShotRequest` below is this fact turned into a type: its
//      only method CONSUMES `self`, so a second request through the same
//      value is a COMPILE error, not a runtime one -- see its own doc
//      comment.
//   3. `events.subscribe` is the only thing that keeps a connection open.
//      Subscribing on a fresh connection acks
//      ({"id":"1","result":{"type":"subscription_started"}}), and the
//      connection then stays open, pushing events. Sending ANY request on
//      an already-subscribed connection closes it. `HerdrEventStream`
//      below owns exactly this lifecycle, and exposes no OTHER method a
//      caller could use to send a second request through it -- see its
//      own doc comment.
//   4. Subscribing replays every EXISTING pane as a `pane_created` event
//      on that SAME connection, before any newly pushed events -- but the
//      replayed records carry no agent identity (a pane that demonstrably
//      had an agent running replays with `agent: null`,
//      `agent_status: "unknown"`). The replay is therefore useless for
//      current agent state; a `session.snapshot` on its OWN connection is
//      the only way to learn it.
//   5. `pane.agent_status_changed` can only be subscribed PER PANE
//      (requires `pane_id`); structure events (`pane.created`,
//      `pane.closed`, `pane.exited`, `pane.agent_detected`,
//      `layout.updated`) are type-only.
//
// Because fact 2 rules out more than one outstanding request per
// connection, there is no id-correlation table anywhere in this file
// (contrast `HerdrSocketSession`'s own `pending: [String: PendingEntry]`
// dictionary) -- a one-shot connection's single response can only ever be
// the answer to the single request just sent on it, so its own "id" is
// never even inspected; an event-stream connection's first line is always
// its subscribe ack (also never id-checked, for the identical reason),
// and every line after that is a pushed event (no "id" field at all, per
// HerdrEvent.swift).
//
// A response echoes the request's own "id" ({"id":..,"result":{...}} or
// {"id":..,"error":{"code":"...","message":"..."}}) -- `code` is a STRING
// here, and there is NO top-level "jsonrpc" field anywhere on this wire;
// this is NOT JSON-RPC 2.0. Do not reuse `JSONRPCRequest`/
// `JSONRPCResponse`/`JSONRPCError` from Calyx/Features/IPC/JSONRPC.swift
// here, and do not "fix" `HerdrRPCError.code` to an `Int` to match
// `JSONRPCError` -- these are two separate, non-interchangeable wire
// protocols that happen to share this codebase's `AnyCodable` helper
// type, nothing more.
//
// EOF vs failure: `HerdrTransport.swift`'s own header explains why a
// clean EOF and a transport-level failure are distinct
// `HerdrTransportEvent` cases. Both terminate a still-pending one-shot
// request or a still-pending subscribe ack the same way (there is no more
// result coming either way) -- `.transportEOF` / `.transportFailure`,
// respectively. `HerdrEventStream`'s own returned event stream, once
// subscribed, treats them asymmetrically, exactly as `HerdrSocketSession
// .subscribe(_:)` used to: a clean EOF finishes the stream NORMALLY (`for
// try await` simply ends, no throw); a transport failure finishes it BY
// THROWING.
//
import Foundation

// MARK: - HerdrSubscription

/// One entry of an `events.subscribe` request's `subscriptions` array.
/// Carried over UNCHANGED from `HerdrSocketSession.swift`.
enum HerdrSubscription: Sendable, Equatable {
    /// A bare {"type": "<name>"} subscription -- every type-only kind
    /// herdr documents: pane.created, pane.updated, pane.closed,
    /// pane.exited, pane.agent_detected, pane.focused, pane.moved,
    /// layout.updated, tab.*, workspace.*, worktree.*.
    case typeOnly(String)
    /// pane.agent_status_changed -- `paneID` is REQUIRED; there is NO
    /// global/type-only form of this subscription (subscribing without
    /// a pane_id is invalid_request and closes the connection).
    /// `agentStatus` is an optional server-side filter.
    case agentStatusChanged(paneID: String, agentStatus: HerdrAgentStatus? = nil)
    /// pane.scroll_changed -- `paneID` REQUIRED.
    case scrollChanged(paneID: String)
    /// pane.output_matched -- `paneID`, `source`, `match` all REQUIRED.
    case outputMatched(paneID: String, source: String, match: String)
}

extension HerdrSubscription: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case paneID = "pane_id"
        case agentStatus = "agent_status"
        case source
        case match
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .typeOnly(let type):
            try container.encode(type, forKey: .type)
        case .agentStatusChanged(let paneID, let agentStatus):
            try container.encode("pane.agent_status_changed", forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encodeIfPresent(agentStatus, forKey: .agentStatus)
        case .scrollChanged(let paneID):
            try container.encode("pane.scroll_changed", forKey: .type)
            try container.encode(paneID, forKey: .paneID)
        case .outputMatched(let paneID, let source, let match):
            try container.encode("pane.output_matched", forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(source, forKey: .source)
            try container.encode(match, forKey: .match)
        }
    }
}

// MARK: - Response payload types (carried over unchanged from HerdrSocketSession.swift)

/// `ping`'s result -- `ResponseResult`'s "pong" branch in the schema.
/// {"type":"pong","version":"0.8.0","protocol":19,
/// "capabilities":{...}}. `type` itself ("pong") is not modeled -- the
/// only caller already knows statically what it asked for. Only
/// `version`/`protocol` are required alongside `type`; `capabilities` is
/// optional AND nullable on the wire (`"anyOf":[ServerCapabilities,null]`,
/// `"default":null`), hence `HerdrCapabilities?` below -- NOT required,
/// despite every real herdr 0.8.0 response observed so far including it.
/// Plain compiler-synthesized `Decodable`.
struct HerdrPingResult: Sendable, Equatable, Decodable {
    let version: String
    let protocolVersion: Int
    let capabilities: HerdrCapabilities?

    private enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
        case capabilities
    }
}

/// `ServerCapabilities` in the schema. `liveHandoff` (wire
/// `live_handoff`) is the only required field; `detachedServerDaemon`
/// (wire `detached_server_daemon`) is a bare, never-nullable boolean
/// that is nonetheless OPTIONAL (absent from `required`), carrying a
/// schema-level `"default":false` this file deliberately does NOT
/// apply -- mirrors `HerdrAgentRecord.stateChangeSeq`'s own precedent in
/// HerdrEvent.swift: an absent field decodes to `nil`, never a
/// substituted default, so "the server didn't send this" stays visibly
/// distinct from "the server sent false".
struct HerdrCapabilities: Sendable, Equatable, Decodable {
    let liveHandoff: Bool
    let detachedServerDaemon: Bool?

    private enum CodingKeys: String, CodingKey {
        case liveHandoff = "live_handoff"
        case detachedServerDaemon = "detached_server_daemon"
    }
}

/// `session.snapshot`'s full RPC result wrapper --
/// {"type":"session_snapshot","snapshot":{...}}. This is the wire shape
/// of `session.snapshot`'s own "result" -- callers of a one-shot
/// `session.snapshot` request ask for THIS type, never
/// `HerdrSessionSnapshot` directly, and read `.snapshot`.
struct HerdrSnapshotRPCResult: Sendable, Decodable {
    let snapshot: HerdrSessionSnapshot
}

/// Decodes just the top-level "result" key straight out of a FULL, raw
/// response line -- {"id":"..","result":{...T...}} -- as `T`, directly
/// from the raw bytes `HerdrOneShotRequest.send` reads off the wire, with
/// no intermediate re-encoding step.
private struct HerdrResponseEnvelope<T: Decodable>: Decodable {
    let result: T
}

// MARK: - HerdrRPCError

/// herdr's own error shape --
/// {"error":{"code":"invalid_request","message":"..."}}. `code` is a
/// STRING on this wire (e.g. "invalid_request"), unlike
/// `JSONRPCError.code` (an Int) used elsewhere in this codebase for
/// LSP/MCP -- these are deliberately two separate, non-interchangeable
/// types; do not conflate them or "fix" this one to match the other.
/// There is also no top-level "jsonrpc" field anywhere on this wire --
/// this is NOT JSON-RPC 2.0.
struct HerdrRPCError: Sendable, Equatable, Decodable, Error {
    let code: String
    let message: String
}

// MARK: - HerdrConnectionError

/// Errors from a one-shot request or an event-stream's own subscribe ack
/// -- both surfaces share the identical "one request line, one response
/// line" ack-handling logic (an event-stream's `subscribe(...)` treats
/// its own ack exactly like a one-shot request's only response), so
/// nothing is served by two separate error enums with identical cases.
///
/// Unlike `HerdrSocketSessionError` (the enum this replaces), there is NO
/// `.alreadySubscribed` case: `HerdrEventStream.subscribe(...)` being a
/// `consuming` method on a noncopyable (`~Copyable`) type rules out a
/// second subscribe attempt through the same value IN THE TYPE SYSTEM (a
/// second call is a COMPILE error, "'self' consumed more than once"),
/// never a runtime condition this error type would need to represent.
enum HerdrConnectionError: Error, Sendable, Equatable {
    /// The server returned an "error" object for the request/ack.
    case rpc(HerdrRPCError)
    /// The transport ended (EOF) before a response/ack ever arrived.
    case transportEOF
    /// The transport failed (not a clean EOF) before a response/ack ever
    /// arrived.
    case transportFailure(String)
    /// A response/ack line had neither "result" nor "error" -- a genuine
    /// protocol violation, never observed against a real herdr server.
    case malformedResponse(String)
}

// MARK: - Wire helpers (shared between HerdrOneShotRequest and HerdrEventStream)

/// The full outbound envelope both `HerdrOneShotRequest.send` and
/// `HerdrEventStream.subscribe` write -- {"id":..,"method":..,
/// "params":{...}}. Generic over `Params` so ONE type serves every
/// caller: `HerdrEmptyParams` for an argument-less one-shot method
/// (`ping`, `session.snapshot`), a caller-supplied `Encodable` for one
/// that takes its own (e.g. `layout.export`'s `{"tab_id":...}` --
/// HerdrTabCoordinator.swift), `HerdrSubscribeParams` for `subscribe`.
/// `params` is never optional -- see this file's header, fact 1: herdr
/// rejects a request with `params` omitted or `null`.
private struct HerdrRequestEnvelope<Params: Encodable>: Encodable {
    let id: String
    let method: String
    let params: Params
}

/// The empty `params` object every current argument-less one-shot
/// method (`ping`, `session.snapshot`) still encodes -- see this file's
/// header, fact 1. A synthesized `encode(to:)` for a zero-property
/// struct still opens a KEYED container, so this reliably serializes as
/// `{}`, never omitted and never `null`. Not `private`: HerdrSyncSnapshotFetch.swift's
/// own bounded, synchronous `session.snapshot` request (used only by
/// AppDelegate's herdr-restore path) reuses this exact shape rather than
/// declaring a second, identical empty-params type.
struct HerdrEmptyParams: Encodable {}

/// `events.subscribe`'s own `params` shape -- {"subscriptions":[...]}.
private struct HerdrSubscribeParams: Encodable {
    let subscriptions: [HerdrSubscription]
}

/// `events.subscribe`'s own ack `result` -- {"type":"subscription_started"}.
/// Decoded only far enough to confirm "result" is present and is a JSON
/// object (a synthesized `init(from:)` for a zero-property struct still
/// opens a KEYED container, which fails to decode a non-object value);
/// its "type" field is never read, since the only caller already knows
/// statically what it just subscribed.
private struct HerdrSubscribeAckResult: Decodable {}

/// {"error":{"code":..,"message":..}} -- see `HerdrRPCError`'s own doc
/// comment for why `code` is a `String`, not `JSONRPCError`'s `Int`.
private struct HerdrErrorEnvelope: Decodable {
    let error: HerdrRPCError
}

/// Probes a response/ack line for "result"/"error" key PRESENCE only --
/// see `HerdrConnectionWire.decodeResult(from:)` for why this must be a
/// separate step from actually decoding either payload.
private struct HerdrResponseKeyProbe: Decodable {
    let hasResult: Bool
    let hasError: Bool

    private enum CodingKeys: String, CodingKey { case result, error }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasResult = container.contains(.result)
        hasError = container.contains(.error)
    }
}

/// Shared plumbing for `HerdrOneShotRequest.send` and `HerdrEventStream
/// .subscribe`'s own ack-read -- both are "write one request line, await
/// exactly one response line" (this file's header, facts 2 and 3), so
/// nothing is served by duplicating this logic across the two types.
/// Not `private`: `requestLine`/`decodeResult` (NOT `nextEvent`/
/// `awaitResponseLine`, both `AsyncStream`-based and therefore still
/// only reachable from the two `async` types below) are also reused by
/// HerdrSyncSnapshotFetch.swift's own bounded, SYNCHRONOUS
/// `session.snapshot` request -- see that file's own header for why a
/// third, hand-rolled connection type exists at all instead of a third
/// caller of `HerdrOneShotRequest` -- so the wire ENVELOPE shape (the
/// request line's own JSON shape; the response's own "result"/"error"
/// probe) stays defined in exactly this one place, never duplicated a
/// second time.
enum HerdrConnectionWire {
    /// Serializes `HerdrRequestEnvelope(id:method:params:)` to a single
    /// NDJSON line -- WITHOUT a trailing newline; `HerdrTransport.send`
    /// owns newline framing (see that protocol's own doc comment).
    static func requestLine<Params: Encodable>(id: String, method: String, params: Params) throws -> String {
        let envelope = HerdrRequestEnvelope(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(envelope)
        return String(decoding: data, as: UTF8.self)
    }

    /// Awaits exactly the NEXT event on `stream` -- `nil` if the stream
    /// finishes without yielding one (e.g. an external `close()`, as
    /// `HerdrIntegrationCoordinator`'s own per-step deadline race
    /// performs on timeout -- see that file's own "HANDSHAKE DEADLINE").
    /// Because `AsyncStream` is backed by ONE shared, ordered buffer
    /// regardless of how many `AsyncIterator` values are created from
    /// it, calling this again later on the SAME stream value (a fresh
    /// `for await`/iterator) picks up wherever this call left off, never
    /// replaying what was already consumed here -- exactly what
    /// `HerdrEventStream.subscribe`'s own ack-read, followed by its
    /// relay task's own independent consumption of that same `incoming`
    /// stream, relies on.
    static func nextEvent(of stream: AsyncStream<HerdrTransportEvent>) async -> HerdrTransportEvent? {
        for await event in stream {
            return event
        }
        return nil
    }

    /// Awaits one response/ack line on `transport`, translating a
    /// finished-without-a-line stream, `.eof`, and `.failure` into
    /// `HerdrConnectionError` -- shared by `HerdrOneShotRequest.send`'s
    /// only response and `HerdrEventStream.subscribe`'s own ack, per
    /// this file's header ("both surfaces share the identical 'one
    /// request line, one response line' ack-handling logic").
    static func awaitResponseLine(on transport: any HerdrTransport) async throws -> String {
        guard let event = await nextEvent(of: transport.incoming) else {
            throw HerdrConnectionError.transportEOF
        }
        switch event {
        case .line(let line):
            return line
        case .eof:
            throw HerdrConnectionError.transportEOF
        case .failure(let failure):
            throw HerdrConnectionError.transportFailure(failure.message)
        }
    }

    /// Decodes a response/ack `line` as `Result` -- see this file's
    /// header for why the response's own "id" is never checked. Checks
    /// "error"/"result" key PRESENCE first (`hasError` before
    /// `hasResult`, matching the RPC-error precedence
    /// `HerdrSocketSession` -- this file's own predecessor -- used),
    /// never attempting to decode `Result` itself until "result" is
    /// confirmed present, so a genuine `Result`-shape decode failure (a
    /// "result" payload that does not match what the caller asked for)
    /// propagates as its own `DecodingError`, distinct from
    /// `.malformedResponse` -- reserved for a line with NEITHER key at
    /// all, per `HerdrConnectionError.malformedResponse`'s own doc
    /// comment.
    ///
    /// `Result` decodes straight from "result" -- no type-identity
    /// dispatch. A wrapped result (`session.snapshot`'s own
    /// `{"type":..,"snapshot":{...}}`) is requested as its own wrapper
    /// type (`HerdrSnapshotRPCResult`), not unwrapped here.
    static func decodeResult<Result: Decodable>(from line: String) throws -> Result {
        let data = Data(line.utf8)
        guard let probe = try? JSONDecoder().decode(HerdrResponseKeyProbe.self, from: data) else {
            throw HerdrConnectionError.malformedResponse(line)
        }
        if probe.hasError {
            let envelope = try JSONDecoder().decode(HerdrErrorEnvelope.self, from: data)
            throw HerdrConnectionError.rpc(envelope.error)
        }
        guard probe.hasResult else {
            throw HerdrConnectionError.malformedResponse(line)
        }
        let envelope = try JSONDecoder().decode(HerdrResponseEnvelope<Result>.self, from: data)
        return envelope.result
    }
}

// MARK: - HerdrTransportFactory

/// Constructs a fresh, not-yet-connected `HerdrTransport`. Each one-shot
/// request / event-stream connection needs its OWN transport instance --
/// herdr's own connections are single-use (see this file's header, facts
/// 2 and 3) -- so nothing in this codebase may share one `HerdrTransport`
/// instance across two `HerdrOneShotRequest`/`HerdrEventStream` values.
/// `HerdrIntegrationCoordinator`'s only transport-construction seam,
/// replacing the role `HerdrSessionFactory` used to play for
/// `HerdrSocketSession`. `async`, not synchronous, purely to allow an
/// actor-isolated test spy to conform directly (mirrors the identical
/// reasoning `HerdrSessionFactory.makeSession` used to document) -- a
/// production conformer need not actually suspend.
protocol HerdrTransportFactory: Sendable {
    func makeTransport() async -> any HerdrTransport
}

/// Production `HerdrTransportFactory`: builds a fresh `HerdrTransport`
/// over a real `BSDHerdrTransport` -- `AppDelegate`'s own
/// `HerdrIntegrationCoordinator` instance is this type's only production
/// call site. Never suspends; `async` only to satisfy the protocol (see
/// its own doc comment for why the protocol itself is `async`).
struct LiveHerdrTransportFactory: HerdrTransportFactory {
    func makeTransport() async -> any HerdrTransport {
        BSDHerdrTransport()
    }
}

// MARK: - HerdrOneShotRequest

/// A single request/response exchange over its OWN, freshly-created
/// transport -- see this file's header, fact 2: "a request/response
/// connection serves EXACTLY ONE request." Used for `ping` and
/// `session.snapshot` (both argument-less, via `send(method:socketPath:)`,
/// which always encodes `"params":{}` -- see this file's header, fact 1)
/// and for a one-shot method that DOES take its own params, e.g.
/// `layout.export`'s `{"tab_id":...}` (HerdrTabCoordinator.swift), via
/// `send(method:params:socketPath:)`.
///
/// `send(...)` CONSUMES `self` (this type is `~Copyable`) -- a SECOND
/// call on the same `HerdrOneShotRequest` value is therefore a COMPILE
/// error ("'self' consumed more than once"), not a runtime guard: "a
/// one-shot request cannot be reused for a second request" holds IN THE
/// TYPE SYSTEM. Because this type is noncopyable, there is also no way to
/// alias it into a second variable and consume each independently
/// (`let copy = request` is itself a compile error) -- the ONLY way to
/// obtain a second request is to construct an entirely new
/// `HerdrOneShotRequest` over an entirely new transport, exactly as this
/// file's header requires.
///
/// Since exactly one response is ever possible on this connection (fact
/// 2), the response's own "id" is never checked against the id `send`
/// generated -- there is nothing else a line arriving on this connection
/// could be. (Contrast `HerdrSocketSession`, the type this replaces,
/// whose `pending: [String: PendingEntry]` id-correlation table existed
/// only because ONE of its connections could carry many concurrent
/// outstanding requests -- that is no longer possible by construction.)
struct HerdrOneShotRequest: ~Copyable {
    private let transport: any HerdrTransport

    /// Takes ownership of an already-constructed, not-yet-connected
    /// transport -- see this file's header "HerdrTransportFactory".
    /// Callers obtain a fresh one via `HerdrTransportFactory
    /// .makeTransport()`.
    init(transport: any HerdrTransport) {
        self.transport = transport
    }

    /// Connects to `socketPath`, sends exactly one NDJSON request line --
    /// `{"id":<generated>,"method":method,"params":{}}` -- awaits exactly
    /// one response line, and returns `Result` decoded from its own
    /// "result" key. ALWAYS closes the transport before returning OR
    /// throwing (a decoded success, an RPC error, a transport EOF/
    /// failure, or a malformed response alike).
    ///
    /// Throws `HerdrConnectionError.rpc` when the response is herdr's own
    /// error shape; `.transportEOF` / `.transportFailure` when the
    /// transport ends before any response line arrives, rather than
    /// hanging forever; `.malformedResponse` when a response line has
    /// neither "result" nor "error".
    ///
    /// Delegates to `send(method:params:socketPath:)` with
    /// `HerdrEmptyParams()` -- every current no-argument one-shot method
    /// (`ping`, `session.snapshot`) still needs `"params":{}` on the wire
    /// (this file's header, fact 1), so this overload exists only to keep
    /// those call sites free of an explicit `HerdrEmptyParams()` argument;
    /// the wire behavior is byte-for-byte identical to before this
    /// overload existed.
    consuming func send<Result: Decodable>(method: String, socketPath: String) async throws -> Result {
        try await send(method: method, params: HerdrEmptyParams(), socketPath: socketPath)
    }

    /// Same contract as `send(method:socketPath:)` above, generalized
    /// over a caller-supplied `params` payload -- e.g. `layout.export`'s
    /// own `{"pane_id":...}`/`{"tab_id":...}`, both allowed by the schema
    /// (`HerdrTabCoordinator.swift`, this type's own caller, only ever
    /// sends `"tab_id"`). `params` is still never optional on the wire
    /// (this file's header, fact 1): a caller passing a genuinely empty
    /// payload uses `HerdrEmptyParams()` explicitly, or the zero-argument
    /// overload above, which does exactly that.
    consuming func send<Params: Encodable, Result: Decodable>(
        method: String, params: Params, socketPath: String
    ) async throws -> Result {
        let transport = self.transport
        defer { await transport.close() }
        try await transport.connect(socketPath: socketPath)
        let line = try HerdrConnectionWire.requestLine(id: UUID().uuidString, method: method, params: params)
        try await transport.send(line)
        let responseLine = try await HerdrConnectionWire.awaitResponseLine(on: transport)
        return try HerdrConnectionWire.decodeResult(from: responseLine)
    }
}

// MARK: - HerdrEventStream

/// Opens ONE transport, sends `events.subscribe` exactly once, and
/// returns a stream of decoded events that lives for as long as the
/// connection does -- see this file's header, fact 3: "events.subscribe
/// is the only thing that keeps a connection open."
///
/// `subscribe(...)` CONSUMES `self` for the identical reason
/// `HerdrOneShotRequest.send(...)` does -- see that type's own doc
/// comment -- and this type ADDITIONALLY exposes NO OTHER method beyond
/// `subscribe(...)`: there is no way to send any OTHER request through an
/// instance of this type, so "an event stream cannot be asked to perform
/// a request" holds simply because no such capability exists on this type
/// to call in the first place -- a stronger guarantee than a runtime
/// check, since there is no incorrect call for the compiler to even
/// accept. The VALUE this method returns once subscribed -- a plain
/// `AsyncThrowingStream<HerdrEvent, Error>` -- carries this same property
/// for a different, even more basic reason: an `AsyncThrowingStream` has
/// no operation but consuming (`for try await`/`.next()`); it was never
/// possible to send a request through one.
struct HerdrEventStream: ~Copyable {
    private let transport: any HerdrTransport

    /// Takes ownership of an already-constructed, not-yet-connected
    /// transport -- see this file's header "HerdrTransportFactory".
    init(transport: any HerdrTransport) {
        self.transport = transport
    }

    /// Connects to `socketPath`, sends exactly one `events.subscribe`
    /// request carrying `subscriptions`, awaits its ack, then returns a
    /// stream of every subsequently pushed `HerdrEvent` -- the replayed
    /// `pane_created` burst included (this file's header, fact 4). The
    /// returned stream finishes NORMALLY on a clean transport EOF, or BY
    /// THROWING on a transport failure -- see this file's header. Throws
    /// (without ever returning a stream) if the subscribe ack itself
    /// fails: an RPC error, or the transport ending before any ack
    /// arrives.
    ///
    /// Transport lifetime, asymmetric by design (contrast
    /// `HerdrOneShotRequest.send`, which ALWAYS closes): closes
    /// `transport` on every FAILURE path above (there is nothing left to
    /// keep it open for), but leaves it OPEN on success -- the whole
    /// point of this connection is to keep pushing events onto the
    /// returned stream for as long as it lives, so the caller (and, on a
    /// timeout, `HerdrIntegrationCoordinator`'s own deadline race, which
    /// already holds this same `transport` directly) owns closing it
    /// once that lifetime ends.
    ///
    /// The relay task that forwards transport lines onto the returned
    /// stream captures ONLY `incoming` (a plain, `Sendable` `AsyncStream`
    /// value) and `continuation` -- NEVER `transport` or `self`. This
    /// matters beyond style: `HerdrIntegrationCoordinator` owns
    /// `transport` directly once this method returns and explicitly
    /// `close()`s it on every teardown path (its own header, "EXPLICIT
    /// TRANSPORT TEARDOWN") -- this type must never independently close
    /// (or otherwise act through) `transport` again after handing it a
    /// live connection, or the two closers could race.
    consuming func subscribe(
        _ subscriptions: [HerdrSubscription], socketPath: String
    ) async throws -> AsyncThrowingStream<HerdrEvent, Error> {
        let transport = self.transport
        do {
            try await transport.connect(socketPath: socketPath)
            let line = try HerdrConnectionWire.requestLine(
                id: UUID().uuidString, method: "events.subscribe", params: HerdrSubscribeParams(subscriptions: subscriptions)
            )
            try await transport.send(line)
            let ackLine = try await HerdrConnectionWire.awaitResponseLine(on: transport)
            let _: HerdrSubscribeAckResult = try HerdrConnectionWire.decodeResult(from: ackLine)

            // SUCCESS from here on: `transport` is deliberately left
            // OPEN (see this method's own doc comment above) -- the
            // relay task below never touches it again, only `incoming`.
            let incoming = transport.incoming
            return AsyncThrowingStream { continuation in
                let relayTask = Task {
                    for await event in incoming {
                        switch event {
                        case .line(let eventLine):
                            do {
                                let decoded = try JSONDecoder().decode(HerdrEvent.self, from: Data(eventLine.utf8))
                                continuation.yield(decoded)
                            } catch {
                                continuation.finish(throwing: error)
                                return
                            }
                        case .eof:
                            continuation.finish()
                            return
                        case .failure(let failure):
                            continuation.finish(throwing: HerdrConnectionError.transportFailure(failure.message))
                            return
                        }
                    }
                    // `incoming` finished without ever yielding a
                    // terminal `.eof`/`.failure` event -- e.g. an
                    // external `close()` (mirrors
                    // `HerdrConnectionWire.nextEvent(of:)`'s own doc
                    // comment). Nothing further will ever arrive;
                    // finishing normally, not by throwing, matches this
                    // file's own EOF-like treatment of that case
                    // everywhere else.
                    continuation.finish()
                }
                continuation.onTermination = { _ in relayTask.cancel() }
            }
        } catch {
            await transport.close()
            throw error
        }
    }
}
