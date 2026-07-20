import XCTest
@testable import AgentRuntime
import CoreModel

final class GrokACPProtocolTests: XCTestCase {
    func test_initializeAdvertisesOnlyImplementedClientCapabilities() {
        let params = GrokACPClient.initializeParams(clientVersion: "test")
        XCTAssertEqual(params["protocolVersion"] as? Int, 1)
        let capabilities = params["clientCapabilities"] as? [String: Any]
        XCTAssertNotNil(capabilities)
        XCTAssertNil(capabilities?["terminal"], "terminal must stay unadvertised until every inbound terminal method exists")
        XCTAssertNil(capabilities?["fs"], "filesystem must stay unadvertised until read/write requests are implemented")
    }

    func test_imageCompatibilityOverridesFalseAdvertisementOnlyOnVerifiedVersions() {
        XCTAssertTrue(GrokACPImageCompatibility.effectiveImageEnabled(advertised: true, agentVersion: nil))
        XCTAssertTrue(GrokACPImageCompatibility.effectiveImageEnabled(advertised: false, agentVersion: "0.2.103"),
                      "0.2.x is verified to accept type=image blocks despite image=false")
        XCTAssertTrue(GrokACPImageCompatibility.effectiveImageEnabled(advertised: false, agentVersion: "0.2.101"))
        XCTAssertFalse(GrokACPImageCompatibility.effectiveImageEnabled(advertised: false, agentVersion: nil),
                       "unknown agent version must fail closed when image is not advertised")
        XCTAssertFalse(GrokACPImageCompatibility.effectiveImageEnabled(advertised: false, agentVersion: "0.3.0"),
                       "unverified major/minor must not inherit the 0.2.x override")
    }

    func test_initializeParsesReal02101Capabilities() throws {
        let fixture: [String: Any] = [
            "protocolVersion": 1,
            "agentCapabilities": [
                "loadSession": true,
                "promptCapabilities": ["image": false, "audio": false, "embeddedContext": true],
                "sessionCapabilities": [:]
            ],
            "_meta": [
                "agentVersion": "0.2.101",
                "modelState": [
                    "currentModelId": "grok-4.5",
                    "availableModels": [["modelId": "grok-4.5", "name": "Grok 4.5"]]
                ]
            ]
        ]
        let result = try GrokACPInitializeResult.parse(fixture)
        XCTAssertEqual(result.protocolVersion, 1)
        XCTAssertTrue(result.loadSession)
        XCTAssertTrue(result.embeddedContext)
        XCTAssertFalse(result.image)
        XCTAssertFalse(result.audio)
        XCTAssertFalse(result.resumeSession, "binary strings do not override absent negotiated capability")
        XCTAssertEqual(result.agentVersion, "0.2.101")
        XCTAssertEqual(result.currentModelId, "grok-4.5")
        XCTAssertEqual(result.models.map(\.id), ["grok-4.5"])
    }

