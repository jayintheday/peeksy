import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Reading and writing `settings.json` — the only code in this app allowed to
/// write there.
///
/// The write is: serialize → verify → back up → temp file → fsync → verify the
/// bytes on disk → `rename(2)`. Every step exists because of a specific way the
/// naive version loses data:
///
///  * writing in place truncates the file first, so a crash mid-write leaves
///    nothing at all;
///  * `Data.write(.atomic)` is atomic but unverified — it will happily install
///    bytes that no longer parse;
///  * a backup in `/tmp` is on a different filesystem from `~`, which turns a
///    restore into a copy that can itself fail.
public enum SettingsIO {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unreadable(path: String, reason: String)
        case notJSON(path: String)
        case rootNotAnObject(path: String)
        case notSerializable(String)
        /// The bytes we were about to install did not survive a round trip.
        case verificationFailed([String])
        case posix(code: Int32, call: String)

        public var description: String {
            switch self {
            case let .unreadable(path, reason):
                return "cannot read \(path): \(reason)"
            case let .notJSON(path):
                return "\(path) is not valid JSON — refusing to write. Fix or move it first."
            case let .rootNotAnObject(path):
                return "\(path) does not contain a JSON object at the top level — refusing to write."
            case let .notSerializable(detail):
                return "the merged settings could not be serialized: \(detail)"
            case let .verificationFailed(reasons):
                return "the merged settings failed verification, nothing was written:\n  "
                    + reasons.joined(separator: "\n  ")
            case let .posix(code, call):
                return "\(call) failed: \(String(cString: strerror(code))) (errno \(code))"
            }
        }
    }

    // MARK: - Serialization

    /// The one canonical form.
    ///
    /// `.sortedKeys` is not cosmetic — it is what makes the before/after diff
    /// meaningful. `JSONSerialization` cannot preserve the input's key order, so
    /// SOME reordering is unavoidable on write; normalising both sides through
    /// this function means the preview shows the real additions and nothing else.
    /// `.withoutEscapingSlashes` keeps `/Users/...` readable in that diff.
    public static func canonicalData(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw Failure.notSerializable("object contains a value JSON cannot represent")
        }
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A) // trailing newline, so the file ends like every other text file
        return data
    }

    public static func canonicalText(_ object: [String: Any]) throws -> String {
        String(decoding: try canonicalData(object), as: UTF8.self)
    }

    // MARK: - Reading

    /// `nil` when the file does not exist — an ordinary first install.
    /// Anything else that is not a JSON object throws, and the caller writes
    /// nothing.
    public static func read(_ url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Failure.unreadable(path: url.path, reason: error.localizedDescription)
        }

        // An empty file is a real state (a half-finished edit), and treating it
        // as `{}` is friendlier than refusing.
        if data.isEmpty { return [:] }

        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { throw Failure.notJSON(path: url.path) }
        guard let object = any as? [String: Any] else { throw Failure.rootNotAnObject(path: url.path) }
        return object
    }

    // MARK: - Writing

    /// `settings.json.agent-notch-backup-20260727-134501`, in the SAME directory.
    ///
    /// Same directory so a restore is a rename rather than a cross-filesystem
    /// copy, and so the user finds it next to the file it belongs to instead of
    /// somewhere they have to be told about.
    public static func backupURL(for url: URL, now: Date, calendar: Calendar = .current) -> URL {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let stamp = String(
            format: "%04d%02d%02d-%02d%02d%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).agent-notch-backup-\(stamp)")
    }

    /// Install `object` at `url`. Returns the backup's URL, or `nil` when there
    /// was no existing file to back up.
    ///
    /// `verify` is handed the bytes that are about to be renamed into place,
    /// already re-parsed from disk. Throwing from it aborts the write with the
    /// original file untouched.
    @discardableResult
    public static func write(
        _ object: [String: Any],
        to url: URL,
        now: Date = Date(),
        verify: ([String: Any]) throws -> Void
    ) throws -> URL? {
        let data = try canonicalData(object)
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()

        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // Back up BEFORE the temp file exists, so the ordering on disk is
        // "original, original+backup, original+backup+temp, new+backup".
        var backup: URL?
        let originalMode = fileMode(of: url)
        if fm.fileExists(atPath: url.path) {
            let destination = backupURL(for: url, now: now)
            try? fm.removeItem(at: destination)
            do {
                try fm.copyItem(at: url, to: destination)
            } catch {
                throw Failure.unreadable(path: url.path, reason: "could not create a backup: \(error.localizedDescription)")
            }
            backup = destination
        }

        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).agent-notch.\(getpid()).tmp")
        try? fm.removeItem(at: temp)

        do {
            try writeAndSync(data, to: temp)

            // THE VERIFICATION. Read back what is actually on disk — not the
            // `Data` we still hold — so a short write, a full disk or a bad
            // serializer is caught while the original file is still intact.
            let reread = try Data(contentsOf: temp)
            guard let any = try? JSONSerialization.jsonObject(with: reread, options: []),
                  let parsed = any as? [String: Any]
            else { throw Failure.verificationFailed(["the file we wrote does not parse back as a JSON object"]) }
            try verify(parsed)

            if let originalMode { chmod(temp.path, originalMode) }

            guard rename(temp.path, url.path) == 0 else {
                throw Failure.posix(code: errno, call: "rename(2)")
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }

        return backup
    }

    // MARK: - Private

    private static func writeAndSync(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw Failure.posix(code: errno, call: "create(\(url.lastPathComponent))") }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        // Without this the rename can be durable while the contents are not, and
        // a power loss leaves a correctly-named empty file where settings.json used to be.
        guard fsync(handle.fileDescriptor) == 0 else {
            throw Failure.posix(code: errno, call: "fsync")
        }
    }

    private static func fileMode(of url: URL) -> mode_t? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.posixPermissions] as? NSNumber
        else { return nil }
        return mode_t(number.uint16Value)
    }
}
