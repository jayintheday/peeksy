import Foundation
import Testing

@testable import PeeksyCore

/// The command string as Claude Code actually consumes it.
///
/// THIS SUITE EXISTS BECAUSE OF A SHIPPED BUG. The installer registered
/// `~/Library/Application Support/Peeksy/peeksy-hook.sh`, which Claude
/// Code runs through `/bin/sh -c` — and the shell word-split it:
///
///     SessionEnd hook […] failed:
///     /bin/sh: /Users/vijay/Library/Application: No such file or directory
///
/// The hook never ran once, for any session. It was not caught because the
/// smoke test piped a payload into the SCRIPT (`… | "$HOOK"`), which bypasses
/// the shell entirely. The registered command string was never executed the way
/// the agent executes it. `executesUnderRealShell` below is that missing test.
@Suite("The hook command string, as a shell sees it")
struct HookCommandTests {

    // MARK: - Quoting

    @Test("an ordinary path is left completely alone")
    func plainPathIsNotQuoted() {
        let path = "/Users/vijay/.peeksy/peeksy-hook.sh"
        #expect(HookSpec.shellQuoted(path) == path)
    }

    @Test("a path with a space is single-quoted")
    func spacedPathIsQuoted() {
        #expect(HookSpec.shellQuoted("/Users/v/Application Support/h.sh")
                == "'/Users/v/Application Support/h.sh'")
    }

    @Test("an embedded single quote is escaped rather than breaking out")
    func embeddedQuote() {
        let quoted = HookSpec.shellQuoted("/Users/v/it's here/h.sh")
        #expect(quoted == #"'/Users/v/it'\''s here/h.sh'"#)
        #expect(HookSpec.unquoted(quoted) == "/Users/v/it's here/h.sh")
    }

    @Test("quoting round-trips", arguments: [
        "/Users/v/.peeksy/peeksy-hook.sh",
        "/Users/v/Application Support/Peeksy/peeksy-hook.sh",
        "/Users/Vijay Patel/.peeksy/peeksy-hook.sh",
        "/tmp/it's/peeksy-hook.sh",
        "/tmp/a$b/peeksy-hook.sh",
        "/tmp/a;rm -rf x/peeksy-hook.sh",
    ])
    func roundTrips(_ path: String) {
        #expect(HookSpec.unquoted(HookSpec.shellQuoted(path)) == path)
    }

    @Test("shell metacharacters are quoted, not passed through")
    func metacharacters() {
        for path in ["/tmp/a b/h.sh", "/tmp/a$b/h.sh", "/tmp/a;b/h.sh", "/tmp/a&b/h.sh",
                     "/tmp/a*b/h.sh", "/tmp/a(b)/h.sh", "/tmp/a`b/h.sh"] {
            #expect(HookSpec.shellQuoted(path).hasPrefix("'"), "\(path) must be quoted")
        }
    }

    // MARK: - The test that was missing

    @Test("the registered command actually RUNS under /bin/sh -c, spaces and all")
    func executesUnderRealShell() throws {
        // A directory whose name has a space, which is exactly the shape of
        // `~/Library/Application Support`.
        let root = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("agent notch shell \(getpid())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = root.appendingPathComponent(HookSpec.scriptName)
        let marker = root.appendingPathComponent("ran")
        try Data("#!/bin/sh\ntouch \"\(marker.path)\"\nexit 0\n".utf8).write(to: script)
        chmod(script.path, 0o755)

        // Precisely what Claude Code does: hand the stored command to a shell.
        let command = HookSpec.shellQuoted(script.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: marker.path),
                "the command string did not execute the script")
    }

    @Test("an UNQUOTED spaced path fails under the shell — the bug, pinned")
    func unquotedSpacedPathFails() throws {
        let root = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("agent notch unquoted \(getpid())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = root.appendingPathComponent(HookSpec.scriptName)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
        chmod(script.path, 0o755)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script.path]     // deliberately NOT quoted
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        // 127 = command not found. If this ever starts passing, the shell
        // stopped word-splitting and the quoting above became optional — which
        // is worth knowing, not worth assuming.
        #expect(process.terminationStatus != 0)
    }

    // MARK: - The installed path

    @Test("the default hook path has no spaces in it")
    func defaultPathIsSpaceFree() {
        let path = SupportPaths.hookScript(home: URL(fileURLWithPath: "/Users/vijay")).path
        #expect(path == "/Users/vijay/.peeksy/peeksy-hook.sh")
        #expect(!path.contains(" "))
        // Belt and braces: even so, the command is built through shellQuoted, so
        // a home directory with a space in it still works.
        #expect(HookSpec.shellQuoted(path) == path)
    }

    @Test("a home directory with a space still yields a working command")
    func spacedHomeStillWorks() {
        let path = SupportPaths.hookScript(home: URL(fileURLWithPath: "/Users/Vijay Patel")).path
        #expect(path.contains(" "))
        #expect(HookSpec.shellQuoted(path).hasPrefix("'"))
    }

    // MARK: - Ownership and migration

    @Test("a command is ours if it is the exact string, quoted or not")
    func recognisesExact() {
        let want = "/Users/v/.peeksy/peeksy-hook.sh"
        #expect(HookSpec.isOurCommand(want, desired: want))
        #expect(HookSpec.isOurCommand("'\(want)'", desired: want))
        #expect(HookSpec.isOurCommand(want, desired: "'\(want)'"))
    }

    @Test("a command at an OLD path is still recognised as ours")
    func recognisesLegacyPath() {
        // The whole point: without this, moving the script would orphan nine
        // dead groups and add nine live ones beside them.
        let old = "'/Users/v/Library/Application Support/Peeksy/peeksy-hook.sh'"
        let new = "/Users/v/.peeksy/peeksy-hook.sh"
        #expect(HookSpec.isOurCommand(old, desired: new))
    }

    /// The rename from AgentNotch to Peeksy. Anybody already running the app has
    /// nine groups pointing at `agent-notch-hook.sh`; if the new binary stops
    /// recognising them, an install appends nine live groups beside nine dead
    /// ones and an uninstall leaves the dead ones behind.
    @Test("a registration written under the OLD APP NAME is still ours")
    func recognisesPreRenameName() {
        let new = "/Users/v/.peeksy/peeksy-hook.sh"
        for old in [
            "/Users/v/.agent-notch/agent-notch-hook.sh",
            "'/Users/v/Library/Application Support/AgentNotch/agent-notch-hook.sh'",
            "agent-notch-hook.sh",
        ] {
            #expect(HookSpec.isOurCommand(old, desired: new), "\(old) should still be ours")
        }
    }

    @Test("every name this project has shipped under is owned, and the current one is first")
    func ownedNamesAreComplete() {
        #expect(HookSpec.ownedScriptNames.first == HookSpec.scriptName)
        #expect(HookSpec.ownedScriptNames.contains("agent-notch-hook.sh"))
        #expect(Set(HookSpec.ownedScriptNames).count == HookSpec.ownedScriptNames.count)
    }

    @Test("another tool's hook is never ours")
    func rejectsForeign() {
        let new = "/Users/v/.peeksy/peeksy-hook.sh"
        #expect(!HookSpec.isOurCommand("/Users/v/.othertool/hooks/notify.sh", desired: new))
        #expect(!HookSpec.isOurCommand("/Users/v/Code/some-project/hooks/some-hook.sh", desired: new))
        #expect(!HookSpec.isOurCommand("/usr/bin/true", desired: new))
        // Not a suffix match on the bare word: only the real filename counts.
        #expect(!HookSpec.isOurCommand("/tmp/not-peeksy-hook.shx", desired: new))
    }
}

