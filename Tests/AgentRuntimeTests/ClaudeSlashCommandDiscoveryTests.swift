import XCTest
@testable import AgentRuntime

/// WHY: the agent composer's `/` menu only listed the cached user-level skills,
/// so a skill living in the OPEN PROJECT folder (the reported `/task` in
/// `2-tasks-repos/.claude`) never appeared, and `/mcp` was missing. Discovery
/// must find project + user skills AND commands, matching interactive claude.
final class ClaudeSlashCommandDiscoveryTests: XCTestCase {

    private func makeTree() throws -> (root: URL, cwd: URL, home: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-slash-\(UUID().uuidString)", isDirectory: true)
        let cwd = root.appendingPathComponent("project", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (root, cwd, home)
    }

    private func writeSkill(_ base: URL, _ name: String) throws {
        let dir = base.appendingPathComponent(".claude/skills/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: \(name)\n---\n".write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    private func writeCommand(_ base: URL, _ name: String) throws {
        let dir = base.appendingPathComponent(".claude/commands", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "do it\n".write(to: dir.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
    }

    func test_discoversProjectSkill_theReportedTaskCase() throws {
        let (root, cwd, home) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeCommand(cwd, "task")   // /task lives in the project folder

        let found = ClaudeSlashCommandDiscovery.discover(cwd: cwd.path, home: home.path)
        XCTAssertTrue(found.contains("task"),
                      "a project-scoped `/task` command must be discovered — the exact reported gap")
    }

    func test_discoversBothProjectAndUserSkillsAndCommands() throws {
        let (root, cwd, home) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkill(cwd, "project-skill")
        try writeCommand(cwd, "project-cmd")
        try writeSkill(home, "user-skill")
        try writeCommand(home, "user-cmd")

        let found = Set(ClaudeSlashCommandDiscovery.discover(cwd: cwd.path, home: home.path))
        XCTAssertEqual(found, ["project-skill", "project-cmd", "user-skill", "user-cmd"])
    }

    func test_deduplicatesSameNameAcrossProjectAndUser() throws {
        let (root, cwd, home) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkill(cwd, "shared")
        try writeSkill(home, "shared")

        let found = ClaudeSlashCommandDiscovery.discover(cwd: cwd.path, home: home.path)
        XCTAssertEqual(found.filter { $0 == "shared" }.count, 1, "same name must appear once")
    }

    func test_nilCwd_scansOnlyUser() throws {
        let (root, _, home) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkill(home, "user-only")

        let found = ClaudeSlashCommandDiscovery.discover(cwd: nil, home: home.path)
        XCTAssertEqual(found, ["user-only"])
    }

    func test_ignoresSkillDirWithoutSkillManifest() throws {
        let (root, cwd, home) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        // A bare dir under skills/ with no SKILL.md is not a skill.
        try FileManager.default.createDirectory(
            at: cwd.appendingPathComponent(".claude/skills/not-a-skill", isDirectory: true),
            withIntermediateDirectories: true)

        let found = ClaudeSlashCommandDiscovery.discover(cwd: cwd.path, home: home.path)
        XCTAssertFalse(found.contains("not-a-skill"))
    }

    func test_missingClaudeDirs_returnEmpty_noThrow() throws {
        let (root, cwd, home) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(ClaudeSlashCommandDiscovery.discover(cwd: cwd.path, home: home.path), [])
    }

    func test_builtInsIncludeMcp() {
        XCTAssertTrue(ClaudeSlashCommandDiscovery.builtInClaudeCommands.contains("/mcp"),
                      "`/mcp` must be offered in the menu — a specific report")
    }
}
