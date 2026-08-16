import CryptoKit
import XCTest
@testable import CoreModel

/// WHY: context compaction ranks Human / RCW1 / RCS1 independently from the
/// same canonical assistant text. Deriving one optimized arm from the other
/// would hide an unproven Human→RCW1 encoder or a corrupted recovery path.
final class TokenSaverContextItemSelectorTests: XCTestCase {
    func test_rcs1WinsWithExactLocalCounterAndRecoversHuman() async throws {
        // WHY: a cheaper, byte-exact RCS1 arm is the only proven compaction
        // that may replace the assistant context item on a fresh destination.
        let human = repeatingHuman
        let rcs1 = TokenSaverContextItemSelector.rcs1Candidate(
            canonicalHuman: human,
            abi: "RCS1 ABI",
            effectiveEnvelope: "RCS1 ABI\n" + (RemoteCodeCompactSpan.encode(human) ?? "")
        )
        XCTAssertEqual(RemoteCodeCompactSpan.decode(rcs1.payload), human)
        let decision = await TokenSaverContextItemSelector.select(
            canonicalHuman: human,
            humanEnvelope: "HUMAN ABI\n\(human)",
            rcw1: TokenSaverContextItemSelector.ineligibleRCW1Candidate(sourceSHA256: sha256(human)),
            rcs1: rcs1,
            target: target,
            counter: capability(counts: [
                human: 90,
                "HUMAN ABI\n\(human)": 100,
                rcs1.effectiveEnvelope: 30,
                rcs1.payload: 20,
                rcs1.abi: 10,
                TokenSaverContextItemSelector.ineligibleRCW1Candidate(sourceSHA256: sha256(human)).effectiveEnvelope: 80,
                TokenSaverContextItemSelector.ineligibleRCW1Candidate(sourceSHA256: sha256(human)).payload: 40,
                TokenSaverContextItemSelector.ineligibleRCW1Candidate(sourceSHA256: sha256(human)).abi: 10,
            ])
        )
        XCTAssertEqual(decision.selectedFormat, .rcs1)
        XCTAssertEqual(decision.reason, .uniqueStrictMinimum)
        XCTAssertFalse(decision.billingClaim)
        XCTAssertEqual(RemoteCodeCompactSpan.decode(decision.selectedPayload), human)
        XCTAssertFalse(decision.arm(.rcw1)?.eligible ?? true)
    }

    func test_humanWinsWhenCheaperOnTieAndOnCounterFailures() async {
        // WHY: ties and unproven counts must keep the visible Human bytes so
        // the fresh session never receives a speculative cheaper envelope.
        let human = repeatingHuman
        let rcs1 = TokenSaverContextItemSelector.rcs1Candidate(
            canonicalHuman: human,
            abi: "RCS1 ABI",
            effectiveEnvelope: "RCS1 ABI\n" + (RemoteCodeCompactSpan.encode(human) ?? "")
        )
        let rcw1 = TokenSaverContextItemSelector.ineligibleRCW1Candidate(sourceSHA256: sha256(human))
        let cheaper = await TokenSaverContextItemSelector.select(
            canonicalHuman: human,
            humanEnvelope: human,
            rcw1: rcw1,
            rcs1: rcs1,
            target: target,
            counter: capability(counts: envelopeCounts(human: 20, rcs1: rcs1, rcw1: rcw1, rcs1Envelope: 40, humanEnvelope: 20))
        )
        XCTAssertEqual(cheaper.selectedFormat, .human)
        XCTAssertEqual(cheaper.reason, .humanLowestCost)

        let tie = await TokenSaverContextItemSelector.select(
            canonicalHuman: human,
            humanEnvelope: human,
            rcw1: rcw1,
            rcs1: rcs1,
            target: target,
            counter: capability(counts: envelopeCounts(human: 30, rcs1: rcs1, rcw1: rcw1, rcs1Envelope: 30, humanEnvelope: 30))
        )
        XCTAssertEqual(tie.reason, .tie)
        XCTAssertEqual(tie.selectedFormat, .human)

        let missing = await TokenSaverContextItemSelector.select(
            canonicalHuman: human,
            humanEnvelope: human,
            rcw1: rcw1,
            rcs1: rcs1,
            target: target,
            counter: nil
        )
        XCTAssertEqual(missing.reason, .counterUnavailable)
        XCTAssertEqual(missing.selectedFormat, .human)

        let throwing = await TokenSaverContextItemSelector.select(
            canonicalHuman: human,
            humanEnvelope: human,
            rcw1: rcw1,
            rcs1: rcs1,
            target: target,
            counter: .init(counter: counter, count: { _ in throw NSError(domain: "c", code: 1) })
        )
        XCTAssertEqual(throwing.reason, .counterError)
        XCTAssertEqual(throwing.selectedFormat, .human)

        let mismatched = await TokenSaverContextItemSelector.select(
            canonicalHuman: human,
            humanEnvelope: human,
            rcw1: rcw1,
            rcs1: rcs1,
            target: TokenSaverBestOfThreeSelector.Target(
                provider: "claude",
                resolvedModel: "other",
                counterID: "fixture-counter",
                counterRevision: "1",
                encoding: "fixture-exact"
            ),
            counter: capability(counts: [:])
        )
        XCTAssertEqual(mismatched.reason, .counterBindingMismatch)
        XCTAssertEqual(mismatched.selectedFormat, .human)

        let uncertain = await TokenSaverContextItemSelector.select(
            canonicalHuman: human,
            humanEnvelope: human,
            rcw1: rcw1,
            rcs1: rcs1,
            target: target,
            counter: .init(
                counter: .init(
                    id: "fixture-counter",
                    revision: "1",
                    encoding: "fixture-exact",
                    provider: "codex",
                    resolvedModel: "gpt-test",
                    quality: .estimated
                ),
                count: { _ in 1 }
            )
        )
        XCTAssertEqual(uncertain.reason, .counterUncertain)
        XCTAssertEqual(uncertain.selectedFormat, .human)
    }

