import Foundation

/// Which build is this, actually?
///
/// `CFBundleShortVersionString` answers a different question — the RELEASE
/// name, typed by a human and changed a few times a year. It cannot tell you
/// whether the app you are looking at came from the last `build_app.sh` or from
/// one three weeks ago, and this app makes that easy to get wrong: it is an
/// `LSUIElement` accessory with no window to check, `open` silently activates an
/// already-running instance rather than launching the new one, and the answer
/// has already cost real time once.
///
/// So `build_app.sh` stamps the commit and the build time into the bundle, and
/// this reads them back. **`dirty` is the one that matters most day to day** —
/// this project is habitually built from an uncommitted working tree, so
/// "which commit" is only half an answer.
///
/// Pure by construction: it parses a dictionary, not a `Bundle`, so the tests
/// never need one. The app hands it `Bundle.main.infoDictionary`.
public struct BuildInfo: Sendable, Equatable {
    /// Info.plist keys. Custom keys must not begin with `CF`/`NS` — those
    /// prefixes are Apple's, and a collision is a silent misparse rather than
    /// an error.
    public enum Key {
        public static let marketingVersion = "CFBundleShortVersionString"
        public static let commit = "PeeksyCommit"
        public static let dirty = "PeeksyDirty"
        public static let builtAt = "PeeksyBuildDate"
    }

    /// The release name. Hand-typed, rarely changes.
    public let marketingVersion: String
    /// Short git SHA, or `nil` when the build was not made from a git checkout
    /// (a source tarball) or not made by `build_app.sh` at all (`swift run`,
    /// the test target).
    public let commit: String?
    /// The build included changes that were not committed.
    public let dirty: Bool
    /// Free-form, as written by the build script. Never parsed — only shown.
    public let builtAt: String?

    public init(marketingVersion: String, commit: String?, dirty: Bool, builtAt: String?) {
        self.marketingVersion = marketingVersion
        self.commit = commit
        self.dirty = dirty
        self.builtAt = builtAt
    }

    /// What a build that was never stamped reports. Not an error state: running
    /// from `swift run` or inside the test target is ordinary, and claiming a
    /// commit there would be a lie.
    public static let unstamped = BuildInfo(
        marketingVersion: fallbackVersion, commit: nil, dirty: false, builtAt: nil)

    /// The version to report when the bundle does not say. Deliberately the one
    /// place in the codebase this string is written — `build_app.sh` passes its
    /// own `VERSION` through the plist, so the two cannot silently disagree
    /// about a build that IS stamped.
    public static let fallbackVersion = "0.2.0"

    /// Parse an `Info.plist` dictionary. Anything missing degrades; nothing throws.
    public static func from(infoDictionary: [String: Any]?) -> BuildInfo {
        guard let info = infoDictionary else { return .unstamped }

        let version = (info[Key.marketingVersion] as? String)?.trimmed.nonEmpty ?? fallbackVersion
        let commit = (info[Key.commit] as? String)?.trimmed.nonEmpty

        // The script writes a string, because a plist written by `cat` has no
        // real booleans. Accept what a plist editor would produce too.
        let dirty: Bool
        switch info[Key.dirty] {
        case let flag as Bool: dirty = flag
        case let text as String: dirty = ["true", "yes", "1"].contains(text.lowercased())
        default: dirty = false
        }

        return BuildInfo(
            marketingVersion: version,
            commit: commit,
            dirty: dirty,
            builtAt: (info[Key.builtAt] as? String)?.trimmed.nonEmpty)
    }

    /// One token, for `/v1/health` and anywhere else that wants it inline.
    ///
    ///     0.2.0+dcb9111          committed
    ///     0.2.0+dcb9111.dirty    built over uncommitted work
    ///     0.2.0+dev              not stamped
    public var short: String {
        guard let commit else { return "\(marketingVersion)+dev" }
        return "\(marketingVersion)+\(commit)\(dirty ? ".dirty" : "")"
    }

    /// A line for a human, for `--doctor`.
    public var summary: String {
        guard let commit else {
            return "\(marketingVersion) (dev build — not stamped by build_app.sh)"
        }
        var detail = commit
        if dirty { detail += ", with uncommitted changes" }
        if let builtAt { detail += ", built \(builtAt)" }
        return "\(marketingVersion) (\(detail))"
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmpty: String? { isEmpty ? nil : self }
}
