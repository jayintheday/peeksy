import AppKit
import Foundation

/// The four ways the world moves out from under a window pinned over the menu
/// bar: the display arrangement changes, the machine wakes, the user switches
/// Space, or the screen locks.
///
/// Unlike `DismissMonitor` these are armed for the app's whole lifetime, because
/// they apply in EVERY phase — a Space change with the panel merely peeking is
/// just as wrong as one with it pinned.
@MainActor
final class SystemEventObserver {

    /// Display arrangement changed. Debounced: `didChangeScreenParameters`
    /// arrives in bursts of three to five while the window server settles, and
    /// acting on the first one measures a half-configured display.
    var onGeometryChanged: (() -> Void)?
    /// Wake, and "the panel has probably been sitting there for eight hours".
    var onWake: (() -> Void)?
    /// Space change / sleep / lock — all of them mean "collapse now".
    var onDismiss: (() -> Void)?

    private var tokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []
    private var debounce: Task<Void, Never>?

    private let debounceInterval: Duration = .milliseconds(250)

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter

        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleGeometryChange() }
        })

        tokens.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onWake?()
                self?.scheduleGeometryChange()
            }
        })

        tokens.append(workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDismiss?() }
        })

        tokens.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDismiss?() }
        })

        // Lock has no NSWorkspace notification; the distributed one is the only
        // published signal.
        distributedTokens.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDismiss?() }
        })
        distributedTokens.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onWake?() }
        })
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        let workspace = NSWorkspace.shared.notificationCenter
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
            workspace.removeObserver(token)
        }
        for token in distributedTokens {
            DistributedNotificationCenter.default().removeObserver(token)
        }
        tokens.removeAll()
        distributedTokens.removeAll()
    }

    private func scheduleGeometryChange() {
        debounce?.cancel()
        debounce = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounceInterval)
            guard !Task.isCancelled else { return }
            self.onGeometryChanged?()
        }
    }
}
