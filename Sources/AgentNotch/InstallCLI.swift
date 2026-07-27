import AgentNotchCore
import Foundation

/// The headless half of the hook installer.
///
/// `scripts/install_hook.sh` is a five-line wrapper around this, so there is
/// exactly one implementation of the merge and one of the preview — a shell
/// script that built its own `jq` pipeline would be a second, subtly different
/// answer to the highest-blast-radius question in the project.
///
/// Runs from `FocusCLI.run`, i.e. before any UI, any socket and any window
/// server registration exists.
enum InstallCLI {

    // MARK: - Entry

    /// Returns an exit code if it handled the args, `nil` if it did not.
    static func run(_ arguments: [String]) -> Int32? {
        if arguments.contains("--install-hook") { return install(arguments, action: .install) }
        if arguments.contains("--uninstall-hook") { return install(arguments, action: .uninstall) }
        if arguments.contains("--print-hook-json") { return printJSON(arguments) }
        return nil
    }

    // MARK: - Options

    /// A message for the user, in `Error` clothing so it fits `Result`.
    struct Complaint: Error, CustomStringConvertible {
        let description: String
    }

    private struct Options {
        var yes = false
        var dryRun = false
        var settingsURL = SupportPaths.claudeSettings()
        /// `nil` means "the standard ~/.agent-notch path, synced from the bundle".
        var hookPath: String?
    }