    func test_invalidRCS1StructureSemanticOrRecoverySelectsHuman() async {
        // WHY: a structurally invalid, semantically unrecoverable, or
        // non-round-tripping RCS1 item must not enter the fresh session.
        let human = repeatingHuman
        let source = sha256(human)
        let invalidStructure = TokenSaverBestOfThreeSelector.Candidate(
            format: .rcs1,
            sourceSHA256: source,
            payload: "not-rcs1",
            abi: "RCS1 ABI",
            effectiveEnvelope: "RCS1 ABI\nnot-rcs1",
            handle: nil,
            producerID: TokenSaverRequestSelectionReceipt.rcs1ProducerID,
            producerRevision: "1",
            abiRevision: "1",
            generation: .passed,
            structural: .failed,
            semantic: .passed,
            recovery: .passed
        )
        let failedSemantic = TokenSaverBestOfThreeSelector.Candidate(
            format: .rcs1,
            sourceSHA256: source,
            payload: RemoteCodeCompactSpan.encode(human) ?? "x",
            abi: "RCS1 ABI",
            effectiveEnvelope: "RCS1 ABI\n" + (RemoteCodeCompactSpan.encode(human) ?? "x"),
            handle: nil,
            producerID: TokenSaverRequestSelectionReceipt.rcs1ProducerID,
            producerRevision: "1",
            abiRevision: "1",
            generation: .passed,
            structural: .passed,
            semantic: .failed,
            recovery: .passed
        )
        let failedRecovery = TokenSaverContextItemSelector.rcs1Candidate(
            canonicalHuman: human + "tampered",
            encodedItem: RemoteCodeCompactSpan.encode(human),
            abi: "RCS1 ABI",
            effectiveEnvelope: "RCS1 ABI\n" + (RemoteCodeCompactSpan.encode(human) ?? "")
        )
        let rcw1 = TokenSaverContextItemSelector.ineligibleRCW1Candidate(sourceSHA256: source)
        for candidate in [invalidStructure, failedSemantic, failedRecovery] {
            let decision = await TokenSaverContextItemSelector.select(
                canonicalHuman: human,
                humanEnvelope: human,
                rcw1: rcw1,
                rcs1: candidate,
                target: target,
                counter: capability(counts: envelopeCounts(human: 90, rcs1: candidate, rcw1: rcw1, rcs1Envelope: 10, humanEnvelope: 90))
            )
            XCTAssertEqual(decision.selectedFormat, .human, "\(candidate.structural)/\(candidate.semantic)/\(candidate.recovery)")
        }
    }

