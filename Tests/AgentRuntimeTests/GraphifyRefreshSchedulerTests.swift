import XCTest
import CoreModel
@testable import AgentRuntime

/// WHY: After the first index, code changes must re-trigger graphify update on send
/// (staleness + trailing rebuild). Without this, agents query a stale map forever.
final class GraphifyRefreshSchedulerTests: XCTestCase {
    private var tempRoot: URL!
    private var service: GraphifyWorkspaceService!
    private var updateCount = 0
    private var lastArgs: [String] = []
    private var simulatedHead = "aaa"

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphify-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        service = GraphifyWorkspaceService(appSupportDirectory: tempRoot.appendingPathComponent("graphs"))
        service.enabled = true
        service.autoEnsure = true
        service.maxAgeFresh = 3600 // isolate head/force tests from age
        service.minRebuildInterval = 0
        service.fseventsDebounce = 0.05
        updateCount = 0
        simulatedHead = "aaa"

        let fakeBin = tempRoot.appendingPathComponent("fake-graphify")
        try """
        #!/bin/sh
        mkdir -p graphify-out
        echo '{"nodes":[],"edges":[]}' > graphify-out/graph.json
        exit 0
        """.write(to: fakeBin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBin.path)
        service.binaryPathOverride = fakeBin.path

