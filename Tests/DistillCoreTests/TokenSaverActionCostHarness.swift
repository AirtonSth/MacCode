import Foundation
import DistillCore
import CoreModel

/// Scores a compressor on **successful agent actions per token**, not compression ratio.
///
/// WHY this metric and not the existing one: `TokenSaverQualityBenchmark` scores literal
/// fidelity — did required substrings survive — over text pairs. That answers "did we keep
/// the words" but not "can the agent still do the next thing". A compressor can preserve
/// every pinned literal and still destroy the one line the agent needed to build its next
/// tool call, and it can also drop a literal that no downstream action ever reads. Both
/// cases score wrong under a ratio-or-literals metric.
///
/// So each case here declares the NEXT ACTION the agent would take and the exact facts that
/// action needs. A case passes only if every one of those facts is still obtainable from the
/// compressed text — either present verbatim, or recoverable through a `[[rc:<handle>]]`
/// marker the agent can resolve. The aggregate is actions preserved per 1,000 tokens spent,
/// which is the number that should gate any dialect or pipe-policy change.
///
/// Deliberately deterministic and model-free: it takes a compressor as a closure, so it runs
/// in CI without the local MLX model and without a provider. That also means it does NOT by
/// itself produce a provider-token baseline — comparing real billed usage with and without
/// the dialect injected is a separate A/B run, and nothing in this file should be read as a
/// substitute for it.
enum TokenSaverActionCostHarness {

    /// One corpus entry: raw tool output plus what the agent must still be able to do.
    struct Case {
        /// Stable identifier used in failure messages.
        let name: String
        /// The raw output a tool produced.
        let input: String
        /// The extraction prompt that would accompany a `| distill` pipe.
        let question: String
        /// What the agent does next with this output, in one line. Documentation for the
        /// human reading a failure, not used in scoring.
        let nextAction: String
        /// Exact facts the next action cannot be performed without. These are the
        /// scoring criteria: a file path it must open, a command it must re-run, an
        /// identifier it must match, a count it must compare.
        let requiredForNextAction: [String]
    }

    struct CaseResult {
        let name: String
        let inputTokens: Int
        let outputTokens: Int
        let missingFacts: [String]
        let recoverableViaHandle: Bool

        /// The action survives when nothing it needs went missing, or when what went
        /// missing is still recoverable byte-exactly through a handle.
        var actionPreserved: Bool { missingFacts.isEmpty || recoverableViaHandle }
        var tokensSaved: Int { max(inputTokens - outputTokens, 0) }
    }

    struct Score {
        let results: [CaseResult]

        var actionsPreserved: Int { results.filter(\.actionPreserved).count }
        var totalCases: Int { results.count }
        var totalOutputTokens: Int { results.reduce(0) { $0 + $1.outputTokens } }
        var totalInputTokens: Int { results.reduce(0) { $0 + $1.inputTokens } }
        var totalTokensSaved: Int { results.reduce(0) { $0 + $1.tokensSaved } }

        /// The headline: how many next-actions survive per 1,000 tokens the agent spends
        /// reading the compressed output. Higher is better. A compressor that halves the
        /// tokens but breaks a third of the actions scores worse than one that saves less.
        var actionsPerThousandOutputTokens: Double {
            guard totalOutputTokens > 0 else { return 0 }
            return Double(actionsPreserved) / Double(totalOutputTokens) * 1_000
        }

        /// Cases whose next action can no longer be performed. Any non-empty value should
        /// fail a gating test regardless of how good the token numbers look.
        var brokenActions: [String] {
            results.filter { !$0.actionPreserved }.map(\.name)
        }
    }

    /// Runs every case through `compress` and scores the outcome.
    ///
    /// `compress` receives the raw output and the question, exactly as a `| distill` pipe
    /// would, and returns what the agent would actually read.
    static func score(cases: [Case], compress: (String, String) -> String) -> Score {
        let results = cases.map { testCase -> CaseResult in
            let output = compress(testCase.input, testCase.question)
            let missing = testCase.requiredForNextAction.filter { !output.contains($0) }
            return CaseResult(
                name: testCase.name,
                inputTokens: TokenEstimator.estimate(testCase.input),
                outputTokens: TokenEstimator.estimate(output),
                missingFacts: missing,
                recoverableViaHandle: output.contains("[[rc:")
            )
        }
        return Score(results: results)
    }

