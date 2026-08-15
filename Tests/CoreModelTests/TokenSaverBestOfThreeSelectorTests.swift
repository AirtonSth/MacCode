import CryptoKit
import XCTest
@testable import CoreModel

final class TokenSaverBestOfThreeSelectorTests: XCTestCase {
    typealias Selector = TokenSaverBestOfThreeSelector

    private let human = "canonical Human content"

    func test_rcw1WinsAsUniqueVerifiedStrictMinimum() async {
        let decision = await select(rcw1: 30, rcw1ABI: 10, caveman: 70, cavemanABI: 10, human: 100)

        XCTAssertEqual(decision.selectedFormat, .rcw1)
        XCTAssertEqual(decision.selectedPayload, candidate(.rcw1).payload)
        XCTAssertEqual(decision.reason, .uniqueStrictMinimum)
        XCTAssertEqual(decision.modeledContextDelta, 60)
        XCTAssertFalse(decision.billingClaim)
    }

    func test_cavemanWinsAsUniqueVerifiedStrictMinimum() async {
        let decision = await select(rcw1: 70, rcw1ABI: 10, caveman: 25, cavemanABI: 5, human: 100)

        XCTAssertEqual(decision.selectedFormat, .caveman)
        XCTAssertEqual(decision.selectedPayload, candidate(.caveman).payload)
        XCTAssertEqual(decision.modeledContextDelta, 70)
    }

    func test_humanWinsWhenEveryVerifiedCandidateCostsMore() async {
        let decision = await select(rcw1: 60, rcw1ABI: 10, caveman: 65, cavemanABI: 10, human: 50)

        XCTAssertEqual(decision.selectedFormat, .human)
        XCTAssertEqual(decision.selectedPayload, human)
        XCTAssertEqual(decision.reason, .humanLowestCost)
    }

    func test_anyMinimumTieFallsBackToHuman() async {
        let optimizedTie = await select(
            rcw1: 30, rcw1ABI: 10, caveman: 35, cavemanABI: 5, human: 100
        )
        let humanTie = await select(
            rcw1: 40, rcw1ABI: 10, caveman: 80, cavemanABI: 10, human: 50
        )

        XCTAssertEqual(optimizedTie.reason, .tie)
        XCTAssertEqual(humanTie.reason, .tie)
        XCTAssertEqual(optimizedTie.selectedFormat, .human)
        XCTAssertEqual(humanTie.selectedFormat, .human)
    }

    func test_knownValidationFailureEliminatesOnlyAffectedCandidate() async {
        let semantic = await select(candidates: [
            candidate(.rcw1, semantic: .failed), candidate(.caveman),
        ], rcw1: 10, rcw1ABI: 5, caveman: 25, cavemanABI: 5, human: 100)
        let structural = await select(candidates: [
            candidate(.rcw1, structural: .failed), candidate(.caveman),
        ], rcw1: 10, rcw1ABI: 5, caveman: 25, cavemanABI: 5, human: 100)
        let recovery = await select(candidates: [
            candidate(.rcw1), candidate(.caveman, recovery: .failed),
        ], rcw1: 30, rcw1ABI: 5, caveman: 10, cavemanABI: 5, human: 100)
        let notRequired = await select(candidates: [
            candidate(.rcw1, recovery: .notRequired), candidate(.caveman),
        ], rcw1: 10, rcw1ABI: 5, caveman: 25, cavemanABI: 5, human: 100)

        XCTAssertEqual(semantic.selectedFormat, .caveman)
        XCTAssertEqual(structural.selectedFormat, .caveman)
        XCTAssertEqual(recovery.selectedFormat, .rcw1)
        XCTAssertEqual(notRequired.selectedFormat, .caveman)
        XCTAssertFalse(semantic.arm(.rcw1)!.eligible)
        XCTAssertFalse(recovery.arm(.caveman)!.eligible)
        XCTAssertFalse(notRequired.arm(.rcw1)!.eligible)
    }

