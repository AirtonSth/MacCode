import XCTest
import CoreModel
import Persistence
@testable import AgentRuntime

final class BotSelfConfigMCPInstallTests: XCTestCase {
    private func tempHome() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rc-bsc-\(UUID().uuidString)", isDirectory: true)
    }

    func test_installBotSelfConfigMCPAdmitsClaudeAndCodexWithoutClobberingUserServers() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = home.appendingPathComponent("bin/RemoteCodeDistillService")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let claudeSettings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"theme":"dark","mcpServers":{"other":{"command":"x"}}}"#.utf8).write(to: claudeSettings)
        let codexConfig = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model = \"gpt\"\n".utf8).write(to: codexConfig)

        let installer = AgentSkillInstaller(homeDirectory: home)
        try installer.installBotSelfConfigMCP(serviceBinaryURL: binary)
        try installer.installBotSelfConfigMCP(serviceBinaryURL: binary)

        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: claudeSettings)) as? [String: Any])
        XCTAssertEqual(settings["theme"] as? String, "dark")
        let servers = try XCTUnwrap(settings["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["other"], "leftover user MCP remains after admit")
        let ours = try XCTUnwrap(servers[BotSelfConfigMCPAdmit.serverName] as? [String: Any])
        XCTAssertEqual(ours["command"] as? String, binary.path)
        XCTAssertEqual(ours["args"] as? [String], [BotSelfConfigMCPAdmit.cliArgument])

        let toml = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertTrue(toml.contains("model = \"gpt\""))
        XCTAssertTrue(BotSelfConfigMCPAdmit.containsAdmittedCodexTOML(toml))
        XCTAssertEqual(toml.components(separatedBy: BotSelfConfigMCPAdmit.tomlBeginMarker).count - 1, 1)
    }

    func test_grokSessionAdmitIncludesSelfConfigAndKeepsLeftovers() {
        let leftover: [Any] = [["name": "user-slack", "command": "npx"]]
        let servers = GrokACPClient.sessionMCPServers(
            existing: leftover,
            command: "/tmp/RemoteCodeDistillService",
            environment: [:]
        )
        XCTAssertTrue(ComputerUseMCPAdmit.containsAdmittedGrokACP(servers))
        XCTAssertTrue(BotSelfConfigMCPAdmit.containsAdmittedGrokACP(servers))
        let names = servers.compactMap { ($0 as? [String: Any])?["name"] as? String }
        XCTAssertTrue(names.contains("user-slack"))
        XCTAssertEqual(names.filter { $0 == BotSelfConfigMCPAdmit.serverName }.count, 1)
        XCTAssertEqual(names.filter { $0 == ComputerUseMCPAdmit.serverName }.count, 1)
    }

    func test_defaultAdmitPathCoversClaudeCodexAndGrok() {
        let command = "/tmp/RemoteCodeDistillService"
        let leftover: [String: Any] = ["user-linear": ["command": "npx"]]
        let claude = BotSelfConfigMCPAdmit.admitClaude(existing: leftover, command: command)
        let grok = BotSelfConfigMCPAdmit.admitGrokACP(existing: [["name": "user-linear"]], command: command, environment: [:])
        let codex = BotSelfConfigMCPAdmit.admitCodexTOML(existing: "[mcp_servers.user-linear]\ncommand = \"npx\"\n", command: command)
        XCTAssertTrue(BotSelfConfigMCPAdmit.containsAdmittedClaude(claude))
        XCTAssertTrue(BotSelfConfigMCPAdmit.containsAdmittedGrokACP(grok))
        XCTAssertTrue(BotSelfConfigMCPAdmit.containsAdmittedCodexTOML(codex))
        XCTAssertNotNil(claude["user-linear"])
        XCTAssertTrue(codex.contains("[mcp_servers.user-linear]"))
        XCTAssertEqual(
            (claude[BotSelfConfigMCPAdmit.serverName] as? [String: Any])?["args"] as? [String],
            [BotSelfConfigMCPAdmit.cliArgument]
        )
    }
}
