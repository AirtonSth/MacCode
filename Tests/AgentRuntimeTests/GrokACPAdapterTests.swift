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
        XCTAssertTrue(box.assistantText.contains("replayed"))
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

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(peer.launchCount, 2)
        XCTAssertTrue(adapter.hasSession(threadId: threadId))
        XCTAssertEqual(
            adapter.listSessions().first { $0.threadId == threadId }?.providerThreadId,
            "replacement-session"
        )
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

        XCTAssertTrue(replay.assistantText.contains("replayed"),
                      "session/load after process death must restore the prior readable ACP context")
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
        try await Task.sleep(nanoseconds: 50_000_000)

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

        XCTAssertTrue(recovered.assistantText.contains("replayed"),
                      "recovery must load the saved ACP identity into a fresh process")
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
        // Live Grok 0.2.x session/new often omits modes.availableModes while still
        // accepting session/set_mode for default / acceptEdits / bypassPermissions.
        let peer = try FakeGrokACPPeer(mode: .discovery)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)

        let discovery = await adapter.discoveryResult()

        XCTAssertFalse(discovery.isFallback)
        XCTAssertEqual(discovery.permissionModes, AgentPermissionMode.allCases,
                       "omitted mode advertisement must not lock Full access out of the picker")
        XCTAssertTrue(discovery.permissionModes.contains(.fullAccess))
        XCTAssertEqual(discovery.interactionModes, [.default],
                       "Plan stays fail-closed until ACP advertises a plan mode id")
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

    func test_planFailsBeforePromptWhenSessionDoesNotAdvertisePlanMode() async throws {
        let peer = try FakeGrokACPPeer(mode: .permission)
        defer { peer.remove() }
        let adapter = GrokACPAdapter(binaryNameOverride: peer.path)
        let request = makeRequest(interactionMode: .plan)

        do {
            _ = try await adapter.startSession(request) { _ in }
            XCTFail("Grok must not claim Plan support when ACP omitted the mode")
        } catch let error as AgentProviderAdapterError {
            guard case .unsupported(let detail) = error else {
                return XCTFail("Expected unsupported, got \(error)")
            }
            XCTAssertTrue(detail.contains("Plan"))
        }

        XCTAssertFalse(adapter.hasSession(threadId: request.threadId),
                       "a prompt-start failure must remove the stopped Grok session so retry cannot reuse a zombie client")

        let retry = GrokACPEventBox()
        _ = try await adapter.startSession(makeRequest(
            threadId: request.threadId,
            interactionMode: .default
        )) { retry.append($0) }
        let pending = try await retry.waitForRequest(timeout: 3)
        try await adapter.respondToRequest(
            threadId: request.threadId,
            requestId: pending.id,
            response: .approve
        )
        let finished = try await retry.waitFinished(timeout: 3)
        XCTAssertEqual(finished.status, .completed,
                       "retry after a rejected Plan start must create a fresh usable Grok session")
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
}

private enum GrokACPTestWaitError: Error {
    case timedOut(String)
}

private final class GrokACPEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentRunEvent] = []
    var errors: [String] { lock.withLock { events.compactMap { if case .error(let text) = $0 { return text }; return nil } } }
    var assistantText: String { lock.withLock { events.compactMap { if case .event(.itemDelta(_, let body, _, _)) = $0 { return body }; return nil }.joined() } }
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
        case permission, cancel, ignoreCancel, crash, load, discovery, plan
        case auth, rateLimit, network, invalidResume, invalidJSON
    }
    let root: URL
    let path: String
    let launchCountPath: String

    var launchCount: Int {
        ((try? String(contentsOfFile: launchCountPath, encoding: .utf8)) ?? "").count
    }

    init(mode: Mode) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fake-grok-acp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("grok")
        launchCountPath = root.appendingPathComponent("launch-count").path
        let body = #"""
        #!/bin/sh
        mode="MODE"
        current_mode="default"
        printf x >> "COUNT_PATH"
        while IFS= read -r line; do
          if printf '%s' "$line" | grep -q '"method":"initialize"'; then
              id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
              printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":false,"audio":false,"embeddedContext":true},"sessionCapabilities":{}},"_meta":{"agentVersion":"0.2.101"}}}\n' "$id"
          elif printf '%s' "$line" | grep -q '"method":"session.*new"'; then
              id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
              if [ "$mode" = plan ]; then
                printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"session-fixed","models":{"currentModelId":"account-live-model","availableModels":[{"modelId":"account-live-model","name":"Live"}]},"modes":{"currentModeId":"default","availableModes":[{"id":"default","name":"Default"},{"id":"plan","name":"Plan"}]}}}\n' "$id"
              else
                printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"session-fixed","models":{"currentModelId":"account-live-model","availableModels":[{"modelId":"account-live-model","name":"Live"}]}}}\n' "$id"
              fi
          elif printf '%s' "$line" | grep -q '"method":"session.*load"'; then
              id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
              loaded_session=$(printf '%s' "$line" | sed -E 's/.*"sessionId":"([^"]+)".*/\1/')
              if [ "$mode" = invalidResume ]; then
                printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"session not found: invalid resume"}}\n' "$id"
                continue
              fi
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
              id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
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
            .replacingOccurrences(of: "COUNT_PATH", with: launchCountPath)
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        path = script.path
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
