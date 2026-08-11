import XCTest
import CoreModel
@testable import AgentRuntime

/// WHY: ArtifactRoot must be unique per commonDir; binary missing is fail-open unavailable;
/// real `graphify update` must produce a canonical graph.json when CLI is present.
final class GraphifyWorkspaceServiceTests: XCTestCase {
    private var tempRoot: URL!
    private var service: GraphifyWorkspaceService!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphify-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        service = GraphifyWorkspaceService(appSupportDirectory: tempRoot.appendingPathComponent("graphs"))
        service.enabled = true
        service.autoEnsure = false
    }

    override func tearDownWithError() throws {
        service?.runProcess = nil
        service?.headProbe = nil
        service?.checkoutIdentityProbe = nil
        service?.setPressurePauseEnsureAndWatch(false)
        service?.enabled = false
        service?.autoEnsure = false
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        service = nil
    }

    func test_artifactRootStableForSameCheckout() {
        let key = GraphifyRepoKey(commonDir: "/repo/.git")
        let checkout = GraphifyCheckout(key: key, displayRoot: "/repo")
        let a = service.artifactRoot(for: checkout)
        let b = service.artifactRoot(for: GraphifyCheckout(key: key, displayRoot: "/repo"))
        XCTAssertEqual(a.path, b.path)
        XCTAssertTrue(a.path.contains(checkout.artifactDirectoryName))
    }

    func test_applyToAgentEnvironmentStripsGraphifyWhenDisabled() {
        // WHY: Token Saver / Graphify off must not leave RC_GRAPHIFY_* that re-enable prompts.
        service.enabled = false
        let applied = service.applyToAgentEnvironment(
            base: [
                "RC_GRAPHIFY_ENABLED": "1",
                "RC_GRAPHIFY_GRAPH_JSON": "/stale/graph.json",
                "PATH": "/usr/bin"
            ],
            threadId: nil,
            threadCwd: tempRoot.path,
            worktreePath: nil,
            workspaceCwd: tempRoot.path,
            attachmentPaths: []
        )
        XCTAssertNil(applied.environment["RC_GRAPHIFY_ENABLED"])
        XCTAssertNil(applied.environment["RC_GRAPHIFY_GRAPH_JSON"])
        XCTAssertEqual(applied.environment["PATH"], "/usr/bin")
        XCTAssertEqual(applied.workingSet.workspaceKind, "disabled")
    }

    func test_verifyMissingBinaryIsUnavailable() {
        service.binaryPathOverride = "/nonexistent/graphify-\(UUID().uuidString)"
        let checkout = GraphifyCheckout(key: GraphifyRepoKey(commonDir: "/x/.git"), displayRoot: "/x")
        XCTAssertEqual(service.verify(checkout), .unavailable)
    }

    func test_resolveBinaryHonorsOverride() throws {
        let fake = tempRoot.appendingPathComponent("fake-graphify")
        try """
        #!/bin/sh
        exit 0
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        service.binaryPathOverride = fake.path
        XCTAssertEqual(service.resolveBinary(), fake.path)
    }

    func test_ensureSyncWithRealGraphifyCLI() throws {
        // Real e2e against installed graphify + real tiny git repo.
        let graphify = "/Users/samuelfajreldines/.local/bin/graphify"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: graphify), "graphify CLI not installed")

        let repo = try makeGitRepo(named: "tiny")
        service.binaryPathOverride = graphify
        service.enabled = true

        guard let id = GraphifyGitProbe.identity(at: repo.path) else {
            return XCTFail("repo identity")
        }
        service.writeInRepo = false
        let status = service.ensureSync(checkout: id.checkout, mode: .update)
        XCTAssertEqual(status, .fresh, "real graphify update must produce fresh status")
        let graph = service.graphJSONPath(for: id.checkout)
        XCTAssertTrue(FileManager.default.fileExists(atPath: graph.path), "canonical ArtifactRoot graph.json")
        let data = try Data(contentsOf: graph)
        XCTAssertGreaterThan(data.count, 50)
        // Default: do not pollute the working tree
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: repo.appendingPathComponent("graphify-out").path),
            "default writeInRepo=false must not create graphify-out in the repo"
        )
    }

    func test_softPreflightMultiRepoAutoBootstrapsOneChildNeverParent() throws {
        let container = tempRoot.appendingPathComponent("multi", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let a = try makeGitRepo(named: "a", parent: container)
        _ = try makeGitRepo(named: "b", parent: container)
        service.enabled = true
        service.autoEnsure = false
        let set = service.softPreflight(workspaceCwd: container.path)
        XCTAssertEqual(set.workspaceKind, "multiRepoContainer")
        XCTAssertEqual(set.roots.count, 1, "auto-bootstrap must pick one product child without user input")
        XCTAssertFalse(set.ambiguous)
        XCTAssertNotEqual(set.roots[0].checkout.displayRoot, container.path)
        XCTAssertTrue(
            set.roots[0].checkout.displayRoot.hasPrefix(container.path + "/"),
            "bootstrap root must be under the container"
        )
        _ = a
    }

    func test_graphifyProviderPromptInjectsWhenEnabled() {
        let base = "User request:\nhello"
        let off = AgentSkillInstaller.graphifyProviderPrompt(base, environment: [:])
        XCTAssertEqual(off, base)
        let on = AgentSkillInstaller.graphifyProviderPrompt(base, environment: [
            "RC_GRAPHIFY_ENABLED": "1",
            "RC_GRAPHIFY_GRAPH_JSON": "/tmp/g.json",
            "RC_GRAPHIFY_ROOTS": "/repo/a",
            "RC_GRAPHIFY_ARTIFACT_ROOT": "/tmp/artifacts/a"
        ])
        XCTAssertTrue(on.contains("Graphify"), on)
        XCTAssertTrue(on.contains("graphify query"), on)
        XCTAssertTrue(on.contains("/tmp/g.json"), on)
        XCTAssertTrue(on.contains("/repo/a"), on)
        // WHY: agents must not treat missing repo graphify-out/ as "no graph".
        XCTAssertTrue(on.contains("RC_GRAPHIFY_GRAPH_JSON"), on)
        XCTAssertTrue(on.contains("NOT `./graphify-out/`") || on.contains("not repo graphify-out"), on)
        XCTAssertTrue(on.contains("/tmp/artifacts/a"), on)
    }

    func test_graphifyStableSkillTextPointsAtCanonicalPathNotRepoOut() {
        let body = GraphifyStableSkillText.agentInstructionsBody
        XCTAssertTrue(body.contains("RC_GRAPHIFY_GRAPH_JSON"), body)
        XCTAssertTrue(body.contains("Application Support") || body.contains("NOT `./graphify-out/`"), body)
        XCTAssertTrue(body.contains("Never answer \"no graph\"") || body.contains("does NOT mean there is no graph"), body)

        let withGraph = GraphifyStableSkillText.augmentTurnPrompt("hi", environment: [
            "RC_GRAPHIFY_ENABLED": "1",
            "RC_GRAPHIFY_GRAPH_JSON": "/tmp/canonical/graph.json"
        ])
        // Banner must lead the prompt (models ignore trailing rules).
        XCTAssertTrue(withGraph.hasPrefix("HOST GRAPHIFY STATUS"), withGraph)
        XCTAssertTrue(withGraph.contains("Graph EXISTS at absolute path: /tmp/canonical/graph.json"), withGraph)
        XCTAssertTrue(withGraph.contains("not repo ./graphify-out") || withGraph.contains("NOT repo ./graphify-out"), withGraph)

        let noPath = GraphifyStableSkillText.augmentTurnPrompt("hi", environment: [
            "RC_GRAPHIFY_ENABLED": "1"
        ])
        XCTAssertTrue(noPath.contains("HOST GRAPHIFY STATUS"), noPath)
        XCTAssertTrue(noPath.contains("do NOT answer") || noPath.contains("NORMAL"), noPath)

        let injected = AgentSkillInstaller.graphifyProviderPrompt(
            "User request:\ntem graph aqui?",
            environment: [
                "RC_GRAPHIFY_ENABLED": "1",
                "RC_GRAPHIFY_GRAPH_JSON": "/tmp/canonical/graph.json"
            ]
        )
        XCTAssertTrue(injected.hasPrefix("HOST GRAPHIFY STATUS"), injected)
        XCTAssertTrue(injected.contains("/tmp/canonical/graph.json"), injected)
        XCTAssertTrue(injected.contains("tem graph aqui?"), injected)
    }

    func test_tokenSaverProviderPromptAlsoChainsGraphify() {
        let base = "hello"
        let combined = AgentSkillInstaller.tokenSaverProviderPrompt(base, environment: [
            "RC_GRAPHIFY_ENABLED": "1"
        ])
        XCTAssertTrue(combined.contains("graphify query"))
    }

    func test_failedUpdateWithExistingGraphReturnsStaleNotFresh() throws {
        let checkout = GraphifyCheckout(
            key: GraphifyRepoKey(commonDir: tempRoot.appendingPathComponent("fail.git").path),
            displayRoot: tempRoot.appendingPathComponent("fail-proj").path
        )
        try FileManager.default.createDirectory(atPath: checkout.displayRoot, withIntermediateDirectories: true)
        // Seed a previous good graph in the artifact root
        let dest = service.graphJSONPath(for: checkout)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"nodes\":[]}".write(to: dest, atomically: true, encoding: .utf8)

        service.binaryPathOverride = tempRoot.appendingPathComponent("failing-graphify").path
        try "#!/bin/sh\nexit 2\n".write(to: URL(fileURLWithPath: service.binaryPathOverride!), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: service.binaryPathOverride!)
        service.runProcess = { _, _, env in
            // Leave existing graph; fail the CLI
            return (2, "", "boom")
        }
        service.writeInRepo = false
        let status = service.ensureSync(checkout: checkout, mode: .update)
        XCTAssertEqual(status, .stale, "failed CLI must not advance fingerprint as fresh")
    }

    /// Codex IMPORTANT: pressure unpause must not block the caller with git Process I/O,
    /// and must revalidate enabled before ensure (Token Saver-off fail-open).
    func test_pressureUnpause_asyncReKick_abortsWhenDisabledMidProbe() {
        service.enabled = true
        service.autoEnsure = true
        service.headProbe = { _ in "deadbeef" }
        var ensureCLIStarts = 0
        let ensureLock = NSLock()
        service.runProcess = { _, _, _ in
            ensureLock.lock(); ensureCLIStarts += 1; ensureLock.unlock()
            return (0, "", "")
        }

        let displayRoot = tempRoot.appendingPathComponent("paused-proj", isDirectory: true)
        try? FileManager.default.createDirectory(at: displayRoot, withIntermediateDirectories: true)
        let checkout = GraphifyCheckout(
            key: GraphifyRepoKey(commonDir: displayRoot.appendingPathComponent(".git").path),
            displayRoot: displayRoot.path
        )

        let probeEntered = expectation(description: "identity probe entered")
        let releaseProbe = DispatchSemaphore(value: 0)
        service.checkoutIdentityProbe = { root in
            probeEntered.fulfill()
            releaseProbe.wait()
            return GraphifyCheckout(
                key: GraphifyRepoKey(commonDir: root + "/.git"),
                displayRoot: root
            )
        }

        service.setPressurePauseEnsureAndWatch(true)
        service.requestRefresh(checkout: checkout, force: true)

        let started = Date()
        service.setPressurePauseEnsureAndWatch(false)
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            0.25,
            "unpause must return without waiting on blocking identity probe"
        )

        wait(for: [probeEntered], timeout: 2.0)
        // Disable Graphify while async re-kick is mid-probe (Token Saver-off).
        service.enabled = false
        releaseProbe.signal()
        // Allow async queue to finish.
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }

        ensureLock.lock(); let starts = ensureCLIStarts; ensureLock.unlock()
        XCTAssertEqual(
            starts,
            0,
            "after disable mid-probe, pressure re-kick must not start ensure CLI"
        )
        service.setPressurePauseEnsureAndWatch(false)
        service.checkoutIdentityProbe = nil
    }

    /// FSEvents/dirty during pressure pause must not schedule ensure work.
    func test_markDirtyDuringPressurePause_doesNotStartEnsure() {
        service.enabled = true
        service.autoEnsure = true
        service.headProbe = { _ in "paused-head" }
        var cliStarts = 0
        let cliLock = NSLock()
        service.runProcess = { _, _, _ in
            cliLock.lock(); cliStarts += 1; cliLock.unlock()
            return (0, "", "")
        }
        let displayRoot = tempRoot.appendingPathComponent("fsevents-paused", isDirectory: true)
        try? FileManager.default.createDirectory(at: displayRoot, withIntermediateDirectories: true)
        let checkout = GraphifyCheckout(
            key: GraphifyRepoKey(commonDir: displayRoot.appendingPathComponent(".git").path),
            displayRoot: displayRoot.path
        )

        service.setPressurePauseEnsureAndWatch(true)
        service.markDirtyFromFilesystem(checkout: checkout)
        service.requestRefresh(checkout: checkout, force: true)
        Thread.sleep(forTimeInterval: 0.15)
        cliLock.lock(); let duringPause = cliStarts; cliLock.unlock()
        XCTAssertEqual(duringPause, 0, "pressure pause must not run ensure from dirty/refresh")

        // Unpause should re-kick the preserved dirty work.
        let ensureStarted = expectation(description: "ensure after unpause")
        ensureStarted.assertForOverFulfill = false
        var fulfilled = false
        service.runProcess = { _, _, _ in
            if !fulfilled {
                fulfilled = true
                ensureStarted.fulfill()
            }
            return (0, "", "")
        }
        service.checkoutIdentityProbe = { root in
            GraphifyCheckout(
                key: GraphifyRepoKey(commonDir: root + "/.git"),
                displayRoot: root
            )
        }
        service.setPressurePauseEnsureAndWatch(false)
        wait(for: [ensureStarted], timeout: 3.0)
    }

    /// startEnsureIfNeeded must not launch CLI if disabled during unlocked head probe.
    func test_startEnsure_abortsWhenDisabledDuringHeadProbe() {
        service.enabled = true
        service.autoEnsure = true
        let probeEntered = expectation(description: "head probe entered")
        let releaseProbe = DispatchSemaphore(value: 0)
        service.headProbe = { _ in
            probeEntered.fulfill()
            releaseProbe.wait()
            return "head-during-disable"
        }
        var cliStarts = 0
        let cliLock = NSLock()
        service.runProcess = { _, _, _ in
            cliLock.lock(); cliStarts += 1; cliLock.unlock()
            return (0, "", "")
        }
        let displayRoot = tempRoot.appendingPathComponent("disable-mid-head", isDirectory: true)
        try? FileManager.default.createDirectory(at: displayRoot, withIntermediateDirectories: true)
        let checkout = GraphifyCheckout(
            key: GraphifyRepoKey(commonDir: displayRoot.appendingPathComponent(".git").path),
            displayRoot: displayRoot.path
        )

        DispatchQueue.global(qos: .userInitiated).async {
            self.service.requestRefresh(checkout: checkout, force: true)
        }
        wait(for: [probeEntered], timeout: 2.0)
        service.enabled = false
        releaseProbe.signal()
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        cliLock.lock(); let starts = cliStarts; cliLock.unlock()
        XCTAssertEqual(starts, 0, "disabled mid-headProbe must not launch graphify CLI")
    }

    func test_pressureUnpause_reKickRunsWhenStillEnabled() {
        service.enabled = true
        service.autoEnsure = true
        service.headProbe = { _ in "cafebabe" }
        let ensureStarted = expectation(description: "ensure CLI started")
        ensureStarted.assertForOverFulfill = false
        let fulfillLock = NSLock()
        var fulfilled = false
        service.runProcess = { _, _, _ in
            fulfillLock.lock()
            if !fulfilled {
                fulfilled = true
                fulfillLock.unlock()
                ensureStarted.fulfill()
            } else {
                fulfillLock.unlock()
            }
            return (0, "", "")
        }

        let displayRoot = tempRoot.appendingPathComponent("live-proj", isDirectory: true)
        try? FileManager.default.createDirectory(at: displayRoot, withIntermediateDirectories: true)
        let checkout = GraphifyCheckout(
            key: GraphifyRepoKey(commonDir: displayRoot.appendingPathComponent(".git").path),
            displayRoot: displayRoot.path
        )
        service.checkoutIdentityProbe = { root in
            GraphifyCheckout(
                key: GraphifyRepoKey(commonDir: root + "/.git"),
                displayRoot: root
            )
        }

        service.setPressurePauseEnsureAndWatch(true)
        service.requestRefresh(checkout: checkout, force: true)
        service.setPressurePauseEnsureAndWatch(false)

        wait(for: [ensureStarted], timeout: 3.0)
    }

    // MARK: helpers

    private func makeGitRepo(named: String, parent: URL? = nil) throws -> URL {
        let base = parent ?? tempRoot!
        let url = base.appendingPathComponent(named, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        func run(_ args: [String]) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = args
            p.currentDirectoryURL = url
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        XCTAssertEqual(run(["git", "init"]), 0)
        XCTAssertEqual(run(["git", "config", "user.email", "t@example.com"]), 0)
        XCTAssertEqual(run(["git", "config", "user.name", "T"]), 0)
        try """
        export function add(a: number, b: number) { return a + b }
        export const name = "tiny"
        """.write(to: url.appendingPathComponent("lib.ts"), atomically: true, encoding: .utf8)
        XCTAssertEqual(run(["git", "add", "."]), 0)
        XCTAssertEqual(run(["git", "commit", "-m", "init"]), 0)
        return url.standardizedFileURL
    }
}
