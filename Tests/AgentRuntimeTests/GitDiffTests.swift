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

    /// Seeds `dir` with one committed file so HEAD exists.
    private func seedCommit(_ dir: String) throws {
        try "hello\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        run(["git", "-C", dir, "add", "a.txt"])
        run(["git", "-C", dir, "commit", "-q", "-m", "init"])
    }

    func test_branches_listsLocalAndCurrent() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        run(["git", "-C", dir, "branch", "feature"])
        let b = GitDiff.branches(in: dir)
        XCTAssertEqual(b.current, "main")
        XCTAssertTrue(b.locals.contains("main"))
        XCTAssertTrue(b.locals.contains("feature"))
    }

    func test_checkout_switchesBranch() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        run(["git", "-C", dir, "branch", "feature"])
        let r = GitDiff.checkout(in: dir, branch: "feature")
        XCTAssertTrue(r.ok, "checkout failed: \(r.message)")
        XCTAssertEqual(GitDiff.branches(in: dir).current, "feature")
    }

    func test_createBranch_createsAndSwitches() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        let r = GitDiff.createBranch(in: dir, name: "feature")
        XCTAssertTrue(r.ok, "createBranch failed: \(r.message)")
        XCTAssertEqual(GitDiff.branches(in: dir).current, "feature")
    }

    func test_commit_stagesAllAndClearsTree() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        try "changed\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: dir + "/b.txt", atomically: true, encoding: .utf8)
        let r = GitDiff.commit(in: dir, message: "wip changes")
        XCTAssertTrue(r.ok, "commit failed: \(r.message)")
        XCTAssertFalse(GitDiff.summary(in: dir).dirty,
                       "working tree must be clean after a stage-all commit")
        XCTAssertTrue(GitDiff.log(in: dir).contains { $0.subject == "wip changes" })
    }

    func test_commit_failsLoudlyWhenNothingToCommit() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        let r = GitDiff.commit(in: dir, message: "noop")
        XCTAssertFalse(r.ok, "committing a clean tree must report failure, not silent success")
        XCTAssertFalse(r.message.isEmpty, "failure must carry a non-empty message")
    }

    func test_log_returnsRecentCommitsNewestFirst() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        try "second\n".write(toFile: dir + "/c.txt", atomically: true, encoding: .utf8)
        run(["git", "-C", dir, "add", "c.txt"])
        run(["git", "-C", dir, "commit", "-q", "-m", "second commit"])
        let commits = GitDiff.log(in: dir, limit: 10)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].subject, "second commit", "log must be newest-first")
        XCTAssertEqual(commits[1].subject, "init")
        XCTAssertFalse(commits[0].shortHash.isEmpty)
        XCTAssertFalse(commits[0].hash.isEmpty)
    }

    // MARK: edge cases / fail-loud contract

    func test_branches_inNonGitDir_isEmptyAndNoCurrent() {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let b = GitDiff.branches(in: dir)
        XCTAssertNil(b.current, "a non-repo has no current branch")
        XCTAssertTrue(b.locals.isEmpty)
    }

    func test_branches_detachedHead_currentIsNil() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        try "two\n".write(toFile: dir + "/d.txt", atomically: true, encoding: .utf8)
        run(["git", "-C", dir, "add", "d.txt"])
        run(["git", "-C", dir, "commit", "-q", "-m", "second"])
        // Detach HEAD onto the first commit.
        let firstHash = GitDiff.log(in: dir).last!.hash
        run(["git", "-C", dir, "checkout", "-q", firstHash])
        XCTAssertNil(GitDiff.branches(in: dir).current,
                     "detached HEAD must report no current branch, not the literal 'HEAD'")
    }

    func test_checkout_nonexistentBranch_failsLoud() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        let r = GitDiff.checkout(in: dir, branch: "does-not-exist")
        XCTAssertFalse(r.ok, "checking out a missing branch must fail")
        XCTAssertFalse(r.message.isEmpty, "failure must carry git's error text, not be silent")
        XCTAssertEqual(GitDiff.branches(in: dir).current, "main",
                       "a failed checkout must not move HEAD")
    }

    func test_checkout_notGitRepo_failsLoud() {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let r = GitDiff.checkout(in: dir, branch: "main")
        XCTAssertFalse(r.ok)
        XCTAssertFalse(r.message.isEmpty)
    }

    func test_createBranch_duplicateName_failsLoud() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        XCTAssertTrue(GitDiff.createBranch(in: dir, name: "feature").ok)
        let again = GitDiff.createBranch(in: dir, name: "feature")
        XCTAssertFalse(again.ok, "creating an existing branch must fail")
        XCTAssertFalse(again.message.isEmpty)
    }

    func test_createBranch_notGitRepo_failsLoud() {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let r = GitDiff.createBranch(in: dir, name: "x")
        XCTAssertFalse(r.ok)
        XCTAssertFalse(r.message.isEmpty)
    }

    func test_commit_notGitRepo_failsLoud() {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let r = GitDiff.commit(in: dir, message: "x")
        XCTAssertFalse(r.ok)
        XCTAssertFalse(r.message.isEmpty)
    }

    func test_commit_stagesDeletionsAndUntracked_thenTreeClean() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)                              // commits a.txt
        try FileManager.default.removeItem(atPath: dir + "/a.txt")  // deletion
        try "fresh\n".write(toFile: dir + "/e.txt", atomically: true, encoding: .utf8) // untracked
        let r = GitDiff.commit(in: dir, message: "remove a, add e")
        XCTAssertTrue(r.ok, "stage-all (git add -A) must include deletions + untracked: \(r.message)")
        let s = GitDiff.summary(in: dir)
        XCTAssertFalse(s.dirty, "tree must be clean after committing every change class")
        XCTAssertFalse(s.files.contains { $0.path == "a.txt" }, "deleted file must be gone")
    }

    func test_commit_preservesMultiWordMessageInLog() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        try "x\n".write(toFile: dir + "/f.txt", atomically: true, encoding: .utf8)
        let msg = "fix: handle spaces and : colons in subject"
        XCTAssertTrue(GitDiff.commit(in: dir, message: msg).ok)
        XCTAssertEqual(GitDiff.log(in: dir).first?.subject, msg,
                       "the commit subject must round-trip verbatim through the %s log format")
    }

    func test_log_respectsLimit() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        for i in 0..<4 {
            try "\(i)\n".write(toFile: dir + "/n\(i).txt", atomically: true, encoding: .utf8)
            run(["git", "-C", dir, "add", "."])
            run(["git", "-C", dir, "commit", "-q", "-m", "c\(i)"])
        }
        XCTAssertEqual(GitDiff.log(in: dir, limit: 2).count, 2,
                       "limit must cap how many commits the panel pulls")
        XCTAssertEqual(GitDiff.log(in: dir, limit: 100).count, 5)
    }

    func test_log_inNonGitDir_isEmpty() {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertTrue(GitDiff.log(in: dir).isEmpty)
    }

    func test_log_emptyRepoWithNoCommits_isEmpty() throws {
        let dir = try mkTmpRepo()      // initialized but no commits yet
        defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertTrue(GitDiff.log(in: dir).isEmpty,
                      "a repo with no commits must yield an empty history, not a crash")
    }

    func test_commitDiff_containsChangedPath_andEmptyForNonGit() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        let hash = GitDiff.log(in: dir).first!.hash
        let d = GitDiff.commitDiff(in: dir, hash: hash)
        XCTAssertTrue(d.contains("a.txt"), "git show output must reference the committed file")
        let nonGit = NSTemporaryDirectory() + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: nonGit, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: nonGit) }
        XCTAssertEqual(GitDiff.commitDiff(in: nonGit, hash: hash), "")
    }

    func test_commitDiff_invalidHash_isEmpty() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        XCTAssertEqual(GitDiff.commitDiff(in: dir, hash: "deadbeefdeadbeef"), "",
                       "an unknown revision must yield empty output, not stale/garbage text")
    }
}
