import Foundation
import Testing

@testable import AgentNotchCore

/// A scratch directory that cleans itself up.
///
/// `/tmp`, not the agent scratchpad: nothing here binds a socket, but keeping
/// every temp path in this repo short is the habit that stops somebody
/// rediscovering the 104-byte `sun_path` limit the hard way.
private struct Scratch: ~Copyable {
    let directory: URL

    init(_ name: String) {
        directory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("agent-notch-tests-\(name)-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var settings: URL { directory.appendingPathComponent("settings.json") }

    func write(_ text: String, to url: URL) {
        try? Data(text.utf8).write(to: url)
    }

    func backups() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.lastPathComponent.contains("agent-notch-backup-") }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private func canonical(_ value: Any?) -> String { SettingsAudit.canonical(value) }

// MARK: - SettingsIO

@Suite("SettingsIO")
struct SettingsIOTests {

    @Test("a missing file reads as nil, an empty file as an empty object")
    func readsMissingAndEmpty() throws {
        let scratch = Scratch("io-read")
        #expect(try SettingsIO.read(scratch.settings) == nil)

        scratch.write("", to: scratch.settings)
        #expect(try SettingsIO.read(scratch.settings)?.isEmpty == true)
    }

    @Test("a file that is not JSON is refused, not repaired")
    func refusesNonJSON() {
        let scratch = Scratch("io-bad")
        scratch.write("{ this is not json", to: scratch.settings)
        #expect(throws: SettingsIO.Failure.notJSON(path: scratch.settings.path)) {
            _ = try SettingsIO.read(scratch.settings)
        }
    }

    @Test("valid JSON that is not an object at the top level is refused")
    func refusesNonObjectRoot() {
        let scratch = Scratch("io-array")
        scratch.write("[1, 2, 3]", to: scratch.settings)
        #expect(throws: SettingsIO.Failure.rootNotAnObject(path: scratch.settings.path)) {
            _ = try SettingsIO.read(scratch.settings)
        }
    }

    @Test("canonical output is sorted, pretty, slash-clean and newline-terminated")
    func canonicalForm() throws {
        let text = try SettingsIO.canonicalText(["b": 1, "a": "/Users/x"])
        #expect(text.hasSuffix("\n"))
        #expect(text.contains("/Users/x"))       // not \/Users\/x
        #expect(text.range(of: "\"a\"")!.lowerBound < text.range(of: "\"b\"")!.lowerBound)
    }

    @Test("a write leaves a timestamped backup beside the original")
    func writesBackup() throws {
        let scratch = Scratch("io-backup")
        scratch.write(#"{"model":"opus"}"#, to: scratch.settings)

        let backup = try SettingsIO.write(["model": "sonnet"], to: scratch.settings) { _ in }

        let backupURL = try #require(backup)
        // Same directory, so restoring is a rename rather than a cross-filesystem copy.
        #expect(backupURL.deletingLastPathComponent().path == scratch.directory.path)
        #expect(backupURL.lastPathComponent.hasPrefix("settings.json.agent-notch-backup-"))
        #expect(try SettingsIO.read(backupURL)?["model"] as? String == "opus")
        #expect(try SettingsIO.read(scratch.settings)?["model"] as? String == "sonnet")
    }

    @Test("writing where no file existed reports no backup")
    func noBackupForNewFile() throws {
        let scratch = Scratch("io-new")
        let backup = try SettingsIO.write(["model": "opus"], to: scratch.settings) { _ in }
        #expect(backup == nil)
        #expect(try SettingsIO.read(scratch.settings)?["model"] as? String == "opus")
    }

    @Test("a failing verification leaves the original file untouched and no temp behind")
    func verificationAborts() throws {
        let scratch = Scratch("io-verify")
        scratch.write(#"{"model":"opus"}"#, to: scratch.settings)

        #expect(throws: SettingsIO.Failure.self) {
            _ = try SettingsIO.write(["model": "sonnet"], to: scratch.settings) { _ in
                throw SettingsIO.Failure.verificationFailed(["nope"])
            }
        }

        #expect(try SettingsIO.read(scratch.settings)?["model"] as? String == "opus")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: scratch.directory.path)) ?? []
        #expect(!leftovers.contains { $0.hasSuffix(".tmp") })
    }

    @Test("the verifier sees the bytes that are actually on disk")
    func verifierSeesDiskBytes() throws {
        let scratch = Scratch("io-sees")
        var seen: [String: Any] = [:]
        try SettingsIO.write(["model": "opus", "n": 3], to: scratch.settings) { written in
            seen = written
        }
        #expect(seen["model"] as? String == "opus")
        #expect(seen["n"] as? Int == 3)
    }

    @Test("the original file's permissions survive the write")
    func preservesMode() throws {
        let scratch = Scratch("io-mode")
        scratch.write(#"{"a":1}"#, to: scratch.settings)
        chmod(scratch.settings.path, 0o600)

        try SettingsIO.write(["a": 2], to: scratch.settings) { _ in }

        let attributes = try FileManager.default.attributesOfItem(atPath: scratch.settings.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)
    }

    @Test("backup filenames are stamped to the second")
    func backupNaming() {
        let url = URL(fileURLWithPath: "/tmp/settings.json")
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 27
        components.hour = 13; components.minute = 45; components.second = 1
        let when = Calendar.current.date(from: components)!
        #expect(SettingsIO.backupURL(for: url, now: when).lastPathComponent
                == "settings.json.agent-notch-backup-20260727-134501")
    }
}

// MARK: - HookInstaller

@Suite("HookInstaller")
struct HookInstallerTests {

