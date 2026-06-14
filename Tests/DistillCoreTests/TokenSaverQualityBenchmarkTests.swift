import XCTest
@testable import DistillCore

final class TokenSaverQualityBenchmarkTests: XCTestCase {
    func test_publicQualityClaimRequiresCleanFixedCorpusWithMeasuredSavingsAndPipeHitRate() {
        let report = TokenSaverQualityBenchmark.evaluate(cases: corpus(), measuredPipeHitRate: 0.31)

        XCTAssertEqual(report.caseCount, 24)
        XCTAssertEqual(report.regressions, [])
        XCTAssertGreaterThan(report.measuredSavingsPercent ?? 0, 0)
        XCTAssertGreaterThan(report.inputTokens, report.outputTokens)
        XCTAssertEqual(
            TokenSaverQualityBenchmark.publicClaimGate(report: report),
            TokenSaverPublicClaimDecision(allowed: true, reason: "measured_corpus_clean")
        )
    }

    func test_publicQualityClaimBlocksSmallCorpus() {
        let report = TokenSaverQualityBenchmark.evaluate(cases: corpus(count: 23), measuredPipeHitRate: 0.31)

        XCTAssertEqual(
            TokenSaverQualityBenchmark.publicClaimGate(report: report),
            TokenSaverPublicClaimDecision(allowed: false, reason: "fixed_corpus_too_small")
        )
    }

    func test_publicQualityClaimBlocksDroppedLiteralRegression() {
        var cases = corpus()
        cases[3] = TokenSaverBenchmarkCase(
            id: "case-04",
            original: originalCase(index: 4),
            compressed: "ERROR code 5004.",
            requiredLiterals: ["Sources/App/File4.swift:204"]
        )

        let report = TokenSaverQualityBenchmark.evaluate(cases: cases, measuredPipeHitRate: 0.31)

        XCTAssertTrue(report.regressions.contains { regression in
            regression.caseID == "case-04" && regression.reason.hasPrefix("dropped_literal:")
        })
        XCTAssertEqual(
            TokenSaverQualityBenchmark.publicClaimGate(report: report),
            TokenSaverPublicClaimDecision(allowed: false, reason: "fixed_corpus_regression")
        )
    }

    func test_publicQualityClaimBlocksWhenPipeHitRateIsNotMeasured() {
        let report = TokenSaverQualityBenchmark.evaluate(cases: corpus(), measuredPipeHitRate: nil)

        XCTAssertEqual(
            TokenSaverQualityBenchmark.publicClaimGate(report: report),
            TokenSaverPublicClaimDecision(allowed: false, reason: "pipe_hit_rate_missing")
        )
    }

    func test_publicQualityClaimBlocksWhenSavingsAreNotMeasuredPositive() {
        let cases = (1...24).map { index in
            TokenSaverBenchmarkCase(
                id: "case-\(String(format: "%02d", index))",
                original: originalCase(index: index),
                compressed: originalCase(index: index),
                requiredLiterals: ["Sources/App/File\(index).swift:\(200 + index)"]
            )
        }
        let report = TokenSaverQualityBenchmark.evaluate(cases: cases, measuredPipeHitRate: 0.31)

        XCTAssertNil(report.measuredSavingsPercent)
        XCTAssertEqual(
            TokenSaverQualityBenchmark.publicClaimGate(report: report),
            TokenSaverPublicClaimDecision(allowed: false, reason: "measured_savings_missing")
        )
    }

    private func corpus(count: Int = 24) -> [TokenSaverBenchmarkCase] {
        (1...count).map { index in
            TokenSaverBenchmarkCase(
                id: "case-\(String(format: "%02d", index))",
                original: originalCase(index: index),
                compressed: firstLine(index: index),
                requiredLiterals: [
                    "Sources/App/File\(index).swift:\(200 + index)",
                    "code \(5000 + index)"
                ]
            )
        }
    }

    private func originalCase(index: Int) -> String {
        """
        \(firstLine(index: index))
        Preserve the stack frame, numeric code, and the failing file location.
        Extra debug context repeated repeated repeated repeated repeated repeated repeated repeated.
        """
    }

    private func firstLine(index: Int) -> String {
        "ERROR test case \(index) failed at Sources/App/File\(index).swift:\(200 + index) with code \(5000 + index)."
    }
}
