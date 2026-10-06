//
//  CalyxMCPServerUsageIngestRouteTests.swift
//  CalyxTests
//
//  R3a: `POST /usage/v1/metrics`, the route Claude Code's OTLP metrics
//  exporter posts to. Checks in order: no endpoint -> 503; any `Origin`
//  -> 403; `UsageIngestEndpoint.accepts` false -> 401; no body -> 400;
//  then `ingest(body, receivedAtNs)` mapped to 200 `{}` / 400 / 503.
//  `note` is told every verdict (nil for an accepted request).
//
//  Three classes:
//  - `UsageIngestEndpointAcceptsTests`: the pure authorization helper.
//  - `CalyxMCPServerUsageIngestRouteTests`: `server.route(request:)`
//    directly, no listener.
//  - `CalyxMCPServerUsageIngestListenerTests`: a real loopback listener on
//    an ephemeral port (`preferredPort: 0`), for the transport body cap and
//    the noting of transport-refused requests (`.tooLarge` / `.unauthorized`),
//    which happen before any route code runs.
//
//  Every token and body here is synthetic.
//

import XCTest
@testable import Calyx

// MARK: - Shared fixtures

/// A synthetic usage token (64 lowercase hex characters).
private let usageToken = String(repeating: "0123456789abcdef", count: 4)
/// A synthetic server (MCP) token, distinct from the usage token.
private let serverToken = "r3a-synthetic-server-token"
/// The injected clock's fixed time: 1_700_000_000.5 s since the epoch,
/// i.e. exactly 1_700_000_000_500_000_000 ns.
private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000.5)
private let fixedNowNs: Int64 = 1_700_000_000_500_000_000

/// Records what `ingest` was handed; answers with a fixed outcome.
private actor IngestRecorder {
    struct Call: Sendable, Equatable {
        let body: Data
        let receivedAtNs: Int64
    }
    let outcome: UsageIngestOutcome
    private(set) var calls: [Call] = []

    init(outcome: UsageIngestOutcome) {
        self.outcome = outcome
    }

    func record(_ body: Data, _ receivedAtNs: Int64) -> UsageIngestOutcome {
        calls.append(Call(body: body, receivedAtNs: receivedAtNs))
        return outcome
    }
}

/// Records what `note` was told.
@MainActor
private final class NoteRecorder {
    struct Entry: Equatable {
        let rejection: UsageIngestRejection?
        let at: Date
    }
    private(set) var entries: [Entry] = []

    func note(_ rejection: UsageIngestRejection?, _ at: Date) {
        entries.append(Entry(rejection: rejection, at: at))
    }
}

/// A clock that advances by one second on every reading, starting at 1_000 s.
@MainActor
private final class ClockCounter {
    private(set) var readings = 0

    func read() -> Date {
        let date = Date(timeIntervalSince1970: TimeInterval(1_000 + readings))
        readings += 1
        return date
    }
}

/// A `token` closure's answers: `answers` in order, then `thereafter`;
/// counts its readings.
@MainActor
private final class TokenSource {
    private var answers: [String?]
    private let thereafter: String?
    private(set) var calls = 0

    init(answers: [String?], thereafter: String?) {
        self.answers = answers
        self.thereafter = thereafter
    }

    func read() -> String? {
        calls += 1
        guard !answers.isEmpty else { return thereafter }
        return answers.removeFirst()
    }
}

@MainActor
private func makeEndpoint(
    token: String? = usageToken,
    now: Date = fixedNow,
    ingest: IngestRecorder,
    notes: NoteRecorder
) -> UsageIngestEndpoint {
    UsageIngestEndpoint(
        token: { token },
        now: { now },
        ingest: { body, receivedAtNs in await ingest.record(body, receivedAtNs) },
        note: { rejection, at in notes.note(rejection, at) }
    )
}

private func header(_ name: String, in response: HTTPResponse) -> String? {
    response.headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
}

// MARK: - UsageIngestEndpoint.accepts

final class UsageIngestEndpointAcceptsTests: XCTestCase {

    private let token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    func test_accepts_bearerPlusExactToken_true() {
        XCTAssertTrue(UsageIngestEndpoint.accepts(authorization: "Bearer \(token)", token: token))
    }

    func test_accepts_nilToken_false() {
        XCTAssertFalse(UsageIngestEndpoint.accepts(authorization: "Bearer \(token)", token: nil))
    }

    func test_accepts_emptyToken_withBearerAlone_false() {
        XCTAssertFalse(UsageIngestEndpoint.accepts(authorization: "Bearer ", token: ""))
    }

    func test_accepts_emptyToken_withBearerWithoutSpace_false() {
        XCTAssertFalse(UsageIngestEndpoint.accepts(authorization: "Bearer", token: ""))
    }

    func test_accepts_nilHeader_false() {
        XCTAssertFalse(UsageIngestEndpoint.accepts(authorization: nil, token: token))
    }

    func test_accepts_lowercaseBearer_false() {
        XCTAssertFalse(UsageIngestEndpoint.accepts(authorization: "bearer \(token)", token: token))
    }

    func test_accepts_basicScheme_false() {
        XCTAssertFalse(UsageIngestEndpoint.accepts(authorization: "Basic \(token)", token: token))
    }

    func test_accepts_bearerAlone_false() {
        XCTAssertFalse(UsageIngestEndpoint.accepts(authorization: "Bearer ", token: token))
    }

    func test_accepts_tokenWithoutScheme_false() {
        XCTAssertFalse(UsageIngestEndpoint.accepts(authorization: token, token: token))
    }

    func test_accepts_trailingSpace_false() {
        XCTAssertFalse(UsageIngestEndpoint.accepts(authorization: "Bearer \(token) ", token: token))
    }

    func test_accepts_leadingSpaceBeforeToken_false() {
        XCTAssertFalse(UsageIngestEndpoint.accepts(authorization: "Bearer  \(token)", token: token))
    }

    func test_accepts_leadingSpaceBeforeScheme_false() {
        XCTAssertFalse(UsageIngestEndpoint.accepts(authorization: " Bearer \(token)", token: token))
    }

