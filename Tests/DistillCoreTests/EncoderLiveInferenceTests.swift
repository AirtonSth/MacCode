import XCTest
@testable import DistillCore

/// REAL encoder inference (C3 / I3.1 / I8.1 / I9.1 / D3). Downloads a small BERT
/// embedder from Hugging Face and runs actual MLX inference on Apple Silicon —
/// no deterministic stand-in. Gated like the live LLM tests; skips loudly.
///
///   REMOTE_CODE_TOKEN_SAVER_LIVE_ENCODER_TEST=1 \
///     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///     swift test --filter EncoderLiveInferenceTests
final class EncoderLiveInferenceTests: XCTestCase {
    private func requireLive() throws {
        guard ProcessInfo.processInfo.environment["REMOTE_CODE_TOKEN_SAVER_LIVE_ENCODER_TEST"] == "1" else {
            throw XCTSkip("Set REMOTE_CODE_TOKEN_SAVER_LIVE_ENCODER_TEST=1 to download bge-micro and run real MLX encoder inference.")
        }
    }

    func test_realEmbeddingCosineSeparatesRelatedFromUnrelated() async throws {
        try requireLive()
        let backend = try MLXEmbeddingBackend(manifest: TokenSaverApprovedEncoderManifests.bgeMicro)
        try await backend.warmup()

        let identical = try await backend.cosine("authentication token expired", "authentication token expired")
        let related = try await backend.cosine("authentication token expired", "the auth session has timed out")
        let unrelated = try await backend.cosine("authentication token expired", "the recipe needs two cups of flour")

        print("REAL-ENCODER cosine identical=\(identical) related=\(related) unrelated=\(unrelated)")
        XCTAssertGreaterThan(identical, 0.99, "identical text must be ~1.0")
        XCTAssertGreaterThan(related, unrelated + 0.10, "related text must score clearly above unrelated")
        XCTAssertGreaterThan(related, 0.4)
    }

    func test_realScorerDrivesEncoderLaneRanking() async throws {
        try requireLive()
        let backend = try MLXEmbeddingBackend(manifest: TokenSaverApprovedEncoderManifests.bgeMicro)
        let lane = EncoderLane(
            manifest: TokenSaverApprovedEncoderManifests.bgeMicro,
            scorer: backend.scoreFn(),
            deadlineMillis: 5_000,
            warmup: { try await backend.warmup() },
            reclaimIdleMemory: { await backend.reclaimIdleMemory() }
        )
        await lane.warmup()

        let chunks = [
            QueryAwareChunk(id: "flour", text: "the recipe needs two cups of flour", position: 0),
            QueryAwareChunk(id: "auth", text: "the auth session token has expired and must refresh", position: 1),
            QueryAwareChunk(id: "weather", text: "it will rain in the afternoon", position: 2),
        ]
        let maybeRanked = await lane.rank(chunks: chunks, query: "why did authentication fail", topK: 3)
        let ranked = try XCTUnwrap(maybeRanked)
        let m = await lane.metricsSnapshot()
        print("REAL-ENCODER lane order=\(ranked.map { $0.chunk.id }) accepts=\(m.accepts) timeouts=\(m.deadlineTimeouts)")
        XCTAssertEqual(ranked.first?.chunk.id, "auth", "real embedding ranking must surface the auth chunk first")
        XCTAssertEqual(m.accepts, 1)
        XCTAssertEqual(m.deadlineTimeouts, 0)
        XCTAssertFalse(m.disabled)
        await lane.reclaimIdleMemory()
    }

    func test_realCosineGateAcceptsFaithfulRejectsDrifted() async throws {
        try requireLive()
        let backend = try MLXEmbeddingBackend(manifest: TokenSaverApprovedEncoderManifests.bgeMicro)
        let gate = SemanticSimilarityGate(threshold: 0.80, cosine: { a, b in try await backend.cosine(a, b) })
        let original = "Build failed: 3 errors in module auth; missing import; undefined symbol login"
        let faithful = "Build failed: 3 errors in auth — missing import, undefined symbol login"
        let drifted = "The weather forecast predicts light rain across the valley tomorrow afternoon"
        let ok = await gate.validate(original: original, compressed: faithful)
        let bad = await gate.validate(original: original, compressed: drifted)
        print("REAL-ENCODER gate faithful=\(ok.accepted) drifted=\(bad.accepted)")
        XCTAssertTrue(ok.accepted)
        XCTAssertFalse(bad.accepted)
    }

    func test_realPrototypeClassifierRoutesContentType() async throws {
        try requireLive()
        let backend = try MLXEmbeddingBackend(manifest: TokenSaverApprovedEncoderManifests.bgeMicro)
        let clf = try await EmbeddingPrototypeClassifier.make(
            labelPrototypes: [
                "test-report": ["test suite results: passed and failed counts with assertion errors"],
                "stack-trace": ["exception traceback with file and line frames calling functions"],
                "source-code": ["a function or class definition with imports and return statements"],
            ],
            minConfidence: 0.2, minMargin: 0.0,
            embed: { try await backend.embed($0) })
        let v = await clf.classify("FAILED tests/test_login.py::test_expired 2 passed 1 failed assert 401 == 200")
        print("REAL-ENCODER classify=\(String(describing: v))")
        XCTAssertEqual(v?.label, "test-report")
    }
}
