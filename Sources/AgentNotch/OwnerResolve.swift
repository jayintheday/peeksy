import AgentNotchCore
import AppKit

/// The AppKit half of `SystemAppActivator.Resolve`: "is this pid an
/// application, and if so which one?"
///
/// The mirror image of `systemParentPid`, which `AgentNotchCore` can supply
/// because it is pure `sysctl`. This one needs AppKit, so it lives on this side
/// of the split line and is injected — that is what keeps the whole ppid walk
/// testable with literals.
///
/// Shared by the running app and by `--doctor` deliberately. They ask the same
/// question and must not be able to answer it differently: a diagnostic that
/// disagrees with the app is worse than no diagnostic.
let systemOwnerResolve: SystemAppActivator.Resolve = { pid in
    guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
    return OwningApp(
        pid: pid,
        bundleID: app.bundleIdentifier,
        localizedName: app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)",
        // `.regular` is the whole test: a Dock tile and a place in ⌘-Tab.
        //
        // Electron spawns its renderers, extension hosts and pty hosts from
        // nested helper BUNDLES, so each one is an `NSRunningApplication` in its
        // own right — `.accessory`, bundle ID `com.github.Electron.helper`
        // (shared by every Electron app on the machine, so useless as identity),
        // localized name `"Cursor Helper (Plugin): extension-host (retrieval)
        // venture-spark-showcase [1-3]"`, and a bundle URL inside
        // `Cursor.app/Contents/Frameworks`. Treating one as the owner is how a
        // session got that string as its label and a Finder alert on click.
        isUserFacing: app.activationPolicy == .regular
    )
}
