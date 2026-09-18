import XCTest
import CoreModel
import Persistence
@testable import AgentRuntime

final class ComputerUseMCPUninstallTests: XCTestCase {
    private func tempHome() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-cu-uninstall-\(UUID().uuidString)", isDirectory: true)
    }

    private struct Snapshot {
        let bytes: Data
        let modifiedAt: Date
        let inode: UInt64
    }

    private static let relativeConfigPaths = [".claude/settings.json", ".codex/config.toml"]

    private func writeClaudeSettings(_ home: URL, servers: [String: Any]) throws {
        let url = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let root: [String: Any] = [
            "tui": "default",
            "model": "opus",
            "enabledPlugins": ["one", "two"],
            "mcpServers": servers,
        ]
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]).write(to: url)
    }

    private func writeCodexConfig(_ home: URL, extra: String = "") throws {
        let url = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = """
        model = "gpt-5"
        approval_policy = "on-request"

        [mcp_servers.user-linear]
        command = "npx"
        args = ["serve"]
        \(extra)
        """
        try Data(text.utf8).write(to: url)
    }

    private func writeCleanHome(_ home: URL) throws {
        try writeClaudeSettings(home, servers: ["slack": ["command": "npx", "args": ["-y", "slack-mcp"]]])
        try writeCodexConfig(home)
    }

    /// Bytes + mtime + inode: an atomic replace swaps the inode, so a no-op pass
    /// has to leave all three alone.
    private func snapshot(_ home: URL) throws -> [String: Snapshot] {
        var snapshots: [String: Snapshot] = [:]
        for relative in Self.relativeConfigPaths {
            let url = home.appendingPathComponent(relative)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            snapshots[relative] = Snapshot(
                bytes: try Data(contentsOf: url),
                modifiedAt: try XCTUnwrap(attributes[.modificationDate] as? Date),
                inode: try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value
            )
        }
        return snapshots
    }

    private func assertUnchanged(
        _ home: URL,
        against snapshots: [String: Snapshot],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for relative in Self.relativeConfigPaths {
            let url = home.appendingPathComponent(relative)
            let expected = try XCTUnwrap(snapshots[relative], file: file, line: line)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(
                try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber, file: file, line: line).uint64Value,
                expected.inode,
                "\(relative) was rewritten (inode changed) with nothing to remove",
                file: file,
                line: line
            )
            XCTAssertEqual(
                try XCTUnwrap(attributes[.modificationDate] as? Date, file: file, line: line),
                expected.modifiedAt,
                "\(relative) was rewritten (mtime changed) with nothing to remove",
                file: file,
                line: line
            )
            XCTAssertEqual(
                try Data(contentsOf: url),
                expected.bytes,
                "\(relative) bytes changed with nothing to remove",
                file: file,
                line: line
            )
        }
    }

    func test_uninstallComputerUseMCP_leavesCleanSharedConfigsUntouched() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeCleanHome(home)
        let before = try snapshot(home)

        try AgentSkillInstaller(homeDirectory: home).uninstallComputerUseMCP()

        try assertUnchanged(home, against: before)
    }

    func test_uninstallComputerUseMCP_removesTheLegacyEntryAndKeepsUserContent() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeClaudeSettings(home, servers: [
            "slack": ["command": "npx", "args": ["-y", "slack-mcp"]],
            ComputerUseMCPAdmit.serverName: ["command": "/legacy/computer-use", "args": ["mcp"]],
        ])
        let markerBlock = """
        \(ComputerUseMCPAdmit.tomlBeginMarker)
        [mcp_servers.\(ComputerUseMCPAdmit.serverName)]
        command = "/legacy/computer-use"
        args = ["mcp"]
        \(ComputerUseMCPAdmit.tomlEndMarker)
        """
        try writeCodexConfig(home, extra: markerBlock)

        // Anti-vacuous: the fixture must actually carry the legacy host entry.
        let claudeBefore = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
        ) as? [String: Any]
        let serversBefore = try XCTUnwrap((claudeBefore?["mcpServers"] as? [String: Any]))
        XCTAssertNotNil(serversBefore[ComputerUseMCPAdmit.serverName], "fixture lost the legacy Claude entry")
        let tomlBefore = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        XCTAssertTrue(tomlBefore.contains(ComputerUseMCPAdmit.tomlBeginMarker), "fixture lost the legacy Codex block")

        try AgentSkillInstaller(homeDirectory: home).uninstallComputerUseMCP()

        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
            ) as? [String: Any]
        )
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        XCTAssertNil(servers[ComputerUseMCPAdmit.serverName], "legacy Claude host entry survived")
        XCTAssertNotNil(servers["slack"], "user MCP server was dropped")
        XCTAssertEqual(root["model"] as? String, "opus")
        let toml = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        XCTAssertFalse(toml.contains(ComputerUseMCPAdmit.tomlBeginMarker), "legacy Codex block survived")
        XCTAssertFalse(toml.contains(ComputerUseMCPAdmit.serverName))
        XCTAssertTrue(toml.contains("[mcp_servers.user-linear]"), "user table was dropped")
    }

    func test_uninstallComputerUseMCP_secondPassLeavesCleanedConfigsUntouched() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeClaudeSettings(home, servers: [
            "slack": ["command": "npx", "args": ["-y", "slack-mcp"]],
            ComputerUseMCPAdmit.serverName: ["command": "/legacy/computer-use", "args": ["mcp"]],
        ])
        try writeCodexConfig(
            home,
            extra: "\(ComputerUseMCPAdmit.tomlBeginMarker)\n[mcp_servers.\(ComputerUseMCPAdmit.serverName)]\ncommand = \"/legacy/computer-use\"\n\(ComputerUseMCPAdmit.tomlEndMarker)\n"
        )
        let installer = AgentSkillInstaller(homeDirectory: home)
        try installer.uninstallComputerUseMCP()

        let cleaned = try snapshot(home)
        try installer.uninstallComputerUseMCP()

        try assertUnchanged(home, against: cleaned)
    }
}