@Suite("SettingsMerge: migrating a stale registration")
struct SettingsMergeMigrationTests {
    private let old = "'/Users/example/Library/Application Support/Peeksy/peeksy-hook.sh'"
    private var new: String { SettingsFixture.ourCommand }

    /// A settings object already carrying the OLD, broken registration.
    private func alreadyInstalledAtOldPath() throws -> [String: Any] {
        var settings = SettingsFixture.object
        var hooks = try #require(settings[HookSpec.hooksKey] as? [String: Any])
        for spec in HookSpec.events {
            var groups = hooks[spec.event] as? [Any] ?? []
            groups.append(HookSpec.group(command: old, matcher: spec.matcher))
            hooks[spec.event] = groups
        }
        settings[HookSpec.hooksKey] = hooks
        return settings
    }

    @Test("the old registration is REWRITTEN in place, not duplicated")
    func migratesInPlace() throws {
        let before = try alreadyInstalledAtOldPath()
        let plan = try SettingsMerge.install(into: before, command: new)

        #expect(plan.events(.repaired).sorted() == HookSpec.events.map(\.event).sorted())
        #expect(plan.events(.added).isEmpty)

        let hooks = try #require(plan.merged[HookSpec.hooksKey] as? [String: Any])
        for spec in HookSpec.events {
            let groups = try #require(hooks[spec.event] as? [Any]).compactMap { $0 as? [String: Any] }
            let commands = groups.flatMap { g in
                (g[HookSpec.hooksKey] as? [Any] ?? [])
                    .compactMap { ($0 as? [String: Any])?[HookSpec.commandKey] as? String }
            }
            #expect(commands.filter { HookSpec.isOurCommand($0, desired: new) } == [new],
                    "\(spec.event) should carry exactly one of ours, at the new path")
        }
    }

    @Test("the foreign groups are untouched by a migration")
    func migrationPreservesForeign() throws {
        let before = try alreadyInstalledAtOldPath()
        let plan = try SettingsMerge.install(into: before, command: new)
        let report = SettingsAudit.preservation(before: before, after: plan.merged, command: new)
        #expect(report.isClean, "violations: \(report.violations)")
        #expect(report.foreignGroupsAfter == SettingsFixture.foreignGroupCount)
    }

    @Test("uninstall removes a stale registration too")
    func uninstallRemovesLegacy() throws {
        let before = try alreadyInstalledAtOldPath()
        let plan = try SettingsMerge.uninstall(from: before, command: new)
        #expect(SettingsAudit.canonical(plan.merged) == SettingsAudit.canonical(SettingsFixture.object))
    }

    @Test("a stale registration reads as NOT installed, so the app offers to fix it")
    func staleReadsAsNotInstalled() throws {
        let plan = try SettingsMerge.install(into: try alreadyInstalledAtOldPath(), command: new)
        #expect(!plan.isNoOp)
    }
}