    private static func parse(_ arguments: [String]) -> Result<Options, Complaint> {
        var options = Options()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--yes", "-y":
                options.yes = true
            case "--dry-run":
                options.dryRun = true
            case "--settings":
                guard let value = value(after: index, in: arguments) else {
                    return .failure(Complaint(description: "--settings needs a path"))
                }
                options.settingsURL = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
                index += 1
            case "--hook-path":
                guard let value = value(after: index, in: arguments) else {
                    return .failure(Complaint(description: "--hook-path needs a path"))
                }
                options.hookPath = (value as NSString).expandingTildeInPath
                index += 1
            case "--install-hook", "--uninstall-hook", "--print-hook-json":
                break
            case let unknown where unknown.hasPrefix("-"):
                return .failure(Complaint(description: "unknown option \(unknown)"))
            default:
                return .failure(Complaint(description: "unexpected argument \(arguments[index])"))
            }
            index += 1
        }
        return .success(options)
    }

    private static func value(after index: Int, in arguments: [String]) -> String? {
        let next = index + 1
        guard next < arguments.count, !arguments[next].hasPrefix("--") else { return nil }
        return arguments[next]
    }

    // MARK: - Install / uninstall

    private static func install(_ arguments: [String], action: HookInstallPreview.Action) -> Int32 {
        let options: Options
        switch parse(arguments) {
        case let .success(parsed): options = parsed
        case let .failure(complaint): return usage(complaint.description)
        }

        // `--hook-path` names a script the caller manages; anything else is the
        // copy in ~/.agent-notch that we own and keep in step with the bundle.
        let managingScript = options.hookPath == nil && action == .install
        let command = HookSpec.shellQuoted(options.hookPath ?? SupportPaths.hookScript().path)

        print("AgentNotch — \(action.rawValue) hook")
        print("")
        print("  settings   \(options.settingsURL.path)")
        print("  command    \(command)")
        if options.hookPath != nil {
            print("             (--hook-path: this script is yours, not synced from the bundle)")
        }
        print("")

        let installer = HookInstaller(settingsURL: options.settingsURL, command: command)

        let preview: HookInstallPreview
        do {
            preview = try installer.preview(action)
        } catch {
            return fail(describe(error), hint: escapeHatch(options))
        }

        print("  \(preview.headline)")
        print("  \(preview.audit.summary)")
        if !preview.audit.isClean {
            print("")
            print("  REFUSING: the merge would not preserve this file:")
            for violation in preview.audit.violations { print("    \(violation)") }
            return 1
        }
        print("")

        guard !preview.isNoOp else {
            print("Nothing to do.")
            return 0
        }

        print(preview.diff)
        print("")

        if options.dryRun {
            print("(--dry-run: nothing was written, and no script was installed)")
            return 0
        }

        guard confirm(options) else {
            print("Cancelled — nothing was written.")
            return 1
        }

        // The script lands on disk BEFORE settings.json points at it, and only
        // once the user has said yes. The other order leaves a window where
        // Claude Code is registered against a file that does not exist, which is
        // a hook error on the user's very next turn.
        var scriptOutcome: HookScriptSync.Outcome?
        if managingScript {
            switch syncScript(to: SupportPaths.hookScript()) {
            case let .success(outcome): scriptOutcome = outcome
            case let .failure(complaint): return fail(complaint.description)
            }
        }

        do {
            let backup = try installer.apply(preview)
            print("")
            if let scriptOutcome { print("  script     \(describe(scriptOutcome))") }
            print("  written    \(options.settingsURL.path)")
            if let backup { print("  backup     \(backup.path)") }
            print("")
            if action == .install {
                print("New Claude Code sessions pick this up automatically. A session that is")
                print("already running needs to be restarted, or `/hooks` to reload.")
            }
            return 0
        } catch {
            return fail(describe(error), hint: escapeHatch(options))
        }
    }

    // MARK: - --print-hook-json

    /// The escape hatch. If anything about the writer is not trusted, this
    /// prints exactly what would have been written and the user pastes it in
    /// themselves — no backup, no rename, no code of ours near their file.
    private static func printJSON(_ arguments: [String]) -> Int32 {
        let options: Options
        switch parse(arguments) {
        case let .success(parsed): options = parsed
        case let .failure(complaint): return usage(complaint.description)
        }

        let command = HookSpec.shellQuoted(options.hookPath ?? SupportPaths.hookScript().path)
        do {
            let preview = try HookInstaller(settingsURL: options.settingsURL, command: command)
                .preview(.install)
            print(preview.afterText, terminator: "")
            return 0
        } catch {
            return fail(describe(error))
        }
    }

    // MARK: - Script location

    static func syncScript(to destination: URL) -> Result<HookScriptSync.Outcome, Complaint> {
        guard let source = bundledHookURL() else {
            return .failure(Complaint(description: """
                cannot find \(SupportPaths.bundledHookName). Build the app bundle first:
                  ./scripts/build_app.sh
                """))
        }
        do {
            return .success(try HookScriptSync.sync(from: source, to: destination))
        } catch {
            return .failure(Complaint(description: describe(error)))
        }
    }

    /// The script shipped with this binary.
    ///
    /// Inside a bundle it is a resource. Under `swift run` there is no bundle,
    /// so walk up from the executable looking for the repo's `hooks/` directory
    /// — a developer running `swift run --install-hook` should not be told to
    /// build a bundle first.
    static func bundledHookURL() -> URL? {
        let fm = FileManager.default

        if let resources = Bundle.main.resourceURL {
            let candidate = resources.appendingPathComponent(SupportPaths.bundledHookName)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }

        var directory = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            guard let current = directory else { break }
            let candidate = current
                .appendingPathComponent("hooks")
                .appendingPathComponent(SupportPaths.bundledHookName)
            if fm.fileExists(atPath: candidate.path) { return candidate }
            directory = current.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Console

    private static func confirm(_ options: Options) -> Bool {
        if options.yes { return true }
        // Never block on a pipe. A CI run or a `| tee` would otherwise hang
        // forever waiting for a keystroke that is not coming.
        guard isatty(FileHandle.standardInput.fileDescriptor) == 1 else {
            printErr("stdin is not a terminal — re-run with --yes to write, or --dry-run to preview.")
            return false
        }
        print("Write these changes to \(options.settingsURL.lastPathComponent)? [y/N] ", terminator: "")
        guard let line = readLine(strippingNewline: true)?.lowercased() else { return false }
        return line == "y" || line == "yes"
    }

    private static func escapeHatch(_ options: Options) -> String {
        """
        You can install by hand instead — this prints the exact merged file:
          AgentNotch --print-hook-json --settings \(options.settingsURL.path)
        """
    }

    /// `String(describing:)` already prefers `CustomStringConvertible`, which
    /// every failure type in the install module conforms to.
    private static func describe(_ error: Error) -> String {
        String(describing: error)
    }

    private static func describe(_ outcome: HookScriptSync.Outcome) -> String {
        switch outcome {
        case .created: return "installed"
        case .updated: return "updated from the app bundle"
        case .upToDate: return "up to date"
        }
    }

    private static func fail(_ message: String, hint: String? = nil) -> Int32 {
        printErr("")
        printErr("error: \(message)")
        if let hint {
            printErr("")
            printErr(hint)
        }
        return 1
    }

    private static func usage(_ message: String) -> Int32 {
        printErr("error: \(message)")
        printErr("")
        printErr("usage:")
        printErr("  AgentNotch --install-hook   [--yes] [--dry-run] [--settings PATH] [--hook-path PATH]")
        printErr("  AgentNotch --uninstall-hook [--yes] [--dry-run] [--settings PATH]")
        printErr("  AgentNotch --print-hook-json            [--settings PATH] [--hook-path PATH]")
        return 2
    }

    private static func printErr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
