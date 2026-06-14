import Foundation

public struct TokenSaverBenchmarkCase: Sendable, Equatable {
    public let id: String
    public let original: String
    public let compressed: String
    public let requiredLiterals: [String]

    public init(id: String, original: String, compressed: String, requiredLiterals: [String] = []) {
        self.id = id
        self.original = original
        self.compressed = compressed
        self.requiredLiterals = requiredLiterals
    }
}

public struct TokenSaverBenchmarkRegression: Sendable, Equatable {
    public let caseID: String
    public let reason: String

    public init(caseID: String, reason: String) {
        self.caseID = caseID
        self.reason = reason
    }
}

public struct TokenSaverQualityBenchmarkReport: Sendable, Equatable {
    public let caseCount: Int
    public let regressions: [TokenSaverBenchmarkRegression]
    public let measuredPipeHitRate: Double?
    public let measuredSavingsPercent: Double?
    public let inputTokens: Int
    public let outputTokens: Int

    public init(
        caseCount: Int,
        regressions: [TokenSaverBenchmarkRegression],
        measuredPipeHitRate: Double?,
        measuredSavingsPercent: Double?,
        inputTokens: Int,
        outputTokens: Int
    ) {
        self.caseCount = caseCount
        self.regressions = regressions
        self.measuredPipeHitRate = measuredPipeHitRate
        self.measuredSavingsPercent = measuredSavingsPercent
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct TokenSaverPublicClaimDecision: Sendable, Equatable {
    public let allowed: Bool
    public let reason: String

    public init(allowed: Bool, reason: String) {
        self.allowed = allowed
        self.reason = reason
    }
}

public enum TokenSaverQualityBenchmark {
    public static let minimumPublicCorpusSize = 24

    public static func evaluate(
        cases: [TokenSaverBenchmarkCase],
        measuredPipeHitRate: Double?
    ) -> TokenSaverQualityBenchmarkReport {
        var regressions: [TokenSaverBenchmarkRegression] = []
        var seen = Set<String>()
        var inputTokens = 0
        var outputTokens = 0

        for item in cases {
            if !seen.insert(item.id).inserted {
                regressions.append(TokenSaverBenchmarkRegression(caseID: item.id, reason: "duplicate_case_id"))
            }

            inputTokens += TokenEstimator.estimate(item.original)
            outputTokens += TokenEstimator.estimate(item.compressed)

            let literalGuard = LiteralPreservation.guarded(original: item.original, compressed: item.compressed)
            if let dropped = literalGuard.droppedLiteral {
                regressions.append(TokenSaverBenchmarkRegression(caseID: item.id, reason: "dropped_literal:\(dropped)"))
            }

            let faithfulness = FaithfulnessGate.validate(original: item.original, compressed: item.compressed)
            if let reason = faithfulness.reason {
                regressions.append(TokenSaverBenchmarkRegression(caseID: item.id, reason: "unfaithful:\(reason)"))
            }

            for literal in item.requiredLiterals where !item.compressed.contains(literal) {
                regressions.append(TokenSaverBenchmarkRegression(caseID: item.id, reason: "missing_required_literal:\(literal)"))
            }
        }

        let measuredSavingsPercent: Double?
        if inputTokens > 0, outputTokens < inputTokens {
            measuredSavingsPercent = (Double(inputTokens - outputTokens) / Double(inputTokens)) * 100
        } else {
            measuredSavingsPercent = nil
        }

        return TokenSaverQualityBenchmarkReport(
            caseCount: cases.count,
            regressions: regressions,
            measuredPipeHitRate: measuredPipeHitRate,
            measuredSavingsPercent: measuredSavingsPercent,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }

    public static func publicClaimGate(
        report: TokenSaverQualityBenchmarkReport,
        minimumCorpusSize: Int = minimumPublicCorpusSize
    ) -> TokenSaverPublicClaimDecision {
        guard report.caseCount >= minimumCorpusSize else {
            return TokenSaverPublicClaimDecision(allowed: false, reason: "fixed_corpus_too_small")
        }
        guard report.regressions.isEmpty else {
            return TokenSaverPublicClaimDecision(allowed: false, reason: "fixed_corpus_regression")
        }
        guard let pipeHitRate = report.measuredPipeHitRate, pipeHitRate > 0, pipeHitRate.isFinite else {
            return TokenSaverPublicClaimDecision(allowed: false, reason: "pipe_hit_rate_missing")
        }
        guard let savings = report.measuredSavingsPercent, savings > 0, savings.isFinite else {
            return TokenSaverPublicClaimDecision(allowed: false, reason: "measured_savings_missing")
        }
        return TokenSaverPublicClaimDecision(allowed: true, reason: "measured_corpus_clean")
    }
}
