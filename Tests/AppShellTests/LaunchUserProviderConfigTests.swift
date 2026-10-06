import XCTest
import CoreModel
import Persistence
@testable import AppShell

/// The launch reconcile (`AppContext.init` → `reconcileComputerUseMCP`, plus the
/// legacy purge of what the removed Token Saver installed) runs against the user's real
/// provider configs. Those files belong to Claude Code / ChatGPT.app, so the
/// launch path may remove RemoteCode residue but must never rewrite a config it
/// has nothing to remove from.
@MainActor
final class LaunchUserProviderConfigTests: XCTestCase {
    private struct Snapshot {
        let bytes: Data
        let modifiedAt: Date
        let inode: UInt64
    }

    private func snapshot(_ urls: [URL]) throws -> [String: Snapshot] {
        var snapshots: [String: Snapshot] = [:]
        for url in urls {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            snapshots[url.lastPathComponent] = Snapshot(
                bytes: try Data(contentsOf: url),
                modifiedAt: try XCTUnwrap(attributes[.modificationDate] as? Date),
                inode: try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value
            )
        }
        return snapshots
    }

    func test_launchReconcileLeavesCleanUserProviderConfigsUntouched() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2LaunchUserConfigs-\(UUID().uuidString)", isDirectory: true)
        let appSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // User-owned configs with no RemoteCode residue at all.
        let claude = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"theme":"dark","mcpServers":{"slack":{"command":"npx"}}}"#.utf8).write(to: claude)
        let codex = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model = \"gpt-5\"\n\n[mcp_servers.user-linear]\ncommand = \"npx\"\n".utf8).write(to: codex)
        let configs = [claude, codex]
        let before = try snapshot(configs)

        _ = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport.path,
            agentSkillsHomeOverrideForTesting: home
        )

        for url in configs {
            let expected = try XCTUnwrap(before[url.lastPathComponent])
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(
                try Data(contentsOf: url),
                expected.bytes,
                "\(url.lastPathComponent) bytes changed during launch with no residue to remove"
            )
            XCTAssertEqual(
                try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value,
                expected.inode,
                "\(url.lastPathComponent) was replaced during launch with no residue to remove"
            )
            XCTAssertEqual(
                try XCTUnwrap(attributes[.modificationDate] as? Date),
                expected.modifiedAt,
                "\(url.lastPathComponent) was rewritten during launch with no residue to remove"
            )
        }
    }
}
