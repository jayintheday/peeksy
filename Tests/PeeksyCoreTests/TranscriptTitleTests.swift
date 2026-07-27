import Foundation
import Testing

@testable import PeeksyCore

/// Fixtures here are shaped from real transcripts under `~/.claude/projects/`.
/// The measured facts they encode — quoted in `TranscriptTitle`'s doc comment —
/// came from all 1 881 transcripts on the machine this was written on.
@Suite("TranscriptTitle")
struct TranscriptTitleTests {
    /// A record exactly as Claude Code writes it.
    private func record(_ title: String, session: String = "s1") -> String {
        #"{"type":"ai-title","aiTitle":"\#(title)","sessionId":"\#(session)"}"#
    }

    private let userLine =
        #"{"type":"user","message":{"role":"user","content":"hello"},"sessionId":"s1"}"#

    @Test("the compact spelling Claude Code actually writes")
    func parsesCompactSpelling() {
        let tail = [userLine, record("Investigate orb animations for notch component")]
            .joined(separator: "\n")
        #expect(TranscriptTitle.parse(tail: tail) == "Investigate orb animations for notch component")
    }

    @Test("the spaced spelling parses too — the JSON is parsed, never byte-matched")
    func parsesSpacedSpelling() {
        let tail = #"{"type": "ai-title", "aiTitle": "Label sessions launched within IDE"}"#
        #expect(TranscriptTitle.parse(tail: tail) == "Label sessions launched within IDE")
    }

    /// The rule that makes the backwards scan correctness rather than a tie-break.
    /// 93 of 1 881 real transcripts flip from a sentence to a slug and never flip
    /// back; a forward scan would pin a title the tab bar stopped showing.
    @Test("the LAST record wins when the title changed mid-session")
    func lastRecordWins() {
        let tail = [
            record("Debug Shield HLS playback with static pre-baked media"),
            userLine,
            record("Debug Shield HLS playback with static pre-baked media"),
            userLine,
            record("shield-hls-playback-debug"),
            userLine,
        ].joined(separator: "\n")
        #expect(TranscriptTitle.parse(tail: tail) == "shield-hls-playback-debug")
    }

    @Test("a partial first line is rejected by JSON validity, not by discarding it")
    func partialFirstLineIsHarmless() {
        // What a tail read starting mid-line actually looks like.
        let tail = ["sult\":\"…truncated garbage\",\"aiTitle\":\"ghost\"}",
                    record("Real title")].joined(separator: "\n")
        #expect(TranscriptTitle.parse(tail: tail) == "Real title")
    }

    /// The corollary of not discarding line one: a file shorter than the window
    /// needs no special case, because its first line really is a whole line.
    @Test("a record on line 1 is found — the whole-file case")
    func recordOnFirstLine() {
        #expect(TranscriptTitle.parse(tail: record("Only line")) == "Only line")
    }

    @Test("no record at all is nil, not an error — 1690 of 1881 transcripts")
    func noRecordYet() {
        let tail = [userLine, userLine].joined(separator: "\n")
        #expect(TranscriptTitle.parse(tail: tail) == nil)
    }

    @Test("empty and whitespace-only input")
    func emptyInput() {
        #expect(TranscriptTitle.parse(tail: "") == nil)
        #expect(TranscriptTitle.parse(tail: "\n\n\n") == nil)
    }

