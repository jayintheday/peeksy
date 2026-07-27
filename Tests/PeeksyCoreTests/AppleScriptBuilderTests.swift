import Testing
@testable import PeeksyCore

@Suite("AppleScript building")
struct AppleScriptBuilderTests {

    // MARK: - escapeAppleScript

    @Test("plain text is untouched")
    func plainText() {
        #expect(escapeAppleScript("ttys003") == "ttys003")
        #expect(escapeAppleScript("") == "")
    }

    @Test("double quotes are escaped")
    func escapesQuotes() {
        #expect(escapeAppleScript("a\"b") == "a\\\"b")
        #expect(escapeAppleScript("\"") == "\\\"")
    }

    @Test("backslashes are escaped")
    func escapesBackslashes() {
        #expect(escapeAppleScript("a\\b") == "a\\\\b")
        #expect(escapeAppleScript("\\") == "\\\\")
    }

    @Test("backslash is escaped BEFORE quote, so an escaped quote is not double-escaped")
    func escapeOrdering() {
        // Input: \"  → the backslash becomes \\ and the quote becomes \" ⇒ \\\"
        // Wrong ordering (quote first) would yield \\\\\" — a literal backslash
        // followed by a string terminator.
        #expect(escapeAppleScript("\\\"") == "\\\\\\\"")
    }

    // MARK: - buildFocusScript

    @Test("the script targets /dev/<tty>")
    func targetsDevPath() {
        let script = buildFocusScript(normalizedTty: "ttys003")
        #expect(script.contains("set targetTty to \"/dev/ttys003\""))
    }

    @Test("all three of frontmost / selected / activate are present")
    func allThreeMutations() {
        let script = buildFocusScript(normalizedTty: "ttys003")
        #expect(script.contains("set frontmost of w to true"))
        #expect(script.contains("set selected of t to true"))
        #expect(script.contains("activate"))
    }

    @Test("the script reports ok / notfound so callers can tell a stale tab from a denial")
    func reportsSentinels() {
        let script = buildFocusScript(normalizedTty: "ttys003")
        #expect(script.contains("return \"ok\""))
        #expect(script.contains("return \"notfound\""))
    }

    @Test("the script walks windows then tabs, addressed to Terminal")
    func structure() {
        let script = buildFocusScript(normalizedTty: "ttys003")
        #expect(script.contains("tell application \"Terminal\""))
        #expect(script.contains("repeat with w in windows"))
        #expect(script.contains("repeat with t in tabs of w"))
        #expect(script.contains("if (tty of t) is targetTty then"))
        #expect(script.contains("end tell"))
    }

    @Test("exact expected shape")
    func exactShape() {
        let expected = """
        tell application "Terminal"
          set targetTty to "/dev/ttys003"
          repeat with w in windows
            repeat with t in tabs of w
              if (tty of t) is targetTty then
                set frontmost of w to true
                set selected of t to true
                activate
                return "ok"
              end if
            end repeat
          end repeat
        end tell
        return "notfound"
        """
        #expect(buildFocusScript(normalizedTty: "ttys003") == expected)
    }

    @Test("a tty containing a quote cannot break out of the string literal")
    func quoteCannotEscapeLiteral() {
        let script = buildFocusScript(normalizedTty: "ttys003\" \nactivate\nset x to \"")
        // The injected quote is escaped, so the literal is not terminated early.
        #expect(script.contains("\\\""))
        #expect(!script.contains("set targetTty to \"/dev/ttys003\" \n"))
        // Exactly one assignment line — no smuggled statements at the top level.
        let assignments = script.components(separatedBy: "set targetTty to").count - 1
        #expect(assignments == 1)
    }

    @Test("a tty containing a backslash cannot escape the closing quote")
    func backslashCannotEscapeClosingQuote() {
        let script = buildFocusScript(normalizedTty: "ttys003\\")
        #expect(script.contains("set targetTty to \"/dev/ttys003\\\\\""))
    }
}
