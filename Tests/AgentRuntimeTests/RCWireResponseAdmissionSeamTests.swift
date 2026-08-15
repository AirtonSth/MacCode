import CoreModel
import XCTest
@testable import AgentRuntime

final class RCWireResponseAdmissionSeamTests: XCTestCase {
    private let rawWire = "RCW1\tA\t1\nO\tFocused tests passed.\n.\n\n"
    private let human = "Focused tests passed."

    /// WHY: RCW1 A savings cannot be inferred when the host has not injected
    /// an exact pair-counting capability.
    func test_missingPairCounterRejectsExplicitly() async {
        let result = await evaluate()
        XCTAssertEqual(result, .rejected(.pairCounterUnavailable))
    }

    /// WHY: one capability call must bind both lexical counts to the exact
    /// provider/model route. Equality at 45% is valid and every raw byte counts.
    func test_exactPairCounterReceivesResolvedBindingOnceAndAdmitsFortyFivePercentBoundary() async {
        let counter = PairCounterStub(result: .success(receipt(
            provider: .grok,
            resolvedModel: "grok-4.5",
            rawWireLexicalCount: 45,
            deterministicHumanLexicalCount: 100
        )))

        let result = await evaluate(
            provider: .grok,
            resolvedModel: "grok-4.5",
            pairCounter: counter
        )
        guard case .admitted(let admission) = result else {
            return XCTFail("exactly 45% must admit, got \(result)")
        }

        let requests = await counter.recordedRequests()
        XCTAssertEqual(requests.count, 1, "both lexical counts must come from one capability call")
        XCTAssertEqual(requests.first?.provider, .grok)
        XCTAssertEqual(requests.first?.resolvedModel, "grok-4.5")
        XCTAssertEqual(requests.first?.projection.rawWire, rawWire)
        XCTAssertEqual(requests.first?.projection.deterministicHuman, human)
        XCTAssertEqual(admission.projection.rawWire, rawWire)
        XCTAssertEqual(admission.projection.deterministicHuman, human)
        XCTAssertEqual(admission.counterID, "exact-lexical-v1")
        XCTAssertEqual(admission.rawWireLexicalCount, 45)
        XCTAssertEqual(admission.deterministicHumanLexicalCount, 100)
    }

