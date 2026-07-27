import PeeksyCore
import Foundation

/// This build, read once from our own bundle.
///
/// The AppKit-side half of `BuildInfo`: Core does the parsing (and is tested on
/// it), this supplies the dictionary. Resolved once — `Bundle.main` cannot
/// change under a running process, and `--doctor` and `/v1/health` must never
/// be able to disagree about which build they belong to.
enum AppBuild {
    static let info = BuildInfo.from(infoDictionary: Bundle.main.infoDictionary)
}
