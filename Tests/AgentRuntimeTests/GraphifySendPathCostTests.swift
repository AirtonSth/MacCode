import XCTest
import CoreModel
@testable import AgentRuntime

/// WHY: every Agent App / bot desk send awaits Graphify root resolution before
/// the provider starts. In a multi-repo workspace that re-spawned `git` for
/// every candidate directory on every send — latency a terminal Distill run
/// never pays. Repeat sends must reuse the cached repo identities.
final class GraphifySendPathCostTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("graphify-send-\(UUID().uuidString)")
        for name in ["api", "web", "docs", "tools"] {
            let repo = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git", "init", "-q", repo.path]
            try p.run(); p.waitUntilExit()
        }
        for name in ["notes", "assets"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name).appendingPathComponent("sub"), withIntermediateDirectories: true)
        }
        GraphifyGitProbe.resetIdentityCacheForTesting()
    }

    override func tearDownWithError() throws {
        GraphifyGitProbe.resetIdentityCacheForTesting()
        try? FileManager.default.removeItem(at: root)
    }

    private func resolveLikeSend() -> GraphifyThreadWorkingSet {
        GraphifyRootResolver().resolve(
            threadId: UUID(),
            threadCwd: root.path,
            worktreePath: nil,
            workspaceCwd: root.path,
            attachmentPaths: []
        )
    }

    func test_repeatSendResolveReusesRepoIdentities() {
        let clock = ContinuousClock()
        GraphifyGitProbe.gitSpawnCountForTesting = 0
        let coldStart = clock.now
        let cold = resolveLikeSend()
        let coldElapsed = coldStart.duration(to: clock.now)
        let coldSpawns = GraphifyGitProbe.gitSpawnCountForTesting

        GraphifyGitProbe.gitSpawnCountForTesting = 0
        let warmStart = clock.now
        let warm = resolveLikeSend()
        let warmElapsed = warmStart.duration(to: clock.now)
        let warmSpawns = GraphifyGitProbe.gitSpawnCountForTesting

        print("PERF graphifySend coldSpawns=\(coldSpawns) coldMs=\(coldElapsed) warmSpawns=\(warmSpawns) warmMs=\(warmElapsed)")
        XCTAssertGreaterThan(coldSpawns, 0, "the first send must probe the real checkouts")
        XCTAssertEqual(warmSpawns, 0, "a repeat send within the TTL must not spawn git")
        XCTAssertEqual(cold.workspaceKind, warm.workspaceKind, "cached identities must classify the workspace the same way")
        XCTAssertEqual(cold.roots.map(\.checkout), warm.roots.map(\.checkout))
    }

    func test_newRepoIsSeenAfterTTLExpiry() throws {
        let plain = root.appendingPathComponent("notes")
        XCTAssertNil(GraphifyGitProbe.identity(at: plain.path))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "init", "-q", plain.path]
        try p.run(); p.waitUntilExit()
        GraphifyGitProbe.resetIdentityCacheForTesting()
        XCTAssertNotNil(GraphifyGitProbe.identity(at: plain.path), "after the cache window the real repo must resolve")
    }
}
