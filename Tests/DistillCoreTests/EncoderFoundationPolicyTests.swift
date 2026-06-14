import XCTest
@testable import DistillCore

/// I3.4 / I3.6 / I3.9: encoder foundation policies.
final class EncoderFoundationPolicyTests: XCTestCase {
    // I3.6: scorer/reranker/nli roles forbid head-truncation and need a chunk-policy.
    func test_roleHeadTruncationAndChunkPolicyGate() {
        XCTAssertTrue(TokenSaverApprovedEncoderManifests.answerAIColBERTSmall.forbidsHeadTruncation) // colbert-ranker
        XCTAssertTrue(TokenSaverApprovedEncoderManifests.answerAIColBERTSmall.chunkPolicySatisfied)
        XCTAssertFalse(TokenSaverApprovedEncoderManifests.bgeSmallEN.forbidsHeadTruncation) // embedder
        // A reranker with no chunk-policy is not structurally usable.
        let bad = TokenSaverEncoderManifest(
            id: "x/y", url: "https://huggingface.co/x/y", revision: "main",
            runtime: "mlx-embedders", role: "reranker", license: "MIT",
            maxSeqLen: 512, chunkPolicy: "")
        XCTAssertFalse(bad.chunkPolicySatisfied)
    }

    // I3.4: encoder install is optional — absent → disabled, never a hard requirement.
    func test_encoderInstallIsOptional() {
        XCTAssertEqual(EncoderInstallPolicy.readyState(encoderInstalled: false), .disabled)
        XCTAssertEqual(EncoderInstallPolicy.readyState(encoderInstalled: true), .enabled)
        XCTAssertFalse(EncoderInstallPolicy.isHardLaunchRequirement)
    }

    // V10: encoder RAM budget — the chosen small embedders fit 8GB; a 500M model doesn't.
    func test_encoderBudgetPolicy() {
        XCTAssertTrue(EncoderBudgetPolicy.withinHostBudget(paramsMillions: 33, hostRAMGB: 8))   // bge-small
        XCTAssertTrue(EncoderBudgetPolicy.withinHostBudget(paramsMillions: 150, hostRAMGB: 8))
        XCTAssertFalse(EncoderBudgetPolicy.withinHostBudget(paramsMillions: 500, hostRAMGB: 8))
        XCTAssertTrue(EncoderBudgetPolicy.withinHostBudget(paramsMillions: 300, hostRAMGB: 16))
        XCTAssertTrue(EncoderBudgetPolicy.sharedTrunkFits(totalMB: 400, quantization: "int8"))
        XCTAssertFalse(EncoderBudgetPolicy.sharedTrunkFits(totalMB: 400, quantization: "int4")) // unapproved quant
        XCTAssertFalse(EncoderBudgetPolicy.sharedTrunkFits(totalMB: 800, quantization: "int8")) // over budget
    }

    // I3.9: parity harness blocks ship on mismatch / coverage gap / constant label.
    func test_parityHarnessShipsOnlyOnFullParity() {
        let good = (0..<5).map { i in
            EncoderParityHarness.ArtifactCase(
                kind: ["log8k", "code", "ansi", "unicode", "empty"][i],
                referenceScore: Double(i) * 0.1, convertedScore: Double(i) * 0.1 + 0.0001)
        }
        XCTAssertTrue(EncoderParityHarness.evaluate(cases: good, tokenizerEquivalent: true).shipsModel)

        XCTAssertEqual(
            EncoderParityHarness.evaluate(cases: good, tokenizerEquivalent: false).reason,
            "tokenizer_mismatch")

        // Missing the "empty" artifact → coverage gap.
        XCTAssertEqual(
            EncoderParityHarness.evaluate(cases: Array(good.prefix(4)), tokenizerEquivalent: true).reason,
            "artifact_coverage_gap")

        // Constant label (the DeBERTa export hazard).
        let constant = ["log8k", "code", "ansi", "unicode", "empty"].map {
            EncoderParityHarness.ArtifactCase(kind: $0, referenceScore: 0.5, convertedScore: 0.5)
        }
        XCTAssertEqual(
            EncoderParityHarness.evaluate(cases: constant, tokenizerEquivalent: true).reason,
            "constant_label_output_variance")
    }
}
