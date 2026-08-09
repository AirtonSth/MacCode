import XCTest
@testable import AgentRuntime
import CoreModel

final class GrokACPAdapterTests: ProviderProcessTestCase {
    override func tearDown() {
        TokenSaverCensusSeam.sharedStore = TokenSaverCensusStore()
        super.tearDown()
    }

    func test_newSessionStreamsPermissionAndSettlesApprovedTurn() async throws {
        let peer = try FakeGrokACPPeer(mode: .permission)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path, cancellationGracePeriod: 0.05)
        let request = makeRequest()
        let box = GrokACPEventBox()
        _ = try await adapter.startSession(request) { box.append($0) }
        let pending = try await box.waitForRequest(timeout: 3)
        XCTAssertEqual(pending.id, "0")
        XCTAssertFalse(pending.allowsSessionApproval,
                       "the UI must hide Approve Session when ACP offered only allow_once")
        try await adapter.respondToRequest(threadId: request.threadId, requestId: pending.id, response: .approve)
        let finished = try await box.waitFinished(timeout: 3)
        XCTAssertEqual(finished.status, .completed)
        XCTAssertEqual(finished.providerThreadId, "session-fixed")
        XCTAssertEqual(finished.finalMessage, "done")
    }

    /// WHY: stopReason max_tokens is completed-class on the ACP wire. Treating it
    /// as .failed produces a false error event and wrong run status.
    func test_maxTokensStopReasonCompletesWithoutError() async throws {
        let peer = try FakeGrokACPPeer(mode: .maxTokens)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path, cancellationGracePeriod: 0.05)
        let request = makeRequest()
        let box = GrokACPEventBox()
        _ = try await adapter.startSession(request) { box.append($0) }
        let finished = try await box.waitFinished(timeout: 3)
        XCTAssertEqual(finished.status, .completed,
                       "max_tokens must complete the turn, not fail it")
        XCTAssertEqual(finished.finalMessage, "token cap reached")
        XCTAssertTrue(box.errors.isEmpty,
                      "completed-class stop reasons must not emit .error events")
    }

    /// WHY: field 2026-08-05 — Grok streamed a full **COMPLETE** final then
    /// never resolved session/prompt (timeout: nil). Working latched 70m+ with
    /// Stop while durable agent_runs stayed running. The inactivity watchdog
    /// must synthesize exactly one terminal so coordinator ownership releases.
    func test_turnInactivityWatchdogSynthesizesTerminalWhenPromptNeverReturns() async throws {
        let peer = try FakeGrokACPPeer(mode: .hangAfterFinal)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(
            binaryNameOverride: peer.path,
            cancellationGracePeriod: 0.05,
            turnInactivityTimeout: 0.25
        )
        let request = makeRequest()
        let box = GrokACPEventBox()
        _ = try await adapter.startSession(request) { box.append($0) }

        let finished = try await box.waitFinished(timeout: 4)
        XCTAssertEqual(finished.status, .completed,
                       "watchdog must prefer completed when speakable final text already streamed")
        XCTAssertEqual(finished.finalMessage, "**COMPLETE** residual note")
        XCTAssertTrue(box.hasWatchdogSynthesizedMarker,
                      "inferred terminals must carry a distinct runtime marker for forensics")
        // Late real prompt results must not double-emit (generation + turnTerminalEmitted).
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(box.finishedCount, 1,
                       "exactly one .finished — late prompt result must not double-terminate")
    }

    /// WHY: field 2026-08-06 — fixed absolute-max (900s) false-completed a
    /// long starsac CI goal mid-Cloud-Build while tools were still progressing.
    /// There must be no wall-clock max: continuous stream/tool activity fully
    /// re-arms inactivity so goals can run for hours. Only true quiet synthesizes.
    func test_turnInactivityWatchdogDoesNotFireWhileStreamEventsContinue() async throws {
        let peer = try FakeGrokACPPeer(mode: .heartbeatThenHangAfterFinal)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(
            binaryNameOverride: peer.path,
            cancellationGracePeriod: 0.05,
            turnInactivityTimeout: 0.25
        )
        let request = makeRequest()
        let box = GrokACPEventBox()
        _ = try await adapter.startSession(request) { box.append($0) }

        // Heartbeats span > inactivity window; turn must still be open.
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(box.finishedCount, 0,
                       "active stream must re-arm inactivity — no absolute max may force completed")

        let finished = try await box.waitFinished(timeout: 4)
        XCTAssertEqual(finished.status, .completed)
        XCTAssertTrue(box.hasWatchdogSynthesizedMarker,
                      "only post-quiet inactivity synthesizes the terminal")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(box.finishedCount, 1,
                       "synthesis must not double-terminate")
    }

    /// WHY: quiet mid long tool after speakable preamble used to synthesize
    /// `.completed` (false green goal). Open tool_call must force interrupted.
    func test_turnInactivityWatchdogInterruptsWhenToolCallStillOpen() async throws {
        let peer = try FakeGrokACPPeer(mode: .hangAfterOpenTool)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(
            binaryNameOverride: peer.path,
            cancellationGracePeriod: 0.05,
            turnInactivityTimeout: 0.25
        )
        let request = makeRequest()
        let box = GrokACPEventBox()
        _ = try await adapter.startSession(request) { box.append($0) }

        let finished = try await box.waitFinished(timeout: 4)
        XCTAssertEqual(finished.status, .interrupted,
                       "open tool_call + quiet must not paint completed")
        XCTAssertTrue(box.hasWatchdogSynthesizedMarker)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(box.finishedCount, 1)
    }

    /// WHY: crash 2026-08-06 — fire→emit→refresh re-entered fire mid-synthesis
    /// and overflowed the stack. Synthesis flag must still serialize that path
    /// even without absolute max.
    func test_turnWatchdogSynthesisDoesNotRecurseOnEmitReentry() async throws {
        let peer = try FakeGrokACPPeer(mode: .hangAfterFinal)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(
            binaryNameOverride: peer.path,
            cancellationGracePeriod: 0.05,
            turnInactivityTimeout: 0.15
        )
        let request = makeRequest()
        let box = GrokACPEventBox()
        _ = try await adapter.startSession(request) { box.append($0) }

        let finished = try await box.waitFinished(timeout: 4)
        XCTAssertEqual(finished.status, .completed)
        XCTAssertTrue(box.hasWatchdogSynthesizedMarker)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(box.finishedCount, 1,
                       "emit during synthesis must not re-enter fire / double-terminate")
    }

    func test_foreignRunAsDoesNotRecordTokenSaverCensus() async throws {
        let peer = try FakeGrokACPPeer(mode: .permission)
        defer { peer.remove() }
        let census = TokenSaverCensusStore()
        TokenSaverCensusSeam.sharedStore = census
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path, cancellationGracePeriod: 0.05)
        let foreign = AgentRunAsUser(
            generatedUID: "foreign",
            shortName: "foreign",
            uid: getuid() &+ 1,
            gid: getgid(),
            homePath: "/tmp"
        )
        let request = makeRequest(runAsUser: foreign)
        let box = GrokACPEventBox()
        _ = try await adapter.startSession(request) { box.append($0) }
        let pending = try await box.waitForRequest(timeout: 3)
        try await adapter.respondToRequest(
            threadId: request.threadId,
            requestId: pending.id,
            response: .approve
        )
        _ = try await box.waitFinished(timeout: 3)
        XCTAssertTrue(census.snapshot().isEmpty)
    }

    func test_cancelUsesACPNotificationAndDoesNotHardCloseFirst() async throws {
        let peer = try FakeGrokACPPeer(mode: .cancel)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path, cancellationGracePeriod: 1)
        let request = makeRequest()
        let box = GrokACPEventBox()
        let handle = try await adapter.startSession(request) { box.append($0) }
        try await Task.sleep(nanoseconds: 50_000_000)
        handle.cancel()
        let finished = try await box.waitFinished(timeout: 3)
        XCTAssertEqual(finished.status, .cancelled)
        XCTAssertEqual(finished.providerThreadId, "session-fixed")
    }

    func test_crashBeforePromptResponseIsFailedButKeepsProviderIdentity() async throws {
        let peer = try FakeGrokACPPeer(mode: .crash)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path, cancellationGracePeriod: 0.05)
        let request = makeRequest()
        let box = GrokACPEventBox()
        _ = try await adapter.startSession(request) { box.append($0) }
        let finished = try await box.waitFinished(timeout: 3)
        XCTAssertEqual(finished.status, .failed)
        XCTAssertEqual(finished.providerThreadId, "session-fixed", "AG-011: session/new identity survives pre-final crash")
        XCTAssertFalse(box.errors.isEmpty, "AG-028: transport failure must feed the shared error/retry path")
    }

    func test_officialPromptFailuresEmitDistinctStableRecoveryTaxonomy() async throws {
        let cases: [(FakeGrokACPPeer.Mode, GrokACPFailureCategory, String)] = [
            (.auth, .authRequired, GrokACPFailureTaxonomy.authRequiredMarker),
            (.rateLimit, .rateLimited, GrokACPFailureTaxonomy.rateLimitedMarker),
            (.network, .network, GrokACPFailureTaxonomy.networkMarker)
        ]

        for (mode, expectedCategory, marker) in cases {
            let peer = try FakeGrokACPPeer(mode: mode)
            defer { peer.remove() }
            let adapter = GrokACPAdapter(binaryNameOverride: peer.path)
            let box = GrokACPEventBox()

            _ = try await adapter.startSession(makeRequest()) { box.append($0) }
            let finished = try await box.waitFinished(timeout: 3)

            XCTAssertEqual(finished.status, .failed, "\(mode) must end the turn as failed")
            let error = try XCTUnwrap(box.errors.last)
            XCTAssertTrue(error.hasPrefix(marker), "\(mode) must emit its stable UI recovery marker")
            XCTAssertEqual(
                GrokACPFailureTaxonomy.normalize(diagnostic: error, context: .turn).category,
                expectedCategory
            )
            XCTAssertFalse(error.contains("fake-secret-value"),
                           "\(mode) diagnostics must redact provider credentials")
            XCTAssertFalse(error.contains("/Users/example"),
                           "\(mode) diagnostics must redact host paths")
            adapter.stopAll()
        }
    }

    func test_invalidResumeFailsStartWithStartFreshTaxonomy() async throws {
        let peer = try FakeGrokACPPeer(mode: .invalidResume)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)

        do {
            try await adapter.recoverSession(makeRequest(providerThreadId: "expired-session")) { _ in }
            XCTFail("an invalid provider resume identity must fail loud")
        } catch let failure as GrokACPFailure {
            XCTAssertEqual(failure.category, .invalidResume)
            XCTAssertTrue(failure.message.hasPrefix(GrokACPFailureTaxonomy.invalidResumeMarker),
                          "the UI must offer Start fresh instead of retrying the same invalid identity")
        }
    }

    func test_malformedJSONFailsLoudWithoutInventingRecovery() async throws {
        let peer = try FakeGrokACPPeer(mode: .invalidJSON)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)
        let box = GrokACPEventBox()

        _ = try await adapter.startSession(makeRequest()) { box.append($0) }
        let finished = try await box.waitFinished(timeout: 3)
        let error = try XCTUnwrap(box.errors.last)

        XCTAssertEqual(finished.status, .failed)
        XCTAssertTrue(error.hasPrefix("Grok ACP failure:"),
                      "invalid JSON must remain visible as a protocol failure")
        XCTAssertFalse(error.contains("[retryable:"),
                       "malformed JSON has no proven safe retry behavior")
        XCTAssertFalse(error.contains("[start-fresh:"),
                       "malformed JSON alone does not prove that the saved session is invalid")
    }

    func test_recoverUsesLoadAndAcceptsReplayBeforeResponse() async throws {
        let peer = try FakeGrokACPPeer(mode: .load)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)
        let request = makeRequest(providerThreadId: "saved-session")
        let box = GrokACPEventBox()
        try await adapter.recoverSession(request) { box.append($0) }
        XCTAssertTrue(adapter.hasSession(threadId: request.threadId))
        // Recovery restores ACP context for pull (`readThread`), not by pushing
        // historical tools into the live onEvent stream (Claude/Codex contract).
        XCTAssertFalse(box.assistantText.contains("replayed"),
                       "recover must not push load replay into the live event stream")
        let history = try await adapter.readThread(threadId: request.threadId)
        XCTAssertTrue(Self.assistantText(in: history).contains("replayed"),
                      "session/load after process death must restore readable ACP context via readThread")
        XCTAssertTrue(Self.toolCallIds(in: history).contains("load-tool-1"))
        XCTAssertEqual(adapter.listSessions().first?.providerThreadId, "saved-session")
    }

    func test_replacingRecoveredSessionIgnoresLateOldProcessTermination() async throws {
        // WHY: replacing a recovered Grok process stops the old transport. Its
        // asynchronous termination callback must not evict the new session
        // stored under the same host thread.
        let peer = try FakeGrokACPPeer(mode: .load)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)
        let threadId = AgentThreadID()

        try await adapter.recoverSession(makeRequest(
            threadId: threadId,
            providerThreadId: "old-session"
        )) { _ in }
        try await adapter.recoverSession(makeRequest(
            threadId: threadId,
            providerThreadId: "replacement-session"
        )) { _ in }

        XCTAssertEqual(peer.launchCount, 2)
        XCTAssertTrue(adapter.hasSession(threadId: threadId))
        XCTAssertEqual(
            adapter.listSessions().first { $0.threadId == threadId }?.providerThreadId,
            "replacement-session"
        )
        adapter.stopAll()
    }

    func test_sendTurnDoesNotPublishStartedWhenRecoveredSessionDiesBeforePromptWrite() async throws {
        let peer = try FakeGrokACPPeer(mode: .load)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)
        let threadId = AgentThreadID()
        try await adapter.recoverSession(makeRequest(
            threadId: threadId,
            providerThreadId: "saved-session"
        )) { _ in }
        let failed = GrokACPEventBox()
        adapter.beforePromptWriteForTesting = {
            try? adapter.stopSession(threadId: threadId)
        }

        do {
            _ = try await adapter.sendTurn(makeRequest(
                threadId: threadId,
                providerThreadId: "saved-session"
            )) { failed.append($0) }
            XCTFail("a dead cached transport must fail before provider acceptance")
        } catch {}

        XCTAssertEqual(failed.turnStartedCount, 0)
        XCTAssertFalse(adapter.hasSession(threadId: threadId))

        adapter.beforePromptWriteForTesting = nil
        try await adapter.recoverSession(makeRequest(
            threadId: threadId,
            providerThreadId: "saved-session"
        )) { _ in }
        XCTAssertTrue(adapter.hasSession(threadId: threadId))
        XCTAssertEqual(peer.launchCount, 2)
        adapter.stopAll()
    }

    func test_promptWriteFailureBeforeAcceptanceEmitsNoTurnLifecycle() async throws {
        // WHY: a failed stdin write is start failure evidence, not evidence that
        // the provider accepted and later failed the turn.
        let peer = try FakeGrokACPPeer(mode: .promptWriteFailure)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)
        let events = GrokACPEventBox()

        do {
            _ = try await adapter.startSession(makeRequest()) { events.append($0) }
            XCTFail("a prompt write to a closed ACP stdin must fail the start")
        } catch {}

        XCTAssertEqual(adapter.promptWriteAcceptanceCountForTesting, 0)
        XCTAssertEqual(events.turnStartedCount, 0)
        XCTAssertEqual(events.runningStatusCount, 0)
        XCTAssertEqual(events.finishedCount, 0)
        adapter.stopAll()
    }

    func test_invalidatedAcceptancePermitBlocksGrokPromptBeforeWireAcceptance() async throws {
        let peer = try FakeGrokACPPeer(mode: .immediateResponse)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)
        let permit = AgentRunAcceptancePermit()
        permit.invalidate()
        var request = makeRequest()
        request.acceptancePermit = permit
        let events = GrokACPEventBox()

        do {
            _ = try await adapter.startSession(request) { events.append($0) }
            XCTFail("suppression must win before the Grok session/prompt write")
        } catch is AgentRunAcceptanceError {}
        catch {}

        XCTAssertEqual(adapter.promptWriteAcceptanceCountForTesting, 0)
        XCTAssertEqual(events.turnStartedCount, 0)
        XCTAssertEqual(events.runningStatusCount, 0)
        XCTAssertEqual(events.finishedCount, 0)
        adapter.stopAll()
    }

    func test_globalShutdownAfterPromptGuardCannotPublishAcceptanceOrTerminal() async throws {
        let peer = try FakeGrokACPPeer(mode: .load)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)
        let threadId = AgentThreadID()
        try await adapter.recoverSession(makeRequest(
            threadId: threadId,
            providerThreadId: "saved-session"
        )) { _ in }
        let events = GrokACPEventBox()
        adapter.beforePromptWriteForTesting = {
            adapter.stopAllForAppTermination()
        }

        do {
            _ = try await adapter.sendTurn(makeRequest(
                threadId: threadId,
                providerThreadId: "saved-session"
            )) { events.append($0) }
            XCTFail("global shutdown must invalidate the guarded session before write")
        } catch {}

        XCTAssertEqual(events.turnStartedCount, 0)
        XCTAssertEqual(events.runningStatusCount, 0)
        XCTAssertEqual(events.finishedCount, 0)
        XCTAssertEqual(adapter.promptWriteAcceptanceCountForTesting, 0)
    }

    func test_replacementAfterPromptGuardCannotAcceptOnOldSession() async throws {
        let peer = try FakeGrokACPPeer(mode: .load)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)
        let threadId = AgentThreadID()
        try await adapter.recoverSession(makeRequest(
            threadId: threadId,
            providerThreadId: "old-session"
        )) { _ in }
        let entered = expectation(description: "old send reached pre-write barrier")
        let release = DispatchSemaphore(value: 0)
        adapter.beforePromptWriteForTesting = {
            entered.fulfill()
            release.wait()
        }
        let events = GrokACPEventBox()
        let oldSend = Task {
            try await adapter.sendTurn(makeRequest(
                threadId: threadId,
                providerThreadId: "old-session"
            )) { events.append($0) }
        }
        await fulfillment(of: [entered], timeout: 3)

        try await adapter.recoverSession(makeRequest(
            threadId: threadId,
            providerThreadId: "replacement-session"
        )) { _ in }
        release.signal()
        do {
            _ = try await oldSend.value
            XCTFail("the replaced session must not accept the old prompt")
        } catch {}

        XCTAssertEqual(events.turnStartedCount, 0)
        XCTAssertEqual(events.runningStatusCount, 0)
        XCTAssertEqual(events.finishedCount, 0)
        XCTAssertEqual(adapter.promptWriteAcceptanceCountForTesting, 0)
        XCTAssertEqual(adapter.listSessions().first?.providerThreadId, "replacement-session")
        adapter.stopAll()
    }

    func test_replacementAfterFinalGuardInvalidatesPhysicalWritePermitBeforeOldPeerBytes() async throws {
        let peer = try FakeGrokACPPeer(mode: .load)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)
        let threadId = AgentThreadID()
        try await adapter.recoverSession(makeRequest(
            threadId: threadId,
            providerThreadId: "old-session"
        )) { _ in }
        let entered = GrokACPAsyncSignal()
        let release = DispatchSemaphore(value: 0)
        adapter.beforePhysicalPromptWriteForTesting = {
            Task { await entered.signal() }
            release.wait()
        }
        let events = GrokACPEventBox()
        let oldSend = Task {
            try await adapter.sendTurn(makeRequest(
                threadId: threadId,
                providerThreadId: "old-session"
            )) { events.append($0) }
        }
        await entered.wait()

        try await adapter.recoverSession(makeRequest(
            threadId: threadId,
            providerThreadId: "replacement-session"
        )) { _ in }
        release.signal()
        do {
            _ = try await oldSend.value
            XCTFail("the replaced session must fail its old physical prompt write")
        } catch {}

        XCTAssertEqual(peer.promptCount, 0,
                       "replacement after the adapter guard must invalidate the permit before old-peer bytes")
        XCTAssertEqual(events.turnStartedCount, 0)
        XCTAssertEqual(events.runningStatusCount, 0)
        XCTAssertEqual(events.finishedCount, 0)
        XCTAssertEqual(adapter.promptWriteAcceptanceCountForTesting, 0)
        XCTAssertEqual(adapter.listSessions().first?.providerThreadId, "replacement-session")
        adapter.stopAll()
    }

    func test_sendTurnKeepsSuccessfulPromptWriteAcceptedWhenSessionDiesImmediatelyAfterward() async throws {
        // WHY: once the ACP prompt is registered and written, provider
        // acceptance is positive evidence. A transport death after that point
        // must not make queue recovery replay the same prompt.
        let peer = try FakeGrokACPPeer(mode: .load)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)
        let threadId = AgentThreadID()
        try await adapter.recoverSession(makeRequest(
            threadId: threadId,
            providerThreadId: "saved-session"
        )) { _ in }
        let accepted = GrokACPEventBox()
        adapter.afterPromptWriteForTesting = {
            try? adapter.stopSession(threadId: threadId)
        }

        _ = try await adapter.sendTurn(makeRequest(
            threadId: threadId,
            providerThreadId: "saved-session"
        )) { accepted.append($0) }

        XCTAssertEqual(accepted.runningStatusCount, 1,
                       "a successful ACP stdin write must publish provider acceptance exactly once")
        XCTAssertFalse(adapter.hasSession(threadId: threadId))
        XCTAssertEqual(adapter.promptWriteAcceptanceCountForTesting, 1)

        adapter.afterPromptWriteForTesting = nil
        try await adapter.recoverSession(makeRequest(
            threadId: threadId,
            providerThreadId: "saved-session"
        )) { _ in }
        XCTAssertEqual(peer.launchCount, 2)
        XCTAssertEqual(adapter.promptWriteAcceptanceCountForTesting, 1,
                       "recovering the dead session must not replay an already accepted prompt")
        adapter.stopAll()
    }

    func test_immediatePromptResponseCannotOvertakeWriteAcceptance() async throws {
        // WHY: an ACP peer may respond in the same scheduler slice as stdin
        // write. The accepted/running evidence must exist before completion so
        // queue recovery never mistakes accepted work for a replay candidate.
        let peer = try FakeGrokACPPeer(mode: .immediateResponse)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)
        let events = GrokACPEventBox()

        _ = try await adapter.startSession(makeRequest()) { events.append($0) }
        let finished = try await events.waitFinished(timeout: 3)

        XCTAssertEqual(finished.status, .completed)
        XCTAssertEqual(events.lifecycleLabels, ["turn_started", "running", "turn_completed", "finished"])
        XCTAssertEqual(adapter.promptWriteAcceptanceCountForTesting, 1)
        XCTAssertEqual(adapter.promptWriteAcceptanceCountForTesting, 1)
        XCTAssertEqual(peer.launchCount, 1)
        adapter.stopAll()
    }

    func test_sendTurnAfterProcessDeathDoesNotPublishLoadReplayUnderNewPrompt() async throws {
        // WHY: follow-up after ACP process death used to drain session/load
        // replay into the live turn (143 prior steps under the new bubble).
        // Load must restore provider context silently; only the new prompt's
        // work may appear on the follow-up event stream.
        let peer = try FakeGrokACPPeer(mode: .loadThenPrompt)
        defer { peer.remove() }
        let threadId = AgentThreadID()
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)
        let box = GrokACPEventBox()

        _ = try await adapter.sendTurn(makeRequest(
            threadId: threadId,
            providerThreadId: "saved-session"
        )) { box.append($0) }
        let finished = try await box.waitFinished(timeout: 3)

        XCTAssertEqual(finished.status, .completed)
        XCTAssertFalse(box.assistantText.contains("replayed"),
                       "session/load historical text must not enter the follow-up turn stream")
        XCTAssertFalse(box.toolCallIds.contains("load-tool-1"),
                       "session/load historical tools must not enter the follow-up turn stream")
        XCTAssertTrue(box.assistantText.contains("fresh-follow-up"),
                      "only the new prompt response may stream after load+prompt")
        XCTAssertEqual(box.turnStartedCount, 1,
                       "exactly one user-facing turn after sealed load hydration")
        XCTAssertEqual(peer.launchCount, 1)
        adapter.stopAll()
    }

    func test_recoverThenSendTurnDoesNotInheritReplayTurnIdentity() async throws {
        // WHY: recoverSession records load history for readThread and seals so
        // the next sendTurn mints a fresh turnStarted — never inherits replay.
        let peer = try FakeGrokACPPeer(mode: .loadThenPrompt)
        defer { peer.remove() }
        let threadId = AgentThreadID()
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)

        let recovered = GrokACPEventBox()
        try await adapter.recoverSession(makeRequest(
            threadId: threadId,
            providerThreadId: "saved-session"
        )) { recovered.append($0) }
        let history = try await adapter.readThread(threadId: threadId)
        XCTAssertTrue(Self.assistantText(in: history).contains("replayed"),
                      "recoverSession restores ACP context via readThread")
        XCTAssertTrue(Self.toolCallIds(in: history).contains("load-tool-1"))
        XCTAssertFalse(recovered.assistantText.contains("replayed"),
                       "recover must not push replay into the live event stream")

        let followUp = GrokACPEventBox()
        _ = try await adapter.sendTurn(makeRequest(
            threadId: threadId,
            providerThreadId: "saved-session"
        )) { followUp.append($0) }
        _ = try await followUp.waitFinished(timeout: 3)

        XCTAssertFalse(followUp.assistantText.contains("replayed"),
                       "follow-up must not re-stream recovery replay text")
        XCTAssertFalse(followUp.toolCallIds.contains("load-tool-1"),
                       "follow-up must not re-stream recovery tools")
        XCTAssertTrue(followUp.assistantText.contains("fresh-follow-up"))
        XCTAssertEqual(followUp.turnStartedCount, 1)
        adapter.stopAll()
    }

    func test_cancelThenProcessDeathRecoversContextThroughSessionLoad() async throws {
        let peer = try FakeGrokACPPeer(mode: .cancel)
        defer { peer.remove() }
        let threadId = AgentThreadID()
        let initial = GrokACPAdapter(binaryNameOverride: peer.path, cancellationGracePeriod: 1)
        let firstRequest = makeRequest(threadId: threadId)
        let first = GrokACPEventBox()
        let handle = try await initial.startSession(firstRequest) { first.append($0) }
        try await Task.sleep(nanoseconds: 50_000_000)
        handle.cancel()
        let cancelled = try await first.waitFinished(timeout: 3)
        let providerThreadId = try XCTUnwrap(cancelled.providerThreadId)
        XCTAssertEqual(cancelled.status, .cancelled)

        let originalProcess = handle.process
        initial.stopAll()
        let deathDeadline = Date().addingTimeInterval(2)
        while originalProcess?.isRunning == true, Date() < deathDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(originalProcess?.isRunning == true,
                       "the simulated app/process death must terminate the original Grok ACP process before recovery")

        let relaunched = GrokACPAdapter(binaryNameOverride: peer.path)
        let replay = GrokACPEventBox()
        try await relaunched.recoverSession(makeRequest(
            threadId: threadId,
            providerThreadId: providerThreadId
        )) { replay.append($0) }

        let history = try await relaunched.readThread(threadId: threadId)
        XCTAssertTrue(Self.assistantText(in: history).contains("replayed"),
                      "session/load after process death must restore the prior readable ACP context")
        XCTAssertFalse(replay.assistantText.contains("replayed"),
                       "recovery must not push historical ACP replay into a live run stream")
        XCTAssertEqual(relaunched.listSessions().first?.providerThreadId, providerThreadId)
        XCTAssertEqual(peer.launchCount, 2,
                       "recovery proof must use a new ACP process and the prior provider session identity")
        relaunched.stopAll()
    }

    func test_forcedCancelEvictsDeadSessionBeforeSavedIdentityRecovery() async throws {
        // WHY: if Grok ignores session/cancel, the grace-period kill ends the
        // process. Keeping that dead client cached makes the next turn write to
        // a zombie transport instead of loading the durable ACP session.
        let peer = try FakeGrokACPPeer(mode: .ignoreCancel)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path, cancellationGracePeriod: 0.05)
        let threadId = AgentThreadID()
        let box = GrokACPEventBox()
        let handle = try await adapter.startSession(makeRequest(threadId: threadId)) { box.append($0) }
        handle.cancel()
        let cancelled = try await box.waitFinished(timeout: 3)
        let savedProviderThreadId = try XCTUnwrap(cancelled.providerThreadId)
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertFalse(adapter.hasSession(threadId: threadId),
                       "a process that was force-killed cannot remain a reusable live session")

        let recovered = GrokACPEventBox()
        try await adapter.recoverSession(makeRequest(
            threadId: threadId,
            providerThreadId: savedProviderThreadId
        )) { recovered.append($0) }

        let history = try await adapter.readThread(threadId: threadId)
        XCTAssertTrue(Self.assistantText(in: history).contains("replayed"),
                      "recovery must load the saved ACP identity into a fresh process")
        XCTAssertFalse(recovered.assistantText.contains("replayed"),
                       "forced-cancel recovery must not push load replay into the live stream")
        XCTAssertEqual(peer.launchCount, 2)
        adapter.stopAll()
    }

    func test_authenticatedDiscoveryUsesSessionModelsInsteadOfStaticCatalog() async throws {
        let peer = try FakeGrokACPPeer(mode: .discovery)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)
        let result = await adapter.listModelsResult()
        XCTAssertFalse(result.isFallback)
        XCTAssertEqual(result.models.map(\.id), ["account-live-model"])
    }

    func test_discoveryWithoutModeAdvertisementExposesFullPermissionSet() async throws {
        // Live Grok 0.2.x / 1.0.0 session/new often omits modes.availableModes while still
        // accepting session/set_mode for default / acceptEdits / bypassPermissions / plan.
        let peer = try FakeGrokACPPeer(mode: .discovery)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)

        let discovery = await adapter.discoveryResult()

        XCTAssertFalse(discovery.isFallback)
        XCTAssertEqual(discovery.permissionModes, AgentPermissionMode.allCases,
                       "omitted mode advertisement must not lock Full access out of the picker")
        XCTAssertTrue(discovery.permissionModes.contains(.fullAccess))
        XCTAssertEqual(discovery.interactionModes, [.default, .plan],
                       "empty mode catalog must open Plan (live set_mode plan succeeds)")
        XCTAssertTrue(discovery.capabilities.supportsPlanReview,
                      "empty mode catalog must expose Plan review capability")
    }

    func test_authenticatedDiscoverySurfacesOnlyNegotiatedPlanCapability() async throws {
        let peer = try FakeGrokACPPeer(mode: .plan)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)

        let discovery = await adapter.discoveryResult()

        XCTAssertFalse(discovery.isFallback)
        XCTAssertEqual(discovery.interactionModes, [.default, .plan])
        XCTAssertEqual(discovery.permissionModes, [.supervised],
                       "when modes are advertised without bypassPermissions, Full access stays closed")
        XCTAssertTrue(discovery.capabilities.supportsPlanReview)
        XCTAssertTrue(discovery.capabilities.supportsAttachments)
        XCTAssertTrue(discovery.capabilities.supportedAttachmentKinds.contains(.image),
                      "0.2.x must advertise image so iOS Camera/Photos are not Unavailable")
        XCTAssertTrue(discovery.capabilities.supportedAttachmentMediaTypes.contains("image/jpeg"))
        XCTAssertTrue(discovery.capabilities.supportsApprovals)
        XCTAssertFalse(discovery.capabilities.supportsUserInput)
    }

    func test_fullAccessAppliesViaSetModeWhenModesOmitted() async throws {
        let peer = try FakeGrokACPPeer(mode: .permission)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)
        let request = makeRequest(permissionMode: .fullAccess)
        let box = GrokACPEventBox()

        _ = try await adapter.startSession(request) { box.append($0) }
        let pending = try await box.waitForRequest(timeout: 3)
        try await adapter.respondToRequest(
            threadId: request.threadId,
            requestId: pending.id,
            response: .approve
        )
        let finished = try await box.waitFinished(timeout: 3)
        XCTAssertEqual(finished.status, .completed,
                       "Full access must start a usable session when ACP omits mode advertisement")
    }

    func test_permissionModeResolutionAllowsKnownWireIDsWithoutAdvertisement() throws {
        XCTAssertEqual(
            try GrokACPAdapter.resolvedPermissionModeID(for: .fullAccess, availableModeIDs: []),
            "bypassPermissions"
        )
        XCTAssertEqual(
            try GrokACPAdapter.resolvedPermissionModeID(for: .autoAcceptEdits, availableModeIDs: []),
            "acceptEdits"
        )
        XCTAssertEqual(
            GrokACPAdapter.permissionModes(from: []),
            AgentPermissionMode.allCases
        )
        XCTAssertEqual(
            GrokACPAdapter.permissionModes(from: ["default", "plan"]),
            [.supervised]
        )
        XCTAssertEqual(
            GrokACPAdapter.permissionModes(from: ["default", "acceptEdits", "bypassPermissions"]),
            [.supervised, .autoAcceptEdits, .fullAccess]
        )
        XCTAssertThrowsError(
            try GrokACPAdapter.resolvedPermissionModeID(
                for: .fullAccess,
                availableModeIDs: ["default", "plan"]
            )
        )
    }

    /// WHY: empty modes catalog must open Plan with wire id `plan`; advertised
    /// catalog without plan must stay fail-closed (GROK-ACP-006).
    func test_planModeResolutionEmptyCatalogOpensPlanAdvertisedWithoutPlanStaysClosed() {
        XCTAssertEqual(
            GrokACPAdapter.interactionModes(availableModeIDs: [], advertisedPlanModeID: nil),
            [.default, .plan]
        )
        XCTAssertEqual(
            GrokACPAdapter.resolvedPlanModeID(availableModeIDs: [], advertisedPlanModeID: nil),
            "plan"
        )
        XCTAssertEqual(
            GrokACPAdapter.interactionModes(
                availableModeIDs: ["default"],
                advertisedPlanModeID: nil
            ),
            [.default],
            "advertised catalog without plan must not expose Plan"
        )
        XCTAssertNil(
            GrokACPAdapter.resolvedPlanModeID(
                availableModeIDs: ["default"],
                advertisedPlanModeID: nil
            ),
            "advertised without plan → fail-closed (no wire fallback)"
        )
        XCTAssertEqual(
            GrokACPAdapter.interactionModes(
                availableModeIDs: ["default", "plan"],
                advertisedPlanModeID: "plan"
            ),
            [.default, .plan]
        )
        XCTAssertEqual(
            GrokACPAdapter.resolvedPlanModeID(
                availableModeIDs: ["default", "plan"],
                advertisedPlanModeID: "plan"
            ),
            "plan"
        )
    }

    func test_discoveryFailureLabelsStaticFallback() async {
        let adapter = GrokACPAdapter(binaryNameOverride: "/definitely/missing/grok")
        let result = await adapter.listModelsResult()
        XCTAssertTrue(result.isFallback)
        XCTAssertFalse(result.models.isEmpty)
    }

    func test_discoveryCacheIsSharedByBinaryAccountIdentityWithinTTL() async throws {
        let peer = try FakeGrokACPPeer(mode: .discovery)
        defer { peer.remove() }
        let firstAdapter = GrokACPAdapter(binaryNameOverride: peer.path, modelCacheTTL: 300)
        let secondAdapter = GrokACPAdapter(binaryNameOverride: peer.path, modelCacheTTL: 300)

        let first = await firstAdapter.discoveryResult()
        let second = await secondAdapter.discoveryResult()

        XCTAssertEqual(first, second)
        XCTAssertEqual(peer.launchCount, 1,
                       "production creates fresh adapters; discovery must still reuse one keyed ACP launch inside the TTL")
    }

    func test_discoveryCacheInvalidatesWhenBinaryChangesInPlace() async throws {
        let peer = try FakeGrokACPPeer(mode: .discovery)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path, modelCacheTTL: 300)
        let live = await adapter.discoveryResult()
        XCTAssertFalse(live.isFallback)

        try """
        #!/bin/sh
        printf x >> "\(peer.launchCountPath)"
        exit 1
        # replacement binary intentionally changes size and discovery behavior
        """.write(toFile: peer.path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: peer.path)

        let refreshed = await adapter.discoveryResult()
        XCTAssertTrue(refreshed.isFallback,
                      "an in-place CLI update must bypass the old live discovery cache")
        XCTAssertNotEqual(live.discoveryCacheKey, refreshed.discoveryCacheKey)
        XCTAssertEqual(peer.launchCount, 2)
    }

    func test_discoveryCacheKeyNeverDependsOnSecretEnvironmentValues() {
        let baseline = GrokACPAdapter.discoveryCacheKey(
            binary: "/tmp/grok",
            cwd: "/tmp/project",
            environment: ["HOME": "/tmp/account-a", "API_TOKEN": "secret-one"]
        )
        let rotatedSecret = GrokACPAdapter.discoveryCacheKey(
            binary: "/tmp/grok",
            cwd: "/tmp/project",
            environment: ["HOME": "/tmp/account-a", "API_TOKEN": "secret-two"]
        )
        let differentAccount = GrokACPAdapter.discoveryCacheKey(
            binary: "/tmp/grok",
            cwd: "/tmp/project",
            environment: ["HOME": "/tmp/account-b", "API_TOKEN": "secret-two"]
        )

        XCTAssertEqual(baseline, rotatedSecret,
                       "secret values must never enter an externally visible cache identity")
        XCTAssertNotEqual(baseline, differentAccount,
                          "the non-secret account-home selector must isolate authenticated catalogs")
    }

    /// WHY: live Grok 1.0.0 omits modes but accepts session/set_mode modeId=plan.
    /// Empty catalog must start Plan (wire id `plan`), not throw "did not advertise".
    func test_planUsesWirePlanIdWhenSessionOmitsModeAdvertisement() async throws {
        let peer = try FakeGrokACPPeer(mode: .permission)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)
        let request = makeRequest(interactionMode: .plan)
        let box = GrokACPEventBox()

        _ = try await adapter.startSession(request) { box.append($0) }
        let pending = try await box.waitForRequest(timeout: 3)
        try await adapter.respondToRequest(
            threadId: request.threadId,
            requestId: pending.id,
            response: .approve
        )
        let finished = try await box.waitFinished(timeout: 3)
        XCTAssertEqual(finished.status, .completed,
                       "Plan must start when ACP omits mode advertisement (set_mode plan)")
        XCTAssertTrue(adapter.hasSession(threadId: request.threadId))
    }

    func test_planUsesAdvertisedModeAndStreamsReviewableArtifact() async throws {
        let peer = try FakeGrokACPPeer(mode: .plan)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)
        let request = makeRequest(interactionMode: .plan)
        let box = GrokACPEventBox()

        _ = try await adapter.startSession(request) { box.append($0) }
        let finished = try await box.waitFinished(timeout: 3)

        XCTAssertEqual(finished.status, .completed)
        XCTAssertTrue(box.hasProposedPlan,
                      "an advertised Grok ACP Plan mode must produce a first-class plan for review")

        let approved = GrokACPEventBox()
        _ = try await adapter.sendTurn(makeRequest(
            threadId: request.threadId,
            providerThreadId: "session-fixed",
            interactionMode: .default
        )) { approved.append($0) }
        let approvedFinish = try await approved.waitFinished(timeout: 3)
        XCTAssertEqual(approvedFinish.providerThreadId, "session-fixed")
        XCTAssertTrue(approved.assistantText.contains("implementation resumed"),
                      "Approve must leave Plan mode and resume implementation in the same ACP session")

        let rejected = GrokACPEventBox()
        _ = try await adapter.sendTurn(makeRequest(
            threadId: request.threadId,
            providerThreadId: "session-fixed",
            interactionMode: .plan
        )) { rejected.append($0) }
        _ = try await rejected.waitFinished(timeout: 3)
        XCTAssertTrue(rejected.hasProposedPlan,
                      "Reject must remain in Plan mode and receive a revised plan in the same ACP session")
        XCTAssertEqual(peer.launchCount, 1,
                       "Plan review must reuse one authenticated Grok ACP process instead of starting unrelated one-shot runs")
    }

    func test_sendTurnRejectsTrueConcurrentPromptButAllowsFollowUpAfterFinish() async throws {
        let peer = try FakeGrokACPPeer(mode: .permission)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)
        let request = makeRequest(permissionMode: .supervised)
        let first = GrokACPEventBox()

        _ = try await adapter.startSession(request) { first.append($0) }
        // Permission peer leaves the first prompt open until approved.
        let pending = try await first.waitForRequest(timeout: 3)

        do {
            _ = try await adapter.sendTurn(makeRequest(
                threadId: request.threadId,
                providerThreadId: "session-fixed",
                permissionMode: .fullAccess
            )) { _ in }
            XCTFail("a second prompt while the first is open must fail closed")
        } catch {
            XCTAssertTrue(String(describing: error).contains("in-flight prompt"),
                          "true concurrent turns must keep the existing in-flight guard")
        }

        try await adapter.respondToRequest(
            threadId: request.threadId,
            requestId: pending.id,
            response: .approve
        )
        _ = try await first.waitFinished(timeout: 3)

        let second = GrokACPEventBox()
        _ = try await adapter.sendTurn(makeRequest(
            threadId: request.threadId,
            providerThreadId: "session-fixed",
            permissionMode: .fullAccess
        )) { second.append($0) }
        // Second turn also hits permission peer; approve and finish.
        let pending2 = try await second.waitForRequest(timeout: 3)
        try await adapter.respondToRequest(
            threadId: request.threadId,
            requestId: pending2.id,
            response: .approve
        )
        let finished = try await second.waitFinished(timeout: 3)
        XCTAssertEqual(finished.status, .completed,
                       "after the prior turn ends, Approve/follow-up must reuse the session")
    }

    private func makeRequest(
        threadId: AgentThreadID? = nil,
        providerThreadId: String? = nil,
        permissionMode: AgentPermissionMode = .supervised,
        interactionMode: AgentInteractionMode = .default,
        runAsUser: AgentRunAsUser? = nil
    ) -> AgentRunRequest {
        AgentRunRequest(
            threadId: threadId ?? AgentThreadID(), provider: .grok, model: "account-live-model", cwd: "/tmp",
            prompt: "hello", providerThreadId: providerThreadId, permissionMode: permissionMode,
            interactionMode: interactionMode, runAsUser: runAsUser
        )
    }

    private static func assistantText(in events: [AssistantEvent]) -> String {
        events.compactMap {
            if case .itemDelta(_, let body, _, _) = $0 { return body }
            return nil
        }.joined()
    }

    private static func toolCallIds(in events: [AssistantEvent]) -> [String] {
        events.compactMap {
            if case .itemStarted(let item) = $0, item.type == .tool { return item.id }
            return nil
        }
    }
}

