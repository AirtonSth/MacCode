import XCTest
@testable import CoreModel

final class TokenSaverBindingIDTests: XCTestCase {
    private func sample(
        trigger: String = "structured_json",
        provider: String = "claude",
        providerAdapterVersion: String = "2.1.216",
        toolShape: String = "mcp.json",
        model: String = "claude-sonnet",
        cachePolicy: String = "default",
        policyVersion: String = "policy-v1",
        billingCohort: String = "same-user-agent",
        hardwareTier: String = "apple-silicon",
        consentVersion: String = "exact-v1"
    ) -> TokenSaverBindingID {
        TokenSaverBindingID(
            trigger: trigger,
            provider: provider,
            providerAdapterVersion: providerAdapterVersion,
            toolShape: toolShape,
            model: model,
            cachePolicy: cachePolicy,
            triggerPolicyClassifierRecipeIndexVersion: policyVersion,
            billingCohort: billingCohort,
            hardwareTier: hardwareTier,
            consentVersion: consentVersion
        )
    }

    func test_identicalDimensions_sameDigest() {
        let a = sample()
        let b = sample()
        XCTAssertEqual(a.digestHex, b.digestHex)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.digestHex.count, 64)
        XCTAssertTrue(a.digestHex.allSatisfy { $0.isHexDigit })
    }

    func test_canonicalUTF8_andDigest_areStableGolden() {
        let id = sample()
        let text = String(data: id.canonicalUTF8, encoding: .utf8)!
        // Values are base64 of UTF-8 (lossless).
        let expected = """
        schema_version=MQ==
        trigger=c3RydWN0dXJlZF9qc29u
        provider=Y2xhdWRl
        provider_adapter_version=Mi4xLjIxNg==
        tool_shape=bWNwLmpzb24=
        model=Y2xhdWRlLXNvbm5ldA==
        cache_policy=ZGVmYXVsdA==
        trigger_policy_classifier_recipe_index_version=cG9saWN5LXYx
        billing_cohort=c2FtZS11c2VyLWFnZW50
        hardware_tier=YXBwbGUtc2lsaWNvbg==
        consent_version=ZXhhY3QtdjE=
        """
        XCTAssertEqual(text, expected.trimmingCharacters(in: .newlines))
        XCTAssertEqual(TokenSaverBindingID.canonicalFieldOrder.count, 11)
        // Independent SHA-256 of the golden canonical form (Python hashlib / CryptoKit).
        XCTAssertEqual(
            id.digestHex,
            "269032595749e6e88cf9d301da6459a136549988b21f74400f25840d19e5c418"
        )
    }

    func test_eachDimensionChange_producesNewDigest() {
        let base = sample()
        let mutants: [TokenSaverBindingID] = [
            sample(trigger: "repeated_log"),
            sample(provider: "codex"),
            sample(providerAdapterVersion: "2.1.217"),
            sample(toolShape: "builtin.bash"),
            sample(model: "other-model"),
            sample(cachePolicy: "live-zone"),
            sample(policyVersion: "policy-v2"),
            sample(billingCohort: "internal-canary"),
            sample(hardwareTier: "intel"),
            sample(consentVersion: "semantic-v1"),
        ]
        XCTAssertEqual(mutants.count, 10, "one mutant per non-schema dimension")
        var digests = Set([base.digestHex])
        for mutant in mutants {
            XCTAssertNotEqual(mutant.digestHex, base.digestHex, "mutant \(mutant.dimensions) must change digest")
            XCTAssertFalse(digests.contains(mutant.digestHex))
            digests.insert(mutant.digestHex)
        }
    }

    func test_displayProjection_isNotCompleteBindingAndHasNoPromotionSurface() {
        let id = sample()
        let projection = id.displayProjection()
        XCTAssertFalse(projection.isCompleteBinding)
        XCTAssertEqual(projection.sourceDigestHex, id.digestHex)
        XCTAssertFalse(projection.fields.keys.contains("schema_version"))
        XCTAssertNotEqual(projection.fields.count, id.dimensions.count)
        let mirror = Mirror(reflecting: projection)
        let names = Set(mirror.children.compactMap(\.label))
        XCTAssertEqual(names, ["sourceDigestHex", "fields", "isCompleteBinding"])
        XCTAssertFalse(names.contains { $0.lowercased().contains("promot") })
        XCTAssertFalse(names.contains { $0.lowercased().contains("estimat") })
    }

    func test_equality_usesDigestOnly() {
        let a = sample()
        let b = sample()
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
    }

    func test_newlinesInValues_areDistinctDimensions() {
        let withNewline = sample(trigger: "structured\njson")
        let without = sample(trigger: "structuredjson")
        XCTAssertNotEqual(withNewline.digestHex, without.digestHex)
        XCTAssertNotEqual(withNewline.trigger, without.trigger)
    }
}
