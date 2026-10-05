import XCTest
@testable import Calyx

final class HTTPParserTests: XCTestCase {

    // MARK: - Helpers

    /// Build raw HTTP request data from a request line, headers, and optional body.
    private func makeRawRequest(
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: String? = nil
    ) -> Data {
        var lines = ["\(method) \(path) HTTP/1.1"]
        for (key, value) in headers {
            lines.append("\(key): \(value)")
        }
        if let body {
            let bodyData = body.data(using: .utf8)!
            // Only add Content-Length if not already provided explicitly
            if headers["Content-Length"] == nil
                && headers["content-length"] == nil {
                lines.append("Content-Length: \(bodyData.count)")
            }
        }
        let headerBlock = lines.joined(separator: "\r\n") + "\r\n\r\n"
        var data = headerBlock.data(using: .utf8)!
        if let body {
            data.append(body.data(using: .utf8)!)
        }
        return data
    }

    /// Build raw HTTP request data from a raw string (for malformed / edge-case tests).
    private func makeRawData(_ string: String) -> Data {
        Data(string.utf8)
    }

    // MARK: - Happy Path: POST

    func test_parseValidPostRequest() throws {
        let raw = makeRawRequest(
            method: "POST",
            path: "/mcp",
            headers: [
                "Content-Type": "application/json",
            ],
            body: "{}"
        )

        let request = try HTTPParser.parse(raw)

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertNotNil(request.body)
        XCTAssertEqual(String(data: request.body!, encoding: .utf8), "{}")
    }

    // MARK: - Happy Path: GET

    func test_parseValidGetRequest() throws {
        let raw = makeRawRequest(
            method: "GET",
            path: "/health",
            headers: ["Host": "localhost"]
        )

        let request = try HTTPParser.parse(raw)

        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/health")
        XCTAssertEqual(request.headers["Host"], "localhost")
        XCTAssertNil(request.body)
    }

    // MARK: - Header Parsing: Authorization

    func test_parseRequestWithAuthorization() throws {
        let raw = makeRawRequest(
            method: "GET",
            path: "/secure",
            headers: [
                "Host": "localhost",
                "Authorization": "Bearer abc123",
            ]
        )

        let request = try HTTPParser.parse(raw)

        XCTAssertEqual(request.headers["Authorization"], "Bearer abc123")
    }

    // MARK: - Error: Header Too Large

    func test_headerTooLarge_throws() {
        // Build a header block that exceeds 8KB
        let hugeValue = String(repeating: "X", count: HTTPParser.maxHeaderSize + 1)
        let raw = makeRawRequest(
            method: "GET",
            path: "/",
            headers: ["X-Large": hugeValue]
        )

        XCTAssertThrowsError(try HTTPParser.parse(raw)) { error in
            XCTAssertEqual(error as? HTTPParseError, .headerTooLarge)
        }
    }

    // MARK: - Error: Body Too Large

    func test_bodyTooLarge_throws() {
        // Content-Length claims more than 1MB
        let oversizedLength = HTTPParser.maxBodySize + 1
        let rawString =
            "POST /upload HTTP/1.1\r\n"
            + "Content-Length: \(oversizedLength)\r\n"
            + "\r\n"
        let raw = makeRawData(rawString)

        XCTAssertThrowsError(try HTTPParser.parse(raw)) { error in
            XCTAssertEqual(error as? HTTPParseError, .bodyTooLarge)
        }
    }

    // MARK: - Error: Invalid Content-Length (Negative)

    func test_invalidContentLength_negative_throws() {
        let rawString =
            "POST /data HTTP/1.1\r\n"
            + "Content-Length: -1\r\n"
            + "\r\n"
        let raw = makeRawData(rawString)

        XCTAssertThrowsError(try HTTPParser.parse(raw)) { error in
            XCTAssertEqual(error as? HTTPParseError, .invalidContentLength)
        }
    }

    // MARK: - Error: Invalid Content-Length (Non-Numeric)

    func test_invalidContentLength_nonNumeric_throws() {
        let rawString =
            "POST /data HTTP/1.1\r\n"
            + "Content-Length: abc\r\n"
            + "\r\n"
        let raw = makeRawData(rawString)

        XCTAssertThrowsError(try HTTPParser.parse(raw)) { error in
            XCTAssertEqual(error as? HTTPParseError, .invalidContentLength)
        }
    }

    // MARK: - Error: Malformed Request

    func test_malformedRequest_throws() {
        let garbage = makeRawData("not an http request at all\u{00}\u{01}\u{02}")

        XCTAssertThrowsError(try HTTPParser.parse(garbage)) { error in
            XCTAssertEqual(error as? HTTPParseError, .malformedRequest)
        }
    }