private enum GrokACPTestWaitError: Error {
    case timedOut(String)
}

private final class GrokACPEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentRunEvent] = []
    var errors: [String] { lock.withLock { events.compactMap { if case .error(let text) = $0 { return text }; return nil } } }
    var assistantText: String { lock.withLock { events.compactMap { if case .event(.itemDelta(_, let body, _, _)) = $0 { return body }; return nil }.joined() } }
    var toolCallIds: [String] {
        lock.withLock {
            events.compactMap {
                if case .event(.itemStarted(let item)) = $0, item.type == .tool { return item.id }
                return nil
            }
        }
    }
    var turnStartedCount: Int {
        lock.withLock {
            events.filter {
                if case .event(.turnStarted) = $0 { return true }
                return false
            }.count
        }
    }
    var runningStatusCount: Int {
        lock.withLock {
            events.filter {
                if case .status(.running) = $0 { return true }
                return false
            }.count
        }
    }
    var finishedCount: Int {
        lock.withLock {
            events.filter {
                if case .finished = $0 { return true }
                return false
            }.count
        }
    }
    var hasWatchdogSynthesizedMarker: Bool {
        lock.withLock {
            events.contains {
                if case .event(.providerRuntime(let runtime)) = $0 {
                    return runtime.method == "grok.turn.watchdog.synthesized"
                }
                return false
            }
        }
    }
    var lifecycleLabels: [String] {
        lock.withLock {
            events.compactMap { event in
                switch event {
                case .event(.turnStarted): return "turn_started"
                case .status(.running): return "running"
                case .event(.turnCompleted): return "turn_completed"
                case .finished: return "finished"
                default: return nil
                }
            }
        }
    }
    var hasProposedPlan: Bool {
        lock.withLock { events.contains { if case .event(.proposedPlan) = $0 { return true }; return false } }
    }

    func append(_ event: AgentRunEvent) { lock.withLock { events.append(event) } }

    func waitForRequest(timeout: TimeInterval) async throws -> AssistantPendingRequest {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let request = lock.withLock({ events.compactMap { if case .event(.requestOpened(let request)) = $0 { return request }; return nil }.last }) { return request }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw GrokACPTestWaitError.timedOut("permission request")
    }

    func waitFinished(timeout: TimeInterval) async throws -> (status: AgentRunStatus, finalMessage: String?, providerThreadId: String?) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let finished = lock.withLock({ events.compactMap { event -> (AgentRunStatus, String?, String?)? in
                if case .finished(let status, let final, let providerThreadId) = event { return (status, final, providerThreadId) }
                return nil
            }.last }) { return finished }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw GrokACPTestWaitError.timedOut("finished event")
    }
}

