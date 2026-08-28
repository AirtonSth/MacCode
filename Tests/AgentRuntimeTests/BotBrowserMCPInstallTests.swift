import XCTest
import CoreModel
import Persistence
@testable import AgentRuntime

final class BotBrowserMCPInstallTests: XCTestCase {
    func test_installAdmitsClaudeCodexGrokWithoutClobberingUserServers() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-bb-\(UUID().uuidString)", isDirectory: true)
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
        try installer.installBotBrowserMCP(serviceBinaryURL: binary)
        try installer.installBotBrowserMCP(serviceBinaryURL: binary)

        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: claudeSettings)) as? [String: Any])
        let servers = try XCTUnwrap(settings["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["other"])
        XCTAssertFalse(
            BotBrowserMCPAdmit.containsAdmittedClaude(servers),
            "Claude bot catalog MCP must not persist in settings.json; Claude Code does not spawn it from there"
        )

        let toml = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertTrue(toml.contains("model = \"gpt\""))
        XCTAssertFalse(
            BotBrowserMCPAdmit.containsAdmittedCodexTOML(toml),
            "Codex bot catalog MCP must not persist in the user-global config.toml that ChatGPT.app shares"
        )

        let leftover: [Any] = [["name": "user-slack", "command": "npx"]]
        let grok = GrokACPClient.sessionMCPServers(
            existing: leftover,
            command: binary.path,
            environment: [:]
        )
        XCTAssertTrue(BotBrowserMCPAdmit.containsAdmittedGrokACP(grok))
        let names = grok.compactMap { ($0 as? [String: Any])?["name"] as? String }
        XCTAssertTrue(names.contains("user-slack"))
    }
}