    // MARK: - Response Serialization: 200 OK

    func test_responseSerialize_200() {
        let body = "{}".data(using: .utf8)!
        let response = HTTPResponse(
            statusCode: 200,
            statusMessage: "OK",
            headers: ["Content-Type": "application/json"],
            body: body
        )

        let serialized = response.serialize()
        let text = String(data: serialized, encoding: .utf8)!

        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{}"))
    }

    // MARK: - Response Serialization: 401 Unauthorized

    func test_responseSerialize_401() {
        let body = "{\"error\":\"unauthorized\"}".data(using: .utf8)!
        let response = HTTPResponse(
            statusCode: 401,
            statusMessage: "Unauthorized",
            headers: ["Content-Type": "application/json"],
            body: body
        )

        let serialized = response.serialize()
        let text = String(data: serialized, encoding: .utf8)!

        XCTAssertTrue(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        XCTAssertTrue(text.contains("Content-Length: \(body.count)\r\n"))
        XCTAssertTrue(text.contains("{\"error\":\"unauthorized\"}"))
    }

    // MARK: - Response Serialization: 413 Payload Too Large

    func test_responseSerialize_413() {
        let body = "{\"error\":\"payload too large\"}".data(using: .utf8)!
        let response = HTTPResponse(
            statusCode: 413,
            statusMessage: "Payload Too Large",
            headers: ["Content-Type": "application/json"],
            body: body
        )

        let serialized = response.serialize()
        let text = String(data: serialized, encoding: .utf8)!

        XCTAssertTrue(text.hasPrefix("HTTP/1.1 413 Payload Too Large\r\n"))
        XCTAssertTrue(text.contains("{\"error\":\"payload too large\"}"))
    }

    // MARK: - Response JSON Helper

    func test_response_json_helper() throws {
        let response = HTTPParser.response(
            statusCode: 200,
            json: ["key": "value"]
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["Content-Type"], "application/json")

        let body = try XCTUnwrap(response.body)
        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: String]
        XCTAssertEqual(parsed?["key"], "value")
    }

    // MARK: - Edge Case: Content-Length Mismatch (Body Too Short)

    func test_contentLengthMismatch_bodyTooShort() {
        // Content-Length says 100 but actual body is only 5 bytes: the
        // request did not fully arrive, which is an error (R3a-0).
        let rawString =
            "POST /data HTTP/1.1\r\n"
            + "Content-Length: 100\r\n"
            + "\r\n"
            + "hello"
        let raw = makeRawData(rawString)

        XCTAssertThrowsError(try HTTPParser.parse(raw)) { error in
            XCTAssertEqual(error as? HTTPParseError, .incompleteBody)
        }
    }

    func test_parse_bodyOneByteShort_throwsIncompleteBody() {
        let raw = makeRawData("POST /data HTTP/1.1\r\nContent-Length: 6\r\n\r\nhello")
        XCTAssertThrowsError(try HTTPParser.parse(raw)) { error in
            XCTAssertEqual(error as? HTTPParseError, .incompleteBody)
        }
    }

    func test_parse_noBodyBytesWithContentLength5_throwsIncompleteBody() {
        let raw = makeRawData("POST /data HTTP/1.1\r\nContent-Length: 5\r\n\r\n")
        XCTAssertThrowsError(try HTTPParser.parse(raw)) { error in
            XCTAssertEqual(error as? HTTPParseError, .incompleteBody)
        }
    }

    func test_parse_bodyOfExactLength_parses() throws {
        let raw = makeRawData("POST /data HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello")
        let request = try HTTPParser.parse(raw)
        XCTAssertEqual(request.body, Data("hello".utf8))
    }


    // MARK: - Edge Case: Case-Insensitive Headers

    func test_caseInsensitiveHeaders() throws {
        let rawString =
            "POST /data HTTP/1.1\r\n"
            + "content-type: application/json\r\n"
            + "content-length: 2\r\n"
            + "\r\n"
            + "{}"
        let raw = makeRawData(rawString)

        // Should parse successfully regardless of header casing
        let request = try HTTPParser.parse(raw)

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/data")
        XCTAssertNotNil(request.body)
        XCTAssertEqual(String(data: request.body!, encoding: .utf8), "{}")

        // Headers should be accessible (parser may normalize or preserve case)
        let contentType = request.headers["Content-Type"]
            ?? request.headers["content-type"]
        XCTAssertEqual(contentType, "application/json",
            "content-type header must be parseable regardless of case")
    }

