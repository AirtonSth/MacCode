import XCTest
@testable import AgentRuntime

final class GitDiffTests: XCTestCase {
    private func mkTmpRepo() throws -> String {
        let dir = NSTemporaryDirectory() + "rc2-git-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        run(["git", "init", "-q", "-b", "main", dir])
        run(["git", "-C", dir, "config", "user.email", "t@t.t"])
        run(["git", "-C", dir, "config", "user.name", "test"])
        return dir
    }

    private func run(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }

    func test_summary_inNonGitDir_isNotRepo() {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = GitDiff.summary(in: dir)
        XCTAssertFalse(s.isGitRepo)
        XCTAssertTrue(s.files.isEmpty)
    }

    func test_summary_inGitDir_detectsAddedAndUntracked() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "hello\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        run(["git", "-C", dir, "add", "a.txt"])
        run(["git", "-C", dir, "commit", "-q", "-m", "init"])
        try "modified\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: dir + "/b.txt", atomically: true, encoding: .utf8)
        let s = GitDiff.summary(in: dir)
        XCTAssertTrue(s.isGitRepo)
        XCTAssertTrue(s.dirty)
        XCTAssertTrue(s.files.contains { $0.path == "a.txt" && $0.status == .modified })
        XCTAssertTrue(s.files.contains { $0.path == "b.txt" && $0.status == .untracked })
    }
}
