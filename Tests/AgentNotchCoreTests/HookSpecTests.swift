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

    // MARK: - snippet()

    /// What `--print-hook-json` emits. The flag used to print the MERGED file,
    /// which is a privacy problem rather than a correctness one: the documented
    /// use is "paste it in yourself", the universal support request is "run this
    /// and paste the output", and a real settings.json carries every other tool
    /// the user has hooked up. These pin it to our block and nothing else.

    @Test("snippet() is our nine registrations and nothing else")
    func snippetIsOnlyOurBlock() throws {
        let snippet = HookSpec.snippet(command: "/x/agent-notch-hook.sh")

        // Exactly one top-level key. A second one would mean settings leaked in.
        #expect(snippet.keys.sorted() == [HookSpec.hooksKey])

        let hooks = try #require(snippet[HookSpec.hooksKey] as? [String: Any])
        #expect(Set(hooks.keys) == Set(HookSpec.events.map(\.event)))

        for spec in HookSpec.events {
            let groups = try #require(hooks[spec.event] as? [Any])
            #expect(groups.count == 1, "\(spec.event) should carry exactly one group — ours")
            let group = try #require(groups[0] as? [String: Any])
            #expect(HookSpec.matcher(of: group) == spec.matcher)
            #expect((group[HookSpec.matcherKey] != nil) == (spec.matcher != nil))
        }
    }

    @Test("snippet() carries the command verbatim, shell quoting and all")
    func snippetCarriesTheCommand() throws {
        let quoted = HookSpec.shellQuoted("/Users/x/Library/Application Support/AgentNotch/agent-notch-hook.sh")
        #expect(quoted.hasPrefix("'"), "a path with a space must arrive quoted or this test proves nothing")

        let hooks = try #require(
            HookSpec.snippet(command: quoted)[HookSpec.hooksKey] as? [String: Any])
        for spec in HookSpec.events {
            let group = try #require((hooks[spec.event] as? [Any])?.first as? [String: Any])
            let entry = try #require((group[HookSpec.hooksKey] as? [Any])?.first as? [String: Any])
            #expect(entry[HookSpec.commandKey] as? String == quoted)
            #expect(entry[HookSpec.typeKey] as? String == HookSpec.commandType)
        }
    }

    /// The regression that matters. Nothing about a user's existing settings can
    /// reach this output, because the output is not derived from it at all.
    @Test("snippet() leaks nothing from a populated settings file")
    func snippetLeaksNothing() throws {
        let text = try SettingsIO.canonicalText(
            HookSpec.snippet(command: SettingsFixture.ourCommand))

        // Two other tools' hook commands, and the top-level keys and events that
        // belong to nobody but the user.
        for secret in [
            SettingsFixture.toolOne,
            SettingsFixture.toolTwo,
            "\"model\"",
            "\"permissions\"",
            "SubagentStop",
            "PreCompact",
        ] {
            #expect(!text.contains(secret), "--print-hook-json emitted \(secret)")
        }

        // And it really is small: 9 events, one group each, nothing else.
        #expect(text.components(separatedBy: HookSpec.scriptName).count - 1 == 9)
    }

    @Test("snippet() and settings-snippet.json are the same document")
    func snippetMatchesTheCommittedFile() throws {
        // The placeholder the committed file ships with.
        let placeholder = "/PATH/TO/agent-notch-hook.sh"
        let fromFile = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: Self.snippetURL))
                as? [String: Any])

        #expect(
            try SettingsIO.canonicalText(fromFile)
                == SettingsIO.canonicalText(HookSpec.snippet(command: placeholder)),
            "hooks/settings-snippet.json has drifted from HookSpec.snippet()")
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