private final class FakeGrokACPPeer {
    enum Mode: String {
        case permission, cancel, ignoreCancel, crash, load, loadThenPrompt, discovery, plan
        case auth, rateLimit, network, invalidResume, invalidJSON, immediateResponse, promptWriteFailure
        /// Streams a complete assistant final then never resolves session/prompt —
        /// field shape of the 70m Grok Working zombie. The turn-inactivity
        /// watchdog must synthesize a single terminal.
        case hangAfterFinal
        /// Streams final + continuous tool updates for longer than a short
        /// inactivity window, then hangs. Proves there is no absolute max —
        /// only quiet inactivity may synthesize.
        case heartbeatThenHangAfterFinal
        /// Streams speakable text + open tool_call, then hangs without terminal
        /// tool status — inactivity must synthesize interrupted, not completed.
        case hangAfterOpenTool
        /// Completes session/prompt with stopReason max_tokens (completed-class).
        case maxTokens
    }
    let root: URL
    let path: String
    let launchCountPath: String
    let promptCountPath: String
    let sessionIdPath: String

    var launchCount: Int {
        ((try? String(contentsOfFile: launchCountPath, encoding: .utf8)) ?? "").count
    }
    var promptCount: Int {
        ((try? String(contentsOfFile: promptCountPath, encoding: .utf8)) ?? "").count
    }

