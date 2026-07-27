import Foundation

/// Everything a human needs to decide whether to approve the change.
///
/// A value type of strings, so the CLI and the SwiftUI sheet render exactly the
/// same thing and neither can grow its own opinion about what the change is.
public struct HookInstallPreview: Sendable {
    public enum Action: String, Sendable { case install, uninstall }

    public let action: Action
    public let settingsPath: String
    /// The exact string that goes into `settings.json`.
    public let command: String
    /// Canonicalised current contents. Also the TOCTOU baseline: `apply`
    /// refuses if the file no longer matches this.
    public let beforeText: String
    public let afterText: String
    /// Unified diff of the two above. Empty when there is nothing to do.
    public let diff: String
    public let audit: SettingsAudit.Report
    public let outcomes: [SettingsMerge.EventOutcome]
    /// Whether the settings file existed at all.
    public let settingsExisted: Bool

    public var isNoOp: Bool { diff.isEmpty }

    /// One line describing the change, e.g. `9 events to register · 0 already
    /// present`.
    public var headline: String {
        let added = outcomes.filter { $0.disposition == .added }.count
        let repaired = outcomes.filter { $0.disposition == .repaired }.count
        let removed = outcomes.filter { $0.disposition == .removed }.count
        let unchanged = outcomes.filter { $0.disposition == .unchanged }.count

        switch action {
        case .install:
            if added == 0 && repaired == 0 { return "Already installed — nothing to change." }
            var parts = ["\(added) event\(added == 1 ? "" : "s") to register"]
            if repaired > 0 { parts.append("\(repaired) to repair") }
            if unchanged > 0 { parts.append("\(unchanged) already present") }
            return parts.joined(separator: " · ")
        case .uninstall:
            if removed == 0 { return "Not installed — nothing to change." }
            return "\(removed) event\(removed == 1 ? "" : "s") to unregister"
        }
    }
}

/// Reads, merges, audits, previews and installs. The only orchestration point;
/// the pieces below it are all pure or narrowly IO.
public struct HookInstaller: Sendable {
    public let settingsURL: URL
    public let command: String

    public init(
        settingsURL: URL = SupportPaths.claudeSettings(),
        command: String = HookSpec.shellQuoted(SupportPaths.hookScript().path)
    ) {
        self.settingsURL = settingsURL
        self.command = command
    }

    // MARK: - Preview

    public func preview(_ action: HookInstallPreview.Action = .install) throws -> HookInstallPreview {
        let existing = try SettingsIO.read(settingsURL)
        let before = existing ?? [:]

        let plan: SettingsMerge.Plan
        switch action {
        case .install: plan = try SettingsMerge.install(into: before, command: command)
        case .uninstall: plan = try SettingsMerge.uninstall(from: before, command: command)
        }

        let audit = SettingsAudit.preservation(before: before, after: plan.merged, command: command)
        // Both sides through the SAME serializer. That is the whole trick: the
        // key reordering `JSONSerialization` imposes appears on both sides and
        // cancels, so the diff shows the merge and nothing else.
        let beforeText = try SettingsIO.canonicalText(before)
        let afterText = try SettingsIO.canonicalText(plan.merged)

        return HookInstallPreview(
            action: action,
            settingsPath: settingsURL.path,
            command: command,
            beforeText: beforeText,
            afterText: afterText,
            diff: UnifiedDiff.between(
                beforeText, afterText,
                fromLabel: settingsURL.lastPathComponent + " (current)",
                toLabel: settingsURL.lastPathComponent + " (after)"),
            audit: audit,
            outcomes: plan.outcomes,
            settingsExisted: existing != nil
        )
    }

    // MARK: - Apply

    /// Write the change the preview described.
    ///
    /// Recomputes from disk rather than trusting the preview's `afterText`: a
    /// GUI sheet can sit open for minutes, and `claude` itself writes to this
    /// file. If the file moved underneath us we stop and say so, because the
    /// diff the user approved is no longer the diff they would get.
    @discardableResult
    public func apply(_ preview: HookInstallPreview, now: Date = Date()) throws -> URL? {
        let current = try SettingsIO.read(settingsURL) ?? [:]
        guard try SettingsIO.canonicalText(current) == preview.beforeText else {
            throw Failure.changedOnDisk(settingsURL.path)
        }

        let plan: SettingsMerge.Plan
        switch preview.action {
        case .install: plan = try SettingsMerge.install(into: current, command: command)
        case .uninstall: plan = try SettingsMerge.uninstall(from: current, command: command)
        }

        let command = self.command
        return try SettingsIO.write(plan.merged, to: settingsURL, now: now) { written in
            // Runs against the bytes on disk, re-parsed. Anything that goes
            // wrong between the merge and here — serializer, short write, full
            // disk — is caught while the original file is still in place.
            var reasons: [String] = []
            let report = SettingsAudit.preservation(before: current, after: written, command: command)
            reasons.append(contentsOf: report.violations)
            if SettingsAudit.canonical(written) != SettingsAudit.canonical(plan.merged) {
                reasons.append("the file we wrote does not match the merge we previewed")
            }
            guard reasons.isEmpty else { throw SettingsIO.Failure.verificationFailed(reasons) }
        }
    }

    // MARK: - Probe

    /// "Is every one of the nine events registered to this exact command?"
    ///
    /// Read-only, cheap enough for the 15 s reap tick, and deliberately stricter
    /// than a substring scan: a half-finished install — five events of nine, or
    /// a `Notification` group carrying a matcher — reads as NOT installed, which
    /// is the only answer that gets the user to fix it.
    public func isInstalled() -> Bool {
        guard let settings = try? SettingsIO.read(settingsURL) ?? [:],
              let plan = try? SettingsMerge.install(into: settings, command: command)
        else { return false }
        return plan.isNoOp
    }

    // MARK: - Errors

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case changedOnDisk(String)

        public var description: String {
            switch self {
            case let .changedOnDisk(path):
                return "\(path) changed on disk since the preview was taken — nothing was written. "
                    + "Take a fresh preview and look at it again."
            }
        }
    }
}
