import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

final class GrokACPProtocolTests: XCTestCase {
    func test_launchArgumentsAreExactlyNoLeaderStdioWithNoDuplication() {
        // WHY: Grok 0.2.112 shared-leader mode dies (exit 143) looking for
        // client_id. Every ACP launch must use isolated agent stdio only.
        let args = GrokACPClient.launchArguments
        XCTAssertEqual(args, ["agent", "--no-leader", "stdio"])
        XCTAssertEqual(Set(args).count, args.count, "ACP argv must not duplicate flags or subcommands")
        XCTAssertFalse(args.contains("client_id"))
        XCTAssertEqual(args.filter { $0 == "--no-leader" }.count, 1)
        XCTAssertEqual(args.filter { $0 == "stdio" }.count, 1)
        XCTAssertEqual(args.filter { $0 == "agent" }.count, 1)
        // initialize params stay free of client_id — auth is CLI-side.
        let params = GrokACPClient.initializeParams(clientVersion: "test")
        XCTAssertNil(params["client_id"])
        XCTAssertNil((params["clientInfo"] as? [String: Any])?["client_id"])
    }

    func test_spawnedProcessUsesExactLaunchArgumentsSeam() throws {
        // WHY: the static seam only helps if GrokACPClient.init wires it through.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-acp-argv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("grok")
        try #"""
        #!/bin/sh
        # Consume stdin until closed; mirror nothing.
        cat >/dev/null
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let client = try GrokACPClient(binary: script.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        XCTAssertEqual(client.runningProcess.arguments, GrokACPClient.launchArguments)
        XCTAssertEqual(client.runningProcess.arguments, ["agent", "--no-leader", "stdio"])
    }

    func test_productionGrokLaunchForwardsRequestedRunAsIdentity() throws {
        // WHY: persisting runAsUser on the thread is not enough; the production
        // adapter and client must forward it into the universal process launcher.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let adapter = try String(
            contentsOf: root.appendingPathComponent("Sources/AgentRuntime/GrokACPAdapter.swift"),
            encoding: .utf8
        )
        let client = try String(
            contentsOf: root.appendingPathComponent("Sources/AgentRuntime/GrokACPClient.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(adapter.contains("runAsUser: request.runAsUser"))
        XCTAssertTrue(client.contains("runAsUser: runAsUser"))
        XCTAssertTrue(client.contains("foreignUserLaunch: foreignUserUID != nil"))
        XCTAssertTrue(client.contains("foreignUserUID: foreignUserUID"))
    }

    func test_samGrokWorkerProfileLaunchArgumentsPreserveSupportedRawGuard() throws {
        // WHY: promoting the raw worker into ACP must not weaken its security
        // contract. In particular, ACP acceptEdits does not replace Grok's
        // provider-side --always-approve behavior for non-edit tools.
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .grok,
            model: "grok-4.5",
            cwd: "/tmp",
            prompt: "inspect",
            permissionMode: .autoAcceptEdits,
            reasoningEffort: .high,
            environment: [
                AgentAppRuntimeProfile.environmentKey:
                    AgentAppRuntimeProfile.samGrokWorkerV1.rawValue
            ]
        )

        XCTAssertEqual(
            try GrokACPClient.launchArguments(for: request),
            [
                "--no-memory",
                "--no-subagents",
                "--disallowed-tools", "Agent",
                "--no-auto-update",
                "--sandbox", "workspace",
                "agent",
                "--model", "grok-4.5",
                "--reasoning-effort", "high",
                "--always-approve",
                "--no-leader",
                "stdio"
            ]
        )
    }

    func test_samGrokWorkerProfileRejectsUnadvertisedMaxEffort() {
        let request = AgentRunRequest(
            threadId: AgentThreadID(), provider: .grok, model: "grok-4.5",
            cwd: "/tmp", prompt: "inspect", permissionMode: .autoAcceptEdits,
            reasoningEffort: .max,
            environment: [AgentAppRuntimeProfile.environmentKey: AgentAppRuntimeProfile.samGrokWorkerV1.rawValue]
        )
        XCTAssertThrowsError(try GrokACPClient.launchArguments(for: request))
    }

    func test_samGrokWorkerProfileAdmitsGrok46AndXhighEffort() throws {
        // WHY: orchestration LIGHT/STANDARD/DEEP prefer grok-4.6, which
        // advertises xhigh. Exact grok-4.5 + grok45-only effort guards fail
        // closed before ACP starts (GROK-ACP-009).
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .grok,
            model: "grok-4.6",
            cwd: "/tmp",
            prompt: "inspect",
            permissionMode: .autoAcceptEdits,
            reasoningEffort: .xhigh,
            environment: [
                AgentAppRuntimeProfile.environmentKey:
                    AgentAppRuntimeProfile.samGrokWorkerV1.rawValue
            ]
        )
        XCTAssertTrue(GrokACPClient.admitsSamGrokWorker(model: "grok-4.6", effort: .xhigh))
        XCTAssertTrue(GrokACPClient.admitsSamGrokWorker(model: "grok-4.6-preview", effort: .xhigh))
        XCTAssertTrue(GrokACPClient.admitsSamGrokWorker(model: "grok-4.5", effort: .high))
        XCTAssertFalse(GrokACPClient.admitsSamGrokWorker(model: "grok-4.5", effort: .xhigh))
        XCTAssertFalse(GrokACPClient.admitsSamGrokWorker(model: "grok-4.6", effort: .max))
        XCTAssertEqual(
            try GrokACPClient.launchArguments(for: request),
            [
                "--no-memory",
                "--no-subagents",
                "--disallowed-tools", "Agent",
                "--no-auto-update",
                "--sandbox", "workspace",
                "agent",
                "--model", "grok-4.6",
                "--reasoning-effort", "xhigh",
                "--always-approve",
                "--no-leader",
                "stdio"
            ]
        )
    }

    func test_samGrokWorkerProfileRejectsGrok45XhighAndGrok46Max() {
        // WHY: router used to allow xhigh/max while the client only accepted
        // grok-4.5 efforts. Both sites now share supportedEfforts.
        let fourFiveXhigh = AgentRunRequest(
            threadId: AgentThreadID(), provider: .grok, model: "grok-4.5",
            cwd: "/tmp", prompt: "inspect", permissionMode: .autoAcceptEdits,
            reasoningEffort: .xhigh,
            environment: [AgentAppRuntimeProfile.environmentKey: AgentAppRuntimeProfile.samGrokWorkerV1.rawValue]
        )
        let fourSixMax = AgentRunRequest(
            threadId: AgentThreadID(), provider: .grok, model: "grok-4.6",
            cwd: "/tmp", prompt: "inspect", permissionMode: .autoAcceptEdits,
            reasoningEffort: .max,
            environment: [AgentAppRuntimeProfile.environmentKey: AgentAppRuntimeProfile.samGrokWorkerV1.rawValue]
        )
        XCTAssertThrowsError(try GrokACPClient.launchArguments(for: fourFiveXhigh))
        XCTAssertThrowsError(try GrokACPClient.launchArguments(for: fourSixMax))
    }