    func test_accepts_firstCharacterDiffers_false() {
        let other = "f" + token.dropFirst()
        XCTAssertFalse(UsageIngestEndpoint.accepts(authorization: "Bearer \(other)", token: token))
    }

    func test_accepts_lastCharacterDiffers_false() {
        let other = token.dropLast() + "0"
        XCTAssertFalse(UsageIngestEndpoint.accepts(authorization: "Bearer \(other)", token: token))
    }

    func test_accepts_tokenOneLonger_false() {
        XCTAssertFalse(UsageIngestEndpoint.accepts(authorization: "Bearer \(token)0", token: token))
    }

    func test_accepts_tokenOneShorter_false() {
        XCTAssertFalse(UsageIngestEndpoint.accepts(authorization: "Bearer \(token.dropLast())", token: token))
    }

    func test_accepts_doesNotRequireHexToken() {
        XCTAssertTrue(UsageIngestEndpoint.accepts(authorization: "Bearer x", token: "x"))
    }
}

// MARK: - Route tests (server.route(request:))

@MainActor
final class CalyxMCPServerUsageIngestRouteTests: XCTestCase {

    private var server: CalyxMCPServer?
    private var agentEndpointDir: String?

    override func setUp() async throws {
        try await super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalyxMCPServerUsageIngestRouteTests-\(UUID().uuidString)").path
        agentEndpointDir = dir
        let server = CalyxMCPServer(agentEndpointDirectory: dir)
        server.agentRegistry = AgentRegistry()
        server._testSetToken(serverToken)
        self.server = server
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        if let agentEndpointDir {
            try? FileManager.default.removeItem(atPath: agentEndpointDir)
        }
        agentEndpointDir = nil
        try await super.tearDown()
    }

    // MARK: Helpers

    private func srv() throws -> CalyxMCPServer {
        try XCTUnwrap(server)
    }

    private let sampleBody = Data("{\"resourceMetrics\":[]}".utf8)

    private func request(
        method: String = "POST",
        path: String = "/usage/v1/metrics",
        authorization: String? = "Bearer \(usageToken)",
        authorizationKey: String = "authorization",
        extraHeaders: [String: String] = [:],
        body: Data? = Data("{\"resourceMetrics\":[]}".utf8),
        repeatsAuthorization: Bool = false
    ) -> HTTPRequest {
        var headers: [String: String] = ["content-type": "application/json", "host": "127.0.0.1"]
        if let authorization {
            headers[authorizationKey] = authorization
        }
        for (key, value) in extraHeaders {
            headers[key] = value
        }
        return HTTPRequest(method: method, path: path, headers: headers, body: body, repeatsAuthorization: repeatsAuthorization)
    }

    /// Installs an endpoint and returns its recorders.
    private func install(
        outcome: UsageIngestOutcome = .stored,
        token: String? = usageToken,
        now: Date = fixedNow
    ) throws -> (IngestRecorder, NoteRecorder) {
        let ingest = IngestRecorder(outcome: outcome)
        let notes = NoteRecorder()
        try srv().usageIngest = makeEndpoint(token: token, now: now, ingest: ingest, notes: notes)
        return (ingest, notes)
    }

    private func assertNoBody(_ response: HTTPResponse, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue((response.body ?? Data()).isEmpty, "expected no body", file: file, line: line)
        XCTAssertEqual(header("Content-Length", in: response), "0", file: file, line: line)
    }

    private func assertStandardHeaders(_ response: HTTPResponse, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(header("Connection", in: response), "close", file: file, line: line)
        XCTAssertEqual(header("Content-Type", in: response), "application/json", file: file, line: line)
    }

    // MARK: Default state

    func test_usageIngest_isNilByDefault() throws {
        XCTAssertNil(try srv().usageIngest)
    }

    // MARK: Check 1: no endpoint

    func test_noEndpoint_returns503() async throws {
        let response = try await srv().route(request: request())
        XCTAssertEqual(response.statusCode, 503)
        assertNoBody(response)
    }

    func test_noEndpoint_withOriginAndNoTokenAndNoBody_returns503() async throws {
        let response = try await srv().route(request: request(authorization: nil, extraHeaders: ["Origin": "https://evil.example"], body: nil))
        XCTAssertEqual(response.statusCode, 503)
    }

    func test_noEndpoint_notesNothing() async throws {
        let (ingest, notes) = try install()
        try srv().usageIngest = nil
        _ = try await srv().route(request: request())
        XCTAssertEqual(notes.entries, [])
        let calls = await ingest.calls
        XCTAssertEqual(calls, [])
    }

    // MARK: Check 2: Origin

    func test_origin_withValidToken_returns403() async throws {
        _ = try install()
        let response = try await srv().route(request: request(extraHeaders: ["Origin": "https://evil.example"]))
        XCTAssertEqual(response.statusCode, 403)
        assertNoBody(response)
        assertStandardHeaders(response)
    }

    func test_origin_loopbackValue_stillReturns403() async throws {
        _ = try install()
        let response = try await srv().route(request: request(extraHeaders: ["Origin": "http://127.0.0.1"]))
        XCTAssertEqual(response.statusCode, 403)
    }

    func test_origin_emptyValue_stillReturns403() async throws {
        _ = try install()
        let response = try await srv().route(request: request(extraHeaders: ["Origin": ""]))
        XCTAssertEqual(response.statusCode, 403)
    }

    func test_origin_lowercaseHeaderName_returns403() async throws {
        _ = try install()
        let response = try await srv().route(request: request(extraHeaders: ["origin": "https://evil.example"]))
        XCTAssertEqual(response.statusCode, 403)
    }

    func test_origin_notesForeignOriginWithClockDate() async throws {
        let (_, notes) = try install()
        _ = try await srv().route(request: request(extraHeaders: ["Origin": "https://evil.example"]))
        XCTAssertEqual(notes.entries, [.init(rejection: .foreignOrigin, at: fixedNow)])
    }

    func test_origin_doesNotCallIngest() async throws {
        let (ingest, _) = try install()
        _ = try await srv().route(request: request(extraHeaders: ["Origin": "https://evil.example"]))
        let calls = await ingest.calls
        XCTAssertEqual(calls, [])
    }