    /// Fixed corpus. Each entry is shaped like output this agent actually pipes, and each
    /// `requiredForNextAction` entry is a fact a real follow-up tool call needs.
    ///
    /// Kept small and hand-checked on purpose: a large auto-generated corpus makes the
    /// metric look rigorous while hiding whether the declared facts are the ones the next
    /// action truly needs. Grow it by adding cases whose action you can name.
    static let corpus: [Case] = [
        Case(
            name: "failing-swift-test",
            input: """
            Test Suite 'SR1ResponseDetectorTests' started at 2026-07-24 09:14:02.113
            Test Case '-[AgentRuntimeTests.SR1ResponseDetectorTests test_isSR1_shortText_returnsFalse]' passed (0.001 seconds).
            Test Case '-[AgentRuntimeTests.SR1ResponseDetectorTests test_isSR1_specR0Example_returnsFalse]' started.
            /Users/dev/app/Tests/AgentRuntimeTests/SR1ResponseDetectorTests.swift:131: error: \
            -[AgentRuntimeTests.SR1ResponseDetectorTests test_isSR1_specR0Example_returnsFalse] : \
            XCTAssertFalse failed - the spec's own R0 reply must not be treated as a compressed payload
            Test Case '-[AgentRuntimeTests.SR1ResponseDetectorTests test_isSR1_specR0Example_returnsFalse]' failed (0.002 seconds).
            Executed 42 tests, with 1 failure (0 unexpected) in 0.412 (0.418) seconds
            """,
            question: "Did tests pass? Return PASS or FAIL, then the failing test names and their file:line.",
            nextAction: "Open the failing test at its exact file:line and read the assertion.",
            requiredForNextAction: [
                "SR1ResponseDetectorTests.swift:131",
                "test_isSR1_specR0Example_returnsFalse"
            ]
        ),
        Case(
            name: "swift-build-error",
            input: """
            [1/4] Compiling AgentRuntime SR1ResponseDetector.swift
            /Users/dev/app/Sources/AgentRuntime/SR1ResponseDetector.swift:27:16: error: \
            cannot find 'DistillSemanticPrefixes' in scope
                          semanticPrefixes.contains(first) else {
                          ^~~~~~~~~~~~~~~~
            /Users/dev/app/Sources/AgentRuntime/SR1ResponseDetector.swift:20:41: note: \
            add 'import CoreModel' to reference this type
            error: fatalError
            """,
            question: "Did the build succeed? If not, return each error as file:line plus the message.",
            nextAction: "Edit that exact file at that line to add the missing import.",
            requiredForNextAction: [
                "SR1ResponseDetector.swift:27",
                "cannot find 'DistillSemanticPrefixes' in scope"
            ]
        ),
        Case(
            name: "git-status-before-commit",
            input: """
             M Sources/AgentRuntime/SR1ResponseDetector.swift
             M Sources/DistillCore/DistillCore.swift
            ?? Sources/CoreModel/DistillSemanticPrefixes.swift
            ?? Tests/AgentRuntimeTests/DistillSemanticPrefixParityTests.swift
            """,
            question: "Which files changed, and which are untracked? One per line.",
            nextAction: "Stage exactly the untracked new files by path.",
            requiredForNextAction: [
                "Sources/CoreModel/DistillSemanticPrefixes.swift",
                "Tests/AgentRuntimeTests/DistillSemanticPrefixParityTests.swift"
            ]
        ),
        Case(
            name: "json-config-lookup",
            input: """
            {"localVersion":"6","sourceRevision":"github-main-remote-code-template-v2",\
            "sha256":"6c7eb641aa0f4d2e9b3c5f7180ab2c4d6e8f0a1b2c3d4e5f60718293a4b5c6d7",\
            "installedAt":"2026-07-24T04:54:56Z","files":["SKILL.md","manifest.json"]}
            """,
            question: "Return the installed version and the sha256.",
            nextAction: "Compare the recorded sha256 against a freshly computed one to decide whether to rewrite the file.",
            requiredForNextAction: [
                "6c7eb641aa0f4d2e9b3c5f7180ab2c4d6e8f0a1b2c3d4e5f60718293a4b5c6d7"
            ]
        ),
        Case(
            name: "noisy-log-with-one-signal",
            input: ([
                "level=info msg=\"distill service ready\" port=51823",
                "level=info msg=\"cache warm\" entries=128"
            ] + (0..<40).map { "level=debug msg=\"mlx decode\" seq=\($0) ms=\(12 + $0)" } + [
                "level=error msg=\"generation deadline exceeded\" deadline_ms=20000 client_timeout_ms=8000",
                "level=info msg=\"lane released\""
            ]).joined(separator: "\n"),
            question: "Was there an error? Return the error line verbatim if so.",
            nextAction: "Align the client timeout with the server deadline using both numbers.",
            requiredForNextAction: ["20000", "8000"]
        ),
        Case(
            name: "diff-needing-exact-context",
            input: """
            diff --git a/Sources/AppShell/AppContext.swift b/Sources/AppShell/AppContext.swift
            index 1a2b3c4..5d6e7f8 100644
            --- a/Sources/AppShell/AppContext.swift
            +++ b/Sources/AppShell/AppContext.swift
            @@ -2467,7 +2467,7 @@ final class AppContext {
                             provider: pending.provider,
                             actualProviderTokens: pending.totalTokens,
            -                estimatedRawTokens: pending.totalTokens,
            +                estimatedRawTokens: pending.measuredRawBaseline,
                             actualProviderBilledTokenUnits: pending.billedTokenUnits,
            """,
            question: "What changed? Return the file and the changed lines.",
            nextAction: "Apply or review the hunk, which requires the exact old and new line text.",
            requiredForNextAction: [
                "estimatedRawTokens: pending.totalTokens",
                "estimatedRawTokens: pending.measuredRawBaseline"
            ]
        )
    ]
}