    func test_missingOrUncertainCounterFallsBackToHuman() async {
        let candidates = [candidate(.rcw1), candidate(.caveman)]
        let missing = await Selector.select(
            canonicalHuman: human, humanEffectiveEnvelope: human,
            target: target, candidates: candidates, counter: nil
        )
        let uncertain = await Selector.select(
            canonicalHuman: human,
            humanEffectiveEnvelope: human,
            target: target,
            candidates: candidates,
            counter: capability(counts: counts(candidates: candidates), quality: .estimated)
        )

        XCTAssertEqual(missing.reason, .counterUnavailable)
        XCTAssertNil(missing.counter)
        XCTAssertEqual(uncertain.reason, .counterUncertain)
        XCTAssertEqual(uncertain.counter?.quality, .estimated)
    }

    func test_generationErrorOrUnknownGateFallsBackToHuman() async {
        let failed = await select(candidates: [
            candidate(.rcw1, generation: .failed), candidate(.caveman),
        ])
        let unknown = await select(candidates: [
            candidate(.rcw1), candidate(.caveman, semantic: .unknown),
        ])

        XCTAssertEqual(failed.reason, .candidateError)
        XCTAssertEqual(unknown.reason, .candidateUnknown)
    }

    func test_candidatesMustBindToTheSameCanonicalHuman() async {
        let decision = await select(candidates: [
            candidate(.rcw1, sourceSHA256: String(repeating: "0", count: 64)),
            candidate(.caveman),
        ], rcw1: 10, rcw1ABI: 5, caveman: 20, cavemanABI: 5, human: 100)

        XCTAssertEqual(decision.selectedFormat, .caveman)
        XCTAssertFalse(decision.arm(.rcw1)!.sourceBound)
    }

    func test_handleIsDiagnosticAndAlreadyIncludedInPayloadAndEnvelope() async {
        let decision = await select(rcw1: 30, rcw1ABI: 10, caveman: 80, cavemanABI: 10, human: 100)
        let rcw1 = decision.cost(.rcw1)!
        let input = candidate(.rcw1)

        XCTAssertEqual(rcw1.payloadTokensIncludingHandle, 30)
        XCTAssertEqual(rcw1.handleTokens, 7)
        XCTAssertEqual(rcw1.abiTokens, 10)
        XCTAssertEqual(rcw1.effectiveEnvelopeTokens, 40)
        XCTAssertEqual(rcw1.payloadSHA256, sha256(input.payload))
        XCTAssertEqual(rcw1.handleSHA256, sha256(input.handle!))
        XCTAssertEqual(rcw1.effectiveEnvelopeSHA256, sha256(input.effectiveEnvelope))
    }

    func test_rankingUsesOneMeasuredFinalEnvelopeNotAdditiveComponents() async {
        let candidates = [candidate(.rcw1), candidate(.caveman)]
        let probe = CountProbe(counts: counts(
            candidates: candidates,
            rcw1: 10, rcw1ABI: 5, rcw1Effective: 90,
            caveman: 25, cavemanABI: 5, cavemanEffective: 40,
            human: 50
        ))
        let decision = await Selector.select(
            canonicalHuman: human,
            humanEffectiveEnvelope: human,
            target: target,
            candidates: candidates,
            counter: capability(probe: probe)
        )
        let requests = await probe.requests

        XCTAssertEqual(decision.selectedFormat, .caveman)
        XCTAssertEqual(decision.cost(.rcw1)?.effectiveEnvelopeTokens, 90)
        XCTAssertEqual(decision.cost(.caveman)?.effectiveEnvelopeTokens, 40)
        XCTAssertTrue(requests.contains(candidates[0].effectiveEnvelope))
        XCTAssertTrue(requests.contains(candidates[1].effectiveEnvelope))
    }

    func test_humanRankingUsesItsFinalEnvelopeNotItsCanonicalPayload() async {
        let candidates = [candidate(.rcw1), candidate(.caveman)]
        let humanEnvelope = "SYSTEM:baseline\nUSER:\(human)"
        var measured = counts(
            candidates: candidates,
            rcw1: 10, rcw1ABI: 5, rcw1Effective: 50,
            caveman: 20, cavemanABI: 5, cavemanEffective: 60,
            human: 10
        )
        measured[humanEnvelope] = 80
        let probe = CountProbe(counts: measured)

        let decision = await Selector.select(
            canonicalHuman: human,
            humanEffectiveEnvelope: humanEnvelope,
            target: target,
            candidates: candidates,
            counter: capability(probe: probe)
        )
        let requests = await probe.requests

        XCTAssertEqual(decision.selectedFormat, .rcw1)
        XCTAssertEqual(decision.cost(.human)?.payloadTokensIncludingHandle, 10)
        XCTAssertEqual(decision.cost(.human)?.effectiveEnvelopeTokens, 80)
        XCTAssertEqual(decision.cost(.human)?.effectiveEnvelopeSHA256, sha256(humanEnvelope))
        XCTAssertTrue(requests.contains(humanEnvelope))
    }

