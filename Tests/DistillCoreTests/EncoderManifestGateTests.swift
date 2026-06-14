import XCTest
@testable import DistillCore

/// I3.2 / V2 / K6: structural license + immutable-revision hard-gate. Permissive
/// licenses only; NC/OpenRAIL rejected; download requires a pinned commit SHA.
final class EncoderManifestGateTests: XCTestCase {
    func test_permissiveLicensesApproved() {
        XCTAssertTrue(TokenSaverApprovedEncoderManifests.bgeSmallEN.isApprovedForTokenSaver)   // MIT
        XCTAssertTrue(TokenSaverApprovedEncoderManifests.miniLML6.isApprovedForTokenSaver)     // Apache-2.0
        XCTAssertTrue(TokenSaverApprovedEncoderManifests.answerAIColBERTSmall.isApprovedForTokenSaver)
    }

    func test_nonCommercialAndOpenRailRejected() {
        for bad in ["cc-by-nc-4.0", "cc-by-nc-nd-4.0", "openrail", "bigscience-openrail-m", "gpl-3.0"] {
            let m = TokenSaverEncoderManifest(
                id: "x/y", url: "https://huggingface.co/x/y",
                revision: "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a",
                runtime: "mlx-embedders", role: "embedder",
                license: bad, maxSeqLen: 512, chunkPolicy: "paragraph")
            XCTAssertFalse(m.isApprovedForTokenSaver, "\(bad) must be rejected by the license gate")
            XCTAssertFalse(m.isApprovedForDownload)
        }
    }

    func test_placeholderRevisionNotDownloadApprovedButRealSHAIs() {
        // answerai/modernbert manifests still carry the placeholder revision → usable
        // for the gate but NOT downloadable.
        XCTAssertTrue(TokenSaverApprovedEncoderManifests.answerAIColBERTSmall.isApprovedForTokenSaver)
        XCTAssertFalse(TokenSaverApprovedEncoderManifests.answerAIColBERTSmall.hasImmutableRevision)
        XCTAssertFalse(TokenSaverApprovedEncoderManifests.answerAIColBERTSmall.isApprovedForDownload)

        // bge-small carries a real 40-hex SHA → download-approved.
        XCTAssertTrue(TokenSaverApprovedEncoderManifests.bgeSmallEN.hasImmutableRevision)
        XCTAssertTrue(TokenSaverApprovedEncoderManifests.bgeSmallEN.isApprovedForDownload)
    }

    func test_branchHeadRevisionRejectedForDownload() {
        let m = TokenSaverEncoderManifest(
            id: "BAAI/bge-small-en-v1.5", url: "https://huggingface.co/BAAI/bge-small-en-v1.5",
            revision: "main", runtime: "mlx-embedders", role: "embedder",
            license: "MIT", maxSeqLen: 512, chunkPolicy: "paragraph")
        XCTAssertFalse(m.hasImmutableRevision, "a branch head is not an immutable pin")
        XCTAssertFalse(m.isApprovedForDownload)
    }

    func test_backendOnlyMapsRunnableModels() throws {
        // Real MLXEmbedders configs exist for these.
        XCTAssertNotNil(MLXEmbeddingBackend.embedderConfiguration(forID: "BAAI/bge-small-en-v1.5"))
        XCTAssertNotNil(MLXEmbeddingBackend.embedderConfiguration(forID: "TaylorAI/bge-micro-v2"))
        // ModernBERT/ColBERT arch is not in MLXEmbedders → unmapped (must not pretend to run).
        XCTAssertNil(MLXEmbeddingBackend.embedderConfiguration(forID: "answerdotai/answerai-colbert-small-v1"))
        XCTAssertThrowsError(try MLXEmbeddingBackend(manifest: TokenSaverApprovedEncoderManifests.answerAIColBERTSmall))
    }
}
