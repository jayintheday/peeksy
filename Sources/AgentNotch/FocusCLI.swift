import AppKit
import Foundation
import AgentNotchCore

/// Which UI to build. Parsed from argv, applied by `AppDelegate`.
enum LaunchMode {
    /// M3: the notch window.
    case notch
    /// M2: the plain draggable panel, kept on disk and reachable via `--slice`.
    ///
    /// The notch is the one component whose failure mode is "you cannot see or
    /// click anything at all", which is indistinguishable from the app being
    /// dead. A known-good fallback UI turns that into a one-flag diagnosis.
    case slice
}

/// Headless entry points, handled before any UI is built.
///
/// `main.swift` calls this as its very first statement:
///
///     if let code = FocusCLI.run(CommandLine.arguments) { exit(code) }
///
/// so `--focus`, `--doctor` and `--geometry` never spin up a menu-bar app, a
/// panel or a socket.
enum FocusCLI {
    /// Returns an exit code if it handled the args, nil if it did not.
    static func run(_ args: [String]) -> Int32? {
        let arguments = Array(args.dropFirst())

        if let index = arguments.firstIndex(of: "--focus") {
            let tty = index + 1 < arguments.count ? arguments[index + 1] : nil
            return focus(tty: tty)
        }
        // Before --doctor and before anything that builds UI. The installer
        // touches ~/.claude/settings.json and must never share a process with a
        // running socket server or a window.
        if let code = InstallCLI.run(arguments) {
            return code
        }
        if arguments.contains("--doctor") {
            return doctor()
        }
        if arguments.contains("--geometry") {
            return MainActor.assumeIsolated { geometry(verbose: true) }
        }
        if arguments.contains("--notch-harness") {
            return MainActor.assumeIsolated { notchHarness() }
        }
        return nil
    }

    /// `--slice` is NOT handled by `run` — it does not exit, it selects a UI.
    static func launchMode(_ args: [String]) -> LaunchMode {
        args.contains("--slice") ? .slice : .notch
    }

    // MARK: - Terminal liveness

    /// Injected into `TerminalFocuser` so `AgentNotchCore` never imports AppKit.
    /// Also the guard that stops `tell application "Terminal"` from launching a
    /// Terminal that the user has deliberately quit.
    private static let terminalBundleID = "com.apple.Terminal"

