/// Version constants and string builder for the rc2 CLI.
///
/// Single-source-of-truth for the CLI and protocol versions so that
/// `--version` output, help text, and any future telemetry all agree.
public enum RC2CLIVersion {

    /// Semantic version of the rc2 CLI binary itself.
    public static let currentCLIVersion: String = "1.0.0"

    /// JSON-RPC protocol version spoken by the rc2 ↔ daemon socket.
    public static let currentProtocolVersion: String = "2.0"

    /// Build a one-line version string for `rc2 --version`.
    ///
    /// - Parameters:
    ///   - cliVersion:      CLI binary version.
    ///   - protocolVersion: RPC protocol version.
    /// - Returns: Single-line string, e.g. `"rc2 1.0.0  protocol 2.0"`.
    public static func versionString(
        cliVersion: String = currentCLIVersion,
        protocolVersion: String = currentProtocolVersion
    ) -> String {
        "rc2 \(cliVersion)  protocol \(protocolVersion)"
    }
}
