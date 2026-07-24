import XCTest
@testable import DistillCore

/// Self-tests for the actions-per-token harness.
///
/// WHY a harness needs its own tests: the whole point of the metric is to fail when a
/// compressor breaks the agent's next action. A scorer that silently reports success is
/// worse than no scorer, because it launders an unmeasured change as measured. These tests
/// prove the scorer detects loss, credits handle-based recovery, and computes the ratio.
final class TokenSaverActionCostHarnessTests: XCTestCase {

    // MARK: - Corpus integrity

    func test_everyCorpusCaseDeclaresFactsPresentInItsOwnInput() {
        // A required fact that is absent from the raw input is a broken case, not a
        // compressor failure — it would make every compressor look lossy forever.
        for testCase in TokenSaverActionCostHarness.corpus {
            for fact in testCase.requiredForNextAction {
                XCTAssertTrue(testCase.input.contains(fact),
                              "case \(testCase.name) requires '\(fact)' which is not in its own input")
            }
            XCTAssertFalse(testCase.requiredForNextAction.isEmpty,
                           "case \(testCase.name) must declare what its next action needs")
            XCTAssertFalse(testCase.nextAction.isEmpty,
                           "case \(testCase.name) must name the next action a human can check")
        }
    }

    func test_corpusCoversTheOutputShapesThatGetPiped() {
        let names = Set(TokenSaverActionCostHarness.corpus.map(\.name))
        for expected in ["failing-swift-test", "swift-build-error", "noisy-log-with-one-signal", "diff-needing-exact-context"] {
            XCTAssertTrue(names.contains(expected), "corpus must keep covering \(expected)")
        }
    }

    // MARK: - Scorer behaviour

    func test_identityCompressorPreservesEveryActionAndSavesNothing() {
        let score = TokenSaverActionCostHarness.score(cases: TokenSaverActionCostHarness.corpus) { input, _ in input }

        XCTAssertEqual(score.actionsPreserved, score.totalCases,
                       "passing the output through unchanged cannot break any next action")
        XCTAssertTrue(score.brokenActions.isEmpty)
        XCTAssertEqual(score.totalTokensSaved, 0,
                       "identity saves nothing — this is the baseline any compressor must beat")
        XCTAssertGreaterThan(score.actionsPerThousandOutputTokens, 0)
    }

    func test_truncatingCompressorIsCaughtEvenThoughItSavesManyTokens() {
        // The failure mode the metric exists for: huge token savings, broken agent.
        let score = TokenSaverActionCostHarness.score(cases: TokenSaverActionCostHarness.corpus) { input, _ in
            String(input.prefix(40))
        }

        XCTAssertGreaterThan(score.totalTokensSaved, 0, "truncation does save tokens")
        XCTAssertFalse(score.brokenActions.isEmpty,
                       "truncation destroys facts the next action needs and must be reported as broken")
        XCTAssertLessThan(score.actionsPreserved, score.totalCases)
    }

    func test_handleMarkerCreditsRecoveryWhenFactsAreElided() {
        // Compression that elides content but leaves a resolvable handle is not the same
        // failure as compression that loses it: the agent can still recover exact bytes.
        let score = TokenSaverActionCostHarness.score(cases: TokenSaverActionCostHarness.corpus) { _, _ in
            "summary only [[rc:abc123]]"
        }

        XCTAssertEqual(score.actionsPreserved, score.totalCases,
                       "an elided region with a recovery handle keeps the action performable")
        XCTAssertTrue(score.results.allSatisfy(\.recoverableViaHandle))
        XCTAssertTrue(score.results.allSatisfy { !$0.missingFacts.isEmpty },
                      "the facts really are absent from the compressed text; only the handle saves it")
    }

    func test_lossWithoutHandleIsNotCredited() {
        let score = TokenSaverActionCostHarness.score(cases: TokenSaverActionCostHarness.corpus) { _, _ in
            "summary only, no recovery reference"
        }

        XCTAssertEqual(score.actionsPreserved, 0,
                       "dropping required facts with no handle breaks every action")
        XCTAssertEqual(score.brokenActions.count, score.totalCases)
    }

    func test_metricRewardsFewerTokensOnlyWhenActionsSurvive() {
        let identity = TokenSaverActionCostHarness.score(cases: TokenSaverActionCostHarness.corpus) { input, _ in input }
        // A compressor that keeps exactly the required facts and drops the rest: the
        // shape a real query-pushdown codec should aim for.
        let extractive = TokenSaverActionCostHarness.score(cases: TokenSaverActionCostHarness.corpus) { input, _ in
            guard let testCase = TokenSaverActionCostHarness.corpus.first(where: { $0.input == input }) else { return input }
            return testCase.requiredForNextAction.joined(separator: "\n")
        }

        XCTAssertEqual(extractive.actionsPreserved, extractive.totalCases,
                       "keeping every required fact must preserve every action")
        XCTAssertGreaterThan(extractive.totalTokensSaved, 0)
        XCTAssertGreaterThan(extractive.actionsPerThousandOutputTokens,
                             identity.actionsPerThousandOutputTokens,
                             "the metric must prefer the extractive compressor over sending everything")
    }

    // MARK: - Scope note

    func test_harnessDoesNotClaimAProviderBaseline() {
        // Guards against the mistake this harness was built to end: a number that looks
        // measured but rests on a counterfactual. The harness only compares texts it was
        // given; it never estimates what a provider would have spent without Token Saver.
        // Establishing that requires an A/B run against real provider usage.
        let score = TokenSaverActionCostHarness.score(cases: [TokenSaverActionCostHarness.corpus[0]]) { input, _ in input }
        XCTAssertEqual(score.totalInputTokens, score.totalOutputTokens,
                       "with identity compression both legs are equal — no hidden credit is applied")
    }
}
