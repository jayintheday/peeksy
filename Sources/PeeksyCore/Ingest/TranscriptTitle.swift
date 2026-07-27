import Foundation

/// Claude Code's own one-line name for what a session is doing, lifted out of
/// the session transcript.
///
/// The agent writes `{"type":"ai-title","aiTitle":"…"}` into its transcript and
/// uses the same string as the Terminal tab title — so the notch can show what
/// the user already reads on their tabs, with no new wire format and no
/// Automation grant. `transcript_path` was already on the hook envelope and
/// already parsed; nothing read it until now.
///
/// Four facts, measured across all 1 881 transcripts on this machine, shape the
/// parser — every one of them counter-intuitive:
///
/// 1. The record is rewritten REPEATEDLY (up to 69 times in one file), and the
///    value genuinely CHANGES mid-session: 93 transcripts flip from a sentence
///    to a slug ("Debug Shield HLS playback with static pre-baked media" →
///    "shield-hls-playback-debug") and never flip back. So the LAST record wins
///    and the scan runs BACKWARDS — a forward scan would pin a title the tab bar
///    stopped showing hours ago.
/// 2. A single transcript line reaches 1.3 MB (an embedded tool result), so a
///    tail window can contain no complete line at all. A line is therefore
///    size-capped and string-matched BEFORE it ever reaches `JSONSerialization`.
/// 3. The last record sits up to 44.5 KB from EOF — in an 11 MB file, and 32 KB
///    in a 428 KB one. Distance does not track file size, so the window is sized
///    off the measured worst case and nothing else.
/// 4. 1 690 of 1 881 transcripts have NO record at all, and the first one lands
///    ~13 messages in. "No title" is the common case, not a failure.
public enum TranscriptTitle {
    /// How much of the file's tail to read.
    ///
    /// 5.7× the worst distance measured (44 544 bytes, in an 11 MB transcript).
    /// Decoding 256 KB is a fraction of a millisecond; being one byte short is a
    /// row that silently never gets a title, so the headroom is the cheap side
    /// of the trade.
    public static let tailBytes = 262_144

    /// A record is three keys and ~110 bytes. Anything larger carrying the
    /// marker is a tool result that happens to quote it — skip it rather than
    /// hand `JSONSerialization` a megabyte to reject.
    private static let maxRecordBytes = 4096

    /// Cheap pre-filter. Quoted, so it cannot match a bare word in prose, and it
    /// matches both spellings seen in the wild (`{"type":"ai-title"` compact and
    /// `{"type": "ai-title"` spaced).
    private static let marker = "\"ai-title\""
    private static let eventType = "ai-title"
    private static let titleKey = "aiTitle"

    /// The last task title in a slice of transcript, or `nil`.
    ///
    /// Deliberately does NOT try to drop a partial first line. A tail read
    /// usually starts mid-line, but a truncated JSON object cannot parse, so
    /// the validity check already rejects it — and skipping the discard means a
    /// file shorter than `tailBytes`, whose real first line may be the title,
    /// needs no special case.
    ///
    /// The `type` check is on the TOP-LEVEL object, which is what makes this
    /// safe against a transcript that merely quotes an `ai-title` line inside a
    /// tool result: there the top-level `type` is `user` or `assistant`.
    public static func parse(tail: String) -> String? {
        for line in tail.split(separator: "\n").reversed() {
            guard line.utf8.count <= maxRecordBytes, line.contains(marker) else { continue }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let fields = object as? [String: Any],
                  fields["type"] as? String == eventType,
                  let raw = fields[titleKey] as? String
            else { continue }

            // Same treatment `lastToolSummary` gets, for the same reason: one
            // row, ~60 columns, and no embedded newline may reach the layout.
            let collapsed = ToolSummary.collapse(raw)
            guard !collapsed.isEmpty else { continue }
            return ToolSummary.truncate(collapsed, to: ToolSummary.maxColumns)
        }
        return nil
    }
}

/// Reading the title off disk, with the file I/O behind an injectable closure.
///
/// Same split as `ProcessScanner`/`ProcessScan`: the parsing is pure and tested
/// against fixture strings, and only this thin shell touches the filesystem.
public struct TranscriptTitleReader: Sendable {
    /// `(path, maxBytes) -> tail`, or `nil` for any failure at all.
    public let readTail: @Sendable (_ path: String, _ maxBytes: Int) -> String?

    public init(readTail: @escaping @Sendable (_ path: String, _ maxBytes: Int) -> String?) {
        self.readTail = readTail
    }

    public func title(atPath path: String) -> String? {
        guard let tail = readTail(path, TranscriptTitle.tailBytes) else { return nil }
        return TranscriptTitle.parse(tail: tail)
    }

    /// Seek to `size - maxBytes` and read to EOF.
    ///
    /// Every failure — missing file, no permission, a directory, an empty file —
    /// is `nil`. A transcript the app cannot read is a row without a title, and
    /// never anything louder than that.
    public static let system = TranscriptTitleReader { path, maxBytes in
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            let window = UInt64(max(0, maxBytes))
            try handle.seek(toOffset: end > window ? end - window : 0)
            guard let data = try handle.readToEnd(), !data.isEmpty else { return nil }
            // Lossy on purpose: slicing at a byte offset lands mid-codepoint
            // roughly one time in four, and the replacement character in a
            // fragment we were going to reject anyway costs nothing.
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }
}
