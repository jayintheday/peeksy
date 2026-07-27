import Foundation

/// Routing, as a pure function from a parsed request to response bytes.
///
/// THE FAIL-OPEN CONTRACT. `POST /v1/event/{source}` answers **204 No Content,
/// always** — for malformed JSON, for a payload with no `session_id`, for an
/// unknown `{source}`, for anything. The hook runs inside the agent's own
/// process tree on every `PreToolUse`; if it ever sees a non-2xx, `curl` starts
/// reporting failures and a user's coding session pays for our bug. Drops are
/// visible in `os.Logger` and nowhere else.
public struct EventRouter: Sendable {
    /// What `/v1/health` reports when nobody injects anything — the release
    /// name alone. The app injects `BuildInfo.short` instead, so a running
    /// daemon can be identified down to the commit; tests keep this stable
    /// default so they never depend on which commit they happen to run at.
    public static let defaultVersion = BuildInfo.fallbackVersion

    /// Hand a normalised envelope to the owner of the registry.
    public typealias Deliver = @Sendable (HookEnvelope) -> Void
    /// Current session count, for `/v1/health`.
    public typealias SessionCount = @Sendable () -> Int
    /// Resolve the `{source}` component of the route to an adapter.
    ///
    /// Injected so a test can register an agent the shipped app has never heard
    /// of. That injection IS the seam test: if adding an agent needed anything
    /// more than an `AgentSource` case and an adapter, this parameter would not
    /// be enough and the design would be wrong.
    public typealias AdapterLookup = @Sendable (String) -> (any AgentAdapter.Type)?

    private static let eventPrefix = "/v1/event/"

    private let clock: @Sendable () -> Date
    private let pid: Int32
    private let version: String
    private let deliver: Deliver
    private let sessionCount: SessionCount
    private let adapterLookup: AdapterLookup
    /// Off unless switched on. See `EventCapture`.
    private let capture: EventCapture?

    public init(
        clock: @escaping @Sendable () -> Date = { Date() },
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        adapterLookup: @escaping AdapterLookup = { AgentRegistry.adapter(forPathComponent: $0) },
        capture: EventCapture? = nil,
        version: String = EventRouter.defaultVersion,
        deliver: @escaping Deliver,
        sessionCount: @escaping SessionCount
    ) {
        self.clock = clock
        self.pid = pid
        self.version = version
        self.adapterLookup = adapterLookup
        self.capture = capture
        self.deliver = deliver
        self.sessionCount = sessionCount
    }

    /// Raw response bytes. Every response carries `Content-Length` and
    /// `Connection: close` — one request per connection, no keep-alive state to
    /// get wrong.
    public func respond(to request: HTTPParse.Request) -> Data {
        if request.method == "POST", request.path.hasPrefix(Self.eventPrefix) {
            let component = String(request.path.dropFirst(Self.eventPrefix.count))
            ingest(sourceComponent: component, body: request.body)
            return Self.response(status: 204, reason: "No Content", contentType: nil, body: Data())
        }

        if request.method == "GET", request.path == "/v1/health" {
            // Hand-built rather than JSONEncoder: four scalars, and a fixed key
            // order makes the response byte-comparable in tests.
            let json = #"{"ok":true,"version":"\#(version)","sessions":\#(sessionCount()),"pid":\#(pid)}"#
            return Self.response(
                status: 200,
                reason: "OK",
                contentType: "application/json",
                body: Data(json.utf8)
            )
        }

        return Self.response(
            status: 404,
            reason: "Not Found",
            contentType: "text/plain; charset=utf-8",
            body: Data("not found\n".utf8)
        )
    }

    // MARK: - Private

    private func ingest(sourceComponent: String, body: Data) {
        // FIRST, before anything can reject it. An event we drop — unknown
        // source, no session_id, malformed JSON — is the most interesting kind
        // of event to a capture, and the only place its shape is visible.
        capture?.record(source: sourceComponent, body: body, at: clock())

        guard let adapter = adapterLookup(sourceComponent) else {
            Log.ingest.error("dropped event: unknown source '\(sourceComponent, privacy: .public)'")
            return
        }
        guard let raw = RawPayload(body) else {
            Log.ingest.error("dropped event: body is not a JSON object (\(body.count) bytes)")
            return
        }
        guard let envelope = adapter.normalize(raw, now: clock()) else {
            Log.ingest.error("dropped event: \(adapter.source.rawValue, privacy: .public) payload has no usable session_id")
            return
        }
        deliver(envelope)
    }

    static func response(status: Int, reason: String, contentType: String?, body: Data) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"

        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    /// Framing-level failure (not a routing failure): the bytes were not a
    /// request we could parse at all, so there is nothing to fail open *about*.
    static func badRequest(reason: String) -> Data {
        response(
            status: 400,
            reason: "Bad Request",
            contentType: "text/plain; charset=utf-8",
            body: Data("\(reason)\n".utf8)
        )
    }
}
