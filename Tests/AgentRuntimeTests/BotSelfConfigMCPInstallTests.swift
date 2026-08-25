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
        XCTAssertNil(
            servers[BotSelfConfigMCPAdmit.serverName],
            "Claude bot catalog MCP must not persist in settings.json; Claude Code does not spawn it from there"
        )

        let toml = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertTrue(toml.contains("model = \"gpt\""))
        XCTAssertFalse(
            BotSelfConfigMCPAdmit.containsAdmittedCodexTOML(toml),
            "Codex bot catalog MCP must not persist in the user-global config.toml that ChatGPT.app shares"
        )
    }

    func test_installStripsLegacyCodexManagedBlockWithoutTouchingUserTables() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = home.appendingPathComponent("bin/RemoteCodeDistillService")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        let codexConfig = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        let polluted = BotSelfConfigMCPAdmit.admitCodexTOML(
            existing: "model = \"gpt\"\n\n[mcp_servers.user-linear]\ncommand = \"npx\"\n",
            command: binary.path
        )
        try Data(polluted.utf8).write(to: codexConfig)

        let installer = AgentSkillInstaller(homeDirectory: home)
        try installer.installBotSelfConfigMCP(serviceBinaryURL: binary)

        let toml = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertTrue(toml.contains("model = \"gpt\""))
        XCTAssertTrue(toml.contains("[mcp_servers.user-linear]"))
        XCTAssertFalse(BotSelfConfigMCPAdmit.containsAdmittedCodexTOML(toml))
        XCTAssertFalse(toml.contains(BotSelfConfigMCPAdmit.tomlBeginMarker))
    }

    func test_installStripsLegacyClaudeSettingsEntryWithoutTouchingUserServers() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = home.appendingPathComponent("bin/RemoteCodeDistillService")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let claudeSettings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let polluted: [String: Any] = [
            "theme": "dark",
            "mcpServers": [
                "other": ["command": "x"],
                BotSelfConfigMCPAdmit.serverName: ["command": binary.path, "args": [BotSelfConfigMCPAdmit.cliArgument]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: polluted, options: [.prettyPrinted]).write(to: claudeSettings)
        let grokConfig = home.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(at: grokConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        let grokOriginal = "[mcp_servers.user-slack]\ncommand = \"npx\"\n"
        try Data(grokOriginal.utf8).write(to: grokConfig)

        let installer = AgentSkillInstaller(homeDirectory: home)
        try installer.installBotSelfConfigMCP(serviceBinaryURL: binary)

        let servers = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: Data(contentsOf: claudeSettings)) as? [String: Any])?["mcpServers"] as? [String: Any]
        )
        XCTAssertNotNil(servers["other"])
        XCTAssertNil(servers[BotSelfConfigMCPAdmit.serverName])
        XCTAssertEqual(
            try String(contentsOf: grokConfig, encoding: .utf8),
            grokOriginal,
            "Grok already admits bot MCP per ACP session; install must not touch ~/.grok/config.toml"
        )
    }

    func test_installBotCatalogStripsFourCodexTablesAndClaudeEntriesWithoutBinary() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let claudeSettings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: claudeSettings.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let claudeServers: [String: Any] = [
            "user-linear": ["command": "npx"],
            BotSelfConfigMCPAdmit.serverName: ["command": "/legacy/self"],
            BotBrowserMCPAdmit.serverName: ["command": "/legacy/browser"],
            BotComputerMCPAdmit.serverName: ["command": "/legacy/computer"],
            BotWebMCPAdmit.serverName: ["command": "/legacy/web"],
        ]
        try JSONSerialization.data(
            withJSONObject: ["theme": "dark", "mcpServers": claudeServers],
            options: [.prettyPrinted]
        ).write(to: claudeSettings)

        let codexConfig = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let codex = """
        model = "gpt"

        [mcp_servers.user-linear]
        command = "npx"
        args = ["serve"]

        \(BotSelfConfigMCPAdmit.tomlBeginMarker)
        [mcp_servers.\(BotSelfConfigMCPAdmit.serverName)]
        command = "/legacy/self"
        args = ["bot-self-config"]
        \(BotSelfConfigMCPAdmit.tomlEndMarker)

        \(BotBrowserMCPAdmit.tomlBeginMarker)
        [mcp_servers.\(BotBrowserMCPAdmit.serverName)]
        command = "/legacy/browser"
        args = ["bot-browser"]
        \(BotBrowserMCPAdmit.tomlEndMarker)

        [mcp_servers.\(BotComputerMCPAdmit.serverName)]
        command = "/legacy/computer"
        args = ["bot-computer"]

        ["mcp_servers"."\(BotWebMCPAdmit.serverName)"]
        command = "/legacy/web"
        args = ["bot-web"]
        """
        try Data(codex.utf8).write(to: codexConfig)

        let installer = AgentSkillInstaller(homeDirectory: home)
        // Cleanup must still happen when the service binary is unavailable:
        // these entry points no longer install a persistent process at all.
        try installer.installBotSelfConfigMCP()
        try installer.installBotBrowserMCP()
        try installer.installBotComputerMCP()
        try installer.installBotWebMCP()

        let settings = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: claudeSettings)) as? [String: Any]
        )
        XCTAssertEqual(settings["theme"] as? String, "dark")
        let remainingServers = try XCTUnwrap(settings["mcpServers"] as? [String: Any])
        XCTAssertNotNil(remainingServers["user-linear"])
        for name in [
            BotSelfConfigMCPAdmit.serverName,
            BotBrowserMCPAdmit.serverName,
            BotComputerMCPAdmit.serverName,
            BotWebMCPAdmit.serverName,
        ] {
            XCTAssertNil(remainingServers[name], "Claude legacy entry must be stripped: \(name)")
        }

        let remainingCodex = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertTrue(remainingCodex.contains("model = \"gpt\""))
        XCTAssertTrue(remainingCodex.contains("[mcp_servers.user-linear]"))
        for name in [
            BotSelfConfigMCPAdmit.serverName,
            BotBrowserMCPAdmit.serverName,
            BotComputerMCPAdmit.serverName,
            BotWebMCPAdmit.serverName,
        ] {
            XCTAssertFalse(remainingCodex.contains("mcp_servers.\(name)"), "Codex legacy table must be stripped: \(name)")
        }
    }

    func test_grokSessionAdmitIncludesSelfConfigAndKeepsLeftovers() {
        let leftover: [Any] = [["name": "user-slack", "command": "npx"]]
        let servers = GrokACPClient.sessionMCPServers(
            existing: leftover,
            command: "/tmp/RemoteCodeDistillService",
            environment: [:]
        )
        XCTAssertFalse(ComputerUseMCPAdmit.containsAdmittedGrokACP(servers))
        XCTAssertTrue(BotSelfConfigMCPAdmit.containsAdmittedGrokACP(servers))
        let names = servers.compactMap { ($0 as? [String: Any])?["name"] as? String }
        XCTAssertTrue(names.contains("user-slack"))
        XCTAssertEqual(names.filter { $0 == BotSelfConfigMCPAdmit.serverName }.count, 1)
        XCTAssertEqual(names.filter { $0 == ComputerUseMCPAdmit.serverName }.count, 0)
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