    /// Origin is checked before the token.
    func test_origin_withWrongToken_returns403NotUnauthorized() async throws {
        let (_, notes) = try install()
        let response = try await srv().route(request: request(authorization: "Bearer wrong", extraHeaders: ["Origin": "https://evil.example"]))
        XCTAssertEqual(response.statusCode, 403)
        XCTAssertEqual(notes.entries.map(\.rejection), [.foreignOrigin])
    }

    /// Origin is checked before the body.
    func test_origin_withNoBody_returns403() async throws {
        _ = try install()
        let response = try await srv().route(request: request(extraHeaders: ["Origin": "https://evil.example"], body: nil))
        XCTAssertEqual(response.statusCode, 403)
    }

    // MARK: Check 3: authorization

    func test_validToken_lowercaseHeaderName_isAccepted() async throws {
        _ = try install()
        let response = try await srv().route(request: request(authorizationKey: "authorization"))
        XCTAssertEqual(response.statusCode, 200)
    }

    func test_validToken_capitalizedHeaderName_isAccepted() async throws {
        _ = try install()
        let response = try await srv().route(request: request(authorizationKey: "Authorization"))
        XCTAssertEqual(response.statusCode, 200)
    }

    private func assertUnauthorized(_ authorization: String?, file: StaticString = #filePath, line: UInt = #line) async throws {
        let (ingest, notes) = try install()
        let response = try await srv().route(request: request(authorization: authorization))
        XCTAssertEqual(response.statusCode, 401, file: file, line: line)
        assertNoBody(response, file: file, line: line)
        assertStandardHeaders(response, file: file, line: line)
        XCTAssertEqual(notes.entries, [.init(rejection: .unauthorized, at: fixedNow)], file: file, line: line)
        let calls = await ingest.calls
        XCTAssertEqual(calls, [], file: file, line: line)
    }

    func test_missingAuthorization_returns401() async throws {
        try await assertUnauthorized(nil)
    }

    func test_lowercaseBearer_returns401() async throws {
        try await assertUnauthorized("bearer \(usageToken)")
    }

    func test_basicScheme_returns401() async throws {
        try await assertUnauthorized("Basic \(usageToken)")
    }

    func test_bearerWithNothing_returns401() async throws {
        try await assertUnauthorized("Bearer ")
    }

    func test_rightTokenWithTrailingSpace_returns401() async throws {
        try await assertUnauthorized("Bearer \(usageToken) ")
    }

    func test_differentToken_returns401() async throws {
        try await assertUnauthorized("Bearer fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210")
    }

    func test_serverToken_returns401() async throws {
        try await assertUnauthorized("Bearer \(serverToken)")
    }

    func test_endpointHasNoToken_returns401() async throws {
        let (ingest, notes) = try install(token: nil)
        let response = try await srv().route(request: request())
        XCTAssertEqual(response.statusCode, 401)
        XCTAssertEqual(notes.entries, [.init(rejection: .unauthorized, at: fixedNow)])
        let calls = await ingest.calls
        XCTAssertEqual(calls, [])
    }

    func test_endpointHasEmptyToken_bearerAlone_returns401() async throws {
        _ = try install(token: "")
        let response = try await srv().route(request: request(authorization: "Bearer "))
        XCTAssertEqual(response.statusCode, 401)
    }

    /// The token is asked for at request time, not captured at install.
    func test_endpointTokenIsReadPerRequest() async throws {
        let ingest = IngestRecorder(outcome: .stored)
        let notes = NoteRecorder()
        var current: String? = nil
        try srv().usageIngest = UsageIngestEndpoint(
            token: { current },
            now: { fixedNow },
            ingest: { body, ns in await ingest.record(body, ns) },
            note: { rejection, at in notes.note(rejection, at) }
        )
        let before = try await srv().route(request: request())
        current = usageToken
        let after = try await srv().route(request: request())
        XCTAssertEqual(before.statusCode, 401)
        XCTAssertEqual(after.statusCode, 200)
    }

    /// The token is checked before the body.
    func test_wrongToken_withNoBody_returns401() async throws {
        let (_, notes) = try install()
        let response = try await srv().route(request: request(authorization: "Bearer wrong", body: nil))
        XCTAssertEqual(response.statusCode, 401)
        XCTAssertEqual(notes.entries.map(\.rejection), [.unauthorized])
    }

    // MARK: The usage token on other routes

    func test_usageToken_onAgentEvent_isUnauthorized() async throws {
        _ = try install()
        let response = try await srv().route(request: request(
            path: "/agent-event",
            authorizationKey: "Authorization",
            extraHeaders: ["X-Calyx-Surface-ID": UUID().uuidString],
            body: Data("{\"hook_event_name\":\"Stop\",\"session_id\":\"s\"}".utf8)
        ))
        XCTAssertEqual(response.statusCode, 401)
    }

    func test_usageToken_onCommandEvent_isUnauthorized() async throws {
        _ = try install()
        let response = try await srv().route(request: request(path: "/command-event", authorizationKey: "Authorization", body: Data("{}".utf8)))
        XCTAssertEqual(response.statusCode, 401)
    }

