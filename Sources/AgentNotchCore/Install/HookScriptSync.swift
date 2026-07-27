import Foundation

/// Keeps the installed hook script in step with the one inside the app bundle.
///
/// The command string registered in `settings.json` is a stable Application
/// Support path (see `SupportPaths`), which is what makes it survive a rebuild —
/// but a stable path with stale contents is its own bug. So the app copies the
/// bundled script over the installed one at launch whenever the bytes differ.
/// Byte comparison rather than mtime: `ditto` and `cp` both preserve
/// timestamps, so mtime says "unchanged" for a script that changed.
public enum HookScriptSync {

    public enum Outcome: String, Sendable, Equatable {
        case created
        case updated
        case upToDate
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case sourceMissing(String)
        case copyFailed(String)

        public var description: String {
            switch self {
            case let .sourceMissing(path):
                return "the hook script is missing from the app bundle (\(path))"
            case let .copyFailed(reason):
                return "could not install the hook script: \(reason)"
            }
        }
    }

    /// Copy `source` to `destination` when they differ, and make it executable.
    @discardableResult
    public static func sync(from source: URL, to destination: URL) throws -> Outcome {
        let fm = FileManager.default

        guard let script = try? Data(contentsOf: source) else {
            throw Failure.sourceMissing(source.path)
        }

        let existed = fm.fileExists(atPath: destination.path)
        if existed,
           let installed = try? Data(contentsOf: destination),
           installed == script,
           isExecutable(destination) {
            return .upToDate
        }

        do {
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // `.atomic` writes a temp file beside the destination and renames it,
            // so a `claude` firing mid-install never sees a half-written script.
            try script.write(to: destination, options: [.atomic])
        } catch {
            throw Failure.copyFailed(error.localizedDescription)
        }

        // Claude Code executes the command directly; without the bit it fails
        // with EACCES on every single hook event.
        guard chmod(destination.path, 0o755) == 0 else {
            throw Failure.copyFailed("chmod 0755 failed with errno \(errno)")
        }

        return existed ? .updated : .created
    }

    private static func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }
}
