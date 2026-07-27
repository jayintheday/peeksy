import Foundation

/// Append every raw hook body to a JSONL file, for finding out what an agent
/// ACTUALLY sends.
///
/// This exists because `HookEnvelope.attentionNotifications` — the three strings
/// that decide whether the pill turns red — were written from an assumption
/// about Claude Code's wire format and have never been checked against a real
/// payload. A wrong value there fails exactly the way a right one looks when
/// nothing needs you, which is the worst failure mode this app has.
///
/// Three rules, all of them consequences of the fail-open contract:
///
///  * capture happens BEFORE routing, so events we drop — unknown source,
///    missing `session_id`, malformed JSON — are recorded too. Those are the
///    ones most worth seeing;
///  * every failure is swallowed. A full disk or a bad path must never turn
///    into a failed hook in somebody's coding session;
///  * it is off unless explicitly switched on, and bounded when it is on.
public final class EventCapture: @unchecked Sendable {

    /// Stop appending past this. A Bash-heavy day is tens of thousands of
    /// events; an unbounded debug file in a 24/7 app is a disk-filling bug
    /// waiting for the one week nobody looks.
    public static let defaultLimit = 8 * 1024 * 1024

    public let url: URL
    private let limitBytes: Int

    private let lock = NSLock()
    private var written: Int
    private var announcedLimit = false

    public init(url: URL, limitBytes: Int = EventCapture.defaultLimit) {
        self.url = url
        self.limitBytes = limitBytes
        let existing = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        self.written = existing.flatMap { $0 } ?? 0
    }

    /// `--capture <path>`, else `$AGENT_NOTCH_CAPTURE`, else off.
    ///
    /// argv first because the app is normally launched with `open`, which does
    /// not pass the shell's environment through — `open … --args --capture …`
    /// is the only reliable way to switch this on for a bundled app.
    public static func resolve(
        arguments: [String] = CommandLine.arguments,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> EventCapture? {
        if let index = arguments.firstIndex(of: "--capture"),
           index + 1 < arguments.count,
           !arguments[index + 1].hasPrefix("--") {
            return EventCapture(url: expand(arguments[index + 1]))
        }
        if let path = env["AGENT_NOTCH_CAPTURE"]?.trimmingCharacters(in: .whitespaces),
           !path.isEmpty {
            return EventCapture(url: expand(path))
        }
        return nil
    }

    private static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// One line per event. Never throws, never logs on the hot path.
    public func record(source: String, body: Data, at now: Date) {
        lock.lock()
        defer { lock.unlock() }

        guard written < limitBytes else {
            if !announcedLimit {
                announcedLimit = true
                Log.ingest.error("capture: \(self.limitBytes, privacy: .public) byte limit reached, stopping")
            }
            return
        }

        // The body is embedded as JSON when it is JSON, and as a string when it
        // is not — a malformed payload is a finding, not something to discard.
        let bodyField: Any = (try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]))
            ?? String(decoding: body, as: UTF8.self)

        let record: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: now),
            "source": source,
            "body": bodyField,
        ]
        guard let line = try? JSONSerialization.data(
            withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }

        var out = line
        out.append(0x0A)
        append(out)
        written += out.count
    }

    private func append(_ data: Data) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 0600: hook payloads carry cwds, prompts and tool arguments.
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        // Open per record rather than holding a handle: the rate is low, and a
        // handle held across a log rotation or a deleted file writes into
        // nothing for the rest of the process's life.
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