    func test_usageToken_onMCP_isUnauthorized() async throws {
        _ = try install()
        let body = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}".utf8)
        let response = try await srv().route(request: request(path: "/mcp", authorizationKey: "Authorization", body: body))
        XCTAssertEqual(response.statusCode, 401)
    }

    func test_usageToken_onCalyxMCP_isUnauthorized() async throws {
        _ = try install()
        let body = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}".utf8)
        let response = try await srv().route(request: request(path: "/calyx-mcp", authorizationKey: "Authorization", body: body))
        XCTAssertEqual(response.statusCode, 401)
    }

    func test_usageToken_onOtherRoutes_notesNothing() async throws {
        let (ingest, notes) = try install()
        _ = try await srv().route(request: request(path: "/command-event", authorizationKey: "Authorization", body: Data("{}".utf8)))
        XCTAssertEqual(notes.entries, [])
        let calls = await ingest.calls
        XCTAssertEqual(calls, [])
    }

    // MARK: Method and path must match exactly

    func test_get_onUsagePath_returns404() async throws {
        _ = try install()
        let response = try await srv().route(request: request(method: "GET", body: nil))
        XCTAssertEqual(response.statusCode, 404)
    }

    func test_usagePathWithQueryString_returns404() async throws {
        _ = try install()
        let response = try await srv().route(request: request(path: "/usage/v1/metrics?x=1"))
        XCTAssertEqual(response.statusCode, 404)
    }

    func test_usagePathWithTrailingSlash_returns404() async throws {
        _ = try install()
        let response = try await srv().route(request: request(path: "/usage/v1/metrics/"))
        XCTAssertEqual(response.statusCode, 404)
    }

    func test_404s_noteNothingAndIngestNothing() async throws {
        let (ingest, notes) = try install()
        _ = try await srv().route(request: request(method: "GET", body: nil))
        _ = try await srv().route(request: request(path: "/usage/v1/metrics?x=1"))
        XCTAssertEqual(notes.entries, [])
        let calls = await ingest.calls
        XCTAssertEqual(calls, [])
    }

    // MARK: Check 4: body

    func test_noBody_returns400() async throws {
        _ = try install()
        let response = try await srv().route(request: request(body: nil))
        XCTAssertEqual(response.statusCode, 400)
        assertNoBody(response)
        assertStandardHeaders(response)
    }

    func test_noBody_notesNoBodyWithClockDate() async throws {
        let (_, notes) = try install()
        _ = try await srv().route(request: request(body: nil))
        XCTAssertEqual(notes.entries, [.init(rejection: .noBody, at: fixedNow)])
    }

    func test_noBody_doesNotCallIngest() async throws {
        let (ingest, _) = try install()
        _ = try await srv().route(request: request(body: nil))
        let calls = await ingest.calls
        XCTAssertEqual(calls, [])
    }

    func test_emptyBody_returns400AndNotesNoBody() async throws {
        let (ingest, notes) = try install()
        let response = try await srv().route(request: request(body: Data()))
        XCTAssertEqual(response.statusCode, 400)
        assertNoBody(response)
        XCTAssertEqual(notes.entries, [.init(rejection: .noBody, at: fixedNow)])
        let calls = await ingest.calls
        XCTAssertEqual(calls, [])
    }

    // MARK: The clock is read exactly once per verdict

    /// Installs an endpoint whose clock advances by one second on every
    /// reading (first reading: 1_000 s = 1_000_000_000_000 ns) and whose
    /// `ingest` suspends before answering.
    private func installAdvancingClock(outcome: UsageIngestOutcome) throws -> (IngestRecorder, NoteRecorder, ClockCounter) {
        let ingest = IngestRecorder(outcome: outcome)
        let notes = NoteRecorder()
        let clock = ClockCounter()
        try srv().usageIngest = UsageIngestEndpoint(
            token: { usageToken },
            now: { clock.read() },
            ingest: { body, ns in
                await Task.yield()
                let outcome = await ingest.record(body, ns)
                await Task.yield()
                return outcome
            },
            note: { rejection, at in notes.note(rejection, at) }
        )
        return (ingest, notes, clock)
    }

    private static let firstReading = Date(timeIntervalSince1970: 1_000)
    private static let firstReadingNs: Int64 = 1_000_000_000_000

    private func assertOneReading(outcome: UsageIngestOutcome, expected: UsageIngestRejection?, file: StaticString = #filePath, line: UInt = #line) async throws {
        let (ingest, notes, clock) = try installAdvancingClock(outcome: outcome)
        _ = try await srv().route(request: request())
        XCTAssertEqual(clock.readings, 1, "the clock must be read exactly once", file: file, line: line)
        XCTAssertEqual(notes.entries, [.init(rejection: expected, at: Self.firstReading)], file: file, line: line)
        let calls = await ingest.calls
        XCTAssertEqual(calls.map(\.receivedAtNs), [Self.firstReadingNs], file: file, line: line)
    }

    func test_clockReadOnce_stored() async throws {
        try await assertOneReading(outcome: .stored, expected: nil)
    }

    func test_clockReadOnce_dropped() async throws {
        try await assertOneReading(outcome: .dropped, expected: nil)
    }

    func test_clockReadOnce_undecodable() async throws {
        try await assertOneReading(outcome: .undecodable, expected: .undecodable)
    }

    func test_clockReadOnce_unavailable() async throws {
        try await assertOneReading(outcome: .unavailable, expected: .unavailable)
    }

    func test_clockReadOnce_rejections() async throws {
        let cases: [(HTTPRequest, UsageIngestRejection)] = [
            (request(extraHeaders: ["Origin": "https://evil.example"]), .foreignOrigin),
            (request(authorization: nil), .unauthorized),
            (request(body: nil), .noBody),
        ]
        for (req, rejection) in cases {
            let (_, notes, clock) = try installAdvancingClock(outcome: .stored)
            _ = try await srv().route(request: req)
            XCTAssertEqual(clock.readings, 1, "\(rejection)")
            XCTAssertEqual(notes.entries, [.init(rejection: rejection, at: Self.firstReading)], "\(rejection)")
        }
    }

    func test_clockNotRead_on404() async throws {
        let (_, _, clock) = try installAdvancingClock(outcome: .stored)
        _ = try await srv().route(request: request(method: "GET", body: nil))
        _ = try await srv().route(request: request(path: "/usage/v1/metrics?x=1"))
        XCTAssertEqual(clock.readings, 0)
    }

    // MARK: Check 5 and 6: ingest

    func test_body_reachesIngestByteForByte() async throws {
        let (ingest, _) = try install()
        let body = Data((0...255).map { UInt8($0) } + (0...255).reversed().map { UInt8($0) })
        _ = try await srv().route(request: request(body: body))
        let calls = await ingest.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.body, body)
    }

    func test_ingest_isCalledExactlyOnce() async throws {
        let (ingest, _) = try install()
        _ = try await srv().route(request: request())
        let calls = await ingest.calls
        XCTAssertEqual(calls.count, 1)
    }

    func test_receivedAtNs_isInjectedClockTime() async throws {
        let (ingest, _) = try install()
        _ = try await srv().route(request: request())
        let calls = await ingest.calls
        XCTAssertEqual(calls.map(\.receivedAtNs), [fixedNowNs])
    }

    func test_receivedAtNs_saturatesForDistantFuture() async throws {
        let (ingest, _) = try install(now: .distantFuture)
        _ = try await srv().route(request: request())
        let calls = await ingest.calls
        XCTAssertEqual(calls.map(\.receivedAtNs), [Int64.max])
    }

    func test_stored_returns200WithEmptyJSONObject() async throws {
        _ = try install(outcome: .stored)
        let response = try await srv().route(request: request())
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data("{}".utf8))
        XCTAssertEqual(header("Content-Length", in: response), "2")
        assertStandardHeaders(response)
    }

    func test_dropped_returns200WithEmptyJSONObject() async throws {
        _ = try install(outcome: .dropped)
        let response = try await srv().route(request: request())
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data("{}".utf8))
        assertStandardHeaders(response)
    }

    func test_undecodable_returns400WithoutBody() async throws {
        _ = try install(outcome: .undecodable)
        let response = try await srv().route(request: request())
        XCTAssertEqual(response.statusCode, 400)
        assertNoBody(response)
        assertStandardHeaders(response)
    }

    func test_unavailable_returns503WithoutBody() async throws {
        _ = try install(outcome: .unavailable)
        let response = try await srv().route(request: request())
        XCTAssertEqual(response.statusCode, 503)
        assertNoBody(response)
        assertStandardHeaders(response)
    }

    func test_stored_notesNilWithClockDate() async throws {
        let (_, notes) = try install(outcome: .stored)
        _ = try await srv().route(request: request())
        XCTAssertEqual(notes.entries, [.init(rejection: nil, at: fixedNow)])
    }

    func test_dropped_notesNilWithClockDate() async throws {
        let (_, notes) = try install(outcome: .dropped)
        _ = try await srv().route(request: request())
        XCTAssertEqual(notes.entries, [.init(rejection: nil, at: fixedNow)])
    }

    func test_undecodable_notesUndecodableWithClockDate() async throws {
        let (_, notes) = try install(outcome: .undecodable)
        _ = try await srv().route(request: request())
        XCTAssertEqual(notes.entries, [.init(rejection: .undecodable, at: fixedNow)])
    }

    func test_unavailable_notesUnavailableWithClockDate() async throws {
        let (_, notes) = try install(outcome: .unavailable)
        _ = try await srv().route(request: request())
        XCTAssertEqual(notes.entries, [.init(rejection: .unavailable, at: fixedNow)])
    }

    func test_note_isCalledOncePerRequest() async throws {
        let (_, notes) = try install(outcome: .stored)
        _ = try await srv().route(request: request())
        _ = try await srv().route(request: request(body: nil))
        _ = try await srv().route(request: request(authorization: nil))
        XCTAssertEqual(notes.entries.map(\.rejection), [nil, .noBody, .unauthorized])
    }

    // MARK: A repeated Authorization header carries no credential

    func test_repeatsAuthorization_withRightToken_returns401() async throws {
        let (ingest, notes) = try install()
        let response = try await srv().route(request: request(repeatsAuthorization: true))
        XCTAssertEqual(response.statusCode, 401)
        assertNoBody(response)
        XCTAssertEqual(notes.entries, [.init(rejection: .unauthorized, at: fixedNow)])
        let calls = await ingest.calls
        XCTAssertEqual(calls, [])
    }

    // MARK: A request is finished with the endpoint it started with

    /// `ingest` installs a new endpoint before answering: the endpoint
    /// that received the request is noted once, the new one not at all.
    func test_endpointReplacedDuringIngest_originalIsNotedOnce_newIsNotNoted() async throws {
        let server = try srv()
        let originalNotes = NoteRecorder()
        let newIngest = IngestRecorder(outcome: .stored)
        let newNotes = NoteRecorder()
        server.usageIngest = UsageIngestEndpoint(
            token: { usageToken },
            now: { fixedNow },
            ingest: { _, _ in
                await MainActor.run {
                    server.usageIngest = makeEndpoint(ingest: newIngest, notes: newNotes)
                }
                return .stored
            },
            note: { rejection, at in originalNotes.note(rejection, at) }
        )
        let response = await server.route(request: request())
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(originalNotes.entries, [.init(rejection: nil, at: fixedNow)])
        XCTAssertEqual(newNotes.entries, [])
        let newCalls = await newIngest.calls
        XCTAssertEqual(newCalls, [])
    }

    func test_endpointReplacedDuringIngest_rejectionGoesToOriginal() async throws {
        let server = try srv()
        let originalNotes = NoteRecorder()
        let newIngest = IngestRecorder(outcome: .stored)
        let newNotes = NoteRecorder()
        server.usageIngest = UsageIngestEndpoint(
            token: { usageToken },
            now: { fixedNow },
            ingest: { _, _ in
                await MainActor.run {
                    server.usageIngest = makeEndpoint(ingest: newIngest, notes: newNotes)
                }
                return .unavailable
            },
            note: { rejection, at in originalNotes.note(rejection, at) }
        )
        let response = await server.route(request: request())
        XCTAssertEqual(response.statusCode, 503)
        XCTAssertEqual(originalNotes.entries, [.init(rejection: .unavailable, at: fixedNow)])
        XCTAssertEqual(newNotes.entries, [])
    }

    func test_endpointRemovedDuringIngest_originalIsNotedOnce() async throws {
        let server = try srv()
        let originalNotes = NoteRecorder()
        server.usageIngest = UsageIngestEndpoint(
            token: { usageToken },
            now: { fixedNow },
            ingest: { _, _ in
                await MainActor.run {
                    server.usageIngest = nil
                }
                return .dropped
            },
            note: { rejection, at in originalNotes.note(rejection, at) }
        )
        let response = await server.route(request: request())
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data("{}".utf8))
        XCTAssertEqual(originalNotes.entries, [.init(rejection: nil, at: fixedNow)])
    }

    // MARK: Rejection raw values

    func test_rejectionRawValues() {
        XCTAssertEqual(UsageIngestRejection.foreignOrigin.rawValue, "foreignOrigin")
        XCTAssertEqual(UsageIngestRejection.unauthorized.rawValue, "unauthorized")
        XCTAssertEqual(UsageIngestRejection.tooLarge.rawValue, "tooLarge")
        XCTAssertEqual(UsageIngestRejection.noBody.rawValue, "noBody")
        XCTAssertEqual(UsageIngestRejection.undecodable.rawValue, "undecodable")
        XCTAssertEqual(UsageIngestRejection.unavailable.rawValue, "unavailable")
    }
}

