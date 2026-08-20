import Foundation

/// Admit the RemoteCode Distill librarian MCP into provider configs.
public enum DistillMCPAdmit: Sendable {
    public static let serverName = "remotecode-distill"
    public static let cliArgument = "mcp"
    public static let recoveryEnvKeys = [
        "RC_TOKEN_SAVER_WORKSPACE_ID",
        "RC_TOKEN_SAVER_PROJECT_ID",
        "RC_TOKEN_SAVER_THREAD_ID",
        "REMOTE_CODE_AGENT_PROVIDER",
        "RC_TOKEN_SAVER_ATTEMPT_ID",
    ]

    public static func grokACPServer(
        command: String,
        environment: [String: String] = [:]
    ) -> [String: Any] {
        var extra: [String: String] = [:]
        for key in recoveryEnvKeys {
            if let value = environment[key], !value.isEmpty {
                extra[key] = value
            }
        }
        return GrokACPMcpServer.stdio(
            name: serverName,
            command: command,
            args: [cliArgument],
            extraEnv: extra
        )
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
