import Foundation
import CoreModel

public enum BotWebMCPAdmit: Sendable {
    public static let serverName = BotWebCatalog.serverName
    public static let cliArgument = BotWebCatalog.cliArgument
    public static let fallbackCommand = "RemoteCodeDistillService"
    public static let tomlBeginMarker = "# RemoteCode managed bot web MCP: begin"
    public static let tomlEndMarker = "# RemoteCode managed bot web MCP: end"

    public static func stdioConfig(command: String) -> [String: Any] {
        ["command": command, "args": [cliArgument]]
    }

    public static func grokACPServer(
        command: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: Any] {
        var extra: [String: String] = [:]
        if let botID = environment[BotWebCatalog.callerEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !botID.isEmpty {
            extra[BotWebCatalog.callerEnvironmentKey] = botID
        }
        return GrokACPMcpServer.stdio(
            name: serverName,
            command: command,
            args: [cliArgument],
            extraEnv: extra
        )
    }

    public static func admitClaude(existing: [String: Any], command: String) -> [String: Any] {
        var next = existing
        next[serverName] = stdioConfig(command: command)
        return next
    }

    public static func admitGrokACP(
        existing: [Any],
        command: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
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

    public static func admitCodexTOML(existing: String, command: String) -> String {
        let escaped = "\"" + command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
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