// MARK: - Real-listener tests (transport cap and .tooLarge noting)

@MainActor
final class CalyxMCPServerUsageIngestListenerTests: XCTestCase {

    private var server: CalyxMCPServer?
    private var agentEndpointDir: String?

    private static let twoMiB = 2 * 1024 * 1024
    private static let sixteenMiB = 16 * 1024 * 1024

    override func setUp() async throws {
        try await super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalyxMCPServerUsageIngestListenerTests-\(UUID().uuidString)").path
        agentEndpointDir = dir
        let server = CalyxMCPServer(agentEndpointDirectory: dir)
        server.agentRegistry = AgentRegistry()
        self.server = server
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        if let agentEndpointDir {
            try? FileManager.default.removeItem(atPath: agentEndpointDir)
        }
        agentEndpointDir = nil
        try await super.tearDown()
    }

    private func startServer() async throws -> (CalyxMCPServer, Int) {
        let server = try XCTUnwrap(server)
        try await server.start(token: serverToken, preferredPort: 0)
        let port = server.port
        XCTAssertNotEqual(port, 0)
        return (server, port)
    }

    private func install(on server: CalyxMCPServer) -> (IngestRecorder, NoteRecorder) {
        let ingest = IngestRecorder(outcome: .stored)
        let notes = NoteRecorder()
        server.usageIngest = makeEndpoint(ingest: ingest, notes: notes)
        return (ingest, notes)
    }

