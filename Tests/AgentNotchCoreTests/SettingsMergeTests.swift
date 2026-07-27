import Foundation
import Testing

@testable import AgentNotchCore

// MARK: - Reading helpers

/// Groups under one event, as decoded objects.
private func groups(_ settings: [String: Any], _ event: String) -> [[String: Any]] {
    let hooks = settings[HookSpec.hooksKey] as? [String: Any] ?? [:]
    let raw = hooks[event] as? [Any] ?? []
    return raw.compactMap { $0 as? [String: Any] }
}

private func commands(_ group: [String: Any]) -> [String] {
    (group[HookSpec.hooksKey] as? [Any] ?? [])
        .compactMap { ($0 as? [String: Any])?[HookSpec.commandKey] as? String }
}

private func canonical(_ value: Any?) -> String { SettingsAudit.canonical(value) }

@Suite("SettingsMerge: install")
struct SettingsMergeInstallTests {

    @Test("every one of the nine events gains exactly one group, appended last")
    func registersNineEvents() throws {
        let before = SettingsFixture.object
        let plan = try SettingsMerge.install(into: before, command: SettingsFixture.ourCommand)

        #expect(plan.events(.added).sorted() == HookSpec.events.map(\.event).sorted())

        for spec in HookSpec.events {
            let after = groups(plan.merged, spec.event)
            let mine = after.filter { commands($0).contains(SettingsFixture.ourCommand) }
            #expect(mine.count == 1, "\(spec.event) should have exactly one of our groups")
            // LAST, so the other tools' hooks keep running in the order they
            // already ran in.
            #expect(commands(after[after.count - 1]).contains(SettingsFixture.ourCommand),
                    "\(spec.event) should append ours at the end")
        }
    }

    @Test("Notification is registered with NO matcher, PreToolUse with \"*\"")
    func matchersAreExact() throws {
        let plan = try SettingsMerge.install(
            into: SettingsFixture.object, command: SettingsFixture.ourCommand)

        // The expensive mistake. A matcher on Notification silently loses every
        // attention event, which is the app's highest-value signal.
        for event in ["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "Notification"] {
            let ours = try #require(
                groups(plan.merged, event).last { commands($0).contains(SettingsFixture.ourCommand) })
            #expect(ours[HookSpec.matcherKey] == nil, "\(event) must carry no matcher key at all")
        }
        for event in ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"] {
            let ours = try #require(
                groups(plan.merged, event).last { commands($0).contains(SettingsFixture.ourCommand) })
            #expect(ours[HookSpec.matcherKey] as? String == "*")
        }
    }

    @Test("our group is exactly one command hook and nothing else")
    func groupShapeIsCanonical() throws {
        let plan = try SettingsMerge.install(
            into: SettingsFixture.object, command: SettingsFixture.ourCommand)
        let ours = try #require(
            groups(plan.merged, "Stop").last { commands($0).contains(SettingsFixture.ourCommand) })

        #expect(ours.keys.sorted() == ["hooks"])
        #expect(canonical(ours) == #"{"hooks":[{"command":"\#(SettingsFixture.ourCommand)","type":"command"}]}"#)
    }

    @Test("every foreign top-level key survives byte-identically")
    func foreignTopLevelKeysSurvive() throws {
        let before = SettingsFixture.object
        let plan = try SettingsMerge.install(into: before, command: SettingsFixture.ourCommand)

        #expect(before.count == SettingsFixture.topLevelKeyCount)
        #expect(plan.merged.count == SettingsFixture.topLevelKeyCount)
        for key in before.keys where key != HookSpec.hooksKey {
            #expect(canonical(plan.merged[key]) == canonical(before[key]), "\(key) changed")
        }
    }

    @Test("every foreign hook group survives byte-identically, in order")
    func foreignGroupsSurviveInOrder() throws {
        let before = SettingsFixture.object
        let plan = try SettingsMerge.install(into: before, command: SettingsFixture.ourCommand)

        let hooksBefore = try #require(before[HookSpec.hooksKey] as? [String: Any])
        #expect(hooksBefore.count == SettingsFixture.hookEventCount)

        var counted = 0
        for event in hooksBefore.keys {
            let old = groups(before, event)
            let new = groups(plan.merged, event)
            // Position-for-position: our group only ever lands at the end, so
            // every foreign group keeps its index as well as its contents.
            for (index, group) in old.enumerated() {
                #expect(canonical(new[index]) == canonical(group),
                        "\(event)[\(index)] moved or changed")
                counted += 1
            }
        }
        #expect(counted == SettingsFixture.foreignGroupCount)
    }

    @Test("events we do not register are untouched")
    func untouchedEventsAreUntouched() throws {
        let before = SettingsFixture.object
        let plan = try SettingsMerge.install(into: before, command: SettingsFixture.ourCommand)
        let hooksAfter = try #require(plan.merged[HookSpec.hooksKey] as? [String: Any])

        for event in ["SubagentStop", "PreCompact"] {
            #expect(canonical(hooksAfter[event]) == canonical((before[HookSpec.hooksKey] as? [String: Any])?[event]))
        }
        // No new events invented.
        #expect(hooksAfter.count == SettingsFixture.hookEventCount)
    }

    @Test("installing twice changes nothing the second time")
    func isIdempotent() throws {
        let first = try SettingsMerge.install(
            into: SettingsFixture.object, command: SettingsFixture.ourCommand)
        let second = try SettingsMerge.install(into: first.merged, command: SettingsFixture.ourCommand)

        #expect(second.isNoOp)
        #expect(second.events(.added).isEmpty)
        #expect(canonical(second.merged) == canonical(first.merged))
    }

    @Test("a fresh install reports work to do")
    func firstInstallIsNotANoOp() throws {
        let plan = try SettingsMerge.install(
            into: SettingsFixture.object, command: SettingsFixture.ourCommand)
        #expect(!plan.isNoOp)
    }

    @Test("an empty settings object grows a complete hooks section")
    func emptySettings() throws {
        let plan = try SettingsMerge.install(into: [:], command: SettingsFixture.ourCommand)
        let hooks = try #require(plan.merged[HookSpec.hooksKey] as? [String: Any])
        #expect(hooks.count == 9)
        #expect(plan.merged.count == 1)
    }

    @Test("a settings file with other keys but no hooks key keeps them")
    func noHooksKey() throws {
        let before: [String: Any] = ["model": "opus", "permissions": ["defaultMode": "auto"]]
        let plan = try SettingsMerge.install(into: before, command: SettingsFixture.ourCommand)
        #expect(plan.merged["model"] as? String == "opus")
        #expect(canonical(plan.merged["permissions"]) == canonical(before["permissions"]))
        #expect((plan.merged[HookSpec.hooksKey] as? [String: Any])?.count == 9)
    }
}

