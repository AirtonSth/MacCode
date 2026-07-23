import XCTest
@testable import CoreModel

final class TokenSaverAuthorityPlaneTests: XCTestCase {
    private func binding(_ t: String = "structured_json") -> TokenSaverBindingID {
        TokenSaverBindingID(
            trigger: t, provider: "claude", providerAdapterVersion: "2.1.216",
            toolShape: "mcp.json", model: "m", cachePolicy: "default",
            triggerPolicyClassifierRecipeIndexVersion: "p1", billingCohort: "same-user-agent",
            hardwareTier: "apple-silicon", consentVersion: "exact-v1"
        )
    }

    func test_registry_defaultOff_unknownDenies() {
        let reg = TokenSaverAuthorityPlane.Registry()
        XCTAssertFalse(reg.allowsReplacement(for: binding()))
        let decision = TokenSaverAuthorityPlane.evaluateRelease(
            binding: binding(),
            registry: reg,
            manifest: .init(cells: ["tests": .present]),
            consent: .init(exactLossless: true, semanticLocalAI: false, isLegacyPreference: false),
            requiresSemantic: false
        )
        XCTAssertEqual(decision, .denyUnknownBinding)
    }

    func test_validator_rejectsMissingStaleSkippedInconclusive() {
        let reg = TokenSaverAuthorityPlane.Registry()
        let b = binding()
        reg.setReplacementAllowed(true, for: b)
        for bad in [TokenSaverAuthorityPlane.CoverageCellStatus.missing, .stale, .skipped, .inconclusive] {
            let decision = TokenSaverAuthorityPlane.evaluateRelease(
                binding: b,
                registry: reg,
                manifest: .init(cells: ["unit": bad]),
                consent: .init(exactLossless: true, semanticLocalAI: false, isLegacyPreference: false),
                requiresSemantic: false
            )
            XCTAssertEqual(decision, .denyCoverage, "\(bad) must deny")
        }
    }

    func test_legacyConsent_neverEnablesSemantic() {
        let c = TokenSaverAuthorityPlane.ConsentState(
            exactLossless: true, semanticLocalAI: true, isLegacyPreference: true
        )
        XCTAssertFalse(c.allowsSemanticLossy)
        XCTAssertFalse(c.semanticLocalAI)
    }

    func test_presentationReceipt_carriesBindingHandleRecovery() {
        let r = TokenSaverAuthorityPlane.PresentationReceipt(
            binding: binding(),
            operationID: "op-1",
            handle: "rc:h1",
            recoveryState: "available",
            expiry: Date().addingTimeInterval(3600)
        )
        XCTAssertTrue(r.isWellFormed)
        XCTAssertEqual(r.binding.digestHex.count, 64)
        XCTAssertFalse(r.handle.isEmpty)
        XCTAssertEqual(r.recoveryState, "available")
    }

    func test_shadow_zeroHeadlineConfirmed() {
        XCTAssertEqual(TokenSaverAuthorityPlane.shadowHeadlineConfirmedSavings, 0)
    }

    func test_revocationEpoch_blocksNewEmissions() {
        let reg = TokenSaverAuthorityPlane.Registry()
        let b = binding()
        reg.setReplacementAllowed(true, for: b)
        XCTAssertTrue(reg.allowsReplacement(for: b))
        reg.revoke(binding: b)
        XCTAssertFalse(reg.allowsReplacement(for: b))
        XCTAssertEqual(reg.epoch(for: b), 1)
        let decision = TokenSaverAuthorityPlane.evaluateRelease(
            binding: b,
            registry: reg,
            manifest: .init(cells: ["unit": .present]),
            consent: .init(exactLossless: true, semanticLocalAI: false, isLegacyPreference: false),
            requiresSemantic: false
        )
        XCTAssertEqual(decision, .denyRevoked)
    }
}
