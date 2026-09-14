import Foundation
import Testing
@testable import PeeksyCore

/// Codex records hook trust in `config.toml`, keyed by our entry's coordinates
/// in `hooks.json`. These fixtures reproduce the real file's shape — a bundled
/// plugin's record beside ours, the bare `[hooks.state]` parent header, records
/// with and without `enabled` — because the one real mistake here would be
/// reading somebody else's record as ours.
@Suite("Codex hook trust")
struct CodexHookTrustTests {
    private let settingsPath = "/Users/example/.codex/hooks.json"
    private let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                          "PermissionRequest", "Stop", "Interrupt", "SessionEnd"]
    private var allAtZero: [String: SettingsMerge.Position] {
        Dictionary(uniqueKeysWithValues: events.map { ($0, SettingsMerge.Position(group: 0, hook: 0)) })
    }

    /// Exactly what Codex 0.154.0 wrote after trusting the eight hooks in
    /// `/hooks`: no `enabled` key on ours, `enabled = true` on the plugin's.
    private func trustedConfig(without missing: Set<String> = []) -> String {
        var toml = """
        model = "gpt-5.6-luna"

        [features]
        js_repl = false

        [hooks.state]

        [hooks.state."browser@openai-bundled:plugin.json#hooks[0]:stop:0:0"]
        trusted_hash = "sha256:317a07045dfc95aef2e80c55428a2f817e2768be867e3b1ef29a73da8636ae7f"
        enabled = true

        """
        for event in events where !missing.contains(event) {
            toml += """
            [hooks.state."\(settingsPath):\(CodexHookTrust.snakeCase(event)):0:0"]
            trusted_hash = "sha256:\(String(repeating: "a", count: 64))"

            """
        }
        return toml
    }

    @Test("Event names are keyed in snake_case, as Codex spells them")
    func snakeCase() {
        #expect(CodexHookTrust.snakeCase("SessionStart") == "session_start")
        #expect(CodexHookTrust.snakeCase("UserPromptSubmit") == "user_prompt_submit")
        #expect(CodexHookTrust.snakeCase("PreToolUse") == "pre_tool_use")
        #expect(CodexHookTrust.snakeCase("PermissionRequest") == "permission_request")
        #expect(CodexHookTrust.snakeCase("Stop") == "stop")
        #expect(CodexHookTrust.snakeCase("Interrupt") == "interrupt")
    }

    @Test("The state key is path, snake-case event and our coordinates")
    func stateKey() {
        let key = CodexHookTrust.stateKey(settingsPath: settingsPath, event: "PreToolUse",
                                          position: SettingsMerge.Position(group: 2, hook: 1))
        #expect(key == "/Users/example/.codex/hooks.json:pre_tool_use:2:1")
    }

    @Test("Eight records → 8/8 trusted, and the plugin's record is not counted as ours")
    func fullyTrusted() {
        let report = CodexHookTrust.audit(configTOML: trustedConfig(), settingsPath: settingsPath,
                                          events: events, positions: allAtZero)
        #expect(report.isFullyTrusted)
        #expect(report.entries.map(\.event) == events)
        #expect(report.summary == "8/8 trusted by Codex")
    }

    @Test("No records at all → 0/8 and a pointer at /hooks")
    func untrusted() {
        let toml = """
        [hooks.state]

        [hooks.state."browser@openai-bundled:plugin.json#hooks[0]:stop:0:0"]
        trusted_hash = "sha256:317a"
        enabled = true
        """
        let report = CodexHookTrust.audit(configTOML: toml, settingsPath: settingsPath,
                                          events: events, positions: allAtZero)
        #expect(report.trusted.isEmpty)
        #expect(report.untrusted == events)
        #expect(report.summary == "0/8 trusted by Codex — open /hooks in Codex and trust the Peeksy hooks")
    }

    @Test("A record switched off in /hooks reads as disabled, not trusted")
    func disabled() {
        var toml = trustedConfig()
        toml += """
        [hooks.state."\(settingsPath):stop:0:0"]
        enabled = false

        """
        // The `Stop` table now appears twice — TOML would reject that, but a
        // second block for the same key must still fold onto the first.
        let report = CodexHookTrust.audit(configTOML: toml, settingsPath: settingsPath,
                                          events: events, positions: allAtZero)
        #expect(report.disabled == ["Stop"])
        #expect(report.trusted.count == 7)
        #expect(report.summary == "7/8 trusted by Codex · 1 disabled (Stop) — open /hooks in Codex")
    }

    @Test("Missing and disabled are both named, in install order")
    func mixed() {
        var toml = trustedConfig(without: ["Interrupt", "SessionEnd"])
        toml += """
        [hooks.state."\(settingsPath):pre_tool_use:0:0"]
        enabled = false

        """
        let report = CodexHookTrust.audit(configTOML: toml, settingsPath: settingsPath,
                                          events: events, positions: allAtZero)
        #expect(report.summary == "5/8 trusted by Codex · 1 disabled (PreToolUse) · 2 need review (Interrupt, SessionEnd) — open /hooks in Codex")
    }

    @Test("The record is looked up at OUR coordinates, so a foreign group in front of us does not hide it")
    func positionsMatter() {
        let toml = """
        [hooks.state."\(settingsPath):stop:0:0"]
        trusted_hash = "sha256:theirs"

        [hooks.state."\(settingsPath):stop:1:0"]
        trusted_hash = "sha256:ours"
        """
        let behindTheirs = CodexHookTrust.audit(configTOML: toml, settingsPath: settingsPath,
                                                events: ["Stop"], positions: ["Stop": .init(group: 1, hook: 0)])
        #expect(behindTheirs.trusted == ["Stop"])

        let unrecorded = CodexHookTrust.audit(configTOML: toml, settingsPath: settingsPath,
                                              events: ["Stop"], positions: ["Stop": .init(group: 2, hook: 0)])
        #expect(unrecorded.untrusted == ["Stop"])
    }

    @Test("A different hooks.json path is a different hook")
    func pathIsPartOfIdentity() {
        let report = CodexHookTrust.audit(configTOML: trustedConfig(), settingsPath: "/Volumes/other/.codex/hooks.json",
                                          events: events, positions: allAtZero)
        #expect(report.untrusted == events)
    }

    @Test("Events we hold no position for are left out rather than reported")
    func unregisteredEventsAreSkipped() {
        var positions = allAtZero
        positions.removeValue(forKey: "Interrupt")
        let report = CodexHookTrust.audit(configTOML: trustedConfig(), settingsPath: settingsPath,
                                          events: events, positions: positions)
        #expect(report.entries.count == 7)
        #expect(report.summary == "7/7 trusted by Codex")
        #expect(CodexHookTrust.audit(configTOML: trustedConfig(), settingsPath: settingsPath,
                                     events: events, positions: [:]).summary == "nothing registered to check")
    }

    @Test("A trusted_hash under some other table never leaks into ours")
    func headersResetTheTable() {
        let toml = """
        [hooks.state."\(settingsPath):stop:0:0"]

        [something.else]
        trusted_hash = "sha256:not-for-us"
        enabled = true

        [hooks.state."\(settingsPath):interrupt:0:0"]
        # a comment between the header and the value
        trusted_hash = 'sha256:literal-string'   # trailing comment
        """
        let report = CodexHookTrust.audit(configTOML: toml, settingsPath: settingsPath,
                                          events: ["Stop", "Interrupt"],
                                          positions: ["Stop": .init(group: 0, hook: 0), "Interrupt": .init(group: 0, hook: 0)])
        #expect(report.untrusted == ["Stop"])
        #expect(report.trusted == ["Interrupt"])
    }

    @Test("Header parsing accepts both TOML quote styles and rejects everything else")
    func headerShapes() {
        #expect(CodexHookTrust.stateTableKey(#"[hooks.state."a:b:0:0"]"#) == "a:b:0:0")
        #expect(CodexHookTrust.stateTableKey("[hooks.state.'a:b:0:0']") == "a:b:0:0")
        #expect(CodexHookTrust.stateTableKey(#"[hooks.state."with \"quote\":0:0" ]"#) == #"with "quote":0:0"#)
        #expect(CodexHookTrust.stateTableKey("[hooks.state]") == nil)
        #expect(CodexHookTrust.stateTableKey("[hooks]") == nil)
        #expect(CodexHookTrust.stateTableKey(#"[hooks.state."unterminated]"#) == nil)
        #expect(CodexHookTrust.stateTableKey(#"[other."a:b:0:0"]"#) == nil)
    }

    @Test("An unparseable file reads as no record, never as a crash")
    func garbageIsHarmless() {
        for junk in ["", "= = =", "[[[", "trusted_hash = \"x\"", "\u{0}\u{1}"] {
            let report = CodexHookTrust.audit(configTOML: junk, settingsPath: settingsPath,
                                              events: ["Stop"], positions: ["Stop": .init(group: 0, hook: 0)])
            #expect(report.untrusted == ["Stop"])
        }
    }
}

