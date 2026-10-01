import XCTest
import AgentRuntime
@testable import Surfaces

final class DiffPanelCommitPipeTests: XCTestCase {
    func test_commitWithVerboseHookCompletes_becauseWaitingBeforeDrainingDeadlocks() throws {
        // WHY: git commit shares one pipe for stdout+stderr; waiting for exit first
        // hangs forever once a pre-commit hook prints more than the 64 KiB buffer.
        let repo = NSTemporaryDirectory() + "rc2-diffpanel-hook-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = URL(fileURLWithPath: repo)
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
        }
        try git(["init", "-q"])
        try git(["config", "user.email", "test@example.com"])
        try git(["config", "user.name", "Test"])
        try git(["config", "commit.gpgsign", "false"])
        try "hello\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        let hook = repo + "/.git/hooks/pre-commit"
        try "#!/bin/sh\nhead -c 1000000 /dev/zero | tr '\\0' h\nexit 0\n".write(toFile: hook, atomically: true, encoding: .utf8)
        chmod(hook, 0o755)

        let finished = expectation(description: "commit returns")
        var result: GitActionResult?
        DispatchQueue.global(qos: .userInitiated).async {
            result = DiffPanelViewModel.runGitCommit(cwd: repo, argv: DiffPanelViewModel.commitArgv(message: "init", amend: false))
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)
        XCTAssertEqual(result?.ok, true)
    }
}
