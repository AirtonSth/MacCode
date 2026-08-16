import CryptoKit
import XCTest
@testable import CoreModel

final class TokenSaverBestOfThreeSelectorTests: XCTestCase {
    typealias Selector = TokenSaverBestOfThreeSelector

    private let human = "canonical Human content"

    func test_rcw1WinsAsUniqueVerifiedStrictMinimum() async {
        let decision = await select(rcw1: 30, rcw1ABI: 10, rcs1: 70, rcs1ABI: 10, human: 100)

        XCTAssertEqual(decision.selectedFormat, .rcw1)
        XCTAssertEqual(decision.selectedPayload, candidate(.rcw1).payload)
        XCTAssertEqual(decision.reason, .uniqueStrictMinimum)
        XCTAssertEqual(decision.modeledContextDelta, 60)
        XCTAssertFalse(decision.billingClaim)
    }

    func test_rcs1WinsAsUniqueVerifiedStrictMinimum() async {
        let decision = await select(rcw1: 70, rcw1ABI: 10, rcs1: 25, rcs1ABI: 5, human: 100)

        XCTAssertEqual(decision.selectedFormat, .rcs1)
        XCTAssertEqual(decision.selectedPayload, candidate(.rcs1).payload)
        XCTAssertEqual(decision.modeledContextDelta, 70)
    }

    func test_threeFormatsAreExactlyHumanRCW1RCS1() {
        XCTAssertEqual(Selector.Format.allCases, [.human, .rcw1, .rcs1])
    }

    func test_disabledRCS1FailedGatesDoNotPoisonEligibleRCW1() async {
        // WHY: production RCS1 is present but unavailable. A cheaper ineligible
        // RCS1 arm with failed generation must not abort the whole decision or
        // an otherwise valid RCW1 winner is lost.
        let disabled = Selector.Candidate(
            format: .rcs1,
            sourceSHA256: sha256(human),
            payload: "RCS1_RUNTIME_UNAVAILABLE",
            abi: "RCS1_ABI_UNAVAILABLE",
            effectiveEnvelope: "RCS1_ABI_UNAVAILABLE\nRCS1_RUNTIME_UNAVAILABLE",
            handle: nil,
            producerID: TokenSaverRequestSelectionReceipt.rcs1UnavailableProducerID,
            producerRevision: "unavailable",
            abiRevision: "unavailable",
            generation: .failed,
            structural: .failed,
            semantic: .failed,
            recovery: .failed
        )
        let decision = await select(
            candidates: [candidate(.rcw1), disabled],
            rcw1: 30, rcw1ABI: 10, rcs1: 5, rcs1ABI: 1, human: 100
        )

        XCTAssertEqual(decision.selectedFormat, .rcw1)
        XCTAssertEqual(decision.reason, .uniqueStrictMinimum)
        XCTAssertEqual(decision.selectedPayload, candidate(.rcw1).payload)
        XCTAssertTrue(decision.arm(.rcw1)!.eligible)
        XCTAssertFalse(decision.arm(.rcs1)!.eligible)
        XCTAssertEqual(decision.arm(.rcs1)!.generation, .failed)
        XCTAssertEqual(
            decision.arm(.rcs1)!.producerID,
            TokenSaverRequestSelectionReceipt.rcs1UnavailableProducerID
        )
    }

    func test_humanWinsWhenEveryVerifiedCandidateCostsMore() async {
        let decision = await select(rcw1: 60, rcw1ABI: 10, rcs1: 65, rcs1ABI: 10, human: 50)

        XCTAssertEqual(decision.selectedFormat, .human)
        XCTAssertEqual(decision.selectedPayload, human)
        XCTAssertEqual(decision.reason, .humanLowestCost)
    }

    func test_humanWinUsesOutboundPromptNotCanonicalBytes() async {
        // WHY: Human ranking and the provider-bound payload are the outbound
        // prompt. Canonical Human is only the source identity, never the
        // selected bytes when that outbound identity is valid.
        let candidates = [candidate(.rcw1), candidate(.rcs1)]
        let humanOutbound = "AUTO:\(human)"
        let humanEnvelope = "SYSTEM:baseline\nUSER:\(humanOutbound)"
        var measured = counts(
            candidates: candidates,
            rcw1: 60, rcw1ABI: 10, rcw1Effective: 80,
            rcs1: 65, rcs1ABI: 10, rcs1Effective: 85,
            human: 90
        )
        measured[humanOutbound] = 40
        measured[humanEnvelope] = 50

        let decision = await Selector.select(
            canonicalHuman: human,
            humanOutboundPrompt: humanOutbound,
            humanEffectiveEnvelope: humanEnvelope,
            target: target,
            candidates: candidates,
            counter: capability(counts: measured)
        )

        XCTAssertEqual(decision.selectedFormat, .human)
        XCTAssertEqual(decision.selectedPayload, humanOutbound)
        XCTAssertNotEqual(decision.selectedPayload, human)
        XCTAssertEqual(decision.reason, .humanLowestCost)
    }