    func test_rcw1ArmIsIndependentlyEvaluatedNeverDerivedFromRCS1() {
        // WHY: there is no proven Human→RCW1 A encoder. The RCW1 arm must
        // come from persisted provider-authored bytes or be explicitly
        // ineligible — never from the RCS1 item.
        let human = repeatingHuman
        let rcs1 = TokenSaverContextItemSelector.rcs1Candidate(
            canonicalHuman: human,
            abi: "RCS1 ABI",
            effectiveEnvelope: "RCS1 ABI\n" + (RemoteCodeCompactSpan.encode(human) ?? "")
        )
        let withoutProof = TokenSaverContextItemSelector.rcw1Candidate(
            canonicalHuman: human,
            persistedProviderWire: nil
        )
        XCTAssertFalse(withoutProof.eligibleArm)
        XCTAssertNotEqual(withoutProof.payload, rcs1.payload)
        XCTAssertNotEqual(withoutProof.producerID, rcs1.producerID)

        let unrelatedWire = "RCW1\tA\t1\nO\tUnrelated provider answer.\n.\n"
        let fromWire = TokenSaverContextItemSelector.rcw1Candidate(
            canonicalHuman: human,
            persistedProviderWire: unrelatedWire
        )
        XCTAssertFalse(fromWire.eligibleArm, "unrelated persisted RCW1 cannot recover this Human")
        XCTAssertNotEqual(fromWire.payload, rcs1.payload)

        let matchingWire = "RCW1\tA\t1\nO\t\(human)\n.\n"
        let recovered = TokenSaverContextItemSelector.rcw1Candidate(
            canonicalHuman: human,
            persistedProviderWire: matchingWire
        )
        if recovered.eligibleArm {
            XCTAssertEqual(recovered.payload, matchingWire)
            XCTAssertNotEqual(recovered.payload, rcs1.payload)
            XCTAssertEqual(RCWireProtocol.renderEnglish(try! RCWireProtocol.parse(matchingWire)), human)
        } else {
            XCTAssertNotEqual(recovered.payload, rcs1.payload)
            XCTAssertEqual(recovered.structural, .failed)
        }
        XCTAssertNotEqual(rcs1.payload, matchingWire)
    }

    func test_preparedSeedOmitsCurrentPromptAndKeepsHumanUserItems() async throws {
        let human = repeatingHuman
        let snapshot = try XCTUnwrap(TokenSaverCanonicalConversationSnapshot.capture(
            messages: [
                AgentMessage(threadId: AgentThreadID(), role: .user, content: "prior user"),
                AgentMessage(threadId: AgentThreadID(), role: .assistant, content: human),
                AgentMessage(threadId: AgentThreadID(), role: .user, content: "current"),
            ],
            persistedRCW1ByMessageId: [:],
            excludingCurrentUserText: "current"
        ))
        let prepared = await TokenSaverContextSeedBuilder.prepare(
            snapshot: snapshot,
            target: target,
            counter: capability(counts: [:]),
            project: { format, payload in
                TokenSaverContextSeedBuilder.ProjectedEnvelope(
                    payload: payload,
                    abi: "\(format.rawValue.uppercased()) ABI",
                    effectiveEnvelope: "\(format.rawValue.uppercased()) ABI\n\(payload)"
                )
            }
        )
        let seed = try XCTUnwrap(prepared?.seed)
        XCTAssertEqual(seed.items.count, 2)
        XCTAssertEqual(seed.items[0].role, .user)
        XCTAssertEqual(seed.items[0].format, .human)
        XCTAssertEqual(seed.items[0].payload, "prior user")
        XCTAssertFalse(seed.items.contains(where: { $0.payload == "current" }))
        XCTAssertEqual(seed.items[1].role, .assistant)
        XCTAssertEqual(RemoteCodeCompactSpan.decode(seed.items[1].payload) ?? seed.items[1].payload, human)
    }

    private var repeatingHuman: String { String(repeating: "ABCDEFGH", count: 16) }

    private var target: TokenSaverBestOfThreeSelector.Target {
        .init(
            provider: "codex",
            resolvedModel: "gpt-test",
            counterID: "fixture-counter",
            counterRevision: "1",
            encoding: "fixture-exact"
        )
    }

    private var counter: TokenSaverBestOfThreeSelector.Counter {
        .init(
            id: "fixture-counter",
            revision: "1",
            encoding: "fixture-exact",
            provider: "codex",
            resolvedModel: "gpt-test",
            quality: .exactLocalTokenizer
        )
    }

    private func capability(counts: [String: Int]) -> TokenSaverBestOfThreeSelector.CounterCapability {
        .init(counter: counter) { text in
            guard let value = counts[text] else { throw NSError(domain: "counter", code: 1) }
            return value
        }
    }

    private func envelopeCounts(
        human: Int,
        rcs1: TokenSaverBestOfThreeSelector.Candidate,
        rcw1: TokenSaverBestOfThreeSelector.Candidate,
        rcs1Envelope: Int,
        humanEnvelope: Int
    ) -> [String: Int] {
        var counts = [
            repeatingHuman: human,
            rcs1.effectiveEnvelope: rcs1Envelope,
            rcs1.payload: 20,
            rcs1.abi: 10,
            rcw1.effectiveEnvelope: 80,
            rcw1.payload: 40,
            rcw1.abi: 10,
        ]
        counts[repeatingHuman] = humanEnvelope
        if humanEnvelope != human {
            counts[repeatingHuman] = human
            counts["HUMAN ABI\n\(repeatingHuman)"] = humanEnvelope
        }
        return counts
    }

    private func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private extension TokenSaverBestOfThreeSelector.Candidate {
    var eligibleArm: Bool {
        generation == .passed && structural == .passed && semantic == .passed && recovery == .passed
    }
}
