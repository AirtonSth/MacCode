import Foundation

/// Merge the RemoteCode computer-use MCP into provider configs without
/// replacing leftover / user-authored servers.
public enum ComputerUseMCPAdmit: Sendable {
    public static let serverName = ComputerUseHostQueue.serverName
    public static let cliArgument = ComputerUseHostQueue.cliArgument
    public static let fallbackCommand = "RemoteCodeDistillService"
    public static let tomlBeginMarker = "# RemoteCode managed computer-use MCP: begin"
    public static let tomlEndMarker = "# RemoteCode managed computer-use MCP: end"

    public static func stdioConfig(command: String) -> [String: Any] {
        [
            "command": command,
            "args": [cliArgument],
        ]
    }

    public static func grokACPServer(command: String) -> [String: Any] {
        [
            "name": serverName,
            "command": command,
            "args": [cliArgument],
        ]
    }

    /// Claude `mcpServers` map. User keys stay; our key is upserted.
    public static func admitClaude(existing: [String: Any], command: String) -> [String: Any] {
        var next = existing
        next[serverName] = stdioConfig(command: command)
        return next
    }

    /// Grok ACP `mcpServers` array. Leftover entries stay; a prior copy of our
    /// server is replaced so admit is idempotent.
    public static func admitGrokACP(existing: [Any], command: String) -> [Any] {
        var kept: [Any] = []
        for item in existing {
            if let object = item as? [String: Any], object["name"] as? String == serverName {
                continue
            }
            kept.append(item)
        }
        kept.append(grokACPServer(command: command))
        return kept
    }

    /// Codex `config.toml`. User tables stay; our managed block is upserted.
    public static func admitCodexTOML(existing: String, command: String) -> String {
        let escaped = tomlString(command)
        let block = """
        \(tomlBeginMarker)
        [mcp_servers.\(serverName)]
        command = \(escaped)
        args = ["\(cliArgument)"]
        \(tomlEndMarker)
        """
        return upsertMarkerBlock(existing, begin: tomlBeginMarker, end: tomlEndMarker, block: block)
    }

    public static func containsAdmittedClaude(_ servers: [String: Any]) -> Bool {
        servers[serverName] != nil
    }

    public static func containsAdmittedGrokACP(_ servers: [Any]) -> Bool {
        servers.contains { item in
            (item as? [String: Any])?["name"] as? String == serverName
        }
    }

    public static func containsAdmittedCodexTOML(_ text: String) -> Bool {
        text.contains("[mcp_servers.\(serverName)]")
    }

    private static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func upsertMarkerBlock(_ text: String, begin: String, end: String, block: String) -> String {
        if let start = text.range(of: begin), let stop = text.range(of: end), start.lowerBound <= stop.upperBound {
            var result = text
            result.removeSubrange(start.lowerBound..<stop.upperBound)
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            let base = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return base.isEmpty ? block + "\n" : base + "\n\n" + block + "\n"
        }
        let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? block + "\n" : base + "\n\n" + block + "\n"
    }
}