    // MARK: - Edge Case: Empty Body with Zero Content-Length

    func test_emptyBody_withZeroContentLength() throws {
        let rawString =
            "POST /empty HTTP/1.1\r\n"
            + "Content-Length: 0\r\n"
            + "\r\n"
        let raw = makeRawData(rawString)

        let request = try HTTPParser.parse(raw)

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/empty")

        // Body should be nil or empty Data — either is acceptable
        if let body = request.body {
            XCTAssertTrue(body.isEmpty, "Body with Content-Length: 0 should be empty")
        }
        // nil is also fine — no assertion needed for that case
    }

    // MARK: - Constants Verification

    func test_maxHeaderSize_is8KB() {
        XCTAssertEqual(HTTPParser.maxHeaderSize, 8 * 1024)
    }

    func test_maxBodySize_is1MB() {
        XCTAssertEqual(HTTPParser.maxBodySize, 1 * 1024 * 1024)
    }

    // ==================== shared Content-Length lookup ====================
    //
    // `contentLength(inHeaderString:)` is the single implementation
    // `parse(_:)` and `CalyxMCPServer.receiveUntilComplete`'s pre-parse
    // buffer-completeness gate (`HTTPParser.completeness(of:)`) both now
    // route through, so a duplicate or mixed-case `Content-Length`
    // header can never be resolved differently by the two.

    // Duplicate `Content-Length` headers, identical casing: the shared
    // lookup takes the first occurrence in document order. This is a
    // deliberate behavior change from the earlier implementation
    // (a `[String: String]` dictionary where a same-case duplicate key
    // simply overwrote the earlier value, so the *last* occurrence won)
    // — see `contentLength(inHeaderString:)`'s doc comment for why
    // "first occurrence, case-insensitively" was chosen as the one
    // deterministic rule both call sites now share.
    func test_contentLength_duplicateHeaders_sameCasing_firstOccurrenceWins() {
        let headerString =
            "POST /data HTTP/1.1\r\n"
            + "Content-Length: 5\r\n"
            + "Content-Length: 999\r\n"

        let result = HTTPParser.contentLength(inHeaderString: headerString)
        guard case .success(let length) = result else {
            return XCTFail("Expected .success, got \(result)")
        }
        XCTAssertEqual(length, 5, "Duplicate Content-Length headers must resolve to the first occurrence")
    }

    // Duplicate `Content-Length` headers with mixed casing: previously
    // non-deterministic (Dictionary iteration order over two
    // differently-cased keys); the shared lookup is a simple ordered
    // scan, so this is now deterministic too — same rule, same result.
    func test_contentLength_duplicateHeaders_mixedCasing_firstOccurrenceWins() {
        let headerString =
            "POST /data HTTP/1.1\r\n"
            + "content-length: 7\r\n"
            + "Content-Length: 999\r\n"
            + "CONTENT-LENGTH: 42\r\n"

        let result = HTTPParser.contentLength(inHeaderString: headerString)
        guard case .success(let length) = result else {
            return XCTFail("Expected .success, got \(result)")
        }
        XCTAssertEqual(length, 7, "Duplicate, mixed-case Content-Length headers must resolve to the first occurrence")
    }

    // The gate (`completeness(of:)`) and `parse(_:)` must agree on
    // which of several duplicate/mixed-case Content-Length values wins
    // — both route through `contentLength(inHeaderString:)`, so a
    // complete buffer built with a duplicate header must be judged
    // `.complete` by the gate at exactly the byte count `parse(_:)`
    // itself then successfully parses.
    func test_gateAndParse_agreeOnDuplicateContentLengthSelection() throws {
        let body = "{}"
        let bodyData = Data(body.utf8)
        let rawString =
            "POST /data HTTP/1.1\r\n"
            + "content-length: \(bodyData.count)\r\n"
            + "Content-Length: 999999\r\n"
            + "\r\n"
            + body
        let raw = makeRawData(rawString)

        let (state, requiredTotal) = HTTPParser.completeness(of: raw)
        XCTAssertEqual(state, .complete, "Gate must judge the buffer complete using the same (first-occurrence) Content-Length parse(_:) will use")
        XCTAssertEqual(requiredTotal, raw.count, "Gate's requiredTotal must match the buffer's actual size once complete")

        let request = try HTTPParser.parse(raw)
        XCTAssertEqual(request.body, bodyData, "parse(_:) must select the same first-occurrence Content-Length the gate used")
    }

    // ==================== completeness(of:) ====================

