import Foundation
import ServiceManagement

/// Launch at login, via `SMAppService.mainApp`.
///
/// The whole app is a background observer: it is worth nothing on the morning
/// after a reboot unless something starts it. This is that something.
///
/// **Default OFF.** Registering a login item behind the user's back is the kind
/// of thing menu-bar apps get uninstalled for, so nothing here runs unless the
/// toggle is tapped. macOS surfaces the result in System Settings → General →
/// Login Items, and a disable made THERE is authoritative — `isEnabled` reads
/// the live `status` every time rather than caching a bool we own, precisely so
/// the toggle cannot disagree with System Settings.
///
/// Two facts worth knowing before debugging this:
///
///  1. **Registration is keyed on the bundle's path.** Move or rename the
///     `.app` and the login item points at a bundle that is no longer there.
///     `build_app.sh --install` always writes `~/Applications/AgentNotch.app`,
///     so the ordinary path is stable — but a bundle launched from `dist/` and
///     registered from there will break the moment the next build deletes it.
///  2. **`.requiresApproval` is a success, not a failure.** The registration
///     landed; the user has "Allow in the background" switched off for this app.
///     The remedy is System Settings, not a retry, so it gets its own case.
enum LoginItem {
    enum Status: Equatable {
        case enabled
        case disabled
        /// Registered, but the user has to allow it in System Settings.
        case requiresApproval
        /// `SMAppService` returned something this macOS added after we shipped.
        case unknown
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered, .notFound: return .disabled
        case .requiresApproval: return .requiresApproval
        @unknown default: return .unknown
        }
    }

    /// True when the app will actually start itself at the next login.
    static var isEnabled: Bool { status == .enabled }

    /// Flip the login item, returning the status it settled on.
    ///
    /// Errors are logged and swallowed: failing to register a convenience must
    /// never take down an app whose real job is watching sessions. The returned
    /// status is re-read from `SMAppService` rather than assumed from the call,
    /// so a registration that silently did not take reports honestly.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Status {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let verb = enabled ? "register" : "unregister"
            uiLog.error(
                "login item \(verb, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        let settled = status
        uiLog.info("login item now \(String(describing: settled), privacy: .public)")
        return settled
    }
}
