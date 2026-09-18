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

        // Pre-existing user content in both files. The Claude file carries a
        // legacy managed entry from older app versions: Claude Code never reads
        // mcpServers from settings.json (the entry never spawned; `claude mcp
        // list` omits it), so install must stop writing it — Claude is admitted
        // per spawn via --mcp-config instead — while uninstall still purges it.
        let claudeSettings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"theme":"dark","mcpServers":{"other":{"command":"x"},"remotecode-distill-retrieve":{"command":"/legacy/RemoteCodeDistillService","args":["mcp"]}}}"#.utf8).write(to: claudeSettings)
        let codexConfig = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model = \"gpt\"\n".utf8).write(to: codexConfig)

        let installer = AgentSkillInstaller(homeDirectory: home)
        try installer.installRetrieveMCP(serviceBinaryURL: binary)
        try installer.installRetrieveMCP(serviceBinaryURL: binary) // idempotent

        let settingsData = try Data(contentsOf: claudeSettings)
        let settings = try XCTUnwrap(try JSONSerialization.jsonObject(with: settingsData) as? [String: Any])
        XCTAssertEqual(settings["theme"] as? String, "dark", "user keys preserved")
        let servers = try XCTUnwrap(settings["mcpServers"] as? [String: Any])
        let legacy = try XCTUnwrap(servers["remotecode-distill-retrieve"] as? [String: Any])
        XCTAssertEqual(legacy["command"] as? String, "/legacy/RemoteCodeDistillService",
                       "install must no longer write Claude settings.json — a dead location that made the librarian look installed while Claude never saw it")

        let toml = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertTrue(toml.contains("model = \"gpt\""), "user TOML preserved")
        XCTAssertTrue(toml.contains("[mcp_servers.remotecode-distill-retrieve]"))
        XCTAssertEqual(toml.components(separatedBy: AgentSkillInstaller.mcpBeginMarker).count - 1, 1, "idempotent: exactly one managed block")

        try installer.uninstallRetrieveMCP()
        let settings2 = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: claudeSettings)) as? [String: Any])
        XCTAssertNil((settings2["mcpServers"] as? [String: Any])?["remotecode-distill-retrieve"],
                     "uninstall must purge the legacy Claude settings.json entry")
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

    /// Bytes + mtime + inode: an atomic replace swaps the inode, so a no-op pass
    /// has to leave all three alone. The live files are user-owned: Claude Code
    /// reads settings.json and ChatGPT.app shares config.toml.
    private func snapshot(_ urls: [URL]) throws -> [String: (bytes: Data, modifiedAt: Date, inode: UInt64)] {
        var snapshots: [String: (bytes: Data, modifiedAt: Date, inode: UInt64)] = [:]
        for url in urls {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            snapshots[url.lastPathComponent] = (
                bytes: try Data(contentsOf: url),
                modifiedAt: try XCTUnwrap(attributes[.modificationDate] as? Date),
                inode: try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value
            )
        }
        return snapshots
    }

    private func assertUnchanged(
        _ urls: [URL],
        against snapshots: [String: (bytes: Data, modifiedAt: Date, inode: UInt64)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for url in urls {
            let expected = try XCTUnwrap(snapshots[url.lastPathComponent], file: file, line: line)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(
                try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber, file: file, line: line).uint64Value,
                expected.inode,
                "\(url.lastPathComponent) was rewritten (inode changed) with nothing to remove",
                file: file,
                line: line
            )
            XCTAssertEqual(
                try XCTUnwrap(attributes[.modificationDate] as? Date, file: file, line: line),
                expected.modifiedAt,
                "\(url.lastPathComponent) was rewritten (mtime changed) with nothing to remove",
                file: file,
                line: line
            )
            XCTAssertEqual(
                try Data(contentsOf: url),
                expected.bytes,
                "\(url.lastPathComponent) bytes changed with nothing to remove",
                file: file,
                line: line
            )
        }
    }

    /// A user-owned pair with no RemoteCode residue: `mcpServers` holds only the
    /// user's server and the Codex config carries only user tables.
    private func makeCleanUserConfigs(_ home: URL) throws -> [URL] {
        let claudeSettings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"theme":"dark","mcpServers":{"other":{"command":"x"}}}"#.utf8).write(to: claudeSettings)
        let codexConfig = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model = \"gpt\"\n\n[mcp_servers.user-linear]\ncommand = \"npx\"\n".utf8).write(to: codexConfig)
        return [claudeSettings, codexConfig]
    }

    func test_uninstallRetrieveMCP_leavesCleanSharedConfigsUntouched() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let configs = try makeCleanUserConfigs(home)
        let before = try snapshot(configs)

        try AgentSkillInstaller(homeDirectory: home).uninstallRetrieveMCP()

        try assertUnchanged(configs, against: before)
    }

    func test_uninstallRetrieveMCP_secondPassLeavesAlreadyCleanedConfigsUntouched() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = home.appendingPathComponent("bin/RemoteCodeDistillService")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let configs = try makeCleanUserConfigs(home)
        let installer = AgentSkillInstaller(homeDirectory: home)
        try installer.installRetrieveMCP(serviceBinaryURL: binary)

        // Anti-vacuous: install must have written the managed block we then purge.
        let codex = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        XCTAssertTrue(codex.contains(AgentSkillInstaller.mcpBeginMarker), "fixture never got the managed block")
        try installer.uninstallRetrieveMCP()

        let cleaned = try snapshot(configs)
        try installer.uninstallRetrieveMCP()

        try assertUnchanged(configs, against: cleaned)
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
