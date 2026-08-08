import Foundation

public enum TokenSaverImageRouterDisposition: String, Codable, Sendable, Equatable {
    case noImageSurface
    case auditOnly
    case eligibleForRouter
}

public struct TokenSaverImageSurfaceSample: Codable, Sendable, Equatable {
    public let textInputTokens: Int
    public let imageAttachmentCount: Int
    public let estimatedImageTokens: Int

    public init(textInputTokens: Int, imageAttachmentCount: Int, estimatedImageTokens: Int) {
        self.textInputTokens = max(0, textInputTokens)
        self.imageAttachmentCount = max(0, imageAttachmentCount)
        self.estimatedImageTokens = max(0, estimatedImageTokens)
    }
}

public struct TokenSaverImageSurfaceAuditSummary: Codable, Sendable, Equatable {
    public let sampleCount: Int
    public let imageAttachmentCount: Int
    public let textInputTokens: Int
    public let estimatedImageTokens: Int

    public init(
        sampleCount: Int,
        imageAttachmentCount: Int,
        textInputTokens: Int,
        estimatedImageTokens: Int
    ) {
        self.sampleCount = max(0, sampleCount)
        self.imageAttachmentCount = max(0, imageAttachmentCount)
        self.textInputTokens = max(0, textInputTokens)
        self.estimatedImageTokens = max(0, estimatedImageTokens)
    }

    public var totalEstimatedTokens: Int {
        textInputTokens + estimatedImageTokens
    }

    public var imageTokenShare: Double {
        guard totalEstimatedTokens > 0 else { return 0 }
        return Double(estimatedImageTokens) / Double(totalEstimatedTokens)
    }
}

public struct TokenSaverImageRouterDecision: Codable, Sendable, Equatable {
    public let disposition: TokenSaverImageRouterDisposition
    public let reason: String

    public init(disposition: TokenSaverImageRouterDisposition, reason: String) {
        self.disposition = disposition
        self.reason = reason
    }
}

public enum TokenSaverImageSurfaceAudit {
    public static let minimumMeasuredSamples = 24
    public static let minimumImageTokenShare = 0.10

    public static func sample(
        prompt: String,
        attachments: [AgentAttachment],
        estimatedTokensPerImage: Int = 1_000
    ) -> TokenSaverImageSurfaceSample {
        let imageCount = attachments.filter { $0.kind == .image }.count
        return TokenSaverImageSurfaceSample(
            textInputTokens: estimateTextTokens(prompt),
            imageAttachmentCount: imageCount,
            estimatedImageTokens: imageCount * max(0, estimatedTokensPerImage)
        )
    }

    public static func summarize(_ samples: [TokenSaverImageSurfaceSample]) -> TokenSaverImageSurfaceAuditSummary {
        TokenSaverImageSurfaceAuditSummary(
            sampleCount: samples.count,
            imageAttachmentCount: samples.reduce(0) { $0 + $1.imageAttachmentCount },
            textInputTokens: samples.reduce(0) { $0 + $1.textInputTokens },
            estimatedImageTokens: samples.reduce(0) { $0 + $1.estimatedImageTokens }
        )
    }

    public static func decision(
        summary: TokenSaverImageSurfaceAuditSummary,
        minimumSamples: Int = minimumMeasuredSamples,
        minimumImageTokenShare: Double = minimumImageTokenShare
    ) -> TokenSaverImageRouterDecision {
        guard summary.imageAttachmentCount > 0 else {
            return TokenSaverImageRouterDecision(disposition: .noImageSurface, reason: "no_image_attachments")
        }
        guard summary.sampleCount >= minimumSamples else {
            return TokenSaverImageRouterDecision(disposition: .auditOnly, reason: "image_surface_under_measured_sample_floor")
        }
        guard summary.imageTokenShare >= minimumImageTokenShare else {
            return TokenSaverImageRouterDecision(disposition: .auditOnly, reason: "image_surface_below_token_share_threshold")
        }
        return TokenSaverImageRouterDecision(disposition: .eligibleForRouter, reason: "image_surface_measured")
    }

    /// Same estimator shape as DistillCore.TokenEstimator (CoreModel cannot import
    /// DistillCore). PERF: O(1) utf8 size + single-pass word count (no grapheme
    /// walk / Substring array from split).
    private static func estimateTextTokens(_ text: String) -> Int {
        let chars = text.utf8.count
        guard chars > 0 else { return 0 }
        let byChars = Int((Double(chars) / 4.0).rounded())
        var words = 0
        var inWord = false
        for byte in text.utf8 {
            switch byte {
            case 0x20, 0x0A, 0x09, 0x0D:
                inWord = false
            default:
                if !inWord {
                    inWord = true
                    words += 1
                }
            }
        }
        let byWords = Int((Double(words) * 1.3).rounded())
        return max(1, max(byChars, byWords))
    }
}
