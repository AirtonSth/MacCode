import XCTest
@testable import CoreModel

final class TokenSaverModelMigrationPolicyTests: XCTestCase {
    func test_keepsInstalledModelWhenSelectedModelIsAlreadyInstalled() {
        XCTAssertEqual(
            TokenSaverModelMigrationPolicy.decision(
                installed: TokenSaverApprovedModels.distill17B,
                selected: TokenSaverApprovedModels.distill17B,
                candidateArtifactAvailable: true,
                perf: passingPerf()
            ),
            TokenSaverModelMigrationDecision(action: .keepInstalled, reason: "selected_model_already_installed")
        )
    }

    func test_keepsInstalledFallbackWhenHigherTierArtifactIsUnavailable() {
        XCTAssertEqual(
            TokenSaverModelMigrationPolicy.decision(
                installed: TokenSaverApprovedModels.distill17B,
                selected: TokenSaverApprovedModels.distillE4B,
                candidateArtifactAvailable: false,
                perf: nil
            ),
            TokenSaverModelMigrationDecision(action: .keepInstalled, reason: "candidate_artifact_unavailable")
        )
    }

    func test_downloadsCandidateBeforeActivationWhenPerfIsUnmeasured() {
        XCTAssertEqual(
            TokenSaverModelMigrationPolicy.decision(
                installed: TokenSaverApprovedModels.distill17B,
                selected: TokenSaverApprovedModels.distillE4B,
                candidateArtifactAvailable: true,
                perf: nil
            ),
            TokenSaverModelMigrationDecision(action: .downloadCandidate, reason: "candidate_needs_warmup_and_perf_measurement")
        )
    }

    func test_keepsInstalledFallbackWhenWarmupOrMeasurementsFail() {
        XCTAssertEqual(
            TokenSaverModelMigrationPolicy.decision(
                installed: TokenSaverApprovedModels.distill17B,
                selected: TokenSaverApprovedModels.distillE4B,
                candidateArtifactAvailable: true,
                perf: TokenSaverModelPerfEnvelope(
                    warmupPassed: false,
                    p95Milliseconds: 900,
                    p95BudgetMilliseconds: 1_000,
                    measuredFootprintBytes: 2_000,
                    memoryBudgetBytes: 3_000
                )
            ),
            TokenSaverModelMigrationDecision(action: .keepInstalled, reason: "candidate_warmup_failed")
        )

        XCTAssertEqual(
            TokenSaverModelMigrationPolicy.decision(
                installed: TokenSaverApprovedModels.distill17B,
                selected: TokenSaverApprovedModels.distillE4B,
                candidateArtifactAvailable: true,
                perf: TokenSaverModelPerfEnvelope(
                    warmupPassed: true,
                    p95Milliseconds: nil,
                    p95BudgetMilliseconds: 1_000,
                    measuredFootprintBytes: 2_000,
                    memoryBudgetBytes: 3_000
                )
            ),
            TokenSaverModelMigrationDecision(action: .keepInstalled, reason: "candidate_p95_unmeasured")
        )
    }

    func test_raisesThresholdInsteadOfRelaxingGateWhenFootprintOrLatencyExceedsBudget() {
        XCTAssertEqual(
            TokenSaverModelMigrationPolicy.decision(
                installed: TokenSaverApprovedModels.distill17B,
                selected: TokenSaverApprovedModels.distillE4B,
                candidateArtifactAvailable: true,
                perf: TokenSaverModelPerfEnvelope(
                    warmupPassed: true,
                    p95Milliseconds: 900,
                    p95BudgetMilliseconds: 1_000,
                    measuredFootprintBytes: 4_000,
                    memoryBudgetBytes: 3_000
                )
            ),
            TokenSaverModelMigrationDecision(action: .raiseMemoryThreshold, reason: "candidate_footprint_exceeds_budget")
        )

        XCTAssertEqual(
            TokenSaverModelMigrationPolicy.decision(
                installed: TokenSaverApprovedModels.distill17B,
                selected: TokenSaverApprovedModels.distillE4B,
                candidateArtifactAvailable: true,
                perf: TokenSaverModelPerfEnvelope(
                    warmupPassed: true,
                    p95Milliseconds: 1_200,
                    p95BudgetMilliseconds: 1_000,
                    measuredFootprintBytes: 2_000,
                    memoryBudgetBytes: 3_000
                )
            ),
            TokenSaverModelMigrationDecision(action: .raiseMemoryThreshold, reason: "candidate_p95_exceeds_budget")
        )
    }

    func test_activatesCandidateOnlyAfterWarmupFootprintAndP95Pass() {
        XCTAssertEqual(
            TokenSaverModelMigrationPolicy.decision(
                installed: TokenSaverApprovedModels.distill17B,
                selected: TokenSaverApprovedModels.distillE4B,
                candidateArtifactAvailable: true,
                perf: passingPerf()
            ),
            TokenSaverModelMigrationDecision(action: .activateCandidate, reason: "candidate_passed_warmup_and_perf")
        )
    }

    private func passingPerf() -> TokenSaverModelPerfEnvelope {
        TokenSaverModelPerfEnvelope(
            warmupPassed: true,
            p95Milliseconds: 900,
            p95BudgetMilliseconds: 1_000,
            measuredFootprintBytes: 2_000,
            memoryBudgetBytes: 3_000
        )
    }
}
