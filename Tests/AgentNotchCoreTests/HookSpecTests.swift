import Foundation
import Testing

@testable import AgentNotchCore

/// `HookSpec.events` is the source of truth; `hooks/settings-snippet.json` is
/// the copy a human reads and pastes. Two sources of truth for the same nine
/// registrations is exactly how a matcher ends up on `Notification` in one of
/// them and not the other, so they are pinned to each other here.
@Suite("HookSpec ↔ settings-snippet.json")
struct HookSpecTests {

    /// The repo root, derived from this file's own path — no bundle resources,
    /// no working-directory assumption.
    private static var snippetURL: URL {
        URL(fileURLWithPath: #filePath)          // Tests/AgentNotchCoreTests/HookSpecTests.swift
            .deletingLastPathComponent()          // Tests/AgentNotchCoreTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // <repo>
            .appendingPathComponent("hooks/settings-snippet.json")
    }

    @Test("the snippet registers exactly the nine events, with exactly the same matchers")
    func snippetMatchesSpec() throws {
        let data = try Data(contentsOf: Self.snippetURL)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(root[HookSpec.hooksKey] as? [String: Any])

        #expect(Set(hooks.keys) == Set(HookSpec.events.map(\.event)))

        for spec in HookSpec.events {
            let groups = try #require(hooks[spec.event] as? [Any])
            #expect(groups.count == 1, "\(spec.event) should carry exactly one group")
            let group = try #require(groups[0] as? [String: Any])

            #expect(HookSpec.matcher(of: group) == spec.matcher,
                    "\(spec.event): snippet says \(String(describing: HookSpec.matcher(of: group))), spec says \(String(describing: spec.matcher))")

            // Presence of the key, not just its value: `"matcher": null` and no
            // matcher key are different JSON and only one of them is right.
            #expect((group[HookSpec.matcherKey] != nil) == (spec.matcher != nil))

            let entries = try #require(group[HookSpec.hooksKey] as? [Any])
            #expect(entries.count == 1)
            let entry = try #require(entries[0] as? [String: Any])
            #expect(entry[HookSpec.typeKey] as? String == HookSpec.commandType)
            #expect((entry[HookSpec.commandKey] as? String)?.hasSuffix("agent-notch-hook.sh") == true)
        }
    }

    @Test("the five lifecycle events take no matcher and the four tool events take \"*\"")
    func matchersAreWhatTheyLook() {
        let byEvent = Dictionary(uniqueKeysWithValues: HookSpec.events.map { ($0.event, $0.matcher) })
        #expect(byEvent["SessionStart"] == .some(nil))
        #expect(byEvent["SessionEnd"] == .some(nil))
        #expect(byEvent["UserPromptSubmit"] == .some(nil))
        #expect(byEvent["Stop"] == .some(nil))
        // The one that costs the app its highest-value signal if it is wrong.
        #expect(byEvent["Notification"] == .some(nil))
        #expect(byEvent["PreToolUse"] == "*")
        #expect(byEvent["PostToolUse"] == "*")
        #expect(byEvent["PostToolUseFailure"] == "*")
        #expect(byEvent["PermissionRequest"] == "*")
        #expect(HookSpec.events.count == 9)
    }

    @Test("group() omits the matcher key entirely rather than writing null")
    func groupOmitsAbsentMatcher() {
        let none = HookSpec.group(command: "/x", matcher: nil)
        #expect(none[HookSpec.matcherKey] == nil)
        #expect(none.keys.sorted() == ["hooks"])

        let star = HookSpec.group(command: "/x", matcher: "*")
        #expect(star[HookSpec.matcherKey] as? String == "*")
        #expect(star.keys.sorted() == ["hooks", "matcher"])
    }
}