@Suite("SettingsMerge: repair and shared groups")
struct SettingsMergeRepairTests {

    @Test("our group with the wrong matcher is repaired")
    func repairsWrongMatcher() throws {
        var before = SettingsFixture.object
        var hooks = try #require(before[HookSpec.hooksKey] as? [String: Any])
        // The exact mistake the whole matcher discussion is about: Notification
        // registered with "*", where it never fires.
        var notification = try #require(hooks["Notification"] as? [Any])
        notification.append([
            "matcher": "*",
            "hooks": [["type": "command", "command": SettingsFixture.ourCommand]],
        ] as [String: Any])
        hooks["Notification"] = notification
        before[HookSpec.hooksKey] = hooks

        let plan = try SettingsMerge.install(into: before, command: SettingsFixture.ourCommand)

        #expect(plan.events(.repaired) == ["Notification"])
        let ours = try #require(
            groups(plan.merged, "Notification").last { commands($0).contains(SettingsFixture.ourCommand) })
        #expect(ours[HookSpec.matcherKey] == nil)
        // Still exactly one of ours, and the two foreign groups are intact.
        #expect(groups(plan.merged, "Notification").count == 3)
    }

    @Test("an empty matcher string counts as no matcher, so nothing is rewritten")
    func emptyMatcherIsNotRewritten() throws {
        var before: [String: Any] = [:]
        before[HookSpec.hooksKey] = [
            "Stop": [["matcher": "", "hooks": [["type": "command", "command": SettingsFixture.ourCommand]]] as [String: Any]]
        ]
        let plan = try SettingsMerge.install(into: before, command: SettingsFixture.ourCommand)
        #expect(plan.events(.repaired).isEmpty)
        #expect(plan.events(.unchanged).contains("Stop"))
    }

    @Test("a group holding our command AND somebody else's is left alone")
    func sharedGroupIsNeverRewritten() throws {
        var before = SettingsFixture.object
        var hooks = try #require(before[HookSpec.hooksKey] as? [String: Any])
        // A hand-merge: our hook dropped into another tool's group. Rewriting it
        // to our canonical shape would delete their hook.
        let shared: [String: Any] = [
            "matcher": "*",
            "hooks": [
                ["type": "command", "command": SettingsFixture.toolOne],
                ["type": "command", "command": SettingsFixture.ourCommand],
            ],
        ]
        hooks["PreToolUse"] = [shared]
        before[HookSpec.hooksKey] = hooks

        let plan = try SettingsMerge.install(into: before, command: SettingsFixture.ourCommand)

        #expect(plan.events(.unchanged).contains("PreToolUse"))
        #expect(groups(plan.merged, "PreToolUse").count == 1)
        #expect(canonical(groups(plan.merged, "PreToolUse")[0]) == canonical(shared))
    }
}

