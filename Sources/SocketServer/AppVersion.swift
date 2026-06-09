import Foundation

/// Reads the advertised app version from the main bundle at runtime.
///
/// SocketServer is a standalone module with no dependency on AppShell, so this
/// helper is defined independently here. Both modules read Bundle.main, which
/// refers to the same running process bundle at runtime.
///
/// Using CFBundleShortVersionString ensures the /v1/discovery "version" field
/// stays in sync with the bundle without requiring a code change on every
/// release.
enum AppVersion {
    /// Returns CFBundleShortVersionString from Bundle.main, or "unknown"
    /// when running in a context where the key is absent (e.g. unit tests).
    static var short: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}
