import XCTest
@testable import AgentRuntime

final class RetrieveMCPInstallTests: XCTestCase {
    private func tempHome() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rc-mcp-\(UUID().uuidString)", isDirectory: true)
    }

    func test_installRetrieveMCPMergesConfigIdempotentlyPreservingUserContent() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let binary = home.appendingPathComponent("bin/RemoteCodeDistillService")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        // Pre-existing user content in both files.
        let claudeSettings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"theme":"dark","mcpServers":{"other":{"command":"x"}}}"#.utf8).write(to: claudeSettings)
        let codexConfig = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model = \"gpt\"\n".utf8).write(to: codexConfig)

        let installer = AgentSkillInstaller(homeDirectory: home)
        try installer.installRetrieveMCP(serviceBinaryURL: binary)
        try installer.installRetrieveMCP(serviceBinaryURL: binary) // idempotent

        let settings = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: claudeSettings)) as? [String: Any])
        XCTAssertEqual(settings["theme"] as? String, "dark", "user keys preserved")
        let servers = try XCTUnwrap(settings["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["other"], "user's other MCP server preserved")
        let ours = try XCTUnwrap(servers["remotecode-distill-retrieve"] as? [String: Any])
        XCTAssertEqual(ours["command"] as? String, binary.path)
        XCTAssertEqual(ours["args"] as? [String], ["mcp"])

        let toml = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertTrue(toml.contains("model = \"gpt\""), "user TOML preserved")
        XCTAssertTrue(toml.contains("[mcp_servers.remotecode-distill-retrieve]"))
        XCTAssertEqual(toml.components(separatedBy: AgentSkillInstaller.mcpBeginMarker).count - 1, 1, "idempotent: exactly one managed block")

        try installer.uninstallRetrieveMCP()
        let settings2 = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: claudeSettings)) as? [String: Any])
        XCTAssertNil((settings2["mcpServers"] as? [String: Any])?["remotecode-distill-retrieve"], "our server removed")
        XCTAssertNotNil((settings2["mcpServers"] as? [String: Any])?["other"], "user MCP preserved on uninstall")
        let toml2 = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertFalse(toml2.contains("[mcp_servers.remotecode-distill-retrieve]"))
        XCTAssertTrue(toml2.contains("model = \"gpt\""), "user TOML preserved on uninstall")
    }
}
