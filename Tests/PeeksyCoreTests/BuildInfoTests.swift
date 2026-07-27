import Foundation
import Testing

@testable import PeeksyCore

/// `CFBundleShortVersionString` is the release NAME. These cover the other
/// question — which build am I actually looking at — including the case this
/// app gets wrong most often, a bundle built over an uncommitted working tree.
@Suite("BuildInfo")
struct BuildInfoTests {

    private func plist(
        version: Any? = "0.1.0", commit: Any? = nil, dirty: Any? = nil, builtAt: Any? = nil
    ) -> [String: Any] {
        var info: [String: Any] = [:]
        if let version { info[BuildInfo.Key.marketingVersion] = version }
        if let commit { info[BuildInfo.Key.commit] = commit }
        if let dirty { info[BuildInfo.Key.dirty] = dirty }
        if let builtAt { info[BuildInfo.Key.builtAt] = builtAt }
        return info
    }

    // MARK: Unstamped

    @Test("no Info.plist at all is a dev build, not an error")
    func noPlist() {
        let info = BuildInfo.from(infoDictionary: nil)
        #expect(info == .unstamped)
        #expect(info.commit == nil)
        #expect(info.short == "0.1.0+dev")
        #expect(info.summary.contains("dev build"))
    }

    /// `swift run` and the test target both have a bundle with a version and no
    /// stamp. Claiming a commit there would be a lie.
    @Test("a plist with a version but no stamp reports dev, not a false commit")
    func versionWithoutStamp() {
        let info = BuildInfo.from(infoDictionary: plist(version: "2.5.0"))
        #expect(info.marketingVersion == "2.5.0")
        #expect(info.commit == nil)
        #expect(info.dirty == false)
        #expect(info.short == "2.5.0+dev")
    }

    @Test("an empty commit string is the same as no commit")
    func emptyCommitIsNoCommit() {
        // Exactly what build_app.sh writes outside a git checkout: the key is
        // present, its value is "".
        #expect(BuildInfo.from(infoDictionary: plist(commit: "")).commit == nil)
        #expect(BuildInfo.from(infoDictionary: plist(commit: "   ")).commit == nil)
    }

    @Test("a missing or empty version falls back rather than reporting nothing")
    func versionFallback() {
        #expect(BuildInfo.from(infoDictionary: plist(version: nil)).marketingVersion == "0.1.0")
        #expect(BuildInfo.from(infoDictionary: plist(version: "")).marketingVersion == "0.1.0")
        #expect(BuildInfo.from(infoDictionary: plist(version: 42)).marketingVersion == "0.1.0")
    }

    // MARK: Stamped

    @Test("a clean stamped build reports version and commit")
    func cleanBuild() {
        let info = BuildInfo.from(
            infoDictionary: plist(commit: "dcb9111", dirty: "false", builtAt: "2026-07-27 18:33"))
        #expect(info.commit == "dcb9111")
        #expect(info.dirty == false)
        #expect(info.short == "0.1.0+dcb9111")
        #expect(info.summary == "0.1.0 (dcb9111, built 2026-07-27 18:33)")
    }

    /// The one that matters day to day: this project is habitually built from
    /// an uncommitted tree, so a commit alone is only half an answer.
    @Test("a dirty build says so in both the short form and the summary")
    func dirtyBuild() {
        let info = BuildInfo.from(
            infoDictionary: plist(commit: "dcb9111", dirty: "true", builtAt: "2026-07-27 18:33"))
        #expect(info.dirty)
        #expect(info.short == "0.1.0+dcb9111.dirty")
        #expect(info.summary.contains("uncommitted"))
    }

    /// The script writes strings — a plist written by `cat` has no real
    /// booleans — but a plist editor writes `<true/>`. Both must read the same.
    @Test("dirty accepts the string the script writes and the bool an editor writes")
    func dirtyAcceptsBothSpellings() {
        for truthy in ["true", "TRUE", "yes", "1"] as [Any] {
            #expect(BuildInfo.from(infoDictionary: plist(commit: "a", dirty: truthy)).dirty,
                    "\(truthy) should read as dirty")
        }
        for falsy in ["false", "no", "0", ""] as [Any] {
            #expect(!BuildInfo.from(infoDictionary: plist(commit: "a", dirty: falsy)).dirty,
                    "\(falsy) should read as clean")
        }
        #expect(BuildInfo.from(infoDictionary: plist(commit: "a", dirty: true)).dirty)
        #expect(!BuildInfo.from(infoDictionary: plist(commit: "a", dirty: false)).dirty)
    }

    @Test("a stamp with no build date still reports the commit")
    func noDate() {
        let info = BuildInfo.from(infoDictionary: plist(commit: "abc1234", dirty: "false"))
        #expect(info.summary == "0.1.0 (abc1234)")
    }

    // MARK: The health endpoint

    @Test("health reports the injected build, and the plain version when nobody injects")
    func healthReportsTheInjectedVersion() {
        let stamped = BuildInfo.from(infoDictionary: plist(commit: "dcb9111", dirty: "true"))

        let injected = EventRouter(
            pid: 4242, version: stamped.short, deliver: { _ in }, sessionCount: { 3 })
        let response = String(decoding: injected.respond(
            to: HTTPParse.Request(method: "GET", path: "/v1/health", body: Data())),
            as: UTF8.self)
        #expect(response.contains(#""version":"0.1.0+dcb9111.dirty""#))

        // Default: tests must never depend on the commit they happen to run at.
        let plain = EventRouter(pid: 4242, deliver: { _ in }, sessionCount: { 3 })
        let plainResponse = String(decoding: plain.respond(
            to: HTTPParse.Request(method: "GET", path: "/v1/health", body: Data())),
            as: UTF8.self)
        #expect(plainResponse.contains(#""version":"0.1.0""#))
    }
}
