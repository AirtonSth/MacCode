import Foundation

/// Reads the advertised app version from the main bundle at runtime.
///
/// Using CFBundleShortVersionString ensures the Bonjour TXT record and any
/// other network-facing version field stay in sync with the bundle without
/// requiring a code change on every release.
enum AppVersion {
    /// Returns CFBundleShortVersionString from Bundle.main, or "unknown"
    /// when running in a context where the key is absent (e.g. unit tests).
    static var short: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}
