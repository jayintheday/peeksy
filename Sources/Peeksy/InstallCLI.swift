import PeeksyCore
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
        var agent: AgentHookConfiguration = .claudeCode
        var settingsOverride: URL?
        var settingsURL: URL { settingsOverride ?? agent.settingsURL() }
        /// `nil` means "the standard ~/.peeksy path, synced from the bundle".
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
            case "--agent":
                guard let value = value(after: index, in: arguments),
                      let agent = AgentHookConfiguration(rawValue: value) else {
                    return .failure(Complaint(description: "--agent must be claude-code or codex"))
                }
                options.agent = agent
                index += 1
            case "--settings":
                guard let value = value(after: index, in: arguments) else {
                    return .failure(Complaint(description: "--settings needs a path"))
                }
                options.settingsOverride = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
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
        // copy in ~/.peeksy that we own and keep in step with the bundle.
        let managingScript = options.hookPath == nil && action == .install
        let command = HookSpec.shellQuoted(options.hookPath ?? options.agent.scriptURL().path)

        print("Peeksy — \(action.rawValue) hook")
        print("")
        print("  settings   \(options.settingsURL.path)")
        print("  command    \(command)")
        if options.hookPath != nil {
            print("             (--hook-path: this script is yours, not synced from the bundle)")
        }
        print("")

        let installer = options.agent.installer(settings: options.settingsURL, command: command)

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
            if managingScript && !options.dryRun {
                if case let .failure(complaint) = syncScript(to: options.agent.scriptURL(), agent: options.agent) {
                    return fail(complaint.description)
                }
            }
            print("No configuration changes needed.")
            if action == .install { print(options.agent.instructions) }
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
            switch syncScript(to: options.agent.scriptURL(), agent: options.agent) {
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
                print(options.agent.instructions)
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

        let command = HookSpec.shellQuoted(options.hookPath ?? options.agent.scriptURL().path)
        do {
            // OUR block only — never the merged file. See `HookSpec.snippet`.
            // It follows that this path no longer reads settings.json at all,
            // so it cannot fail on a settings file that is missing or broken,
            // which is exactly when somebody reaches for this flag.
            print(try SettingsIO.canonicalText(HookSpec.snippet(command: command, events: options.agent.events)), terminator: "")
            return 0
        } catch {
            return fail(describe(error))
        }
    }

    // MARK: - Script location

    static func syncScript(to destination: URL, agent: AgentHookConfiguration = .claudeCode) -> Result<HookScriptSync.Outcome, Complaint> {
        guard let source = bundledHookURL(agent: agent) else {
            return .failure(Complaint(description: """
                cannot find \(agent.scriptName). Build the app bundle first:
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
    static func bundledHookURL(agent: AgentHookConfiguration = .claudeCode) -> URL? {
        let fm = FileManager.default

        if let resources = Bundle.main.resourceURL {
            let candidate = resources.appendingPathComponent(agent.scriptName)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }

        var directory = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            guard let current = directory else { break }
            let candidate = current
                .appendingPathComponent("hooks")
                .appendingPathComponent(agent.scriptName)
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
        You can install by hand instead — this prints the block to merge into
        the "hooks" object of \(options.settingsURL.lastPathComponent):
          Peeksy --print-hook-json --agent \(options.agent.rawValue)
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
        printErr("usage (all modes accept --agent claude-code|codex; default claude-code):")
        printErr("  Peeksy --install-hook   [--yes] [--dry-run] [--settings PATH] [--hook-path PATH]")
        printErr("  Peeksy --uninstall-hook [--yes] [--dry-run] [--settings PATH]")
        printErr("  Peeksy --print-hook-json            [--hook-path PATH]")
        return 2
    }

    private static func printErr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
