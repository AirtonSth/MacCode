import XCTest
import CoreModel
@testable import AgentRuntime

/// WHY: Multi-repo containers like empath/ must never become graph roots; worktrees
/// must collapse to one GraphifyRepoKey; empty multi-repo must stay ambiguous.
final class GraphifyRootResolverTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphify-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
    }

    func test_repoKeyEqualityIgnoresDisplayRoot() {
        let key = GraphifyRepoKey(commonDir: "/tmp/repo/.git")
        let a = GraphifyCheckout(key: key, displayRoot: "/tmp/repo")
        let b = GraphifyCheckout(key: key, displayRoot: "/tmp/worktrees/repo-w1")
        XCTAssertEqual(a.key, b.key)
        XCTAssertEqual(a.key.hashValue, b.key.hashValue)
        XCTAssertNotEqual(a.displayRoot, b.displayRoot)
    }

    func test_singleRepo_workspaceIsRoot() throws {
        let repo = try makeGitRepo(named: "api-v2")
        let resolver = GraphifyRootResolver()
        let kind = resolver.classify(workspaceCwd: repo.path)
        guard case .singleRepo(let checkout) = kind else {
            return XCTFail("expected singleRepo, got \(kind)")
        }
        XCTAssertEqual(checkout.displayRoot, repo.path)

        let set = resolver.resolve(
            threadCwd: repo.path,
            worktreePath: nil,
            workspaceCwd: repo.path
        )
        XCTAssertEqual(set.roots.count, 1)
        XCTAssertFalse(set.ambiguous)
        XCTAssertEqual(set.workspaceKind, "singleRepo")
    }

    func test_multiRepoContainer_neverUsesParent() throws {
        let container = tempRoot.appendingPathComponent("empath", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let api = try makeGitRepo(named: "empath-api-v2", parent: container)
        let ui = try makeGitRepo(named: "empath-ui", parent: container)
        _ = api; _ = ui

        let resolver = GraphifyRootResolver()
        let kind = resolver.classify(workspaceCwd: container.path)
        guard case .multiRepoContainer(let children) = kind else {
            return XCTFail("expected multiRepoContainer, got \(kind)")
        }
        XCTAssertEqual(children.count, 2)

        let empty = resolver.resolve(
            threadCwd: container.path,
            worktreePath: nil,
            workspaceCwd: container.path
        )
        XCTAssertTrue(empty.roots.isEmpty, "parent cwd must not invent product roots")
        XCTAssertTrue(empty.ambiguous)
        XCTAssertFalse(empty.roots.contains { $0.checkout.displayRoot == container.path })
    }

    func test_multiRepo_attachmentSelectsChild() throws {
        let container = tempRoot.appendingPathComponent("empath2", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let api = try makeGitRepo(named: "empath-api-v2", parent: container)
        let ui = try makeGitRepo(named: "empath-ui", parent: container)
        let file = ui.appendingPathComponent("src/App.tsx")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "export const App = () => null".write(to: file, atomically: true, encoding: .utf8)

        let set = GraphifyRootResolver().resolve(
            threadCwd: container.path,
            worktreePath: nil,
            workspaceCwd: container.path,
            attachmentPaths: [file.path]
        )
        XCTAssertEqual(set.roots.count, 1)
        XCTAssertEqual(set.roots[0].checkout.displayRoot, ui.path)
        XCTAssertEqual(set.roots[0].reason, "attachment")
        XCTAssertFalse(set.ambiguous)
        _ = api
    }

    func test_worktreeCollapsesToSameKey() throws {
        let main = try makeGitRepo(named: "main-repo")
        // Create a linked worktree
        let wt = tempRoot.appendingPathComponent("wt-main", isDirectory: true)
        let r = run(["git", "worktree", "add", "-b", "feature-wt", wt.path, "HEAD"], cwd: main.path)
        XCTAssertEqual(r.exit, 0, r.stderr)

        let mainId = GraphifyGitProbe.identity(at: main.path)
        let wtId = GraphifyGitProbe.identity(at: wt.path)
        XCTAssertNotNil(mainId)
        XCTAssertNotNil(wtId)
        XCTAssertEqual(mainId?.checkout.key, wtId?.checkout.key, "worktree must share GraphifyRepoKey")
        XCTAssertNotEqual(mainId?.toplevel, wtId?.toplevel)
    }

    func test_stickyPinBootstrapsMultiRepo() throws {
        let container = tempRoot.appendingPathComponent("empath3", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let api = try makeGitRepo(named: "empath-api-v2", parent: container)
        _ = try makeGitRepo(named: "empath-ui", parent: container)

        let resolver = GraphifyRootResolver(stickyLastTouchedRoot: api.path)
        let set = resolver.resolve(
            threadCwd: container.path,
            worktreePath: nil,
            workspaceCwd: container.path
        )
        XCTAssertEqual(set.roots.count, 1)
        XCTAssertEqual(set.roots[0].checkout.displayRoot, api.path)
        XCTAssertEqual(set.roots[0].reason, "sticky_pin")
    }

    // MARK: - helpers

    private func makeGitRepo(named: String, parent: URL? = nil) throws -> URL {
        let base = parent ?? tempRoot!
        let url = base.appendingPathComponent(named, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var r = run(["git", "init"], cwd: url.path)
        XCTAssertEqual(r.exit, 0, r.stderr)
        r = run(["git", "config", "user.email", "test@example.com"], cwd: url.path)
        XCTAssertEqual(r.exit, 0)
        r = run(["git", "config", "user.name", "Test"], cwd: url.path)
        XCTAssertEqual(r.exit, 0)
        try "export const n = 1\n".write(to: url.appendingPathComponent("index.ts"), atomically: true, encoding: .utf8)
        r = run(["git", "add", "."], cwd: url.path)
        XCTAssertEqual(r.exit, 0, r.stderr)
        r = run(["git", "commit", "-m", "init"], cwd: url.path)
        XCTAssertEqual(r.exit, 0, r.stderr)
        return url.standardizedFileURL
    }

    private func run(_ args: [String], cwd: String) -> (exit: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try? p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (
            p.terminationStatus,
            String(data: o, encoding: .utf8) ?? "",
            String(data: e, encoding: .utf8) ?? ""
        )
    }
}