    func test_counterMustBindEveryIndependentTargetIdentity() async {
        let candidates = [candidate(.rcw1), candidate(.caveman)]
        let counter = capability(counts: counts(candidates: candidates))
        let mismatches: [Selector.Target] = [
            target(provider: "grok"), target(model: "different-model"),
            target(counterID: "other-counter"), target(revision: "2"),
            target(encoding: "other-encoding"),
        ]

        for target in mismatches {
            let decision = await Selector.select(
                canonicalHuman: human, humanEffectiveEnvelope: human, target: target,
                candidates: candidates, counter: counter
            )
            XCTAssertEqual(decision.reason, .counterBindingMismatch)
        }
    }

    func test_declaredHandleMustBeNonWhitespaceAndAppearExactlyOnce() async {
        let valid = candidate(.rcw1)
        let missing = candidate(.rcw1, payload: "RCW1 candidate without marker")
        let repeated = candidate(.rcw1, payload: valid.payload + valid.payload)
        let whitespace = candidate(.rcw1, payload: "RCW1 [[rc:   ]]", handle: "   ")

        for invalid in [missing, repeated, whitespace] {
            let decision = await select(candidates: [invalid, candidate(.caveman)])
            XCTAssertEqual(decision.reason, .candidateError)
            XCTAssertFalse(decision.arm(.rcw1)!.eligible)
        }
    }

    func test_candidateOrderDoesNotChangeDecisionOrReceiptOrder() async {
        let forward = [candidate(.rcw1), candidate(.caveman)]
        let reverse = Array(forward.reversed())
        let first = await select(candidates: forward, rcw1: 30, rcw1ABI: 5,
                                 caveman: 20, cavemanABI: 5, human: 100)
        let second = await select(candidates: reverse, rcw1: 30, rcw1ABI: 5,
                                  caveman: 20, cavemanABI: 5, human: 100)

        XCTAssertEqual(first.receipt, second.receipt)
        XCTAssertEqual(first.arms.map(\.format), [.rcw1, .caveman])
        XCTAssertEqual(first.costs.map(\.format), [.human, .rcw1, .caveman])
    }

    func test_receiptIsCodableWithoutCanonicalOrCandidatePayloads() async throws {
        let decision = await select(rcw1: 30, rcw1ABI: 10, caveman: 80, cavemanABI: 10, human: 100)
        let json = String(decoding: try JSONEncoder().encode(decision.receipt), as: UTF8.self)

        XCTAssertFalse(json.contains(human))
        XCTAssertFalse(json.contains("RCW1 candidate"))
        XCTAssertFalse(json.contains("Caveman candidate"))
        XCTAssertTrue(json.contains("unique_strict_minimum"))
        XCTAssertFalse(decision.receipt.billingClaim)
    }

    func test_counterErrorOrInvalidCountFallsBackToHuman() async {
        let candidates = [candidate(.rcw1), candidate(.caveman)]
        let error = await Selector.select(
            canonicalHuman: human,
            humanEffectiveEnvelope: human,
            target: target,
            candidates: candidates,
            counter: capability(counts: [:])
        )
        var invalidCounts = counts(candidates: candidates)
        invalidCounts[human] = 0
        let invalid = await Selector.select(
            canonicalHuman: human,
            humanEffectiveEnvelope: human,
            target: target,
            candidates: candidates,
            counter: capability(counts: invalidCounts)
        )

        XCTAssertEqual(error.reason, .counterError)
        XCTAssertEqual(invalid.reason, .invalidMeasurement)
        XCTAssertEqual(error.selectedFormat, .human)
        XCTAssertEqual(invalid.selectedFormat, .human)
    }

