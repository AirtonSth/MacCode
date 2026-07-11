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

    func test_installRetrieveMCPMigratesLegacyUnmarkedCodexTableToManagedBlock() throws {
        let fixture = try makeFixture(codexConfig: """
        [mcp_servers.remotecode-distill-retrieve]
        command = "/legacy/RemoteCodeDistillService"
        args = ["legacy"]
        """)
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        try fixture.installer.installRetrieveMCP(serviceBinaryURL: fixture.binary)

        let toml = try String(contentsOf: fixture.codexConfig, encoding: .utf8)
        XCTAssertEqual(
            toml.components(separatedBy: "[mcp_servers.remotecode-distill-retrieve]").count - 1,
            1,
            "the reserved MCP table must have one owner so Codex can parse config.toml"
        )
        XCTAssertFalse(toml.contains("/legacy/RemoteCodeDistillService"))
        XCTAssertTrue(toml.contains("command = \"\(fixture.binary.path)\""))
        XCTAssertEqual(toml.components(separatedBy: AgentSkillInstaller.mcpBeginMarker).count - 1, 1)
    }

    func test_installRetrieveMCPMigratesSemanticallyEquivalentQuotedLegacyTable() throws {
        let fixture = try makeFixture(codexConfig: """
        ["mcp_servers"."remotecode-distill-retrieve"]
        command = "/legacy/quoted-service"
        args = ["mcp"]
        """)
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        try fixture.installer.installRetrieveMCP(serviceBinaryURL: fixture.binary)

        let toml = try String(contentsOf: fixture.codexConfig, encoding: .utf8)
        XCTAssertFalse(toml.contains("[\"mcp_servers\".\"remotecode-distill-retrieve\"]"))
        XCTAssertFalse(toml.contains("/legacy/quoted-service"))
        XCTAssertEqual(toml.components(separatedBy: "[mcp_servers.remotecode-distill-retrieve]").count - 1, 1)
    }

    func test_installRetrieveMCPIsByteStableAfterLegacyTableMigration() throws {
        let fixture = try makeFixture(codexConfig: """
        [mcp_servers.remotecode-distill-retrieve]
        command = "/legacy/RemoteCodeDistillService"
        args = ["mcp"]
        """)
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        try fixture.installer.installRetrieveMCP(serviceBinaryURL: fixture.binary)
        let migrated = try Data(contentsOf: fixture.codexConfig)
        let migratedText = try XCTUnwrap(String(data: migrated, encoding: .utf8))
        XCTAssertEqual(
            migratedText.components(separatedBy: "[mcp_servers.remotecode-distill-retrieve]").count - 1,
            1,
            "idempotence is meaningful only after the legacy duplicate is reconciled"
        )

        try fixture.installer.installRetrieveMCP(serviceBinaryURL: fixture.binary)
        let reinstalled = try Data(contentsOf: fixture.codexConfig)

        XCTAssertEqual(reinstalled, migrated, "reconciliation must not grow or reorder config.toml")
    }

    func test_installRetrieveMCPMigrationPreservesUnrelatedCodexTables() throws {
        let fixture = try makeFixture(codexConfig: """
        model = "gpt"

        [mcp_servers.other]
        command = "/usr/bin/other"
        args = ["serve"]

        [mcp_servers.remotecode-distill-retrieve]
        command = "/legacy/RemoteCodeDistillService"
        args = ["mcp"]

        [projects."/tmp/proj]name"]
        trust_level = "trusted"

        [mcp_servers.remotecode-distill-retrieve-backup]
        command = "/usr/bin/backup"

        [mcp_servers."remotecode-distill-retrieve "]
        command = "/usr/bin/distinct"
        """)
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        try fixture.installer.installRetrieveMCP(serviceBinaryURL: fixture.binary)

        let toml = try String(contentsOf: fixture.codexConfig, encoding: .utf8)
        XCTAssertEqual(toml.components(separatedBy: "[mcp_servers.remotecode-distill-retrieve]").count - 1, 1)
        XCTAssertFalse(toml.contains("/legacy/RemoteCodeDistillService"))
        XCTAssertTrue(toml.contains("model = \"gpt\""))
        XCTAssertTrue(toml.contains("""
        [mcp_servers.other]
        command = "/usr/bin/other"
        args = ["serve"]
        """))
        XCTAssertTrue(toml.contains("""
        [mcp_servers.remotecode-distill-retrieve-backup]
        command = "/usr/bin/backup"
        """))
        XCTAssertTrue(toml.contains("""
        [mcp_servers."remotecode-distill-retrieve "]
        command = "/usr/bin/distinct"
        """))
        XCTAssertTrue(toml.contains("""
        [projects."/tmp/proj]name"]
        trust_level = "trusted"
        """))
    }

    private func makeFixture(
        codexConfig contents: String
    ) throws -> (home: URL, binary: URL, codexConfig: URL, installer: AgentSkillInstaller) {
        let home = tempHome()
        let binary = home.appendingPathComponent("bin/RemoteCodeDistillService")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let codexConfig = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: codexConfig)

        return (home, binary, codexConfig, AgentSkillInstaller(homeDirectory: home))
    }
}
