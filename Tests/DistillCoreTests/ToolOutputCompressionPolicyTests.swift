import XCTest
import CoreModel
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

    func test_bashExactOutputShellRecognizesCatalogPrefixesAndGitGlobalOptions() {
        let prefixedCommands = WrappedCommandCatalog.exactOutputCommands.flatMap { command in
            [
                "FOO=1 \(command) sample",
                "/usr/bin/env FOO=1 \(command) sample",
                "env -- \(command) sample",
                "command \(command) sample",
                "/usr/bin/command -- \(command) sample",
            ]
        }
        for command in prefixedCommands + [
            "env -S rg needle Sources",
            "env -S 'rg -n needle Sources'",
            "env -C /tmp rg -n needle Sources",
            "env -P /usr/bin rg -n needle Sources",
            "env -v rg -n needle Sources",
            "env -iv rg -n needle Sources",
            "FOO='a b' rg -n needle Sources",
            "env FOO='a b' rg -n needle Sources",
            "exec -a 'display name' rg -n needle Sources",
            "\"/usr/bin/env\" FOO=1 rg -n needle Sources",
            "\"/usr/bin/command\" -- rg -n needle Sources",
            "exec -a display-name rg -n needle Sources",
            "git -C repo show HEAD",
            "env FOO=1 git --git-dir=.git grep needle",
            "exec git -c color.ui=false cat-file -p HEAD",
        ] {
            XCTAssertTrue(
                ToolOutputCompressionPolicy.shellCommandLooksExactOutput(command),
                "exact-output command must bypass PostToolUse Distill: \(command)"
            )
        }
        XCTAssertFalse(ToolOutputCompressionPolicy.shellCommandLooksExactOutput("env FOO=1 swift test"))
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
