import XCTest
import os
import AgentRuntime
import CoreModel
import Persistence
import SocketServer
@testable import AppShell

/// Plan A S8: which Distill runs go to the bot's Linux guest, and how a guest
/// run claims the bot, waits its turn, and is prepared and cleaned up.
@MainActor
final class BotGuestRunResolverTests: XCTestCase {
    private var root: URL!
    private var gateways: [BotGuestMCPGateway] = []

    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    override func setUpWithError() throws {
        // Resolved: the cwd rules compare symlink-resolved paths (/var → /private/var).
        root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("RC2GuestResolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        gateways.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture

    private struct Fixture {
        let ctx: AppContext
        let router: AppCommandRouter
        let bot: BotDefinition
        let workspace: Workspace
        let hostHome: URL
        let vm: FakeGuestVM
        let registry: BotVMRunRegistry
        let leases: DistillGuestLeases
        let barrier: DistillGuestLaunchBarrier
        let refreshes: Recorder<DistillAccountProvider?>
        let resolver: BotGuestRunResolver
        let deps: BotGuestRunResolver.Dependencies
        let appSupport: URL

        var guestHome: URL {
            BotComputerGuestSpec.guestHomeURL(appSupport: appSupport, botID: bot.id)
        }
        var guestDistillHome: URL { DistillGuestCredentials.distillHome(guestHome: guestHome) }
        var runsDirectory: URL { DistillGuestEnvironment.runsDirectory(appSupport: appSupport) }
    }

    private func makeFixture(openBarrier: Bool = true) async throws -> Fixture {
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let workspaceDir = root.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let workspace = try router.createWorkspace(name: "ws", cwd: workspaceDir.path)
        let bot = try ctx.botStore.create(
            name: "Vera", title: "", description: "", desktopKind: .dockerDesktop, workspaceID: workspace.id
        )
        // Provisioning creates the bot's guest home; the fake VM does not.
        try FileManager.default.createDirectory(
            at: BotComputerGuestSpec.guestHomeURL(appSupport: ctx.appSupportDirectory, botID: bot.id),
            withIntermediateDirectories: true
        )
        let hostHome = root.appendingPathComponent("host-distill", isDirectory: true)
        try FileManager.default.createDirectory(at: hostHome, withIntermediateDirectories: true)
        try """
            [models]
            default = "claude/claude-sonnet-4-5"

            [model.local]
            base_url = "http://127.0.0.1:8000/v1"
            api_key = "sk-local-secret"
            """.write(to: hostHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try #"{"access_token":"at-1","refresh_token":"rt-host-only","expires_at":4102444800000}"#
            .write(to: hostHome.appendingPathComponent("claude-auth.json"), atomically: true, encoding: .utf8)

        let vm = FakeGuestVM()
        let registry = BotVMRunRegistry()
        let leases = DistillGuestLeases()
        let barrier = DistillGuestLaunchBarrier()
        if openBarrier { await barrier.open() }
        let refreshes = Recorder<DistillAccountProvider?>()
        let gateway = BotGuestMCPGateway()
        gateways.append(gateway)
        let workspaces = [workspace.id: workspaceDir.path]
        let deps = BotGuestRunResolver.Dependencies(
            threadRepo: ctx.threadRepo,
            botStore: ctx.botStore,
            appSupport: ctx.appSupportDirectory,
            registry: registry,
            leases: leases,
            barrier: barrier,
            gateway: gateway,
            vm: vm,
            binaryGuestPath: { _, arch in
                XCTAssertEqual(arch, "aarch64")
                return "/opt/remotecode-agent/distill/2.0.31/distill-linux-aarch64"
            },
            refresh: { _, provider in refreshes.append(provider) },
            dockerExecutable: { "/usr/bin/true" },
            workspaces: { workspaces },
            hostBinary: { _ in nil },
            gitIdentity: { GitIdentity(name: "Ada", email: "ada@example.com") },
            processEnvironment: ["DISTILL_HOME": hostHome.path],
            heartbeatInterval: 0.05
        )
        return Fixture(
            ctx: ctx, router: router, bot: bot, workspace: workspace, hostHome: hostHome, vm: vm,
            registry: registry, leases: leases, barrier: barrier, refreshes: refreshes,
            resolver: BotGuestRunResolver(deps), deps: deps, appSupport: ctx.appSupportDirectory
        )
    }

    /// A conversation locked to the bot's VM; `marked` adds the plan-A guest marker.
    private func makeThread(
        _ f: Fixture, workspace: Bool = false, marked: Bool = true,
        target: ExecutionTarget = .vm, title: String = "Desk chat"
    ) throws -> AgentThread {
        let thread = try f.router.createAgentThread(
            workspace: workspace ? f.workspace.id : nil, title: title, provider: .distill,
            model: "claude/claude-sonnet-4-5", permissionMode: .supervised, reasoningEffort: .medium,
            routingConfiguration: nil, quiet: true
        )
        XCTAssertTrue(try f.ctx.threadRepo.setActor(
            id: thread.id, actor: .bot(f.bot.id), lockedAt: Date(), executionTarget: target
        ))
        if marked { XCTAssertTrue(try f.ctx.threadRepo.setGuestRuntime(id: thread.id, BotGuestRuntime.distillV1)) }
        return thread
    }

    private func request(
        _ thread: AgentThread, cwd: String? = nil, runAsUser: AgentRunAsUser? = nil,
        permit: AgentRunAcceptancePermit? = nil
    ) -> AgentRunRequest {
        AgentRunRequest(
            threadId: thread.id, provider: .distill, model: "claude/claude-sonnet-4-5",
            cwd: cwd ?? root.appendingPathComponent("BotHome").path, prompt: "uname -a",
            environment: [
                "RC_TOKEN_SAVER_DISTILL_HINT": "1",
                BotSecretEnvironment.botIDEnvironmentKey: "bot",
                "PATH": "/Users/someone/bin:/usr/bin",
            ],
            runAsUser: runAsUser,
            acceptancePermit: permit
        )
    }

    private func envFile(_ f: Fixture, _ runID: AgentRunID) -> URL {
        f.runsDirectory.appendingPathComponent("\(runID.value.uuidString.lowercased()).env")
    }

    private func leaseFile(_ f: Fixture, _ runID: AgentRunID) -> URL {
        f.guestHome.appendingPathComponent(".rc-runs/\(runID.value.uuidString.lowercased()).lease")
    }

    // MARK: - Routing

    func test_legacyVMThreadWithoutTheMarker_andAMarkedThreadMovedToTheMac_stayOnTheMac() async throws {
        // WHY (B3, D5): a `.vm` thread from before plan A has its Distill
        // session on the Mac; loading it in the guest would fail. And a thread
        // the user moved to the Mac must not go back to the guest.
        let f = try await makeFixture()
        let legacy = try makeThread(f, marked: false)
        let movedToMac = try makeThread(f, target: .mac)
        for thread in [legacy, movedToMac] {
            XCTAssertFalse(f.resolver.isGuestThread(thread.id))
            let plan = try await f.resolver.prepare(request(thread)) { _ in }
            XCTAssertNil(plan)
        }
        XCTAssertEqual(f.vm.calls.count, 0, "no guest work for a Mac thread")
        XCTAssertNil(f.registry.active(botID: f.bot.id), "a Mac run does not claim the bot's VM")
    }

    func test_theMarkerSurvivesWholeThreadWrites() async throws {
        // WHY: model, routing and title edits rewrite the whole thread row;
        // dropping the marker would send a guest thread (and its guest
        // session cursor) back to the Mac without anyone asking.
        let f = try await makeFixture()
        var thread = try XCTUnwrap(try f.ctx.threadRepo.get(id: try makeThread(f).id))
        thread.title = "Renamed"
        thread.model = "claude/claude-opus-4-1"
        try f.ctx.threadRepo.upsert(thread)
        XCTAssertTrue(try f.ctx.threadRepo.setActor(id: thread.id, actor: thread.actor, lockedAt: thread.actorLockedAt, executionTarget: .vm))
        XCTAssertEqual(try f.ctx.threadRepo.guestPlacement(of: thread.id),
                       AgentThreadGuestPlacement(executionTarget: .vm, guestRuntime: BotGuestRuntime.distillV1))
        XCTAssertTrue(f.resolver.isGuestThread(thread.id))
    }

    func test_deskThreadPlanRunsInTheGuestHomeWithACleanEnvAndRefreshBlankedSignIn_andTeardownLeavesNothing() async throws {
        let f = try await makeFixture()
        let thread = try makeThread(f)
        XCTAssertTrue(f.resolver.isGuestThread(thread.id))
        let stages = Recorder<DistillGuestStage>()
        let req = request(thread)
        let plan = try unwrapPlan(try await f.resolver.prepare(req) { stages.append($0) })

        XCTAssertEqual(plan.container, "remotecode-bot-test")
        XCTAssertEqual(plan.guestCwd, BotComputerGuestSpec.guestUserHome,
                       "a desk thread has no workspace: it runs in the guest home, never the Mac's BotHome path")
        XCTAssertEqual(plan.guestCommand.first, "/opt/remotecode-agent/distill/2.0.31/distill-linux-aarch64")
        XCTAssertEqual(f.vm.calls.first?.workspace, nil, "a desk thread is provisioned, never asked to mount BotHome (B5)")
        XCTAssertEqual(stages.values, [.startingVM, .preparingAgent, .signingIn, .launching])
        XCTAssertEqual(f.refreshes.values, [.claude], "the Mac renews the model's sign-in before the guest copy is made")
        XCTAssertEqual(f.registry.active(botID: f.bot.id)?.runID, req.runId,
                       "the spawn point claims the bot for every send path (B2)")

        // Environment: allowlisted, nothing of Token Saver or the Mac.
        let env = try String(contentsOf: plan.envFileURL, encoding: .utf8)
        XCTAssertEqual(try posixMode(plan.envFileURL), 0o600)
        XCTAssertTrue(env.contains("RC_GUEST_RUN_ID=\(req.runId.value.uuidString.lowercased())\n"))
        XCTAssertTrue(env.contains("RC_GUEST_GATEWAY_TOKEN="))
        XCTAssertTrue(env.contains("GIT_AUTHOR_EMAIL=ada@example.com\n"))
        XCTAssertFalse(env.contains("RC_TOKEN_SAVER"), "Token Saver injects nothing into guest runs")
        XCTAssertFalse(env.contains("/Users/"), "no Mac path reaches the guest")

        // Config: gateway by bearer env var; the model key moved out of the file.
        let config = try String(contentsOf: f.guestDistillHome.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(config.contains("url = \"http://host.docker.internal:"))
        XCTAssertTrue(config.contains("bearer_token_env_var = \"RC_GUEST_GATEWAY_TOKEN\""))
        XCTAssertFalse(config.contains("sk-local-secret"), "secrets ride in the env file, not the guest-readable config")
        XCTAssertTrue(env.contains("sk-local-secret"))

        // Sign-in copy: the guest can never spend the refresh token.
        let copy = f.guestDistillHome.appendingPathComponent("claude-auth.json")
        let copied = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: copy)) as? [String: Any])
        XCTAssertEqual(copied["refresh_token"] as? String, "")
        XCTAssertEqual(copied["access_token"] as? String, "at-1")
        XCTAssertEqual(try posixMode(copy), 0o600)

        // Lease: written before the agent starts and renewed by re-creating it.
        let lease = leaseFile(f, req.runId)
        let firstInode = try inode(lease)
        try await waitUntil { (try? self.inode(lease)) != firstInode }

        await plan.finish(.completed).value
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "no sign-in copy outlives the run")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.path), "no lease outlives the run")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.envFileURL.path))
        let leaseHeld = await f.leases.isHeld(f.bot.id.value.uuidString.lowercased())
        XCTAssertFalse(leaseHeld)
    }

    func test_workspaceThreadRunsAtItsOwnPathInsideTheMountedWorkspace() async throws {
        let f = try await makeFixture()
        let thread = try makeThread(f, workspace: true)
        let sub = root.appendingPathComponent("ws/app", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let plan = try unwrapPlan(try await f.resolver.prepare(request(thread, cwd: sub.path)) { _ in })
        XCTAssertEqual(f.vm.calls.first?.workspace, root.appendingPathComponent("ws").path,
                       "the registered workspace root is what gets mounted")
        XCTAssertEqual(plan.guestCwd, sub.path, "the workspace is bound at the same path in the guest")
        await plan.finish(.completed).value
    }

    // MARK: - Fail closed

    func test_cwdOutsideEveryMountFailsClosed_andLeavesNothingBehind() async throws {
        // WHY (M6): falling back to the guest home would run the agent somewhere
        // the user did not ask for, with no error.
        let f = try await makeFixture()
        let thread = try makeThread(f, workspace: true)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let req = request(thread, cwd: elsewhere.path)
        await assertUnavailable(containing: "not inside a folder mounted") {
            _ = try await f.resolver.prepare(req) { _ in }
        }
        try await assertNothingLeft(f, req)
    }

    func test_dockerDownFailsClosed_freesTheLease_andLeavesNoSignInOrEnvFile() async throws {
        // WHY (D11): never fall back to the Mac; a failed start must not keep
        // the bot's lease or leave credentials on the guest-visible bind.
        let f = try await makeFixture()
        f.vm.error = BotComputerGuestError.dockerUnavailable
        let thread = try makeThread(f)
        let req = request(thread)
        await assertUnavailable(containing: "") {
            _ = try await f.resolver.prepare(req) { _ in }
        }
        try await assertNothingLeft(f, req)
        XCTAssertEqual(f.registry.active(botID: f.bot.id)?.runID, req.runId,
                       "the claim stays for the coordinator's run-finished, which also drains the next queued send")
    }

    func test_aForeignMacUserIsRefused() async throws {
        // WHY (M9): the guest gets the app user's own sign-ins; a run meant for
        // another macOS user must not run with them.
        let f = try await makeFixture()
        let thread = try makeThread(f)
        let other = AgentRunAsUser(
            generatedUID: "", shortName: "someone-else", uid: getuid() + 1, gid: getgid(), homePath: "/Users/someone-else"
        )
        await assertUnavailable(containing: "someone-else") {
            _ = try await f.resolver.prepare(self.request(thread, runAsUser: other)) { _ in }
        }
        XCTAssertEqual(f.vm.calls.count, 0)
        XCTAssertNil(f.registry.active(botID: f.bot.id))
    }

    func test_aMarkerFromANewerBuildFailsInsteadOfRunningOnTheMac() async throws {
        let f = try await makeFixture()
        let thread = try makeThread(f)
        XCTAssertTrue(try f.ctx.threadRepo.setGuestRuntime(id: thread.id, "guest-v9"))
        XCTAssertTrue(f.resolver.isGuestThread(thread.id), "the adapter must not open it on the Mac")
        await assertUnavailable(containing: "newer RemoteCode") {
            _ = try await f.resolver.prepare(self.request(thread)) { _ in }
        }
    }

    // MARK: - One run per bot

    func test_twoConversationsStartingTogether_getOnePlanAndOneBusy() async throws {
        // WHY (B2): two runs in one container would share its DISTILL_HOME,
        // config and sign-in copies.
        let f = try await makeFixture()
        let first = try makeThread(f, title: "First chat")
        let second = try makeThread(f, title: "Second chat")
        let gate = DispatchSemaphore(value: 0)
        f.vm.gate = gate
        let firstRun = Task { try await f.resolver.prepare(self.request(first)) { _ in } }
        try await waitUntil { f.vm.calls.count == 1 }
        do {
            _ = try await f.resolver.prepare(request(second)) { _ in }
            XCTFail("the second conversation must not get the bot")
        } catch {
            XCTAssertEqual(error as? DistillGuestLaunchError, .busy("bot ocupado em First chat"))
        }
        gate.signal()
        let plan = try unwrapPlan(try await firstRun.value)
        XCTAssertEqual(f.vm.calls.count, 1)
        await plan.finish(.completed).value
    }

    func test_stopThenQueuedSend_waitsForTheStoppedRunsTeardownBeforeTouchingTheGuest() async throws {
        // WHY (B1): Stop frees the registry before the stopped run's guest
        // process and sign-in copies are gone; the next run must not start in
        // the guest (or rewrite its copies) until that teardown is done.
        let f = try await makeFixture()
        let first = try makeThread(f, title: "First chat")
        let second = try makeThread(f, title: "Second chat")
        let firstRequest = request(first)
        let firstPlan = try unwrapPlan(try await f.resolver.prepare(firstRequest) { _ in })
        _ = f.registry.releaseAndNextWaiting(runID: firstRequest.runId) // the coordinator's run-finished

        let firstLease = leaseFile(f, firstRequest.runId)
        f.vm.onPrepare = { XCTAssertFalse(FileManager.default.fileExists(atPath: firstLease.path),
                                          "the second run reached the guest before the first run's teardown") }
        let stages = Recorder<DistillGuestStage>()
        let secondRun = Task { try await f.resolver.prepare(self.request(second)) { stages.append($0) } }
        try await waitUntil { stages.values.first == .waitingForBot }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(f.vm.calls.count, 1, "the second run waits on the bot's lease")

        await firstPlan.finish(.cancelled).value
        let secondPlan = try unwrapPlan(try await secondRun.value)
        XCTAssertEqual(f.vm.calls.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.guestDistillHome.appendingPathComponent("claude-auth.json").path),
            "the first run's cleanup did not delete the second run's sign-in copy")
        await secondPlan.finish(.completed).value
    }

    func test_guestRunsWaitForLaunchCleanupBeforeClaimingTheBot() async throws {
        // WHY (M5): launch cleanup deletes leftover sign-in copies and env
        // files; a run that started first would lose its own.
        let f = try await makeFixture(openBarrier: false)
        let thread = try makeThread(f)
        let run = Task { try await f.resolver.prepare(self.request(thread)) { _ in } }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(f.vm.calls.count, 0)
        XCTAssertNil(f.registry.active(botID: f.bot.id))
        await f.barrier.open()
        let plan = try unwrapPlan(try await run.value)
        await plan.finish(.completed).value
    }

    // MARK: - Stop while preparing

    func test_stopWhileTheVMIsStarting_copiesNoSignIn_writesNothing_andFreesTheBot() async throws {
        // WHY (AGENTS.md loading rules): a stopped send must not go on to
        // renew sign-ins, copy them into the guest, mint a gateway token and
        // spawn an agent minutes later (an image build), nor keep the bot's
        // lease so the next send waits on a run nobody wants.
        let f = try await makeFixture()
        let thread = try makeThread(f)
        let permit = AgentRunAcceptancePermit()
        let req = request(thread, permit: permit)
        let gate = DispatchSemaphore(value: 0)
        f.vm.gate = gate
        let run = Task { try await f.resolver.prepare(req) { _ in } }
        try await waitUntil { f.vm.calls.count == 1 }
        permit.invalidate() // what the coordinator's Stop does to a pending start
        gate.signal()
        do {
            let plan = try await run.value
            XCTFail("a stopped run must not get a launch plan")
            await plan?.finish(.cancelled).value
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(f.refreshes.values.isEmpty, "no sign-in renewal for a stopped run")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: f.guestDistillHome.appendingPathComponent("config.toml").path))
        try await assertNothingLeft(f, req)

        // Positive control: the same thread runs normally afterwards.
        _ = f.registry.releaseAndNextWaiting(runID: req.runId)
        f.vm.gate = nil
        let plan = try unwrapPlan(try await f.resolver.prepare(request(thread)) { _ in })
        await plan.finish(.completed).value
    }

    func test_stopWhileWaitingForLaunchCleanup_endsTheWaitWithoutClaimingTheBot() async throws {
        let f = try await makeFixture(openBarrier: false)
        let thread = try makeThread(f)
        let permit = AgentRunAcceptancePermit()
        let run = Task { try await f.resolver.prepare(self.request(thread, permit: permit)) { _ in } }
        try await Task.sleep(nanoseconds: 100_000_000)
        permit.invalidate()
        let ended = OSAllocatedUnfairLock(initialState: false)
        Task { _ = try? await run.value; ended.withLock { $0 = true } }
        try await waitUntil(timeout: 2) { ended.withLock { $0 } } // fails: Stop did not end the wait
        if !ended.withLock({ $0 }) { await f.barrier.open() }
        do {
            let plan = try await run.value
            XCTFail("a stopped run must not get a launch plan")
            await plan?.finish(.cancelled).value
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(f.vm.calls.count, 0)
        XCTAssertNil(f.registry.active(botID: f.bot.id), "a run stopped before the barrier never claims the bot")
    }

    // MARK: - Guest-owned directories

    func test_aGuestSwappingItsDistillFolderForASymlink_neverGetsTheConfigWrittenIntoAMacFolder() async throws {
        // WHY: the guest owns `~/.distill`. A leftover guest process can flip
        // it between a folder and a symlink to a Mac folder (the user's own
        // ~/.distill, ~/.codex, ...); a config write that follows it would
        // replace the Mac's config.toml.
        let f = try await makeFixture()
        let thread = try makeThread(f)
        let victim = root.appendingPathComponent("mac-victim", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        let distill = f.guestDistillHome.path
        let link = f.guestHome.appendingPathComponent("link").path
        try FileManager.default.createDirectory(atPath: distill, withIntermediateDirectories: true)
        XCTAssertEqual(symlink(victim.path, link), 0)
        // The attacker's primitive: atomically exchange the folder and the
        // symlink (Linux renameat2 RENAME_EXCHANGE; RENAME_SWAP here).
        let stop = OSAllocatedUnfairLock(initialState: false)
        let flipper = Thread {
            while !stop.withLock({ $0 }) {
                guard renamex_np(link, distill, UInt32(RENAME_SWAP)) == 0 else { continue }
                usleep(50)
                renamex_np(link, distill, UInt32(RENAME_SWAP))
                usleep(50)
            }
        }
        flipper.start()
        var plans = 0
        for _ in 0..<60 {
            let req = request(thread)
            if let plan = try? await f.resolver.prepare(req, progress: { _ in }) {
                plans += 1
                await plan.finish(.completed).value
            }
            _ = f.registry.releaseAndNextWaiting(runID: req.runId)
        }
        stop.withLock { $0 = true }
        while !flipper.isFinished { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertGreaterThan(plans, 0, "positive control: runs still prepare while the folder is real")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: victim.path), [],
                       "nothing the guest run writes may land in a Mac folder (\(plans) runs prepared)")
    }

    func test_aGuestSwappingItsLeaseFolderForASymlink_neverMakesTheMacWriteOrDeleteThere() async throws {
        // WHY: the agent owns `~/.rc-runs` during its run. Renewals, Stop and
        // the launch sweep must not create or delete `*.lease` files in a Mac
        // folder it points that name at.
        let f = try await makeFixture()
        let thread = try makeThread(f)
        let req = request(thread)
        let plan = try unwrapPlan(try await f.resolver.prepare(req) { _ in })
        let victim = root.appendingPathComponent("mac-victim", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        let runLease = "\(req.runId.value.uuidString.lowercased()).lease"
        try "mine\n".write(to: victim.appendingPathComponent(runLease), atomically: true, encoding: .utf8)
        try "mine\n".write(to: victim.appendingPathComponent("other.lease"), atomically: true, encoding: .utf8)
        let leases = f.guestHome.appendingPathComponent(".rc-runs", isDirectory: true)
        try FileManager.default.removeItem(at: leases)
        try FileManager.default.createSymbolicLink(at: leases, withDestinationURL: victim)

        try await Task.sleep(nanoseconds: 300_000_000) // several 50 ms renewals
        await plan.finish(.completed).value
        BotGuestLaunchSweep.removeLeftovers(appSupport: f.appSupport)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: victim.path).sorted(),
                       ["other.lease", runLease].sorted())
        for name in ["other.lease", runLease] {
            XCTAssertEqual(try String(contentsOf: victim.appendingPathComponent(name), encoding: .utf8), "mine\n",
                           "\(name) was rewritten through the guest's symlink")
        }
    }

    func test_aSymlinkedLeaseFolderFailsTheRunClosed() async throws {
        // Positive control for the run itself: with no lease the guest
        // reaper would end the agent, so the start fails instead.
        let f = try await makeFixture()
        let thread = try makeThread(f)
        let victim = root.appendingPathComponent("mac-victim", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: f.guestHome.appendingPathComponent(".rc-runs"), withDestinationURL: victim
        )
        let req = request(thread)
        await assertUnavailable(containing: "") {
            _ = try await f.resolver.prepare(req) { _ in }
        }
        try await assertNothingLeft(f, req)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: victim.path), [])
    }

    // MARK: - Launch sweep and quit (S10)

    func test_launchSweep_endsLeftoverAgentsOnlyInRunningContainersOfThisAppsOwnBots() throws {
        // WHY: an agent left running by a crashed session keeps executing with
        // the user's sign-ins until something ends it. The Docker daemon is
        // shared with the user's installed app (and other sandboxes), whose
        // live runs must never be killed: only containers named and labelled
        // for this database's bots, with their home bound from this app's
        // Application Support, are touched.
        let appSupport = root.appendingPathComponent("support-a", isDirectory: true)
        let otherSupport = root.appendingPathComponent("support-b", isDirectory: true)
        let mine = BotID(), stopped = BotID(), predatesKit = BotID(), copiedDB = BotID(), relabelled = BotID()
        let foreign = BotID()
        let docker = SweepDocker()
        func add(_ bot: BotID, running: Bool = true, label: BotID? = nil, support: URL? = nil) {
            docker.containers[BotComputerGuestSpec.containerName(botID: bot)] = BotComputerContainerInspect(
                running: running, imageID: "img", hostPort: 0,
                labels: [BotComputerGuestSpec.botIDLabelKey: (label ?? bot).value.uuidString.lowercased()],
                homeSource: BotComputerGuestSpec.guestHomeURL(appSupport: support ?? appSupport, botID: bot).path
            )
        }
        add(mine)
        add(stopped, running: false)
        add(predatesKit)
        add(copiedDB, support: otherSupport) // same bot id, the other app's container
        add(relabelled, label: BotID())
        add(foreign) // a bot of the other app's database
        docker.failingExecs = [BotComputerGuestSpec.containerName(botID: predatesKit)]

        let swept = BotGuestLaunchSweep.endLeftoverRuns(
            docker: docker, appSupport: appSupport,
            botIDs: [predatesKit, mine, stopped, copiedDB, relabelled, BotID() /* no container */]
        )

        XCTAssertEqual(swept, [BotComputerGuestSpec.containerName(botID: mine)],
                       "a container whose kill-agent fails (no kit yet) does not stop the sweep")
        XCTAssertEqual(docker.execs.map(\.name), [predatesKit, mine].map { BotComputerGuestSpec.containerName(botID: $0) })
        for exec in docker.execs {
            XCTAssertEqual(exec.command, [BotComputerGuestSpec.killAgentPath, "--all"])
            XCTAssertEqual(exec.user, BotComputerGuestSpec.agentUser,
                           "root cannot read another user's run tags: kill-agent must run as the guest user")
        }
        XCTAssertFalse(docker.inspected.contains(BotComputerGuestSpec.containerName(botID: foreign)),
                       "the other app's bots are not even looked at")

        // Docker down: no container runs, nothing to end, no exec attempted.
        let down = SweepDocker()
        down.infoFails = true
        XCTAssertEqual(BotGuestLaunchSweep.endLeftoverRuns(docker: down, appSupport: appSupport, botIDs: [mine]), [])
        XCTAssertTrue(down.inspected.isEmpty)
    }

    func test_launchSweep_endsLeftoverAgentsBeforeDeletingTheirSignInCopies_andOnlyThenAdmitsGuestRuns() async throws {
        // WHY (M5): a leftover agent must be dead before its copies go (it
        // would otherwise run on, then fail mid-turn), and a new run must not
        // start until the sweep is done or the sweep would end it or delete
        // what it just wrote.
        let f = try await makeFixture(openBarrier: false)
        try await f.ctx.botGuestLaunchBarrier.wait() // the context's own launch sweep is done
        let copy = f.guestDistillHome.appendingPathComponent("claude-auth.json")
        try FileManager.default.createDirectory(at: f.guestDistillHome, withIntermediateDirectories: true)
        try #"{"access_token":"stale","refresh_token":""}"#.write(to: copy, atomically: true, encoding: .utf8)
        let docker = SweepDocker()
        docker.containers[BotComputerGuestSpec.containerName(botID: f.bot.id)] = BotComputerContainerInspect(
            running: true, imageID: "img", hostPort: 0,
            labels: [BotComputerGuestSpec.botIDLabelKey: f.bot.id.value.uuidString.lowercased()],
            homeSource: f.guestHome.path
        )
        let killing = DispatchSemaphore(value: 0)
        let copyAtKill = Recorder<Bool>()
        docker.onExec = {
            copyAtKill.append(FileManager.default.fileExists(atPath: copy.path))
            killing.wait()
        }
        let thread = try makeThread(f)
        let run = Task { try await f.resolver.prepare(self.request(thread)) { _ in } }
        let sweep = Thread {
            BotGuestLaunchSweep.run(docker: docker, appSupport: f.appSupport, botIDs: [f.bot.id], barrier: f.barrier)
        }
        sweep.start()

        try await waitUntil { docker.execs.count == 1 }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(copyAtKill.values, [true], "the agent is ended while its copies still exist")
        XCTAssertEqual(f.vm.calls.count, 0, "no guest run starts while the sweep is still ending leftovers")
        XCTAssertNil(f.registry.active(botID: f.bot.id))
        killing.signal()

        let plan = try unwrapPlan(try await run.value)
        XCTAssertEqual(f.vm.calls.count, 1)
        let fresh = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: copy)) as? [String: Any])
        XCTAssertEqual(fresh["access_token"] as? String, "at-1", "the new run's copy is written after the sweep, never deleted by it")
        await plan.finish(.completed).value
    }

    func test_quit_endsALiveGuestRun_deletesItsSignInCopyEnvFileAndLease_andNothingIsCopiedAgain() async throws {
        // WHY: after quit nothing renews the sign-in copies or the lease; the
        // agent must not keep running with the user's accounts, and the copies
        // must not sit in the guest-readable home until the next launch.
        let f = try await makeFixture()
        try await f.ctx.botGuestLaunchBarrier.wait() // the context's own launch sweep is done
        let log = root.appendingPathComponent("docker.log")
        let fakeDocker = root.appendingPathComponent("fake-docker")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(log.path)'\n".write(to: fakeDocker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDocker.path)
        var deps = f.deps
        deps.dockerExecutable = { fakeDocker.path }
        let resolver = BotGuestRunResolver(deps)
        let req = request(try makeThread(f))
        let plan = try unwrapPlan(try await resolver.prepare(req) { _ in })
        let copy = f.guestDistillHome.appendingPathComponent("claude-auth.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "positive control: the live run has its copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.envFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: leaseFile(f, req.runId).path))

        // The resolver kills it itself: a run whose turn is still ending is
        // no longer in the adapter's sessions, which the adapter's quit kill
        // walks.
        resolver.endRunsForAppTermination()

        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.envFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leaseFile(f, req.runId).path))
        let runID = req.runId.value.uuidString.lowercased()
        try await waitUntil { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains(runID) }
        plan.killGuestDetached() // the adapter's own quit kill of the same run: no second docker call
        // A Mac renewal right after quit must not re-copy the sign-in.
        try #"{"access_token":"at-2","refresh_token":"rt-host-only","expires_at":4102444800000}"#
            .write(to: f.hostHome.appendingPathComponent("claude-auth.json"), atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 900_000_000) // past the mirror's 0.5 s debounce
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "exec -d -u remotecode remotecode-bot-test \(BotComputerGuestSpec.killAgentPath) \(runID)\n")
        await plan.finish(.cancelled).value
    }

    func test_quitOfAProcessThatHostsNoGuestRuns_leavesTheAppsLiveRunsAlone() async throws {
        // WHY: the scheduled-task agent shares this Application Support; its
        // exit must not delete the sign-in copies of the app's live runs.
        let f = try await makeFixture()
        let req = request(try makeThread(f))
        let plan = try unwrapPlan(try await f.resolver.prepare(req) { _ in })
        var deps = f.deps
        deps.hostsGuestRuns = false
        BotGuestRunResolver(deps).endRunsForAppTermination()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.guestDistillHome.appendingPathComponent("claude-auth.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.envFileURL.path))
        await plan.finish(.completed).value
    }

    // MARK: - Coordinator placement

    func test_aGuestThreadOnAnotherProviderFailsBeforeAnythingIsRecordedOrSpawned() async throws {
        // WHY (B4): only Distill runs in the guest. A guest thread switched to
        // another provider (picker, Auto routing) would otherwise run on the
        // Mac while it claims to run in the VM.
        let f = try await makeFixture()
        let runner = ControlledBotHandoffRunner(provider: .codex)
        f.ctx.coordinator.replaceProviderAdapter(.codex, adapter: TerminalRetiringOneShotAdapter(runner: runner))
        let thread = try f.router.createAgentThread(
            workspace: f.workspace.id, title: "Codex chat", provider: .codex, model: "fake-model",
            permissionMode: .supervised, reasoningEffort: .medium
        )
        XCTAssertTrue(try f.ctx.threadRepo.setActor(id: thread.id, actor: .bot(f.bot.id), lockedAt: Date(), executionTarget: .vm))
        XCTAssertTrue(try f.ctx.threadRepo.setGuestRuntime(id: thread.id, BotGuestRuntime.distillV1))
        let blocked = AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: f.workspace.cwd, prompt: "hi"
        )
        do {
            _ = try await f.ctx.coordinator.startRun(blocked)
            XCTFail("a non-Distill run of a guest thread must fail")
        } catch {
            XCTAssertTrue(String(describing: error).contains("only runs Distill"), "\(error)")
        }
        XCTAssertTrue(runner.requests.isEmpty, "nothing spawned")
        XCTAssertNil(try f.ctx.runRepo.status(of: blocked.runId), "no run recorded")

        // Positive control: the same send runs once the thread is not a guest thread.
        XCTAssertTrue(try f.ctx.threadRepo.setGuestRuntime(id: thread.id, nil))
        _ = try await f.ctx.coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: f.workspace.cwd, prompt: "hi"
        ))
        XCTAssertEqual(runner.requests.count, 1)
    }

    // MARK: - cwd rules

    func test_guestCwdRules() throws {
        let mount = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: mount + "/src", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: mount + "/.git", withIntermediateDirectories: true)
        XCTAssertEqual(try BotGuestRunResolver.guestCwd(requestCwd: "/anywhere", workspace: nil, mounted: []),
                       BotComputerGuestSpec.guestUserHome)
        XCTAssertEqual(try BotGuestRunResolver.guestCwd(requestCwd: mount, workspace: mount, mounted: [mount]), mount)
        XCTAssertEqual(try BotGuestRunResolver.guestCwd(requestCwd: mount + "/src", workspace: mount, mounted: [mount]),
                       mount + "/src")
        // A sibling sharing the prefix is not inside the mount.
        try FileManager.default.createDirectory(atPath: mount + "-other", withIntermediateDirectories: true)
        XCTAssertThrowsError(try BotGuestRunResolver.guestCwd(requestCwd: mount + "-other", workspace: mount, mounted: [mount]))

        // A linked worktree inside the mount whose repository is elsewhere.
        let worktree = mount + "/wt"
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        let foreignGitDir = root.appendingPathComponent("other-repo/.git/worktrees/wt").path
        try "gitdir: \(foreignGitDir)\n".write(toFile: worktree + "/.git", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try BotGuestRunResolver.guestCwd(requestCwd: worktree, workspace: mount, mounted: [mount])) {
            XCTAssertTrue(String(describing: $0).contains("git worktree"))
        }
        // Its repository is the mounted one: fine.
        try "gitdir: ../.git/worktrees/wt\n".write(toFile: worktree + "/.git", atomically: true, encoding: .utf8)
        XCTAssertEqual(try BotGuestRunResolver.guestCwd(requestCwd: worktree, workspace: mount, mounted: [mount]), worktree)
    }

    // MARK: - Helpers

    private func assertNothingLeft(_ f: Fixture, _ req: AgentRunRequest) async throws {
        let leaseHeld = await f.leases.isHeld(f.bot.id.value.uuidString.lowercased())
        XCTAssertFalse(leaseHeld, "a failed start must not keep the bot")
        XCTAssertFalse(FileManager.default.fileExists(atPath: envFile(f, req.runId).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: f.guestDistillHome.appendingPathComponent("claude-auth.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leaseFile(f, req.runId).path))
    }

    private func assertUnavailable(
        containing text: String,
        _ body: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("expected the guest run to fail", file: file, line: line)
        } catch let error as DistillGuestLaunchError {
            guard case .unavailable(let reason) = error else {
                return XCTFail("unexpected \(error)", file: file, line: line)
            }
            if !text.isEmpty { XCTAssertTrue(reason.contains(text), reason, file: file, line: line) }
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    private func posixMode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? 0) & 0o777
    }

    private func inode(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int ?? 0
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func unwrapPlan(_ plan: DistillGuestLaunchPlan?) throws -> DistillGuestLaunchPlan {
        try XCTUnwrap(plan, "expected a guest launch plan")
    }
}

private final class FakeGuestVM: BotGuestVMPreparing, @unchecked Sendable {
    struct Call { let botID: BotID; let workspace: String? }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var error: Error?
    var gate: DispatchSemaphore?
    var onPrepare: (() -> Void)?

    var calls: [Call] { lock.withLock { recorded } }

    func prepare(
        botID: BotID, threadID: AgentThreadID, workspace: String?, registeredWorkspaces: Set<String>
    ) throws -> BotGuestVM {
        let (gate, error, onPrepare) = lock.withLock { () -> (DispatchSemaphore?, Error?, (() -> Void)?) in
            recorded.append(Call(botID: botID, workspace: workspace))
            return (self.gate, self.error, self.onPrepare)
        }
        onPrepare?()
        gate?.wait()
        if let error { throw error }
        return BotGuestVM(container: "remotecode-bot-test", dockerArch: "aarch64", mountedWorkspaces: workspace.map { [$0] } ?? [])
    }
}

/// Docker for the launch sweep: containers by name, exec recording.
private final class SweepDocker: BotComputerDockerClienting, @unchecked Sendable {
    struct Exec { let name: String; let command: [String]; let user: String? }
    private let lock = NSLock()
    var containers: [String: BotComputerContainerInspect] = [:]
    var failingExecs: Set<String> = []
    var infoFails = false
    var onExec: (() -> Void)?
    private var recordedExecs: [Exec] = []
    private var recordedInspects: [String] = []
    var execs: [Exec] { lock.withLock { recordedExecs } }
    var inspected: [String] { lock.withLock { recordedInspects } }

    func info() throws -> String {
        if infoFails { throw BotComputerDockerError.daemonUnavailable }
        return "Architecture: aarch64"
    }
    func inspect(name: String) throws -> BotComputerContainerInspect {
        lock.withLock { recordedInspects.append(name) }
        guard let container = containers[name] else { throw BotComputerDockerError.provisioningFailed }
        return container
    }
    func exec(name: String, command: [String], user: String?, detach: Bool, workdir: String?, environment: [String: String]) throws -> Data {
        lock.withLock { recordedExecs.append(Exec(name: name, command: command, user: user)) }
        onExec?()
        if failingExecs.contains(name) { throw BotComputerDockerError.provisioningFailed }
        return Data()
    }
    func imageExists(tag: String) throws -> Bool { true }
    func imageLabel(tag: String, key: String) throws -> String { "" }
    func imageID(tag: String) throws -> String { "" }
    func build(context: URL, tag: String) throws {}
    func create(options: BotComputerContainerCreateOptions) throws -> String { "" }
    func start(name: String) throws {}
    func stop(name: String) throws {}
    func rename(from: String, to: String) throws {}
    func ensureNetwork(name: String) throws {}
    func remove(name: String) throws { XCTFail("the launch sweep never removes a container") }
    func removeMatching(namePrefix: String) throws { XCTFail("the launch sweep never removes a container") }
}

private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    func append(_ value: Value) { lock.withLock { storage.append(value) } }
    var values: [Value] { lock.withLock { storage } }
}
