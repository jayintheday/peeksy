import Foundation
import Testing

@testable import AgentNotchCore

@Suite("ProjectLabel")
struct ProjectLabelTests {
    @Test("nil in, nil out")
    func nilCWD() {
        #expect(ProjectLabel.projectKey(nil) == nil)
        #expect(ProjectLabel.display(nil) == nil)
        #expect(ProjectLabel.projectKey("") == nil)
        #expect(ProjectLabel.display("   ") == nil)
    }

    @Test("the key is the FULL path — basenames collide on a real machine")
    func keyIsFullPath() {
        // These four all live on the author's machine. Two pairs of them share
        // a basename or differ only by case; keying on the basename would merge
        // unrelated sessions into one row.
        let a = "/Users/vijay/Desktop/test-app/test-app-1"
        let b = "/Users/vijay/Desktop/snacksnap-master/project-snacksnap"
        let c = "/Users/vijay/Desktop/TestRepo"
        let d = "/Users/vijay/Desktop/Testrepo-Friendsofclaude"

        #expect(ProjectLabel.projectKey(a) == a)
        #expect(ProjectLabel.projectKey(b) == b)
        #expect(Set([a, b, c, d].compactMap(ProjectLabel.projectKey)).count == 4)
    }

    @Test("two projects that share a basename keep distinct keys")
    func siblingBasenamesDoNotCollide() {
        let one = ProjectLabel.projectKey("/Users/x/work/client-a/api")
        let two = ProjectLabel.projectKey("/Users/x/work/client-b/api")

        #expect(one != two)
    }

    @Test("display is the last two segments")
    func displayIsLastTwo() {
        #expect(ProjectLabel.display("/Users/vijay/Desktop/TestRepo/agent-notch") == "TestRepo/agent-notch")
        #expect(ProjectLabel.display("/a/b") == "a/b")
    }

    @Test("a single-segment path displays as that segment")
    func singleSegment() {
        #expect(ProjectLabel.display("/Users") == "Users")
        #expect(ProjectLabel.display("relative") == "relative")
    }

    @Test("root has no segments and degrades gracefully")
    func root() {
        #expect(ProjectLabel.projectKey("/") == "/")
        #expect(ProjectLabel.display("/") == "/")
    }

    @Test("trailing slashes are normalised away")
    func trailingSlashes() {
        #expect(ProjectLabel.projectKey("/a/b/") == "/a/b")
        #expect(ProjectLabel.projectKey("/a/b///") == "/a/b")
        #expect(ProjectLabel.display("/a/b/c/") == "b/c")
    }

    @Test("a deep path still shows exactly two segments")
    func deepPath() {
        #expect(ProjectLabel.display("/a/b/c/d/e/f/g/h") == "g/h")
    }

    @Test("surrounding whitespace is trimmed")
    func trimsWhitespace() {
        #expect(ProjectLabel.projectKey("  /a/b  ") == "/a/b")
        #expect(ProjectLabel.display("  /a/b  ") == "a/b")
    }

    @Test("Session exposes both forms")
    func sessionConvenience() {
        let s = Session(
            id: "s",
            source: .claudeCode,
            cwd: "/Users/vijay/Desktop/TestRepo/agent-notch",
            updatedAt: t0,
            createdAt: t0
        )

        #expect(s.projectDisplay == "TestRepo/agent-notch")
        #expect(s.projectKey == "/Users/vijay/Desktop/TestRepo/agent-notch")
    }
}
