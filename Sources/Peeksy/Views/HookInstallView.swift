import PeeksyCore
import SwiftUI

/// The approval sheet.
///
/// Everything the user needs to say yes to is on screen at once: the file, the
/// command string that will be written into it, a count of what is preserved,
/// and the diff itself. The diff is the point — a "this is safe, trust me"
/// dialog for somebody else's config file is not consent.
struct HookInstallView: View {
    @Bindable var model: HookInstallModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            field("Settings", model.settingsPath)
            field("Hook command", model.command)
            if let preview = model.preview, preview.audit.isClean {
                Text(preview.audit.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(12)
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .ready:
            diff
        case .nothingToDo:
            message(
                symbol: "checkmark.circle",
                title: model.action == .install ? "Already installed." : "Not installed.",
                detail: "Nothing to change.")
        case let .done(backup):
            done(backup: backup)
        case let .refused(reason):
            message(symbol: "exclamationmark.triangle", title: "Nothing was written.", detail: reason)
        }
    }

    private var diff: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(colour(for: line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .background(background(for: line))
                }
            }
            .padding(8)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var diffLines: [String] {
        (model.preview?.diff ?? "").components(separatedBy: "\n")
    }

    /// Additions green, removals red. A removal in an install diff is the one
    /// thing a reader must not be able to miss.
    private func colour(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
        if line.hasPrefix("@@") { return .secondary }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        return .primary
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return Color.green.opacity(0.10) }
        if line.hasPrefix("-") { return Color.red.opacity(0.12) }
        return .clear
    }

    private func message(symbol: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title).font(.system(size: 13, weight: .medium))
            }
            ScrollView {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func done(backup: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(model.action == .install ? "Hook installed." : "Hook removed.")
                    .font(.system(size: 13, weight: .medium))
            }
            if let status = model.scriptStatus {
                field("Script", "\(SupportPaths.hookScript().path) — \(status)")
            }
            if let backup {
                field("Backup", backup)
            }
            if model.action == .install {
                Text("""
                    New Claude Code sessions pick this up automatically. A session that is \
                    already running needs to be restarted, or `/hooks` to reload.
                    """)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if model.preview != nil {
                // The "copy the JSON instead" escape hatch, present on every
                // screen where there is something to copy. Somebody who does not
                // want our writer near their file must always have a way out
                // that does not involve trusting it.
                Button("Copy merged JSON") { model.copyJSON() }
                if case .ready = model.stage {
                    Button("Copy diff") { model.copyDiff() }
                }
            }
            Button("Reveal settings.json") { model.revealSettings() }

            Spacer()

            switch model.stage {
            case .ready:
                Button("Cancel") { model.close() }
                    .keyboardShortcut(.cancelAction)
                Button(model.action == .install ? "Install" : "Remove") { model.apply() }
                    .keyboardShortcut(.defaultAction)
            case .nothingToDo, .done, .refused:
                Button("Close") { model.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }
}
