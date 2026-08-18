import Foundation
import CoreModel

public enum BotBrowserMCPAdmit: Sendable {
    public static let serverName = BotBrowserCatalog.serverName
    public static let cliArgument = BotBrowserCatalog.cliArgument
    public static let fallbackCommand = "RemoteCodeDistillService"
    public static let tomlBeginMarker = "# RemoteCode managed bot browser MCP: begin"
    public static let tomlEndMarker = "# RemoteCode managed bot browser MCP: end"

    public static func stdioConfig(command: String) -> [String: Any] {
        ["command": command, "args": [cliArgument]]
    }

    public static func grokACPServer(
        command: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: Any] {
        var extra: [String: String] = [:]
        if let botID = environment[BotBrowserCatalog.callerEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !botID.isEmpty {
            extra[BotBrowserCatalog.callerEnvironmentKey] = botID
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
        if let start = existing.range(of: tomlBeginMarker),
           let stop = existing.range(of: tomlEndMarker),
           start.lowerBound <= stop.upperBound {
            var result = existing
            result.removeSubrange(start.lowerBound..<stop.upperBound)
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            let base = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return base.isEmpty ? block + "\n" : base + "\n\n" + block + "\n"
        }
        let base = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? block + "\n" : base + "\n\n" + block + "\n"
    }

    public static func containsAdmittedClaude(_ servers: [String: Any]) -> Bool {
        servers[serverName] != nil
    }

    public static func containsAdmittedGrokACP(_ servers: [Any]) -> Bool {
        servers.contains { ($0 as? [String: Any])?["name"] as? String == serverName }
    }

    public static func containsAdmittedCodexTOML(_ text: String) -> Bool {
        text.contains("[mcp_servers.\(serverName)]")
    }
}