    func test_anyMinimumTieFallsBackToHuman() async {
        let optimizedTie = await select(
            rcw1: 30, rcw1ABI: 10, rcs1: 35, rcs1ABI: 5, human: 100
        )
        let humanTie = await select(
            rcw1: 40, rcw1ABI: 10, rcs1: 80, rcs1ABI: 10, human: 50
        )

        XCTAssertEqual(optimizedTie.reason, .tie)
        XCTAssertEqual(humanTie.reason, .tie)
        XCTAssertEqual(optimizedTie.selectedFormat, .human)
        XCTAssertEqual(humanTie.selectedFormat, .human)
    }

    func test_knownValidationFailureEliminatesOnlyAffectedCandidate() async {
        let semantic = await select(candidates: [
            candidate(.rcw1, semantic: .failed), candidate(.rcs1),
        ], rcw1: 10, rcw1ABI: 5, rcs1: 25, rcs1ABI: 5, human: 100)
        let structural = await select(candidates: [
            candidate(.rcw1, structural: .failed), candidate(.rcs1),
        ], rcw1: 10, rcw1ABI: 5, rcs1: 25, rcs1ABI: 5, human: 100)
        let recovery = await select(candidates: [
            candidate(.rcw1), candidate(.rcs1, recovery: .failed),
        ], rcw1: 30, rcw1ABI: 5, rcs1: 10, rcs1ABI: 5, human: 100)
        let notRequired = await select(candidates: [
            candidate(.rcw1, recovery: .notRequired), candidate(.rcs1),
        ], rcw1: 10, rcw1ABI: 5, rcs1: 25, rcs1ABI: 5, human: 100)

        XCTAssertEqual(semantic.selectedFormat, .rcs1)
        XCTAssertEqual(structural.selectedFormat, .rcs1)
        XCTAssertEqual(recovery.selectedFormat, .rcw1)
        XCTAssertEqual(notRequired.selectedFormat, .rcs1)
        XCTAssertFalse(semantic.arm(.rcw1)!.eligible)
        XCTAssertFalse(recovery.arm(.rcs1)!.eligible)
        XCTAssertFalse(notRequired.arm(.rcw1)!.eligible)
    }

    func test_missingOrUncertainCounterFallsBackToHuman() async {
        let candidates = [candidate(.rcw1), candidate(.rcs1)]
        let missing = await Selector.select(
            canonicalHuman: human, humanOutboundPrompt: human, humanEffectiveEnvelope: human,
            target: target, candidates: candidates, counter: nil
        )
        let uncertain = await Selector.select(
            canonicalHuman: human,
            humanOutboundPrompt: human,
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
            candidate(.rcw1, generation: .failed), candidate(.rcs1),
        ])
        let unknown = await select(candidates: [
            candidate(.rcw1), candidate(.rcs1, semantic: .unknown),
        ])

