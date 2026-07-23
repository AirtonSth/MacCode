import XCTest
@testable import AgentRuntime

/// WHY: headless `claude --print` short-circuits remote OAuth MCP servers to
/// `needs-auth` off a stale `~/.claude/mcp-needs-auth-cache.json`, so Linear (and
/// every claude.ai connector) showed as perpetually "connecting" in the Agent App
/// while the terminal had them connected. Clearing the cache before the spawn
/// restores terminal parity — but it deletes a vendor-owned file under the user's
/// home, so the safeguards (kill switch, same-user-only, regular-file-only,
/// fail-open) must each hold exactly.
final class ClaudeMCPAuthCacheResetTests: XCTestCase {
    private var home: String!
    private var cachePath: String!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-mcp-auth-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".claude", isDirectory: true),
            withIntermediateDirectories: true)
        home = dir.path
        cachePath = (home as NSString).appendingPathComponent(ClaudeMCPAuthCacheReset.cacheRelativePath)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(atPath: home) }
    }

    private func writeCache(_ contents: String = "{\"linear\":{\"timestamp\":1}}") {
        FileManager.default.createFile(atPath: cachePath, contents: Data(contents.utf8))
    }

    func test_removesRegularCacheFile() {
        writeCache()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachePath))
        let outcome = ClaudeMCPAuthCacheReset.reset(home: home, isForeignUser: false, environment: [:])
        XCTAssertEqual(outcome, .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachePath))
    }

    func test_absentCacheIsNoOp() {
        let outcome = ClaudeMCPAuthCacheReset.reset(home: home, isForeignUser: false, environment: [:])
        XCTAssertEqual(outcome, .absent)
    }

    func test_killSwitchDisablesAndLeavesFile() {
        writeCache()
        let outcome = ClaudeMCPAuthCacheReset.reset(
            home: home, isForeignUser: false,
            environment: [ClaudeMCPAuthCacheReset.killSwitchEnvKey: "0"])
        XCTAssertEqual(outcome, .disabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachePath), "kill switch must not touch the file")
    }

    func test_defaultEnabledWhenKillSwitchUnset() {
        writeCache()
        // Any value other than "0" (including unset) keeps the reset active.
        let outcome = ClaudeMCPAuthCacheReset.reset(
            home: home, isForeignUser: false,
            environment: [ClaudeMCPAuthCacheReset.killSwitchEnvKey: "1"])
        XCTAssertEqual(outcome, .removed)
    }

    func test_foreignUserIsSkippedAndLeavesFile() {
        writeCache()
        let outcome = ClaudeMCPAuthCacheReset.reset(home: home, isForeignUser: true, environment: [:])
        XCTAssertEqual(outcome, .skippedForeignUser)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachePath),
                      "must never mutate a run-as-user target's home")
    }

    func test_symlinkAtCachePathIsRefused() throws {
        // A symlink where the cache should be must NOT be unlinked and its target
        // must be untouched (defends against a swapped entry).
        let targetPath = (home as NSString).appendingPathComponent(".claude/real-secret.json")
        FileManager.default.createFile(atPath: targetPath, contents: Data("keep-me".utf8))
        try FileManager.default.createSymbolicLink(atPath: cachePath, withDestinationPath: targetPath)

        let outcome = ClaudeMCPAuthCacheReset.reset(home: home, isForeignUser: false, environment: [:])
        XCTAssertEqual(outcome, .skippedNotRegularFile)
        // Both the symlink and its target survive.
        var isSymlink = false
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cachePath) {
            isSymlink = (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
        }
        XCTAssertTrue(isSymlink, "symlink itself must remain")
        XCTAssertEqual(try String(contentsOfFile: targetPath, encoding: .utf8), "keep-me")
    }

    func test_directoryAtCachePathIsRefused() throws {
        try FileManager.default.createDirectory(atPath: cachePath, withIntermediateDirectories: true)
        let child = (cachePath as NSString).appendingPathComponent("inner.txt")
        FileManager.default.createFile(atPath: child, contents: Data("nested".utf8))

        let outcome = ClaudeMCPAuthCacheReset.reset(home: home, isForeignUser: false, environment: [:])
        XCTAssertEqual(outcome, .skippedNotRegularFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: child), "must never remove a directory recursively")
    }
}
