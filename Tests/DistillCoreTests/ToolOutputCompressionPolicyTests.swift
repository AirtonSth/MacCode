import XCTest
@testable import DistillCore

final class ToolOutputCompressionPolicyTests: XCTestCase {
    private let policy = ToolOutputCompressionPolicy()

    func test_defaultExcludedToolsPassThroughFileMutationTools() {
        for tool in ["Edit", "Write", "MultiEdit", "NotebookEdit"] {
            let decision = policy.decision(toolName: tool, output: largeOutput())
            XCTAssertFalse(decision.shouldCompress, "\(tool) must stay raw by default")
            XCTAssertEqual(decision.skipReason, .excludedTool)
        }
    }

    func test_largeReadIsAllowlistedForExtractiveCompression() {
        let decision = policy.decision(toolName: "Read", output: largeOutput())
        XCTAssertTrue(decision.shouldCompress, "large Read should compress via skeleton/BERT path")
        XCTAssertEqual(decision.profile, .moderate)
        XCTAssertNil(decision.skipReason)
        XCTAssertTrue(decision.contractQuestion.localizedCaseInsensitiveContains("file read"))
    }

    func test_imagePayloadSkipsTextDistill() {
        let jpegish = String(repeating: "/9j/4AAQSkZJRgABAQAAAQABAAD", count: 40)
        let decision = policy.decision(toolName: "Read", output: jpegish)
        XCTAssertFalse(decision.shouldCompress)
        XCTAssertEqual(decision.skipReason, .multimodalImage)
    }

    func test_bashExactOutputShellSkipsCompression() {
        let large = largeOutput()
        let rg = policy.decision(
            toolName: "Bash",
            output: large,
            toolArgumentsSummary: "command=rg -n fail Sources"
        )
        XCTAssertFalse(rg.shouldCompress)
        XCTAssertEqual(rg.skipReason, .exactOutputShell)

        let mixed = policy.decision(
            toolName: "Bash",
            output: large,
            toolArgumentsSummary: "command=command -v swift\nswift noisy.swift"
        )
        XCTAssertFalse(mixed.shouldCompress)
        XCTAssertEqual(
            mixed.skipReason,
            .exactOutputShell,
            "the aggregate hook must stay raw; the compound PATH wrapper owns segment-level distill"
        )

        let gitGrep = policy.decision(
            toolName: "Bash",
            output: large,
            toolArgumentsSummary: "command=git grep -n TODO"
        )
        XCTAssertFalse(gitGrep.shouldCompress)
        XCTAssertEqual(gitGrep.skipReason, .exactOutputShell)

        let make = policy.decision(
            toolName: "Bash",
            output: large,
            toolArgumentsSummary: "command=make test"
        )
        XCTAssertTrue(make.shouldCompress)
    }

    func test_bashExplicitDistillInvocationSkipsSecondCompressionPass() {
        let explicitCommands = [
            "swift test 2>&1 | distill 'test failures'",
            "distill retrieve 01234567-89ab-cdef-0123-456789abcdef",
            "/Applications/RemoteCode.app/Contents/MacOS/distill retrieve handle",
            "command /opt/remotecode/bin/distill 'summarize build'",
            "env RC_EXPLICIT=1 /opt/remotecode/bin/distill 'summarize build'",
        ]

        for command in explicitCommands {
            let decision = policy.decision(
                toolName: "Bash",
                output: largeOutput(),
                toolArgumentsSummary: "command=\(command)"
            )
            XCTAssertFalse(decision.shouldCompress, "explicit Distill must own one pass: \(command)")
            XCTAssertEqual(decision.skipReason, .explicitDistillPipeline)
            XCTAssertEqual(decision.skipReason?.rawValue, "explicit_distill_pipeline")
        }

        let ordinary = policy.decision(
            toolName: "Bash",
            output: largeOutput(),
            toolArgumentsSummary: "command=swift test --filter FeatureTests"
        )
        XCTAssertTrue(ordinary.shouldCompress, "ordinary noisy Swift output still uses PostToolUse")
        XCTAssertNil(ordinary.skipReason)
    }

    func test_profilesMatchPlanForSearchShellAndWebFetch() {
        XCTAssertEqual(policy.decision(toolName: "Grep", output: largeOutput()).profile, .conservative)
        XCTAssertEqual(policy.decision(toolName: "Glob", output: largeOutput()).profile, .conservative)
        XCTAssertEqual(policy.decision(toolName: "Bash", output: largeOutput()).profile, .moderate)
        XCTAssertEqual(policy.decision(toolName: "Read", output: largeOutput()).profile, .moderate)
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
