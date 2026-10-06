import XCTest
import CoreModel
@testable import AgentRuntime

/// In-guest transport (plan A, S7): a bot's Distill turn runs inside its Linux
/// guest through `docker exec`, and nothing of the Mac launch path leaks in.
final class DistillGuestLaunchTests: ProviderProcessTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("distill-guest-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - argv

    func test_dockerArgvRunsTheGuestBinaryUnderRunAgentWithEveryValueInTheEnvFile() throws {
        // WHY: values passed with `-e` show in the Mac's `ps`; run-agent is what
        // tags the run so kill-agent and the lease reaper can find it; and the
        // guest binary must never self-update on its read-only mount.
        let request = AgentRunRequest(
            threadId: AgentThreadID(), provider: .distill, model: "grok-4.6",
            cwd: "/Users/someone/project", prompt: "hi"
        )
        let command = try DistillGuestLaunchPlan.guestCommand(
            binaryPath: "/opt/remotecode-agent/distill/2.0.31/distill-linux-aarch64",
            for: request
        )
        XCTAssertEqual(command, [
            "/opt/remotecode-agent/distill/2.0.31/distill-linux-aarch64",
            "--no-auto-update", "agent", "--model", "grok-4.6", "--no-leader", "stdio",
        ])
        let runID = request.runId.value.uuidString
        let plan = makePlan(runID: runID, docker: "/usr/local/bin/docker", command: command)
        XCTAssertEqual(plan.dockerArguments, [
            "exec", "-i", "--env-file", plan.envFileURL.path, "-u", "remotecode",
            "-w", "/home/remotecode", "remotecode-bot-test",
            "/opt/remotecode-agent/bin/run-agent", runID, "--",
        ] + command)
        XCTAssertFalse(plan.dockerArguments.contains("-e"))
    }

    func test_guestCommandDoesNotRepeatNoAutoUpdate_becauseTheWorkerProfileAlreadyCarriesIt() throws {
        // WHY: the sam-grok-worker argv already has the top-level flag; a
        // duplicate is a CLI parse error that would fail every worker run.
        let request = AgentRunRequest(
            threadId: AgentThreadID(), provider: .distill, model: "grok-4.6",
            cwd: "/tmp", prompt: "hi", permissionMode: .autoAcceptEdits,
            reasoningEffort: .high,
            environment: [AgentAppRuntimeProfile.environmentKey: AgentAppRuntimeProfile.samGrokWorkerV1.rawValue]
        )
        let command = try DistillGuestLaunchPlan.guestCommand(binaryPath: "/guest/distill", for: request)
        XCTAssertEqual(command.filter { $0 == "--no-auto-update" }.count, 1)
        XCTAssertEqual(command.first, "/guest/distill")
    }

    func test_killUsesTheGuestUserAndAppTerminationDoesNotWait() async throws {
        // WHY: kill-agent refuses root (root cannot read another user's run
        // tag); the quit path cannot wait for docker, so it must use `exec -d`.
        let docker = try writeFakeDocker()
        let runID = UUID().uuidString
        let plan = makePlan(runID: runID, docker: docker.path, command: ["/guest/distill"])
        await plan.killGuest()
        await plan.killGuest()
        plan.killGuestDetached()
        let calls = try await waitForRecords(kind: "kill", count: 3)
        let killArgv = ["-u", "remotecode", "remotecode-bot-test", "/opt/remotecode-agent/bin/kill-agent", runID]
        XCTAssertEqual(calls[0], ["exec"] + killArgv)
        XCTAssertEqual(calls[1], ["exec"] + killArgv, "kill is safe to repeat: Stop and the run's finish both call it")
        XCTAssertEqual(calls[2], ["exec", "-d"] + killArgv)
    }

    // MARK: - A guest turn through the adapter

    func test_guestTurnSpeaksACPThroughDockerExec_withGuestCwdNoMacMCPsAndNoHostCatalog() async throws {
        let docker = try writeFakeDocker()
        let resolver = FakeGuestResolver()
        let adapter = DistillACPAdapter(binaryNameOverride: "/missing/mac-distill")
        adapter.setGuestLaunchResolver(resolver)
        defer { adapter.stopAll() }
        let threadID = AgentThreadID()
        resolver.guestThreads = [threadID]
        let teardownGate = Gate()
        let teardowns = Recorder<AgentRunStatus>()
        let leases = DistillGuestLeases()
        resolver.makePlan = { request in
            let runID = request.runId.value.uuidString
            let envFile = try DistillGuestEnvironment.writeEnvFile(
                ["RC_GUEST_RUN_ID": runID, "SECRET_PROBE": "s3cr3t"],
                runID: runID,
                directory: self.root.appendingPathComponent("guest-runs")
            )
            return DistillGuestLaunchPlan(
                runID: runID,
                dockerExecutable: docker.path,
                container: "remotecode-bot-test",
                guestCwd: "/home/remotecode",
                guestCommand: try DistillGuestLaunchPlan.guestCommand(binaryPath: "/guest/distill", for: request),
                envFileURL: envFile,
                lease: try await leases.acquire("bot-1"),
                teardown: { status in
                    await teardownGate.wait()
                    teardowns.append(status)
                },
                killGuest: {},
                killGuestDetached: {}
            )
        }

        let first = GuestEventBox()
        let request = AgentRunRequest(
            threadId: threadID, provider: .distill, model: "grok-4.6",
            cwd: "/Users/someone/BotHome", prompt: "First request"
        )
        _ = try await adapter.startSession(request) { first.append($0) }
        let finished = try await first.waitForFinish()

        // WHY (B1): the turn's callbacks must not wait on teardown (docker kill,
        // credential cleanup); the lease is what keeps the next run of this bot
        // out until teardown is done.
        XCTAssertEqual(finished.status, .completed)
        XCTAssertEqual(finished.finalMessage, "guest reply 1")
        XCTAssertEqual(teardowns.values, [], "callbacks arrived while teardown was still blocked")
        let heldDuringTeardown = await leases.isHeld("bot-1")
        XCTAssertTrue(heldDuringTeardown, "the bot's lease stays held until teardown finishes")
        XCTAssertFalse(adapter.hasSession(threadId: threadID),
                       "no idle guest process keeps the bot's credentials after the turn")
        teardownGate.open()
        try await waitUntil { teardowns.values == [.completed] }
        try await waitUntilAsync { await !leases.isHeld("bot-1") }

        let spawns = records(kind: "spawn")
        XCTAssertEqual(spawns.count, 1)
        let spawn = try XCTUnwrap(spawns.first)
        let envFile = spawn[0]
        XCTAssertEqual(Array(spawn.dropFirst(3)), [
            "exec", "-i", "--env-file", envFile, "-u", "remotecode", "-w", "/home/remotecode",
            "remotecode-bot-test", "/opt/remotecode-agent/bin/run-agent", request.runId.value.uuidString, "--",
            "/guest/distill", "--no-auto-update", "agent", "--model", "grok-4.6", "--no-leader", "stdio",
        ])
        XCTAssertEqual(spawn[1], "600")
        XCTAssertEqual(spawn[2], "1", "docker reads the run's env from the file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: envFile),
                       "the env file holds secrets and is deleted once initialize proves docker read it")

        let open = try XCTUnwrap(acpParams(method: "session/new").first)
        XCTAssertEqual(open["cwd"] as? String, "/home/remotecode", "a guest cwd, never the Mac path or Mac home")
        XCTAssertEqual((open["mcpServers"] as? [Any])?.count, 0,
                       "Mac stdio MCP servers cannot run in the guest; its MCPs come from its config.toml")
        XCTAssertEqual(records(kind: "open").first, ["0"], "the env file was gone when the session opened")
        let prompt = try XCTUnwrap(acpParams(method: "session/prompt").first)
        let text = promptText(prompt)
        XCTAssertTrue(text.contains(BotPeerDelegation.askTool), "peer delegation is offered by the guest gateway")
        XCTAssertFalse(text.contains(RemoteCodeHostCatalog.workspaceCreate),
                       "the guest gateway does not offer the rc_* host catalog, so the prompt must not name it")

        // The next turn runs in a new guest process that loads the same session.
        let second = GuestEventBox()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadID, provider: .distill, model: "grok-4.6",
            cwd: "/Users/someone/BotHome", prompt: "Second request",
            providerThreadId: finished.providerThreadId
        )) { second.append($0) }
        let secondFinished = try await second.waitForFinish()
        XCTAssertEqual(secondFinished.finalMessage, "guest reply 1", "a fresh guest process answered the load")
        XCTAssertEqual(records(kind: "spawn").count, 2)
        let load = try XCTUnwrap(acpParams(method: "session/load").first)
        XCTAssertEqual(load["sessionId"] as? String, finished.providerThreadId)
        XCTAssertEqual(load["cwd"] as? String, "/home/remotecode")
        XCTAssertEqual((load["mcpServers"] as? [Any])?.count, 0)
        try await waitUntil { teardowns.values == [.completed, .completed] }
    }

    func test_recoverSpawnsNothing_readThreadIsEmpty_andForkIsUnsupportedForGuestThreads() async throws {
        // WHY (M3): opening an interrupted guest thread recovers its session;
        // that must neither throw nor start a guest process holding credentials.
        let resolver = FakeGuestResolver()
        let threadID = AgentThreadID()
        resolver.guestThreads = [threadID]
        resolver.makePlan = { _ in XCTFail("recovery must not prepare a guest run"); return nil }
        let harness = try writeMacSpawnProbe()
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        adapter.setGuestLaunchResolver(resolver)
        try await adapter.recoverSession(AgentRunRequest(
            threadId: threadID, provider: .distill, model: "grok-4.6",
            cwd: "/tmp", prompt: "", providerThreadId: "guest-session"
        )) { _ in }
        XCTAssertFalse(adapter.hasSession(threadId: threadID))
        let history = try await adapter.readThread(threadId: threadID)
        XCTAssertEqual(history.count, 0)
        XCTAssertEqual(adapter.forkSafety(threadId: threadID), .unsupported)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("mac-spawned").path),
                       "a guest thread never spawns the Mac distill")
        XCTAssertEqual(resolver.prepareCount, 0)
    }

    func test_resolverFailureFailsTheRunWithoutAMacSpawn() async throws {
        // WHY (D11): a guest thread that cannot run in its guest must fail, not
        // silently run on the Mac with the user's Mac tools and files.
        let resolver = FakeGuestResolver()
        resolver.makePlan = { _ in throw GuestTestError.vmUnavailable }
        let harness = try writeMacSpawnProbe()
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        adapter.setGuestLaunchResolver(resolver)
        do {
            _ = try await adapter.startSession(AgentRunRequest(
                threadId: AgentThreadID(), provider: .distill, model: "grok-4.6", cwd: "/tmp", prompt: "hi"
            )) { _ in }
            XCTFail("expected the resolver's error")
        } catch {
            XCTAssertEqual(error as? GuestTestError, .vmUnavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("mac-spawned").path))
    }

    func test_spawnFailureFinishesTheRunAndFreesTheLease() async throws {
        // WHY: a run that never started still claimed the bot (lease, credentials,
        // gateway token); leaving them would block every later run of the bot.
        let resolver = FakeGuestResolver()
        let leases = DistillGuestLeases()
        let teardowns = Recorder<AgentRunStatus>()
        resolver.makePlan = { request in
            DistillGuestLaunchPlan(
                runID: request.runId.value.uuidString,
                dockerExecutable: "/missing/docker",
                container: "remotecode-bot-test",
                guestCwd: "/home/remotecode",
                guestCommand: ["/guest/distill"],
                envFileURL: self.root.appendingPathComponent("never.env"),
                lease: try await leases.acquire("bot-1"),
                teardown: { teardowns.append($0) },
                killGuest: {},
                killGuestDetached: {}
            )
        }
        let adapter = DistillACPAdapter(binaryNameOverride: "/missing/mac-distill")
        adapter.setGuestLaunchResolver(resolver)
        do {
            _ = try await adapter.startSession(AgentRunRequest(
                threadId: AgentThreadID(), provider: .distill, model: "grok-4.6", cwd: "/tmp", prompt: "hi"
            )) { _ in }
            XCTFail("expected a spawn failure")
        } catch {}
        try await waitUntil { teardowns.values == [.failed] }
        try await waitUntilAsync { await !leases.isHeld("bot-1") }
    }

    func test_guestExitMidTurnFailsTheTurnAndStillTearsDownOnce() async throws {
        // WHY: the docker client can die (daemon restart, guest crash) while the
        // guest process may live on; the run must end, kill the guest and clean
        // up exactly once.
        let docker = try writeFakeDocker()
        let resolver = FakeGuestResolver()
        let kills = Recorder<String>()
        let teardowns = Recorder<AgentRunStatus>()
        resolver.makePlan = { request in
            let runID = request.runId.value.uuidString
            return DistillGuestLaunchPlan(
                runID: runID,
                dockerExecutable: docker.path,
                container: "remotecode-bot-test",
                guestCwd: "/home/remotecode",
                guestCommand: ["/guest/distill"],
                envFileURL: try DistillGuestEnvironment.writeEnvFile(
                    ["RC_GUEST_RUN_ID": runID], runID: runID,
                    directory: self.root.appendingPathComponent("guest-runs")
                ),
                lease: nil,
                teardown: { teardowns.append($0) },
                killGuest: { kills.append("kill") },
                killGuestDetached: { kills.append("detached") }
            )
        }
        let adapter = DistillACPAdapter(binaryNameOverride: "/missing/mac-distill")
        adapter.setGuestLaunchResolver(resolver)
        let box = GuestEventBox()
        _ = try await adapter.startSession(AgentRunRequest(
            threadId: AgentThreadID(), provider: .distill, model: "grok-4.6", cwd: "/tmp", prompt: "DIE now"
        )) { box.append($0) }
        let finished = try await box.waitForFinish()
        XCTAssertEqual(finished.status, .failed)
        try await waitUntil { teardowns.values == [.failed] }
        XCTAssertTrue(kills.values.contains("kill"), "the guest process is killed even though its client already exited")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(teardowns.values, [.failed], "teardown runs once")
    }

    func test_hardStopMidTurnKillsTheGuestAndFinishesTheRunAsCancelled() async throws {
        // WHY: the guest process outlives its docker client, so Stop must run
        // kill-agent and release the run as cancelled, even though the client's
        // own exit reaches the adapter as a stale termination.
        let docker = try writeFakeDocker()
        let resolver = FakeGuestResolver()
        let kills = Recorder<String>()
        let teardowns = Recorder<AgentRunStatus>()
        resolver.makePlan = { request in
            let runID = request.runId.value.uuidString
            return DistillGuestLaunchPlan(
                runID: runID,
                dockerExecutable: docker.path,
                container: "remotecode-bot-test",
                guestCwd: "/home/remotecode",
                guestCommand: ["/guest/distill"],
                envFileURL: try DistillGuestEnvironment.writeEnvFile(
                    ["RC_GUEST_RUN_ID": runID], runID: runID,
                    directory: self.root.appendingPathComponent("guest-runs")
                ),
                lease: nil,
                teardown: { teardowns.append($0) },
                killGuest: { kills.append("kill") },
                killGuestDetached: { kills.append("detached") }
            )
        }
        let adapter = DistillACPAdapter(binaryNameOverride: "/missing/mac-distill")
        adapter.setGuestLaunchResolver(resolver)
        let threadID = AgentThreadID()
        _ = try await adapter.startSession(AgentRunRequest(
            threadId: threadID, provider: .distill, model: "grok-4.6", cwd: "/tmp", prompt: "HANG"
        )) { _ in }
        try await waitUntil { !self.acpParams(method: "session/prompt").isEmpty }
        try adapter.stopSession(threadId: threadID)
        try await waitUntil { teardowns.values == [.cancelled] }
        XCTAssertTrue(kills.values.contains("kill"))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(teardowns.values, [.cancelled], "the client's exit does not finish the run a second time")
    }

    func test_finishedTurnClosesStdinAndLetsDistillExitBeforeTheKill() async throws {
        // WHY: a TERM right after `session/prompt` answers skips Distill's
        // session shutdown, which flushes the turn's last durable records
        // (TurnCompleted is fire-and-forget). Every later turn of a guest
        // thread is a `session/load` in a new process, so a lost tail is a bot
        // that forgets its last turn. EOF lets Distill exit on its own first.
        let docker = try writeFakeDocker()
        let log = recordsURL
        let kills = Recorder<String>()
        let teardowns = Recorder<AgentRunStatus>()
        let resolver = FakeGuestResolver()
        resolver.makePlan = { request in
            let runID = request.runId.value.uuidString
            return DistillGuestLaunchPlan(
                runID: runID,
                dockerExecutable: docker.path,
                container: "remotecode-bot-test",
                guestCwd: "/home/remotecode",
                guestCommand: ["/guest/distill"],
                envFileURL: try DistillGuestEnvironment.writeEnvFile(
                    ["RC_GUEST_RUN_ID": runID], runID: runID,
                    directory: self.root.appendingPathComponent("guest-runs")
                ),
                lease: nil,
                teardown: { teardowns.append($0) },
                killGuest: {
                    let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline)
                    kills.append(lines.contains("eof") ? "after-eof" : "before-eof")
                },
                killGuestDetached: { kills.append("detached") }
            )
        }
        let adapter = DistillACPAdapter(binaryNameOverride: "/missing/mac-distill")
        adapter.setGuestLaunchResolver(resolver)
        let box = GuestEventBox()
        _ = try await adapter.startSession(AgentRunRequest(
            threadId: AgentThreadID(), provider: .distill, model: "grok-4.6", cwd: "/tmp", prompt: "hi"
        )) { box.append($0) }
        let finished = try await box.waitForFinish()
        XCTAssertEqual(finished.status, .completed)
        try await waitUntil { teardowns.values == [.completed] }
        XCTAssertEqual(records(kind: "eof").count, 1, "the guest client saw EOF and exited by itself")
        XCTAssertEqual(kills.values.first, "after-eof", "kill-agent only runs once the turn's process had its clean exit")
        XCTAssertFalse(kills.values.contains("before-eof"))
    }

    func test_guestThreadWithoutAPlanFailsInsteadOfRunningOnTheMac() async throws {
        // WHY (D11): the resolver's two answers are written separately; if
        // `prepare` says "Mac" for a thread `isGuestThread` calls a guest
        // thread, the run must fail, not silently use the Mac's tools and files.
        let resolver = FakeGuestResolver()
        let threadID = AgentThreadID()
        resolver.guestThreads = [threadID]
        resolver.makePlan = { _ in nil }
        let harness = try writeMacSpawnProbe()
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        adapter.setGuestLaunchResolver(resolver)
        do {
            _ = try await adapter.startSession(AgentRunRequest(
                threadId: threadID, provider: .distill, model: "grok-4.6", cwd: "/tmp", prompt: "hi"
            )) { _ in }
            XCTFail("a guest thread without a guest launch must not run")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("mac-spawned").path))
    }

    func test_aPlanForAnOpenWithoutAPromptIsFinishedAndRefused() async throws {
        // WHY: only a turn's end finishes a guest run. A guest session opened
        // with no prompt (recovery of a thread `isGuestThread` missed) would
        // hold the bot's lease and credentials until Stop or quit.
        let docker = try writeFakeDocker()
        let resolver = FakeGuestResolver()
        let leases = DistillGuestLeases()
        let teardowns = Recorder<AgentRunStatus>()
        resolver.makePlan = { request in
            DistillGuestLaunchPlan(
                runID: request.runId.value.uuidString,
                dockerExecutable: docker.path,
                container: "remotecode-bot-test",
                guestCwd: "/home/remotecode",
                guestCommand: ["/guest/distill"],
                envFileURL: self.root.appendingPathComponent("never.env"),
                lease: try await leases.acquire("bot-1"),
                teardown: { teardowns.append($0) },
                killGuest: {},
                killGuestDetached: {}
            )
        }
        let adapter = DistillACPAdapter(binaryNameOverride: "/missing/mac-distill")
        adapter.setGuestLaunchResolver(resolver)
        let threadID = AgentThreadID()
        do {
            try await adapter.recoverSession(AgentRunRequest(
                threadId: threadID, provider: .distill, model: "grok-4.6",
                cwd: "/tmp", prompt: "", providerThreadId: "guest-session"
            )) { _ in }
            XCTFail("a guest plan for an open without a prompt must be refused")
        } catch {}
        XCTAssertFalse(adapter.hasSession(threadId: threadID))
        XCTAssertEqual(records(kind: "spawn").count, 0, "no guest process was started")
        try await waitUntil { teardowns.values == [.cancelled] }
        try await waitUntilAsync { await !leases.isHeld("bot-1") }
    }

    func test_appTerminationKillsTheGuestWithoutWaiting() throws {
        // WHY: at quit nothing async completes; the guest process would keep
        // running with live credentials until the lease reaper caught it.
        let kills = Recorder<String>()
        let docker = root.appendingPathComponent("idle-docker")
        try "#!/bin/sh\nexec sleep 30\n".write(to: docker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)
        let plan = DistillGuestLaunchPlan(
            runID: UUID().uuidString, dockerExecutable: docker.path, container: "c",
            guestCwd: "/home/remotecode", guestCommand: [], envFileURL: root.appendingPathComponent("x.env"),
            lease: nil, teardown: { _ in },
            killGuest: { kills.append("kill") }, killGuestDetached: { kills.append("detached") }
        )
        let client = try DistillACPClient(guest: plan)
        client.stopImmediatelyForAppTermination()
        XCTAssertEqual(kills.values, ["detached"])
    }

    // MARK: - Lease

    func test_leaseSerializesOneBotAndLeavesOtherBotsAlone() async throws {
        // WHY (B1): a queued thread of the same bot must not start (and rewrite
        // the guest's credentials) until the previous run's teardown is done.
        let leases = DistillGuestLeases()
        let first = try await leases.acquire("bot-1")
        let other = try await leases.acquire("bot-2")
        let acquired = Recorder<String>()
        let waiter = Task {
            let second = try await leases.acquire("bot-1")
            acquired.append("second")
            await second.release()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(acquired.values, [], "the second run of bot-1 waits")
        await first.release()
        await first.release()
        try await waiter.value
        XCTAssertEqual(acquired.values, ["second"])
        let stillHeld = await leases.isHeld("bot-1")
        XCTAssertFalse(stillHeld, "a repeated release does not free a lease someone else holds")
        await other.release()
    }

    func test_hungTeardownStillFreesTheLease() async throws {
        // WHY: the lease is what the next run of the bot waits on; a cleanup
        // that never returns must not block that bot until the app restarts.
        let leases = DistillGuestLeases()
        let never = Gate()
        let plan = DistillGuestLaunchPlan(
            runID: UUID().uuidString, dockerExecutable: "/missing/docker", container: "c",
            guestCwd: "/home/remotecode", guestCommand: [], envFileURL: root.appendingPathComponent("x.env"),
            lease: try await leases.acquire("bot-1"),
            teardown: { _ in await never.wait() },
            killGuest: {}, killGuestDetached: {},
            teardownTimeout: 0.2
        )
        await plan.finish(.completed).value
        let held = await leases.isHeld("bot-1")
        XCTAssertFalse(held, "teardown timed out and the lease was freed anyway")
        let next = try await leases.acquire("bot-1")
        await next.release()
        never.open()
    }

    func test_cancelledWaiterLeavesTheQueueAndNeverTakesTheLease() async throws {
        // WHY: Stop on a run still waiting for its bot must end that wait, and
        // the cancelled run must not later hold the bot's guest.
        let leases = DistillGuestLeases()
        let first = try await leases.acquire("bot-1")
        let waiter = Task { try await leases.acquire("bot-1") }
        try await Task.sleep(nanoseconds: 100_000_000)
        waiter.cancel()
        do {
            let lease = try await waiter.value
            await lease.release()
            XCTFail("a cancelled waiter must not get the lease")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await first.release()
        let held = await leases.isHeld("bot-1")
        XCTAssertFalse(held, "release found no waiter to hand the lease to")
    }

    func test_guestPromptDropsOnlyTheHostCatalogParagraph() {
        XCTAssertEqual(
            BotPeerDelegation.providerDirective,
            BotPeerDelegation.peerDirective + "\n\n" + RemoteCodeHostCatalog.providerDirective,
            "Mac runs keep the exact directive they had"
        )
        XCTAssertFalse(BotPeerDelegation.peerDirective.contains("rc_"))
    }

    // MARK: - Helpers

    private func makePlan(runID: String, docker: String, command: [String]) -> DistillGuestLaunchPlan {
        DistillGuestLaunchPlan(
            runID: runID,
            dockerExecutable: docker,
            container: "remotecode-bot-test",
            guestCwd: "/home/remotecode",
            guestCommand: command,
            envFileURL: root.appendingPathComponent("\(runID).env"),
            lease: nil,
            teardown: { _ in }
        )
    }

    /// Tab-separated lines the fake docker writes: `kill <argv…>`,
    /// `spawn <env file> <mode> <had secret 0|1> <argv…>`, `open <env file
    /// exists 0|1>` and `eof` when its stdin closes.
    private var recordsURL: URL { root.appendingPathComponent("docker.tsv") }
    /// Every ACP line the fake docker read, verbatim.
    private var acpURL: URL { root.appendingPathComponent("acp.jsonl") }

    private func records(kind: String) -> [[String]] {
        guard let text = try? String(contentsOf: recordsURL, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
            .filter { $0.first == kind }
            .map { Array($0.dropFirst()) }
    }

    private func acpParams(method: String) -> [[String: Any]] {
        guard let text = try? String(contentsOf: acpURL, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["method"] as? String == method }
            .compactMap { $0["params"] as? [String: Any] }
    }

    private func promptText(_ params: [String: Any]) -> String {
        (params["prompt"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private func waitForRecords(kind: String, count: Int) async throws -> [[String]] {
        try await waitUntil { self.records(kind: kind).count >= count }
        return records(kind: kind)
    }

    /// A `docker` (POSIX sh, no python) that speaks just enough line-based ACP
    /// for `docker exec -i … -- <cmd>` and records `kill-agent` calls. A
    /// prompt with DIE exits mid-turn; one with HANG is never answered.
    private func writeFakeDocker() throws -> URL {
        let url = root.appendingPathComponent("docker")
        let script = #"""
        #!/bin/sh
        log=__LOG__
        acp=__ACP__
        record() { printf '%s' "$1"; shift; for a in "$@"; do printf '\t%s' "$a"; done; printf '\n'; }
        case " $* " in
        *" -i "*) ;;
        *) record kill "$@" >> "$log"; exit 0 ;;
        esac
        env_file= prev=
        for a in "$@"; do
            [ "$prev" = "--env-file" ] && env_file=$a
            prev=$a
        done
        if grep -qx 'SECRET_PROBE=s3cr3t' "$env_file"; then secret=1; else secret=0; fi
        record spawn "$env_file" "$(stat -f %Lp "$env_file")" "$secret" "$@" >> "$log"
        number() { printf '%s\n' "$line" | sed -n "s/.*\"$1\":\([0-9][0-9]*\).*/\1/p"; }
        string() { printf '%s\n' "$line" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }
        while IFS= read -r line; do
            printf '%s\n' "$line" >> "$acp"
            id=$(number id)
            [ -n "$id" ] || continue
            case $line in
            *'"method":"initialize"'*)
                printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{}}}}\n' "$id" ;;
            *'"method":"session/new"'*|*'"method":"session/load"'*)
                session=$(string sessionId)
                [ -n "$session" ] || session=guest-session-1
                if [ -e "$env_file" ]; then exists=1; else exists=0; fi
                record open "$exists" >> "$log"
                printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"%s","models":{"availableModels":[],"currentModelId":"grok-4.6"}}}\n' "$id" "$session" ;;
            *'"method":"session/prompt"'*)
                case $line in *DIE*) exit 3 ;; *HANG*) continue ;; esac
                printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"%s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"guest reply 1"}}}}\n' "$(string sessionId)"
                printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id" ;;
            *)
                printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id" ;;
            esac
        done
        record eof >> "$log"
        """#
            .replacingOccurrences(of: "__LOG__", with: shellQuoted(recordsURL.path))
            .replacingOccurrences(of: "__ACP__", with: shellQuoted(acpURL.path))
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// A Mac `distill` that only records that it was started.
    private func writeMacSpawnProbe() throws -> URL {
        let url = root.appendingPathComponent("mac-distill")
        let marker = root.appendingPathComponent("mac-spawned").path
        try "#!/bin/sh\ntouch \(marker)\nexit 1\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw GuestTestError.timedOut }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func waitUntilAsync(timeout: TimeInterval = 5, _ condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date() < deadline else { throw GuestTestError.timedOut }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private enum GuestTestError: Error, Equatable {
    case timedOut
    case vmUnavailable
}

private final class FakeGuestResolver: DistillGuestLaunchResolving, @unchecked Sendable {
    private let lock = NSLock()
    var guestThreads: Set<AgentThreadID> = []
    var makePlan: (@Sendable (AgentRunRequest) async throws -> DistillGuestLaunchPlan?)?
    private var prepares = 0

    var prepareCount: Int { lock.withLock { prepares } }

    func isGuestThread(_ threadId: AgentThreadID) -> Bool {
        lock.withLock { guestThreads.contains(threadId) }
    }

    func prepare(_ request: AgentRunRequest) async throws -> DistillGuestLaunchPlan? {
        let make = lock.withLock { () -> (@Sendable (AgentRunRequest) async throws -> DistillGuestLaunchPlan?)? in
            prepares += 1
            return makePlan
        }
        return try await make?(request)
    }
}

private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    func append(_ value: Value) { lock.withLock { storage.append(value) } }
    var values: [Value] { lock.withLock { storage } }
}

/// Blocks teardown until the test opens it.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}

private final class GuestEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AgentRunEvent] = []

    func append(_ event: AgentRunEvent) { lock.withLock { values.append(event) } }

    func waitForFinish(timeout: TimeInterval = 10) async throws -> (status: AgentRunStatus, finalMessage: String?, providerThreadId: String?) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let result = lock.withLock { () -> (AgentRunStatus, String?, String?)? in
                values.compactMap { event -> (AgentRunStatus, String?, String?)? in
                    guard case .finished(let status, let final, let providerThreadId) = event else { return nil }
                    return (status, final, providerThreadId)
                }.first
            }
            if let result { return result }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw GuestTestError.timedOut
    }
}