    private func send(
        port: Int, path: String, authorization: String?, contentLength: Int, body: Data?,
        extraHeaderLines: [String] = [], contentLengthText: String? = nil, shutdownWriteAfterSend: Bool = false
    ) async throws -> RawHTTPResponse {
        try await Task.detached {
            try sendRawUsagePost(
                port: port, path: path, authorization: authorization, contentLength: contentLength, body: body,
                extraHeaderLines: extraHeaderLines, contentLengthText: contentLengthText,
                shutdownWriteAfterSend: shutdownWriteAfterSend
            )
        }.value
    }

    /// Installs an endpoint whose `token` closure answers from `source`.
    private func install(on server: CalyxMCPServer, tokens source: TokenSource) -> (IngestRecorder, NoteRecorder) {
        let ingest = IngestRecorder(outcome: .stored)
        let notes = NoteRecorder()
        server.usageIngest = UsageIngestEndpoint(
            token: { source.read() },
            now: { fixedNow },
            ingest: { body, ns in await ingest.record(body, ns) },
            note: { rejection, at in notes.note(rejection, at) }
        )
        return (ingest, notes)
    }

    func test_twoMiB_withUsageToken_reachesIngestCompleteAndGets200() async throws {
        let (server, port) = try await startServer()
        let (ingest, notes) = install(on: server)
        let body = Data(repeating: 0x20, count: Self.twoMiB)
        let response = try await send(port: port, path: "/usage/v1/metrics", authorization: "Bearer \(usageToken)", contentLength: body.count, body: body)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data("{}".utf8))
        let calls = await ingest.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.body.count, Self.twoMiB)
        XCTAssertTrue(calls.first?.body == body, "the body must reach ingest byte for byte")
        XCTAssertEqual(notes.entries, [.init(rejection: nil, at: fixedNow)])
    }

    func test_twoMiB_withWrongToken_gets413AndIsNotedUnauthorized() async throws {
        let (server, port) = try await startServer()
        let (ingest, notes) = install(on: server)
        let response = try await send(port: port, path: "/usage/v1/metrics", authorization: "Bearer wrong-synthetic-token", contentLength: Self.twoMiB, body: nil)
        XCTAssertEqual(response.statusCode, 413)
        XCTAssertEqual(notes.entries, [.init(rejection: .unauthorized, at: fixedNow)])
        let calls = await ingest.calls
        XCTAssertEqual(calls, [])
    }

    func test_twoMiB_withServerToken_gets413AndIsNotedUnauthorized() async throws {
        let (server, port) = try await startServer()
        let (_, notes) = install(on: server)
        let response = try await send(port: port, path: "/usage/v1/metrics", authorization: "Bearer \(serverToken)", contentLength: Self.twoMiB, body: nil)
        XCTAssertEqual(response.statusCode, 413)
        XCTAssertEqual(notes.entries, [.init(rejection: .unauthorized, at: fixedNow)])
    }

    func test_twoMiB_withoutAuthorization_gets413AndIsNotedUnauthorized() async throws {
        let (server, port) = try await startServer()
        let (_, notes) = install(on: server)
        let response = try await send(port: port, path: "/usage/v1/metrics", authorization: nil, contentLength: Self.twoMiB, body: nil)
        XCTAssertEqual(response.statusCode, 413)
        XCTAssertEqual(notes.entries, [.init(rejection: .unauthorized, at: fixedNow)])
    }

    /// A header block over the server's limit (8 KiB) is refused before
    /// any body cap applies; it is never noted, even with the right token.
    func test_oversizedHeaderBlock_withUsageToken_gets413AndIsNotNoted() async throws {
        let (server, port) = try await startServer()
        let (ingest, notes) = install(on: server)
        let padding = String(repeating: "a", count: HTTPParser.maxHeaderSize + 1024)
        let response = try await send(
            port: port, path: "/usage/v1/metrics", authorization: "Bearer \(usageToken)",
            contentLength: 16, body: nil, extraHeaderLines: ["x-padding: \(padding)"]
        )
        XCTAssertEqual(response.statusCode, 413)
        XCTAssertEqual(notes.entries, [])
        let calls = await ingest.calls
        XCTAssertEqual(calls, [])
    }

    func test_overSixteenMiB_withUsageToken_gets413AndIsNotedTooLarge() async throws {
        let (server, port) = try await startServer()
        let (ingest, notes) = install(on: server)
        let response = try await send(port: port, path: "/usage/v1/metrics", authorization: "Bearer \(usageToken)", contentLength: Self.sixteenMiB + 1, body: nil)
        XCTAssertEqual(response.statusCode, 413)
        XCTAssertEqual(notes.entries, [.init(rejection: .tooLarge, at: fixedNow)])
        let calls = await ingest.calls
        XCTAssertEqual(calls, [])
    }

    func test_twoMiB_onAgentEvent_withUsageToken_gets413AndIsNotNoted() async throws {
        let (server, port) = try await startServer()
        let (_, notes) = install(on: server)
        let response = try await send(port: port, path: "/agent-event", authorization: "Bearer \(usageToken)", contentLength: Self.twoMiB, body: nil)
        XCTAssertEqual(response.statusCode, 413)
        XCTAssertEqual(notes.entries, [])
    }

    func test_twoMiB_onUsagePathWithQuery_withUsageToken_gets413AndIsNotNoted() async throws {
        let (server, port) = try await startServer()
        let (_, notes) = install(on: server)
        let response = try await send(port: port, path: "/usage/v1/metrics?x=1", authorization: "Bearer \(usageToken)", contentLength: Self.twoMiB, body: nil)
        XCTAssertEqual(response.statusCode, 413)
        XCTAssertEqual(notes.entries, [])
    }

    func test_twoMiB_noEndpointInstalled_gets413AndNothingIsNoted() async throws {
        let (server, port) = try await startServer()
        let (ingest, notes) = install(on: server)
        server.usageIngest = nil
        let response = try await send(port: port, path: "/usage/v1/metrics", authorization: "Bearer \(usageToken)", contentLength: Self.twoMiB, body: nil)
        XCTAssertEqual(response.statusCode, 413)
        XCTAssertEqual(notes.entries, [])
        let calls = await ingest.calls
        XCTAssertEqual(calls, [])
    }

    // MARK: Repeated Authorization headers over the real listener

    /// Two `Authorization` lines, in both orders and in the same and in
    /// different spellings (and both carrying the right token): none of
    /// them carries the credential.
    private static let repeatedAuthorizationVariants: [(name: String, lines: [String])] = [
        ("right first, same spelling", ["authorization: Bearer \(usageToken)", "authorization: Bearer wrong-synthetic"]),
        ("right last, same spelling", ["authorization: Bearer wrong-synthetic", "authorization: Bearer \(usageToken)"]),
        ("right first, different spellings", ["Authorization: Bearer \(usageToken)", "authorization: Bearer wrong-synthetic"]),
        ("right last, different spellings", ["authorization: Bearer wrong-synthetic", "Authorization: Bearer \(usageToken)"]),
        ("right twice, different spellings", ["Authorization: Bearer \(usageToken)", "authorization: Bearer \(usageToken)"]),
    ]

    func test_repeatedAuthorization_smallBody_gets401AndIsNotedUnauthorized() async throws {
        let (server, port) = try await startServer()
        for variant in Self.repeatedAuthorizationVariants {
            let (ingest, notes) = install(on: server)
            let body = Data("{}".utf8)
            let response = try await send(
                port: port, path: "/usage/v1/metrics", authorization: nil,
                contentLength: body.count, body: body, extraHeaderLines: variant.lines
            )
            XCTAssertEqual(response.statusCode, 401, variant.name)
            XCTAssertEqual(notes.entries, [.init(rejection: .unauthorized, at: fixedNow)], variant.name)
            let calls = await ingest.calls
            XCTAssertEqual(calls, [], variant.name)
        }
    }

    func test_repeatedAuthorization_twoMiB_gets413AndIsNotedUnauthorized() async throws {
        let (server, port) = try await startServer()
        // An implementation that grants 16 MiB here waits for a body that
        // never comes; keep that failure short.
        server.connectionReceiveDeadline = .seconds(3)
        for variant in Self.repeatedAuthorizationVariants {
            let (ingest, notes) = install(on: server)
            let response = try await send(
                port: port, path: "/usage/v1/metrics", authorization: nil,
                contentLength: Self.twoMiB, body: nil, extraHeaderLines: variant.lines
            )
            XCTAssertEqual(response.statusCode, 413, variant.name)
            XCTAssertEqual(notes.entries, [.init(rejection: .unauthorized, at: fixedNow)], variant.name)
            let calls = await ingest.calls
            XCTAssertEqual(calls, [], variant.name)
        }
    }

    // MARK: The verdict is taken once, only for the usage path

    func test_tokenClosure_isNotCalled_forAgentEventRequest() async throws {
        let (server, port) = try await startServer()
        let source = TokenSource(answers: [usageToken], thereafter: usageToken)
        _ = install(on: server, tokens: source)
        let body = Data("{}".utf8)
        _ = try await send(port: port, path: "/agent-event", authorization: "Bearer \(usageToken)", contentLength: body.count, body: body)
        XCTAssertEqual(source.calls, 0)
    }

    func test_tokenClosure_isCalledOnce_forRefusedUsageRequest() async throws {
        let (server, port) = try await startServer()
        let source = TokenSource(answers: [usageToken], thereafter: usageToken)
        let (_, notes) = install(on: server, tokens: source)
        let response = try await send(port: port, path: "/usage/v1/metrics", authorization: "Bearer wrong-synthetic", contentLength: Self.twoMiB, body: nil)
        XCTAssertEqual(response.statusCode, 413)
        XCTAssertEqual(source.calls, 1)
        XCTAssertEqual(notes.entries, [.init(rejection: .unauthorized, at: fixedNow)])
    }

    /// The note for a refused body uses the verdict that chose the cap,
    /// not a second reading of the token.
    func test_tokenRightOnFirstCallOnly_overSixteenMiB_isStillNotedTooLarge() async throws {
        let (server, port) = try await startServer()
        let source = TokenSource(answers: [usageToken], thereafter: nil)
        let (_, notes) = install(on: server, tokens: source)
        let response = try await send(port: port, path: "/usage/v1/metrics", authorization: "Bearer \(usageToken)", contentLength: Self.sixteenMiB + 1, body: nil)
        XCTAssertEqual(response.statusCode, 413)
        XCTAssertEqual(notes.entries, [.init(rejection: .tooLarge, at: fixedNow)])
    }

    // MARK: A cut-off body is not an export

    /// The client declares 1,000 bytes, sends 10 and closes its write side:
    /// the request did not fully arrive and never reaches the route.
    func test_cutOffBody_isNotNotedAndNotIngested() async throws {
        let (server, port) = try await startServer()
        let (ingest, notes) = install(on: server)
        let response = try await send(
            port: port, path: "/usage/v1/metrics", authorization: "Bearer \(usageToken)",
            contentLength: 1_000, body: Data(repeating: 0x20, count: 10), shutdownWriteAfterSend: true
        )
        XCTAssertEqual(response.statusCode, 400)
        XCTAssertEqual(notes.entries, [])
        let calls = await ingest.calls
        XCTAssertEqual(calls, [])
    }

    /// The client declares 1,000 bytes, sends none and closes: the request
    /// never reaches the route, so not even `.noBody` is noted.
    func test_cutOffBody_zeroBytes_isNotNotedAndNotIngested() async throws {
        let (server, port) = try await startServer()
        let (ingest, notes) = install(on: server)
        let response = try await send(
            port: port, path: "/usage/v1/metrics", authorization: "Bearer \(usageToken)",
            contentLength: 1_000, body: Data(), shutdownWriteAfterSend: true
        )
        XCTAssertEqual(response.statusCode, 400)
        XCTAssertEqual(notes.entries, [])
        let calls = await ingest.calls
        XCTAssertEqual(calls, [])
    }

    // MARK: Transport 400 is not noted (deliberate)

    func test_malformedContentLength_onUsagePath_gets400AndIsNotNoted() async throws {
        let (server, port) = try await startServer()
        let (ingest, notes) = install(on: server)
        let response = try await send(
            port: port, path: "/usage/v1/metrics", authorization: "Bearer \(usageToken)",
            contentLength: 0, body: nil, contentLengthText: "abc"
        )
        XCTAssertEqual(response.statusCode, 400)
        XCTAssertEqual(notes.entries, [])
        let calls = await ingest.calls
        XCTAssertEqual(calls, [])
    }
}