    func test_completeness_headersNotYetTerminated_isIncomplete() {
        let raw = makeRawData("POST /data HTTP/1.1\r\nContent-Length: 2\r\n")
        let (state, requiredTotal) = HTTPParser.completeness(of: raw)
        XCTAssertEqual(state, .incomplete)
        XCTAssertNil(requiredTotal, "requiredTotal must be nil until the header terminator itself has been found")
    }

    func test_completeness_headersTerminatedBodyNotYetArrived_isIncompleteWithKnownTotal() {
        let headerOnly = "POST /data HTTP/1.1\r\nContent-Length: 5\r\n\r\n"
        let raw = makeRawData(headerOnly)
        let (state, requiredTotal) = HTTPParser.completeness(of: raw)
        XCTAssertEqual(state, .incomplete)
        XCTAssertEqual(requiredTotal, headerOnly.utf8.count + 5, "requiredTotal must be headerLength + Content-Length once the terminator is known")
    }

    func test_completeness_fullRequest_isComplete() {
        let raw = makeRawRequest(method: "POST", path: "/data", body: "{}")
        let (state, requiredTotal) = HTTPParser.completeness(of: raw)
        XCTAssertEqual(state, .complete)
        XCTAssertEqual(requiredTotal, raw.count)
    }

    func test_completeness_noContentLengthHeader_isCompleteAssoonAsHeadersTerminate() {
        let raw = makeRawRequest(method: "GET", path: "/health", headers: ["Host": "localhost"])
        let (state, _) = HTTPParser.completeness(of: raw)
        XCTAssertEqual(state, .complete, "A request with no Content-Length has no body to wait for once headers terminate")
    }

    // MARK: - Integer-overflow-safe size gating (pre-auth DoS)

    // A `Content-Length` near `Int.max` must be rejected as `.tooLarge`
    // immediately — not crash the process by overflowing `headerLength +
    // contentLength` (a client-triggerable, pre-authentication integer
    // overflow trap otherwise reachable with a single header line).
    func test_completeness_contentLengthNearIntMax_isTooLarge_doesNotCrash() {
        let rawString =
            "POST /data HTTP/1.1\r\n"
            + "Content-Length: \(Int.max)\r\n"
            + "\r\n"
        let raw = makeRawData(rawString)

        let (state, requiredTotal) = HTTPParser.completeness(of: raw)
        XCTAssertEqual(state, .tooLarge)
        XCTAssertNil(requiredTotal, "A too-large Content-Length must not report a requiredTotal to accumulate toward")
    }

    // The gate's size threshold must match `parse(_:)`'s own
    // `length > maxBodySize` rejection exactly — previously the gate
    // compared `headerLength + contentLength` against the looser
    // `maxHeaderSize + maxBodySize`, which could accept (as still
    // "waiting for more data") a Content-Length `parse(_:)` would
    // itself reject as `.bodyTooLarge` once the buffer did complete.
    func test_completeness_contentLengthJustOverMaxBodySize_isTooLarge() {
        let rawString =
            "POST /data HTTP/1.1\r\n"
            + "Content-Length: \(HTTPParser.maxBodySize + 1)\r\n"
            + "\r\n"
        let raw = makeRawData(rawString)

        let (state, _) = HTTPParser.completeness(of: raw)
        XCTAssertEqual(state, .tooLarge)
    }

    func test_completeness_contentLengthAtMaxBodySize_isNotTooLarge() {
        let rawString =
            "POST /data HTTP/1.1\r\n"
            + "Content-Length: \(HTTPParser.maxBodySize)\r\n"
            + "\r\n"
        let raw = makeRawData(rawString)

        let (state, requiredTotal) = HTTPParser.completeness(of: raw)
        XCTAssertEqual(state, .incomplete, "Exactly maxBodySize is still an acceptable Content-Length — only strictly greater is rejected")
        XCTAssertEqual(requiredTotal, rawString.utf8.count + HTTPParser.maxBodySize)
    }

    // ==================== request line must never be scanned for Content-Length ====================
    //
    // Before this diff, `parse(_:)` built its `headers` dictionary from
    // `lines[1...]` — explicitly excluding the request line (`lines[0]`).
    // `contentLength(inHeaderString:)` initially scanned the *entire*
    // `headerString` including the request line. `parse(_:)`'s own
    // request-line parser is lenient (`lines[0].split(separator: " ",
    // maxSplits: 2)` only requires `count >= 2`), so a request line
    // shaped like `Content-Length: 999999` parses structurally without
    // throwing `.malformedRequest`, and used to *also* be picked up as
    // a genuine Content-Length declaration. Fixed via `.dropFirst()` in
    // `contentLength(inHeaderString:)`.

