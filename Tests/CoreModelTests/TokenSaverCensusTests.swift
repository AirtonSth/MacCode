import XCTest
@testable import CoreModel

final class TokenSaverCensusTests: XCTestCase {
    private func binding(trigger: String = "structured_json", provider: String = "claude") -> TokenSaverBindingID {
        TokenSaverBindingID(
            trigger: trigger,
            provider: provider,
            providerAdapterVersion: "2.1.216",
            toolShape: "mcp.json",
            model: "claude-sonnet",
            cachePolicy: "default",
            triggerPolicyClassifierRecipeIndexVersion: "policy-v1",
            billingCohort: "same-user-agent",
            hardwareTier: "apple-silicon",
            consentVersion: "exact-v1"
        )
    }

    private func observation(
        binding: TokenSaverBindingID,
        control: TokenSaverCensusControl = .noChange,
        tokens: Int64 = 100,
        sameUser: Bool = true,
        matched: Bool = true
    ) -> TokenSaverCensusObservation {
        TokenSaverCensusObservation(
            binding: binding,
            control: control,
            eligibleTokens: tokens,
            parserMatched: matched,
            streamKind: .completedTranscript,
            toolKind: .mcp,
            isSameUser: sameUser
        )
    }

    func test_providerVisiblePayload_unchangedByCensusHelper() {
        let payload = Data("provider-visible-bytes".utf8)
        let after = TokenSaverCensusStore.providerVisiblePayloadUnchanged(payload)
        XCTAssertEqual(after, payload)
    }

    func test_record_requiresCompleteBindingAndSameUser() {
        let store = TokenSaverCensusStore()
        let b = binding()
        XCTAssertTrue(store.record(observation(binding: b, sameUser: true)))
        XCTAssertFalse(store.record(observation(binding: b, sameUser: false)))
        XCTAssertEqual(store.snapshot().count, 1)
        XCTAssertTrue(store.snapshot()[0].hasCompleteBindingID)
        XCTAssertEqual(store.snapshot()[0].bindingDimensions.count, TokenSaverBindingID.canonicalFieldOrder.count)
        XCTAssertFalse(store.record(observation(binding: binding(trigger: "  "))))
    }

    func test_controls_areDistinguishable() {
        let store = TokenSaverCensusStore()
        let b = binding()
        for control in TokenSaverCensusControl.allCases {
            XCTAssertTrue(store.record(observation(binding: b, control: control, tokens: 10)))
        }
        let controls = Set(store.snapshot().map(\.control))
        XCTAssertEqual(controls, Set(TokenSaverCensusControl.allCases))
    }

    func test_recentSamplesAreBounded_withoutLosingAggregateTotals() {
        let store = TokenSaverCensusStore(maxRecentObservations: 3)
        let b = binding()
        for _ in 0..<10 {
            XCTAssertTrue(store.record(observation(binding: b, tokens: 2)))
        }
        XCTAssertEqual(store.snapshot().count, 3)
        let aggregate = store.aggregates().first
        XCTAssertEqual(aggregate?.observationCount, 10)
        XCTAssertEqual(aggregate?.absoluteEligibleTokens, 20)
    }

    func test_aggregate_volume_and_invalid_rank_without_volume() {
        let store = TokenSaverCensusStore()
        let high = binding(trigger: "structured_json")
        let zero = binding(trigger: "repeated_log")
        XCTAssertTrue(store.record(observation(binding: high, tokens: 500)))
        XCTAssertTrue(store.record(observation(binding: high, tokens: 500)))
        XCTAssertTrue(store.record(observation(binding: zero, tokens: 0)))

        let aggs = store.aggregates()
        XCTAssertEqual(aggs.count, 2)
        let byDigest = Dictionary(uniqueKeysWithValues: aggs.map { ($0.bindingDigestHex, $0) })
        let highAgg = byDigest[high.digestHex]!
        let zeroAgg = byDigest[zero.digestHex]!
        XCTAssertEqual(highAgg.absoluteEligibleTokens, 1000)
        XCTAssertEqual(highAgg.rankByAbsoluteVolume, 1)
        XCTAssertTrue(highAgg.isValidForGate)
        XCTAssertEqual(zeroAgg.absoluteEligibleTokens, 0)
        XCTAssertNil(zeroAgg.rankByAbsoluteVolume)
        XCTAssertFalse(zeroAgg.isValidForGate)
    }

