import Foundation

/// Which build is actually running.
///
/// A rebuilt app is only picked up once the running process is replaced, and a stale
/// process looks exactly like a fresh one — several debugging sessions have been spent
/// reading logs from a build that no longer matched the source. The "Stamp build info"
/// build phase writes the commit into the app's Info.plist so the Settings window can
/// say which one this is.
enum BuildInfo {
    /// `MARKETING_VERSION (CURRENT_PROJECT_VERSION)`, e.g. `1.0 (1)`.
    static var version: String {
        let short = string(for: "CFBundleShortVersionString") ?? "—"
        guard let build = string(for: "CFBundleVersion") else { return short }
        return "\(short) (\(build))"
    }

    /// Short commit hash, with a trailing `+` when the working tree had uncommitted
    /// changes. `unknown` when built outside a git checkout — from a source archive,
    /// say — which is a fact worth showing rather than hiding.
    static var commit: String { string(for: "GitCommit") ?? "unknown" }

    static var builtAt: String { string(for: "BuildDate") ?? "—" }

    private static func string(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else { return nil }
        return value
    }
}