    private static func isTerminalRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == terminalBundleID }
    }

    // MARK: - --focus

    private static func focus(tty: String?) -> Int32 {
        guard let tty, !tty.hasPrefix("--") else {
            printErr("usage: AgentNotch --focus <tty>   (e.g. ttys003 or /dev/ttys003)")
            return 1
        }

        let focuser = TerminalFocuser(isTerminalRunning: isTerminalRunning,
                                      log: { message in printErr(message) })
        let outcome = focuser.focus(tty: tty)
        print(describe(outcome))
        return outcome == .focused ? 0 : 1
    }

    private static func describe(_ outcome: FocusOutcome) -> String {
        switch outcome {
        case .focused:
            return "focused"
        case .notFound:
            return "notfound: no Terminal tab is attached to that tty (session probably ended)"
        case .unknownTty:
            return "unknowntty: no usable tty was recorded for that session"
        case .terminalNotRunning:
            return "terminalnotrunning: Terminal.app is not running"
        case let .blockedByTCC(remedy):
            return "blocked: \(remedy)"
        case let .failed(message):
            return "failed: \(message)"
        }
    }

    // MARK: - --doctor

    /// Exit code 0 unless Automation is actively blocked, so `doctor.sh` is
    /// scriptable.
    private static func doctor() -> Int32 {
        var blocked = false

        print("AgentNotch doctor")
        print("")

        // 1. Socket. Recomputed inline rather than importing SocketPath so this
        //    file stays decoupled from the ingest side of the app; the rule below
        //    must stay identical to it.
        let socket = resolvedSocketPath()
        print("socket path:      \(socket)")
        if let override = ProcessInfo.processInfo.environment["AGENT_NOTCH_SOCK"], !override.isEmpty {
            print("                  (from $AGENT_NOTCH_SOCK)")
        }
        print("socket exists:    \(describeSocket(at: socket))")
        print("")

        // 2. Terminal.
        let terminalRunning = isTerminalRunning()
        print("Terminal.app:     \(terminalRunning ? "running" : "not running")")
        print("")

        // 3. Live agent sessions, as the hook would see them.
        let sessions = claudeProcesses()
        if sessions.isEmpty {
            print("claude processes: none found")
        } else {
            print("claude processes:")
            for session in sessions {
                let tty = normalizeTty(session.tty) ?? "(no tty)"
                print("  pid \(session.pid)  tty \(tty)")
            }
        }
        print("")

        // 4. Automation probe. Skipped when Terminal is not running — probing
        //    would launch it, which is precisely what this app must never do.
        if terminalRunning {
            do {
                let output = try SystemOsascript()
                    .run("tell application \"Terminal\" to return (count of windows) as text", timeout: 5.0)
                let count = output.trimmingCharacters(in: .whitespacesAndNewlines)
                print("automation probe: ok (Terminal reports \(count) window(s))")
            } catch let OsascriptError.failed(status, stderr) {
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if Tcc.isTccError(stderr) {
                    blocked = true
                    print("automation probe: BLOCKED (exit \(status))")
                    print("  \(detail)")
                } else {
                    print("automation probe: failed (exit \(status))")
                    print("  \(detail)")
                }
            } catch OsascriptError.timedOut {
                print("automation probe: timed out after 5s (is Terminal beachballing?)")
            } catch {
                print("automation probe: failed (\(error))")
            }
        } else {
            print("automation probe: skipped — Terminal.app is not running, and probing")
            print("                  it would launch it.")
        }

        // 5. Notch geometry. Numbers only — deliberately. Everything a human
        //    needs to check the window's placement and layering is a rect, and a
        //    picture of somebody's screen is not a diagnostic this app is
        //    entitled to take.
        print("")
        _ = MainActor.assumeIsolated { geometry(verbose: false) }

        if blocked {
            print("")
            print(Tcc.remedy)
            print("")
            print("If AgentNotch does not appear under Automation, or you have rebuilt the")
            print("app (ad-hoc signing changes the cdhash every build), reset the grant with:")
            print("  tccutil reset AppleEvents com.vijaypatel.agentnotch")
        }

        return blocked ? 1 : 0
    }

    // MARK: - --geometry

    /// Print the resolved `NotchGeometry` for every attached display, check the
    /// invariant, and dry-run one hover transition through the real FSM.
    ///
    /// This exists so the window's placement can be verified WITHOUT anybody
    /// capturing an image of the screen. Rects, an invariant verdict and a
    /// state-machine trace are strictly more informative than a screenshot and
    /// cost nobody their privacy.
    @MainActor
    private static func geometry(verbose: Bool) -> Int32 {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            print("notch geometry:   no screens attached")
            return 1
        }

        var ok = true
        // A representative expanded panel: three single-line rows under the
        // header. The real content height comes from `NotchListMetrics`.
        let threeRows = NotchListMetrics.headerHeight
            + 3 * NotchListMetrics.rowHeight
            + 2 * NotchListMetrics.separatorHeight

        for screen in screens {
            let metrics = ScreenMetrics(
                displayID: ScreenMetricsReader.displayID(of: screen),
                frame: screen.frame,
                auxLeftWidth: screen.auxiliaryTopLeftArea?.width ?? 0,
                auxRightWidth: screen.auxiliaryTopRightArea?.width ?? 0,
                safeAreaTop: screen.safeAreaInsets.top
            )
            let resolved = NotchGeometryResolver.resolve(
                screen: metrics, listContentHeight: threeRows)

            print("notch geometry:   \(screen.localizedName)")
            print(resolved.description)

            let report = NotchGeometryResolver.check(resolved)
            if report.isSatisfied {
                print("  invariant       OK (collapsedFrame == notchRect ∪ pillHotRect)")
            } else {
                ok = false
                print("  invariant       FAILED")
                for violation in report.violations { print("    \(violation)") }
            }

            if verbose {
                print(simulateTransition(resolved))
            }
        }
        return ok ? 0 : 1
    }

    /// Drive `HoverEngineCore` with synthetic samples and report the frames the
    /// window would take. No pointer is moved and no window is created.
    @MainActor
    private static func simulateTransition(_ g: NotchGeometry) -> String {
        var core = HoverEngineCore()
        let zones = g.hoverZones
        let inside = CGPoint(x: g.pillRect.midX, y: g.pillRect.midY)
        let outside = CGPoint(x: g.screenFrame.midX, y: g.screenFrame.midY - 200)
        var lines: [String] = ["  transition dry-run"]

        func note(_ label: String, _ effects: [HoverEffect]) {
            let frame = core.phase == .collapsed ? g.collapsedFrame : g.expandedFrame
            let effect = effects.map { $0 == .expand ? "expand" : "collapse" }.joined(separator: ",")
            lines.append("    "
                + label.padding(toLength: 22, withPad: " ", startingAt: 0)
                + core.phase.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)
                + String(format: "frame=%.0fx%.0f", frame.width, frame.height)
                + (effect.isEmpty ? "" : "  → \(effect)"))
        }

        note("start", [])
        // Slow entry: two samples 60 ms apart, well under the velocity gate.
        note("enter pill t=0.00", core.pointer(inside, at: 0.00, zones: zones))
        note("dwelling t=0.06", core.pointer(inside, at: 0.06, zones: zones))
        note("dwell fires t=0.19", core.tick(0.19))
        note("leave t=0.30", core.pointer(outside, at: 0.30, zones: zones))
        note("grace fires t=0.56", core.tick(0.56))

        // And the gate: a fast traverse restarts rather than accumulating.
        var fast = HoverEngineCore()
        _ = fast.pointer(CGPoint(x: g.pillRect.minX - 300, y: g.pillRect.midY), at: 0, zones: zones)
        _ = fast.pointer(inside, at: 0.05, zones: zones) // ≈6000 pt/s
        let armedAt = fast.dwellDeadline ?? -1
        lines.append(String(
            format: "    velocity gate         speed=%.0f pt/s, dwell re-armed at t=%.3f",
            fast.lastSpeed, armedAt))
        return lines.joined(separator: "\n")
    }

    // MARK: - --notch-harness

    /// Drive a REAL `NotchController` through expand → pin → collapse and print
    /// the window frame at each step.
    ///
    /// The frame ORDERING is the one part of M3 with no pure equivalent: whether
    /// the window grows on frame 1 and shrinks only after the content has
    /// settled is a fact about AppKit, not about arithmetic. The alternative way
    /// to observe it is to drag the user's pointer across their screen, which is
    /// intrusive, unreproducible, and would move their windows around.
    ///
    /// Starts NO socket server — `FocusCLI` runs before any of that exists — so
    /// it cannot collide with a running instance.
    @MainActor
    private static func notchHarness() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let store = SessionStore(
            focuser: TerminalFocuser(isTerminalRunning: isTerminalRunning, log: { _ in }),
            activator: SystemAppActivator(resolve: { _ in nil }, activate: { _ in false }),
            ownerLookup: { _ in nil }
        )
        let controller = NotchController(store: store)
        controller.start()

        func report(_ label: String) {
            let frame = controller.debugPanelFrame ?? .zero
            print(String(
                format: "  %@ phase=%@ frame=x%.0f y%.0f %.0fx%.0f mask=%d",
                label.padding(toLength: 26, withPad: " ", startingAt: 0),
                controller.phase.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0),
                frame.minX, frame.minY, frame.width, frame.height,
                controller.debugMask.count))
        }

        print("notch harness")
        var failures = 0
        let pointer = NSEvent.mouseLocation
        print(String(format: "  pointer at x%.0f y%.0f", pointer.x, pointer.y))
        // A status item's window reports a degenerate frame until the run loop
        // has placed it, so give it a turn before asking. `nil` after that is
        // the app's ONLY signal for menu-bar-hidden / full-screen / status-item
        // overflow, and it means `orderOut`; nil on an ordinary desktop would
        // mean the app hides itself the first time anything re-resolves geometry.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let anchorFrame = controller.debugAnchorFrame {
            print(String(format: "  anchor    x%.0f y%.0f %.0fx%.0f on %@",
                         anchorFrame.minX, anchorFrame.minY,
                         anchorFrame.width, anchorFrame.height,
                         controller.debugAnchorScreen ?? "?"))
        } else {
            print("  anchor    NIL — the app would order itself out")
            failures += 1
        }
        report("start")

        let collapsed = controller.geometry?.collapsedFrame ?? .zero
        let expanded = controller.geometry?.expandedFrame ?? .zero

        controller.togglePin()
        report("after togglePin")
        // GROW happens on frame 1, synchronously, before anything animates.
        if controller.debugPanelFrame != expanded {
            print("  FAIL: expected the window to grow to \(expanded) immediately")
            failures += 1
        }
        // Two rects while open: the pill and the list.
        if controller.debugMask.count != 2 {
            print("  FAIL: expected pill+list in the mask while pinned")
            failures += 1
        }

        controller.collapse()
        report("immediately after collapse")
        // SHRINK is deferred. If the window shrank here, SwiftUI would clip the
        // list away instead of animating it — window layers always mask to bounds.
        if controller.debugPanelFrame != expanded {
            print("  FAIL: the window shrank before the content had animated")
            failures += 1
        }
        if controller.debugMask.count != 1 {
            print("  FAIL: the list is still clickable during the fade-out")
            failures += 1
        }

        // Long enough for the spring to settle plus the watchdog's slack.
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        report("after settle")
        if controller.phase == .collapsed {
            if controller.debugPanelFrame != collapsed {
                print("  FAIL: expected the settled frame to be \(collapsed)")
                failures += 1
            }
        } else {
            // The pointer is resting on the pill, so the dwell re-opened us
            // during the settle window. That is the exact race `frameEpoch`
            // exists for: the stale collapse completion must NOT land on top of
            // the fresh expansion. Assert that instead — it is the more valuable
            // observation of the two.
            print("  note: the pointer is dwelling on the pill, so the panel re-opened")
            if controller.debugPanelFrame != expanded {
                print("  FAIL: a stale collapse settle shrank the window under expanded content")
                failures += 1
            }
        }

        controller.stop()
        print(failures == 0 ? "  OK: grow is immediate, shrink is deferred, settle lands" : "  \(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }

    // MARK: - Doctor helpers

    private static func resolvedSocketPath() -> String {
        if let override = ProcessInfo.processInfo.environment["AGENT_NOTCH_SOCK"], !override.isEmpty {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/AgentNotch/hook.sock")
            .path
    }

    private static func describeSocket(at path: String) -> String {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: path) else {
            return "no (nothing at that path — is AgentNotch running?)"
        }
        let type = attributes[.type] as? FileAttributeType
        if type == .typeSocket { return "yes (socket)" }
        return "PATH EXISTS BUT IS NOT A SOCKET (\(type?.rawValue ?? "unknown"))"
    }

    private struct AgentProcess {
        let pid: String
        let tty: String
    }

    /// `ps -Ao pid=,tty=,args=` — a doctor-grade heuristic, not a registry.
    private static func claudeProcesses() -> [AgentProcess] {
        guard let output = shellPS() else { return [] }
        var found: [AgentProcess] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3 else { continue }
            let pid = String(fields[0])
            let tty = String(fields[1])
            let command = fields.dropFirst(2).joined(separator: " ")
            guard isClaudeCommand(command) else { continue }
            found.append(AgentProcess(pid: pid, tty: tty))
        }
        return found
    }

    private static func isClaudeCommand(_ command: String) -> Bool {
        let lowered = command.lowercased()
        guard lowered.contains("claude") else { return false }
        // Don't report ourselves, the doctor invocation, or the hook.
        if lowered.contains("agentnotch") || lowered.contains("agent-notch") { return false }
        return true
    }

    private static func shellPS() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pid=,tty=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func printErr(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