    func test_contentLength_ignoresPathologicalRequestLine() {
        // The request line itself looks like a Content-Length header;
        // no real one follows. Must resolve to .success(nil), never
        // picking up "999999" from the request line.
        let headerString =
            "Content-Length: 999999\r\n"
            + "Host: localhost\r\n"

        let result = HTTPParser.contentLength(inHeaderString: headerString)
        guard case .success(let length) = result else {
            return XCTFail("Expected .success, got \(result)")
        }
        XCTAssertNil(length, "The request line must never be scanned for Content-Length, even when it happens to look like one")
    }

    func test_completeness_pathologicalRequestLine_notTreatedAsContentLength() {
        let rawString =
            "Content-Length: 999999\r\n"
            + "Host: localhost\r\n"
            + "\r\n"
        let raw = makeRawData(rawString)

        let (state, requiredTotal) = HTTPParser.completeness(of: raw)
        XCTAssertEqual(state, .complete, "With no real Content-Length header, the buffer is complete as soon as headers terminate — the request line's 'Content-Length: 999999' must not be mistaken for a real header")
        XCTAssertEqual(requiredTotal, rawString.utf8.count)
    }

    func test_parse_pathologicalRequestLine_notTreatedAsContentLength() throws {
        let rawString =
            "Content-Length: 999999\r\n"
            + "Host: localhost\r\n"
            + "\r\n"
            + "trailing-bytes-that-must-not-be-read-as-a-body"
        let raw = makeRawData(rawString)

        let request = try HTTPParser.parse(raw)
        XCTAssertNil(request.body, "With no real Content-Length header, parse(_:) must not extract a body — even though the request line looks like a Content-Length header")
    }
}

// MARK: - Per-path body cap with the usage route (R3a)

/// `bodyLimit(forHeaderString:isAuthorized:isUsageAuthorized:)`: 32 MiB for
/// `/calyx-mcp` when `isAuthorized` accepts, 16 MiB for `/usage/v1/metrics`
/// when `isUsageAuthorized` accepts, 1 MiB for everything else. Each closure
/// is asked only for its own path and receives the trimmed `Authorization`
/// value (nil without the header).
extension HTTPParserTests {

    private static let oneMiB = 1024 * 1024
    private static let sixteenMiB = 16 * 1024 * 1024
    private static let thirtyTwoMiB = 32 * 1024 * 1024

    private func headerBlock(_ requestLine: String, authorization: String? = nil) -> String {
        var lines = [requestLine, "Host: 127.0.0.1"]
        if let authorization {
            lines.append("Authorization: \(authorization)")
        }
        lines.append("Content-Type: application/json")
        return lines.joined(separator: "\r\n")
    }

    func test_usageMetricsPath_constant() {
        XCTAssertEqual(HTTPParser.usageMetricsPath, "/usage/v1/metrics")
    }

    func test_maxUsageMetricsBodySize_is16MiB() {
        XCTAssertEqual(HTTPParser.maxUsageMetricsBodySize, 16_777_216)
    }

    func test_bodyLimit_usagePath_usageAuthorized_is16MiB() {
        let limit = HTTPParser.bodyLimit(
            forHeaderString: headerBlock("POST /usage/v1/metrics HTTP/1.1", authorization: "Bearer u"),
            isAuthorized: { _ in false },
            isUsageAuthorized: { _ in true }
        )
        XCTAssertEqual(limit, Self.sixteenMiB)
    }

    func test_bodyLimit_usagePath_usageAuthorized_isAuthorizedAlsoTrue_is16MiB() {
        let limit = HTTPParser.bodyLimit(
            forHeaderString: headerBlock("POST /usage/v1/metrics HTTP/1.1", authorization: "Bearer u"),
            isAuthorized: { _ in true },
            isUsageAuthorized: { _ in true }
        )
        XCTAssertEqual(limit, Self.sixteenMiB)
    }

    func test_bodyLimit_usagePath_notUsageAuthorized_is1MiB_evenWhenIsAuthorizedAccepts() {
        let limit = HTTPParser.bodyLimit(
            forHeaderString: headerBlock("POST /usage/v1/metrics HTTP/1.1", authorization: "Bearer s"),
            isAuthorized: { _ in true },
            isUsageAuthorized: { _ in false }
        )
        XCTAssertEqual(limit, Self.oneMiB)
    }

    func test_bodyLimit_usagePath_neitherAuthorized_is1MiB() {
        let limit = HTTPParser.bodyLimit(
            forHeaderString: headerBlock("POST /usage/v1/metrics HTTP/1.1", authorization: "Bearer x"),
            isAuthorized: { _ in false },
            isUsageAuthorized: { _ in false }
        )
        XCTAssertEqual(limit, Self.oneMiB)
    }

