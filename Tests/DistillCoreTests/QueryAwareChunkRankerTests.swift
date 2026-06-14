import XCTest
@testable import DistillCore

final class QueryAwareChunkRankerTests: XCTestCase {
    func test_bm25RanksQueryAndToolArgumentsTogether() {
        let ranker = QueryAwareChunkRanker()
        let chunks = [
            QueryAwareChunk(id: "noise", text: "startup complete", position: 0),
            QueryAwareChunk(id: "target", text: "checkout payment error in BillingService", contentType: .buildOutput, position: 1),
            QueryAwareChunk(id: "tail", text: "all done", position: 2),
        ]

        let ranked = ranker.rank(chunks: chunks, query: "why did checkout fail", toolArguments: "BillingService")

        XCTAssertEqual(ranked.first?.chunk.id, "target")
        XCTAssertGreaterThan(ranked.first?.bm25Score ?? 0, 0)
    }

    func test_embeddingTieBreakerCanPromoteSemanticMatch() {
        let ranker = QueryAwareChunkRanker(hybridAlpha: 0.50)
        let chunks = [
            QueryAwareChunk(id: "a", text: "auth token refresh failed", position: 0),
            QueryAwareChunk(id: "b", text: "auth login session expired", position: 1),
        ]

        let ranked = ranker.rank(chunks: chunks, query: "auth problem", embeddingScore: { _, text in
            text.contains("session") ? 1.0 : 0.0
        })

        XCTAssertEqual(ranked.first?.chunk.id, "b")
        XCTAssertEqual(ranked.first?.embeddingScore, 1.0)
    }

    func test_contentTypeAndPositionBoostAreDeterministicTieBreakers() {
        let ranker = QueryAwareChunkRanker(hybridAlpha: 0)
        let chunks = [
            QueryAwareChunk(id: "prose", text: "payment failed", contentType: .prose, position: 5),
            QueryAwareChunk(id: "build", text: "payment failed", contentType: .buildOutput, position: 6),
        ]

        let ranked = ranker.rank(chunks: chunks, query: "payment failed")

        XCTAssertEqual(ranked.first?.chunk.id, "build")
        XCTAssertGreaterThan(ranked[0].finalScore, ranked[1].finalScore)
    }
}
