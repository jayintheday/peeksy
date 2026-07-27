import Foundation
import Testing

@testable import AgentNotchCore

@Suite("UnifiedDiff")
struct UnifiedDiffTests {

    @Test("identical input produces no diff at all")
    func identical() {
        #expect(UnifiedDiff.between("a\nb\nc", "a\nb\nc").isEmpty)
        #expect(UnifiedDiff.between("", "").isEmpty)
    }

    @Test("a pure insertion shows only the inserted lines")
    func insertion() {
        let diff = UnifiedDiff.between("a\nb\nc", "a\nb\nX\nc")
        #expect(diff.contains("+X"))
        // Removal LINES, not the "---" header, which starts with a dash too.
        #expect(removals(in: diff).isEmpty)
        #expect(diff.contains(" a"))
        #expect(diff.contains(" c"))
    }

    private func removals(in diff: String) -> [Substring] {
        diff.split(separator: "\n").filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }
    }

    @Test("a deletion is marked and a replacement shows both sides")
    func deletionAndReplacement() {
        #expect(UnifiedDiff.between("a\nb\nc", "a\nc").contains("-b"))

        let replaced = UnifiedDiff.between("a\nb\nc", "a\nB\nc")
        #expect(replaced.contains("-b"))
        #expect(replaced.contains("+B"))
    }

    @Test("distant changes become separate hunks, adjacent ones merge")
    func hunking() {
        let before = (1...40).map(String.init).joined(separator: "\n")
        var after = (1...40).map(String.init)
        after[2] = "three"
        after[30] = "thirty-one"
        let diff = UnifiedDiff.between(before, after.joined(separator: "\n"))

        let headers = diff.split(separator: "\n").filter { $0.hasPrefix("@@") }
        #expect(headers.count == 2)
        // Untouched middle lines are not carried along.
        #expect(!diff.contains(" 20"))
    }

    @Test("context is clamped at the ends rather than running off them")
    func clampsContext() {
        let diff = UnifiedDiff.between("a\nb", "X\na\nb")
        #expect(diff.contains("+X"))
        #expect(diff.hasPrefix("--- before\n+++ after\n@@"))
    }

    @Test("everything-changed and empty-to-something both work")
    func edges() {
        #expect(UnifiedDiff.between("a", "b").contains("+b"))
        #expect(UnifiedDiff.between("", "a").contains("+a"))
        #expect(UnifiedDiff.between("a", "").contains("-a"))
    }

    @Test("a file past the line limit degrades to a summary instead of hanging")
    func tooLarge() {
        let huge = (0..<(UnifiedDiff.lineLimit + 1)).map(String.init).joined(separator: "\n")
        let diff = UnifiedDiff.between(huge, huge + "\nextra")
        #expect(diff.contains("too large"))
    }

    @Test("the labels name the file the user is about to change")
    func labels() {
        let diff = UnifiedDiff.between("a", "b", fromLabel: "settings.json (current)", toLabel: "settings.json (after)")
        #expect(diff.hasPrefix("--- settings.json (current)\n+++ settings.json (after)\n"))
    }
}