    @Test("a malformed record is skipped and an earlier valid one still wins")
    func malformedRecordFallsBack() {
        let tail = [record("Good title"),
                    #"{"type":"ai-title","aiTitle":"broken"#].joined(separator: "\n")
        #expect(TranscriptTitle.parse(tail: tail) == "Good title")
    }

    /// The real defence against a transcript that DISCUSSES this feature. The
    /// session that designed it has 17 lines mentioning `ai-title` and only 7
    /// records; the top-level `type` check is what tells them apart.
    @Test("a nested ai-title is not a record — the type check is top-level")
    func nestedTypeIsNotARecord() {
        let quoted =
            #"{"type":"assistant","message":{"content":[{"type":"ai-title","aiTitle":"nope"}]}}"#
        #expect(TranscriptTitle.parse(tail: quoted) == nil)
        // And it does not shadow a real record further back.
        #expect(TranscriptTitle.parse(tail: [record("Real"), quoted].joined(separator: "\n")) == "Real")
    }

    @Test("a wrong top-level type is not a record")
    func wrongTopLevelType() {
        #expect(TranscriptTitle.parse(tail: #"{"type":"summary","aiTitle":"nope"}"#) == nil)
    }

    @Test("a missing, empty, or non-string aiTitle is nil")
    func unusableTitleValue() {
        #expect(TranscriptTitle.parse(tail: #"{"type":"ai-title","sessionId":"s"}"#) == nil)
        #expect(TranscriptTitle.parse(tail: #"{"type":"ai-title","aiTitle":""}"#) == nil)
        #expect(TranscriptTitle.parse(tail: #"{"type":"ai-title","aiTitle":"   "}"#) == nil)
        #expect(TranscriptTitle.parse(tail: #"{"type":"ai-title","aiTitle":42}"#) == nil)
        #expect(TranscriptTitle.parse(tail: #"{"type":"ai-title","aiTitle":{"a":1}}"#) == nil)
    }

    /// A single real transcript line reaches 1.3 MB. Handing that to
    /// `JSONSerialization` on every read is the cost the cap avoids.
    @Test("an oversized line carrying the marker is skipped without being parsed")
    func oversizedLineIsSkipped() {
        let padding = String(repeating: "x", count: 8000)
        let bloated = #"{"type":"ai-title","aiTitle":"from a tool result \#(padding)"}"#
        #expect(bloated.utf8.count > 4096)
        #expect(TranscriptTitle.parse(tail: bloated) == nil)
        // …and it does not hide a legitimate record behind it.
        #expect(TranscriptTitle.parse(tail: [record("Real"), bloated].joined(separator: "\n")) == "Real")
    }

    @Test("a title is collapsed and truncated like any other row text")
    func collapsedAndTruncated() {
        let messy = record("Investigate   orb\\nanimations")
        #expect(TranscriptTitle.parse(tail: messy) == "Investigate orb animations")

        let long = String(repeating: "ab", count: 80)
        let title = TranscriptTitle.parse(tail: record(long))
        #expect(title?.count == ToolSummary.maxColumns)
        #expect(title?.hasSuffix("…") == true)
    }

    @Test("a stray carriage return does not reject a record")
    func toleratesCRLF() {
        let tail = record("Windows line ending") + "\r"
        #expect(TranscriptTitle.parse(tail: tail) == "Windows line ending")
    }

    @Test("the tail window is sized off the measured worst case, not a round number")
    func windowClearsTheWorstMeasuredDistance() {
        // 44 544 bytes was the worst distance from EOF to the last record across
        // 1 881 transcripts. Shrinking this constant silently drops titles.
        #expect(TranscriptTitle.tailBytes >= 44_544 * 2)
    }
}

@Suite("TranscriptTitleReader")
struct TranscriptTitleReaderTests {
    @Test("the seam is asked for tailBytes, and its answer is parsed")
    func readsThroughTheSeam() {
        let captured = Locked<(String, Int)?>(nil)
        let reader = TranscriptTitleReader { path, maxBytes in
            captured.set((path, maxBytes))
            return #"{"type":"ai-title","aiTitle":"From the seam"}"#
        }
        #expect(reader.title(atPath: "/tmp/x.jsonl") == "From the seam")
        #expect(captured.get()?.0 == "/tmp/x.jsonl")
        #expect(captured.get()?.1 == TranscriptTitle.tailBytes)
    }

    @Test("an unreadable file is nil, never a crash")
    func unreadableIsNil() {
        let reader = TranscriptTitleReader { _, _ in nil }
        #expect(reader.title(atPath: "/nope") == nil)
    }

    @Test("the system reader finds the LAST record in a real file on disk")
    func systemReaderOnDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeksy-title-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        // Bigger than the tail window, so this also exercises the seek: the
        // first record must fall outside it and the last must be found.
        let filler = #"{"type":"user","message":"\#(String(repeating: "p", count: 2000))"}"#
        var lines = [#"{"type":"ai-title","aiTitle":"stale, way back at the top"}"#]
        lines += Array(repeating: filler, count: 200)
        lines.append(#"{"type":"ai-title","aiTitle":"Current task"}"#)
        lines.append(filler)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        #expect(TranscriptTitleReader.system.title(atPath: url.path) == "Current task")
    }

    @Test("a missing path, a directory, and an empty file are all nil")
    func systemReaderFailuresAreQuiet() throws {
        #expect(TranscriptTitleReader.system.title(atPath: "/does/not/exist.jsonl") == nil)
        #expect(TranscriptTitleReader.system.title(atPath: NSTemporaryDirectory()) == nil)

        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeksy-empty-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: empty) }
        try Data().write(to: empty)
        #expect(TranscriptTitleReader.system.title(atPath: empty.path) == nil)
    }
}

/// Minimal box so a `@Sendable` stub can record what it was asked.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
