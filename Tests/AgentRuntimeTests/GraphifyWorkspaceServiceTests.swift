import XCTest
import CoreModel
import Darwin
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
        service?.beforeMarkDirtyLockForTesting = nil
        service?.beforeWatchCheckoutLockForTesting = nil
        service?.beforeVerifyScheduleWarmLockForTesting = nil
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

    func test_missingBinaryLeavesDirtyWorkForLaterWithoutImmediateRetryLoop() {
        // WHY: CI and fresh installs legitimately have no Graphify binary. One
        // forced refresh may probe once, but an unavailable result must not
        // recursively enqueue work until the process exhausts CPU and memory.
        service.autoEnsure = true
        service.binaryPathOverride = "/nonexistent/graphify-\(UUID().uuidString)"
        let displayRoot = tempRoot.appendingPathComponent("missing-binary", isDirectory: true)
        try? FileManager.default.createDirectory(at: displayRoot, withIntermediateDirectories: true)
        let checkout = GraphifyCheckout(
            key: GraphifyRepoKey(commonDir: displayRoot.appendingPathComponent(".git").path),
            displayRoot: displayRoot.path
        )
        let firstProbe = expectation(description: "single scheduled refresh probe")
        firstProbe.assertForOverFulfill = false
        let countLock = NSLock()
        var probeCount = 0
        service.headProbe = { _ in
            countLock.lock()
            probeCount += 1
            let count = probeCount
            countLock.unlock()
            if count == 1 { firstProbe.fulfill() }
            return nil
        }

        service.requestRefresh(checkout: checkout, force: true)
        wait(for: [firstProbe], timeout: 2)
        Thread.sleep(forTimeInterval: 0.2)
        service.enabled = false

        countLock.lock()
        let finalProbeCount = probeCount
        countLock.unlock()
        XCTAssertEqual(
            finalProbeCount,
            1,
            "an unavailable attempt stays dirty for a future send instead of immediately retrying forever"
        )
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
    func test_startEnsure_abortsWhenDisabledDuringHeadProbe() throws {
        service.enabled = true
        service.autoEnsure = true
        let fakeBinary = tempRoot.appendingPathComponent("fake-graphify-disable-mid-head")
        try "#!/bin/sh\nexit 0\n".write(to: fakeBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)
        service.binaryPathOverride = fakeBinary.path
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

    func test_watchedCheckoutsAreBounded_becauseEveryVisitedRepoKeptAnFSEventStreamForever() throws {
        // WHY: one FSEvents stream per checkout ever refreshed stayed alive for the
        // app lifetime; switching repos for months accumulated streams and callbacks.
        service.autoEnsure = true
        let limit = GraphifyWorkspaceService.maxWatchedCheckouts
        var checkouts: [GraphifyCheckout] = []
        for index in 0..<(limit + 10) {
            let root = tempRoot.appendingPathComponent("watched-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let checkout = GraphifyCheckout(
                key: GraphifyRepoKey(commonDir: root.appendingPathComponent(".git").path),
                displayRoot: root.path
            )
            checkouts.append(checkout)
            XCTAssertTrue(service.watchCheckout(checkout))
        }
        XCTAssertEqual(service.lifecycleSnapshotForTesting.watchers, limit)
        // Re-watching a recent checkout keeps it; re-watching an evicted one re-arms it within the bound.
        XCTAssertTrue(service.watchCheckout(checkouts.last!))
        XCTAssertTrue(service.watchCheckout(checkouts.first!))
        XCTAssertEqual(service.lifecycleSnapshotForTesting.watchers, limit)
        service.stopWatchingAll()
        XCTAssertEqual(service.lifecycleSnapshotForTesting.watchers, 0)
    }

    func test_stopWatchingAll_releasesPendingDebounces_and_rearmsOnNextRefresh() throws {
        // WHY: Token Saver OFF must release delayed work immediately, while the
        // retained schedule still forces the next active checkout refresh and
        // the rearmed real FSEventStream must observe later source edits.
        service.autoEnsure = true
        service.fseventsDebounce = 0.01
        let root = tempRoot.appendingPathComponent("toggle-rearm", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let checkout = GraphifyCheckout(
            key: GraphifyRepoKey(commonDir: root.appendingPathComponent(".git").path),
            displayRoot: root.path
        )
        let fakeBinary = tempRoot.appendingPathComponent("fake-graphify-toggle")
        try "#!/bin/sh\nexit 0\n".write(to: fakeBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)
        service.binaryPathOverride = fakeBinary.path
        service.headProbe = { _ in "toggle-head" }
        let runLock = NSLock()
        var updateStarts = 0
        service.runProcess = { args, _, environment in
            guard args.first == fakeBinary.path, args.dropFirst().first == "update" else {
                return (0, "", "")
            }
            if let output = environment?["GRAPHIFY_OUT"] {
                try? FileManager.default.createDirectory(
                    atPath: output,
                    withIntermediateDirectories: true
                )
                try? "{\"nodes\":[]}".write(
                    to: URL(fileURLWithPath: output).appendingPathComponent("graph.json"),
                    atomically: true,
                    encoding: .utf8
                )
            }
            runLock.lock(); updateStarts += 1; runLock.unlock()
            return (0, "", "")
        }
        XCTAssertEqual(service.ensureSync(checkout: checkout), .fresh)
        runLock.lock(); updateStarts = 0; runLock.unlock()
        service.checkoutIdentityProbe = { _ in checkout }

        service.watchCheckout(checkout)
        service.markDirtyFromFilesystem(checkout: checkout)
        XCTAssertEqual(service.lifecycleSnapshotForTesting.watchers, 1)
        XCTAssertEqual(service.lifecycleSnapshotForTesting.debounceTasks, 1)

        service.enabled = false
        service.stopWatchingAll()
        let disabled = service.lifecycleSnapshotForTesting
        XCTAssertEqual(disabled.watchers, 0)
        XCTAssertEqual(disabled.debounceTasks, 0, "OFF must not retain a delayed task per checkout")
        XCTAssertEqual(disabled.schedules, 1, "dirty schedule is the rearm authority")

        service.enabled = true
        service.resumeAfterDisable()
        service.requestRefresh(checkout: checkout)
        XCTAssertEqual(service.lifecycleSnapshotForTesting.watchers, 1, "next active refresh rearms FSEvents")
        XCTAssertEqual(service.lifecycleSnapshotForTesting.schedules, 1)

        var deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            runLock.lock(); let starts = updateStarts; runLock.unlock()
            if starts >= 1, service.verify(checkout) == .fresh { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        runLock.lock(); let resumeStarts = updateStarts; updateStarts = 0; runLock.unlock()
        XCTAssertEqual(resumeStarts, 1, "dirty work retained through OFF must rebuild once")

        try "let changed = true\n".write(
            to: root.appendingPathComponent("Changed.swift"),
            atomically: true,
            encoding: .utf8
        )
        deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            runLock.lock(); let starts = updateStarts; runLock.unlock()
            if starts >= 1 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        runLock.lock(); let postRearmStarts = updateStarts; runLock.unlock()
        XCTAssertEqual(postRearmStarts, 1, "rearmed FSEvents must rebuild after a real source write")
    }

    func test_completedDebounce_releasesItsRegistryEntry() throws {
        // WHY: a checkout touched once must not retain its completed work item
        // for the lifetime of the app.
        service.autoEnsure = true
        service.fseventsDebounce = 0.01
        service.binaryPathOverride = "/nonexistent/graphify-\(UUID().uuidString)"
        service.headProbe = { _ in nil }
        let root = tempRoot.appendingPathComponent("completed-debounce", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let checkout = GraphifyCheckout(
            key: GraphifyRepoKey(commonDir: root.appendingPathComponent(".git").path),
            displayRoot: root.path
        )

        service.markDirtyFromFilesystem(checkout: checkout)
        let deadline = Date().addingTimeInterval(1)
        while service.lifecycleSnapshotForTesting.debounceTasks != 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(
            service.lifecycleSnapshotForTesting.debounceTasks,
            0,
            "a fired debounce must release its retained checkout/work item"
        )
    }

    func test_disableRacingAdmittedFilesystemCallback_leavesNoDelayedWork() throws {
        // WHY: the callback can pass the unlocked public gate just before the
        // settings thread turns Graphify off. Revalidate under the scheduler lock.
        service.autoEnsure = true
        service.fseventsDebounce = 30
        let root = tempRoot.appendingPathComponent("disable-race", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let checkout = GraphifyCheckout(
            key: GraphifyRepoKey(commonDir: root.appendingPathComponent(".git").path),
            displayRoot: root.path
        )
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        service.beforeMarkDirtyLockForTesting = {
            entered.signal()
            release.wait()
        }
        let finished = expectation(description: "filesystem callback finished")
        DispatchQueue.global(qos: .userInitiated).async {
            self.service.markDirtyFromFilesystem(checkout: checkout)
            finished.fulfill()
        }

        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        service.enabled = false
        service.stopWatchingAll()
        release.signal()
        wait(for: [finished], timeout: 1)

        let disabled = service.lifecycleSnapshotForTesting
        XCTAssertEqual(disabled.watchers, 0)
        XCTAssertEqual(disabled.schedules, 0)
        XCTAssertEqual(disabled.debounceTasks, 0)
    }

    func test_disableRacingAdmittedRefresh_doesNotInstallWatcherAfterStop() throws {
        // WHY: refresh can pass its unlocked gate before OFF, then reach watcher
        // registration only after stopWatchingAll has already returned.
        service.autoEnsure = true
        service.binaryPathOverride = "/nonexistent/graphify-\(UUID().uuidString)"
        let root = tempRoot.appendingPathComponent("refresh-disable-race", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let checkout = GraphifyCheckout(
            key: GraphifyRepoKey(commonDir: root.appendingPathComponent(".git").path),
            displayRoot: root.path
        )
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        service.beforeWatchCheckoutLockForTesting = {
            entered.signal()
            release.wait()
        }
        let finished = expectation(description: "admitted refresh finished")
        DispatchQueue.global(qos: .userInitiated).async {
            self.service.requestRefresh(checkout: checkout)
            finished.fulfill()
        }

        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        service.enabled = false
        service.stopWatchingAll()
        release.signal()
        wait(for: [finished], timeout: 1)

        let disabled = service.lifecycleSnapshotForTesting
        XCTAssertEqual(disabled.watchers, 0, "OFF must linearize before late watcher registration")
        XCTAssertEqual(disabled.schedules, 0)
        XCTAssertEqual(disabled.debounceTasks, 0)
    }

    func test_disableDuringRefreshVerify_doesNotRecreateColdScheduleAfterStop() throws {
        // WHY: verify performs disk/git probes outside the scheduler lock. OFF
        // must prevent its cold fingerprint warm-up from recreating retained
        // schedule state after stopWatchingAll has returned.
        let raceService = GraphifyWorkspaceService(appSupportDirectory: tempRoot.appendingPathComponent("race-graphs"))
        raceService.enabled = true
        raceService.autoEnsure = true
        raceService.headProbe = { _ in "race-head" }
        let fakeBinary = tempRoot.appendingPathComponent("fake-graphify-race")
        try "#!/bin/sh\nexit 0\n".write(to: fakeBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)
        raceService.binaryPathOverride = fakeBinary.path
        defer {
            raceService.beforeVerifyScheduleWarmLockForTesting = nil
            raceService.enabled = false
            raceService.stopWatchingAll()
        }

        let root = tempRoot.appendingPathComponent("verify-disable-race", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let checkout = GraphifyCheckout(
            key: GraphifyRepoKey(commonDir: root.appendingPathComponent(".git").path),
            displayRoot: root.path
        )
        let artifact = raceService.artifactRoot(for: checkout)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        try "{\"nodes\":[]}".write(
            to: artifact.appendingPathComponent("graph.json"),
            atomically: true,
            encoding: .utf8
        )
        let fingerprint = try JSONSerialization.data(withJSONObject: [
            "head": "race-head",
            "displayRoot": root.path,
            "builtAt": Date().timeIntervalSince1970,
        ])
        try fingerprint.write(to: artifact.appendingPathComponent("fingerprint.json"), options: .atomic)

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        raceService.beforeVerifyScheduleWarmLockForTesting = {
            entered.signal()
            release.wait()
        }
        let finished = expectation(description: "refresh verify finished")
        DispatchQueue.global(qos: .userInitiated).async {
            raceService.requestRefresh(checkout: checkout)
            finished.fulfill()
        }

        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        raceService.enabled = false
        raceService.stopWatchingAll()
        release.signal()
        wait(for: [finished], timeout: 1)

        let disabled = raceService.lifecycleSnapshotForTesting
        XCTAssertEqual(disabled.watchers, 0)
        XCTAssertEqual(disabled.schedules, 0, "OFF must reject a late cold-schedule warm-up")
        XCTAssertEqual(disabled.debounceTasks, 0)
    }

    func test_microbenchWatcherLifecycleRelease() throws {
        // WHY: a feature OFF must release live streams and delayed work even
        // after many checkouts were touched. This benchmark uses real
        // FSEventStream registrations plus process RSS/FD/CPU counters.
        let warmups = 2
        let measured = 7
        let rootCount = 32

        for sample in 0..<(warmups + measured) {
            let sampleRoot = tempRoot.appendingPathComponent("watcher-bench-\(sample)", isDirectory: true)
            let sampleService = GraphifyWorkspaceService(
                appSupportDirectory: sampleRoot.appendingPathComponent("graphs", isDirectory: true)
            )
            sampleService.enabled = true
            sampleService.autoEnsure = true
            sampleService.fseventsDebounce = 0.5
            sampleService.headProbe = { _ in nil }

            for index in 0..<rootCount {
                let root = sampleRoot.appendingPathComponent("repo-\(index)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let checkout = GraphifyCheckout(
                    key: GraphifyRepoKey(commonDir: root.appendingPathComponent(".git").path),
                    displayRoot: root.path
                )
                sampleService.watchCheckout(checkout)
                sampleService.markDirtyFromFilesystem(checkout: checkout)
            }

            let before = sampleService.lifecycleSnapshotForTesting
            let fdBefore = Self.openFileDescriptorCount()
            let processBefore = Self.processTaskInfo()
            let started = ContinuousClock.now
            sampleService.enabled = false
            sampleService.stopWatchingAll()
            let wall = ContinuousClock.now - started
            let processAfter = Self.processTaskInfo()
            let fdAfter = Self.openFileDescriptorCount()
            let after = sampleService.lifecycleSnapshotForTesting

            let wallMilliseconds = Double(wall.components.seconds) * 1_000
                + Double(wall.components.attoseconds) / 1_000_000_000_000_000
            let cpuMilliseconds = Double(
                (processAfter.pti_total_user &+ processAfter.pti_total_system)
                    &- (processBefore.pti_total_user &+ processBefore.pti_total_system)
            ) / 1_000_000
            let rssBefore = processBefore.pti_resident_size
            let rssAfter = processAfter.pti_resident_size
            print(
                "GRAPHIFY_WATCHER_BENCH sample=\(sample) measured=\(sample >= warmups) "
                    + "watchers_before=\(before.watchers) watchers_after=\(after.watchers) "
                    + "schedules_after=\(after.schedules) debounce_after=\(after.debounceTasks) "
                    + "retained_after=\(after.schedules + after.debounceTasks + after.watchers) "
                    + "fd_before=\(fdBefore) fd_after=\(fdAfter) "
                    + "rss_before=\(rssBefore) rss_after=\(rssAfter) "
                    + "wall_ms=\(wallMilliseconds) cpu_ms=\(cpuMilliseconds)"
            )

            // Let the baseline's uncancelled delayed items drain before the
            // next same-process sample, keeping all seven samples comparable.
            Thread.sleep(forTimeInterval: 0.55)
        }
    }

    // MARK: helpers

    private static func processTaskInfo() -> proc_taskinfo {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        _ = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, pointer, size)
        }
        return info
    }

    private static func openFileDescriptorCount() -> Int {
        let bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return -1 }
        return Int(bytes) / MemoryLayout<proc_fdinfo>.stride
    }

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