    func test_samGrokWorkerRouterGuardUsesSharedAdmissionPredicate() throws {
        // WHY: AppCommandRouter must not keep a second allow-list that admits
        // xhigh on grok-4.5 while launchArguments rejects it.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let router = try String(
            contentsOf: root.appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            router.contains("GrokACPClient.admitsSamGrokWorker(model: m, effort: t.reasoningEffort)"),
            "Router must reuse the client admission predicate"
        )
        XCTAssertFalse(
            router.contains("m == \"grok-4.5\""),
            "Router must not pin sam-grok-worker to exact grok-4.5"
        )
    }

    func test_samGrokWorkerProfileFailsClosedForProviderSessionResume() {
        // WHY: the promoted raw contract is a fresh one-shot execution. It
        // cannot silently inherit a previous provider session's state.
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .grok,
            model: "grok-4.5",
            cwd: "/tmp",
            prompt: "inspect",
            providerThreadId: "existing-provider-session",
            permissionMode: .autoAcceptEdits,
            reasoningEffort: .high,
            environment: [
                AgentAppRuntimeProfile.environmentKey:
                    AgentAppRuntimeProfile.samGrokWorkerV1.rawValue
            ]
        )

        XCTAssertThrowsError(try GrokACPClient.launchArguments(for: request))
    }

    func test_regularACPLaunchIncludesModelAndReasoningEffort() throws {
        // WHY: Agent App Grok picker model + effort must reach AgentArgs under
        // `agent` (GROK-ACP-008). Flags before `agent` bind top-level PagerArgs
        // and are discarded by run_agent_command (live: effort stays default).
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .grok,
            model: "grok-4.5",
            cwd: "/tmp",
            prompt: "hello",
            permissionMode: .fullAccess,
            reasoningEffort: .high
        )

        XCTAssertEqual(
            try GrokACPClient.launchArguments(for: request),
            [
                "agent",
                "--model", "grok-4.5",
                "--reasoning-effort", "high",
                "--no-leader",
                "stdio"
            ]
        )
        let argv = try GrokACPClient.launchArguments(for: request)
        let agentIdx = try XCTUnwrap(argv.firstIndex(of: "agent"))
        let modelIdx = try XCTUnwrap(argv.firstIndex(of: "--model"))
        let effortIdx = try XCTUnwrap(argv.firstIndex(of: "--reasoning-effort"))
        XCTAssertLessThan(agentIdx, modelIdx, "AgentArgs flags must follow `agent`")
        XCTAssertLessThan(agentIdx, effortIdx, "AgentArgs flags must follow `agent`")
    }

    func test_regularACPLaunchEmptyModelOmitsModelFlagAndMatchesEffortSemantics() throws {
        // WHY: empty model means account default (Grok 4.6). Do not emit --model;
        // still emit --reasoning-effort when effort is set, matching
        // GrokRunner.modelSupportsReasoningEffort("") == true.
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .grok,
            model: "  ",
            cwd: "/tmp",
            prompt: "hello",
            permissionMode: .fullAccess,
            reasoningEffort: .medium
        )

        XCTAssertTrue(GrokRunner.modelSupportsReasoningEffort(""))
        XCTAssertEqual(
            try GrokACPClient.launchArguments(for: request),
            [
                "agent",
                "--reasoning-effort", "medium",
                "--no-leader",
                "stdio"
            ]
        )
    }

    func test_regularACPLaunchComposerFastOmitsReasoningEffort() throws {
        // WHY: composer-fast rejects/ignores effort; omit --reasoning-effort so
        // the CLI does not fail or silently ignore a misleading flag.
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .grok,
            model: "grok-composer-2.5-fast",
            cwd: "/tmp",
            prompt: "hello",
            permissionMode: .fullAccess,
            reasoningEffort: .high
        )

        XCTAssertFalse(GrokRunner.modelSupportsReasoningEffort("grok-composer-2.5-fast"))
        XCTAssertEqual(
            try GrokACPClient.launchArguments(for: request),
            [
                "agent",
                "--model", "grok-composer-2.5-fast",
                "--no-leader",
                "stdio"
            ]
        )
    }

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
        XCTAssertTrue(GrokACPImageCompatibility.effectiveImageEnabled(advertised: false, agentVersion: "1.0.0"),
                      "1.0.x live canary accepts type=image despite image=false")
        XCTAssertTrue(GrokACPImageCompatibility.effectiveImageEnabled(advertised: false, agentVersion: "1.0.1"))
        XCTAssertFalse(GrokACPImageCompatibility.effectiveImageEnabled(advertised: false, agentVersion: nil),
                       "unknown agent version must fail closed when image is not advertised")
        XCTAssertFalse(GrokACPImageCompatibility.effectiveImageEnabled(advertised: false, agentVersion: "0.3.0"),
                       "unverified major/minor must not inherit the verified-family override")
        XCTAssertFalse(GrokACPImageCompatibility.effectiveImageEnabled(advertised: false, agentVersion: ""),
                       "empty agent version must fail closed")
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

        let payment = GrokACPFailureTaxonomy.normalize(
            GrokACPError.rpcError(code: 402, message: "Payment Required: balance exhausted"),
            context: .turn
        )
        XCTAssertEqual(payment.category, .nonRecoverable,
                       "Grok Build balance exhaustion must not be retried as auth or rate limit")

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

    func test_sessionBootstrapDoesNotRegisterReadFileOutputRewrite() {
        // WHY: ACP session/new only passes cwd + mcpServers. There is no hook
        // channel that can replace native read_file bytes before Grok's model
        // sees them. PostToolUse remains passive (stdout ignored).
        let servers = GrokACPClient.sessionMCPServers()
        let encoded = (try? JSONSerialization.data(withJSONObject: servers))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(encoded.contains("updatedToolOutput"))
        XCTAssertFalse(encoded.contains("post-tool-use"))
        let initParams = GrokACPClient.initializeParams(clientVersion: "test")
        XCTAssertNil(initParams["hooks"])
        XCTAssertFalse(
            (try? JSONSerialization.data(withJSONObject: initParams))
                .flatMap { String(data: $0, encoding: .utf8) }?
                .contains("PostToolUse") ?? false
        )
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

        // Token Saver off → no Distill / safety ABI on Grok ACP.
        let emptyEnvRequest = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .grok,
            model: "grok-4.5",
            cwd: "/tmp",
            prompt: "inspect"
        )
        let emptyEnvBlocks = try GrokACPClient.promptBlocks(
            for: emptyEnvRequest,
            capabilities: .init(protocolVersion: 1, loadSession: true, embeddedContext: true)
        )
        let emptyEnvPrompt = try XCTUnwrap(emptyEnvBlocks.first?["text"] as? String)
        XCTAssertFalse(emptyEnvPrompt.contains(TokenSaverProviderSafetyABI.block))
        XCTAssertFalse(emptyEnvPrompt.contains("| distill"))
    }

    func test_promptBlocksInjectBackgroundAwaitDirectiveNotClaudeMCP() throws {
        // WHY: Grok never received systemPromptDirective, so the deterministic
        // [[RC_AWAITING]] self-declare path was dead. Inject only that directive —
        // not Claude-only MCP rules.
        let turnContext = "REMOTE CODE RESOLVED IDENTITY ONLY: @quinn is Quinn"
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .grok,
            model: "grok-4.5",
            cwd: "/tmp",
            prompt: "inspect",
            environment: [BotPeerDelegation.turnContextEnvironmentKey: turnContext]
        )
        let blocks = try GrokACPClient.promptBlocks(
            for: request,
            capabilities: .init(protocolVersion: 1, loadSession: true, embeddedContext: true)
        )
        let prompt = try XCTUnwrap(blocks.first?["text"] as? String)
        XCTAssertTrue(
            prompt.contains(BackgroundAwaitContinuation.awaitingMarker),
            "Grok prompt blocks must include the exact [[RC_AWAITING]] token"
        )
        XCTAssertTrue(
            prompt.contains("Background-await protocol"),
            "Grok must receive systemPromptDirective"
        )
        XCTAssertTrue(
            prompt.contains(BotPeerDelegation.providerDirective),
            "Grok must receive the AI-authored Bot delegation contract"
        )
        XCTAssertTrue(
            prompt.contains(turnContext),
            "Grok must receive this turn's identity-only Bot context"
        )
        XCTAssertFalse(
            prompt.contains(BackgroundAwaitContinuation.mcpToolAvailabilityDirective),
            "must not inject Claude-only mcpToolAvailabilityDirective"
        )
        XCTAssertFalse(
            prompt.contains(BackgroundAwaitContinuation.mcpConnectWaitDirective),
            "must not inject Claude-only mcpConnectWaitDirective"
        )
        XCTAssertFalse(
            prompt.contains("RefreshMcpTools"),
            "Claude-only MCP connect-wait wording must not appear on Grok"
        )
    }

    func test_mapperShellDetachedToolCall_stampsAwaitingMarkerExactlyOnceOnCompletedTurn() {
        let mapper = GrokACPEventMapper(sessionId: "grok-detach")
        var events: [AssistantEvent] = []
        events += mapper.beginTurn()
        let detachCmd = "grok --prompt-file /tmp/w2-c02.txt --output-format json > /tmp/w2-c02-result.json 2>&1 &\nPID_C02=$!\necho started"
        events += mapper.consumeSessionUpdate([
            "sessionUpdate": "tool_call",
            "toolCallId": "tool-detach",
            "title": "run_terminal_command",
            "rawInput": ["command": detachCmd]
        ])
        events += mapper.consumeSessionUpdate([
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": "Workers launched"]
        ])
        events += mapper.finishTurn(stopReason: "end_turn", usage: nil)

        let marker = BackgroundAwaitContinuation.awaitingMarker
        let turnFinals = events.compactMap { event -> String? in
            if case .turnCompleted(_, let msg) = event { return msg }
            return nil
        }
        XCTAssertEqual(turnFinals.count, 1)
        let final = try! XCTUnwrap(turnFinals.first)
        XCTAssertTrue(final.contains(marker),
                      "turnCompleted must carry [[RC_AWAITING]]; got \(final)")
        XCTAssertEqual(final.components(separatedBy: marker).count - 1, 1,
                       "marker must appear exactly once")
        XCTAssertEqual(mapper.finalAssistantMessage, final,
                       "adapter .finished reads finalAssistantMessage — same stamped text")
        XCTAssertTrue(final.contains("Workers launched"))
    }

    /// WHY: max_tokens is completed-class — detached shell must still stamp
    /// [[RC_AWAITING]] so the host can poll background work after a length cap.
    func test_mapperShellDetachedToolCall_maxTokens_stampsAwaitingMarker() {
        let mapper = GrokACPEventMapper(sessionId: "grok-detach-max-tokens")
        var events: [AssistantEvent] = []
        events += mapper.beginTurn()
        let detachCmd = "nohup sleep 99 > /tmp/bg.log 2>&1 &\necho started"
        events += mapper.consumeSessionUpdate([
            "sessionUpdate": "tool_call",
            "toolCallId": "tool-detach-mt",
            "title": "run_terminal_command",
            "rawInput": ["command": detachCmd]
        ])
        events += mapper.consumeSessionUpdate([
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": "capped after detach"]
        ])
        events += mapper.finishTurn(stopReason: "max_tokens", usage: nil)

        let marker = BackgroundAwaitContinuation.awaitingMarker
        let final = events.compactMap { event -> String? in
            if case .turnCompleted(_, let msg) = event { return msg }
            return nil
        }.first
        let stamped = try! XCTUnwrap(final)
        XCTAssertTrue(stamped.contains(marker),
                      "max_tokens + detached shell must stamp [[RC_AWAITING]]; got \(stamped)")
        XCTAssertEqual(mapper.finalAssistantMessage, stamped)
        XCTAssertTrue(stamped.contains("capped after detach"))
    }

    func test_mapperNonDetachingAndFailedTerminals_doNotStampAwaitingMarker() {
        let marker = BackgroundAwaitContinuation.awaitingMarker

        // Non-detaching command → no stamp.
        do {
            let mapper = GrokACPEventMapper(sessionId: "grok-nodetach")
            var events: [AssistantEvent] = []
            events += mapper.beginTurn()
            events += mapper.consumeSessionUpdate([
                "sessionUpdate": "tool_call",
                "toolCallId": "tool-build",
                "title": "run_terminal_command",
                "rawInput": ["command": "swift build && echo ok"]
            ])
            events += mapper.consumeSessionUpdate([
                "sessionUpdate": "agent_message_chunk",
                "content": ["type": "text", "text": "build ok"]
            ])
            events += mapper.finishTurn(stopReason: "end_turn", usage: nil)
            let final = events.compactMap { event -> String? in
                if case .turnCompleted(_, let msg) = event { return msg }
                return nil
            }.first
            XCTAssertEqual(final, "build ok")
            XCTAssertFalse(final?.contains(marker) == true)
            XCTAssertEqual(mapper.finalAssistantMessage, "build ok")
        }

        // Failed terminal with detaching command → no stamp.
        do {
            let mapper = GrokACPEventMapper(sessionId: "grok-fail-detach")
            var events: [AssistantEvent] = []
            events += mapper.beginTurn()
            events += mapper.consumeSessionUpdate([
                "sessionUpdate": "tool_call",
                "toolCallId": "tool-d",
                "title": "run_terminal_command",
                "rawInput": ["command": "nohup sleep 99 &"]
            ])
            events += mapper.consumeSessionUpdate([
                "sessionUpdate": "agent_message_chunk",
                "content": ["type": "text", "text": "oops"]
            ])
            events += mapper.finishTurn(stopReason: "failed", usage: nil)
            let final = events.compactMap { event -> String? in
                if case .turnCompleted(_, let msg) = event { return msg }
                return nil
            }.first
            XCTAssertEqual(final, "oops")
            XCTAssertFalse(final?.contains(marker) == true)
        }

        // Cancelled terminal with detaching command → no stamp.
        do {
            let mapper = GrokACPEventMapper(sessionId: "grok-cancel-detach")
            var events: [AssistantEvent] = []
            events += mapper.beginTurn()
            events += mapper.consumeSessionUpdate([
                "sessionUpdate": "tool_call",
                "toolCallId": "tool-c",
                "title": "run_terminal_command",
                "rawInput": ["command": "sleep 30 &"]
            ])
            events += mapper.consumeSessionUpdate([
                "sessionUpdate": "agent_message_chunk",
                "content": ["type": "text", "text": "cancelling"]
            ])
            events += mapper.finishTurn(stopReason: "cancelled", usage: nil)
            let final = events.compactMap { event -> String? in
                if case .turnCompleted(_, let msg) = event { return msg }
                return nil
            }.first
            XCTAssertEqual(final, "cancelling")
            XCTAssertFalse(final?.contains(marker) == true)
        }
    }

    func test_mapperRewrapsPlainACPSubagentLifecycleForSubagentsSurface() {
        // WHY: orchestrated Grok workers must reach ProviderNativeSubagentLifecycle
        // even when the wire uses plain ACP sessionUpdate kinds instead of the
        // live `x.ai/session_notification` envelope (user rule: orchestrated
        // agents always appear as subagents under the controller).
        let childID = "019FB003-077E-7391-9013-BE1849DF3941"
        let mapper = GrokACPEventMapper(sessionId: "grok-parent")
        let events = mapper.consumeSessionUpdate([
            "sessionUpdate": "subagent_spawned",
            "subagent_id": childID.lowercased(),
            "child_session_id": childID.lowercased(),
            "description": "explore payments",
        ])
        guard case .providerRuntime(let runtime)? = events.last else {
            return XCTFail("subagent_spawned must emit a providerRuntime event")
        }
        XCTAssertEqual(runtime.method, "x.ai/session_notification")
        XCTAssertTrue(
            ProviderNativeSubagentLifecycle.isPotentialLifecycleEvent(events.last!),
            "re-wrapped event must be on the Subagents lifecycle hot path"
        )
        let updates = ProviderNativeSubagentLifecycle.updates(
            from: events.last!,
            parentProvider: .grok
        )
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.phase, .active)
        XCTAssertEqual(
            updates.first?.childRunId.value.uuidString.lowercased(),
            childID.lowercased()
        )
    }

    func test_legacyUnderscoreSessionNotificationStillReachesLifecycle() {
        // WHY: persisted replay / older fixtures may still emit `_x.ai/*`.
        let childID = "019FB003-077E-7391-9013-BE1849DF3941"
        let payload: [String: Any] = [
            "sessionId": "grok-parent",
            "update": [
                "sessionUpdate": "subagent_finished",
                "subagent_id": childID.lowercased(),
                "child_session_id": childID.lowercased(),
                "status": "completed",
            ] as [String: Any],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let event = AssistantEvent.providerRuntime(ProviderRuntimeEvent(
            provider: .grok,
            source: "grok.acp",
            method: "_x.ai/session_notification",
            payloadJSON: String(decoding: data, as: UTF8.self),
            receivedAtMs: 1
        ))
        XCTAssertTrue(ProviderNativeSubagentLifecycle.isPotentialLifecycleEvent(event))
        XCTAssertEqual(
            ProviderNativeSubagentLifecycle.updates(from: event, parentProvider: .grok).first?.phase,
            .completed
        )
    }

    /// WHY: live grok-build emit_subagent_notification uses `x.ai/session_notification`.
    /// Adapter must forward both live and legacy prefixes (GROK-ACP-005).
    func test_adapterAcceptsLiveAndLegacyGrokExtNotificationPrefixes() throws {
        let root = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let adapter = try String(
            contentsOf: root.appendingPathComponent("Sources/AgentRuntime/GrokACPAdapter.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            adapter.contains("hasPrefix(\"x.ai/\")") && adapter.contains("hasPrefix(\"_x.ai/\")"),
            "handleNotification must treat live x.ai/* and legacy _x.ai/* as runtime events"
        )
        XCTAssertTrue(
            adapter.contains("unwrapGrokExtNotification"),
            "adapter should unwrap leader nested {method,params} ext envelopes"
        )
        let lifecycle = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/AgentRuntime/ProviderNativeSubagentLifecycle.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            lifecycle.contains("\"x.ai/session_notification\"")
                && lifecycle.contains("\"_x.ai/session_notification\""),
            "lifecycle must accept live and legacy session_notification methods"
        )
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

    /// GROK-ACP-005: if session/prompt ends while a tool_call never got a terminal
    /// tool_call_update, finishTurn must still emit itemCompleted so tool rows
    /// do not remain streaming forever on the Agent App timeline.
    func test_finishTurn_sealsOpenToolCalls_byStopReason() {
        func run(stopReason: String, expected: AssistantItemState, file: StaticString = #filePath, line: UInt = #line) {
            let mapper = GrokACPEventMapper(sessionId: "grok-open-tool-\(stopReason)")
            var events: [AssistantEvent] = []
            events += mapper.beginTurn()
            events += mapper.consumeSessionUpdate([
                "sessionUpdate": "tool_call",
                "toolCallId": "tool-open-\(stopReason)",
                "title": "run_terminal_command",
                "rawInput": ["command": "sleep 999"]
            ])
            XCTAssertTrue(mapper.hasOpenToolCalls, "tool_call without update must stay open", file: file, line: line)
            events += mapper.finishTurn(stopReason: stopReason, usage: nil)

            let completions = events.compactMap { event -> AssistantItemState? in
                if case .itemCompleted(let id, let state) = event, id == "tool-open-\(stopReason)" {
                    return state
                }
                return nil
            }
            XCTAssertEqual(completions, [expected],
                           "finishTurn(\(stopReason)) must seal open tool as \(expected); got \(completions)",
                           file: file, line: line)
            XCTAssertFalse(mapper.hasOpenToolCalls,
                           "openToolCallIds must clear after finishTurn",
                           file: file, line: line)
            // Tool completion must precede turnCompleted so the timeline is terminal before the turn ends.
            let toolDone = events.firstIndex {
                if case .itemCompleted(let id, _) = $0 { return id == "tool-open-\(stopReason)" }
                return false
            }
            let turnDone = events.firstIndex {
                if case .turnCompleted = $0 { return true }
                return false
            }
            XCTAssertNotNil(toolDone)
            XCTAssertNotNil(turnDone)
            if let toolDone, let turnDone {
                XCTAssertLessThan(toolDone, turnDone,
                                  "open tools must complete before turnCompleted",
                                  file: file, line: line)
            }
        }

        run(stopReason: "end_turn", expected: .completed)
        run(stopReason: "max_tokens", expected: .completed)
        run(stopReason: "cancelled", expected: .cancelled)
        run(stopReason: "failed", expected: .failed)
    }

    /// Tools that already received a terminal update must not get a second seal.
    func test_finishTurn_doesNotDoubleCompleteAlreadyTerminalTools() {
        let mapper = GrokACPEventMapper(sessionId: "grok-tool-already-done")
        var events: [AssistantEvent] = []
        events += mapper.beginTurn()
        events += mapper.consumeSessionUpdate([
            "sessionUpdate": "tool_call",
            "toolCallId": "tool-done",
            "title": "read_file",
            "rawInput": ["path": "a.txt"]
        ])
        events += mapper.consumeSessionUpdate([
            "sessionUpdate": "tool_call_update",
            "toolCallId": "tool-done",
            "status": "completed",
            "content": [["type": "content", "content": ["type": "text", "text": "ok"]]]
        ])
        XCTAssertFalse(mapper.hasOpenToolCalls)
        events += mapper.finishTurn(stopReason: "end_turn", usage: nil)
        let toolCompletions = events.filter {
            if case .itemCompleted("tool-done", _) = $0 { return true }
            return false
        }
        XCTAssertEqual(toolCompletions.count, 1,
                       "already-terminal tools must not receive a second itemCompleted on finishTurn")
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

    /// Live Grok 1.0 session/prompt `_meta.usage` includes `costUsdTicks`
    /// (1 USD = 10^10 ticks). finishTurn must map them into reportedCostMicros
    /// so Agent App spend / Token Saver rings match the CLI parser path.
    func test_finishTurn_mapsCostUsdTicksToReportedCostMicros() {
        let mapper = GrokACPEventMapper(sessionId: "grok-cost-ticks")
        var events: [AssistantEvent] = []
        events += mapper.beginTurn()
        // 1 USD = 10^10 ticks; micros = USD * 1e6 → micros = ticks / 1e4.
        // 50_000_000 ticks → 5_000 micros.
        events += mapper.finishTurn(
            stopReason: "end_turn",
            usage: [
                "inputTokens": 100,
                "outputTokens": 20,
                "totalTokens": 120,
                "costUsdTicks": 50_000_000
            ]
        )
        let costs = events.compactMap { event -> Int? in
            if case .tokenUsage(let usage) = event { return usage.reportedCostMicros }
            return nil
        }
        XCTAssertEqual(costs, [5_000],
                       "costUsdTicks 50_000_000 must become reportedCostMicros 5000 (ticks/1e4)")
        XCTAssertEqual(mapper.latestUsage?.reportedCostMicros, 5_000)
        XCTAssertEqual(mapper.latestUsage?.totalTokens, 120)
    }

    /// Live incident: last agent_message_chunk phase was `Repos` + `8` + `<|eos|>`
    /// and became the only visible final answer. Control tokens must never reach
    /// turnCompleted.finalMessage or itemDelta bodies.
    func test_mapperStripsLeakedControlTokensFromFinalAndDeltas() {
        let mapper = GrokACPEventMapper(sessionId: "grok-eos-leak")
        var events: [AssistantEvent] = []
        events += mapper.beginTurn()
        events += mapper.consumeSessionUpdate([
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": "Repos"]
        ])
        events += mapper.consumeSessionUpdate([
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": "8"]
        ])
        events += mapper.consumeSessionUpdate([
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": "<|eos|>"]
        ])
        events += mapper.finishTurn(stopReason: "end_turn", usage: nil)

        let deltaBodies = events.compactMap { ev -> String? in
            if case .itemDelta(_, let body, _, _) = ev { return body }
            return nil
        }
        XCTAssertFalse(deltaBodies.contains { $0.contains("<|") || $0.contains("|>") },
                       "streamed itemDelta must never carry control tokens")
        XCTAssertEqual(deltaBodies.joined(), "Repos8")
        XCTAssertTrue(events.contains {
            if case .turnCompleted(_, let final) = $0 { return final == "Repos8" }
            return false
        }, "final must strip <|eos|> while keeping residual prose")
        XCTAssertEqual(mapper.finalAssistantMessage, "Repos8")
    }

    func test_mapperPureEosPhaseYieldsNilFinalMessage() {
        let mapper = GrokACPEventMapper(sessionId: "grok-eos-only")
        var events: [AssistantEvent] = []
        events += mapper.beginTurn()
        events += mapper.consumeSessionUpdate([
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": "<|eos|>"]
        ])
        events += mapper.finishTurn(stopReason: "end_turn", usage: nil)

        XCTAssertTrue(events.contains {
            if case .turnCompleted(_, let final) = $0 { return final == nil }
            return false
        }, "token-only final phase must not invent a visible answer")
        XCTAssertNil(mapper.finalAssistantMessage)
        XCTAssertFalse(events.contains {
            if case .itemDelta(_, let body, _, _) = $0 { return body?.isEmpty == false }
            return false
        }, "token-only chunks must not open a non-empty assistant delta")
    }

    /// After tools, a pure `<|eos|>` tail must fall back to the pre-tool phase
    /// so finishTurn does not wipe a turn that already spoke.
    func test_mapperFallsBackToPreToolPhaseWhenTrailingPhaseIsOnlyEos() {
        let mapper = GrokACPEventMapper(sessionId: "grok-eos-fallback")
        var events: [AssistantEvent] = []
        events += mapper.beginTurn()
        events += mapper.consumeSessionUpdate([
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": "preface answer"]
        ])
        events += mapper.consumeSessionUpdate([
            "sessionUpdate": "tool_call",
            "toolCallId": "t1",
            "title": "read_file",
            "rawInput": ["path": "a.txt"]
        ])
        events += mapper.consumeSessionUpdate([
            "sessionUpdate": "tool_call_update",
            "toolCallId": "t1",
            "status": "completed"
        ])
        events += mapper.consumeSessionUpdate([
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": "<|eos|>"]
        ])
        events += mapper.finishTurn(stopReason: "end_turn", usage: nil)

        XCTAssertTrue(events.contains {
            if case .turnCompleted(_, let final) = $0 { return final == "preface answer" }
            return false
        }, "empty trailing phase after control-token strip must fall back to last real phase")
        XCTAssertEqual(mapper.finalAssistantMessage, "preface answer")
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

    func test_eventIDDedupeEvictsOnlyBeyondRecentWindowAndResetsOnReopen() {
        let mapper = GrokACPEventMapper(
            sessionId: "s",
            eventIDDedupeLimit: 3,
            eventIDDedupePruneSlack: 2
        )
        func update(_ id: Int) -> [String: Any] {
            [
                "sessionUpdate": "config_option_update",
                "value": id,
                "_meta": ["eventId": "event-\(id)"]
            ]
        }

        for id in 0..<3 {
            XCTAssertFalse(mapper.consumeSessionUpdate(update(id)).isEmpty)
        }
        XCTAssertEqual(mapper.retainedEventIDCountForTesting, 3)
        XCTAssertTrue(mapper.consumeSessionUpdate(update(0)).isEmpty,
                      "an ID inside the exact recent window must dedupe")

        XCTAssertFalse(mapper.consumeSessionUpdate(update(3)).isEmpty)
        XCTAssertEqual(mapper.retainedEventIDCountForTesting, 3,
                       "inserting a new ID must evict the oldest logical member")
        XCTAssertTrue(mapper.consumeSessionUpdate(update(2)).isEmpty,
                      "a recent retained ID must still dedupe after pruning")
        XCTAssertFalse(mapper.consumeSessionUpdate(update(0)).isEmpty,
                       "an evicted old ID may be accepted without unbounded retention")
        XCTAssertEqual(mapper.bufferedEventIDCountForTesting, 5,
                       "physical ID storage may use bounded slack before compaction")
        XCTAssertFalse(mapper.consumeSessionUpdate(update(4)).isEmpty)
        XCTAssertEqual(mapper.bufferedEventIDCountForTesting, 3,
                       "crossing slack must compact the discarded FIFO prefix")

        let reopened = GrokACPEventMapper(
            sessionId: "s",
            eventIDDedupeLimit: 3,
            eventIDDedupePruneSlack: 2
        )
        XCTAssertFalse(reopened.consumeSessionUpdate(update(2)).isEmpty,
                       "a new ACP mapper/reopen must not inherit stale in-memory dedupe state")
    }

    func test_sealHydrationClearsReplayTurnSoBeginTurnMintsFreshUserTurn() {
        // WHY: session/load replay used to leave turnId set; beginTurn no-oped
        // and follow-up prompts inherited prior tool_call steps.
        let mapper = GrokACPEventMapper(sessionId: "s-load")
        let replay = mapper.consumeSessionUpdate([
            "sessionUpdate": "tool_call",
            "toolCallId": "old-tool-1",
            "title": "prior work",
            "rawInput": ["command": "echo old"],
            "_meta": ["isReplay": true, "eventId": "replay-tool-1"]
        ])
        XCTAssertTrue(replay.contains { if case .turnStarted = $0 { return true }; return false })
        XCTAssertTrue(replay.contains {
            if case .itemStarted(let item) = $0 { return item.id == "old-tool-1" }
            return false
        })

        mapper.sealHydration()

        let next = mapper.beginTurn()
        XCTAssertEqual(next.filter { if case .turnStarted = $0 { return true }; return false }.count, 1,
                       "after sealHydration, beginTurn must mint a new user-facing turn")
        let live = mapper.consumeSessionUpdate([
            "sessionUpdate": "tool_call",
            "toolCallId": "new-tool-1",
            "title": "fresh work",
            "rawInput": ["command": "echo new"]
        ])
        XCTAssertTrue(live.contains {
            if case .itemStarted(let item) = $0 {
                return item.id == "new-tool-1" && item.turnId != ""
            }
            return false
        })
        XCTAssertFalse(live.contains {
            if case .itemStarted(let item) = $0 { return item.id == "old-tool-1" }
            return false
        }, "prior load tools must not reappear on the sealed follow-up turn")
    }

    func test_sealHydrationStillAppliesModeAndCommandsWithoutReopeningTurn() {
        let mapper = GrokACPEventMapper(sessionId: "s-state")
        mapper.sealHydration()
        let events = mapper.consumeSessionUpdate([
            "sessionUpdate": "available_commands_update",
            "availableCommands": [["name": "compact", "description": "Compress"]]
        ]) + mapper.consumeSessionUpdate([
            "sessionUpdate": "current_mode_update",
            "currentModeId": "acceptEdits"
        ])
        XCTAssertEqual(mapper.availableCommands.map(\.name), ["compact"])
        XCTAssertEqual(mapper.currentModeId, "acceptEdits")
        XCTAssertFalse(events.contains { if case .turnStarted = $0 { return true }; return false },
                       "post-seal state updates must not mint a turn")
        XCTAssertFalse(events.contains { if case .itemStarted = $0 { return true }; return false })
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

    /// WHY: max_tokens / max_turn_requests / refusal are successful ACP terminals
    /// (wire tokens from grok-build stop_reason_wire). Misclassifying them as
    /// .failed surfaces false error events and blocks awaiting-marker stamps.
    func test_stopReasonClassifierMatrix_completedClassAndUnknown() {
        let completed = ["end_turn", "max_tokens", "max_turn_requests", "refusal"]
        for reason in completed {
            XCTAssertEqual(
                GrokACPTerminalClassifier.status(stopReason: reason),
                .completed,
                "\(reason) must complete the turn"
            )
            XCTAssertTrue(
                GrokACPTerminalClassifier.isCompletedStopReason(reason),
                "\(reason) is completed-class"
            )
        }
        XCTAssertEqual(GrokACPTerminalClassifier.status(stopReason: "cancelled"), .cancelled)
        XCTAssertFalse(GrokACPTerminalClassifier.isCompletedStopReason("cancelled"))
        XCTAssertEqual(GrokACPTerminalClassifier.status(stopReason: "failed"), .failed)
        XCTAssertEqual(GrokACPTerminalClassifier.status(stopReason: "unknown_wire"), .failed)
        XCTAssertFalse(GrokACPTerminalClassifier.isCompletedStopReason("failed"))
        XCTAssertFalse(GrokACPTerminalClassifier.isCompletedStopReason("unknown_wire"))
    }

    /// WHY: Foundation JSONSerialization escapes `/` as `\/` by default; grok-build
    /// documents `session\/prompt` as a historical ACP method-parse hazard.
    /// Outbound ACP lines must use `.withoutEscapingSlashes`.
    func test_outboundACPJSONDoesNotEscapeMethodSlashes() throws {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "session/prompt",
            "params": ["sessionId": "s1"]
        ]
        let escaped = try JSONSerialization.data(withJSONObject: payload)
        let canonical = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.withoutEscapingSlashes]
        )
        let escapedText = String(decoding: escaped, as: UTF8.self)
        let canonicalText = String(decoding: canonical, as: UTF8.self)
        // Foundation default: method appears as session\/prompt (backslash + slash bytes).
        XCTAssertTrue(
            escapedText.contains("session\\/prompt"),
            "sanity: Foundation default escapes slashes: \(escapedText)"
        )
        XCTAssertTrue(canonicalText.contains("\"method\":\"session/prompt\"")
                        || canonicalText.contains("session/prompt"),
                      "canonical form keeps unescaped method path: \(canonicalText)")
        XCTAssertFalse(
            canonicalText.contains("session\\/prompt"),
            "canonical ACP method must not be slash-escaped: \(canonicalText)"
        )
        // GrokACPClient.write must use the same options as `canonical`.
        // Guard the source seam so a future rewrite that drops the option fails CI.
        // #file → …/Tests/AgentRuntimeTests/GrokACPProtocolTests.swift → package root
        let packageRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let clientSourceURL = packageRoot.appendingPathComponent("Sources/AgentRuntime/GrokACPClient.swift")
        let clientSource = try String(contentsOf: clientSourceURL, encoding: .utf8)
        XCTAssertTrue(
            clientSource.contains("withoutEscapingSlashes"),
            "GrokACPClient.write must serialize with .withoutEscapingSlashes"
        )
    }

    /// WHY: UI/thread reasoning effort is ignored unless ACP set_model carries
    /// `_meta.reasoningEffort` (grok-build REASONING_EFFORT_META_KEY).
    func test_setModelParamsIncludeReasoningEffortMeta() throws {
        // Reconstruct the params shape GrokACPClient.setModel must emit.
        let effort = AgentReasoningEffort.high
        var params: [String: Any] = ["sessionId": "sid", "modelId": "grok-4.5"]
        params["_meta"] = ["reasoningEffort": GrokACPClient.wireReasoningEffort(effort)]
        XCTAssertEqual((params["_meta"] as? [String: Any])?["reasoningEffort"] as? String, "high")
        let root = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/AgentRuntime/GrokACPClient.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("reasoningEffort"), "setModel must accept reasoningEffort")
        XCTAssertTrue(
            source.contains("_meta") && source.contains("reasoningEffort"),
            "setModel must send _meta.reasoningEffort"
        )
        XCTAssertTrue(
            source.contains("wireReasoningEffort"),
            "setModel must map effort via wireReasoningEffort before the wire call"
        )
        let adapter = try String(
            contentsOf: root.appendingPathComponent("Sources/AgentRuntime/GrokACPAdapter.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            adapter.contains("modelEffortBind"),
            "Adapter must re-bind effort when it changes even if model id is unchanged"
        )
        XCTAssertFalse(
            adapter.contains("setConfigOptionReasoningEffort") || adapter.contains("session.client.setConfigOption"),
            "Live grok 1.0.13 rejects session/set_config_option with Invalid params; effort-only must use set_model"
        )
    }

    /// WHY: ACP and CLI must send only values advertised by the effective
    /// account-default model (Grok 4.6), never stale shared-picker aliases.
    /// Live grok 1.0.13 grok-4.6 ads omit `minimal`; static fallback matches.
    func test_wireReasoningEffortNormalizesForDefaultGrok46() {
        XCTAssertEqual(GrokACPClient.wireReasoningEffort(.ultracode), "xhigh")
        XCTAssertEqual(GrokACPClient.wireReasoningEffort(.minimal), "low",
                       "Grok 4.6 live catalog omits minimal; remap to low")
        XCTAssertEqual(GrokACPClient.wireReasoningEffort(.low), "low")
        XCTAssertEqual(GrokACPClient.wireReasoningEffort(.medium), "medium")
        XCTAssertEqual(GrokACPClient.wireReasoningEffort(.high), "high")
        XCTAssertEqual(GrokACPClient.wireReasoningEffort(.xhigh), "xhigh")
        XCTAssertEqual(GrokACPClient.wireReasoningEffort(.max), "xhigh")
        // grok-4.5 still remaps minimal → low (catalog omits minimal).
        XCTAssertEqual(GrokACPClient.wireReasoningEffort(.minimal, modelId: "grok-4.5"), "low")
    }

    /// WHY: Live grok-4.6 lists efforts as xhigh→…→low with default:true on high.
    /// Schedulers use `.first`; preserving agent order would seed Extra High.
    func test_modelDescriptorsPrefersDefaultAndStableOrder() {
        let models = GrokACPClient.modelDescriptors(from: [
            "availableModels": [[
                "modelId": "grok-4.6",
                "name": "Grok 4.6",
                "_meta": [
                    "supportsReasoningEffort": true,
                    "reasoningEffort": "xhigh",
                    "reasoningEfforts": [
                        ["id": "xhigh", "value": "xhigh", "default": false],
                        ["id": "high", "value": "high", "default": true],
                        ["id": "medium", "value": "medium", "default": false],
                        ["id": "low", "value": "low", "default": false],
                    ],
                ],
            ] as [String: Any]],
        ])
        let model = try! XCTUnwrap(models.first)
        XCTAssertEqual(model.supportedReasoningEfforts.first, .high)
        XCTAssertEqual(model.supportedReasoningEfforts, [.high, .low, .medium, .xhigh])
        XCTAssertEqual(
            GrokACPClient.seededReasoningEffort(models: models, currentModelId: "grok-4.6"),
            .high
        )
    }

    /// WHY: Image #1 Agent App Grok send died at start with
    /// `Grok ACP RPC error: Invalid params`. New threads always carry a
    /// composer effort (default medium) while `Session.reasoningEffort` is
    /// nil, so the first prompt is an effort-only bind. Live grok 1.0.13
    /// rejects `session/set_config_option` (`-32602` nested `{value:{value:}}`,
    /// `-32601` ACP string value) and accepts `session/set_model` +
    /// `_meta.reasoningEffort` for the same model id.
    func test_modelEffortBindRoutesEffortOnlyToSetModelNotSetConfigOption() {
        let firstTurn = GrokACPClient.modelEffortBind(
            requestModel: "grok-4.6",
            sessionModel: "grok-4.6",
            requestEffort: .medium,
            sessionEffort: nil
        )
        guard case let .setModel(firstModel, firstEffort) = firstTurn else {
            return XCTFail("first-turn effort bind must use set_model, got \(firstTurn)")
        }
        XCTAssertEqual(firstModel, "grok-4.6")
        XCTAssertEqual(firstEffort, .medium)

        let effortOnly = GrokACPClient.modelEffortBind(
            requestModel: "grok-4.6",
            sessionModel: "grok-4.6",
            requestEffort: .high,
            sessionEffort: .low
        )
        guard case let .setModel(modelId, reasoningEffort) = effortOnly else {
            return XCTFail("effort-only must use set_model, got \(effortOnly)")
        }
        XCTAssertEqual(modelId, "grok-4.6")
        XCTAssertEqual(reasoningEffort, .high)
        XCTAssertEqual(
            GrokACPClient.wireReasoningEffort(.high, modelId: modelId),
            "high"
        )

        let modelChange = GrokACPClient.modelEffortBind(
            requestModel: "grok-4.5",
            sessionModel: "grok-4.6",
            requestEffort: .medium,
            sessionEffort: .high
        )
        guard case let .setModel(changedModel, changedEffort) = modelChange else {
            return XCTFail("model change must use set_model, got \(modelChange)")
        }
        XCTAssertEqual(changedModel, "grok-4.5")
        XCTAssertEqual(changedEffort, .medium)

        let noop = GrokACPClient.modelEffortBind(
            requestModel: "grok-4.6",
            sessionModel: "grok-4.6",
            requestEffort: .high,
            sessionEffort: .high
        )
        XCTAssertEqual(noop, .none)
    }

    /// WHY: session/new|load advertise typed configOptions; ignoring them leaves
    /// the host blind to agent-selectable efforts (GROK-ACP-013).
    func test_openResultParsesConfigOptions() throws {
        let result: [String: Any] = [
            "sessionId": "sid-1",
            "models": [
                "currentModelId": "grok-4.6",
                "availableModels": [
                    ["modelId": "grok-4.6", "name": "Grok 4.6", "_meta": ["supportsReasoningEffort": true]],
                ],
            ] as [String: Any],
            "modes": [
                "currentModeId": "default",
                "availableModes": [["id": "default", "name": "Default"]],
            ] as [String: Any],
            "configOptions": [
                [
                    "id": "reasoning_effort",
                    "category": "thought_level",
                    "options": [
                        ["value": "minimal", "name": "Minimal"],
                        ["value": "high", "name": "High"],
                    ],
                ],
            ],
        ]
        let open = try GrokACPClient.openResult(result, fallbackSessionId: nil)
        XCTAssertEqual(open.sessionId, "sid-1")
        XCTAssertFalse(open.configOptions.isEmpty)
        XCTAssertEqual(open.advertisedReasoningEffortIds, ["minimal", "high"])
    }

    /// WHY: warm reattach + prompt still paid full gateway replay unless
    /// session/load carries `_meta.noReplay` (grok-build parse_no_replay).
    /// Recover without prompt must keep replay so readThread has history.
    func test_loadSessionParamsIncludeNoReplayMetaWhenRequested() throws {
        // Reconstruct the params shape GrokACPClient.loadSession must emit.
        let withReplay = GrokACPClient.sessionOpenParams(
            cwd: "/tmp",
            mcpServers: [Any](),
            sessionId: "sid"
        )
        // Default: no _meta.noReplay
        XCTAssertNil(withReplay["_meta"])

        let noReplay = GrokACPClient.sessionOpenParams(
            cwd: "/tmp",
            mcpServers: [Any](),
            sessionId: "sid",
            noReplay: true
        )
        XCTAssertEqual((noReplay["_meta"] as? [String: Any])?["noReplay"] as? Bool, true)

        let root = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let clientSource = try String(
            contentsOf: root.appendingPathComponent("Sources/AgentRuntime/GrokACPClient.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(clientSource.contains("sessionMCPServers"), "Grok session/new and session/load must still send MCP servers")
        XCTAssertTrue(
            clientSource.contains("ComputerUseMCPAdmit.admitGrokACP"),
            "Grok logical Desktop sessions must admit the native host MCP conditionally"
        )
        XCTAssertTrue(clientSource.contains("noReplay"), "loadSession must accept noReplay")
        XCTAssertTrue(
            clientSource.contains("\"noReplay\": true")
                || clientSource.contains("[\"noReplay\": true]")
                || clientSource.contains("meta[\"noReplay\"] = true"),
            "loadSession must send _meta.noReplay when requested"
        )
        let adapterSource = try String(
            contentsOf: root.appendingPathComponent("Sources/AgentRuntime/GrokACPAdapter.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            adapterSource.contains("noReplay: shouldStartPrompt"),
            "Adapter must pass noReplay:true only on load+prompt path"
        )
        XCTAssertTrue(
            adapterSource.contains("yoloMode: request.permissionMode == .fullAccess"),
            "Adapter must stamp spawn-time yoloMode for fullAccess new/load"
        )
    }

    func test_sessionOpenParamsEncodeYoloModeWithoutAutoMode() throws {
        // WHY: grok-build session_setup reads _meta.yoloMode on new/load as
        // structural always-approve. Post-open set_mode still covers the parent
        // turn path; autoMode is not RemoteCode autoAcceptEdits (GROK-ACP-010).
        let servers: [Any] = []
        let omitted = GrokACPClient.sessionOpenParams(cwd: "/tmp", mcpServers: servers)
        XCTAssertNil(omitted["_meta"], "supervised/autoAcceptEdits must omit yoloMode")
        XCTAssertNil(omitted["sessionId"])
        XCTAssertEqual(omitted["cwd"] as? String, "/tmp")

        let yolo = GrokACPClient.sessionOpenParams(
            cwd: "/tmp",
            mcpServers: servers,
            yoloMode: true
        )
        let yoloMeta = try XCTUnwrap(yolo["_meta"] as? [String: Any])
        XCTAssertEqual(yoloMeta["yoloMode"] as? Bool, true)
        XCTAssertNil(yoloMeta["autoMode"])
        XCTAssertNil(yoloMeta["noReplay"])

        let coldLoad = GrokACPClient.sessionOpenParams(
            cwd: "/tmp",
            mcpServers: servers,
            sessionId: "sid",
            yoloMode: true,
            noReplay: true
        )
        XCTAssertEqual(coldLoad["sessionId"] as? String, "sid")
        let loadMeta = try XCTUnwrap(coldLoad["_meta"] as? [String: Any])
        XCTAssertEqual(loadMeta["yoloMode"] as? Bool, true)
        XCTAssertEqual(loadMeta["noReplay"] as? Bool, true)
        XCTAssertNil(loadMeta["autoMode"])

        let encoded = try JSONSerialization.data(withJSONObject: yolo, options: [.sortedKeys])
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual((parsed["_meta"] as? [String: Any])?["yoloMode"] as? Bool, true)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let adapter = try String(
            contentsOf: root.appendingPathComponent("Sources/AgentRuntime/GrokACPAdapter.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            adapter.contains("session.client.setMode(sessionId:"),
            "Adapter must keep the set_mode path after spawn-time yoloMode"
        )
        let client = try String(
            contentsOf: root.appendingPathComponent("Sources/AgentRuntime/GrokACPClient.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(
            client.contains("\"autoMode\""),
            "ACP open params must not emit autoMode"
        )
    }

    /// WHY: Image #1 Bot Desk Grok send died on session/new Invalid params.
    /// Live grok 1.0.4 accepted empty mcpServers and rejected bot MCP objects
    /// that omitted env or used a dict. The shipped session/new builder must
    /// emit the stdio shape that succeeded live: env as [{name,value}].
    func test_sessionMCPServersMatchLiveGrokMcpServerSchema() throws {
        let servers = GrokACPClient.sessionMCPServers(
            existing: [],
            command: "/tmp/RemoteCodeDistillService",
            environment: [BotSelfConfigCatalog.callerEnvironmentKey: "bot-desk-1"]
        )
        XCTAssertFalse(servers.isEmpty, "Desk Grok sessions still admit bot MCP servers")
        for item in servers {
            let object = try XCTUnwrap(item as? [String: Any], "mcpServers entries must be objects")
            XCTAssertNotNil(object["name"] as? String)
            XCTAssertNotNil(object["command"] as? String)
            XCTAssertNotNil(object["args"] as? [String])
            XCTAssertTrue(
                GrokACPMcpServer.envIsACPArray(object["env"]),
                "live grok rejects missing env and {KEY:value} dicts: \(object)"
            )
            XCTAssertFalse(object["env"] is [String: String], "env must not be a string dictionary")
        }
        let encoded = try JSONSerialization.data(withJSONObject: servers)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        XCTAssertEqual(parsed.count, servers.count)
        let selfConfig = try XCTUnwrap(parsed.first { ($0["name"] as? String) == BotSelfConfigMCPAdmit.serverName })
        let env = try XCTUnwrap(selfConfig["env"] as? [[String: String]])
        XCTAssertTrue(env.contains { $0["name"] == BotSelfConfigCatalog.callerEnvironmentKey && $0["value"] == "bot-desk-1" })
        XCTAssertFalse(
            GrokACPClient.sessionMCPServers().contains { item in
                (item as? [String: Any])?["name"] as? String == ComputerUseMCPAdmit.serverName
            },
            "Grok sessions must not re-admit remotecode-computer-use"
        )
    }

    /// WHY: the Distill librarian MCP (rc_* / 01-catalogo.html) is Token Saver
    /// surface. It must ride Grok sessions only while the run carries the Token
    /// Saver hint — the same gate Claude (--mcp-config) and Codex (config.toml
    /// lifecycle) apply — instead of unconditionally on every session.
    func test_sessionMCPServersAdmitDistillLibrarianOnlyWithTokenSaver() {
        func names(_ environment: [String: String]) -> [String] {
            GrokACPClient.sessionMCPServers(
                existing: [],
                command: "/tmp/RemoteCodeDistillService",
                environment: environment
            ).compactMap { ($0 as? [String: Any])?["name"] as? String }
        }

        let on = names([DistillMCPAdmit.tokenSaverHintEnvironmentKey: "1"])
        XCTAssertTrue(on.contains(DistillMCPAdmit.serverName),
                      "Token Saver on must admit the librarian MCP into the Grok session")

        let off = names([:])
        XCTAssertFalse(off.contains(DistillMCPAdmit.serverName),
                       "Token Saver off must not expose the librarian MCP to Grok")
        XCTAssertTrue(off.contains(BotSelfConfigMCPAdmit.serverName),
                      "the gate is librarian-only: bot servers stay admitted either way")
    }

    /// WHY: workspace-less bot threads fall through to currentDirectoryPath,
    /// which can be empty. Live grok session/new then returns
    /// Invalid params / Path is not absolute.
    func test_resolvedSessionCwdRejectsEmptyAndRelative() {
        let home = "/Users/fixture"
        XCTAssertEqual(GrokACPClient.resolvedSessionCwd("", home: home, fileExists: { _ in false }), home)
        XCTAssertEqual(GrokACPClient.resolvedSessionCwd("   ", home: home, fileExists: { _ in false }), home)
        XCTAssertEqual(GrokACPClient.resolvedSessionCwd("relative", home: home, fileExists: { _ in true }), home)
        XCTAssertEqual(GrokACPClient.resolvedSessionCwd("/", home: home, fileExists: { $0 == "/" }), "/")
        XCTAssertEqual(
            GrokACPClient.resolvedSessionCwd("/missing", home: home, fileExists: { $0 == "/" }),
            home
        )
        let existing = "/Users/fixture/proj"
        XCTAssertEqual(
            GrokACPClient.resolvedSessionCwd(existing, home: home, fileExists: { $0 == existing }),
            existing
        )
    }
}
