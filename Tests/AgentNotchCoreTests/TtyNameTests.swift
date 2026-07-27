import Testing
@testable import AgentNotchCore

@Suite("normalizeTty")
struct TtyNameTests {
    @Test("nil in, nil out")
    func nilInput() {
        #expect(normalizeTty(nil) == nil)
    }

    @Test("already-bare names pass through")
    func bareName() {
        #expect(normalizeTty("ttys003") == "ttys003")
        #expect(normalizeTty("ttys000") == "ttys000")
        #expect(normalizeTty("ttys123") == "ttys123")
    }

    @Test("a leading /dev/ is stripped — that is the AppleScript form")
    func stripsDevPrefix() {
        #expect(normalizeTty("/dev/ttys003") == "ttys003")
        #expect(normalizeTty("/dev/ttys012") == "ttys012")
    }

    @Test("only a LEADING /dev/ is stripped, and only once")
    func stripsOnlyLeadingPrefix() {
        #expect(normalizeTty("/dev//dev/ttys003") == "/dev/ttys003")
        #expect(normalizeTty("ttys003/dev/") == "ttys003/dev/")
    }

    @Test("whitespace and newlines are trimmed", arguments: [
        "  ttys003", "ttys003  ", "  ttys003  ", "ttys003\n", "\tttys003\t",
        "  /dev/ttys003\n",
    ])
    func trimsWhitespace(_ input: String) {
        #expect(normalizeTty(input) == "ttys003")
    }

    @Test("sentinels for 'no controlling terminal' map to nil", arguments: [
        "", "??", "?", "-",
    ])
    func sentinels(_ input: String) {
        #expect(normalizeTty(input) == nil)
    }

    @Test("sentinels survive whitespace padding", arguments: [
        "  ", "\n", " ?? ", " ? ", "\t-\n",
    ])
    func paddedSentinels(_ input: String) {
        #expect(normalizeTty(input) == nil)
    }

    @Test("a /dev/-prefixed sentinel is still nil")
    func devPrefixedSentinel() {
        #expect(normalizeTty("/dev/") == nil)
        #expect(normalizeTty("/dev/??") == nil)
        #expect(normalizeTty("/dev/?") == nil)
    }

    @Test("normalization is idempotent")
    func idempotent() {
        let once = normalizeTty("/dev/ttys003")
        #expect(normalizeTty(once) == once)
    }
}
