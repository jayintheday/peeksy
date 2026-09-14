import PeeksyCore
import AppKit
import Observation
import SwiftUI

// MARK: - Model

/// What the sheet shows and what the buttons do.
///
/// The whole approval flow lives here so the view is a rendering of state and
/// nothing else — a SwiftUI `Button` action that reads and writes
/// `~/.claude/settings.json` inline is not something anyone should have to find
/// by reading a view body.
@MainActor
@Observable
final class HookInstallModel {

    enum Stage: Equatable {
        /// A preview waiting for a decision.
        case ready
        /// Nothing to do — already installed, or already absent.
        case nothingToDo
        /// The write happened. Carries the backup path, if there was one.
        case done(backup: String?)
        /// We refused, or the write failed. Nothing was changed.
        case refused(String)
    }

    private(set) var stage: Stage = .ready
    private(set) var preview: HookInstallPreview?
    private(set) var scriptStatus: String?

    let action: HookInstallPreview.Action
    private var installer: HookInstaller
    var agent: AgentHookConfiguration = .claudeCode {
        didSet { installer = agent.installer(); refresh() }
    }
    private let onClose: () -> Void

    init(
        action: HookInstallPreview.Action = .install,
        installer: HookInstaller = HookInstaller(),
        onClose: @escaping () -> Void
    ) {
        self.action = action
        self.installer = installer
        self.agent = installer.source == .codex ? .codex : .claudeCode
        self.onClose = onClose
        refresh()
    }

    var settingsPath: String { installer.settingsURL.path }
    var command: String { installer.command }

    /// (Re)compute the preview. Read-only — nothing on disk moves here, which is
    /// what makes it safe to call every time the sheet opens.
    func refresh() {
        do {
            let taken = try installer.preview(action)
            preview = taken
            if !taken.audit.isClean {
                stage = .refused(
                    "Refusing to write — the merge would not preserve this file:\n"
                        + taken.audit.violations.map { "• \($0)" }.joined(separator: "\n"))
            } else {
                stage = taken.isNoOp ? .nothingToDo : .ready
            }
        } catch {
            preview = nil
            stage = .refused(String(describing: error))
        }
    }

    func apply() {
        guard let preview else { return }

        // The script goes down first, so settings.json never names a file that
        // is not there. Only after the user has said yes: a cancelled sheet
        // should leave nothing behind.
        if action == .install {
            switch InstallCLI.syncScript(to: agent.scriptURL(), agent: agent) {
            case let .success(outcome):
                scriptStatus = outcome == .upToDate ? "already up to date" : outcome.rawValue
            case let .failure(complaint):
                stage = .refused(complaint.description)
                return
            }
        }

        do {
            let backup = try installer.apply(preview)
            stage = .done(backup: backup?.path)
        } catch {
            stage = .refused(String(describing: error))
        }
    }

    /// The escape hatch: the merged file, verbatim, for a human to paste.
    func copyJSON() {
        guard let preview else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(preview.afterText, forType: .string)
    }

    func copyDiff() {
        guard let preview else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(preview.diff, forType: .string)
    }

    func revealSettings() {
        NSWorkspace.shared.activateFileViewerSelecting([installer.settingsURL])
    }

    func close() { onClose() }
}

// MARK: - Window

/// An ORDINARY window, on purpose.
///
/// Modelled on `SliceWindow`: titled, closable, floating, and shown with
/// `orderFrontRegardless` because an `.accessory` app is never the active app.
/// Deliberately NOT the notch panel — the notch is borderless, non-activating
/// and 380 pt wide, none of which suits a scrollable diff the user has to read
/// carefully before agreeing to it.
@MainActor
final class HookInstallWindow {
    private let panel: NSPanel
    private var model: HookInstallModel?

    private static let size = NSSize(width: 640, height: 560)

    init(action: HookInstallPreview.Action = .install, installer: HookInstaller = HookInstaller()) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = action == .install ? "Install Peeksy hook" : "Remove Peeksy hook"
        panel.level = .floating
        panel.isFloatingPanel = true
        // The app is an LSUIElement accessory, so it is almost never active.
        // Without this the window vanishes the moment focus goes anywhere else —
        // which includes the Finder window that "Reveal" just opened.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let model = HookInstallModel(action: action, installer: installer) { [weak panel] in
            panel?.orderOut(nil)
        }
        self.model = model

        let hosting = NSHostingView(rootView: HookInstallView(model: model))
        // EMPTY sizingOptions. `NSHostingView` otherwise drives the window's
        // size from SwiftUI's ideal size, and a 300-line diff has a very large
        // ideal size — see LEARNINGS, this cost real time once already.
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setContentSize(Self.size)
        panel.center()
    }

    func show() {
        model?.refresh()
        panel.orderFrontRegardless()
        // Take key so the buttons respond on the FIRST click. Without it the
        // first click on an inactive app's window only activates the window.
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { panel.orderOut(nil) }
}