@Suite("SettingsMerge: refusals")
struct SettingsMergeRefusalTests {

    @Test("a hooks value that is not an object is refused")
    func hooksNotAnObject() {
        #expect(throws: SettingsMerge.Refusal.hooksNotAnObject) {
            _ = try SettingsMerge.install(into: ["hooks": "nope"], command: "/x")
        }
        #expect(throws: SettingsMerge.Refusal.hooksNotAnObject) {
            _ = try SettingsMerge.install(into: ["hooks": [1, 2, 3]], command: "/x")
        }
    }

    @Test("an event whose value is not an array is refused")
    func eventNotAnArray() {
        #expect(throws: SettingsMerge.Refusal.eventNotAnArray("Stop")) {
            _ = try SettingsMerge.install(into: ["hooks": ["Stop": "nope"]], command: "/x")
        }
    }

    @Test("a group that is not an object is refused BEFORE anything is written")
    func groupNotAnObject() {
        #expect(throws: SettingsMerge.Refusal.groupNotAnObject(event: "Stop", index: 1)) {
            _ = try SettingsMerge.install(
                into: ["hooks": ["Stop": [["hooks": []] as [String: Any], "nope"]]], command: "/x")
        }
    }

    @Test("a malformed group under an event we do not register still refuses")
    func malformedForeignEventRefuses() {
        // We would never touch SubagentStop, but writing the file at all means
        // re-serializing every byte of it, so a shape we cannot round-trip
        // safely has to stop the whole operation.
        #expect(throws: SettingsMerge.Refusal.self) {
            _ = try SettingsMerge.uninstall(
                from: ["hooks": ["SubagentStop": ["nope"]]], command: "/x")
        }
    }
}

@Suite("SettingsMerge: uninstall")
struct SettingsMergeUninstallTests {

    @Test("install then uninstall returns the file to exactly where it started")
    func roundTrips() throws {
        let before = SettingsFixture.object
        let installed = try SettingsMerge.install(into: before, command: SettingsFixture.ourCommand)
        let removed = try SettingsMerge.uninstall(from: installed.merged, command: SettingsFixture.ourCommand)

        #expect(canonical(removed.merged) == canonical(before))
    }

    @Test("uninstall removes only groups that are exclusively ours")
    func leavesSharedGroups() throws {
        var settings: [String: Any] = [:]
        settings[HookSpec.hooksKey] = [
            "PreToolUse": [
                ["matcher": "*", "hooks": [["type": "command", "command": SettingsFixture.toolOne]]] as [String: Any],
                ["matcher": "*", "hooks": [
                    ["type": "command", "command": SettingsFixture.toolTwo],
                    ["type": "command", "command": SettingsFixture.ourCommand],
                ]] as [String: Any],
            ]
        ]
        let plan = try SettingsMerge.uninstall(from: settings, command: SettingsFixture.ourCommand)
        #expect(groups(plan.merged, "PreToolUse").count == 2)
        #expect(canonical(plan.merged) == canonical(settings))
    }

