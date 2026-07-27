import Foundation

/// The merge, as a pure function on a decoded settings object.
///
/// THE HIGHEST-BLAST-RADIUS CODE IN THIS PROJECT. `~/.claude/settings.json`
/// carries hooks for other tools the user depends on; losing one of them breaks
/// software that has nothing to do with us, silently, and the user finds out
/// hours later when a notification never arrives.
///
/// Three rules make that impossible rather than merely unlikely:
///
///  * **`JSONSerialization`, never `Codable`.** A typed model round-trips only
///    the keys it knows about, so every unknown key — and there are nine of them
///    in the real file today — would be dropped on write. Here the object is
///    `[String: Any]` from parse to serialize and unknown data is carried
///    through untouched because nothing ever looks at it.
///  * **Append-only, keyed on the exact command string.** We add groups; we
///    never reorder, rewrite or remove anything we did not write ourselves.
///  * **Refuse rather than guess.** Any shape we do not recognise throws, and
///    the caller writes nothing at all.
public enum SettingsMerge {

    // MARK: - Refusals

    /// A shape we will not touch. Every case means "write nothing".
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case hooksNotAnObject
        case eventNotAnArray(String)
        case groupNotAnObject(event: String, index: Int)

        public var description: String {
            switch self {
            case .hooksNotAnObject:
                return #"the "hooks" value is not a JSON object"#
            case let .eventNotAnArray(event):
                return #"the "hooks.\#(event)" value is not a JSON array"#
            case let .groupNotAnObject(event, index):
                return #"entry \#(index) of "hooks.\#(event)" is not a JSON object"#
            }
        }
    }

    // MARK: - Outcomes

    /// What happened to one event.
    public enum Disposition: String, Sendable, Equatable {
        /// A group of ours was appended.
        case added
        /// Our group was there with the wrong matcher and was rewritten.
        case repaired
        /// Already correct, or our command sits in a group we do not own.
        case unchanged
        /// `uninstall` removed our group.
        case removed
        /// `uninstall` found nothing of ours.
        case absent
    }

    public struct EventOutcome: Sendable, Equatable {
        public let spec: HookEventSpec
        public let disposition: Disposition

        public init(spec: HookEventSpec, disposition: Disposition) {
            self.spec = spec
            self.disposition = disposition
        }
    }

    /// The merged object plus a per-event account of how it got that way.
    ///
    /// Not `Sendable`: `merged` is `[String: Any]`. It never leaves the thread
    /// that computed it — the UI and the CLI both render `HookInstallPreview`,
    /// which is a value type of strings.
    public struct Plan {
        public let merged: [String: Any]
        public let outcomes: [EventOutcome]

        public init(merged: [String: Any], outcomes: [EventOutcome]) {
            self.merged = merged
            self.outcomes = outcomes
        }

        public func events(_ disposition: Disposition) -> [String] {
            outcomes.filter { $0.disposition == disposition }.map(\.spec.event)
        }

        /// Nothing to write. The installer is idempotent, so this is the normal
        /// answer on every run after the first.
        public var isNoOp: Bool {
            outcomes.allSatisfy { $0.disposition == .unchanged || $0.disposition == .absent }
        }
    }

    // MARK: - Ownership

    /// Whose group is this?
    ///
    /// The `shared` case is why this is three-valued rather than a `Bool`. If a
    /// user has hand-merged our command into a group alongside another tool's,
    /// rewriting that group to our canonical shape would delete their hook. We
    /// would rather leave a group in a shape we did not choose than touch one we
    /// do not own.
    enum Ownership: Equatable {
        case notOurs
        /// Every command hook in the group is ours.
        case exclusive
        /// Ours, plus somebody else's.
        case shared
    }

    static func ownership(of group: [String: Any], command: String) -> Ownership {
        guard let hooks = group[HookSpec.hooksKey] as? [Any], !hooks.isEmpty else { return .notOurs }
        var mine = 0
        for entry in hooks {
            guard let hook = entry as? [String: Any] else { continue }
            if hook[HookSpec.commandKey] as? String == command { mine += 1 }
        }
        if mine == 0 { return .notOurs }
        return mine == hooks.count ? .exclusive : .shared
    }

    // MARK: - Install

    /// Add every missing registration. Idempotent.
    public static func install(into settings: [String: Any], command: String) throws -> Plan {
        var root = settings
        var hooks = try hooksObject(in: root)
        var outcomes: [EventOutcome] = []

        for spec in HookSpec.events {
            var groups = try groupArray(in: hooks, event: spec.event)
            let disposition: Disposition

            if let match = try ourGroup(in: groups, event: spec.event, command: command) {
                if match.ownership == .shared {
                    // Somebody hand-merged our command in beside another tool's.
                    // Rewriting that group would delete their hook.
                    disposition = .unchanged
                } else if HookSpec.matcher(of: match.group) == spec.matcher {
                    disposition = .unchanged
                } else {
                    // A wrong matcher means the hook never fires. The group is
                    // ours and ours alone, so rewriting it destroys nothing.
                    groups[match.index] = HookSpec.group(command: command, matcher: spec.matcher)
                    disposition = .repaired
                }
            } else {
                // APPEND, never insert. Foreign groups keep their order and we
                // run last, after whatever was already registered.
                groups.append(HookSpec.group(command: command, matcher: spec.matcher))
                disposition = .added
            }

            outcomes.append(EventOutcome(spec: spec, disposition: disposition))
            hooks[spec.event] = groups
        }

        root[HookSpec.hooksKey] = hooks
        return Plan(merged: root, outcomes: outcomes)
    }

    // MARK: - Uninstall

    /// Remove every group that is exclusively ours, and nothing else.
    public static func uninstall(from settings: [String: Any], command: String) throws -> Plan {
        var root = settings
        var hooks = try hooksObject(in: root)
        var outcomes: [EventOutcome] = []

        // Every event in the file, not just our nine: a stale registration under
        // an event we no longer ask for still has to come out.
        let allEvents = Set(hooks.keys).union(HookSpec.events.map(\.event)).sorted()
        let specByEvent = Dictionary(uniqueKeysWithValues: HookSpec.events.map { ($0.event, $0) })

        for event in allEvents {
            guard hooks[event] != nil else {
                if let spec = specByEvent[event] {
                    outcomes.append(EventOutcome(spec: spec, disposition: .absent))
                }
                continue
            }
            var groups = try groupArray(in: hooks, event: event)
            let before = groups.count

            groups = try groups.enumerated().compactMap { index, raw -> Any? in
                guard let group = raw as? [String: Any] else {
                    throw Refusal.groupNotAnObject(event: event, index: index)
                }
                return ownership(of: group, command: command) == .exclusive ? nil : raw
            }

            let removed = before - groups.count
            if let spec = specByEvent[event] {
                outcomes.append(EventOutcome(spec: spec, disposition: removed > 0 ? .removed : .absent))
            }

            // An event key we emptied goes away entirely. Leaving `"Stop": []`
            // behind would be harmless but it is also litter we created.
            if groups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = groups
            }
        }

        if hooks.isEmpty {
            root.removeValue(forKey: HookSpec.hooksKey)
        } else {
            root[HookSpec.hooksKey] = hooks
        }
        return Plan(merged: root, outcomes: outcomes)
    }

    // MARK: - Shape checks

    /// The `hooks` object, created when absent.
    ///
    /// A missing key is an ordinary first install. A key holding something that
    /// is not an object is a file we do not understand, and we stop.
    private static func hooksObject(in root: [String: Any]) throws -> [String: Any] {
        guard let raw = root[HookSpec.hooksKey] else { return [:] }
        guard let hooks = raw as? [String: Any] else { throw Refusal.hooksNotAnObject }
        return hooks
    }

    private static func groupArray(in hooks: [String: Any], event: String) throws -> [Any] {
        guard let raw = hooks[event] else { return [] }
        guard let groups = raw as? [Any] else { throw Refusal.eventNotAnArray(event) }
        return groups
    }

    struct OwnedGroup {
        let index: Int
        let group: [String: Any]
        let ownership: Ownership
    }

    /// First group containing our command, with how much of it is ours.
    ///
    /// Validates every entry on the way past — not just up to the match — so a
    /// malformed group anywhere in the array is refused before anything is
    /// written rather than after.
    private static func ourGroup(
        in groups: [Any],
        event: String,
        command: String
    ) throws -> OwnedGroup? {
        var found: OwnedGroup?
        for (index, raw) in groups.enumerated() {
            guard let group = raw as? [String: Any] else {
                throw Refusal.groupNotAnObject(event: event, index: index)
            }
            let owned = ownership(of: group, command: command)
            if owned != .notOurs, found == nil {
                found = OwnedGroup(index: index, group: group, ownership: owned)
            }
        }
        return found
    }
}
