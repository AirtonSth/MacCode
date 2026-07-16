import XCTest
@testable import AgentRuntime
import CoreModel

/// Live smoke against the real `grok` binary when present and authenticated.
/// Skips cleanly when the binary or auth is unavailable.
final class GrokRunnerLiveTests: ProviderProcessTestCase {

    func test_realGrokACPDiscoveryPublishesNegotiatedCapabilitiesOnly() async throws {
        guard let path = ProcessLocator.resolve("grok") else {
            throw XCTSkip("grok binary not on PATH; skip native ACP discovery")
        }
        let discovery = await GrokACPAdapter(
            binaryNameOverride: path,
            discoveryCwd: FileManager.default.temporaryDirectory.path,
            modelCacheTTL: 0
        ).discoveryResult()

        XCTAssertFalse(discovery.isFallback, "authenticated ACP discovery must not silently use static models")
        XCTAssertFalse(discovery.models.isEmpty)
        XCTAssertTrue(discovery.permissionModes.contains(.supervised))
        XCTAssertTrue(
            discovery.permissionModes.contains(.fullAccess),
            "live Grok omits modes advertisement but Full access must remain selectable via set_mode"
        )
        XCTAssertEqual(
            discovery.capabilities.supportsPlanReview,
            discovery.interactionModes.contains(.plan),
            "the provider card and /plan gate must derive from the same negotiated session mode state"
        )
    }

