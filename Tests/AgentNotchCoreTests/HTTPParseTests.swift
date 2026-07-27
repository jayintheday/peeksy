import Foundation
import Testing

@testable import AgentNotchCore

@Suite("HTTPParse")
struct HTTPParseTests {
    private func request(body: String, path: String = "/v1/event/claude-code", method: String = "POST") -> Data {
        Data(
            """
            \(method) \(path) HTTP/1.1\r
            Host: agent-notch\r
            Content-Type: application/json\r
            Content-Length: \(body.utf8.count)\r
            \r
            \(body)
            """.utf8)
    }

    @Test("a whole request in one buffer parses")
    func wholeRequest() throws {
        let bytes = request(body: #"{"session_id":"s"}"#)

        guard case .complete(let req, let consumed) = HTTPParse.parse(bytes) else {
            Issue.record("expected .complete")
            return
        }
        #expect(req.method == "POST")
        #expect(req.path == "/v1/event/claude-code")
        #expect(String(data: req.body, encoding: .utf8) == #"{"session_id":"s"}"#)
        #expect(consumed == bytes.count)
    }

    @Test("every prefix short of the whole request asks for more")
    func everyPrefixNeedsMore() {
        let bytes = request(body: #"{"a":1}"#)
        for cut in 1..<bytes.count {
            #expect(HTTPParse.parse(bytes.prefix(cut)) == .needMore, "prefix of \(cut) bytes")
        }
    }

    @Test("headers split across reads are reassembled")
    func splitHeaders() {
        let bytes = request(body: "{}")
        let headerEnd = bytes.range(of: Data("\r\n\r\n".utf8))!.upperBound

        #expect(HTTPParse.parse(bytes.prefix(10)) == .needMore)
        #expect(HTTPParse.parse(bytes.prefix(headerEnd - 3)) == .needMore) // mid-terminator
        #expect(HTTPParse.parse(bytes.prefix(headerEnd)) == .needMore) // headers done, body missing

        guard case .complete = HTTPParse.parse(bytes) else {
            Issue.record("expected .complete once the body lands")
            return
        }
    }

    @Test("a body split mid-stream completes when the rest arrives")
    func bodySplitMidStream() throws {
        let body = #"{"session_id":"abc","hook_event_name":"PreToolUse"}"#
        let bytes = request(body: body)
        let firstHalf = bytes.prefix(bytes.count - 12)

        #expect(HTTPParse.parse(firstHalf) == .needMore)

        guard case .complete(let req, _) = HTTPParse.parse(bytes) else {
            Issue.record("expected .complete")
            return
        }
        #expect(String(data: req.body, encoding: .utf8) == body)
    }

    @Test("no Content-Length means no body — GET /v1/health has to parse")
    func missingContentLength() throws {
        let bytes = Data("GET /v1/health HTTP/1.1\r\nHost: agent-notch\r\n\r\n".utf8)

        guard case .complete(let req, let consumed) = HTTPParse.parse(bytes) else {
            Issue.record("expected .complete")
            return
        }
        #expect(req.method == "GET")
        #expect(req.path == "/v1/health")
        #expect(req.body.isEmpty)
        #expect(consumed == bytes.count)
    }

    @Test("header names are matched case-insensitively")
    func caseInsensitiveHeaders() throws {
        let bytes = Data("POST /x HTTP/1.1\r\ncOnTeNt-LeNgTh: 2\r\n\r\nhi".utf8)

        guard case .complete(let req, _) = HTTPParse.parse(bytes) else {
            Issue.record("expected .complete")
            return
        }
        #expect(String(data: req.body, encoding: .utf8) == "hi")
    }

    @Test("a body over the cap is malformed, not merely incomplete")
    func overCap() {
        let bytes = Data("POST /x HTTP/1.1\r\nContent-Length: 5000\r\n\r\n".utf8)

        guard case .malformed(let reason) = HTTPParse.parse(bytes, maxBody: 100) else {
            Issue.record("expected .malformed")
            return
        }
        #expect(reason.contains("5000"))
        #expect(reason.contains("100"))
    }

    @Test("a non-numeric Content-Length is malformed")
    func badContentLength() {
        guard case .malformed = HTTPParse.parse(Data("POST /x HTTP/1.1\r\nContent-Length: banana\r\n\r\n".utf8)) else {
            Issue.record("expected .malformed")
            return
        }
    }

    @Test("a negative Content-Length is malformed")
    func negativeContentLength() {
        guard case .malformed = HTTPParse.parse(Data("POST /x HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)) else {
            Issue.record("expected .malformed")
            return
        }
    }

    @Test("a garbage request line is malformed")
    func badRequestLine() {
        guard case .malformed = HTTPParse.parse(Data("HELLO\r\n\r\n".utf8)) else {
            Issue.record("expected .malformed")
            return
        }
    }

    @Test("a header with no colon is malformed")
    func headerWithoutColon() {
        guard case .malformed = HTTPParse.parse(Data("POST /x HTTP/1.1\r\nnonsense\r\n\r\n".utf8)) else {
            Issue.record("expected .malformed")
            return
        }
    }

    @Test("chunked transfer-encoding is refused rather than silently mis-framed")
    func chunkedIsRefused() {
        guard case .malformed = HTTPParse.parse(
            Data("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        ) else {
            Issue.record("expected .malformed")
            return
        }
    }

    @Test("endless headers with no terminator eventually become malformed")
    func headerFlood() {
        var bytes = Data("POST /x HTTP/1.1\r\n".utf8)
        while bytes.count <= HTTPParse.maxHeaderBytes {
            bytes.append(Data("X-Pad: \(String(repeating: "p", count: 200))\r\n".utf8))
        }

        guard case .malformed = HTTPParse.parse(bytes) else {
            Issue.record("expected .malformed")
            return
        }
    }

    @Test("a query string is stripped from the path")
    func stripsQuery() throws {
        guard case .complete(let req, _) = HTTPParse.parse(Data("GET /v1/health?verbose=1 HTTP/1.1\r\n\r\n".utf8)) else {
            Issue.record("expected .complete")
            return
        }
        #expect(req.path == "/v1/health")
    }

    @Test("the method is upper-cased")
    func upperCasesMethod() throws {
        guard case .complete(let req, _) = HTTPParse.parse(Data("get /v1/health HTTP/1.1\r\n\r\n".utf8)) else {
            Issue.record("expected .complete")
            return
        }
        #expect(req.method == "GET")
    }

    @Test("a pipelined second request survives the caller dropping `consumed` bytes")
    func consumedIsExact() throws {
        var buffer = request(body: "{}")
        buffer.append(request(body: #"{"b":2}"#))

        guard case .complete(let first, let consumed) = HTTPParse.parse(buffer) else {
            Issue.record("expected .complete")
            return
        }
        #expect(String(data: first.body, encoding: .utf8) == "{}")

        // `dropFirst` leaves a slice with a NON-ZERO startIndex — exactly what a
        // caller draining a buffer produces, and the classic place a Data-index
        // bug hides.
        guard case .complete(let second, _) = HTTPParse.parse(buffer.dropFirst(consumed)) else {
            Issue.record("expected the second request to parse from a slice")
            return
        }
        #expect(String(data: second.body, encoding: .utf8) == #"{"b":2}"#)
    }

    @Test("an empty buffer just needs more")
    func emptyBuffer() {
        #expect(HTTPParse.parse(Data()) == .needMore)
    }

    @Test("a zero-length body is complete, not pending")
    func zeroLengthBody() throws {
        guard case .complete(let req, _) = HTTPParse.parse(
            Data("POST /v1/event/claude-code HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8)
        ) else {
            Issue.record("expected .complete")
            return
        }
        #expect(req.body.isEmpty)
    }
}
