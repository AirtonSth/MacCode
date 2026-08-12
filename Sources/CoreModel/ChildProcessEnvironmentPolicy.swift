import Foundation
import Darwin

/// Removes RemoteCode host-bootstrap state before an environment crosses a
/// child-process boundary. These keys configure the owning GUI process and are
/// never provider, command-wrapper, sidecar, or helper execution context.
public enum ChildProcessEnvironmentPolicy {
    public static let managedIntegrationHomeKey = "RC2_MANAGED_INTEGRATION_HOME"

    /// Consumes bootstrap-only state at the owning process boundary so even
    /// direct `Process()` children that inherit the environment cannot see it.
    public static func consumeHostOnlyKeysFromCurrentProcess(
        unsetEnvironmentVariable: (String) -> Void = { key in
            _ = Darwin.unsetenv(key)
        }
    ) {
        unsetEnvironmentVariable(managedIntegrationHomeKey)
    }

    public static func scrubHostOnlyKeys(
        from environment: [String: String]
    ) -> [String: String] {
        var scrubbed = environment
        scrubbed.removeValue(forKey: managedIntegrationHomeKey)
        return scrubbed
    }
}
