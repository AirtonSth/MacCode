import XCTest
@testable import Surfaces
import AgentRuntime

/// Tests for the async-load init path introduced to fix the surface-creation
/// stall on large repos (PERF: DiffPanelViewModel.init with asyncLoad:true).
///
/// WHY each test matters:
/// - If init with asyncLoad:true blocks on git, the surface takes ~N seconds
///   to appear on a large repo - the exact problem being fixed.
/// - If isLoading starts false, the spinner is absent during the git call,
///   leaving the user with a blank panel and no feedback.
/// - If the loaded state never populates, the panel stays empty forever.
/// - If the transition can go loaded -> loading from this path, the user
///   would see a spinner flash after the data is already visible.
///
/// Tests that touch @MainActor types are marked @MainActor.
/// Pure-helper tests (performLoad shape) are non-isolated.
@MainActor
final class DiffPanelAsyncLoadTests: XCTestCase {

    // MARK: - helpers

    private func sh(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        p.waitUntilExit()
    }

    private func mkTmpRepo() throws -> String {
        let dir = NSTemporaryDirectory() + "rc2-async-" + UUID().uuidString
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

    /// Spin the main run loop until condition holds or timeout fires.
    private func waitUntil(_ desc: String,
                            timeout: TimeInterval = 5,
                            _ cond: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(cond(), "timed out waiting for: \(desc)")
    }

    // MARK: - async init: initial loading state

    /// WHY: the entire point of asyncLoad:true is that init returns before
    /// git runs. If isLoading is false immediately after init, the panel
    /// has no spinner and the user sees a blank, frozen-looking surface.
    func test_asyncInit_isLoadingImmediately() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seed(dir)

        let vm = DiffPanelViewModel(cwd: dir, asyncLoad: true)

        XCTAssertTrue(vm.isLoading,
                      "asyncLoad:true must set isLoading=true immediately so " +
                      "the surface shows a spinner while git runs in the background")
    }

    /// WHY: the summary must start as a loading placeholder (isGitRepo:false,
    /// no files) so the surface renders instantly without blocking on git.
    /// An isGitRepo:true value immediately after async init would mean git
    /// was called synchronously, defeating the perf fix.
    func test_asyncInit_summaryIsPlaceholderBeforeLoad() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seed(dir)

        let vm = DiffPanelViewModel(cwd: dir, asyncLoad: true)

        XCTAssertFalse(vm.summary.isGitRepo,
                       "summary must be a placeholder (isGitRepo:false) immediately " +
                       "after asyncLoad:true init - git has not run yet")
        XCTAssertTrue(vm.summary.files.isEmpty,
                      "placeholder summary must have no files before git load completes")
    }

    /// WHY: the branches placeholder must be empty so the branch chip in
    /// the header shows nothing (not a stale value) before git responds.
    func test_asyncInit_branchesIsPlaceholderBeforeLoad() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seed(dir)

        let vm = DiffPanelViewModel(cwd: dir, asyncLoad: true)

        XCTAssertNil(vm.branches.current,
                     "branches.current must be nil in placeholder state " +
                     "so the chip shows nothing until git responds")
        XCTAssertTrue(vm.branches.locals.isEmpty,
                      "branches.locals must be empty in placeholder state")
    }

    // MARK: - async init: loaded state

    /// WHY: after the background Task completes, summary must reflect the
    /// real git state. If summary stays as a placeholder, the panel is
    /// permanently broken - no file list, no change counts, no branch chip.
    func test_asyncInit_summaryPopulatesAfterLoad() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seed(dir)

        let vm = DiffPanelViewModel(cwd: dir, asyncLoad: true)

        waitUntil("summary reflects the real repo after async load") {
            vm.summary.isGitRepo
        }
        XCTAssertTrue(vm.summary.isGitRepo,
                      "summary.isGitRepo must be true after async load - " +
                      "the panel must know it is inside a git repository")
    }

    /// WHY: branches must reflect reality after load so the branch chip
    /// shows the correct current branch. A nil or wrong current branch
    /// causes the user to see incorrect state even after loading.
    func test_asyncInit_branchesPopulatesAfterLoad() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seed(dir)

        let vm = DiffPanelViewModel(cwd: dir, asyncLoad: true)

        waitUntil("branches.current set after async load") {
            vm.branches.current != nil
        }
        XCTAssertEqual(vm.branches.current, "main",
                       "branches.current must be the real branch name after load")
    }

    // MARK: - async init: one-way loading transition

    /// WHY: isLoading must become false exactly once after git completes and
    /// must not flip back to true from the async-init path. A second loading
    /// flash would cause the surface to show a spinner over valid data,
    /// confusing the user and potentially hiding the content.
    func test_asyncInit_isLoadingBecomsFalseAfterLoad() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seed(dir)

        let vm = DiffPanelViewModel(cwd: dir, asyncLoad: true)

        XCTAssertTrue(vm.isLoading, "must start loading")

        waitUntil("isLoading clears after async load") { !vm.isLoading }

        XCTAssertFalse(vm.isLoading,
                       "isLoading must be false once git load completes " +
                       "so the spinner disappears and the content is visible")
    }

    // MARK: - sync init backward compat

    /// WHY: the default (asyncLoad:false) init must remain synchronous so
    /// all existing tests that check state immediately after init keep passing.
    /// A regression here would mean the async flag silently changes the default.
    func test_syncInit_summaryPopulatesImmediately() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seed(dir)

        let vm = DiffPanelViewModel(cwd: dir)  // asyncLoad defaults to false

        XCTAssertTrue(vm.summary.isGitRepo,
                      "default (sync) init must still populate summary immediately " +
                      "to preserve backward compat with existing tests")
        XCTAssertEqual(vm.branches.current, "main",
                       "default init must populate branches.current synchronously")
        XCTAssertFalse(vm.isLoading,
                       "default init must NOT set isLoading - no background task is running")
    }

    // MARK: - performLoad helper

    /// WHY: performLoad is the pure coordination helper that decouples the
    /// background thread call from the actor boundary. If it returns wrong
    /// values, both the async-init path and any future callers are broken.
    func test_performLoad_returnsRealGitState() async throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seed(dir)

        let (loaded, branches) = await DiffPanelViewModel.performLoad(cwd: dir)
        let summary = try XCTUnwrap(loaded)

        XCTAssertTrue(summary.isGitRepo,
                      "performLoad must return the real git summary for a valid repo")
        XCTAssertEqual(branches.current, "main",
                       "performLoad must return the real current branch")
    }

    /// WHY: performLoad on a non-git directory must return a safe placeholder
    /// (isGitRepo:false) rather than crashing or hanging. The surface must
    /// be able to display the "not a git repo" empty state gracefully.
    func test_performLoad_nonGitDir_returnsPlaceholder() async throws {
        let dir = NSTemporaryDirectory() + "rc2-nonrepo-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let (loaded, branches) = await DiffPanelViewModel.performLoad(cwd: dir)
        let summary = try XCTUnwrap(loaded)

        XCTAssertFalse(summary.isGitRepo,
                       "performLoad on a non-git directory must return isGitRepo:false " +
                       "so the surface shows the not-a-repo empty state")
        XCTAssertNil(branches.current,
                     "performLoad on a non-git directory must return nil current branch")
    }
}
