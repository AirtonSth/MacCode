import XCTest
@testable import CoreModel

final class TokenSaverImageSurfaceAuditTests: XCTestCase {
    func test_sampleCountsOnlyImageAttachmentsAndEstimatesPromptTokens() {
        let sample = TokenSaverImageSurfaceAudit.sample(
            prompt: "inspect this screenshot",
            attachments: [
                AgentAttachment(path: "/tmp/screen.png", kind: .image, mimeType: "image/png"),
                AgentAttachment(path: "/tmp/log.txt", kind: .file, mimeType: "text/plain")
            ],
            estimatedTokensPerImage: 900
        )

        XCTAssertEqual(sample.imageAttachmentCount, 1)
        XCTAssertEqual(sample.estimatedImageTokens, 900)
        XCTAssertGreaterThan(sample.textInputTokens, 0)
    }

    func test_decisionKeepsImageRouterAuditOnlyUntilEnoughMeasuredSamplesExist() {
        let summary = TokenSaverImageSurfaceAudit.summarize(Array(repeating: imageHeavySample(), count: 23))

        XCTAssertEqual(
            TokenSaverImageSurfaceAudit.decision(summary: summary),
            TokenSaverImageRouterDecision(disposition: .auditOnly, reason: "image_surface_under_measured_sample_floor")
        )
    }

    func test_decisionKeepsImageRouterAuditOnlyWhenMeasuredShareIsLow() {
        let samples = Array(repeating: TokenSaverImageSurfaceSample(textInputTokens: 10_000, imageAttachmentCount: 1, estimatedImageTokens: 100), count: 24)
        let summary = TokenSaverImageSurfaceAudit.summarize(samples)

        XCTAssertEqual(
            TokenSaverImageSurfaceAudit.decision(summary: summary),
            TokenSaverImageRouterDecision(disposition: .auditOnly, reason: "image_surface_below_token_share_threshold")
        )
    }

    func test_decisionAllowsRouterOnlyAfterMeasuredVolumeJustifiesIt() {
        let summary = TokenSaverImageSurfaceAudit.summarize(Array(repeating: imageHeavySample(), count: 24))

        XCTAssertEqual(
            TokenSaverImageSurfaceAudit.decision(summary: summary),
            TokenSaverImageRouterDecision(disposition: .eligibleForRouter, reason: "image_surface_measured")
        )
    }

    func test_decisionSkipsWhenNoImageSurfaceExists() {
        let summary = TokenSaverImageSurfaceAudit.summarize([
            TokenSaverImageSurfaceSample(textInputTokens: 500, imageAttachmentCount: 0, estimatedImageTokens: 0)
        ])

        XCTAssertEqual(
            TokenSaverImageSurfaceAudit.decision(summary: summary),
            TokenSaverImageRouterDecision(disposition: .noImageSurface, reason: "no_image_attachments")
        )
    }

    private func imageHeavySample() -> TokenSaverImageSurfaceSample {
        TokenSaverImageSurfaceSample(textInputTokens: 500, imageAttachmentCount: 1, estimatedImageTokens: 1_000)
    }
}
