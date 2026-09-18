import XCTest
import CoreModel
import Persistence
@testable import AgentRuntime

final class BotMCPResidueStripTests: XCTestCase {
    private func tempHome() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-botmcp-residue-\(UUID().uuidString)", isDirectory: true)
    }

    /// Counts probes of the shared Codex config. The agent-turn path runs the
    /// whole bot-MCP cleanup in one `stripManagedBotMCPResidue()` call, so the
    /// shared `~/.codex/config.toml` (also read by ChatGPT.app) must be probed
    /// once per turn — the four per-server entry points probed it four times.
    private final class CodexTouchCountingFileManager: FileManager, @unchecked Sendable {
        var codexPath = ""
        var codexTouches = 0

        // The product asks the one-argument variant; Foundation's ObjC core does
        // not route it through the pointer overload, so this is the seam.
        override func fileExists(atPath path: String) -> Bool {
            if path == codexPath { codexTouches += 1 }
            return super.fileExists(atPath: path, isDirectory: nil)
        }
    }

    /// Legacy residue exactly as older installers wrote it: marker blocks for
    /// two servers, an unmarked table for another and a quoted-header table for
    /// the last (the shapes the stripper explicitly supports).
    private func writePollutedHome(_ home: URL) throws {
        let claude = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: claude.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let servers: [String: Any] = [
            "user-linear": ["command": "npx", "args": ["serve"]],
            BotSelfConfigMCPAdmit.serverName: ["command": "/legacy/self", "args": ["bot-self-config"]],
            BotBrowserMCPAdmit.serverName: ["command": "/legacy/browser", "args": ["bot-browser"]],
            BotComputerMCPAdmit.serverName: ["command": "/legacy/computer", "args": ["bot-computer"]],
            BotWebMCPAdmit.serverName: ["command": "/legacy/web", "args": ["bot-web"]],
        ]
        try JSONSerialization.data(
            withJSONObject: ["theme": "dark", "mcpServers": servers],
            options: [.prettyPrinted]
        ).write(to: claude)

        let codex = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: codex.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let toml = """
        model = "gpt-5"

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
        try Data(toml.utf8).write(to: codex)
    }

    /// Both shared provider configs the residue pass touches.
    private static let relativeConfigPaths = [".claude/settings.json", ".codex/config.toml"]

    private func assertFixtureCarriesAllFourResidues(_ home: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let claude = home.appendingPathComponent(".claude/settings.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: claude)) as? [String: Any])
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        for name in [
            BotSelfConfigMCPAdmit.serverName,
            BotBrowserMCPAdmit.serverName,
            BotComputerMCPAdmit.serverName,
            BotWebMCPAdmit.serverName,
        ] {
            XCTAssertNotNil(servers[name], "fixture lost residue \(name)", file: file, line: line)
        }
        let toml = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        for name in [
            BotSelfConfigMCPAdmit.serverName,
            BotBrowserMCPAdmit.serverName,
            BotComputerMCPAdmit.serverName,
            BotWebMCPAdmit.serverName,
        ] {
            XCTAssertTrue(
                toml.contains("[mcp_servers.\(name)]") || toml.contains("\"\(name)\""),
                "fixture lost residue \(name)",
                file: file,
                line: line
            )
        }
    }

    private func assertNoResidueLeft(_ home: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let claude = home.appendingPathComponent(".claude/settings.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: claude)) as? [String: Any])
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any], file: file, line: line)
        XCTAssertNotNil(servers["user-linear"], "user MCP server was dropped", file: file, line: line)
        for name in [
            BotSelfConfigMCPAdmit.serverName,
            BotBrowserMCPAdmit.serverName,
            BotComputerMCPAdmit.serverName,
            BotWebMCPAdmit.serverName,
        ] {
            XCTAssertNil(servers[name], "residue \(name) survived", file: file, line: line)
        }
        let toml = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        XCTAssertTrue(toml.contains("[mcp_servers.user-linear]"), "user table was dropped", file: file, line: line)
        for name in [
            BotSelfConfigMCPAdmit.serverName,
            BotBrowserMCPAdmit.serverName,
            BotComputerMCPAdmit.serverName,
            BotWebMCPAdmit.serverName,
        ] {
            XCTAssertFalse(
                toml.contains("[mcp_servers.\(name)]") || toml.contains("\"\(name)\""),
                "residue \(name) survived",
                file: file,
                line: line
            )
        }
    }

    func test_combinedStripChecksTheSharedCodexConfigOncePerPass() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writePollutedHome(home)
        try assertFixtureCarriesAllFourResidues(home)

        let codex = home.appendingPathComponent(".codex/config.toml")
        let fileManager = CodexTouchCountingFileManager()
        fileManager.codexPath = codex.path
        let installer = AgentSkillInstaller(homeDirectory: home, fileManager: fileManager)

        try installer.stripManagedBotMCPResidue()

        XCTAssertLessThanOrEqual(
            fileManager.codexTouches,
            1,
            "one turn must probe the shared Codex config once, not once per bot MCP"
        )
        try assertNoResidueLeft(home)
    }

    func test_combinedStripLeavesTheSameBytesAsTheFourPerServerPoints() throws {
        let combinedHome = tempHome()
        let sequentialHome = tempHome()
        defer {
            try? FileManager.default.removeItem(at: combinedHome)
            try? FileManager.default.removeItem(at: sequentialHome)
        }
        try writePollutedHome(combinedHome)
        try writePollutedHome(sequentialHome)
        try assertFixtureCarriesAllFourResidues(combinedHome)

        try AgentSkillInstaller(homeDirectory: combinedHome).stripManagedBotMCPResidue()

        let sequential = AgentSkillInstaller(homeDirectory: sequentialHome)
        try sequential.installBotSelfConfigMCP()
        try sequential.installBotBrowserMCP()
        try sequential.installBotComputerMCP()
        try sequential.installBotWebMCP()

        for relativePath in Self.relativeConfigPaths {
            let combinedBytes = try Data(contentsOf: combinedHome.appendingPathComponent(relativePath))
            let sequentialBytes = try Data(contentsOf: sequentialHome.appendingPathComponent(relativePath))
            XCTAssertEqual(
                combinedBytes,
                sequentialBytes,
                "combined pass must leave \(relativePath) byte-identical to the four per-server points"
            )
        }
        try assertNoResidueLeft(combinedHome)
        try assertNoResidueLeft(sequentialHome)
    }

    func test_combinedStrip_secondPassLeavesBothConfigsUntouched() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writePollutedHome(home)
        let installer = AgentSkillInstaller(homeDirectory: home)
        try installer.stripManagedBotMCPResidue()

        let before = try Self.relativeConfigPaths.map { relativePath -> (bytes: Data, modifiedAt: Date, inode: UInt64) in
            let url = home.appendingPathComponent(relativePath)
            return (
                bytes: try Data(contentsOf: url),
                modifiedAt: try XCTUnwrap(
                    (try FileManager.default.attributesOfItem(atPath: url.path))[.modificationDate] as? Date
                ),
                inode: try XCTUnwrap(
                    (try FileManager.default.attributesOfItem(atPath: url.path))[.systemFileNumber] as? NSNumber
                ).uint64Value
            )
        }

        try installer.stripManagedBotMCPResidue()

        for (index, relativePath) in Self.relativeConfigPaths.enumerated() {
            let url = home.appendingPathComponent(relativePath)
            XCTAssertEqual(try Data(contentsOf: url), before[index].bytes)
            XCTAssertEqual(
                try XCTUnwrap(
                    (try FileManager.default.attributesOfItem(atPath: url.path))[.modificationDate] as? Date
                ),
                before[index].modifiedAt,
                "\(relativePath) was rewritten with nothing left to strip"
            )
            XCTAssertEqual(
                try XCTUnwrap(
                    (try FileManager.default.attributesOfItem(atPath: url.path))[.systemFileNumber] as? NSNumber
                ).uint64Value,
                before[index].inode,
                "atomic rewrites replace the inode; a no-op pass must not touch \(relativePath)"
            )
        }
    }
}