    func test_bodyLimit_calyxMCP_authorized_is32MiB_whateverIsUsageAuthorizedSays() {
        for usage in [true, false] {
            let limit = HTTPParser.bodyLimit(
                forHeaderString: headerBlock("POST /calyx-mcp HTTP/1.1", authorization: "Bearer s"),
                isAuthorized: { _ in true },
                isUsageAuthorized: { _ in usage }
            )
            XCTAssertEqual(limit, Self.thirtyTwoMiB, "isUsageAuthorized=\(usage)")
        }
    }

    func test_bodyLimit_calyxMCP_notAuthorized_is1MiB_evenWhenUsageAuthorizedAccepts() {
        let limit = HTTPParser.bodyLimit(
            forHeaderString: headerBlock("POST /calyx-mcp HTTP/1.1", authorization: "Bearer u"),
            isAuthorized: { _ in false },
            isUsageAuthorized: { _ in true }
        )
        XCTAssertEqual(limit, Self.oneMiB)
    }

    func test_bodyLimit_usagePath_asksOnlyIsUsageAuthorized() {
        var authorizedCalls = 0
        var usageCalls = 0
        _ = HTTPParser.bodyLimit(
            forHeaderString: headerBlock("POST /usage/v1/metrics HTTP/1.1", authorization: "Bearer u"),
            isAuthorized: { _ in authorizedCalls += 1; return true },
            isUsageAuthorized: { _ in usageCalls += 1; return true }
        )
        XCTAssertEqual(authorizedCalls, 0)
        XCTAssertEqual(usageCalls, 1)
    }

    func test_bodyLimit_calyxMCP_asksOnlyIsAuthorized() {
        var authorizedCalls = 0
        var usageCalls = 0
        _ = HTTPParser.bodyLimit(
            forHeaderString: headerBlock("POST /calyx-mcp HTTP/1.1", authorization: "Bearer s"),
            isAuthorized: { _ in authorizedCalls += 1; return true },
            isUsageAuthorized: { _ in usageCalls += 1; return true }
        )
        XCTAssertEqual(authorizedCalls, 1)
        XCTAssertEqual(usageCalls, 0)
    }

    func test_bodyLimit_otherPath_asksNeitherClosure_and_is1MiB() {
        var calls = 0
        let limit = HTTPParser.bodyLimit(
            forHeaderString: headerBlock("POST /mcp HTTP/1.1", authorization: "Bearer s"),
            isAuthorized: { _ in calls += 1; return true },
            isUsageAuthorized: { _ in calls += 1; return true }
        )
        XCTAssertEqual(limit, Self.oneMiB)
        XCTAssertEqual(calls, 0)
    }

    func test_bodyLimit_usagePathWithQueryString_is1MiB_andAsksNeitherClosure() {
        var calls = 0
        let limit = HTTPParser.bodyLimit(
            forHeaderString: headerBlock("POST /usage/v1/metrics?x=1 HTTP/1.1", authorization: "Bearer u"),
            isAuthorized: { _ in calls += 1; return true },
            isUsageAuthorized: { _ in calls += 1; return true }
        )
        XCTAssertEqual(limit, Self.oneMiB)
        XCTAssertEqual(calls, 0)
    }

    func test_bodyLimit_usagePath_isUsageAuthorizedReceivesTrimmedValue() {
        var received: [String?] = []
        _ = HTTPParser.bodyLimit(
            forHeaderString: "POST /usage/v1/metrics HTTP/1.1\r\nHost: h\r\nAuthorization:   Bearer synthetic-usage   \r\nX: y",
            isAuthorized: { _ in false },
            isUsageAuthorized: { received.append($0); return true }
        )
        XCTAssertEqual(received, ["Bearer synthetic-usage"])
    }

    func test_bodyLimit_usagePath_lowercaseHeaderName_isFound() {
        var received: [String?] = []
        _ = HTTPParser.bodyLimit(
            forHeaderString: "POST /usage/v1/metrics HTTP/1.1\r\nhost: h\r\nauthorization: Bearer synthetic-usage",
            isAuthorized: { _ in false },
            isUsageAuthorized: { received.append($0); return true }
        )
        XCTAssertEqual(received, ["Bearer synthetic-usage"])
    }

    func test_bodyLimit_usagePath_noAuthorizationHeader_closureReceivesNil() {
        var received: [String?] = []
        _ = HTTPParser.bodyLimit(
            forHeaderString: headerBlock("POST /usage/v1/metrics HTTP/1.1"),
            isAuthorized: { _ in false },
            isUsageAuthorized: { received.append($0); return false }
        )
        XCTAssertEqual(received, [nil])
    }

