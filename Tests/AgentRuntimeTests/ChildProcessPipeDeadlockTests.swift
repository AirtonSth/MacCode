import XCTest
import Darwin
@testable import AgentRuntime

final class ChildProcessPipeDeadlockTests: XCTestCase {
    func test_gitProbeSurvivesStderrFlood_becauseAnUndrainedStderrPipeBlocksStdoutForever() throws {
        // WHY: the probe read stdout to EOF while stderr sat in a second, undrained
        // pipe. A git that warns > 64 KiB before printing blocks both processes forever.
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
          *--show-toplevel*) echo "\(repo)" ;;
          *--git-common-dir*) echo ".git" ;;
        esac
        """.write(toFile: shim, atomically: true, encoding: .utf8)
        chmod(shim, 0o755)
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        setenv("PATH", shimDir + ":" + originalPath, 1)
        defer { setenv("PATH", originalPath, 1) }

        let finished = expectation(description: "probe returns")
        var identity: GraphifyGitProbe.RepoIdentity?
        DispatchQueue.global(qos: .userInitiated).async {
            identity = GraphifyGitProbe.identity(at: repo)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(identity?.toplevel, repo)
    }
}