    private func installer(_ scratch: borrowing Scratch) -> HookInstaller {
        HookInstaller(settingsURL: scratch.settings, command: SettingsFixture.ourCommand)
    }

    @Test("the preview diffs a normalised before against a normalised after")
    func previewDiffsOnlyRealChanges() throws {
        let scratch = Scratch("preview")
        scratch.write(SettingsFixture.json, to: scratch.settings)

        let preview = try installer(scratch).preview()

        #expect(!preview.isNoOp)
        #expect(preview.audit.isClean)
        #expect(preview.headline.contains("9 events to register"))
        // Only additions: the reordering JSONSerialization imposes appears on
        // BOTH sides and cancels, so a `-` line here would be a real removal.
        let removals = preview.diff.split(separator: "\n").filter {
            $0.hasPrefix("-") && !$0.hasPrefix("---")
        }
        #expect(removals.isEmpty, "the diff should be pure additions, got: \(removals)")
        #expect(preview.diff.contains(SettingsFixture.ourCommand))
    }

    @Test("apply writes, backs up, and survives an audit of the bytes on disk")
    func applyWrites() throws {
        let scratch = Scratch("apply")
        scratch.write(SettingsFixture.json, to: scratch.settings)
        let installer = self.installer(scratch)

        let backup = try installer.apply(installer.preview())
        #expect(backup != nil)
        #expect(scratch.backups().count == 1)

        let after = try #require(try SettingsIO.read(scratch.settings))
        let before = SettingsFixture.object
        for key in before.keys where key != HookSpec.hooksKey {
            #expect(canonical(after[key]) == canonical(before[key]), "\(key) changed")
        }
        #expect(installer.isInstalled())
    }

    @Test("installing twice is a no-op the second time")
    func applyIsIdempotent() throws {
        let scratch = Scratch("idempotent")
        scratch.write(SettingsFixture.json, to: scratch.settings)
        let installer = self.installer(scratch)

        try installer.apply(installer.preview())
        let first = try Data(contentsOf: scratch.settings)

        let second = try installer.preview()
        #expect(second.isNoOp)
        #expect(second.headline == "Already installed — nothing to change.")
        try installer.apply(second)
        #expect(try Data(contentsOf: scratch.settings) == first)
    }