    private func select(
        candidates: [Selector.Candidate]? = nil,
        rcw1: Int = 30,
        rcw1ABI: Int = 10,
        rcw1Effective: Int? = nil,
        caveman: Int = 60,
        cavemanABI: Int = 10,
        cavemanEffective: Int? = nil,
        human: Int = 100
    ) async -> Selector.Decision {
        let candidates = candidates ?? [candidate(.rcw1), candidate(.caveman)]
        return await Selector.select(
            canonicalHuman: self.human,
            humanEffectiveEnvelope: self.human,
            target: target,
            candidates: candidates,
            counter: capability(counts: counts(
                candidates: candidates,
                rcw1: rcw1, rcw1ABI: rcw1ABI, rcw1Effective: rcw1Effective,
                caveman: caveman, cavemanABI: cavemanABI,
                cavemanEffective: cavemanEffective, human: human
            ))
        )
    }

    private func candidate(
        _ format: Selector.Format,
        sourceSHA256: String? = nil,
        payload: String? = nil,
        handle: String? = nil,
        generation: Selector.GateStatus = .passed,
        structural: Selector.GateStatus = .passed,
        semantic: Selector.GateStatus = .passed,
        recovery: Selector.GateStatus = .passed
    ) -> Selector.Candidate {
        let handle = handle ?? (format == .rcw1 ? "rcv1.handle" : "cave.handle")
        let payload = payload ?? (format == .rcw1
            ? "RCW1 candidate [[rc:\(handle)]]"
            : "Caveman candidate [[ccr:\(handle)]]")
        let abi = format == .rcw1 ? "RCW1 ABI" : "Caveman ABI"
        return .init(
            format: format,
            sourceSHA256: sourceSHA256 ?? sha256(human),
            payload: payload,
            abi: abi,
            effectiveEnvelope: "SYSTEM:\(abi)\nUSER:\(payload)",
            handle: handle,
            producerID: format == .rcw1 ? "remotecode-rcw1" : "caveman",
            producerRevision: "fixture-1",
            abiRevision: "fixture-abi-1",
            generation: generation,
            structural: structural,
            semantic: semantic,
            recovery: recovery
        )
    }

    private func counts(
        candidates: [Selector.Candidate],
        rcw1: Int = 30,
        rcw1ABI: Int = 10,
        rcw1Effective: Int? = nil,
        caveman: Int = 60,
        cavemanABI: Int = 10,
        cavemanEffective: Int? = nil,
        human: Int = 100
    ) -> [String: Int] {
        var result = [self.human: human]
        for candidate in candidates {
            let isRCW1 = candidate.format == .rcw1
            let payload = isRCW1 ? rcw1 : caveman
            let abi = isRCW1 ? rcw1ABI : cavemanABI
            result[candidate.payload] = payload
            result[candidate.handle!] = isRCW1 ? 7 : 6
            result[candidate.abi] = abi
            result[candidate.effectiveEnvelope] = isRCW1
                ? (rcw1Effective ?? payload + abi)
                : (cavemanEffective ?? payload + abi)
        }
        return result
    }

    private func capability(
        counts: [String: Int],
        quality: Selector.CounterQuality = .exactLocalTokenizer
    ) -> Selector.CounterCapability {
        capability(probe: CountProbe(counts: counts), quality: quality)
    }

    private func capability(
        probe: CountProbe,
        quality: Selector.CounterQuality = .exactLocalTokenizer
    ) -> Selector.CounterCapability {
        .init(counter: .init(
            id: "fixture-counter", revision: "1", encoding: "fixture-exact",
            provider: "codex", resolvedModel: "gpt-test", quality: quality
        )) { text in
            try await probe.count(text)
        }
    }

    private var target: Selector.Target { target() }

    private func target(
        provider: String = "codex",
        model: String = "gpt-test",
        counterID: String = "fixture-counter",
        revision: String = "1",
        encoding: String = "fixture-exact"
    ) -> Selector.Target {
        .init(
            provider: provider, resolvedModel: model,
            counterID: counterID, counterRevision: revision, encoding: encoding
        )
    }

    private func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private actor CountProbe {
    private let counts: [String: Int]
    private(set) var requests: [String] = []

    init(counts: [String: Int]) {
        self.counts = counts
    }

    func count(_ text: String) throws -> Int {
        requests.append(text)
        guard let value = counts[text] else { throw CountError.missing }
        return value
    }

    private enum CountError: Error {
        case missing
    }
}
