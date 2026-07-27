import Foundation
import Testing

@testable import AgentNotchCore

@Suite("ToolSummary")
struct ToolSummaryTests {
    @Test("command wins over every other key")
    func prefersCommand() {
        let r = ToolSummary.describe(
            toolName: "Bash",
            input: ["command": "npm test", "file_path": "/a/b", "path": "/c", "url": "https://x"]
        )
        #expect(r.summary == "Bash: npm test")
    }

    @Test("the key preference order is command, file_path, path, url, then nothing")
    func keyPreferenceOrder() {
        #expect(ToolSummary.describe(toolName: "T", input: ["file_path": "/a", "path": "/c", "url": "u"]).summary == "T: /a")
        #expect(ToolSummary.describe(toolName: "T", input: ["path": "/c", "url": "u"]).summary == "T: /c")
        #expect(ToolSummary.describe(toolName: "T", input: ["url": "https://x.dev"]).summary == "T: https://x.dev")
        #expect(ToolSummary.describe(toolName: "T", input: ["other": "z"]).summary == "T")
        #expect(ToolSummary.describe(toolName: "T", input: nil).summary == "T")
        #expect(ToolSummary.describe(toolName: "T", input: [:]).summary == "T")
    }

    @Test("newlines are collapsed BEFORE truncation, so a heredoc cannot wreck the row")
    func collapsesNewlinesFirst() {
        let heredoc = """
            cat <<'EOF' > /tmp/x
            line one
            line two
            EOF
            """
        let r = ToolSummary.describe(toolName: "Bash", input: ["command": heredoc])

        #expect(!r.summary.contains("\n"))
        #expect(!r.detail.contains("\n"))
        #expect(r.detail == "Bash: cat <<'EOF' > /tmp/x line one line two EOF")
    }

    @Test("runs of whitespace and tabs collapse to a single space")
    func collapsesWhitespaceRuns() {
        let r = ToolSummary.describe(toolName: "Bash", input: ["command": "  npm\t\t run   \n  test  "])
        #expect(r.summary == "Bash: npm run test")
    }

    @Test("truncation lands on exactly 60 characters including the ellipsis")
    func truncatesToSixtyColumns() {
        let long = String(repeating: "x", count: 200)
        let r = ToolSummary.describe(toolName: "Bash", input: ["command": long])

        #expect(r.summary.count == 60)
        #expect(r.summary.hasSuffix("…"))
        #expect(r.summary.hasPrefix("Bash: xxx"))
    }

    @Test("the detail form is never truncated — that is what the tooltip is for")
    func detailIsUntruncated() {
        let long = String(repeating: "x", count: 200)
        let r = ToolSummary.describe(toolName: "Bash", input: ["command": long])

        #expect(r.detail.count == 206) // "Bash: " + 200
        #expect(!r.detail.hasSuffix("…"))
    }

    @Test("a value that lands exactly on the limit is left alone")
    func exactLimitIsNotTruncated() {
        let value = String(repeating: "y", count: 54) // "Bash: " is 6
        let r = ToolSummary.describe(toolName: "Bash", input: ["command": value])

        #expect(r.summary.count == 60)
        #expect(!r.summary.hasSuffix("…"))
        #expect(r.summary == r.detail)
    }

    @Test("one character over the limit truncates")
    func oneOverTruncates() {
        let value = String(repeating: "y", count: 55)
        let r = ToolSummary.describe(toolName: "Bash", input: ["command": value])

        #expect(r.summary.count == 60)
        #expect(r.summary.hasSuffix("…"))
    }

    @Test("a whitespace-only value falls through to the next key")
    func whitespaceOnlyValueIsIgnored() {
        let r = ToolSummary.describe(toolName: "Edit", input: ["command": "   \n  ", "file_path": "/a/b.swift"])
        #expect(r.summary == "Edit: /a/b.swift")
    }

    @Test("a non-string value is coerced when it can be, ignored when it cannot")
    func nonStringValues() {
        #expect(ToolSummary.describe(toolName: "T", input: ["path": 42]).summary == "T: 42")
        #expect(ToolSummary.describe(toolName: "T", input: ["path": ["a": 1]]).summary == "T")
    }

    @Test("collapse and truncate are exact")
    func primitives() {
        #expect(ToolSummary.collapse("") == "")
        #expect(ToolSummary.collapse("   ") == "")
        #expect(ToolSummary.collapse("a\n\n\nb") == "a b")
        #expect(ToolSummary.truncate("abc", to: 10) == "abc")
        #expect(ToolSummary.truncate("abcdef", to: 3) == "ab…")
        #expect(ToolSummary.truncate("abc", to: 0) == "")
    }

    @Test("multi-byte text truncates by character, not by byte")
    func unicodeSafeTruncation() {
        let r = ToolSummary.describe(toolName: "Bash", input: ["command": String(repeating: "é", count: 100)])
        #expect(r.summary.count == 60)
    }
}
