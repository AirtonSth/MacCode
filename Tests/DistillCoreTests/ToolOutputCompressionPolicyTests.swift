import XCTest
@testable import DistillCore

final class ToolOutputCompressionPolicyTests: XCTestCase {
    private let policy = ToolOutputCompressionPolicy()

    func test_defaultExcludedToolsPassThroughFileMutationTools() {
        for tool in ["Read", "Edit", "Write", "MultiEdit", "NotebookEdit"] {
            let decision = policy.decision(toolName: tool, output: largeOutput())
            XCTAssertFalse(decision.shouldCompress, "\(tool) must stay raw by default")
            XCTAssertEqual(decision.profile, .passthrough)
            XCTAssertEqual(decision.skipReason, .excludedTool)
        }
    }

    func test_profilesMatchPlanForSearchShellAndWebFetch() {
        XCTAssertEqual(policy.decision(toolName: "Grep", output: largeOutput()).profile, .conservative)
        XCTAssertEqual(policy.decision(toolName: "Glob", output: largeOutput()).profile, .conservative)
        XCTAssertEqual(policy.decision(toolName: "Bash", output: largeOutput()).profile, .moderate)
        XCTAssertEqual(policy.decision(toolName: "WebFetch", output: largeOutput()).profile, .aggressive)
    }

    func test_thresholdRequiresLargeOutputBeforeHookCompression() {
        let small = policy.decision(toolName: "Bash", output: "ok\n")
        XCTAssertFalse(small.shouldCompress)
        XCTAssertEqual(small.skipReason, .belowThreshold)

        let manyLines = policy.decision(toolName: "Bash", output: Array(repeating: "line", count: 31).joined(separator: "\n"))
        XCTAssertTrue(manyLines.shouldCompress)

        let manyBytes = policy.decision(toolName: "Bash", output: String(repeating: "x", count: 2_049))
        XCTAssertTrue(manyBytes.shouldCompress)
    }

    func test_onlyWebFetchAllowsAbstractRewrite() {
        let grep = policy.decision(toolName: "Grep", output: largeOutput())
        XCTAssertFalse(grep.allowsAbstractRewrite)
        XCTAssertFalse(grep.allowsLinePruning, "search matches must not be pruned")
        XCTAssertTrue(grep.contractQuestion.contains("without dropping any match line"))

        let bash = policy.decision(toolName: "Bash", output: largeOutput())
        XCTAssertFalse(bash.allowsAbstractRewrite)
        XCTAssertTrue(bash.allowsLinePruning)

        let webFetch = policy.decision(toolName: "WebFetch", output: largeOutput())
        XCTAssertTrue(webFetch.allowsAbstractRewrite)
        XCTAssertTrue(webFetch.allowsLinePruning)
    }

    func test_hookDecisionsUseCommandOutputModeAndStoreBackedLedgerState() {
        let decision = policy.decision(
            toolName: "Bash",
            output: largeOutput(),
            toolArgumentsSummary: "swift test --filter FooTests",
            taskSummary: "verify failing tests"
        )

        XCTAssertTrue(decision.shouldCompress)
        XCTAssertEqual(decision.mode, .commandOutput)
        XCTAssertEqual(decision.cacheState, "tool_output_hooked")
        XCTAssertEqual(decision.reversibleStoreMinBytes, 2_048)
        XCTAssertTrue(decision.contractQuestion.contains("swift test --filter FooTests"))
    }

    private func largeOutput() -> String {
        String(repeating: "error: expected value did not match actual value\n", count: 60)
    }
}