        service.runProcess = { [weak self] args, cwd, env in
            guard let self else { return (0, "", "") }
            self.updateCount += 1
            self.lastArgs = args
            // Honor GRAPHIFY_OUT absolute (App Support) or default repo graphify-out
            let outDir: URL
            if let gOut = env?["GRAPHIFY_OUT"], !gOut.isEmpty {
                outDir = URL(fileURLWithPath: gOut)
            } else {
                outDir = URL(fileURLWithPath: cwd).appendingPathComponent("graphify-out")
            }
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            try? "{\"nodes\":[{\"id\":\"n\(self.updateCount)\"}],\"edges\":[]}".write(
                to: outDir.appendingPathComponent("graph.json"),
                atomically: true,
                encoding: .utf8
            )
            return (0, "ok", "")
        }
        service.headProbe = { [weak self] _ in self?.simulatedHead }
    }

    override func tearDownWithError() throws {
        service.stopWatchingAll()
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func test_requestRefreshAfterHeadChangeTriggersSecondUpdate() throws {
        let repo = try makeGitRepo(named: "r1")
        guard let id = GraphifyGitProbe.identity(at: repo.path) else {
            return XCTFail("identity")
        }
        let checkout = id.checkout

        // First build at head aaa
        simulatedHead = "aaa"
        let first = service.ensureSync(checkout: checkout, mode: .update)
        XCTAssertEqual(first, .fresh)
        let afterFirst = updateCount

        // Same head → requestRefresh should not need another CLI run immediately
        // (may still no-op). Then change HEAD → must update.
        simulatedHead = "bbb"
        service.requestRefresh(checkout: checkout, force: false)
        waitForUpdate(beyond: afterFirst, timeout: 3)
        XCTAssertGreaterThan(updateCount, afterFirst, "head change must schedule a new update")
    }

    func test_trailingRerunWhenDirtyDuringBuild() throws {
        let repo = try makeGitRepo(named: "r2")
        guard let id = GraphifyGitProbe.identity(at: repo.path) else { return XCTFail("identity") }
        let checkout = id.checkout

        // Slow update
        service.runProcess = { [weak self] args, cwd, env in
            guard let self else { return (0, "", "") }
            self.updateCount += 1
            Thread.sleep(forTimeInterval: 0.2)
            let outDir: URL
            if let gOut = env?["GRAPHIFY_OUT"], !gOut.isEmpty {
                outDir = URL(fileURLWithPath: gOut)
            } else {
                outDir = URL(fileURLWithPath: cwd).appendingPathComponent("graphify-out")
            }
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            try? "{\"nodes\":[]}".write(to: outDir.appendingPathComponent("graph.json"), atomically: true, encoding: .utf8)
            return (0, "", "")
        }

        service.requestRefresh(checkout: checkout, force: true)
        // Mid-flight dirty
        Thread.sleep(forTimeInterval: 0.05)
        service.markDirtyFromFilesystem(checkout: checkout)
        // Wait for primary + trailing
        let deadline = Date().addingTimeInterval(3)
        while updateCount < 2 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertGreaterThanOrEqual(updateCount, 2, "dirty during build must produce trailing update")
    }

    func test_globalSingleFlightDefersSecondCheckoutUntilFirstCompletes() throws {
        // WHY: two agent threads rooted in different large checkouts must not run
        // graphify CLI concurrently, and the deferred checkout must not be lost.
        let firstRepo = try makeGitRepo(named: "single-flight-a")
        let secondRepo = try makeGitRepo(named: "single-flight-b")
        let firstCheckout = try XCTUnwrap(GraphifyGitProbe.identity(at: firstRepo.path)?.checkout)
        let secondCheckout = try XCTUnwrap(GraphifyGitProbe.identity(at: secondRepo.path)?.checkout)
        let stateLock = NSLock()
        let firstStarted = expectation(description: "first graphify update started")
        let releaseFirst = DispatchSemaphore(value: 0)
        var active = 0
        var maximumActive = 0
        var completedRoots = Set<String>()

        service.runProcess = { args, cwd, env in
            stateLock.lock()
            active += 1
            maximumActive = max(maximumActive, active)
            let isFirst = completedRoots.isEmpty
            stateLock.unlock()

            if isFirst {
                firstStarted.fulfill()
                _ = releaseFirst.wait(timeout: .now() + 3)
            }
            let outDir = env?["GRAPHIFY_OUT"].map(URL.init(fileURLWithPath:))
                ?? URL(fileURLWithPath: cwd).appendingPathComponent("graphify-out")
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            try? "{\"nodes\":[],\"edges\":[]}".write(
                to: outDir.appendingPathComponent("graph.json"),
                atomically: true,
                encoding: .utf8
            )

            stateLock.lock()
            active -= 1
            completedRoots.insert(cwd)
            stateLock.unlock()
            return (0, args.joined(separator: " "), "")
        }

        service.requestRefresh(checkout: firstCheckout, force: true)
        wait(for: [firstStarted], timeout: 2)
        service.requestRefresh(checkout: secondCheckout, force: true)

        stateLock.lock()
        let activeWhileFirstHeld = active
        let maxWhileFirstHeld = maximumActive
        stateLock.unlock()
        XCTAssertEqual(activeWhileFirstHeld, 1)
        XCTAssertEqual(maxWhileFirstHeld, 1, "the global gate must admit only one CLI child")

        releaseFirst.signal()
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            stateLock.lock()
            let complete = completedRoots.count == 2
            stateLock.unlock()
            if complete { break }
            Thread.sleep(forTimeInterval: 0.02)
        }

        stateLock.lock()
        let finalRoots = completedRoots
        let finalMaximum = maximumActive
        stateLock.unlock()
        XCTAssertEqual(finalRoots, Set([firstRepo.path, secondRepo.path]))
        XCTAssertEqual(finalMaximum, 1, "deferred work must remain globally single-flight")
    }

    func test_authoritativeResolveRefreshesEvenWhenGraphExists() throws {
        let repo = try makeGitRepo(named: "r3")
        guard let id = GraphifyGitProbe.identity(at: repo.path) else { return XCTFail("identity") }
        XCTAssertEqual(service.ensureSync(checkout: id.checkout), .fresh)
        let base = updateCount

        simulatedHead = "changed-head"
        _ = service.authoritativeResolve(
            threadId: nil,
            threadCwd: repo.path,
            worktreePath: nil,
            workspaceCwd: repo.path,
            attachmentPaths: []
        )
        waitForUpdate(beyond: base, timeout: 3)
        XCTAssertGreaterThan(updateCount, base, "send path must refresh when head/graph is stale")
    }

    func test_worktreesGetSeparateArtifactRoots() throws {
        let main = try makeGitRepo(named: "main")
        let wt = tempRoot.appendingPathComponent("wt", isDirectory: true)
        _ = run(["git", "worktree", "add", "-b", "feat", wt.path, "HEAD"], cwd: main.path)
        guard let m = GraphifyGitProbe.identity(at: main.path),
              let w = GraphifyGitProbe.identity(at: wt.path) else {
            return XCTFail("ids")
        }
        XCTAssertEqual(m.checkout.key, w.checkout.key)
        XCTAssertNotEqual(
            service.artifactRoot(for: m.checkout).path,
            service.artifactRoot(for: w.checkout).path,
            "divergent worktrees must not share artifact paths"
        )
    }

    // MARK: - helpers

    /// Test-only: write fingerprint via public ensure path side effects; if private, re-ensure.
    private func waitForUpdate(beyond: Int, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while updateCount <= beyond && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
        }
    }

    private func makeGitRepo(named: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(named, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertEqual(run(["git", "init"], cwd: url.path).0, 0)
        XCTAssertEqual(run(["git", "config", "user.email", "t@example.com"], cwd: url.path).0, 0)
        XCTAssertEqual(run(["git", "config", "user.name", "T"], cwd: url.path).0, 0)
        try "export const a = 1\n".write(to: url.appendingPathComponent("a.ts"), atomically: true, encoding: .utf8)
        XCTAssertEqual(run(["git", "add", "."], cwd: url.path).0, 0)
        XCTAssertEqual(run(["git", "commit", "-m", "i"], cwd: url.path).0, 0)
        return url.standardizedFileURL
    }

    private func run(_ args: [String], cwd: String) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }
}
