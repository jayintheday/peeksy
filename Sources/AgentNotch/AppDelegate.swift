import AgentNotchCore
import AppKit
import Dispatch
import Foundation

/// Owns everything with a lifetime: the socket server, the store, the window and
/// the signal handlers.
///
/// The whole app is single-threaded apart from two seams, both of which are here:
/// the socket's io queue (which only ever hops one envelope to the main actor)
/// and the focus queue inside `SessionStore`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let ioQueue = DispatchQueue(label: "com.agentnotch.io")
    private let socketURL = SocketPath.resolve()

    private var store: SessionStore?
    private var server: UnixSocketServer?
    /// The M3 UI. Nil in `--slice` mode.
    private var notch: NotchController?
    /// The M2 UI, kept reachable behind `--slice`.
    ///
    /// A known-good fallback while the notch is being tuned: the notch is the
    /// only part of this app whose failure mode is "you cannot see or click
    /// anything", and having no way back to a plain window would make a bad
    /// geometry bug indistinguishable from a dead app.
    private var sliceWindow: SliceWindow?
    /// Built on first use. An approval sheet for somebody's settings file has no
    /// business existing before they ask for one.
    private var installWindow: HookInstallWindow?
    private var signalSources: [DispatchSourceSignal] = []

    private let terminalBundleID = "com.apple.Terminal"
    private let mode: LaunchMode

    init(mode: LaunchMode) {
        self.mode = mode
        super.init()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let activator = Self.makeActivator()
        let store = SessionStore(
            focuser: TerminalFocuser(
                isTerminalRunning: { [terminalBundleID] in
                    NSWorkspace.shared.runningApplications
                        .contains { $0.bundleIdentifier == terminalBundleID }
                },
                log: { message in uiLog.error("\(message, privacy: .public)") }
            ),
            activator: activator,
            ownerLookup: { pid in activator.owner(ofPid: pid)?.localizedName }
        )
        self.store = store

        // THE ONE CROSS-ACTOR EDGE. Everything the socket learns enters the app
        // right here and nowhere else; downstream of this hop the whole model is
        // main-actor confined and needs no locks.
        let counts = store.sessionCounts
        // `open … --args --capture <path>` is the only reliable way to switch
        // this on for a bundled app: `open` does not pass the shell's env.
        let capture = EventCapture.resolve()
        if let capture {
            uiLog.info("capturing raw hook payloads to \(capture.url.path, privacy: .public)")
        }
        let router = EventRouter(
            capture: capture,
            deliver: { envelope in
                Task { @MainActor in store.ingest(envelope) }
            },
            sessionCount: { counts.current }
        )

        let server = UnixSocketServer(path: socketURL, queue: ioQueue) { request in
            router.respond(to: request)
        }

        do {
            try server.start()
        } catch let error as UnixSocketServer.StartError {
            // No modal. An incumbent instance is the NORMAL failure here (a
            // double-launch from Finder), and a dialog in front of a working app
            // is worse than a log line — the other instance keeps the socket.
            return fail(describe(error))
        } catch {
            return fail("could not start server: \(error)")
        }
        self.server = server

        uiLog.info("listening on \(self.socketURL.path, privacy: .public)")

        store.startReaping()
        refreshInstalledHookScript()
        bootstrapRunningSessions(into: store)

        switch mode {
        case .notch:
            let notch = NotchController(store: store)
            notch.onInstallHookRequested = { [weak self] in self?.showInstallSheet() }
            notch.start()
            self.notch = notch
        case .slice:
            uiLog.info("--slice: using the M2 window instead of the notch")
            let window = SliceWindow(store: store) { [weak self] in self?.showInstallSheet() }
            window.show()
            self.sliceWindow = window
        }

        installSignalHandlers(server: server)
    }

    // MARK: - Cold start

    /// Ask the system what was already running, off the main thread.
    ///
    /// Deliberately AFTER `server.start()`. The scan takes tens of milliseconds
    /// and hook events are the better source for anything it would find, so the
    /// ingest path must be open first — `SessionRegistry.seed` then skips every
    /// pid and tty a hook has already claimed.
    private func bootstrapRunningSessions(into store: SessionStore) {
        let scanner = ProcessScanner()
        ioQueue.async {
            let found = scanner.scan()
            guard !found.isEmpty else { return }
            Task { @MainActor in store.bootstrap(found) }
        }
    }

    // MARK: - Hook

    /// Keep the installed script in step with this build.
    ///
    /// `settings.json` names a stable Application Support path rather than one
    /// inside the bundle, precisely so a rebuild cannot delete it out from under
    /// Claude Code. The cost of that stability is that the copy can go stale, so
    /// it is refreshed here — but ONLY when the hook is already registered.
    /// Writing a script nobody asked for, into a directory the user has not
    /// opted into, is not something a launch should do.
    private func refreshInstalledHookScript() {
        guard HookProbe.isInstalled() else { return }
        switch InstallCLI.syncScript(to: SupportPaths.hookScript()) {
        case let .success(outcome) where outcome != .upToDate:
            uiLog.info("hook script \(outcome.rawValue, privacy: .public) from the app bundle")
        case .success:
            break
        case let .failure(complaint):
            uiLog.error("could not refresh the hook script: \(complaint.description, privacy: .public)")
        }
    }

    private func showInstallSheet() {
        let window = installWindow ?? HookInstallWindow()
        installWindow = window
        window.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        notch?.stop()
        store?.stopReaping()
        server?.stop() // unlinks the socket file
    }

    /// The panel is closable and there is no Dock icon to reopen from, but an
    /// accessory app that quits when its window closes would take the ingest
    /// server down with it and silently stop recording sessions.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Activation seam

    /// The AppKit half of `SystemAppActivator`, injected so `AgentNotchCore`
    /// stays AppKit-free — the same shape as `TerminalFocuser`'s
    /// `isTerminalRunning`.
    private static func makeActivator() -> SystemAppActivator {
        SystemAppActivator(
            resolve: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
                return OwningApp(
                    pid: pid,
                    bundleID: app.bundleIdentifier,
                    localizedName: app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
                )
            },
            activate: { owner in
                guard let app = NSRunningApplication(processIdentifier: owner.pid) else { return false }

                // LaunchServices is the PRIMARY path, not a fallback.
                //
                // `NSRunningApplication.activate` cannot be trusted here. Since
                // macOS 14 the window server ignores cross-app activation from a
                // process that is not itself frontmost, and we are `.accessory`
                // so we never are. Worse, it still returns `true` — which is
                // exactly why the first version of this looked like it worked and
                // silently did nothing. Re-opening an already-running bundle goes
                // through LaunchServices, which is not subject to that
                // restriction, and never starts a second copy.
                guard let bundleURL = app.bundleURL else {
                    return app.activate(options: [.activateAllWindows])
                }

                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true

                // Runs on `focusQueue`, never the main actor (see
                // SessionStore.focus), so a bounded wait here cannot stall the UI
                // and buys us an honest return value instead of an optimistic one.
                let done = DispatchSemaphore(value: 0)
                // Safe without a lock: the semaphore establishes happens-before
                // between the write in the completion handler and the read below.
                let result = ActivationResultBox()
                NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { running, error in
                    if let error {
                        uiLog.error("openApplication failed: \(error.localizedDescription, privacy: .public)")
                    }
                    result.ok = (running != nil && error == nil)
                    done.signal()
                }
                guard done.wait(timeout: .now() + 3) == .success else { return false }
                return result.ok
            }
        )
    }

    // MARK: - Signals

    /// Ctrl-C from a terminal launch, and `kill` from a script, both have to
    /// unlink the socket. A leftover socket file makes the NEXT launch look like
    /// a double-launch until the takeover probe runs.
    private func installSignalHandlers(server: UnixSocketServer) {
        for sig in [SIGINT, SIGTERM] {
            // The default disposition has to go first or the process dies before
            // the DispatchSource ever fires.
            signal(sig, SIG_IGN)
            // Deliberately NOT the io queue: `stop()` does a `queue.sync` onto
            // it, which would deadlock against an in-flight request.
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            // `@Sendable` IS LOad-BEARING. `DispatchSourceHandler` is a bare
            // `@convention(block) () -> Void` with no `@Sendable`, so a closure
            // written inside this `@MainActor` type silently INHERITS main-actor
            // isolation — and libdispatch then calls it on a root queue, which
            // trips `swift_task_checkIsolated` and takes the process out with
            // SIGTRAP. Observed: every Ctrl-C crashed and left the socket file
            // behind. `@Sendable` opts the closure out of inheriting isolation.
            source.setEventHandler { @Sendable in
                server.stop() // closes the listener and unlinks the socket file
                FileHandle.standardError.write(Data("agent-notch stopped\n".utf8))
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Errors

    private func describe(_ error: UnixSocketServer.StartError) -> String {
        switch error {
        case let .alreadyRunning(pid):
            let who = pid.map { " (pid \($0))" } ?? ""
            return "another agent-notch is already listening on \(socketURL.path)\(who) — leaving it alone"
        case let .pathTooLong(bytes):
            return "socket path is \(bytes) bytes, over the \(SocketPath.sunPathLimit)-byte sun_path limit: \(socketURL.path)"
        case let .posix(code, call):
            return "\(call) failed: \(String(cString: strerror(code))) (errno \(code))"
        }
    }

    private func fail(_ message: String) {
        uiLog.error("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("agent-notch: \(message)\n".utf8))
        // No window has been created yet, so there is nothing to tear down and
        // nothing on screen to explain. Exit is the honest outcome.
        exit(1)
    }
}

/// One-shot result cell for `NSWorkspace.openApplication`'s completion handler.
///
/// `@unchecked Sendable` is honest here: the only write happens before the
/// semaphore signal and the only read after the corresponding wait, so the
/// semaphore supplies the ordering a lock would.
private final class ActivationResultBox: @unchecked Sendable {
    var ok = false
}
