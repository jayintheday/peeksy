import Foundation
import Testing
@testable import PeeksyCore

// MARK: - Test doubles

private final class MockOsascript: OsascriptRunning, @unchecked Sendable {
    enum Behaviour: Sendable {
        case succeed(String)
        case fail(Error)
    }

    private let lock = NSLock()
    private let behaviour: Behaviour
    private var calls: [String] = []

    init(_ behaviour: Behaviour) { self.behaviour = behaviour }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls.count
    }

    var lastScript: String? {
        lock.lock(); defer { lock.unlock() }
        return calls.last
    }

    func run(_ script: String, timeout: TimeInterval) throws -> String {
        lock.lock()
        calls.append(script)
        lock.unlock()
        switch behaviour {
        case let .succeed(output): return output
        case let .fail(error): throw error
        }
    }
}

private final class LogSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return lines.count
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    func record(_ line: String) {
        lock.lock(); lines.append(line); lock.unlock()
    }
}

private let tccStderr = "execution error: Not authorized to send Apple events to Terminal. (-1743)"

// MARK: - Tests

@Suite("TerminalFocuser")
struct TerminalFocuserTests {

    @Test("\"ok\" means the tab was found and raised")
    func okIsFocused() {
        let mock = MockOsascript(.succeed("ok"))
        let focuser = TerminalFocuser(run: mock, isTerminalRunning: { true })
        #expect(focuser.focus(tty: "ttys003") == .focused)
        #expect(mock.callCount == 1)
    }

    @Test("trailing newline from osascript is tolerated")
    func okWithNewline() {
        let mock = MockOsascript(.succeed("ok\n"))
        let focuser = TerminalFocuser(run: mock, isTerminalRunning: { true })
        #expect(focuser.focus(tty: "ttys003") == .focused)
    }

    @Test("\"notfound\" means the session's tab is gone, not that we were denied")
    func notfoundIsNotFound() {
        let mock = MockOsascript(.succeed("notfound\n"))
        let focuser = TerminalFocuser(run: mock, isTerminalRunning: { true })
        #expect(focuser.focus(tty: "ttys003") == .notFound)
    }

    @Test("the script the runner receives is built from the NORMALIZED tty")
    func normalizesBeforeBuilding() {
        let mock = MockOsascript(.succeed("ok"))
        let focuser = TerminalFocuser(run: mock, isTerminalRunning: { true })
        #expect(focuser.focus(tty: "  /dev/ttys003 ") == .focused)
        #expect(mock.lastScript?.contains("\"/dev/ttys003\"") == true)
    }

    @Test("unexpected output is a failure, not a silent success")
    func unexpectedOutput() {
        let mock = MockOsascript(.succeed("who knows"))
        let focuser = TerminalFocuser(run: mock, isTerminalRunning: { true })
        guard case let .failed(message) = focuser.focus(tty: "ttys003") else {
            Issue.record("expected .failed")
            return
        }
        #expect(message.contains("who knows"))
    }

    // MARK: - Guards that must run BEFORE any process spawns

    @Test("an unusable tty short-circuits and never spawns osascript", arguments: [
        nil, "", "  ", "??", "?", "-", "/dev/",
    ] as [String?])
    func unknownTtyNeverCallsRunner(_ tty: String?) {
        let mock = MockOsascript(.succeed("ok"))
        let focuser = TerminalFocuser(run: mock, isTerminalRunning: { true })
        #expect(focuser.focus(tty: tty) == .unknownTty)
        #expect(mock.callCount == 0)
    }

    @Test("a quit Terminal short-circuits and never spawns osascript")
    func terminalNotRunningNeverCallsRunner() {
        // Load-bearing: `tell application "Terminal"` LAUNCHES Terminal. Without
        // this guard, clicking a stale row after quitting Terminal would pop open
        // a fresh empty window.
        let mock = MockOsascript(.succeed("ok"))
        let focuser = TerminalFocuser(run: mock, isTerminalRunning: { false })
        #expect(focuser.focus(tty: "ttys003") == .terminalNotRunning)
        #expect(mock.callCount == 0)
    }

    @Test("the tty guard is checked before the Terminal guard")
    func guardOrdering() {
        let mock = MockOsascript(.succeed("ok"))
        let focuser = TerminalFocuser(run: mock, isTerminalRunning: { false })
        #expect(focuser.focus(tty: "??") == .unknownTty)
        #expect(mock.callCount == 0)
    }

    // MARK: - TCC

    @Test("a -1743 stderr becomes .blockedByTCC and latches didWarnTCC")
    func tccBlocked() {
        let mock = MockOsascript(.fail(OsascriptError.failed(status: 1, stderr: tccStderr)))
        let focuser = TerminalFocuser(run: mock, isTerminalRunning: { true })
        #expect(focuser.didWarnTCC == false)
        #expect(focuser.focus(tty: "ttys003") == .blockedByTCC(remedy: Tcc.remedy))
        #expect(focuser.didWarnTCC == true)
    }

