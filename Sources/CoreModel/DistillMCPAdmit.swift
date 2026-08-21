import Foundation

/// Admit the RemoteCode Distill librarian MCP into provider configs.
public enum DistillMCPAdmit: Sendable {
    public static let serverName = "remotecode-distill"
    public static let cliArgument = "mcp"

    /// Token Saver activation signal: set to "1" on every admitted run's
    /// environment by the execution receipt when the distill capability is on.
    public static let tokenSaverHintEnvironmentKey = "RC_TOKEN_SAVER_DISTILL_HINT"

    /// The librarian is paid-feature surface: it must be admitted for a run —
    /// on EVERY provider — only while Token Saver is enabled, exactly like the
    /// `| distill` policy prompt that instructs the model to use it.
    public static func isEnabled(environment: [String: String]) -> Bool {
        environment[tokenSaverHintEnvironmentKey] == "1"
    }
    public static let recoveryEnvKeys = [
        "RC_TOKEN_SAVER_WORKSPACE_ID",
        "RC_TOKEN_SAVER_PROJECT_ID",
        "RC_TOKEN_SAVER_THREAD_ID",
        "REMOTE_CODE_AGENT_PROVIDER",
        "RC_TOKEN_SAVER_ATTEMPT_ID",
    ]

    /// Librarian tool names served by the `mcp` subcommand. Must mirror
    /// `ManagedRetrieveMCP.*ToolName` (DistillCore, which CoreModel cannot
    /// import); a parity test pins the two lists together.
    public static let toolNames = ["rc_stats", "rc_search", "rc_ask", "rc_retrieve", "rc_compress"]

    /// Claude's supervised mode must not turn a local librarian lookup into a
    /// user confirmation: these tools only read/compress content the host
    /// already holds (handles, ledger stats, catalog ops) — same trust class
    /// as the already auto-allowed bot self-config tools.
    public static let claudeAutomaticallyAllowedTools =
        toolNames.map { "mcp__\(serverName)__\($0)" }

    /// Per-spawn server definition for Claude (`--mcp-config` on the CLI route,
    /// `mcp_servers` on the SDK bridge). Claude does not reliably read
    /// `mcpServers` from settings.json (proven: an installed entry never
    /// spawns and `claude mcp list` omits it), so — like the bot peer MCP —
    /// the librarian must be admitted explicitly on every run.
    public static func claudeServer(
        command: String,
        environment: [String: String] = [:]
    ) -> [String: Any] {
        var config: [String: Any] = [
            "command": command,
            "args": [cliArgument],
        ]
        let extra = recoveryEnvironment(environment)
        if !extra.isEmpty {
            config["env"] = extra
        }
        return config
    }

    public static func grokACPServer(
        command: String,
        environment: [String: String] = [:]
    ) -> [String: Any] {
        GrokACPMcpServer.stdio(
            name: serverName,
            command: command,
            args: [cliArgument],
            extraEnv: recoveryEnvironment(environment)
        )
    }

    private static func recoveryEnvironment(_ environment: [String: String]) -> [String: String] {
        var extra: [String: String] = [:]
        for key in recoveryEnvKeys {
            if let value = environment[key], !value.isEmpty {
                extra[key] = value
            }
        }
        return extra
    }

    public static func admitGrokACP(
        existing: [Any],
        command: String,
        environment: [String: String] = [:]
    ) -> [Any] {
        var kept: [Any] = []
        for item in existing {
            if let object = item as? [String: Any], object["name"] as? String == serverName {
                continue
            }
            kept.append(item)
        }
        kept.append(grokACPServer(command: command, environment: environment))
        return kept
    }

    public static func containsAdmittedGrokACP(_ servers: [Any]) -> Bool {
        servers.contains { item in
            (item as? [String: Any])?["name"] as? String == serverName
        }
    }
}
