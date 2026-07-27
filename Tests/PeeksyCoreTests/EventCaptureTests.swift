import Foundation
import Testing

@testable import PeeksyCore

private func scratch(_ name: String) -> URL {
    URL(fileURLWithPath: "/tmp")
        .appendingPathComponent("peeksy-capture-\(name)-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
}

@Suite("EventCapture")
struct EventCaptureTests {

    @Test("off unless explicitly switched on")
    func offByDefault() {
        #expect(EventCapture.resolve(arguments: [], env: [:]) == nil)
        #expect(EventCapture.resolve(arguments: ["Peeksy"], env: ["PEEKSY_CAPTURE": ""]) == nil)
        #expect(EventCapture.resolve(arguments: ["Peeksy"], env: ["PEEKSY_CAPTURE": "  "]) == nil)
    }

    @Test("argv beats the environment, because `open` does not pass the environment")
    func argvWins() throws {
        let capture = try #require(EventCapture.resolve(
            arguments: ["Peeksy", "--capture", "/tmp/from-argv.jsonl"],
            env: ["PEEKSY_CAPTURE": "/tmp/from-env.jsonl"]))
        #expect(capture.url.path == "/tmp/from-argv.jsonl")
    }

    @Test("the environment still works when argv is silent")
    func envFallback() throws {
        let capture = try #require(EventCapture.resolve(
            arguments: ["Peeksy"], env: ["PEEKSY_CAPTURE": "/tmp/from-env.jsonl"]))
        #expect(capture.url.path == "/tmp/from-env.jsonl")
    }

    @Test("--capture with no path is ignored rather than eating the next flag")
    func captureNeedsAPath() {
        #expect(EventCapture.resolve(arguments: ["Peeksy", "--capture", "--slice"], env: [:]) == nil)
        #expect(EventCapture.resolve(arguments: ["Peeksy", "--capture"], env: [:]) == nil)
    }

    @Test("each event is one JSON line carrying the body verbatim")
    func writesJSONL() throws {
        let url = scratch("write").appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let capture = EventCapture(url: url)

        capture.record(source: "claude-code",
                       body: Data(#"{"session_id":"a","hook_event_name":"Stop"}"#.utf8), at: t0)
        capture.record(source: "claude-code",
                       body: Data(#"{"session_id":"b","notification_type":"idle"}"#.utf8), at: t0)

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)

        let first = try #require(
            try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(first["source"] as? String == "claude-code")
        let body = try #require(first["body"] as? [String: Any])
        #expect(body["hook_event_name"] as? String == "Stop")
    }

    @Test("a body that is not JSON is kept as text, not dropped")
    func keepsMalformedBodies() throws {
        // A malformed payload is a FINDING. Discarding it would hide exactly the
        // kind of surprise this file exists to surface.
        let url = scratch("malformed").appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        EventCapture(url: url).record(source: "claude-code", body: Data("not json{".utf8), at: t0)

        let line = try String(contentsOf: url, encoding: .utf8)
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(parsed["body"] as? String == "not json{")
    }

    @Test("the file is created 0600 — payloads carry cwds, prompts and tool arguments")
    func fileIsPrivate() throws {
        let url = scratch("perms").appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        EventCapture(url: url).record(source: "x", body: Data("{}".utf8), at: t0)

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.uint16Value == 0o600)
    }

    @Test("writing stops at the size limit instead of filling the disk")
    func respectsLimit() throws {
        let url = scratch("limit").appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let capture = EventCapture(url: url, limitBytes: 200)

        for i in 0..<50 { capture.record(source: "s", body: Data(#"{"n":\#(i)}"#.utf8), at: t0) }

        let size = try #require(
            try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size < 400, "capture grew past its limit: \(size)")
        #expect(size > 0)
    }

    @Test("an unwritable path is silently ignored — never a failed hook")
    func failsOpen() {
        // The fail-open contract reaches all the way here: a debug feature must
        // not be able to break somebody's coding session.
        let capture = EventCapture(url: URL(fileURLWithPath: "/no-such-root/nope/events.jsonl"))
        capture.record(source: "x", body: Data("{}".utf8), at: t0)
        // Reaching this line without throwing or trapping IS the assertion.
        #expect(Bool(true))
    }
}

@Suite("CaptureReport")
struct CaptureReportTests {

    private func line(_ body: String) -> String {
        #"{"at":"2026-07-27T14:00:00Z","source":"claude-code","body":\#(body)}"#
    }

    @Test("counts events and sessions")
    func counts() {
        let report = CaptureReport.parse([
            line(#"{"session_id":"a","hook_event_name":"PreToolUse"}"#),
            line(#"{"session_id":"a","hook_event_name":"PostToolUse"}"#),
            line(#"{"session_id":"b","hook_event_name":"PreToolUse"}"#),
        ].joined(separator: "\n"))

        #expect(report.totalEvents == 3)
        #expect(report.distinctSessions == 2)
        #expect(report.eventNames.first?.value == "PreToolUse")
        #expect(report.eventNames.first?.count == 2)
    }

    @Test("a notification_type we ignore is reported as THE finding")
    func surfacesUnrecognisedAttention() {
        // The bug this whole feature exists to catch: a real value arrives, we
        // do not recognise it, and the pill silently never goes red.
        let report = CaptureReport.parse(
            line(#"{"session_id":"a","hook_event_name":"Notification","notification_type":"tool_use_permission"}"#),
            attention: ["permission_prompt", "idle_prompt", "agent_needs_input"])

        #expect(report.unrecognisedAttention.map(\.value) == ["tool_use_permission"])
        #expect(report.recognisedAttention.isEmpty)
        #expect(report.description.contains("should have gone red and did not"))
    }

    @Test("constants that never arrive are reported as dead")
    func surfacesDeadConstants() {
        let report = CaptureReport.parse(
            line(#"{"session_id":"a","hook_event_name":"Notification","notification_type":"idle_prompt"}"#),
            attention: ["idle_prompt", "permission_prompt"])

        #expect(report.recognisedAttention.map(\.value) == ["idle_prompt"])
        #expect(report.neverSeenAttention == ["permission_prompt"])
        #expect(report.description.contains("dead constant"))
    }

    @Test("a clean match says so plainly")
    func verdictWhenCorrect() {
        let report = CaptureReport.parse(
            line(#"{"session_id":"a","hook_event_name":"Notification","notification_type":"idle_prompt"}"#),
            attention: ["idle_prompt"])
        #expect(report.description.contains("matches what actually arrives"))
    }

    @Test("no notifications at all is called out rather than read as success")
    func verdictWhenSilent() {
        let report = CaptureReport.parse(
            line(#"{"session_id":"a","hook_event_name":"Stop"}"#), attention: ["idle_prompt"])
        #expect(!report.sawAnyNotification)
        #expect(report.description.contains("no Notification carried a notification_type"))
    }

    @Test("field presence shows which keys are actually populated")
    func fieldPresence() {
        let report = CaptureReport.parse([
            line(#"{"session_id":"a","hook_event_name":"PreToolUse","tool_name":"Bash"}"#),
            line(#"{"session_id":"b","hook_event_name":"Stop"}"#),
        ].joined(separator: "\n"))

        let fields = Dictionary(uniqueKeysWithValues: report.fieldPresence.map { ($0.value, $0.count) })
        #expect(fields["session_id"] == 2)
        #expect(fields["tool_name"] == 1)
    }

    @Test("junk lines are counted, not fatal")
    func tolerates_junk() {
        let report = CaptureReport.parse("not json\n" + line(#"{"session_id":"a"}"#) + "\n{}")
        #expect(report.totalEvents == 3)
        #expect(report.unparseable == 2)
        #expect(report.distinctSessions == 1)
    }

    @Test("an empty capture is empty, not a crash")
    func empty() {
        let report = CaptureReport.parse("")
        #expect(report.totalEvents == 0)
        #expect(!report.sawAnyNotification)
    }
}
