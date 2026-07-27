import Foundation

/// Just enough HTTP/1.1 to accept a `curl --unix-socket` POST.
///
/// PURE and incremental: `parse` is a static function over a `Data` buffer with
/// no I/O and no state. The socket layer appends bytes and calls it again; when
/// it returns `.complete` the caller drops `consumed` bytes. That split is why
/// the entire request-framing layer — split headers, a body arriving in three
/// TCP segments, an over-cap payload — is testable with `Data` literals and no
/// sockets at all.
public struct HTTPParse {
    public struct Request: Sendable, Equatable {
        public let method: String
        /// Path only; any `?query` is stripped.
        public let path: String
        public let body: Data

        public init(method: String, path: String, body: Data) {
            self.method = method
            self.path = path
            self.body = body
        }
    }

    public enum Outcome: Sendable, Equatable {
        case needMore
        case complete(Request, consumed: Int)
        case malformed(reason: String)
    }

    /// A request line plus headers larger than this is not a mistake we should
    /// keep buffering for.
    public static let maxHeaderBytes = 32 * 1024

    private static let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // CRLF CRLF

    /// Parse one request from the front of `buffer`.
    ///
    /// - Parameter maxBody: hard cap on `Content-Length`. Over it is
    ///   `.malformed`, not `.needMore` — otherwise a bad `Content-Length` pins
    ///   memory until the peer gives up.
    public static func parse(_ buffer: Data, maxBody: Int = 1 << 20) -> Outcome {
        let base = buffer.startIndex

        guard let terminator = buffer.range(of: headerTerminator) else {
            if buffer.count > maxHeaderBytes {
                return .malformed(reason: "headers exceed \(maxHeaderBytes) bytes")
            }
            return .needMore
        }

        guard let headerText = String(data: Data(buffer[base..<terminator.lowerBound]), encoding: .utf8) else {
            return .malformed(reason: "headers are not valid UTF-8")
        }

        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return .malformed(reason: "bad request line: \(requestLine)")
        }
        let method = parts[0].uppercased()
        let target = String(parts[1])

        var contentLength = 0
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                return .malformed(reason: "bad header line: \(line)")
            }
            // Header names are case-insensitive per RFC 9110; curl sends
            // `Content-Length`, other clients send `content-length`.
            let name = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)

            switch name {
            case "content-length":
                guard let n = Int(value), n >= 0 else {
                    return .malformed(reason: "bad Content-Length: \(value)")
                }
                contentLength = n
            case "transfer-encoding":
                if value.lowercased().contains("chunked") {
                    return .malformed(reason: "chunked transfer-encoding is not supported")
                }
            default:
                break
            }
        }

        if contentLength > maxBody {
            return .malformed(reason: "body of \(contentLength) exceeds cap of \(maxBody)")
        }

        // No Content-Length means no body — NOT an error. `GET /v1/health`
        // arrives that way and has to parse.
        let bodyStart = terminator.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        if available < contentLength { return .needMore }

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = Data(buffer[bodyStart..<bodyEnd])
        let consumed = buffer.distance(from: base, to: bodyEnd)

        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        return .complete(Request(method: method, path: path, body: body), consumed: consumed)
    }
}
