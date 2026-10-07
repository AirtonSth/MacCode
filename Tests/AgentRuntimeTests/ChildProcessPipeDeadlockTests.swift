import XCTest
import Darwin
@testable import AgentRuntime

final class ChildProcessPipeDeadlockTests: XCTestCase {
    func test_gitHelperSurvivesStderrFlood_becauseAnUndrainedStderrPipeBlocksStdoutForever() throws {
        // WHY: a helper that reads stdout to EOF while stderr sits in a second,
        // undrained pipe hangs forever: a git that warns > 64 KiB before
        // printing blocks both processes.
        let shimDir = NSTemporaryDirectory() + "rc2-git-shim-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: shimDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: shimDir) }
        let repo = shimDir + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let shim = shimDir + "/git"
        try """
        #!/bin/sh
        head -c 200000 /dev/zero | tr '\\0' w >&2
        case "$*" in
          *--is-inside-work-tree*) echo "true" ;;
          *--abbrev-ref*) echo "main" ;;
        esac
        """.write(toFile: shim, atomically: true, encoding: .utf8)
        chmod(shim, 0o755)
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        setenv("PATH", shimDir + ":" + originalPath, 1)
        defer { setenv("PATH", originalPath, 1) }

        let finished = expectation(description: "git helper returns")
        var branches: GitBranches?
        DispatchQueue.global(qos: .userInitiated).async {
            branches = GitDiff.branches(in: repo)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(branches?.current, "main")
    }
}
