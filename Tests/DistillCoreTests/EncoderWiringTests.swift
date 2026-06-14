import XCTest
@testable import DistillCore

/// Wave 2: real-encoder wiring exercised with a DETERMINISTIC bag-of-words stub
/// embedder (no model download). The same seams are driven by the real MLX backend
/// in EncoderLiveInferenceTests. Proves: I8.1 cosine gate, I9.1 cosine nomination
/// (deterministic diff still decides), and embedding-prototype zero-shot (I7/I10.5/F14).
final class EncoderWiringTests: XCTestCase {
    /// 96-dim L2-normalized bag-of-words vector — deterministic, no network.
    private static func stubEmbed(_ texts: [String]) -> [[Float]] {
        texts.map { text in
            var v = [Float](repeating: 0, count: 96)
            for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                var h = 5381
                for b in token.utf8 { h = ((h << 5) &+ h) &+ Int(b) }
                v[abs(h) % 96] += 1
            }
            let norm = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
            return norm > 0 ? v.map { $0 / norm } : v
        }
    }
    private static let embed: @Sendable ([String]) async throws -> [[Float]] = { stubEmbed($0) }
    private static let cosine: @Sendable (String, String) async throws -> Double = { a, b in
        let vs = stubEmbed([a, b]); return MLXEmbeddingBackend.dot(vs[0], vs[1])
    }

    // MARK: I8.1 cosine gate

    func test_cosineGateAcceptsSimilarRejectsDissimilar() async {
        let gate = SemanticSimilarityGate(threshold: 0.5, cosine: Self.cosine)
        let original = "authentication token expired and the session must refresh now"
        let faithful = "authentication token expired session must refresh"
        let drifted = "the cake recipe needs two cups of flour and sugar"
        let ok = await gate.validate(original: original, compressed: faithful)
        let bad = await gate.validate(original: original, compressed: drifted)
        XCTAssertTrue(ok.accepted)
        XCTAssertFalse(bad.accepted)
    }

    func test_cosineGateFailsOpenOnEncoderError() async {
        let gate = SemanticSimilarityGate(threshold: 0.99, cosine: { _, _ in throw CancellationError() })
        let r = await gate.validate(original: "a b c", compressed: "x y z")
        XCTAssertTrue(r.accepted, "encoder error must fail open to the deterministic gate")
    }

    func test_combinedGateDefersToDeterministicRejectionFirst() async {
        // Deterministic gate rejects a dropped salient 'error' word regardless of cosine.
        let gate = SemanticSimilarityGate(threshold: 0.0, cosine: { _, _ in 1.0 })
        let original = "line one\nfatal error: disk full\nline three"
        let compressed = "line one\nline three"
        let r = await gate.validateCombined(original: original, compressed: compressed)
        XCTAssertFalse(r.accepted)
        XCTAssertEqual(r.reason?.contains("salient"), true)
    }

    // MARK: I9.1 cosine nomination (deterministic diff still decides — I9.2)

    func test_cosineNominatorEnablesNearDupCollapseButDiffStillGates() async {
        // Multi-line block whose ONLY difference is a short volatile timestamp line →
        // the deterministic diff produces a short pointer and allows collapse.
        let body = (1...6)
            .map { "auth session token refresh failed retry backoff handler step \($0)" }
            .joined(separator: "\n")
        let blockA = "started at 2026-06-14T01:00:00Z\n" + body
        let blockB = "started at 2026-06-14T02:30:00Z\n" + body
        let text = blockA + "\n\n" + blockB
        let nominator = await EmbeddingNearDuplicateNominator.make(
            forBlocksIn: text, embed: Self.embed, threshold: 0.9, minBlockChars: 100)
        let nom = try? XCTUnwrap(nominator)
        let result = DistillBlockDeduper.dedupe(text, minBlockChars: 100, nearDuplicateNominator: nom)
        XCTAssertEqual(result.nearDedupedBlocks, 1, "volatile-only diff must collapse via pointer")
        XCTAssertTrue(result.output.contains("⟪same as block #1 above except"))
    }

    func test_cosineNominatorCannotForceUnsafeMerge() async {
        // Two blocks that embed similarly but differ in a load-bearing count → diff must REJECT.
        let stem = String(repeating: "processed records batch worker queue drain commit flush ", count: 8)
        let blockA = stem + "\ntotal processed: 412 records"
        let blockB = stem + "\ntotal processed: 987 records"
        let text = blockA + "\n\n" + blockB
        let nominator = await EmbeddingNearDuplicateNominator.make(
            forBlocksIn: text, embed: Self.embed, threshold: 0.0, minBlockChars: 100) // nominate everything
        let nom = try? XCTUnwrap(nominator)
        let result = DistillBlockDeduper.dedupe(text, minBlockChars: 100, nearDuplicateNominator: nom)
        XCTAssertEqual(result.nearDedupedBlocks, 0, "differing counts are not volatile — deterministic diff must refuse")
        XCTAssertEqual(result.output, text)
    }

    // MARK: I7 / I10.5 / F14 embedding-prototype zero-shot

    func test_prototypeClassifierRoutesAndAbstains() async throws {
        let clf = try await EmbeddingPrototypeClassifier.make(
            labelPrototypes: [
                "test-report": ["3 passed 2 failed", "FAILED test_login assert error", "pytest results summary"],
                "source-code": ["import os def main return value", "func compute() -> Int { return x }"],
                "stack-trace": ["Traceback most recent call line File", "at handler at module at main"],
            ],
            minConfidence: 0.35, minMargin: 0.01, embed: Self.embed)

        let testReport = await clf.classify("2 passed 1 failed assert error in summary")
        XCTAssertEqual(testReport?.label, "test-report")

        let code = await clf.classify("import os def main return value compute")
        XCTAssertEqual(code?.label, "source-code")

        // Garbage / unrelated → abstain (nil), so caller falls through.
        let abstain = await clf.classify("xqz qwerty zzz")
        XCTAssertNil(abstain)
    }
}
