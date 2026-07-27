import Testing
@testable import PeeksyCore

@Suite("TCC error detection")
struct TccErrorTests {

    @Test("every marker matches when present verbatim", arguments: Tcc.markers)
    func markersMatch(_ marker: String) {
        #expect(Tcc.isTccError("osascript: \(marker) blah"))
    }

    @Test("matching is case-insensitive", arguments: Tcc.markers)
    func markersMatchUppercased(_ marker: String) {
        #expect(Tcc.isTccError("OSASCRIPT: \(marker.uppercased()) BLAH"))
    }

    @Test("the real -1743 stderr macOS emits")
    func realAutomationDenial() {
        let stderr = """
        execution error: Not authorized to send Apple events to Terminal. (-1743)
        """
        #expect(Tcc.isTccError(stderr))
    }

    @Test("Accessibility-flavoured denials also match")
    func accessibilityFlavoured() {
        #expect(Tcc.isTccError("execution error: assistive access is not enabled (-25211)"))
        #expect(Tcc.isTccError("osascript is not allowed assistive access. (-1719)"))
    }

    @Test("unrelated stderr does not match", arguments: [
        "",
        "execution error: Terminal got an error: Can't get window 1. (-1728)",
        "syntax error: Expected end of line but found identifier. (-2741)",
        "sh: osascript: command not found",
        "some totally unrelated failure",
    ])
    func unrelatedDoesNotMatch(_ stderr: String) {
        #expect(!Tcc.isTccError(stderr))
    }

    @Test("a numeric marker does not fire on an unrelated error code")
    func noFalsePositiveOnNearbyCodes() {
        #expect(!Tcc.isTccError("execution error: something failed (-1744)"))
        #expect(!Tcc.isTccError("execution error: something failed (1743)"))
    }

    @Test("the remedy names the exact System Settings path")
    func remedyText() {
        #expect(Tcc.remedy == "macOS blocked Peeksy from controlling Terminal. Enable it in System Settings → Privacy & Security → Automation → Peeksy → Terminal.")
    }
}
