import XCTest
@testable import CoreModel

final class TokenSaverAddressabilityGateTests: XCTestCase {
    private func binding(trigger: String) -> TokenSaverBindingID {
        TokenSaverBindingID(
            trigger: trigger,
            provider: "claude",
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

    private func slice(
        trigger: String,
        tokens: Int64,
        overlap: Double = 0,
        cost: Double = 0,
        valuePerToken: Double = 0.001
    ) -> TokenSaverAddressabilityGate.SliceOpportunity {
        .init(
            binding: binding(trigger: trigger),
            absoluteEligibleTokens: tokens,
            overlapFraction: overlap,
            incrementalCost: cost,
            expectedValuePerToken: valuePerToken
        )
    }

    func test_belowAbsoluteThreshold_deniesBuild() {
        let decision = TokenSaverAddressabilityGate.authorizeBuild(sortedByPriority: [
            slice(trigger: "a", tokens: 100)
        ])
        XCTAssertEqual(decision, .denyBelowThreshold)
    }

    func test_nonPositiveNetValue_deniesEvenAboveThreshold() {
        let decision = TokenSaverAddressabilityGate.authorizeBuild(sortedByPriority: [
            slice(trigger: "a", tokens: 2000, cost: 10, valuePerToken: 0)
        ])
        XCTAssertEqual(decision, .denyNonPositiveNetValue)
    }

    func test_incompleteBindingCannotAuthorizeSlice() {
        let incomplete = slice(trigger: " ", tokens: 10_000)
        XCTAssertFalse(incomplete.isQualifying)
        XCTAssertEqual(
            TokenSaverAddressabilityGate.authorizeBuild(sortedByPriority: [incomplete]),
            .denyIncompleteBinding
        )
    }

    func test_winner_authorizesAtMostOneNextSlice_usingCanonicalDigest() {
        let low = slice(trigger: "low", tokens: 1500, valuePerToken: 0.001)
        let high = slice(trigger: "high", tokens: 5000, valuePerToken: 0.001)
        let decision = TokenSaverAddressabilityGate.authorizeBuild(sortedByPriority: [low, high])
        XCTAssertEqual(decision, .authorizeNextSlice(bindingDigestHex: high.bindingDigestHex))
        XCTAssertEqual(high.bindingDigestHex.count, 64)
    }

    func test_largerNegativeSlice_doesNotMaskSmallerQualifyingSlice() {
        let negativeBig = slice(trigger: "big-neg", tokens: 50_000, cost: 10_000, valuePerToken: 0.001)
        // net = 50 - 10000 < 0
        XCTAssertFalse(negativeBig.isQualifying)
        let positiveSmall = slice(trigger: "small-pos", tokens: 2_000, valuePerToken: 0.001)
        XCTAssertTrue(positiveSmall.isQualifying)
        let decision = TokenSaverAddressabilityGate.authorizeBuild(sortedByPriority: [
            negativeBig, positiveSmall
        ])
        XCTAssertEqual(decision, .authorizeNextSlice(bindingDigestHex: positiveSmall.bindingDigestHex))
    }

    func test_emptyPortfolio_denies() {
        XCTAssertEqual(
            TokenSaverAddressabilityGate.authorizeBuild(sortedByPriority: []),
            .denyEmptyPortfolio
        )
    }

    func test_sharedInfra_requiresTwoSlices() {
        XCTAssertEqual(
            TokenSaverAddressabilityGate.authorizeSharedInfrastructure(sliceCountDemonstratingReuse: 1),
            .deniedNeedsAtLeastTwoSlices(observed: 1)
        )
        XCTAssertEqual(
            TokenSaverAddressabilityGate.authorizeSharedInfrastructure(sliceCountDemonstratingReuse: 2),
            .authorized(reusedBySlices: 2)
        )
    }

    func test_probe_refusesProductionSQLitePaths_andStoresMemoryOnly() {
        let probe = TokenSaverMemoryOnlyProbe()
        let ok = probe.storeEnvelope(id: "syn-1", bytes: Data("hello".utf8), pathHint: nil)
        XCTAssertTrue(ok)
        XCTAssertEqual(probe.loadEnvelope(id: "syn-1"), Data("hello".utf8))
        XCTAssertEqual(probe.memoryBlobCount, 1)

        let denied = probe.storeEnvelope(
            id: "bad",
            bytes: Data("x".utf8),
            pathHint: "/Users/me/Library/Application Support/RemoteCode/db.sqlite-wal"
        )
        XCTAssertFalse(denied)
        XCTAssertNil(probe.loadEnvelope(id: "bad"))
        XCTAssertEqual(probe.refusedProductionPaths.count, 1)
        XCTAssertTrue(probe.isForbiddenProductionPath("/tmp/backup/store.sqlite"))
    }

    func test_probe_comparesNoChangeWrapperAndOptionalNative() {
        let probe = TokenSaverMemoryOnlyProbe()
        let withoutNative = probe.compareArms(rawTokens: 1000, wrapperTokens: 700, providerNativeTokens: nil)
        XCTAssertEqual(withoutNative.arms.count, 2)
        XCTAssertEqual(withoutNative.bestArm, .wrapperExact)
        XCTAssertEqual(withoutNative.deltaVsNoChange, 300)

        let withNative = probe.compareArms(rawTokens: 1000, wrapperTokens: 700, providerNativeTokens: 500)
        XCTAssertEqual(withNative.arms.count, 3)
        XCTAssertEqual(withNative.bestArm, .providerNative)
        XCTAssertEqual(withNative.deltaVsNoChange, 500)
    }

    func test_overlapAndCost_reduceNetValue() {
        let highOverlap = slice(trigger: "x", tokens: 5000, overlap: 0.9, cost: 1, valuePerToken: 0.001)
        XCTAssertLessThan(highOverlap.netExpectedValue, 0)
        let decision = TokenSaverAddressabilityGate.authorizeBuild(sortedByPriority: [highOverlap])
        XCTAssertEqual(decision, .denyNonPositiveNetValue)
    }

    // MARK: - Cardinality caps (PERF)

    /// PERF: synthetic probe id / refused-path churn must not pin unbounded
    /// Data blobs or path strings for the life of the probe instance.
    func test_probe_builtInCountLimits() {
        XCTAssertEqual(TokenSaverMemoryOnlyProbe.memoryBlobCountLimit, 32)
        XCTAssertEqual(TokenSaverMemoryOnlyProbe.refusedPathCountLimit, 64)
    }

    func test_noteMemoryBlob_capsDistinctIds() {
        var blobs: [String: Data] = [:]
        let limit = 5
        var newest = ""
        for i in 0..<(limit + 10) {
            newest = "id-\(i)"
            TokenSaverMemoryOnlyProbe.noteMemoryBlob(
                &blobs, id: newest, bytes: Data([UInt8(i)]), countLimit: limit
            )
        }
        XCTAssertEqual(blobs.count, limit)
        XCTAssertEqual(blobs[newest], Data([UInt8(limit + 9)]))
    }

    func test_storeEnvelope_enforcesBlobCap() {
        let probe = TokenSaverMemoryOnlyProbe(memoryBlobCountLimit: 4)
        for i in 0..<12 {
            XCTAssertTrue(probe.storeEnvelope(id: "b-\(i)", bytes: Data("x\(i)".utf8), pathHint: nil))
        }
        XCTAssertEqual(probe.memoryBlobCount, 4)
        XCTAssertEqual(probe.loadEnvelope(id: "b-11"), Data("x11".utf8))
    }

    func test_noteRefusedPath_tailCapsNewest() {
        var paths: [String] = []
        let limit = 3
        for i in 0..<(limit + 5) {
            TokenSaverMemoryOnlyProbe.noteRefusedPath(
                &paths, path: "/tmp/backup/\(i).sqlite", countLimit: limit
            )
        }
        XCTAssertEqual(paths.count, limit)
        XCTAssertEqual(paths.last, "/tmp/backup/\(limit + 4).sqlite")
        XCTAssertFalse(paths.contains("/tmp/backup/0.sqlite"))
    }

    func test_storeEnvelope_enforcesRefusedPathCap() {
        let probe = TokenSaverMemoryOnlyProbe(refusedPathCountLimit: 3)
        for i in 0..<10 {
            _ = probe.storeEnvelope(
                id: "x-\(i)",
                bytes: Data(),
                pathHint: "/Users/me/Library/Application Support/RemoteCode/db-\(i).sqlite"
            )
        }
        XCTAssertEqual(probe.refusedProductionPaths.count, 3)
        XCTAssertTrue(probe.refusedProductionPaths.last?.contains("db-9.sqlite") == true)
    }

    func test_retentionEstimate_2kBlobsTo32Window() {
        let uncapped = 2_000
        let limit = TokenSaverMemoryOnlyProbe.memoryBlobCountLimit
        let reduction = Double(uncapped - limit) / Double(uncapped)
        XCTAssertGreaterThan(reduction, 0.98)
        XCTAssertEqual(limit, 32)
        // Basis: ~1 KB/blob envelope → 2k ≈ 2 MB; 32 ≈ 32 KB (−98.4%).
        let perKey = 1_024
        let before = uncapped * perKey
        let after = limit * perKey
        XCTAssertEqual(before, 2_048_000)
        XCTAssertEqual(after, 32_768)
        XCTAssertLessThan(Double(after) / Double(before), 0.02)
    }
}