    func test_realGrokACPEmbeddedAttachmentAndStreaming() async throws {
        guard let path = ProcessLocator.resolve("grok") else {
            throw XCTSkip("grok binary not on PATH; skip native ACP canary")
        }
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-acp-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        let attachment = cwd.appendingPathComponent("known.txt")
        let nonce = "ACP_FILE_42A7"
        try Data(nonce.utf8).write(to: attachment)

        let adapter = GrokACPAdapter(binaryNameOverride: path)
        defer { adapter.stopAll() }
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .grok,
            model: "grok-4.5",
            cwd: cwd.path,
            prompt: "Read the embedded attachment and reply with exactly its content, nothing else.",
            attachments: [AgentAttachment(path: attachment.path, kind: .file, mimeType: "text/plain")],
            permissionMode: .supervised,
            providerBinary: path
        )
        let box = EventBox()
        do {
            _ = try await adapter.startSession(request) { box.append($0) }
        } catch {
            let text = String(describing: error)
            if text.localizedCaseInsensitiveContains("auth") || text.localizedCaseInsensitiveContains("login") {
                throw XCTSkip("grok present but not authenticated: \(text)")
            }
            throw error
        }
        try await box.waitFinished(timeout: 90)
        let finished = try XCTUnwrap(box.finished, "native Grok ACP canary must finish within 90s")
        if finished.status == .failed {
            let errors = box.errors.joined(separator: "\n")
            if errors.localizedCaseInsensitiveContains("auth") || errors.localizedCaseInsensitiveContains("login") {
                throw XCTSkip("grok present but not authenticated: \(errors)")
            }
            XCTFail("native Grok ACP failed: \(errors)")
            return
        }
        XCTAssertEqual(finished.status, .completed)
        XCTAssertNotNil(finished.providerThreadId)
        XCTAssertTrue((finished.finalMessage ?? box.assistantText).contains(nonce),
                      "real ACP response must depend on embedded attachment bytes")
    }

    func test_realGrokACPToolCallAppearsInTimelineAndChangesWorkspace() async throws {
        guard let path = ProcessLocator.resolve("grok") else {
            throw XCTSkip("grok binary not on PATH; skip native ACP tool canary")
        }
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-acp-tool-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        let output = cwd.appendingPathComponent("tool-proof.txt")
        let nonce = "RC_GROK_ACP_TOOL_42A7"

        let adapter = GrokACPAdapter(binaryNameOverride: path)
        defer { adapter.stopAll() }
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .grok,
            model: "grok-4.5",
            cwd: cwd.path,
            prompt: "Use a shell tool to write exactly \(nonce) into tool-proof.txt, then reply exactly \(nonce).",
            permissionMode: .supervised,
            providerBinary: path
        )
        let box = EventBox()
        do {
            _ = try await adapter.startSession(request) { event in
                box.append(event)
                if case .event(.requestOpened(let pending)) = event {
                    Task {
                        try? await adapter.respondToRequest(
                            threadId: request.threadId,
                            requestId: pending.id,
                            response: .approve
                        )
                    }
                }
            }
        } catch {
            let text = String(describing: error)
            if text.localizedCaseInsensitiveContains("auth") || text.localizedCaseInsensitiveContains("login") {
                throw XCTSkip("grok present but not authenticated: \(text)")
            }
            throw error
        }
        try await box.waitFinished(timeout: 90)
        let finished = try XCTUnwrap(box.finished, "native Grok ACP tool canary must finish within 90s")
        XCTAssertEqual(finished.status, .completed, "real Grok ACP tool turn failed: \(box.errors)")
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), nonce,
                       "the real tool call must produce the requested workspace mutation")
        XCTAssertTrue(box.events.contains { event in
            guard case .event(.itemStarted(let item)) = event else { return false }
            return item.type == .tool || item.type == .commandExecution
        }, "a real Grok ACP tool_call must render as timeline work instead of remaining invisible")
    }

    func test_realGrokACPPlanReviewResumesIntoImplementation() async throws {
        guard let path = ProcessLocator.resolve("grok") else {
            throw XCTSkip("grok binary not on PATH; skip native ACP plan review")
        }
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-acp-plan-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        let output = cwd.appendingPathComponent("plan-proof.txt")
        let nonce = "RC_GROK_PLAN_42A7"
        let threadId = AgentThreadID()
        let adapter = GrokACPAdapter(binaryNameOverride: path)
        defer { adapter.stopAll() }
        let planRequest = AgentRunRequest(
            threadId: threadId,
            provider: .grok,
            model: "grok-4.5",
            cwd: cwd.path,
            prompt: "Propose a short two-step plan to create plan-proof.txt containing \(nonce). Do not execute it yet.",
            permissionMode: .supervised,
            interactionMode: .plan,
            providerBinary: path
        )

        let discovery = await adapter.discoveryResult()
        if !discovery.capabilities.supportsPlanReview {
            XCTAssertFalse(discovery.interactionModes.contains(.plan),
                           "Plan must stay capability-gated when the live ACP session does not advertise modes")
            do {
                _ = try await adapter.startSession(planRequest) { _ in }
                XCTFail("a live ACP session without Plan capability must reject Plan before provider execution")
            } catch let error as AgentProviderAdapterError {
                guard case .unsupported(let message) = error else {
                    return XCTFail("expected an explicit unsupported result, got \(error)")
                }
                XCTAssertTrue(message.contains("did not advertise Plan mode"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                           "an unsupported Plan request must not mutate the workspace")
            return
        }

        let planBox = EventBox()
        do {
            _ = try await adapter.startSession(planRequest) { planBox.append($0) }
        } catch {
            let text = String(describing: error)
            if text.localizedCaseInsensitiveContains("auth") || text.localizedCaseInsensitiveContains("login") {
                throw XCTSkip("grok present but not authenticated: \(text)")
            }
            throw error
        }
        try await planBox.waitFinished(timeout: 90)
        let planned = try XCTUnwrap(planBox.finished, "real Grok Plan turn must finish within 90s")
        XCTAssertEqual(planned.status, .completed, "real Grok Plan failed: \(planBox.errors)")
        XCTAssertTrue(planBox.hasProposedPlan,
                      "the negotiated ACP Plan mode must publish a proposedPlan event for sidebar review")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "Plan mode must not execute the proposed workspace mutation before approval")
        let providerThreadId = try XCTUnwrap(planned.providerThreadId)

        let implementationBox = EventBox()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .grok,
            model: "grok-4.5",
            cwd: cwd.path,
            prompt: "The plan is approved. Implement it now and write exactly \(nonce) to plan-proof.txt.",
            providerThreadId: providerThreadId,
            permissionMode: .supervised,
            interactionMode: .default,
            providerBinary: path
        )) { event in
            implementationBox.append(event)
            if case .event(.requestOpened(let pending)) = event {
                Task {
                    try? await adapter.respondToRequest(
                        threadId: threadId,
                        requestId: pending.id,
                        response: .approve
                    )
                }
            }
        }
        try await implementationBox.waitFinished(timeout: 90)
        let implemented = try XCTUnwrap(implementationBox.finished)
        XCTAssertEqual(implemented.status, .completed, "approved Grok plan implementation failed: \(implementationBox.errors)")
        XCTAssertEqual(implemented.providerThreadId, providerThreadId,
                       "plan review and implementation must retain one provider session")
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), nonce,
                       "approved plan implementation must produce the requested real workspace change")
    }

    func test_realGrokOneShotProducesAssistantTextAndSessionId() async throws {
        guard let path = ProcessLocator.resolve("grok") else {
            throw XCTSkip("grok binary not on PATH; skip real-run")
        }

        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }

        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .grok,
            model: "grok-4.5",
            cwd: cwd.path,
            prompt: "Reply with exactly the single word: pong",
            permissionMode: .fullAccess,
            providerBinary: path
        )

        let runner = GrokRunner(binaryNameOverride: path)
        let box = EventBox()
        let handle = try await runner.startRun(request) { event in
            box.append(event)
        }

        // Wait for process exit (real network call).
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if box.finished != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let finished = try XCTUnwrap(box.finished, "Grok run must finish within 90s")
        if finished.status == .failed {
            let errs = box.errors.joined(separator: "\n")
            if errs.localizedCaseInsensitiveContains("auth")
                || errs.localizedCaseInsensitiveContains("login")
                || errs.localizedCaseInsensitiveContains("not logged") {
                throw XCTSkip("grok present but not authenticated: \(errs)")
            }
            XCTFail("Grok run failed: status=\(finished.status) errors=\(errs)")
            return
        }

        XCTAssertEqual(finished.status, .completed,
                       "successful Grok turn must complete; errors=\(box.errors)")
        let text = (finished.finalMessage ?? box.assistantText).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(text.isEmpty, "assistant transcript must be non-empty for a real Grok turn")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("pong"),
                      "model should follow the short prompt; got: \(text)")
        let sessionId = try XCTUnwrap(finished.providerThreadId,
                                      "sessionId from end event is required for multi-turn resume")
        XCTAssertFalse(sessionId.isEmpty)
        _ = handle
    }

    func test_realGrokCancelStopsWithoutCrashing() async throws {
        guard let path = ProcessLocator.resolve("grok") else {
            throw XCTSkip("grok binary not on PATH; skip cancel path")
        }
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-live-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }

        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .grok,
            model: "grok-4.5",
            cwd: cwd.path,
            prompt: "Write a very long essay of at least 2000 words about clouds. Keep going until done.",
            permissionMode: .fullAccess,
            providerBinary: path
        )
        let runner = GrokRunner(binaryNameOverride: path)
        let box = EventBox()
        let handle = try await runner.startRun(request) { box.append($0) }
        // Let the process actually start, then cancel.
        try await Task.sleep(nanoseconds: 800_000_000)
        handle.cancel()
        try await box.waitFinished(timeout: 30)
        let finished = try XCTUnwrap(box.finished, "cancel must produce a finished event")
        if finished.status == .failed {
            let errors = box.errors.joined(separator: "\n")
            if errors.localizedCaseInsensitiveContains("auth")
                || errors.localizedCaseInsensitiveContains("login") {
                throw XCTSkip("grok present but not authenticated: \(errors)")
            }
        }
        XCTAssertEqual(finished.status, .cancelled,
                       "a real user stop must end as cancelled, not merely any terminal state; errors=\(box.errors)")
    }

    func test_realGrokMultiTurnResumeKeepsSession() async throws {
        guard let path = ProcessLocator.resolve("grok") else {
            throw XCTSkip("grok binary not on PATH; skip real multi-turn")
        }

        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-live-mt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }

        let runner = GrokRunner(binaryNameOverride: path)
        let threadId = AgentThreadID()

        // Turn 1
        let r1 = AgentRunRequest(
            threadId: threadId,
            provider: .grok,
            model: "grok-4.5",
            cwd: cwd.path,
            prompt: "Remember the secret codeword is BANANA. Reply with only: ok",
            permissionMode: .fullAccess,
            providerBinary: path
        )
        let box1 = EventBox()
        _ = try await runner.startRun(r1) { box1.append($0) }
        try await box1.waitFinished(timeout: 90)
        guard let f1 = box1.finished, f1.status == .completed, let session = f1.providerThreadId, !session.isEmpty else {
            let errs = box1.errors.joined(separator: "\n")
            if errs.localizedCaseInsensitiveContains("auth") || errs.localizedCaseInsensitiveContains("login") {
                throw XCTSkip("grok not authenticated: \(errs)")
            }
            XCTFail("real Grok turn 1 must complete with a resumable session; got \(String(describing: box1.finished)) errors=\(errs)")
            return
        }

        // Turn 2 with resume
        let r2 = AgentRunRequest(
            threadId: threadId,
            provider: .grok,
            model: "grok-4.5",
            cwd: cwd.path,
            prompt: "What is the secret codeword? Reply with only the codeword.",
            providerThreadId: session,
            permissionMode: .fullAccess,
            providerBinary: path
        )
        let box2 = EventBox()
        _ = try await runner.startRun(r2) { box2.append($0) }
        try await box2.waitFinished(timeout: 90)
        let f2 = try XCTUnwrap(box2.finished)
        XCTAssertEqual(f2.status, .completed, "resume turn must complete; errors=\(box2.errors)")
        XCTAssertEqual(f2.providerThreadId, session,
                       "follow-up must keep the same provider session identity")
        let text = (f2.finalMessage ?? box2.assistantText).uppercased()
        XCTAssertTrue(text.contains("BANANA"),
                      "resumed session must retain prior-turn context; got: \(f2.finalMessage ?? box2.assistantText)")
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [AgentRunEvent] = []
    private(set) var finished: (status: AgentRunStatus, finalMessage: String?, providerThreadId: String?)?
    private(set) var errors: [String] = []
    private(set) var assistantText = ""

    var hasProposedPlan: Bool {
        lock.withLock {
            events.contains { event in
                if case .event(.proposedPlan) = event { return true }
                return false
            }
        }
    }

    func append(_ event: AgentRunEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
        switch event {
        case .error(let s):
            errors.append(s)
        case .finished(let status, let final, let ptid):
            finished = (status, final, ptid)
        case .event(let ae):
            if case .itemDelta(_, let body, _, _) = ae, let body {
                assistantText += body
            }
        default:
            break
        }
    }

    func waitFinished(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock(); let done = finished != nil; lock.unlock()
            if done { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