    /// WHY: an unresolved model cannot be rebound by a counter after admission
    /// starts; the caller must supply the immutable resolved model first.
    func test_blankResolvedModelRejectsBeforePairCounting() async {
        let counter = PairCounterStub(result: .success(receipt()))

        let result = await evaluate(resolvedModel: " \t\n", pairCounter: counter)

        XCTAssertEqual(result, .rejected(.invalidResolvedModel))
        let requests = await counter.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    /// WHY: estimated or unknown-quality counts cannot authorize a response
    /// claim even when their integers look favorable.
    func test_nonExactQualityRejectsExplicitly() async {
        for quality in [
            RCWireResponseAdmissionSeam.CountQuality.estimated,
            .unknown
        ] {
            let counter = PairCounterStub(result: .success(receipt(quality: quality)))
            let result = await evaluate(pairCounter: counter)
            XCTAssertEqual(result, .rejected(.countQualityNotExactLexical(quality)))
        }
    }

    /// WHY: a receipt from a rerouted provider or model is not evidence for the
    /// requested immutable binding.
    func test_receiptProviderOrResolvedModelMismatchRejectsExplicitly() async {
        for receiptBinding in [
            (provider: AgentProvider.grok, model: "gpt-5.6"),
            (provider: AgentProvider.codex, model: "gpt-5.5")
        ] {
            let counter = PairCounterStub(result: .success(receipt(
                provider: receiptBinding.provider,
                resolvedModel: receiptBinding.model
            )))
            let result = await evaluate(pairCounter: counter)
            XCTAssertEqual(result, .rejected(.counterBindingMismatch))
        }
    }

    /// WHY: no receipt is no exact proof; it must remain distinguishable from
    /// an unavailable capability and a thrown counter failure.
    func test_nilPairReceiptRejectsExplicitly() async {
        let counter = PairCounterStub(result: .success(nil))
        let result = await evaluate(pairCounter: counter)
        XCTAssertEqual(result, .rejected(.pairCountUnavailable))
    }

    /// WHY: network, authentication, or tokenizer errors cannot silently turn
    /// into an admitted response claim.
    func test_pairCounterErrorRejectsExplicitly() async {
        let counter = PairCounterStub(result: .failure(.unavailable))
        let result = await evaluate(pairCounter: counter)
        XCTAssertEqual(result, .rejected(.pairCounterFailed))
    }

    /// WHY: integer wraparound must never turn an unprovable ratio into an
    /// admitted response claim.
    func test_ratioArithmeticOverflowRejectsExplicitly() async {
        let counter = PairCounterStub(result: .success(receipt(
            rawWireLexicalCount: .max,
            deterministicHumanLexicalCount: .max
        )))
        let result = await evaluate(pairCounter: counter)
        XCTAssertEqual(result, .rejected(.tokenRatioOverflow))
    }

    /// WHY: RCW1 A is admitted only when the complete frame is no more than
    /// 45% of its deterministic Human projection.
    func test_aboveFortyFivePercentRejectsExplicitly() async {
        let counter = PairCounterStub(result: .success(receipt(
            rawWireLexicalCount: 46,
            deterministicHumanLexicalCount: 100
        )))
        let result = await evaluate(pairCounter: counter)
        XCTAssertEqual(result, .rejected(.aboveMaximumTokenRatio))
    }

    /// WHY: an empty or whitespace-only counter identity or nonpositive count cannot be
    /// interpreted as exact lexical proof.
    func test_invalidExactReceiptRejectsExplicitly() async {
        let cases: [
            (receipt: RCWireResponseAdmissionSeam.PairCountReceipt,
             rejection: RCWireResponseAdmissionSeam.Rejection)
        ] = [
            (receipt(counterID: ""), .invalidCounterID),
            (receipt(counterID: " \t\n"), .invalidCounterID),
            (receipt(rawWireLexicalCount: 0), .invalidLexicalCount)
        ]

        for item in cases {
            let counter = PairCounterStub(result: .success(item.receipt))
            let result = await evaluate(pairCounter: counter)
            XCTAssertEqual(result, .rejected(item.rejection))
        }
    }

    /// WHY: the economic seam must inherit byte-zero RCW1 A validation rather
    /// than rescuing a BOM or provider prose preamble.
    func test_nonByteZeroWireRejectsBeforeCounting() async {
        let counter = PairCounterStub(result: .success(receipt()))

        let result = await evaluate(
            rawResponse: "\u{FEFF}" + rawWire,
            pairCounter: counter
        )

        XCTAssertEqual(result, .rejected(.invalidResponse))
        let requests = await counter.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    private func evaluate(
        rawResponse: String? = nil,
        provider: AgentProvider = .codex,
        resolvedModel: String = "gpt-5.6",
        pairCounter: (any RCWireResponseAdmissionSeam.PairCounting)? = nil
    ) async -> RCWireResponseAdmissionSeam.Decision {
        await RCWireResponseAdmissionSeam.evaluate(
            rawResponse: rawResponse ?? rawWire,
            provider: provider,
            resolvedModel: resolvedModel,
            pairCounter: pairCounter
        )
    }

    private func receipt(
        counterID: String = "exact-lexical-v1",
        quality: RCWireResponseAdmissionSeam.CountQuality = .exactLexical,
        provider: AgentProvider = .codex,
        resolvedModel: String = "gpt-5.6",
        rawWireLexicalCount: Int = 1,
        deterministicHumanLexicalCount: Int = 100
    ) -> RCWireResponseAdmissionSeam.PairCountReceipt {
        .init(
            counterID: counterID,
            quality: quality,
            provider: provider,
            resolvedModel: resolvedModel,
            rawWireLexicalCount: rawWireLexicalCount,
            deterministicHumanLexicalCount: deterministicHumanLexicalCount
        )
    }
}

private actor PairCounterStub: RCWireResponseAdmissionSeam.PairCounting {
    enum Failure: Error, Sendable {
        case unavailable
    }

    private let result: Result<RCWireResponseAdmissionSeam.PairCountReceipt?, Failure>
    private var requests: [RCWireResponseAdmissionSeam.PairCountRequest] = []

    init(result: Result<RCWireResponseAdmissionSeam.PairCountReceipt?, Failure>) {
        self.result = result
    }

    func countPair(
        _ request: RCWireResponseAdmissionSeam.PairCountRequest
    ) async throws -> RCWireResponseAdmissionSeam.PairCountReceipt? {
        requests.append(request)
        return try result.get()
    }

    func recordedRequests() -> [RCWireResponseAdmissionSeam.PairCountRequest] {
        requests
    }
}
