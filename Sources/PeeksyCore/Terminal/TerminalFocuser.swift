import Foundation

// MARK: - Runner seam

/// The one process-spawning seam, isolated so `TerminalFocuser` is testable
/// without ever touching AppleScript or TCC.
public protocol OsascriptRunning: Sendable {
    /// Runs `script` and returns its raw STDOUT.
    ///
    /// Throws `OsascriptError.failed(status:stderr:)` carrying STDERR TEXT, not a
    /// `localizedDescription` — the TCC markers live in stderr and nowhere else.
    func run(_ script: String, timeout: TimeInterval) throws -> String
}

public enum OsascriptError: Error, Sendable {
    case failed(status: Int32, stderr: String)
    case timedOut
    case launchFailed(String)
}

/// Spawns `/usr/bin/osascript` directly — no shell anywhere, so nothing in a
/// script body can ever be re-interpreted as a command.
///
/// Deliberately NOT `NSAppleScript`: `executeAndReturnError:` is synchronous with
/// no timeout and no cancellation, so a beachballing Terminal would freeze the
/// hover UI with no way out. TCC attribution is identical either way — Apple-event
/// responsibility is inherited by the spawning process — so `NSAppleScript` buys
/// nothing and costs us the watchdog.
public struct SystemOsascript: OsascriptRunning {
    public init() {}

    public func run(_ script: String, timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw OsascriptError.launchFailed(String(describing: error))
        }

        let state = RunState(process: process)

        // Drain both pipes concurrently. A serial read deadlocks the moment the
        // child writes more than the 64 KiB pipe buffer to the stream we are not
        // reading yet — and a TCC failure is exactly the case that produces
        // stderr while stdout stays empty.
        let sink = OutputSink()
        let group = DispatchGroup()
        let readQueue = DispatchQueue(label: "com.vijaypatel.peeksy.osascript.read",
                                      attributes: .concurrent)
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        readQueue.async(group: group) { sink.setStdout(outHandle.readDataToEndOfFile()) }
        readQueue.async(group: group) { sink.setStderr(errHandle.readDataToEndOfFile()) }

        // Watchdog: SIGTERM at `timeout`, SIGKILL a second later if it ignored us.
        let watchdogQueue = DispatchQueue.global(qos: .userInitiated)
        let killItem = DispatchWorkItem { state.killIfRunning() }
        let terminateItem = DispatchWorkItem {
            if state.terminateIfRunning() {
                watchdogQueue.asyncAfter(deadline: .now() + 1.0, execute: killItem)
            }
        }
        watchdogQueue.asyncAfter(deadline: .now() + timeout, execute: terminateItem)

        group.wait()
        process.waitUntilExit()
        state.markFinished()
        terminateItem.cancel()
        killItem.cancel()

        if state.timedOut { throw OsascriptError.timedOut }

        let status = process.terminationStatus
        guard status == 0 else {
            throw OsascriptError.failed(status: status, stderr: sink.stderrText)
        }
        return sink.stdoutText
    }
}

/// Lock-guarded output buffers — the two reader closures are `@Sendable` and
/// cannot capture plain `var`s.
private final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func setStdout(_ d: Data) { lock.lock(); out = d; lock.unlock() }
    func setStderr(_ d: Data) { lock.lock(); err = d; lock.unlock() }

    var stdoutText: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: out, as: UTF8.self)
    }
    var stderrText: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: err, as: UTF8.self)
    }
}

/// Guards the watchdog against signalling a process that has already exited
/// (whose pid the kernel is free to reuse).
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var finished = false
    private var didTimeOut = false

    init(process: Process) { self.process = process }

    var timedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return didTimeOut
    }

    func markFinished() {
        lock.lock(); finished = true; lock.unlock()
    }

    /// Returns true if it actually signalled, i.e. the kill escalation is warranted.
    func terminateIfRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished, process.isRunning else { return false }
        didTimeOut = true
        process.terminate()
        return true
    }

    func killIfRunning() {
        lock.lock(); defer { lock.unlock() }
        guard !finished, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }
}

// MARK: - Outcome

public enum FocusOutcome: Sendable, Equatable {
    case focused
    case notFound
    case unknownTty
    case terminalNotRunning
    case blockedByTCC(remedy: String)
    case failed(String)
}

// MARK: - Focuser

/// Brings the Terminal window/tab owning a given tty to the front.
///
/// Never throws and never blocks on user interaction: a click that cannot be
/// honoured degrades into a `FocusOutcome`, and a TCC denial logs its remedy once
/// and then stays quiet for the rest of the process lifetime.
public final class TerminalFocuser: @unchecked Sendable {
    private let runner: OsascriptRunning
    private let isTerminalRunning: @Sendable () -> Bool
    private let log: @Sendable (String) -> Void
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var didWarnTCCStorage = false

    public init(run: OsascriptRunning = SystemOsascript(),
                isTerminalRunning: @escaping @Sendable () -> Bool,
                log: @escaping @Sendable (String) -> Void = { _ in },
                timeout: TimeInterval = 5.0) {
        self.runner = run
        self.isTerminalRunning = isTerminalRunning
        self.log = log
        self.timeout = timeout
    }

    /// One-shot latch: true once a TCC denial has been reported.
    public private(set) var didWarnTCC: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return didWarnTCCStorage
        }
        set {
            lock.lock(); defer { lock.unlock() }
            didWarnTCCStorage = newValue
        }
    }

    /// NEVER throws. Safe to call from any thread.
    public func focus(tty: String?) -> FocusOutcome {
        // Guard 1: nothing to aim at — don't pay for a process spawn.
        guard let normalized = normalizeTty(tty) else { return .unknownTty }

        // Guard 2: `tell application "Terminal"` LAUNCHES Terminal if it isn't
        // running. Without this check, clicking a stale row after quitting
        // Terminal would spawn a fresh empty window — worse than doing nothing.
        // The NSWorkspace lookup is injected from the executable target so this
        // module stays AppKit-free.
        guard isTerminalRunning() else { return .terminalNotRunning }

        let script = buildFocusScript(normalizedTty: normalized)
        do {
            let output = try runner.run(script, timeout: timeout)
            switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "ok": return .focused
            case "notfound": return .notFound
            case let other: return .failed("unexpected osascript output: \(other)")
            }
        } catch let error as OsascriptError {
            switch error {
            case let .failed(status, stderr):
                if Tcc.isTccError(stderr) { return blocked() }
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failed("osascript exited \(status): \(detail)")
            case .timedOut:
                return .failed("osascript timed out after \(timeout)s")
            case let .launchFailed(message):
                return .failed("could not launch osascript: \(message)")
            }
        } catch {
            let message = String(describing: error)
            if Tcc.isTccError(message) { return blocked() }
            return .failed(message)
        }
    }

    /// Latch, log once, carry on. Never modal, never fatal — a denied Automation
    /// grant must not take the app down or nag on every click.
    private func blocked() -> FocusOutcome {
        lock.lock()
        let isFirst = !didWarnTCCStorage
        didWarnTCCStorage = true
        lock.unlock()
        if isFirst { log(Tcc.remedy) }
        return .blockedByTCC(remedy: Tcc.remedy)
    }
}
