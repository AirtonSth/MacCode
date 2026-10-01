import XCTest
@testable import AgentRuntime
import CoreModel

final class DistillACPClientSessionParamsTests: XCTestCase {
    func test_sessionNewUsesDistillMetaModelAndReasoningEffortWireFields() {
        let params = DistillACPClient.sessionOpenParams(
            cwd: "/tmp",
            mcpServers: [],
            modelId: "grok-4.6",
            reasoningEffort: .high
        )

        XCTAssertNil(params["model"], "Distill's session setup does not select a model from the generic top-level field")
        XCTAssertNil(params["reasoning_effort"])
        let meta = params["_meta"] as? [String: Any]
        XCTAssertEqual(meta?["modelId"] as? String, "grok-4.6")
        XCTAssertEqual(meta?["reasoningEffort"] as? String, "high")
    }

    func test_fallbackCatalogContainsOnlyExplicitDistillModels_becauseMainSelectionMustNeverBeAccountDefault() {
        let models = DistillRunner.listModels(installedVersion: nil)

        XCTAssertFalse(models.isEmpty)
        XCTAssertTrue(models.allSatisfy { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        XCTAssertFalse(models.contains { $0.label == "Default (account)" })
    }

    func test_cliRunnerRejectsEmptyMainModelBeforeResolvingBinary_becauseAccountDefaultIsNotSelectable() async throws {
        let runner = DistillRunner(binaryNameOverride: "/missing/distill-agent")
        do {
            _ = try await runner.startRun(
                AgentRunRequest(
                    threadId: AgentThreadID(),
                    provider: .distill,
                    model: "",
                    cwd: "/tmp",
                    prompt: "Do work"
                ),
                onEvent: { _ in }
            )
            XCTFail("The CLI runner must not omit --model for a Distill run")
        } catch let error as AgentRunError {
            guard case .spawnFailed(let message) = error else {
                return XCTFail("expected explicit Main-model validation, got \(error)")
            }
            XCTAssertEqual(message, "Select an explicit Distill Main model before running.")
        }
    }

    func test_sessionNewOmitsUnavailableModelAndEffort() {
        let params = DistillACPClient.sessionOpenParams(cwd: "/tmp", mcpServers: [])

        XCTAssertNil(params["model"])
        XCTAssertNil(params["reasoning_effort"])
        XCTAssertNil(params["_meta"])
    }

    func test_promptBlocks_keepOriginalPromptAndEssentialBotDirectives_withoutGenericModeOrTokenSaverText() throws {
        let original = "Original user request with exact wording."
        let botContext = "RemoteCode-resolved Bot identities for this exact turn: @quinn"
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .distill,
            model: "grok-4.6",
            cwd: "/tmp",
            prompt: original,
            interactionMode: .plan,
            environment: [
                BotPeerDelegation.turnContextEnvironmentKey: botContext,
                "RC_TOKEN_SAVER_ENABLED": "1",
                "RC_AUTO_ENABLED": "1"
            ]
        )
        let capabilities = DistillACPInitializeResult(
            protocolVersion: 1,
            loadSession: true,
            embeddedContext: false
        )

        let blocks = try DistillACPClient.promptBlocks(for: request, capabilities: capabilities)
        let text = try XCTUnwrap(blocks.first?["text"] as? String)

        XCTAssertTrue(text.contains(original))
        XCTAssertTrue(text.contains(botContext))
        XCTAssertTrue(text.contains(BackgroundAwaitContinuation.awaitingMarker))
        XCTAssertTrue(text.contains(BotPeerDelegation.providerDirective))
        XCTAssertFalse(text.contains("Default mode."))
        XCTAssertFalse(text.contains("Plan mode."))
        XCTAssertFalse(text.contains("Auto is on."))
        XCTAssertFalse(text.contains("Token Saver"))
    }

    func test_otherProviderStillUsesGenericModePrompt() {
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .claude,
            model: "claude",
            cwd: "/tmp",
            prompt: "Original"
        )

        XCTAssertTrue(request.providerPrompt.contains("Default mode."))
        XCTAssertTrue(request.providerPrompt.contains("User request:\nOriginal"))
    }

    func test_distillPromptBlocks_preserveAttachmentBlocks() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("distill-prompt-\(UUID().uuidString).txt")
        try Data("attachment body".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .distill,
            model: "grok-4.6",
            cwd: "/tmp",
            prompt: "Keep this prompt",
            attachments: [AgentAttachment(path: fileURL.path, kind: .file)]
        )
        let capabilities = DistillACPInitializeResult(
            protocolVersion: 1,
            loadSession: true,
            embeddedContext: true
        )

        let blocks = try DistillACPClient.promptBlocks(for: request, capabilities: capabilities)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[1]["type"] as? String, "resource")
    }

    func test_distillHomePrecedence_instanceThenEnvThenDotDistill() {
        // WHY: an explicit instance home must win over the app env, and ~/.grok must never be adopted.
        XCTAssertEqual(
            DistillProvisioner.homeURL(
                instanceHomePath: " /i ", environment: ["DISTILL_HOME": "/e", "GROK_HOME": "/g"], userHome: "/u"
            ).path,
            "/i"
        )
        XCTAssertEqual(
            DistillProvisioner.homeURL(
                instanceHomePath: "", environment: ["DISTILL_HOME": "/e", "GROK_HOME": "/g"], userHome: "/u"
            ).path,
            "/e"
        )
        XCTAssertEqual(
            DistillProvisioner.homeURL(instanceHomePath: nil, environment: ["GROK_HOME": "/g"], userHome: "/u").path,
            "/u/.distill"
        )
    }

    func test_distillModelsConfigReadsOnlyWorkerKeysFromModelsSection() {
        // WHY: the global Worker display must ignore comments, other sections, and empty values.
        let parsed = DistillModelsConfig.parse("""
        worker = "top-level-ignored"
        [other]
        worker = "other-section"
        [models]
        # worker = "commented"
        main = "gpt"
        worker = "grok-4.5" # trailing
        worker_effort = 'high'
        """)
        XCTAssertEqual(parsed.worker, "grok-4.5")
        XCTAssertEqual(parsed.workerEffort, "high")
        let empty = DistillModelsConfig.parse("[models]\nworker = \"\"\nworker_effort = \"\"\n")
        XCTAssertNil(empty.worker)
        XCTAssertNil(empty.workerEffort)
    }

    func test_distillModelsConfigReadMissingFileIsNil() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)")
        let result = DistillModelsConfig.read(home: home)
        XCTAssertNil(result.worker)
        XCTAssertNil(result.workerEffort)
    }
}
