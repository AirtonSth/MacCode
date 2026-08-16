import XCTest
import CoreModel
@testable import AgentRuntime

final class ComputerUseMCPInstallTests: XCTestCase {
    private func tempHome() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rc-cu-\(UUID().uuidString)", isDirectory: true)
    }

    func test_installComputerUseMCPAdmitsClaudeAndCodexWithoutClobberingUserServers() throws {
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
        try installer.installComputerUseMCP(serviceBinaryURL: binary)
        try installer.installComputerUseMCP(serviceBinaryURL: binary)

        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: claudeSettings)) as? [String: Any])
        XCTAssertEqual(settings["theme"] as? String, "dark")
        let servers = try XCTUnwrap(settings["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["other"], "leftover user MCP remains after admit")
        let ours = try XCTUnwrap(servers[ComputerUseMCPAdmit.serverName] as? [String: Any])
        XCTAssertEqual(ours["command"] as? String, binary.path)
        XCTAssertEqual(ours["args"] as? [String], [ComputerUseMCPAdmit.cliArgument])

        let toml = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertTrue(toml.contains("model = \"gpt\""))
        XCTAssertTrue(ComputerUseMCPAdmit.containsAdmittedCodexTOML(toml))
        XCTAssertEqual(toml.components(separatedBy: ComputerUseMCPAdmit.tomlBeginMarker).count - 1, 1)
    }

    func test_grokSessionAdmitUsesTheSameServerAndKeepsLeftovers() {
        let leftover: [Any] = [["name": "user-slack", "command": "npx"]]
        let servers = GrokACPClient.sessionMCPServers(existing: leftover, command: "/tmp/RemoteCodeDistillService")
        XCTAssertTrue(ComputerUseMCPAdmit.containsAdmittedGrokACP(servers))
        let names = servers.compactMap { ($0 as? [String: Any])?["name"] as? String }
        XCTAssertTrue(names.contains("user-slack"))
        XCTAssertEqual(names.filter { $0 == ComputerUseMCPAdmit.serverName }.count, 1)
    }

    func test_defaultAdmitPathCoversClaudeCodexAndGrok() {
        let command = "/tmp/RemoteCodeDistillService"
        let claude = ComputerUseMCPAdmit.admitClaude(existing: [:], command: command)
        let grok = ComputerUseMCPAdmit.admitGrokACP(existing: [], command: command)
        let codex = ComputerUseMCPAdmit.admitCodexTOML(existing: "", command: command)
        XCTAssertTrue(ComputerUseMCPAdmit.containsAdmittedClaude(claude))
        XCTAssertTrue(ComputerUseMCPAdmit.containsAdmittedGrokACP(grok))
        XCTAssertTrue(ComputerUseMCPAdmit.containsAdmittedCodexTOML(codex))
        XCTAssertEqual(
            (claude[ComputerUseMCPAdmit.serverName] as? [String: Any])?["args"] as? [String],
            [ComputerUseMCPAdmit.cliArgument]
        )
    }
}