    func test_failureTaxonomyMapsOnlyExplicitRecoveryClassesAndSanitizesDiagnostics() {
        let auth = GrokACPFailureTaxonomy.normalize(
            GrokACPError.rpcError(
                code: 401,
                message: "Unauthorized access_token=fake-secret-value at /Users/example/.grok/config"
            ),
            context: .turn
        )
        XCTAssertEqual(auth.category, .authRequired)
        XCTAssertTrue(auth.message.hasPrefix(GrokACPFailureTaxonomy.authRequiredMarker))
        XCTAssertFalse(auth.message.contains("fake-secret-value"),
                       "provider credentials must never enter the persisted run error")
        XCTAssertFalse(auth.message.contains("/Users/example"),
                       "host paths must be redacted before the diagnostic reaches macOS or iOS")

        let rateLimit = GrokACPFailureTaxonomy.normalize(
            GrokACPError.rpcError(code: 429, message: "Too many requests"),
            context: .turn
        )
        XCTAssertEqual(rateLimit.category, .rateLimited)
        XCTAssertTrue(rateLimit.message.hasPrefix(GrokACPFailureTaxonomy.rateLimitedMarker))

        let network = GrokACPFailureTaxonomy.normalize(
            GrokACPError.rpcError(code: nil, message: "network connection reset"),
            context: .turn
        )
        XCTAssertEqual(network.category, .network)
        XCTAssertTrue(network.message.hasPrefix(GrokACPFailureTaxonomy.networkMarker))

        let processNetwork = GrokACPFailureTaxonomy.normalize(
            GrokACPError.processExited(
                reason: .exit,
                status: 1,
                stderrTail: "connection refused while reading /Users/example/.grok/state"
            ),
            context: .turn
        )
        XCTAssertEqual(processNetwork.category, .network,
                       "process stderr must feed the same taxonomy as ACP RPC errors")
        XCTAssertFalse(processNetwork.message.contains("/Users/example"))

        let timeout = GrokACPFailureTaxonomy.normalize(
            GrokACPError.requestTimedOut("session/prompt"),
            context: .turn
        )
        XCTAssertEqual(timeout.category, .timeout)
        XCTAssertTrue(timeout.message.hasPrefix(GrokACPFailureTaxonomy.timeoutMarker))

        let invalidResume = GrokACPFailureTaxonomy.normalize(
            GrokACPError.rpcError(code: -32_000, message: "session not found: invalid resume"),
            context: .resume
        )
        XCTAssertEqual(invalidResume.category, .invalidResume)
        XCTAssertTrue(invalidResume.message.hasPrefix(GrokACPFailureTaxonomy.invalidResumeMarker))
        XCTAssertTrue(invalidResume.message.localizedCaseInsensitiveContains("invalid resume"),
                      "the shared UI classifier consumes the canonical invalid-resume phrase")

        let malformed = GrokACPFailureTaxonomy.normalize(
            GrokACPError.invalidJSON("not-json"),
            context: .turn
        )
        XCTAssertEqual(malformed.category, .nonRecoverable)
        XCTAssertFalse(malformed.message.contains("[retryable:"),
                       "malformed provider output has no proven retry contract")
        XCTAssertFalse(malformed.message.contains("[start-fresh:"),
                       "a generic protocol failure must not discard resumable context")
        XCTAssertFalse(malformed.message.contains(GrokACPFailureTaxonomy.authRequiredMarker))
    }

    func test_notificationAfterProcessExitThrowsTypedErrorInsteadOfWritingClosedStdin() async throws {
        // WHY: Grok can terminate between ACP messages. A later notification
        // must fail as processExited without SIGPIPE or an indefinite wait.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-acp-closed-stdin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("grok")
        try #"""
        #!/usr/bin/env python3
        import json, sys

        request = json.loads(sys.stdin.readline())
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": {"protocolVersion": 1, "agentCapabilities": {}}}), flush=True)
        sys.exit(0)
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let terminated = expectation(description: "Grok ACP terminated")
        let client = try GrokACPClient(binary: script.path, cwd: root.path, tagProcess: false)
        client.terminationHandler = { _, _, _ in terminated.fulfill() }
        defer { client.stop() }

        _ = try await client.initialize(clientVersion: "test")
        await fulfillment(of: [terminated], timeout: 3)

        XCTAssertThrowsError(try client.notify(method: "session/cancel", params: ["sessionId": "dead"])) { error in
            guard case GrokACPError.processExited = error else {
                return XCTFail("expected typed processExited, got \(error)")
            }
        }
    }

    func test_sessionOpenParsesOnlyAdvertisedACPModeIds() throws {
        let result = try GrokACPClient.openResult([
            "sessionId": "session-with-modes",
            "modes": [
                "currentModeId": "default",
                "availableModes": [
                    ["id": "default", "name": "Default"],
                    ["id": "plan", "name": "Plan"],
                    ["id": "", "name": "Invalid"]
                ]
            ]
        ], fallbackSessionId: nil)

        XCTAssertEqual(result.currentModeId, "default")
        XCTAssertEqual(result.availableModes.map(\.id), ["default", "plan"])
        XCTAssertEqual(result.availableModes.map(\.name), ["Default", "Plan"])
    }

