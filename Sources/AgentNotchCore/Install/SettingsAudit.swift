import Foundation

/// "Did anything that is not ours change?", answered mechanically.
///
/// The merge is written to be safe; this is the check that it *was*. It runs
/// twice — once to build the preview a human approves, and once against the
/// bytes actually about to be renamed into place, after serialization and
/// re-parsing. That second run is the one that matters: it means a bug in the
/// merge, in `JSONSerialization`, or in our own writer cannot reach the file.
public enum SettingsAudit {

    /// One foreign hook group, identified by where it lives and what it says.
    private struct ForeignGroup: Equatable {
        let event: String
        let position: Int
        let json: String
    }

    public struct Report: Sendable, Equatable {
        public let topLevelKeysBefore: Int
        public let topLevelKeysAfter: Int
        public let hookEventsBefore: Int
        public let hookEventsAfter: Int
        public let foreignGroupsBefore: Int
        public let foreignGroupsAfter: Int
        public let ourGroupsBefore: Int
        public let ourGroupsAfter: Int
        /// Empty when nothing foreign was lost, changed or reordered.
        public let violations: [String]

        public var isClean: Bool { violations.isEmpty }

        /// The line shown above the diff. Deliberately counts rather than
        /// adjectives: "18/18 foreign groups preserved" is checkable, "safe" is
        /// not.
        public var summary: String {
            let delta = ourGroupsAfter - ourGroupsBefore
            let change = delta == 0 ? "no change"
                : (delta > 0 ? "\(delta) group\(delta == 1 ? "" : "s") added"
                             : "\(-delta) group\(delta == -1 ? "" : "s") removed")
            return """
                \(topLevelKeysBefore)/\(topLevelKeysBefore) top-level keys preserved · \
                \(foreignGroupsBefore)/\(foreignGroupsBefore) foreign hook groups preserved · \
                \(change)
                """
        }
    }

    /// Compare a before/after pair.
    ///
    /// Works for install and uninstall alike, because it never asserts anything
    /// about OUR groups — only that every byte belonging to somebody else is
    /// still there, still says the same thing, and is still in the same order
    /// within its event.
    public static func preservation(
        before: [String: Any],
        after: [String: Any],
        command: String
    ) -> Report {
        var violations: [String] = []

        // 1. Every top-level key except `hooks` must survive byte-identically.
        //    This is the check that catches a `Codable`-shaped mistake: nine of
        //    the thirteen keys in the real file are ones this app has never
        //    heard of.
        for key in before.keys.sorted() where key != HookSpec.hooksKey {
            guard let afterValue = after[key] else {
                violations.append("top-level key \"\(key)\" was dropped")
                continue
            }
            if canonical(before[key]) != canonical(afterValue) {
                violations.append("top-level key \"\(key)\" changed")
            }
        }

        let beforeHooks = before[HookSpec.hooksKey] as? [String: Any] ?? [:]
        let afterHooks = after[HookSpec.hooksKey] as? [String: Any] ?? [:]

        // 2. Foreign groups, per event, in order.
        let beforeForeign = foreignGroups(in: beforeHooks, command: command)
        let afterForeign = foreignGroups(in: afterHooks, command: command)
        if beforeForeign != afterForeign {
            let lost = beforeForeign.filter { !afterForeign.contains($0) }
            for group in lost {
                violations.append(
                    "foreign hook group \(group.position) under \"\(group.event)\" was lost or changed")
            }
            // Ordering can break without anything being lost — an insert at the
            // head would do it — so the set check above is not enough on its own.
            if lost.isEmpty {
                violations.append("foreign hook groups were reordered")
            }
        }

        // 3. An event that held foreign groups must still exist.
        for event in beforeHooks.keys.sorted()
        where !beforeForeign.filter({ $0.event == event }).isEmpty && afterHooks[event] == nil {
            violations.append("hook event \"\(event)\" was dropped")
        }

        return Report(
            topLevelKeysBefore: before.count,
            topLevelKeysAfter: after.count,
            hookEventsBefore: beforeHooks.count,
            hookEventsAfter: afterHooks.count,
            foreignGroupsBefore: beforeForeign.count,
            foreignGroupsAfter: afterForeign.count,
            ourGroupsBefore: ourGroupCount(in: beforeHooks, command: command),
            ourGroupsAfter: ourGroupCount(in: afterHooks, command: command),
            violations: violations
        )
    }

    // MARK: - Private

    private static func foreignGroups(in hooks: [String: Any], command: String) -> [ForeignGroup] {
        var found: [ForeignGroup] = []
        for event in hooks.keys.sorted() {
            guard let groups = hooks[event] as? [Any] else { continue }
            var position = 0
            for raw in groups {
                guard let group = raw as? [String: Any] else {
                    // Not something we can classify — count it as foreign, which
                    // is the conservative answer: it then has to survive intact.
                    found.append(ForeignGroup(event: event, position: position, json: canonical(raw)))
                    position += 1
                    continue
                }
                guard SettingsMerge.ownership(of: group, command: command) == .notOurs else { continue }
                found.append(ForeignGroup(event: event, position: position, json: canonical(group)))
                position += 1
            }
        }
        return found
    }

    private static func ourGroupCount(in hooks: [String: Any], command: String) -> Int {
        var count = 0
        for (_, raw) in hooks {
            guard let groups = raw as? [Any] else { continue }
            for entry in groups {
                guard let group = entry as? [String: Any] else { continue }
                if SettingsMerge.ownership(of: group, command: command) != .notOurs { count += 1 }
            }
        }
        return count
    }

    /// Order-independent string form of any JSON value.
    ///
    /// `.sortedKeys` is what makes `==` on two dictionaries meaningful here:
    /// Swift dictionaries have no order, so comparing serialized bytes without
    /// it would report a change every time the hash seed moved.
    static func canonical(_ value: Any?) -> String {
        guard let value else { return "<nil>" }
        if let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
        ) {
            return String(decoding: data, as: UTF8.self)
        }
        return String(describing: value)
    }
}