@Suite("SettingsMerge.positions")
struct SettingsMergePositionsTests {
    private let ours = "/Users/example/.peeksy/peeksy-codex-hook.sh"
    private let events = AgentHookConfiguration.codex.events

    private func settings(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test("A fresh install is 0:0 for every event")
    func freshInstall() throws {
        let plan = try SettingsMerge.install(into: [:], command: ours, events: events, source: .codex)
        let positions = SettingsMerge.positions(in: plan.merged, command: ours, events: events, source: .codex)
        #expect(positions.count == events.count)
        #expect(positions.values.allSatisfy { $0 == SettingsMerge.Position(group: 0, hook: 0) })
    }

    @Test("Behind two foreign groups the installer appends, so ours is 2:0")
    func behindForeignGroups() throws {
        let existing = try settings("""
        {"hooks": {"Stop": [
          {"hooks": [{"type": "command", "command": "/theirs/one.sh"}]},
          {"hooks": [{"type": "command", "command": "/theirs/two.sh"}]}
        ]}}
        """)
        let plan = try SettingsMerge.install(into: existing, command: ours, events: events, source: .codex)
        let positions = SettingsMerge.positions(in: plan.merged, command: ours, events: events, source: .codex)
        #expect(positions["Stop"] == SettingsMerge.Position(group: 2, hook: 0))
        #expect(positions["SessionStart"] == SettingsMerge.Position(group: 0, hook: 0))
    }

    @Test("In a group somebody shares with us, the hook index is ours, not the group's first")
    func sharedGroup() throws {
        let shared = try settings("""
        {"hooks": {"Stop": [
          {"hooks": [{"type": "command", "command": "/theirs/one.sh"},
                     {"type": "command", "command": "\(ours)", "timeout": 3}]}
        ]}}
        """)
        let positions = SettingsMerge.positions(in: shared, command: ours, events: events, source: .codex)
        #expect(positions["Stop"] == SettingsMerge.Position(group: 0, hook: 1))
        #expect(positions["SessionStart"] == nil)
    }

    @Test("A file the merge would refuse yields nothing rather than a guess")
    func refusedFileYieldsNothing() throws {
        let broken = try settings(#"{"hooks": {"Stop": "not an array"}}"#)
        #expect(SettingsMerge.positions(in: broken, command: ours, events: events, source: .codex).isEmpty)
    }
}