        XCTAssertEqual(failed.reason, .candidateError)
        XCTAssertEqual(unknown.reason, .candidateUnknown)
    }

    func test_candidatesMustBindToTheSameCanonicalHuman() async {
        let decision = await select(candidates: [
            candidate(.rcw1, sourceSHA256: String(repeating: "0", count: 64)),
            candidate(.rcs1),
        ], rcw1: 10, rcw1ABI: 5, rcs1: 20, rcs1ABI: 5, human: 100)

        XCTAssertEqual(decision.selectedFormat, .rcs1)
        XCTAssertFalse(decision.arm(.rcw1)!.sourceBound)
    }

    func test_handleIsDiagnosticAndAlreadyIncludedInPayloadAndEnvelope() async {
        let decision = await select(rcw1: 30, rcw1ABI: 10, rcs1: 80, rcs1ABI: 10, human: 100)
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
        let candidates = [candidate(.rcw1), candidate(.rcs1)]
        let probe = CountProbe(counts: counts(
            candidates: candidates,
            rcw1: 10, rcw1ABI: 5, rcw1Effective: 90,
            rcs1: 25, rcs1ABI: 5, rcs1Effective: 40,
            human: 50
        ))
        let decision = await Selector.select(
            canonicalHuman: human,
            humanOutboundPrompt: human,
            humanEffectiveEnvelope: human,
            target: target,
            candidates: candidates,
            counter: capability(probe: probe)
        )
        let requests = await probe.requests

        XCTAssertEqual(decision.selectedFormat, .rcs1)
        XCTAssertEqual(decision.cost(.rcw1)?.effectiveEnvelopeTokens, 90)
        XCTAssertEqual(decision.cost(.rcs1)?.effectiveEnvelopeTokens, 40)
        XCTAssertTrue(requests.contains(candidates[0].effectiveEnvelope))
        XCTAssertTrue(requests.contains(candidates[1].effectiveEnvelope))
    }

    func test_humanRankingUsesItsFinalEnvelopeNotItsCanonicalPayload() async {
        let candidates = [candidate(.rcw1), candidate(.rcs1)]
        let humanOutbound = "AUTO:\(human)"
        let humanEnvelope = "SYSTEM:baseline\nUSER:\(humanOutbound)"
        var measured = counts(
            candidates: candidates,
            rcw1: 10, rcw1ABI: 5, rcw1Effective: 50,
            rcs1: 20, rcs1ABI: 5, rcs1Effective: 60,
            human: 10
        )
        measured[humanOutbound] = 12
        measured[humanEnvelope] = 80
        let probe = CountProbe(counts: measured)

        let decision = await Selector.select(
            canonicalHuman: human,
            humanOutboundPrompt: humanOutbound,
            humanEffectiveEnvelope: humanEnvelope,
            target: target,
            candidates: candidates,
            counter: capability(probe: probe)
        )
        let requests = await probe.requests

        XCTAssertEqual(decision.selectedFormat, .rcw1)
        XCTAssertEqual(decision.cost(.human)?.payloadTokensIncludingHandle, 12)
        XCTAssertEqual(decision.cost(.human)?.effectiveEnvelopeTokens, 80)
        XCTAssertEqual(decision.cost(.human)?.effectiveEnvelopeSHA256, sha256(humanEnvelope))
        XCTAssertTrue(requests.contains(humanEnvelope))
    }

    func test_counterMustBindEveryIndependentTargetIdentity() async {
        let candidates = [candidate(.rcw1), candidate(.rcs1)]
        let counter = capability(counts: counts(candidates: candidates))
        let mismatches: [Selector.Target] = [
            target(provider: "grok"), target(model: "different-model"),
            target(counterID: "other-counter"), target(revision: "2"),
            target(encoding: "other-encoding"),
        ]

        for target in mismatches {
            let decision = await Selector.select(
                canonicalHuman: human, humanOutboundPrompt: human,
                humanEffectiveEnvelope: human, target: target,
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
            let decision = await select(candidates: [invalid, candidate(.rcs1)])
            XCTAssertEqual(decision.reason, .candidateError)
            XCTAssertFalse(decision.arm(.rcw1)!.eligible)
        }
    }

    func test_candidateOrderDoesNotChangeDecisionOrReceiptOrder() async {
        let forward = [candidate(.rcw1), candidate(.rcs1)]
        let reverse = Array(forward.reversed())
        let first = await select(candidates: forward, rcw1: 30, rcw1ABI: 5,
                                 rcs1: 20, rcs1ABI: 5, human: 100)
        let second = await select(candidates: reverse, rcw1: 30, rcw1ABI: 5,
                                  rcs1: 20, rcs1ABI: 5, human: 100)

        XCTAssertEqual(first.receipt, second.receipt)
        XCTAssertEqual(first.arms.map(\.format), [.rcw1, .rcs1])
        XCTAssertEqual(first.costs.map(\.format), [.human, .rcw1, .rcs1])
    }

    func test_receiptIsCodableWithoutCanonicalOrCandidatePayloads() async throws {
        let decision = await select(rcw1: 30, rcw1ABI: 10, rcs1: 80, rcs1ABI: 10, human: 100)
        let json = String(decoding: try JSONEncoder().encode(decision.receipt), as: UTF8.self)

        XCTAssertFalse(json.contains(human))
        XCTAssertFalse(json.contains("RCW1 candidate"))
        XCTAssertFalse(json.contains("RCS1 candidate"))
        XCTAssertTrue(json.contains("unique_strict_minimum"))
        XCTAssertFalse(decision.receipt.billingClaim)
    }

    func test_humanFallbackDropsMismatchedHumanPayloadEvidence() async throws {
        // WHY: fail-closed Human must not persist costs measured against a
        // different outbound. A stale Human Cost.payloadSHA256 would record
        // another context's tokens as this turn's evidence.
        let decision = await select(rcw1: 30, rcw1ABI: 10, rcs1: 80, rcs1ABI: 10, human: 100)
        let payload = "AUTO:\(human)"
        let fallback = decision.fallingBackToHuman(
            payload: payload,
            reason: .candidateError,
            canonicalHuman: human
        )
        let json = String(decoding: try JSONEncoder().encode(fallback.receipt), as: UTF8.self)

        XCTAssertEqual(decision.selectedFormat, .rcw1)
        XCTAssertEqual(fallback.selectedFormat, .human)
        XCTAssertEqual(fallback.selectedPayload, payload)
        XCTAssertEqual(fallback.reason, .candidateError)
        XCTAssertEqual(fallback.modeledContextDelta, 0)
        XCTAssertEqual(fallback.sourceSHA256, sha256(human))
        XCTAssertTrue(fallback.costs.isEmpty)
        XCTAssertTrue(fallback.arms.isEmpty)
        XCTAssertNil(fallback.counter)
        XCTAssertFalse(fallback.billingClaim)
        XCTAssertFalse(json.contains(payload))
        XCTAssertFalse(json.contains(human))
        XCTAssertFalse(json.contains("RCW1 candidate"))
    }

    func test_bindingToCurrentHumanRejectsOptimizedDecisionForAnotherProvider() async {
        // WHY: identical bytes ranked by another provider's tokenizer are not
        // evidence for this target. Fail closed to Human with an explicit
        // counter-binding reason, not a generic candidate error.
        let decision = await select(rcw1: 30, rcw1ABI: 10, rcs1: 70, rcs1ABI: 10, human: 100)
        let rebound = decision.bindingToCurrentHuman(
            canonicalHuman: human,
            admittedPrompt: human,
            provider: "claude",
            resolvedModel: "gpt-test"
        )

        XCTAssertEqual(decision.selectedFormat, .rcw1)
        XCTAssertEqual(decision.counter?.provider, "codex")
        XCTAssertEqual(rebound.selectedFormat, .human)
        XCTAssertEqual(rebound.selectedPayload, human)
        XCTAssertEqual(rebound.reason, .counterBindingMismatch)
        XCTAssertEqual(rebound.modeledContextDelta, 0)
        XCTAssertEqual(rebound.sourceSHA256, sha256(human))
        XCTAssertTrue(rebound.costs.isEmpty)
        XCTAssertTrue(rebound.arms.isEmpty)
        XCTAssertNil(rebound.counter)
    }

    func test_bindingToCurrentHumanRejectsOptimizedDecisionForAnotherResolvedModel() async {
        let decision = await select(rcw1: 70, rcw1ABI: 10, rcs1: 25, rcs1ABI: 5, human: 100)
        let rebound = decision.bindingToCurrentHuman(
            canonicalHuman: human,
            admittedPrompt: human,
            provider: "codex",
            resolvedModel: "other-model"
        )

        XCTAssertEqual(decision.selectedFormat, .rcs1)
        XCTAssertEqual(decision.counter?.resolvedModel, "gpt-test")
        XCTAssertEqual(rebound.selectedFormat, .human)
        XCTAssertEqual(rebound.selectedPayload, human)
        XCTAssertEqual(rebound.reason, .counterBindingMismatch)
        XCTAssertEqual(rebound.modeledContextDelta, 0)
        XCTAssertTrue(rebound.costs.isEmpty)
        XCTAssertTrue(rebound.arms.isEmpty)
        XCTAssertNil(rebound.counter)
    }

    func test_bindingToCurrentHumanKeepsOptimizedDecisionForCurrentTarget() async {
        let decision = await select(rcw1: 30, rcw1ABI: 10, rcs1: 70, rcs1ABI: 10, human: 100)
        let rebound = decision.bindingToCurrentHuman(
            canonicalHuman: human,
            admittedPrompt: human,
            provider: "codex",
            resolvedModel: "gpt-test"
        )

        XCTAssertEqual(rebound, decision)
        XCTAssertEqual(rebound.selectedFormat, .rcw1)
        XCTAssertEqual(rebound.reason, .uniqueStrictMinimum)
    }

    func test_bindingToCurrentHumanKeepsHumanDecisionsWithNoCounter() async {
        // WHY: tie/unavailable/error already selected Human. Missing counter
        // evidence is not a stale optimized ranking.
        let candidates = [candidate(.rcw1), candidate(.rcs1)]
        let missing = await Selector.select(
            canonicalHuman: human, humanOutboundPrompt: human, humanEffectiveEnvelope: human,
            target: target, candidates: candidates, counter: nil
        )
        let rebound = missing.bindingToCurrentHuman(
            canonicalHuman: human,
            admittedPrompt: human,
            provider: "codex",
            resolvedModel: "gpt-test"
        )

        XCTAssertEqual(missing.reason, .counterUnavailable)
        XCTAssertNil(missing.counter)
        XCTAssertEqual(rebound, missing)
        XCTAssertEqual(rebound.selectedFormat, .human)
        XCTAssertEqual(rebound.reason, .counterUnavailable)
    }

    func test_bindingToCurrentHumanKeepsHumanTieAndCounterErrorForCurrentTarget() async {
        let tied = await select(rcw1: 40, rcw1ABI: 10, rcs1: 80, rcs1ABI: 10, human: 50)
        let candidates = [candidate(.rcw1), candidate(.rcs1)]
        let error = await Selector.select(
            canonicalHuman: human,
            humanOutboundPrompt: human,
            humanEffectiveEnvelope: human,
            target: target,
            candidates: candidates,
            counter: capability(counts: [:])
        )
        let reboundTie = tied.bindingToCurrentHuman(
            canonicalHuman: human,
            admittedPrompt: human,
            provider: "codex",
            resolvedModel: "gpt-test"
        )
        let reboundError = error.bindingToCurrentHuman(
            canonicalHuman: human,
            admittedPrompt: human,
            provider: "codex",
            resolvedModel: "gpt-test"
        )

        XCTAssertEqual(tied.reason, .tie)
        XCTAssertEqual(error.reason, .counterError)
        XCTAssertEqual(reboundTie, tied)
        XCTAssertEqual(reboundError, error)
        XCTAssertEqual(reboundTie.selectedFormat, .human)
        XCTAssertEqual(reboundError.selectedFormat, .human)
    }

    func test_bindingToCurrentHumanDropsMismatchedCounterFromHumanDecision() async {
        // WHY: a Human winner measured on another provider/model is no longer
        // human_lowest_cost for this target. Keep the admitted Human bytes and
        // fail closed with the explicit counter-binding reason, not the stale
        // ranking reason, while dropping that other tokenizer's evidence.
        let decision = await select(rcw1: 60, rcw1ABI: 10, rcs1: 65, rcs1ABI: 10, human: 50)
        let rebound = decision.bindingToCurrentHuman(
            canonicalHuman: human,
            admittedPrompt: human,
            provider: "grok",
            resolvedModel: "gpt-test"
        )

        XCTAssertEqual(decision.selectedFormat, .human)
        XCTAssertEqual(decision.reason, .humanLowestCost)
        XCTAssertEqual(decision.counter?.provider, "codex")
        XCTAssertFalse(decision.costs.isEmpty)
        XCTAssertEqual(rebound.selectedFormat, .human)
        XCTAssertEqual(rebound.selectedPayload, human)
        XCTAssertEqual(rebound.reason, .counterBindingMismatch)
        XCTAssertEqual(rebound.modeledContextDelta, 0)
        XCTAssertNil(rebound.counter)
        XCTAssertTrue(rebound.costs.isEmpty)
        XCTAssertTrue(rebound.arms.isEmpty)
    }

    func test_bindingToCurrentHumanUsesCandidateErrorWhenHumanBytesDoNotBind() async {
        // WHY: stale target evidence is counter_binding_mismatch only when
        // canonical/outbound bytes still match. A different Human stays the
        // content-unbound candidate path.
        let decision = await select(rcw1: 30, rcw1ABI: 10, rcs1: 70, rcs1ABI: 10, human: 100)
        let other = "different canonical Human"
        let rebound = decision.bindingToCurrentHuman(
            canonicalHuman: other,
            admittedPrompt: other,
            provider: "claude",
            resolvedModel: "other-model"
        )

        XCTAssertEqual(rebound.selectedFormat, .human)
        XCTAssertEqual(rebound.selectedPayload, other)
        XCTAssertEqual(rebound.reason, .candidateError)
        XCTAssertEqual(rebound.modeledContextDelta, 0)
        XCTAssertNil(rebound.counter)
        XCTAssertTrue(rebound.costs.isEmpty)
    }

    func test_humanFallbackPreservesBoundEvidenceWhenPayloadMatchesHumanCost() async throws {
        // WHY: capability/malformed fallback may keep measured arms only when
        // Human Cost.payloadSHA256 is the exact bytes that will be sent.
        let decision = await select(rcw1: 30, rcw1ABI: 10, rcs1: 80, rcs1ABI: 10, human: 100)
        let fallback = decision.fallingBackToHuman(
            payload: human,
            reason: .candidateError,
            canonicalHuman: human
        )
        let json = String(decoding: try JSONEncoder().encode(fallback.receipt), as: UTF8.self)

        XCTAssertEqual(decision.selectedFormat, .rcw1)
        XCTAssertEqual(fallback.selectedFormat, .human)
        XCTAssertEqual(fallback.selectedPayload, human)
        XCTAssertEqual(fallback.reason, .candidateError)
        XCTAssertEqual(fallback.modeledContextDelta, 0)
        XCTAssertEqual(fallback.sourceSHA256, decision.sourceSHA256)
        XCTAssertEqual(fallback.counter, decision.counter)
        XCTAssertEqual(fallback.costs, decision.costs)
        XCTAssertEqual(fallback.arms, decision.arms)
        XCTAssertEqual(fallback.cost(.human)?.payloadSHA256, sha256(human))
        XCTAssertFalse(fallback.billingClaim)
        XCTAssertFalse(json.contains(human))
        XCTAssertFalse(json.contains("RCW1 candidate"))
    }

    func test_counterErrorOrInvalidCountFallsBackToHuman() async {
        let candidates = [candidate(.rcw1), candidate(.rcs1)]
        let error = await Selector.select(
            canonicalHuman: human,
            humanOutboundPrompt: human,
            humanEffectiveEnvelope: human,
            target: target,
            candidates: candidates,
            counter: capability(counts: [:])
        )
        var invalidCounts = counts(candidates: candidates)
        invalidCounts[human] = 0
        let invalid = await Selector.select(
            canonicalHuman: human,
            humanOutboundPrompt: human,
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
        rcs1: Int = 60,
        rcs1ABI: Int = 10,
        rcs1Effective: Int? = nil,
        human: Int = 100
    ) async -> Selector.Decision {
        let candidates = candidates ?? [candidate(.rcw1), candidate(.rcs1)]
        return await Selector.select(
            canonicalHuman: self.human,
            humanOutboundPrompt: self.human,
            humanEffectiveEnvelope: self.human,
            target: target,
            candidates: candidates,
            counter: capability(counts: counts(
                candidates: candidates,
                rcw1: rcw1, rcw1ABI: rcw1ABI, rcw1Effective: rcw1Effective,
                rcs1: rcs1, rcs1ABI: rcs1ABI,
                rcs1Effective: rcs1Effective, human: human
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
        let handle = handle ?? (format == .rcw1 ? "rcv1.handle" : "rcs1.handle")
        let payload = payload ?? (format == .rcw1
            ? "RCW1 candidate [[rc:\(handle)]]"
            : "RCS1 candidate [[rc:\(handle)]]")
        let abi = format == .rcw1 ? "RCW1 ABI" : "RCS1 ABI"
        return .init(
            format: format,
            sourceSHA256: sourceSHA256 ?? sha256(human),
            payload: payload,
            abi: abi,
            effectiveEnvelope: "SYSTEM:\(abi)\nUSER:\(payload)",
            handle: handle,
            producerID: format == .rcw1 ? "remotecode-rcw1" : "remotecode-rcs1",
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
        rcs1: Int = 60,
        rcs1ABI: Int = 10,
        rcs1Effective: Int? = nil,
        human: Int = 100
    ) -> [String: Int] {
        var result = [self.human: human]
        for candidate in candidates {
            let isRCW1 = candidate.format == .rcw1
            let payload = isRCW1 ? rcw1 : rcs1
            let abi = isRCW1 ? rcw1ABI : rcs1ABI
            result[candidate.payload] = payload
            if let handle = candidate.handle {
                result[handle] = isRCW1 ? 7 : 6
            }
            result[candidate.abi] = abi
            result[candidate.effectiveEnvelope] = isRCW1
                ? (rcw1Effective ?? payload + abi)
                : (rcs1Effective ?? payload + abi)
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