    func test_bodyLimit_calyxMCP_isAuthorizedReceivesTrimmedValue() {
        var received: [String?] = []
        _ = HTTPParser.bodyLimit(
            forHeaderString: "POST /calyx-mcp HTTP/1.1\r\nAuthorization:  Bearer synthetic-server \r\nHost: h",
            isAuthorized: { received.append($0); return true },
            isUsageAuthorized: { _ in false }
        )
        XCTAssertEqual(received, ["Bearer synthetic-server"])
    }

    func test_bodyLimit_methodIsNotLookedAt_forUsagePath() {
        let limit = HTTPParser.bodyLimit(
            forHeaderString: headerBlock("PUT /usage/v1/metrics HTTP/1.1", authorization: "Bearer u"),
            isAuthorized: { _ in false },
            isUsageAuthorized: { _ in true }
        )
        XCTAssertEqual(limit, Self.sixteenMiB)
    }

    // Without the third argument the function behaves as before.

    func test_bodyLimit_twoArguments_usagePath_is1MiB_evenWhenIsAuthorizedAccepts() {
        let limit = HTTPParser.bodyLimit(
            forHeaderString: headerBlock("POST /usage/v1/metrics HTTP/1.1", authorization: "Bearer s"),
            isAuthorized: { _ in true }
        )
        XCTAssertEqual(limit, Self.oneMiB)
    }

    func test_bodyLimit_twoArguments_calyxMCP_authorized_is32MiB() {
        let limit = HTTPParser.bodyLimit(forHeaderString: headerBlock("POST /calyx-mcp HTTP/1.1", authorization: "Bearer s")) { _ in true }
        XCTAssertEqual(limit, Self.thirtyTwoMiB)
    }

    func test_bodyLimit_twoArguments_calyxMCP_notAuthorized_is1MiB() {
        let limit = HTTPParser.bodyLimit(forHeaderString: headerBlock("POST /calyx-mcp HTTP/1.1", authorization: "Bearer s")) { _ in false }
        XCTAssertEqual(limit, Self.oneMiB)
    }
}

// MARK: - Constant-time comparison (R3a)

extension HTTPParserTests {

    func test_constantTimeEquals_equalStrings_true() {
        XCTAssertTrue(HTTPParser.constantTimeEquals("Bearer abc123", "Bearer abc123"))
    }

    func test_constantTimeEquals_differentLengths_false() {
        XCTAssertFalse(HTTPParser.constantTimeEquals("abc", "abcd"))
        XCTAssertFalse(HTTPParser.constantTimeEquals("abcd", "abc"))
    }

    func test_constantTimeEquals_prefixOfOther_false() {
        XCTAssertFalse(HTTPParser.constantTimeEquals("", "a"))
        XCTAssertFalse(HTTPParser.constantTimeEquals("a", ""))
    }

    func test_constantTimeEquals_differenceInFirstByte_false() {
        XCTAssertFalse(HTTPParser.constantTimeEquals("xbcdef", "abcdef"))
    }

    func test_constantTimeEquals_differenceInLastByte_false() {
        XCTAssertFalse(HTTPParser.constantTimeEquals("abcdef", "abcdeg"))
    }

    func test_constantTimeEquals_emptyStrings_true() {
        XCTAssertTrue(HTTPParser.constantTimeEquals("", ""))
    }

    func test_constantTimeEquals_nonASCIIEqual_true() {
        XCTAssertTrue(HTTPParser.constantTimeEquals("トークン-é", "トークン-é"))
    }

    func test_constantTimeEquals_nonASCIIDifferent_false() {
        XCTAssertFalse(HTTPParser.constantTimeEquals("トークン-é", "トークン-e"))
    }

    /// Compares UTF-8 bytes, not Unicode canonical equivalence: precomposed
    /// "é" (C3 A9) and "e" + combining acute (65 CC 81) are equal as Swift
    /// Strings but differ as bytes.
    func test_constantTimeEquals_comparesBytesNotCanonicalEquivalence() {
        let precomposed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        XCTAssertEqual(precomposed, decomposed, "Fixture check: Swift String equality is canonical")
        XCTAssertFalse(HTTPParser.constantTimeEquals(precomposed, decomposed))
    }
}

// MARK: - One reading of the credential: repeated Authorization (R3a round 2)

extension HTTPParserTests {