    func test_exportJSON_omitsSavingsKeys_andSerializesNullRank() throws {
        let store = TokenSaverCensusStore()
        let zero = binding(trigger: "repeated_log")
        let high = binding(trigger: "structured_json")
        XCTAssertTrue(store.record(observation(binding: high, control: .wrappers, tokens: 42)))
        XCTAssertTrue(store.record(observation(binding: zero, tokens: 0)))
        let data = try store.exportJSON()
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["schema"] as? String, "token-saver-census-v1")
        for forbidden in ["headline_savings_confirmed", "tokens_saved", "confirmed_savings", "impact_estimate"] {
            XCTAssertNil(obj[forbidden], "export must not contain savings key \(forbidden)")
        }
        let aggregates = obj["aggregates"] as! [[String: Any]]
        XCTAssertEqual(aggregates.count, 2)
        let byDigest = Dictionary(uniqueKeysWithValues: aggregates.map {
            ($0["binding_digest"] as! String, $0)
        })
        XCTAssertEqual(byDigest[high.digestHex]!["absolute_eligible_tokens"] as? Int, 42)
        XCTAssertEqual(byDigest[high.digestHex]!["valid_for_gate"] as? Bool, true)
        XCTAssertEqual(byDigest[zero.digestHex]!["absolute_eligible_tokens"] as? Int, 0)
        XCTAssertEqual(byDigest[zero.digestHex]!["valid_for_gate"] as? Bool, false)
        XCTAssertTrue(byDigest[zero.digestHex]!["rank_by_absolute_volume"] is NSNull)
    }

    func test_observeWithoutMutating_providerPayloadGolden() {
        let store = TokenSaverCensusStore()
        let original = Data([0x01, 0x02, 0x03, 0xFF, 0x00])
        let out = store.observeWithoutMutatingProviderPayload(
            observation: observation(binding: binding(), tokens: 1),
            providerVisiblePayload: original
        )
        XCTAssertEqual(out, original)
        XCTAssertEqual(store.snapshot().count, 1)
        let off = TokenSaverCensusStore.providerVisiblePayloadUnchanged(original)
        XCTAssertEqual(out, off)
    }

    /// AC-01 multi-provider fixture: census on/off leaves identical provider-bound envelopes.
    /// AgentRuntime does not depend on DistillCore (avoids MLX); seam is this pure pass-through.
    func test_providerEnvelope_unchangedAcrossCensusOnOff_forClaudeCodexGrokShapes() {
        let envelopes: [(String, Data)] = [
            ("claude", Data(#"{"type":"tool_result","tool_use_id":"tu_1","content":[{"type":"text","text":"{\"ok\":true}"}]}"#.utf8)),
            ("codex", Data(#"{"type":"function_call_output","call_id":"c1","output":"{\"tests\":3}"}"#.utf8)),
            ("grok", Data(#"{"type":"tool_result","name":"bash","content":"exit 0\n"}"#.utf8)),
        ]
        for (provider, original) in envelopes {
            let onStore = TokenSaverCensusStore()
            let afterOn = onStore.observeWithoutMutatingProviderPayload(
                observation: observation(
                    binding: binding(provider: provider),
                    control: .noChange,
                    tokens: Int64(original.count)
                ),
                providerVisiblePayload: original
            )
            let afterOff = TokenSaverCensusStore.providerVisiblePayloadUnchanged(original)
            XCTAssertEqual(afterOn, original, "\(provider) census-on mutated payload")
            XCTAssertEqual(afterOff, original, "\(provider) census-off mutated payload")
            XCTAssertEqual(afterOn, afterOff, "\(provider) on/off diverge")
            XCTAssertEqual(onStore.snapshot().count, 1)
        }
    }
}