// MARK: - Raw socket helper

private struct RawHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
}

private func socketError(_ code: Int, _ message: String) -> NSError {
    NSError(domain: "CalyxMCPServerUsageIngestListenerTests", code: code, userInfo: [NSLocalizedDescriptionKey: message])
}

/// File scope (no actor isolation), so it can block inside `Task.detached`
/// without starving the server's main-actor connection handling. Sends the
/// header block declaring `contentLength`, then `body` when given (pass nil
/// to send headers only: the cap is decided from the header block, and not
/// writing megabytes into a connection the server has already answered and
/// closed keeps the 413 readable). `SO_NOSIGPIPE` keeps a write onto a
/// closed connection from killing the test process. Reads to EOF.
private func sendRawUsagePost(
    port: Int, path: String, authorization: String?, contentLength: Int, body: Data?,
    extraHeaderLines: [String] = [], contentLengthText: String? = nil, shutdownWriteAfterSend: Bool = false
) throws -> RawHTTPResponse {
    var headerString = "POST \(path) HTTP/1.1\r\n"
    headerString += "host: 127.0.0.1:\(port)\r\n"
    if let authorization {
        headerString += "authorization: \(authorization)\r\n"
    }
    for line in extraHeaderLines {
        headerString += line + "\r\n"
    }
    headerString += "content-type: application/json\r\n"
    headerString += "content-length: \(contentLengthText ?? String(contentLength))\r\n"
    headerString += "connection: keep-alive\r\n"
    headerString += "\r\n"

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(truncatingIfNeeded: port).bigEndian
    addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else { throw socketError(1, "socket() failed: errno \(errno)") }
    defer { close(fd) }

    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var recvTimeout = timeval(tv_sec: 15, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout, socklen_t(MemoryLayout<timeval>.size))

    let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
            Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connectResult == 0 else { throw socketError(2, "connect() failed: errno \(errno)") }

    var toSend = Data(headerString.utf8)
    if let body {
        toSend.append(body)
    }
    try toSend.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
        guard let base = rawBuf.baseAddress else { return }
        var offset = 0
        while offset < rawBuf.count {
            let sent = Darwin.send(fd, base.advanced(by: offset), rawBuf.count - offset, 0)
            if sent > 0 {
                offset += sent
                continue
            }
            let code = errno
            if sent < 0 && code == EINTR { continue }
            // The server may answer and close while the rest is still
            // being written; stop writing and read its answer.
            if code == EPIPE || code == ECONNRESET { return }
            throw socketError(3, "send() failed: errno \(code)")
        }
    }

    if shutdownWriteAfterSend {
        // Ends the request early: the server sees the peer close.
        _ = shutdown(fd, SHUT_WR)
    }

    var responseData = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        let received = buffer.withUnsafeMutableBytes { rawBuf -> Int in
            Darwin.recv(fd, rawBuf.baseAddress, rawBuf.count, 0)
        }
        if received > 0 {
            responseData.append(contentsOf: buffer.prefix(received))
            continue
        }
        if received == 0 { break }
        let code = errno
        if code == EINTR { continue }
        if code == EAGAIN || code == EWOULDBLOCK {
            throw socketError(6, "receive timed out after 15 s (\(responseData.count) bytes received)")
        }
        if code == ECONNRESET { break }
        throw socketError(7, "recv() failed: errno \(code)")
    }

    guard let separator = responseData.range(of: Data("\r\n\r\n".utf8)) else {
        throw socketError(4, "no complete response head (\(responseData.count) bytes)")
    }
    let head = String(decoding: responseData[responseData.startIndex..<separator.lowerBound], as: UTF8.self)
    let statusLine = head.components(separatedBy: "\r\n").first ?? ""
    let parts = statusLine.split(separator: " ", maxSplits: 2)
    guard parts.count >= 2, let statusCode = Int(parts[1]) else {
        throw socketError(5, "could not parse status line: \(statusLine)")
    }
    return RawHTTPResponse(statusCode: statusCode, body: Data(responseData[separator.upperBound...]))
}
