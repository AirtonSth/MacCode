import XCTest
import CoreModel
@testable import AgentRuntime

final class MacOSHarnessInstallTests: XCTestCase {
    private func tempHome() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-macos-harness-\(UUID().uuidString)", isDirectory: true)
    }

    func test_installMacOSHarnessWritesSkillForEveryProvider() throws {
        // WHY: Claude, Codex, and Grok must all see macos-harness. A
        // Claude-only skill would leave Codex/Grok bots on the old MCP.
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentSkillInstaller(homeDirectory: home)
        try installer.installMacOSHarness()
        try installer.installMacOSHarness()

        for provider in AgentProvider.allCases {
            let skill = installer.skillDirectory(provider: provider, skillID: AgentSkillInstaller.macosHarnessSkillID)
                .appendingPathComponent("SKILL.md")
            let text = try String(contentsOf: skill, encoding: .utf8)
            XCTAssertTrue(text.contains("macos-harness"), "\(provider) skill must name the CLI")
            XCTAssertTrue(text.contains("mac.see"), "\(provider) skill must teach the six primitives")
            XCTAssertTrue(text.contains("Do not call remotecode-computer-use"))
        }
    }

    func test_installMacOSHarnessStripsManagedComputerUseMCP() throws {
        // WHY: leftover remotecode-computer-use would compete with macos-harness.
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = home.appendingPathComponent("bin/RemoteCodeDistillService")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let claudeSettings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"other":{"command":"x"}}}"#.utf8).write(to: claudeSettings)
        let installer = AgentSkillInstaller(homeDirectory: home)
        try installer.installComputerUseMCP(serviceBinaryURL: binary)
        try installer.installMacOSHarness()

        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: claudeSettings)) as? [String: Any])
        let servers = try XCTUnwrap(settings["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["other"], "user MCP must survive the swap")
        XCTAssertNil(servers[ComputerUseMCPAdmit.serverName], "managed computer-use MCP must be removed")
    }

    func test_grokSessionDoesNotAdmitComputerUseMCP() {
        let leftover: [Any] = [["name": "user-slack", "command": "npx"]]
        let servers = GrokACPClient.sessionMCPServers(
            existing: leftover,
            command: "/tmp/RemoteCodeDistillService"
        )
        XCTAssertFalse(ComputerUseMCPAdmit.containsAdmittedGrokACP(servers))
        let names = servers.compactMap { ($0 as? [String: Any])?["name"] as? String }
        XCTAssertTrue(names.contains("user-slack"))
        XCTAssertFalse(names.contains(ComputerUseMCPAdmit.serverName))
    }
}