    init(mode: Mode) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fake-grok-acp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("grok")
        launchCountPath = root.appendingPathComponent("launch-count").path
        promptCountPath = root.appendingPathComponent("prompt-count").path
        sessionIdPath = root.appendingPathComponent("session-id").path
        let body = #"""
        #!/bin/sh
        mode="MODE"
        current_mode="default"
        session_id="session-fixed"
        printf x >> "COUNT_PATH"
        while IFS= read -r line; do
          if printf '%s' "$line" | grep -q '"method":"initialize"'; then
              id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
              printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":false,"audio":false,"embeddedContext":true},"sessionCapabilities":{}},"_meta":{"agentVersion":"0.2.101"}}}\n' "$id"
          elif printf '%s' "$line" | grep -q '"method":"session.*new"'; then
              id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
              session_id="session-fixed"
              printf '%s' "$session_id" > "SESSION_ID_PATH"
              if [ "$mode" = promptWriteFailure ]; then
                exec 0<&-
              fi
              if [ "$mode" = plan ]; then
                printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"session-fixed","models":{"currentModelId":"account-live-model","availableModels":[{"modelId":"account-live-model","name":"Live"}]},"modes":{"currentModeId":"default","availableModes":[{"id":"default","name":"Default"},{"id":"plan","name":"Plan"}]}}}\n' "$id"
              else
                printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"session-fixed","models":{"currentModelId":"account-live-model","availableModels":[{"modelId":"account-live-model","name":"Live"}]}}}\n' "$id"
              fi
              if [ "$mode" = promptWriteFailure ]; then
                exec tail -f "COUNT_PATH" >/dev/null
              fi
          elif printf '%s' "$line" | grep -q '"method":"session.*load"'; then
              id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
              loaded_session=$(printf '%s' "$line" | sed -E 's/.*"sessionId":"([^"]+)".*/\1/')
              session_id="$loaded_session"
              printf '%s' "$session_id" > "SESSION_ID_PATH"
              if [ "$mode" = invalidResume ]; then
                printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"session not found: invalid resume"}}\n' "$id"
                continue
              fi
              printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"%s","update":{"sessionUpdate":"tool_call","toolCallId":"load-tool-1","title":"prior tool","rawInput":{"command":"echo prior"},"_meta":{"isReplay":true,"eventId":"replay-tool-1"}}}}\n' "$loaded_session"
              printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"%s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"replayed"},"_meta":{"isReplay":true,"eventId":"replay-1"}}}}\n' "$loaded_session"
              printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"%s"}}\n' "$id" "$loaded_session"
          elif printf '%s' "$line" | grep -q '"method":"session.*set_model"'; then
              id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
              printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id"
          elif printf '%s' "$line" | grep -q '"method":"session.*set_mode"'; then
              id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
              current_mode=$(printf '%s' "$line" | sed -E 's/.*"modeId":"([^"]+)".*/\1/')
              printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id"
          elif printf '%s' "$line" | grep -q '"method":"session.*prompt"'; then
              printf p >> "PROMPT_COUNT_PATH"
              id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
              if [ -f "SESSION_ID_PATH" ]; then session_id=$(cat "SESSION_ID_PATH"); fi
              if [ "$mode" = crash ]; then kill -ABRT $$; fi
              if [ "$mode" = cancel ] || [ "$mode" = ignoreCancel ]; then prompt_id="$id"; continue; fi
              if [ "$mode" = auth ]; then
                printf '{"jsonrpc":"2.0","id":%s,"error":{"code":401,"message":"Unauthorized access_token=fake-secret-value at /Users/example/.grok/config"}}\n' "$id"
                continue
              fi
              if [ "$mode" = rateLimit ]; then
                printf '{"jsonrpc":"2.0","id":%s,"error":{"code":429,"message":"Too many requests"}}\n' "$id"
                continue
              fi
              if [ "$mode" = network ]; then
                printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"network connection reset"}}\n' "$id"
                continue
              fi
              if [ "$mode" = invalidJSON ]; then
                printf 'not-json\n'
                continue
              fi
              if [ "$mode" = loadThenPrompt ]; then
                printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"%s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"fresh-follow-up"}}}}\n' "$session_id"
                printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id"
                continue
              fi
              if [ "$mode" = immediateResponse ]; then
                printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-fixed","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"immediate"}}}}\n'
                printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id"
                continue
              fi
              if [ "$mode" = maxTokens ]; then
                printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-fixed","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"token cap reached"}}}}\n'
                printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"max_tokens"}}\n' "$id"
                continue
              fi
              if [ "$mode" = hangAfterFinal ]; then
                # Stream the full final answer (and a late available_commands_update)
                # then deliberately never return session/prompt — the host must
                # release Working via the turn-inactivity watchdog.
                printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-fixed","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"**COMPLETE** residual note"}}}}\n'
                printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-fixed","update":{"sessionUpdate":"available_commands_update","availableCommands":[]}}}\n'
                prompt_id="$id"
                continue
              fi
              if [ "$mode" = heartbeatThenHangAfterFinal ]; then
                printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-fixed","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"**COMPLETE** residual note"}}}}\n'
                printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-fixed","update":{"sessionUpdate":"tool_call","toolCallId":"tool-hb","title":"working","rawInput":{"command":"echo hb"}}}}\n'
                # Keep emitting tool progress longer than a short inactivity window
                # so absolute-max regressions would fire mid-heartbeat incorrectly.
                i=0
                while [ "$i" -lt 10 ]; do
                  printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-fixed","update":{"sessionUpdate":"tool_call_update","toolCallId":"tool-hb","status":"in_progress","title":"working","content":[{"type":"content","content":{"type":"text","text":"hb %s"}}]}}}\n' "$i"
                  sleep 0.08
                  i=$((i + 1))
                done
                # Close the tool so post-quiet synthesis can be completed (not interrupted).
                printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-fixed","update":{"sessionUpdate":"tool_call_update","toolCallId":"tool-hb","status":"completed","title":"working","content":[{"type":"content","content":{"type":"text","text":"done"}}]}}}\n'
                prompt_id="$id"
                continue
              fi
              if [ "$mode" = hangAfterOpenTool ]; then
                printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-fixed","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"starting long CI"}}}}\n'
                printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-fixed","update":{"sessionUpdate":"tool_call","toolCallId":"tool-open","title":"run_terminal_command","rawInput":{"command":"sleep 999"}}}}\n'
                # Never complete the tool and never resolve session/prompt.
                prompt_id="$id"
                continue
              fi
              if [ "$mode" = plan ] && [ "$current_mode" = plan ]; then
                printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-fixed","update":{"sessionUpdate":"plan","entries":[{"content":"Inspect","status":"completed"},{"content":"Patch","status":"pending"}]}}}\n'
                printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id"
                continue
              fi
              if [ "$mode" = plan ]; then
                printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-fixed","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"implementation resumed"}}}}\n'
                printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id"
                continue
              fi
              printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-fixed","update":{"sessionUpdate":"tool_call","toolCallId":"tool-1","title":"run_terminal_command","rawInput":{"command":"echo hi"}}}}\n'
              printf '{"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"sessionId":"session-fixed","toolCall":{"toolCallId":"tool-1","title":"Run command","rawInput":{"command":"echo hi"}},"options":[{"optionId":"allow-once","name":"Yes","kind":"allow_once"},{"optionId":"reject-once","name":"No","kind":"reject_once"}]}}\n'
              prompt_id="$id"
          elif printf '%s' "$line" | grep -q '"id":0'; then
              printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-fixed","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"done"}}}}\n'
              printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$prompt_id"
          elif printf '%s' "$line" | grep -q '"method":"session.*cancel"'; then
            if [ "$mode" = ignoreCancel ]; then continue; fi
            printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"cancelled"}}\n' "$prompt_id"
          fi
        done
        """#
            .replacingOccurrences(of: "MODE", with: mode.rawValue)
            .replacingOccurrences(of: "PROMPT_COUNT_PATH", with: promptCountPath)
            .replacingOccurrences(of: "COUNT_PATH", with: launchCountPath)
            .replacingOccurrences(of: "SESSION_ID_PATH", with: sessionIdPath)
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        path = script.path
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor GrokACPAsyncSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        guard !signalled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
