import XCTest
@testable import DistillCore

final class EncoderLaneTests: XCTestCase {
    func test_encoderManifestRequiresApprovedLicenseRuntimeAndRole() {
        XCTAssertTrue(TokenSaverApprovedEncoderManifests.answerAIColBERTSmall.isApprovedForTokenSaver)

        let bad = TokenSaverEncoderManifest(
            id: "example/bad",
            url: "https://example.invalid/bad",
            revision: "rev",
            runtime: "python",
            role: "generator",
            license: "cc-by-nc",
            maxSeqLen: 512,
            chunkPolicy: "paragraph"
        )
        XCTAssertFalse(bad.isApprovedForTokenSaver)
    }

    func test_encoderLaneRanksWithEmbeddingScorerAndRecordsAccept() async throws {
        let lane = EncoderLane(
            manifest: TokenSaverApprovedEncoderManifests.answerAIColBERTSmall,
            scorer: { _, text in text.contains("session") ? 1.0 : 0.0 }
        )
        let chunks = [
            QueryAwareChunk(id: "token", text: "auth token refresh failed", position: 0),
            QueryAwareChunk(id: "session", text: "auth session expired", position: 1),
        ]

        let maybeRanked = await lane.rank(chunks: chunks, query: "auth problem", topK: 1)
        let ranked = try XCTUnwrap(maybeRanked)
        let metrics = await lane.metricsSnapshot()

        XCTAssertEqual(ranked.first?.chunk.id, "session")
        XCTAssertEqual(metrics.invocations, 1)
        XCTAssertEqual(metrics.accepts, 1)
        XCTAssertEqual(metrics.fallbacks, 0)
    }

    func test_encoderLaneFailOpensWhenScorerUnavailable() async {
        let lane = EncoderLane(
            manifest: TokenSaverApprovedEncoderManifests.answerAIColBERTSmall,
            scorer: nil
        )
        let chunks = [QueryAwareChunk(id: "a", text: "auth token", position: 0)]

        let ranked = await lane.rank(chunks: chunks, query: "auth")
        let metrics = await lane.metricsSnapshot()

        XCTAssertNil(ranked)
        XCTAssertEqual(metrics.invocations, 1)
        XCTAssertEqual(metrics.accepts, 0)
        XCTAssertEqual(metrics.fallbacks, 1)
    }

    func test_encoderLaneFailOpensOnScorerError() async {
        struct TestError: Error {}
        let lane = EncoderLane(
            manifest: TokenSaverApprovedEncoderManifests.answerAIColBERTSmall,
            scorer: { _, _ in throw TestError() }
        )
        let chunks = [QueryAwareChunk(id: "a", text: "auth token", position: 0)]

        let ranked = await lane.rank(chunks: chunks, query: "auth")
        let metrics = await lane.metricsSnapshot()

        XCTAssertNil(ranked)
        XCTAssertEqual(metrics.failures, 1)
        XCTAssertEqual(metrics.fallbacks, 1)
    }
}
