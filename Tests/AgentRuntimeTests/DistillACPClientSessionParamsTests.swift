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
}
