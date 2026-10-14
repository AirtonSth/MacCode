import XCTest
@testable import AgentRuntime

/// WHY: `GitDiff.runCommand` read stdout/stderr to EOF with no deadline. EOF
/// only arrives when every copy of the write end is closed, so a descendant
/// that kept the pipe (a hook's daemon, an fsmonitor, a terminal shell that
/// inherited it) pinned the calling thread and a `git.pipe.drain` thread
/// forever even though git itself had exited. The Agent App branch chip and
/// the diff summary never filled in.
final class GitDiffRunCommandBoundTests: XCTestCase {
    func test_runCommand_returnsOnceRootExits_evenWhenADescendantKeepsThePipe() {
        let started = Date()
        let result = GitDiff.runCommand(
            ["sh", "-c", "(/bin/sleep 4 &) ; echo hi ; echo warn >&2"],
            cwd: NSTemporaryDirectory(),
            environment: nil
        )
        let elapsed = Date().timeIntervalSince(started)
        NSLog("[perf-proof] gitDiff runCommand descendant-holds-pipe elapsed_ms=%.0f", elapsed * 1_000)
        XCTAssertEqual(result.exit, 0)
        XCTAssertEqual(result.stdout, "hi\n", "output written before exit must still be captured")
        XCTAssertEqual(result.stderr, "warn\n")
        XCTAssertLessThan(elapsed, 2, "the reader must stop shortly after the root exits, not when the descendant does")
    }

    func test_runCommand_stopsAStuckReadOnlyProbeAtItsDeadline() {
        // A hung probe (fsmonitor, credential helper) must not pin the branch
        // chip's thread forever; the failure reaches the existing error paths.
        let started = Date()
        let result = GitDiff.runCommand(
            ["sh", "-c", "/bin/sleep 30"],
            cwd: NSTemporaryDirectory(),
            environment: nil,
            timeout: 0.5
        )
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(result.exit, -1)
        XCTAssertTrue(result.stderr.contains("timed out"), result.stderr)
        XCTAssertLessThan(elapsed, 3)
    }

    func test_onlyReadOnlyGitCommandsGetADeadline() {
        // Killing a commit hook, push, fetch, pull or checkout midway could
        // leave work half done, so only probes the UI waits on are bounded.
        for args in [["rev-parse", "--is-inside-work-tree"], ["diff", "--numstat", "HEAD"], ["ls-files", "--others"], ["log", "-n", "1"]] {
            XCTAssertEqual(GitDiff.timeout(forGitArguments: args), GitDiff.readOnlyCommandTimeout, "\(args)")
        }
        for args in [["commit", "-m", "x"], ["push"], ["fetch", "--prune"], ["pull", "--ff-only"], ["checkout", "main"], ["add", "-A"], ["stash", "push"]] {
            XCTAssertNil(GitDiff.timeout(forGitArguments: args), "\(args)")
        }
    }
}
