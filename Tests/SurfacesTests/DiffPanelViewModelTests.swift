import XCTest
@testable import Surfaces
import AgentRuntime

/// Behavioural coverage for the git-tab view model. These prove the
/// panel's user-facing contract: what the sidebar shows, what selecting
/// a row does, that mutating ops refresh state, and that failures are
/// surfaced loudly instead of swallowed.
@MainActor
final class DiffPanelViewModelTests: XCTestCase {

    // MARK: helpers

    private func sh(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try? p.run(); p.waitUntilExit()
    }

    private func mkTmpRepo() throws -> String {
        let dir = NSTemporaryDirectory() + "rc2-vm-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        sh(["git", "init", "-q", "-b", "main", dir])
        sh(["git", "-C", dir, "config", "user.email", "t@t.t"])
        sh(["git", "-C", dir, "config", "user.name", "test"])
        return dir
    }

    private func seed(_ dir: String) throws {
        try "hello\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        sh(["git", "-C", dir, "add", "a.txt"])
        sh(["git", "-C", dir, "commit", "-q", "-m", "init"])
    }

    /// Spin the main run loop until `cond` holds — the view model hops to
    /// a background queue then back to main, so async results land here.
    private func waitUntil(_ desc: String,
                           timeout: TimeInterval = 5,
                           _ cond: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(cond(), "timed out waiting for: \(desc)")
    }

    // MARK: init / synchronous selection contract

    func test_init_nonGitDir_reportsNotARepo() {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let vm = DiffPanelViewModel(cwd: dir)
        XCTAssertFalse(vm.summary.isGitRepo,
                       "panel must show the not-a-repo empty state for a plain folder")
        XCTAssertNil(vm.branches.current)
        XCTAssertTrue(vm.branches.locals.isEmpty)
    }

    func test_init_gitRepo_seedsBranchAndSummary() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seed(dir)
        let vm = DiffPanelViewModel(cwd: dir)
        XCTAssertTrue(vm.summary.isGitRepo)
        XCTAssertEqual(vm.branches.current, "main",
                       "the branch chip must reflect the real current branch on open")
    }

    func test_selectFile_thenClear_managesSelectionExclusively() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seed(dir)
        let vm = DiffPanelViewModel(cwd: dir)
        vm.selectedCommit = "stale"
        vm.selectFile("a.txt")
        XCTAssertEqual(vm.selectedPath, "a.txt")
        XCTAssertNil(vm.selectedCommit,
                     "selecting a file must clear any prior commit selection")
        vm.selectFile(nil)
        XCTAssertNil(vm.selectedPath)
        XCTAssertEqual(vm.rawDiff, "", "clearing the file selection must clear the diff pane")
    }

    func test_selectCommit_clearsFileSelection() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seed(dir)
        let vm = DiffPanelViewModel(cwd: dir)
        vm.selectedPath = "a.txt"
        vm.selectCommit("abc123")
        XCTAssertEqual(vm.selectedCommit, "abc123")
        XCTAssertNil(vm.selectedPath,
                     "viewing a commit must take over the diff pane from file view")
    }

    func test_commit_emptyMessage_isNoOpGuard() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seed(dir)
        try "x\n".write(toFile: dir + "/b.txt", atomically: true, encoding: .utf8)
        let vm = DiffPanelViewModel(cwd: dir)
        vm.commitMessage = "   "
        vm.commit()
        XCTAssertNil(vm.lastError, "an empty message must be a silent guard, not an error")
        XCTAssertTrue(vm.summary.isGitRepo)
        // Nothing was committed: the working change is still present.
        waitUntil("tree stays dirty after no-op commit") { vm.summary.dirty }
    }

    func test_newBranch_blankName_isNoOpGuard() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seed(dir)
        let vm = DiffPanelViewModel(cwd: dir)
        vm.newBranch("   ")
        XCTAssertEqual(vm.branches.current, "main",
                       "a blank branch name must not create or switch anything")
        XCTAssertNil(vm.lastError)
    }

    // MARK: async mutating ops

    func test_switchBranch_movesHeadAndClearsError() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seed(dir)
        sh(["git", "-C", dir, "branch", "feature"])
        let vm = DiffPanelViewModel(cwd: dir)
        vm.lastError = "stale error"
        vm.switchBranch("feature")
        waitUntil("branch chip follows checkout") { vm.branches.current == "feature" }
        XCTAssertNil(vm.lastError, "a successful switch must clear a prior error banner")
    }

    func test_newBranch_createsSwitchesAndShowsInList() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seed(dir)
        let vm = DiffPanelViewModel(cwd: dir)
        vm.newBranch("spike")
        waitUntil("created branch becomes current") { vm.branches.current == "spike" }
        XCTAssertTrue(vm.branches.locals.contains("spike"),
                      "a new branch must appear in the switch menu")
    }

    func test_commit_clearsMessageRefreshesTreeAndHistory() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seed(dir)
        try "changed\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        let vm = DiffPanelViewModel(cwd: dir)
        vm.commitMessage = "apply the change"
        vm.commit()
        waitUntil("commit lands and clears the composer") {
            !vm.summary.dirty && vm.commitMessage.isEmpty
        }
        XCTAssertNil(vm.lastError)
        XCTAssertTrue(vm.commits.contains { $0.subject == "apply the change" },
                      "a successful commit must show up in History without a manual reload")
    }

    func test_commit_onCleanTree_failsLoudInBanner() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seed(dir)
        let vm = DiffPanelViewModel(cwd: dir)
        vm.commitMessage = "nothing staged"
        vm.commit()
        waitUntil("clean-tree commit surfaces an error") { vm.lastError != nil }
        XCTAssertFalse(vm.lastError?.isEmpty ?? true,
                       "the failure banner must carry git's message, never be blank")
    }

    func test_loadHistory_isIdempotentUntilForced() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seed(dir)
        let vm = DiffPanelViewModel(cwd: dir)
        vm.loadHistory()
        waitUntil("initial history loads") { vm.commits.count == 1 }
        // A commit made outside the panel must not appear until a forced reload.
        try "y\n".write(toFile: dir + "/g.txt", atomically: true, encoding: .utf8)
        sh(["git", "-C", dir, "add", "."])
        sh(["git", "-C", dir, "commit", "-q", "-m", "external"])
        vm.loadHistory()                       // gated: should NOT re-query
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(vm.commits.count, 1,
                       "loadHistory must be a one-shot cache until force is requested")
        vm.loadHistory(force: true)
        waitUntil("forced reload picks up the new commit") { vm.commits.count == 2 }
    }

    func test_refresh_picksUpExternalWorkingTreeChange() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seed(dir)
        let vm = DiffPanelViewModel(cwd: dir)
        XCTAssertFalse(vm.summary.dirty)
        try "edited\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        vm.refresh()
        waitUntil("refresh reflects the new working-tree edit") { vm.summary.dirty }
    }
}