    @Test("the remedy is logged exactly once across repeated denials")
    func logsRemedyOnce() {
        let spy = LogSpy()
        let mock = MockOsascript(.fail(OsascriptError.failed(status: 1, stderr: tccStderr)))
        let focuser = TerminalFocuser(run: mock,
                                      isTerminalRunning: { true },
                                      log: { [spy] line in spy.record(line) })

        #expect(focuser.focus(tty: "ttys003") == .blockedByTCC(remedy: Tcc.remedy))
        #expect(focuser.focus(tty: "ttys004") == .blockedByTCC(remedy: Tcc.remedy))

        #expect(spy.count == 1)
        #expect(spy.all.first == Tcc.remedy)
        // The outcome still reports the block every time — only the log is one-shot.
        #expect(mock.callCount == 2)
    }

    @Test("a non-TCC osascript failure stays .failed and does not latch")
    func nonTccFailure() {
        let stderr = "execution error: Terminal got an error: Can't get window 1. (-1728)"
        let mock = MockOsascript(.fail(OsascriptError.failed(status: 1, stderr: stderr)))
        let spy = LogSpy()
        let focuser = TerminalFocuser(run: mock,
                                      isTerminalRunning: { true },
                                      log: { [spy] line in spy.record(line) })

        guard case let .failed(message) = focuser.focus(tty: "ttys003") else {
            Issue.record("expected .failed")
            return
        }
        #expect(message.contains("-1728"))
        #expect(focuser.didWarnTCC == false)
        #expect(spy.count == 0)
    }

    // MARK: - Watchdog + launch failures surface, never throw

    @Test("a timeout becomes .failed rather than propagating")
    func timeoutIsFailed() {
        let mock = MockOsascript(.fail(OsascriptError.timedOut))
        let focuser = TerminalFocuser(run: mock, isTerminalRunning: { true })
        guard case let .failed(message) = focuser.focus(tty: "ttys003") else {
            Issue.record("expected .failed")
            return
        }
        #expect(message.lowercased().contains("timed out"))
        #expect(focuser.didWarnTCC == false)
    }

    @Test("a launch failure becomes .failed")
    func launchFailureIsFailed() {
        let mock = MockOsascript(.fail(OsascriptError.launchFailed("No such file")))
        let focuser = TerminalFocuser(run: mock, isTerminalRunning: { true })
        guard case let .failed(message) = focuser.focus(tty: "ttys003") else {
            Issue.record("expected .failed")
            return
        }
        #expect(message.contains("No such file"))
    }

    @Test("an arbitrary thrown error is contained, not propagated")
    func arbitraryErrorIsFailed() {
        struct Boom: Error {}
        let mock = MockOsascript(.fail(Boom()))
        let focuser = TerminalFocuser(run: mock, isTerminalRunning: { true })
        guard case .failed = focuser.focus(tty: "ttys003") else {
            Issue.record("expected .failed")
            return
        }
    }
}

// MARK: - SystemOsascript

/// Exercises the real `/usr/bin/osascript` with scripts that send NO Apple
/// events — so these never touch Terminal and never provoke a TCC prompt.
@Suite("SystemOsascript")
struct SystemOsascriptTests {

    @Test("stdout comes back verbatim on success")
    func capturesStdout() throws {
        let output = try SystemOsascript().run("return \"ok\"", timeout: 5.0)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
    }

    @Test("a non-zero exit throws .failed carrying raw STDERR, not a localizedDescription")
    func failureCarriesStderr() {
        do {
            _ = try SystemOsascript().run("error \"boom-marker\" number 42", timeout: 5.0)
            Issue.record("expected a throw")
        } catch let OsascriptError.failed(status, stderr) {
            #expect(status != 0)
            // The TCC markers only ever appear in stderr, so this text must be
            // the untouched stream — that is the whole point of the error shape.
            #expect(stderr.contains("boom-marker"))
        } catch {
            Issue.record("expected .failed, got \(error)")
        }
    }

    @Test("a hung script is killed by the watchdog instead of hanging the caller")
    func watchdogTimesOut() {
        let started = Date()
        do {
            _ = try SystemOsascript().run("delay 30", timeout: 0.4)
            Issue.record("expected a throw")
        } catch OsascriptError.timedOut {
            // Must return promptly — a frozen Terminal must not freeze the UI.
            #expect(Date().timeIntervalSince(started) < 5.0)
        } catch {
            Issue.record("expected .timedOut, got \(error)")
        }
    }

    @Test("a script that floods stderr does not deadlock the stdout read")
    func concurrentDrainAvoidsDeadlock() throws {
        // ~70 KiB on stderr (osascript sends `log` there) before a single byte
        // reaches stdout. A serial read — stdout first — wedges here forever once
        // the 64 KiB pipe buffer fills. Deliberately given a generous timeout so
        // a failure shows up as a hang caught by the watchdog, not a flake.
        let script = """
        set payload to "0123456789012345678901234567890123456789012345678901234567890123456789"
        repeat 1000 times
          log payload
        end repeat
        return "ok"
        """
        let output = try SystemOsascript().run(script, timeout: 30.0)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
    }
}