    @Test("install then uninstall returns the file to what it said before")
    func roundTrip() throws {
        let scratch = Scratch("round-trip")
        scratch.write(SettingsFixture.json, to: scratch.settings)
        let installer = self.installer(scratch)

        try installer.apply(installer.preview(.install))
        try installer.apply(installer.preview(.uninstall))

        #expect(canonical(try SettingsIO.read(scratch.settings)) == canonical(SettingsFixture.object))
        #expect(!installer.isInstalled())
    }

    @Test("a file that changed since the preview is refused, not overwritten")
    func refusesStalePreview() throws {
        let scratch = Scratch("stale")
        scratch.write(SettingsFixture.json, to: scratch.settings)
        let installer = self.installer(scratch)
        let preview = try installer.preview()

        // Somebody — `claude` itself, or the user in an editor — writes while
        // the approval sheet is open.
        var moved = SettingsFixture.object
        moved["model"] = "changed-underneath-us"
        try SettingsIO.write(moved, to: scratch.settings) { _ in }

        #expect(throws: HookInstaller.Failure.changedOnDisk(scratch.settings.path)) {
            try installer.apply(preview)
        }
        #expect(try SettingsIO.read(scratch.settings)?["model"] as? String == "changed-underneath-us")
    }

    @Test("a settings file that does not exist yet installs cleanly")
    func installsIntoNothing() throws {
        let scratch = Scratch("fresh")
        let installer = self.installer(scratch)

        let preview = try installer.preview()
        #expect(!preview.settingsExisted)
        try installer.apply(preview)
        #expect(installer.isInstalled())
        #expect((try SettingsIO.read(scratch.settings)?[HookSpec.hooksKey] as? [String: Any])?.count == 9)
    }

    @Test("a partial install reads as NOT installed")
    func partialInstallIsNotInstalled() throws {
        let scratch = Scratch("partial")
        var settings = SettingsFixture.object
        var hooks = try #require(settings[HookSpec.hooksKey] as? [String: Any])
        // Five of nine — the state a hand-edit or an interrupted install leaves.
        for event in ["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "Notification"] {
            var groups = hooks[event] as? [Any] ?? []
            groups.append(HookSpec.group(command: SettingsFixture.ourCommand, matcher: nil))
            hooks[event] = groups
        }
        settings[HookSpec.hooksKey] = hooks
        try SettingsIO.write(settings, to: scratch.settings) { _ in }

        let installer = self.installer(scratch)
        // A substring scan would say yes here, which is exactly why it was
        // replaced: the four tool events are missing and no row would ever move.
        #expect(!installer.isInstalled())
        #expect(try installer.preview().headline.contains("4 events to register"))
    }

    @Test("an unparseable settings file refuses at preview time and never writes")
    func refusesBrokenFile() throws {
        let scratch = Scratch("broken")
        scratch.write("{ not json at all", to: scratch.settings)
        let installer = self.installer(scratch)

        #expect(throws: SettingsIO.Failure.self) { _ = try installer.preview() }
        #expect(!installer.isInstalled())
        #expect(String(decoding: try Data(contentsOf: scratch.settings), as: UTF8.self) == "{ not json at all")
    }
}

// MARK: - HookScriptSync

@Suite("HookScriptSync")
struct HookScriptSyncTests {

    @Test("first sync creates the script and makes it executable")
    func creates() throws {
        let scratch = Scratch("sync-create")
        let source = scratch.directory.appendingPathComponent("bundled.sh")
        scratch.write("#!/bin/sh\nexit 0\n", to: source)
        let destination = scratch.directory.appendingPathComponent("installed/agent-notch-hook.sh")

        #expect(try HookScriptSync.sync(from: source, to: destination) == .created)
        #expect(FileManager.default.isExecutableFile(atPath: destination.path))
        #expect(try Data(contentsOf: destination) == Data(contentsOf: source))
    }

