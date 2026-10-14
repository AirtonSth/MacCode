import XCTest
import GitTestSupport
@testable import AgentRuntime

/// Demonstrates and validates the GitRepoFixture shared helper.
///
/// WHY: T028-T035 each build temp repos inline using copy-pasted helpers
/// (mkTmpRepo / seedCommit / sh duplicated in GitDiffTests and
/// DiffPanelViewModelTests). GitRepoFixture eliminates that duplication.
/// These two tests prove the fixture core contract so callers can trust it
/// without reading its implementation.
final class GitRepoFixtureUsageTests: XCTestCase {

    // MARK: - T-FIXTURE-01

    /// WHY: The most common fixture use-case is "committed file, then dirty edit" --
    /// confirms that fixture.commit + writeUnstaged produce a real modified entry
    /// that GitDiff.summary sees, proving the helper is wired correctly.
    func test_fixture_dirtyFile_appearsAsModifiedInGitDiffSummary() throws {
        let fixture = try GitRepoFixture(prefix: "rc2-fx-dirty")
        defer { fixture.cleanup() }

        try fixture
            .commit(file: "readme.txt", content: "original\n", message: "init")
            .writeUnstaged(file: "readme.txt", content: "changed\n")

        let summary = try XCTUnwrap(GitDiff.summary(in: fixture.path))

        XCTAssertTrue(summary.isGitRepo,
                      "fixture must produce a valid git repository")
        XCTAssertTrue(summary.dirty,
                      "working-tree edit via fixture.writeUnstaged must make the repo dirty")
        XCTAssertTrue(summary.files.contains { $0.path == "readme.txt" && $0.status == .modified },
                      "the edited file must appear as modified in GitDiff.summary, not untracked")
    }

    // MARK: - T-FIXTURE-02

    /// WHY: Binary commits, branch switching, and untracked entries each have
    /// separate code paths in GitDiff. This test proves the fixture can set up
    /// a repo with all three in one fluent chain, so T028-T035 callers get
    /// full topology coverage without reimplementing setup.
    func test_fixture_branchBinaryAndUntracked_allVisibleToGitDiff() throws {
        let fixture = try GitRepoFixture(prefix: "rc2-fx-multi")
        defer { fixture.cleanup() }

        try fixture
            .commit(file: "main.txt", content: "v1\n", message: "init")
            .commitBinaryFile(named: "logo.png")
            .checkoutNewBranch(named: "feature")

        // Add an untracked file on the feature branch without staging.
        try fixture.writeUnstaged(file: "feature.txt", content: "new feature\n")

        // Branch contract: HEAD must be the new branch, original still listed.
        let branches = GitDiff.branches(in: fixture.path)
        XCTAssertEqual(branches.current, "feature",
                       "checkoutNewBranch must switch HEAD to the new branch")
        XCTAssertTrue(branches.locals.contains("main"),
                      "original branch must still be visible in the local branch list")

        // Untracked contract: writeUnstaged on a new file makes the repo dirty.
        let summary = try XCTUnwrap(GitDiff.summary(in: fixture.path))
        XCTAssertTrue(summary.dirty,
                      "an untracked file on a feature branch must make the repo dirty")
        XCTAssertTrue(summary.files.contains { $0.path == "feature.txt" && $0.status == .untracked },
                      "writeUnstaged on a new file must appear as untracked in GitDiff.summary")

        // Binary commit contract: the binary commit must appear in log history.
        // summary only shows uncommitted changes; committed files appear in log.
        let commits = GitDiff.log(in: fixture.path)
        XCTAssertTrue(commits.contains { $0.subject == "add binary" },
                      "commitBinaryFile must produce a real commit visible in GitDiff.log")
    }
}
