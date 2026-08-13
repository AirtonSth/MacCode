import XCTest
@testable import DistillCore
@testable import CoreModel

final class TokenSaverTypedCrushersBridgeTests: XCTestCase {
    override func tearDown() {
        TokenSaverTypedCrushersBridge.deactivate()
        super.tearDown()
    }

    func test_pytestFailureLines_excludesSummary() {
        let out = """
        test_a FAILED
        test_b FAILED
        ===== 2 failed, 3 passed in 0.1s =====
        """
        let lines = TokenSaverTypedCrushersBridge.pytestFailureLines(from: out)
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines.contains(where: { $0.contains("=====") }))
    }

    func test_bridgeObserve_doesNotThrow() {
        TokenSaverTypedCrushersBridge.observeToolOutput(
            toolName: "Bash",
            output: "test_a FAILED\n===== 1 failed ====="
        )
        TokenSaverTypedCrushersBridge.observeToolOutput(
            toolName: "Grep",
            output: "a.swift:1:hit",
            bindingDigest: "abc"
        )
        XCTAssertTrue(true)
    }

    func test_extractRecoveryHandles_hexAndRcv1() {
        let out = "see [[rc:deadbeefcafebabe]] and [[rc:rcv1.ae525256]]"
        let hs = TokenSaverTypedCrushersBridge.extractRecoveryHandles(from: out)
        XCTAssertEqual(hs.count, 2)
        XCTAssertTrue(hs.contains("deadbeefcafebabe"))
        XCTAssertTrue(hs.contains("rcv1.ae525256"))
    }

    func test_searchScopeRequiresBindingDigestMatch() {
        // Default OFF → deny regardless
        XCTAssertFalse(TokenSaverRecoveryBridge.observeSearch(queryScope: "a", resultScope: "b"))
        // Live would deny mismatch via projections
        XCTAssertFalse(TokenSaverRecoveryProjections.admitSearch(
            queryScopeDigest: "scopeA", resultScopeDigest: "scopeB", live: true
        ))
        XCTAssertTrue(TokenSaverRecoveryProjections.admitSearch(
            queryScopeDigest: "scopeA", resultScopeDigest: "scopeA", live: true
        ))
    }

    func test_productionBridge_independentScopes() {
        // Missing result scope → empty → deny when live
        XCTAssertFalse(TokenSaverRecoveryProjections.admitSearch(
            queryScopeDigest: "query-scope", resultScopeDigest: "", live: true
        ))
        // Production bridge API: mismatch via observeSearch
        XCTAssertFalse(TokenSaverRecoveryBridge.observeSearch(queryScope: "q", resultScope: "r"))
        XCTAssertFalse(TokenSaverRecoveryProjections.admitSearch(
            queryScopeDigest: "query-scope", resultScopeDigest: "other-scope", live: true
        ))
        XCTAssertTrue(TokenSaverRecoveryProjections.admitSearch(
            queryScopeDigest: "query-scope", resultScopeDigest: "query-scope", live: true
        ))
        // exercise observeToolOutput with independent scopes (fail-open, default OFF)
        TokenSaverTypedCrushersBridge.observeToolOutput(
            toolName: "Grep", output: "hit",
            bindingDigest: "query-scope", resultScopeDigest: "other-scope"
        )
        TokenSaverTypedCrushersBridge.observeToolOutput(
            toolName: "Grep", output: "hit",
            bindingDigest: "query-scope" // missing result → empty
        )
    }

    func test_releaseActivationStoresOriginalEncrypted_andRevocationStopsIt() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("typed-bridge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyProvider = TokenSaverInMemoryProjectKeyProvider()
        let encrypted = try TokenSaverEncryptedStore(projectRoot: dir, keyProvider: keyProvider)
        try encrypted.markMigrationComplete()
        let scope = TokenSaverEncryptedStore.Scope(
            uid: 501,
            workspaceID: "w",
            projectID: "p",
            threadID: "t",
            provider: "claude",
            sessionGeneration: 1
        )
        let binding = TokenSaverBindingID(
            trigger: "pytest",
            provider: "claude",
            providerAdapterVersion: "1",
            toolShape: "text",
            model: "m",
            cachePolicy: "none",
            triggerPolicyClassifierRecipeIndexVersion: "1",
            billingCohort: "test",
            hardwareTier: "apple-silicon",
            consentVersion: "1"
        )
        let authority = TokenSaverAuthorityPlane.Registry()
        authority.setReplacementAllowed(true, for: binding)
        let manifest = TokenSaverAuthorityPlane.CoverageManifest(
            cells: Dictionary(
                uniqueKeysWithValues: TokenSaverAuthorityPlane.CoverageManifest.requiredCellIDs.map {
                    ($0, .present)
                }
            )
        )
        let seal = TokenSaverAuthorityPlane.mintReleaseSeal(
            binding: binding,
            registry: authority,
            manifest: manifest,
            consent: .init(exactLossless: true, semanticLocalAI: false, isLegacyPreference: false),
            requiresSemantic: false
        )!
        TokenSaverTypedCrushersBridge.activate(
            kinds: [.pytest],
            bindingDigest: binding.digestHex,
            releaseSeal: seal,
            encryptedStore: encrypted,
            scope: scope
        )

        let first = "test_a FAILED\n===== 1 failed ====="
        TokenSaverTypedCrushersBridge.observeToolOutput(
            toolName: "Bash",
            output: first,
            bindingDigest: binding.digestHex
        )
        let originals = TokenSaverEncryptedOriginalStore(store: encrypted, scope: scope)
        let firstHandle = TokenSaverTypedCrushers.handleID(for: Data(first.utf8))
        XCTAssertEqual(originals.load(handle: "typed-crusher|\(firstHandle)"), Data(first.utf8))
        XCTAssertFalse(encrypted.plaintextExistsOnDisk(scanning: Data(first.utf8)))

        authority.revoke(binding: binding)
        let second = "test_b FAILED\n===== 1 failed ====="
        TokenSaverTypedCrushersBridge.observeToolOutput(
            toolName: "Bash",
            output: second,
            bindingDigest: binding.digestHex
        )
        let secondHandle = TokenSaverTypedCrushers.handleID(for: Data(second.utf8))
        XCTAssertNil(originals.load(handle: "typed-crusher|\(secondHandle)"))
    }
}
