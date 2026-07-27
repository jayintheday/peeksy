import Foundation
import Testing

@testable import AgentNotchCore

/// The row label rules, tested for the first time.
///
/// They used to live in `SliceRow.build` in the AppKit target, which `Tests/`
/// cannot import — so the duplicate-project rule, the owning-IDE suffix and the
/// no-cwd fallback chain were all shipped on inspection alone. Moving them to
/// Core was the precondition for changing them.
@Suite("SessionRowText")
struct SessionRowTextTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(
        id: String,
        cwd: String? = "/Users/v/Desktop/TestRepo/agent-notch",
        tty: String? = "ttys003",
        pid: Int32? = 501,
        toolSummary: String? = nil,
        permission: PendingPermission? = nil
    ) -> Session {
        Session(
            id: id, source: .claudeCode, cwd: cwd, tty: tty, pid: pid,
            state: .working, origin: .hook, updatedAt: now, createdAt: now,
            pendingPermission: permission, lastToolSummary: toolSummary)
    }

    private func build(
        _ sessions: [Session],
        titles: [String: String] = [:],
        owners: [Int32: String] = [:]
    ) -> [SessionRowText] {
        SessionRowTextBuilder.build(
            sessions: sessions,
            taskTitle: { titles[$0] },
            ownerName: { owners[$0] })
    }

    // MARK: - No title: today's behaviour, unchanged

    @Test("with no title the label is the project and the subtitle is the activity")
    func noTitleIsTheOldLayout() {
        let rows = build([session(id: "a", toolSummary: "Bash: npm test")])
        #expect(rows[0].title == "TestRepo/agent-notch")
        #expect(rows[0].subtitle == "Bash: npm test")
    }

    /// Both rows, never just the second — showing "agent-notch" twice is
    /// indistinguishable from a duplicate-row bug.
    @Test("two untitled sessions in one project BOTH get their tty")
    func duplicateProjectDisambiguatesBoth() {
        let rows = build([
            session(id: "a", tty: "ttys001", pid: 1),
            session(id: "b", tty: "ttys002", pid: 2),
        ])
        #expect(rows[0].title == "TestRepo/agent-notch · ttys001")
        #expect(rows[1].title == "TestRepo/agent-notch · ttys002")
    }

    @Test("a lone session in a project gets no tty suffix")
    func singleProjectIsNotDisambiguated() {
        #expect(build([session(id: "a")])[0].title == "TestRepo/agent-notch")
    }

    @Test("a real tty owned by something other than Terminal names the IDE")
    func ideOwnerIsAppended() {
        let rows = build([session(id: "a", pid: 42)], owners: [42: "Zed"])
        #expect(rows[0].title == "TestRepo/agent-notch · Zed")
    }

    @Test("no cwd and no tty falls back to the owning app, then to the source name")
    func fallbackChain() {
        let owned = build([session(id: "a", cwd: nil, tty: nil, pid: 42)], owners: [42: "Claude"])
        #expect(owned[0].title == "Claude")

        let unowned = build([session(id: "a", cwd: nil, tty: nil, pid: nil)])
        #expect(unowned[0].title == "Claude Code")
    }

    @Test("nothing to say on line two means no line two")
    func noSubtitleWhenNothingToSay() {
        #expect(build([session(id: "a")])[0].subtitle == nil)
    }

    // MARK: - Title present: the new ranking

    @Test("a title takes line one and the project moves to line two")
    func titleTakesLineOne() {
        let rows = build(
            [session(id: "a", toolSummary: "Read: orbs-demo.png")],
            titles: ["a": "Investigate orb animations for notch component"])
        #expect(rows[0].title == "Investigate orb animations for notch component")
        #expect(rows[0].subtitle == "TestRepo/agent-notch · Read: orbs-demo.png")
    }

    @Test("line two keeps the tty and the IDE as well as the activity")
    func subtitleCarriesEverything() {
        let rows = build(
            [session(id: "a", tty: "ttys001", pid: 1, toolSummary: "Bash: swift test"),
             session(id: "b", tty: "ttys002", pid: 2)],
            titles: ["a": "Fix the reaper"],
            owners: [1: "Cursor"])
        #expect(rows[0].title == "Fix the reaper")
        #expect(rows[0].subtitle == "TestRepo/agent-notch · ttys001 · Cursor · Bash: swift test")
        // The untitled sibling is unaffected.
        #expect(rows[1].title == "TestRepo/agent-notch · ttys002")
    }

    @Test("a titled row with no project and no activity still gets a subtitle")
    func titledRowWithMinimalContext() {
        let rows = build([session(id: "a", cwd: nil, tty: nil, pid: nil)],
                         titles: ["a": "Something"])
        #expect(rows[0].title == "Something")
        #expect(rows[0].subtitle == "Claude Code")
    }

    /// Three agents in one repo was the reported bug: three rows differing only
    /// by a tty number.
    @Test("three sessions in one repo become three distinct titles")
    func theReportedBug() {
        let rows = build(
            [session(id: "a", tty: "ttys000", pid: 1),
             session(id: "b", tty: "ttys002", pid: 2),
             session(id: "c", tty: "ttys003", pid: 3)],
            titles: [
                "a": "Fix notch app hiding other icons in idle state",
                "b": "Troubleshoot cursor agent window issue",
                "c": "Investigate orb animations for notch component",
            ])
        #expect(Set(rows.map(\.title)).count == 3)
        #expect(rows.allSatisfy { $0.subtitle?.hasPrefix("TestRepo/agent-notch · ttys") == true })
    }

    // MARK: - Precedence and hygiene

    @Test("a pending permission outranks the tool summary on line two")
    func permissionOutranksToolSummary() {
        let permission = PendingPermission(
            requestID: "r1", toolName: "Bash", summary: "Bash: rm -rf /tmp/x",
            detail: "Bash: rm -rf /tmp/x", receivedAt: now)
        let rows = build(
            [session(id: "a", toolSummary: "Read: file.swift", permission: permission)],
            titles: ["a": "Clean up"])
        #expect(rows[0].subtitle == "TestRepo/agent-notch · Bash: rm -rf /tmp/x")

        // …and with no title, exactly as before.
        let untitled = build([session(id: "a", toolSummary: "Read: f", permission: permission)])
        #expect(untitled[0].subtitle == "Bash: rm -rf /tmp/x")
    }

    @Test("an empty or whitespace-only title is treated as no title")
    func blankTitleIsIgnored() {
        #expect(build([session(id: "a")], titles: ["a": ""])[0].title == "TestRepo/agent-notch")
        #expect(build([session(id: "a")], titles: ["a": "   "])[0].title == "TestRepo/agent-notch")
    }

    @Test("row order is the order given — this never re-sorts")
    func preservesOrder() {
        let rows = build([session(id: "a", tty: "ttys001", pid: 1),
                          session(id: "b", tty: "ttys002", pid: 2)],
                         titles: ["a": "First", "b": "Second"])
        #expect(rows.map(\.title) == ["First", "Second"])
    }

    @Test("an empty snapshot builds no rows")
    func emptySnapshot() {
        #expect(build([]).isEmpty)
    }
}