    @Test("an event array we empty is dropped, and so is an empty hooks object")
    func dropsEmptyContainers() throws {
        let settings: [String: Any] = [
            "model": "opus",
            "hooks": ["Stop": [["hooks": [["type": "command", "command": SettingsFixture.ourCommand]]] as [String: Any]]],
        ]
        let plan = try SettingsMerge.uninstall(from: settings, command: SettingsFixture.ourCommand)
        #expect(plan.merged[HookSpec.hooksKey] == nil)
        #expect(plan.merged["model"] as? String == "opus")
    }

    @Test("uninstalling when nothing is installed is a no-op")
    func uninstallIsIdempotent() throws {
        let before = SettingsFixture.object
        let plan = try SettingsMerge.uninstall(from: before, command: SettingsFixture.ourCommand)
        #expect(plan.isNoOp)
        #expect(canonical(plan.merged) == canonical(before))
    }

    @Test("a stale registration under an event we no longer ask for is still removed")
    func removesStaleEvents() throws {
        var settings: [String: Any] = [:]
        settings[HookSpec.hooksKey] = [
            "PreCompact": [
                ["hooks": [["type": "command", "command": SettingsFixture.toolOne]]] as [String: Any],
                ["hooks": [["type": "command", "command": SettingsFixture.ourCommand]]] as [String: Any],
            ]
        ]
        let plan = try SettingsMerge.uninstall(from: settings, command: SettingsFixture.ourCommand)
        #expect(groups(plan.merged, "PreCompact").count == 1)
        #expect(commands(groups(plan.merged, "PreCompact")[0]) == [SettingsFixture.toolOne])
    }
}

@Suite("SettingsAudit")
struct SettingsAuditTests {

    @Test("a clean install reports no violations and counts what it did")
    func cleanInstall() throws {
        let before = SettingsFixture.object
        let plan = try SettingsMerge.install(into: before, command: SettingsFixture.ourCommand)
        let report = SettingsAudit.preservation(
            before: before, after: plan.merged, command: SettingsFixture.ourCommand)

        #expect(report.isClean)
        #expect(report.topLevelKeysBefore == SettingsFixture.topLevelKeyCount)
        #expect(report.foreignGroupsBefore == SettingsFixture.foreignGroupCount)
        #expect(report.foreignGroupsAfter == SettingsFixture.foreignGroupCount)
        #expect(report.ourGroupsBefore == 0)
        #expect(report.ourGroupsAfter == 9)
        #expect(report.summary.contains("18/18 foreign hook groups preserved"))
        #expect(report.summary.contains("9 groups added"))
    }

    @Test("a dropped top-level key is caught")
    func catchesDroppedKey() throws {
        var after = SettingsFixture.object
        after.removeValue(forKey: "statusLine")
        let report = SettingsAudit.preservation(
            before: SettingsFixture.object, after: after, command: SettingsFixture.ourCommand)
        #expect(!report.isClean)
        #expect(report.violations.contains { $0.contains("statusLine") && $0.contains("dropped") })
    }

    @Test("a changed top-level key is caught")
    func catchesChangedKey() throws {
        var after = SettingsFixture.object
        after["model"] = "sonnet"
        let report = SettingsAudit.preservation(
            before: SettingsFixture.object, after: after, command: SettingsFixture.ourCommand)
        #expect(report.violations.contains { $0.contains("model") && $0.contains("changed") })
    }

    @Test("a lost foreign hook group is caught")
    func catchesLostForeignGroup() throws {
        var after = SettingsFixture.object
        var hooks = try #require(after[HookSpec.hooksKey] as? [String: Any])
        hooks["PreToolUse"] = [(hooks["PreToolUse"] as? [Any] ?? []).first as Any]
        after[HookSpec.hooksKey] = hooks

        let report = SettingsAudit.preservation(
            before: SettingsFixture.object, after: after, command: SettingsFixture.ourCommand)
        #expect(!report.isClean)
        #expect(report.violations.contains { $0.contains("PreToolUse") })
    }

    @Test("reordering foreign groups is caught even though nothing is lost")
    func catchesReorder() throws {
        var after = SettingsFixture.object
        var hooks = try #require(after[HookSpec.hooksKey] as? [String: Any])
        hooks["Stop"] = (hooks["Stop"] as? [Any] ?? []).reversed()
        after[HookSpec.hooksKey] = hooks

        let report = SettingsAudit.preservation(
            before: SettingsFixture.object, after: after, command: SettingsFixture.ourCommand)
        #expect(!report.isClean)
    }
}