    private func parseRaw(_ headerLines: [String], body: String = "{}") throws -> HTTPRequest {
        var raw = "POST /usage/v1/metrics HTTP/1.1\r\n"
        for line in headerLines {
            raw += line + "\r\n"
        }
        raw += "Content-Length: \(body.utf8.count)\r\n\r\n" + body
        return try HTTPParser.parse(Data(raw.utf8))
    }

    func test_parse_twoAuthorizationHeaders_sameSpelling_setsRepeatsAuthorization() throws {
        let request = try parseRaw(["Authorization: Bearer a", "Authorization: Bearer b"])
        XCTAssertTrue(request.repeatsAuthorization)
    }

    func test_parse_twoAuthorizationHeaders_differentSpellings_setsRepeatsAuthorization() throws {
        let request = try parseRaw(["authorization: Bearer a", "AUTHORIZATION: Bearer a"])
        XCTAssertTrue(request.repeatsAuthorization)
    }

    func test_parse_oneAuthorizationHeader_doesNotSetRepeatsAuthorization() throws {
        let request = try parseRaw(["Host: h", "authorization: Bearer a"])
        XCTAssertFalse(request.repeatsAuthorization)
    }

    func test_parse_noAuthorizationHeader_doesNotSetRepeatsAuthorization() throws {
        let request = try parseRaw(["Host: h"])
        XCTAssertFalse(request.repeatsAuthorization)
    }

    func test_parse_otherRepeatedHeader_doesNotSetRepeatsAuthorization() throws {
        let request = try parseRaw(["X-Other: 1", "X-Other: 2", "Authorization: Bearer a"])
        XCTAssertFalse(request.repeatsAuthorization)
    }

    func test_handBuiltRequest_repeatsAuthorizationIsFalse() {
        let request = HTTPRequest(method: "POST", path: "/usage/v1/metrics", headers: ["Authorization": "Bearer a"], body: nil)
        XCTAssertFalse(request.repeatsAuthorization)
    }

    func test_requestTarget_oneHeader_answersPathAndTrimmedValue() throws {
        let target = try XCTUnwrap(HTTPParser.requestTarget(inHeaderString: "POST /usage/v1/metrics HTTP/1.1\r\nHost: h\r\naUtHoRiZaTiOn:   Bearer v  "))
        XCTAssertEqual(target.path, "/usage/v1/metrics")
        XCTAssertEqual(target.authorization, "Bearer v")
    }

    func test_requestTarget_noHeader_answersNilValue() throws {
        let target = try XCTUnwrap(HTTPParser.requestTarget(inHeaderString: "POST /calyx-mcp HTTP/1.1\r\nHost: h"))
        XCTAssertEqual(target.path, "/calyx-mcp")
        XCTAssertNil(target.authorization)
    }

    func test_requestTarget_repeatedHeader_sameSpelling_answersNilValue() throws {
        let target = try XCTUnwrap(HTTPParser.requestTarget(inHeaderString: "POST /usage/v1/metrics HTTP/1.1\r\nAuthorization: Bearer v\r\nAuthorization: Bearer v"))
        XCTAssertEqual(target.path, "/usage/v1/metrics")
        XCTAssertNil(target.authorization)
    }

    func test_requestTarget_repeatedHeader_differentSpellings_answersNilValue() throws {
        let target = try XCTUnwrap(HTTPParser.requestTarget(inHeaderString: "POST /usage/v1/metrics HTTP/1.1\r\nauthorization: Bearer v\r\nX: y\r\nAuthorization: Bearer w"))
        XCTAssertNil(target.authorization)
    }

    func test_bodyLimit_usagePath_repeatedAuthorization_closureReceivesNil() {
        var received: [String?] = []
        let limit = HTTPParser.bodyLimit(
            forHeaderString: "POST /usage/v1/metrics HTTP/1.1\r\nauthorization: Bearer v\r\nAuthorization: Bearer v",
            isAuthorized: { _ in true },
            isUsageAuthorized: { received.append($0); return $0 != nil }
        )
        XCTAssertEqual(received, [nil])
        XCTAssertEqual(limit, 1024 * 1024)
    }

    func test_bodyLimit_calyxMCP_repeatedAuthorization_closureReceivesNil() {
        var received: [String?] = []
        let limit = HTTPParser.bodyLimit(
            forHeaderString: "POST /calyx-mcp HTTP/1.1\r\nAuthorization: Bearer s\r\nAuthorization: Bearer s",
            isAuthorized: { received.append($0); return $0 != nil },
            isUsageAuthorized: { _ in true }
        )
        XCTAssertEqual(received, [nil])
        XCTAssertEqual(limit, 1024 * 1024)
    }
}