    @Test("an unchanged script is left alone, a changed one is replaced")
    func updatesOnlyWhenBytesDiffer() throws {
        let scratch = Scratch("sync-update")
        let source = scratch.directory.appendingPathComponent("bundled.sh")
        let destination = scratch.directory.appendingPathComponent("agent-notch-hook.sh")
        scratch.write("#!/bin/sh\nexit 0\n", to: source)

        #expect(try HookScriptSync.sync(from: source, to: destination) == .created)
        #expect(try HookScriptSync.sync(from: source, to: destination) == .upToDate)

        scratch.write("#!/bin/sh\necho different\nexit 0\n", to: source)
        #expect(try HookScriptSync.sync(from: source, to: destination) == .updated)
        #expect(try Data(contentsOf: destination) == Data(contentsOf: source))
    }

    @Test("a script that lost its executable bit is repaired even with identical bytes")
    func repairsPermissions() throws {
        let scratch = Scratch("sync-chmod")
        let source = scratch.directory.appendingPathComponent("bundled.sh")
        let destination = scratch.directory.appendingPathComponent("agent-notch-hook.sh")
        scratch.write("#!/bin/sh\nexit 0\n", to: source)
        try HookScriptSync.sync(from: source, to: destination)

        chmod(destination.path, 0o644)
        // Without this, every hook event would fail with EACCES and the app
        // would look dead while the settings file said it was installed.
        #expect(try HookScriptSync.sync(from: source, to: destination) == .updated)
        #expect(FileManager.default.isExecutableFile(atPath: destination.path))
    }

    @Test("a missing bundled script is an error, not a silent no-op")
    func missingSource() {
        let scratch = Scratch("sync-missing")
        #expect(throws: HookScriptSync.Failure.self) {
            _ = try HookScriptSync.sync(
                from: scratch.directory.appendingPathComponent("nope.sh"),
                to: scratch.directory.appendingPathComponent("out.sh"))
        }
    }
}

// MARK: - The real file

/// The merge, run against the user's ACTUAL `~/.claude/settings.json`.
///
/// Entirely in memory — this suite never writes, never backs up and never
/// touches the file. It exists because the fixture is a reconstruction, and a
/// reconstruction can be wrong in exactly the way that matters. Skipped when
/// the file is absent (CI, a fresh machine).
@Suite("SettingsMerge against the real ~/.claude/settings.json")
struct SettingsMergeLiveTests {

    /// `nil` only when the file genuinely is not there. A file that exists but
    /// fails to read is a FAILURE, not a skip — a silent skip is how this whole
    /// suite quietly stops testing anything.
    private func realSettings() throws -> [String: Any]? {
        let url = SupportPaths.claudeSettings()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let parsed = try SettingsIO.read(url)
        #expect(parsed != nil, "settings.json exists but did not read back")
        return parsed
    }

    @Test("every foreign key and hook group survives a real merge, in memory")
    func realFileSurvives() throws {
        guard let before = try realSettings() else { return }
        let command = SupportPaths.hookScript().path

        let plan = try SettingsMerge.install(into: before, command: command)
        let report = SettingsAudit.preservation(before: before, after: plan.merged, command: command)

        #expect(report.isClean, "violations: \(report.violations)")
        #expect(report.topLevelKeysAfter >= report.topLevelKeysBefore)
        #expect(report.foreignGroupsAfter == report.foreignGroupsBefore)

        // Belt and braces, independent of the audit's own logic.
        for key in before.keys where key != HookSpec.hooksKey {
            #expect(canonical(plan.merged[key]) == canonical(before[key]), "\(key) changed")
        }
    }

    @Test("the real file round-trips through install and uninstall")
    func realFileRoundTrips() throws {
        guard let before = try realSettings() else { return }
        let command = SupportPaths.hookScript().path

        let installed = try SettingsMerge.install(into: before, command: command)
        let removed = try SettingsMerge.uninstall(from: installed.merged, command: command)
        #expect(canonical(removed.merged) == canonical(before))
    }

    @Test("the real file serializes and re-parses without losing anything")
    func realFileSurvivesSerialization() throws {
        guard let before = try realSettings() else { return }
        let text = try SettingsIO.canonicalText(before)
        let reparsed = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        // The `Codable`-would-have-dropped-it check, on real data: nine of these
        // keys are ones this app has never heard of.
        #expect(canonical(reparsed) == canonical(before))
    }
}
