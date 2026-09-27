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

    func test_sessionNewOmitsUnavailableModelAndEffort() {
        let params = DistillACPClient.sessionOpenParams(cwd: "/tmp", mcpServers: [])

        XCTAssertNil(params["model"])
        XCTAssertNil(params["reasoning_effort"])
        XCTAssertNil(params["_meta"])
    }
}
