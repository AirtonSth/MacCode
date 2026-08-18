import Foundation

/// Wire shape for Grok ACP `session/new` / `session/load` `mcpServers` entries.
/// Live grok 1.0.4 (`untagged enum McpServer`) requires stdio `env` as
/// `[{name,value}, …]` — omitting it or sending a `{KEY: value}` dict is
/// `-32602 Invalid params`.
public enum GrokACPMcpServer {
    public static func stdio(
        name: String,
        command: String,
        args: [String],
        extraEnv: [String: String] = [:]
    ) -> [String: Any] {
        [
            "name": name,
            "command": command,
            "args": args,
            "env": extraEnv.keys.sorted().map { ["name": $0, "value": extraEnv[$0] ?? ""] },
        ]
    }

    public static func envIsACPArray(_ value: Any?) -> Bool {
        guard let rows = value as? [[String: Any]] else { return false }
        return rows.allSatisfy { $0["name"] is String && $0["value"] is String }
    }
}