    func test_promptEmbedsFileBytesAndImageBytesEvenWhenImageCapabilityFalse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("note.txt")
        try Data("known-sha-input".utf8).write(to: note)
        let request = AgentRunRequest(
            threadId: AgentThreadID(), provider: .grok, model: "grok-4.5", cwd: root.path,
            prompt: "Return the attached content",
            attachments: [AgentAttachment(path: note.path, kind: .file, mimeType: "text/plain")]
        )
        let blocks = try GrokACPClient.promptBlocks(
            for: request,
            capabilities: .init(protocolVersion: 1, loadSession: true, embeddedContext: true)
        )
        XCTAssertEqual(blocks.first?["type"] as? String, "text")
        let resource = try XCTUnwrap(blocks.last?["resource"] as? [String: Any])
        XCTAssertEqual(resource["text"] as? String, "known-sha-input")
        XCTAssertEqual(resource["mimeType"] as? String, "text/plain")

        // Live Grok 0.2.x advertises image=false but accepts type=image blocks.
        // RemoteCode must still embed camera/photos so iOS attach is not a dead end.
        let imagePath = root.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imagePath)
        let imageRequest = AgentRunRequest(
            threadId: AgentThreadID(), provider: .grok, model: "grok-4.5", cwd: root.path,
            prompt: "inspect", attachments: [AgentAttachment(path: imagePath.path, kind: .image, mimeType: "image/png")]
        )
        let imageBlocks = try GrokACPClient.promptBlocks(
            for: imageRequest,
            capabilities: .init(
                protocolVersion: 1,
                loadSession: true,
                embeddedContext: true,
                image: false,
                agentVersion: "0.2.103"
            )
        )
        let imageBlock = try XCTUnwrap(imageBlocks.last)
        XCTAssertEqual(imageBlock["type"] as? String, "image",
                       "image attachments must embed on verified 0.2.x even when image=false")
        XCTAssertEqual(imageBlock["mimeType"] as? String, "image/png")
        XCTAssertFalse((imageBlock["data"] as? String ?? "").isEmpty)

        XCTAssertThrowsError(try GrokACPClient.promptBlocks(
            for: imageRequest,
            capabilities: .init(
                protocolVersion: 1,
                loadSession: true,
                embeddedContext: true,
                image: false,
                agentVersion: "0.3.0"
            )
        ), "unverified agent versions must still reject images when advertisement is false")
    }

    func test_promptBlocksInjectTokenSaverSafetyABIExactlyOnceForGrokACP() throws {
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .grok,
            model: "grok-4.5",
            cwd: "/tmp",
            prompt: "inspect",
            environment: ["RC_TOKEN_SAVER_DISTILL_HINT": "1"]
        )
        let blocks = try GrokACPClient.promptBlocks(
            for: request,
            capabilities: .init(protocolVersion: 1, loadSession: true, embeddedContext: true)
        )
        let prompt = try XCTUnwrap(blocks.first?["text"] as? String)
        XCTAssertEqual(prompt.components(separatedBy: TokenSaverProviderSafetyABI.block).count - 1, 1)
        XCTAssertEqual(
            (AgentSkillInstaller.distillAgentInstructionsTemplate + "\n\n" + prompt)
                .components(separatedBy: TokenSaverProviderSafetyABI.block).count - 1,
            1,
            "Grok ACP effective disk plus runtime context receives the safety ABI exactly once"
        )

        let disabledRequest = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .grok,
            model: "grok-4.5",
            cwd: "/tmp",
            prompt: "inspect"
        )
        let disabledBlocks = try GrokACPClient.promptBlocks(
            for: disabledRequest,
            capabilities: .init(protocolVersion: 1, loadSession: true, embeddedContext: true)
        )
        let disabledPrompt = try XCTUnwrap(disabledBlocks.first?["text"] as? String)
        XCTAssertFalse(disabledPrompt.contains(TokenSaverProviderSafetyABI.block))
    }

    func test_mapperStreamsThoughtTextToolsPlanAndKeepsLastTextPhaseFinal() {
        let mapper = GrokACPEventMapper(sessionId: "grok-session")
        var events: [AssistantEvent] = []
        events += mapper.consumeSessionUpdate(["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "think"]])
        events += mapper.consumeSessionUpdate(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "preface"]])
        events += mapper.consumeSessionUpdate(["sessionUpdate": "tool_call", "toolCallId": "tool-1", "title": "read_file", "rawInput": ["path": "a.txt"]])
        events += mapper.consumeSessionUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "tool-1", "status": "completed", "content": [["type": "content", "content": ["type": "text", "text": "ok"]]]])
        events += mapper.consumeSessionUpdate(["sessionUpdate": "plan", "entries": [["content": "Inspect", "status": "completed"], ["content": "Patch", "status": "pending"]]])
        events += mapper.consumeSessionUpdate(["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "again"]])
        events += mapper.consumeSessionUpdate(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "final answer"]])
        events += mapper.finishTurn(stopReason: "end_turn", usage: nil)

        // Default/full-access turns: ACP plan entries are live progress, not Approve gates.
        XCTAssertTrue(events.contains {
            if case .activePlanUpdated(let plan) = $0 {
                return plan.steps.map(\.title) == ["Inspect", "Patch"]
                    && plan.steps.map(\.status) == [.completed, .pending]
            }
            return false
        }, "Grok plan session updates must map to active plan progress")
        XCTAssertFalse(events.contains { if case .proposedPlan = $0 { return true }; return false },
                       "live plan progress must not become proposedPlan (full access would auto-queue Implement)")
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.id == "tool-1" && item.type == .tool }; return false })
        XCTAssertTrue(events.contains { if case .itemCompleted("tool-1", .completed) = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .turnCompleted(_, let final) = $0 { return final == "final answer" }; return false },
                      "AG-057: only the last assistant text phase is the final answer")
    }

    func test_mapperPlanModeEmitsReviewableProposedPlanAndActiveProgress() {
        let mapper = GrokACPEventMapper(sessionId: "grok-plan-mode")
        mapper.setPlanReviewModeId("plan")
        mapper.setCurrentModeId("plan")
        let events = mapper.consumeSessionUpdate([
            "sessionUpdate": "plan",
            "entries": [
                ["content": "Inspect", "status": "completed"],
                ["content": "Patch", "status": "pending"]
            ]
        ])
        XCTAssertTrue(events.contains {
            if case .activePlanUpdated(let plan) = $0 {
                return plan.steps.count == 2 && plan.steps[1].status == .pending
            }
            return false
        }, "Plan mode still surfaces active step progress")
        XCTAssertTrue(events.contains {
            if case .proposedPlan(let plan) = $0 {
                return plan.markdown.contains("Inspect") && plan.markdown.contains("Patch")
            }
            return false
        }, "Plan interaction mode must still publish a reviewable proposed plan")
    }

    func test_mapperNegotiatedPlanModeIdEmitsProposedPlan() {
        let mapper = GrokACPEventMapper(sessionId: "grok-plan-alias")
        mapper.setPlanReviewModeId("architect")
        mapper.setCurrentModeId("architect")
        let events = mapper.consumeSessionUpdate([
            "sessionUpdate": "plan",
            "entries": [["content": "Step A", "status": "pending"]]
        ])
        XCTAssertTrue(events.contains { if case .proposedPlan = $0 { return true }; return false },
                      "negotiated Plan mode id must mint a reviewable proposed plan")
    }

    func test_mapperFullAccessPermissionModeDoesNotEmitProposedPlan() {
        let mapper = GrokACPEventMapper(sessionId: "grok-bypass")
        // Wire permission mode id — must not be confused with Plan interaction mode.
        mapper.setCurrentModeId("bypassPermissions")
        let events = mapper.consumeSessionUpdate([
            "sessionUpdate": "plan",
            "entries": [["content": "Already implementing", "status": "in_progress"]]
        ])
        XCTAssertTrue(events.contains { if case .activePlanUpdated = $0 { return true }; return false })
        XCTAssertFalse(events.contains { if case .proposedPlan = $0 { return true }; return false },
                       "full-access permission mode must not mint proposedPlan from live plan progress")
    }

    /// WHY: double finish (prompt complete + process exit) used to call ensureTurn
    /// after turnId was cleared, minting a second turnStarted that collided with
    /// durable seq 1 (often pre-turn servers_updated) once the coordinator cleared seq.
    func test_mapperFinishTurnIsIdempotentAndDoesNotReopenTurnStarted() {
        let mapper = GrokACPEventMapper(sessionId: "grok-finish-once")
        let started = mapper.beginTurn()
        XCTAssertEqual(started.filter { if case .turnStarted = $0 { return true }; return false }.count, 1)
        let firstFinish = mapper.finishTurn(stopReason: "end_turn", usage: nil)
        XCTAssertEqual(firstFinish.filter { if case .turnCompleted = $0 { return true }; return false }.count, 1)
        let secondFinish = mapper.finishTurn(stopReason: "end_turn", usage: nil)
        XCTAssertTrue(secondFinish.isEmpty,
                      "second finishTurn must be a no-op")
        XCTAssertFalse(secondFinish.contains { if case .turnStarted = $0 { return true }; return false },
                       "second finish must not mint a new turnStarted")
    }

    func test_mapperIgnoresSessionUpdatesAfterFinishWithoutNewTurnStarted() {
        let mapper = GrokACPEventMapper(sessionId: "grok-late-update")
        _ = mapper.beginTurn()
        _ = mapper.finishTurn(stopReason: "end_turn", usage: nil)
        let late = mapper.consumeSessionUpdate([
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": "late"]
        ])
        XCTAssertFalse(late.contains { if case .turnStarted = $0 { return true }; return false },
                       "post-finish session updates must not reopen a turn")
        XCTAssertFalse(late.contains { if case .itemDelta = $0 { return true }; return false },
                       "post-finish content chunks must be dropped until the next beginTurn")
    }

    func test_mapperTracksCommandsModeModelsAndUsage() {
        let mapper = GrokACPEventMapper(sessionId: "s")
        _ = mapper.consumeSessionUpdate(["sessionUpdate": "available_commands_update", "availableCommands": [["name": "compact", "description": "Compress"]]])
        _ = mapper.consumeSessionUpdate(["sessionUpdate": "current_mode_update", "currentModeId": "plan"])
        _ = mapper.consumeSessionUpdate(["sessionUpdate": "usage_update", "usage": ["inputTokens": 10, "outputTokens": 2, "totalTokens": 12]])
        XCTAssertEqual(mapper.availableCommands.map(\.name), ["compact"])
        XCTAssertEqual(mapper.currentModeId, "plan")
        XCTAssertEqual(mapper.latestUsage?.totalTokens, 12)
    }

    func test_loadReplayEventIdsAreDeduplicated() {
        let mapper = GrokACPEventMapper(sessionId: "s")
        let update: [String: Any] = [
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": "once"],
            "_meta": ["isReplay": true, "eventId": "replay-1"]
        ]
        let events = mapper.consumeSessionUpdate(update) + mapper.consumeSessionUpdate(update)
        let text = events.compactMap { if case .itemDelta(_, let body, _, _) = $0 { return body }; return nil }.joined()
        XCTAssertEqual(text, "once")
    }

    func test_permissionRequestPreservesExactOptionIds() throws {
        let parsed = try GrokACPPermissionRequest.parse(id: .int(0), params: [
            "sessionId": "s",
            "toolCall": ["toolCallId": "t", "title": "Run command", "rawInput": ["command": "echo hi"]],
            "options": [
                ["optionId": "allow-once", "name": "Yes", "kind": "allow_once"],
                ["optionId": "reject-once", "name": "No", "kind": "reject_once"]
            ]
        ])
        XCTAssertEqual(parsed.requestId.jsonValue as? Int, 0, "request ids are direction-local and zero is valid")
        XCTAssertEqual(parsed.toolCallId, "t")
        XCTAssertEqual(parsed.options.map(\.optionId), ["allow-once", "reject-once"])
        XCTAssertEqual(parsed.optionId(for: .approve), "allow-once")
        XCTAssertNil(parsed.optionId(for: .approveForSession),
                     "Approve Session must never degrade to a one-shot allow while claiming broader scope")
        XCTAssertEqual(parsed.optionId(for: .decline(nil)), "reject-once")
    }

    func test_terminalClassificationDistinguishesCrashFromUserCancel() {
        XCTAssertEqual(GrokACPTerminalClassifier.status(promptResolved: false, cancelRequested: false, forcedKillByUs: false, terminationReason: .uncaughtSignal, exitStatus: 6), .failed)
        XCTAssertEqual(GrokACPTerminalClassifier.status(promptResolved: false, cancelRequested: true, forcedKillByUs: true, terminationReason: .uncaughtSignal, exitStatus: 15), .cancelled)
        XCTAssertEqual(GrokACPTerminalClassifier.status(promptResolved: true, cancelRequested: true, forcedKillByUs: false, terminationReason: .exit, exitStatus: 0), .completed)
    }
}
