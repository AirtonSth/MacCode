import XCTest
@testable import CoreModel

final class TokenSaverTypedCrushersTests: XCTestCase {
    private func liveRegistry() -> TokenSaverTypedCrushers.Registry {
        let r = TokenSaverTypedCrushers.Registry()
        r.enableAllForTesting()
        return r
    }

    private let masterON = true

    func test_defaultOff_deniesAllCrushers() {
        XCTAssertFalse(TokenSaverTypedCrushers.defaultEnabled)
        let reg = TokenSaverTypedCrushers.Registry()
        reg.enableAllForTesting()
        // Master still OFF → all deny
        XCTAssertFalse(TokenSaverTypedCrushers.crushPytest(
            original: "1 failed", failureLines: ["f"], registry: reg
        ).accepted)
        XCTAssertFalse(TokenSaverTypedCrushers.crushStacktrace(
            original: "at a\nat a", registry: reg
        ).accepted)
        XCTAssertFalse(TokenSaverTypedCrushers.crushDiff(
            original: "+a\n-b", isBinary: false, registry: reg
        ).accepted)
        XCTAssertFalse(TokenSaverTypedCrushers.crushSearch(
            original: "m1", matchLines: ["m1"], registry: reg
        ).accepted)
        XCTAssertFalse(TokenSaverTypedCrushers.crushAdaptiveJSON(
            original: "{\"a\":1}", registry: reg
        ).accepted)
    }

    func test_registryOFF_deniesEvenWithMasterON() {
        let reg = TokenSaverTypedCrushers.Registry() // all false
        XCTAssertFalse(TokenSaverTypedCrushers.crushPytest(
            original: "1 failed", failureLines: ["fail"], registry: reg, masterEnabled: masterON
        ).accepted)
    }

    func test_releaseSealActivatesOnlyItsBinding() {
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
        let consent = TokenSaverAuthorityPlane.ConsentState(
            exactLossless: true,
            semanticLocalAI: false,
            isLegacyPreference: false
        )
        let seal = TokenSaverAuthorityPlane.mintReleaseSeal(
            binding: binding,
            registry: authority,
            manifest: manifest,
            consent: consent,
            requiresSemantic: false
        )
        XCTAssertNotNil(seal)

        let registry = TokenSaverTypedCrushers.Registry()
        registry.activate([.pytest], releaseSeal: seal!)
        XCTAssertTrue(registry.isEnabled(.pytest, bindingDigest: binding.digestHex))
        XCTAssertFalse(registry.isEnabled(.pytest, bindingDigest: "other"))
        XCTAssertFalse(registry.isEnabled(.diff, bindingDigest: binding.digestHex))
        authority.revoke(binding: binding)
        XCTAssertFalse(registry.isEnabled(.pytest, bindingDigest: binding.digestHex))
        registry.deactivate()
        XCTAssertFalse(registry.isEnabled(.pytest, bindingDigest: binding.digestHex))
    }

    func test_pytest_ON_parsesFailedCountAndStores() {
        let reg = liveRegistry()
        let store = TokenSaverTypedCrushers.MemoryStore()
        let original = """
        test_a FAILED
        test_b FAILED
        ===== 2 failed, 3 passed in 0.1s =====
        """
        let r = TokenSaverTypedCrushers.crushPytest(
            original: original,
            failureLines: ["test_a FAILED", "test_b FAILED"],
            store: store,
            registry: reg,
            masterEnabled: masterON
        )
        XCTAssertTrue(r.accepted)
        XCTAssertNotNil(r.handle)
        XCTAssertEqual(r.handle?.count, 64)
        XCTAssertEqual(TokenSaverTypedCrushers.readback(handle: r.handle!, store: store), Data(original.utf8))
        XCTAssertTrue(r.collapsed!.contains("[[rc:"))
        // Mismatch count → deny
        let bad = TokenSaverTypedCrushers.crushPytest(
            original: original,
            failureLines: ["only-one"],
            store: store,
            registry: reg,
            masterEnabled: masterON
        )
        XCTAssertFalse(bad.accepted)
    }

    func test_stacktrace_consecutiveRLE_only() {
        let reg = liveRegistry()
        let store = TokenSaverTypedCrushers.MemoryStore()
        let original = """
        Exception: boom
        at foo
        at foo
        at foo
        at bar
        root cause here
        """
        let r = TokenSaverTypedCrushers.crushStacktrace(
            original: original, store: store, registry: reg, masterEnabled: masterON
        )
        XCTAssertTrue(r.accepted)
        XCTAssertTrue(r.collapsed!.contains("⟦×3⟧"))
        XCTAssertTrue(r.collapsed!.contains("Exception: boom"))
        XCTAssertTrue(r.collapsed!.contains("root cause here"))
        XCTAssertTrue(r.collapsed!.contains("at bar"))
        XCTAssertEqual(TokenSaverTypedCrushers.readback(handle: r.handle!, store: store), Data(original.utf8))
        // Distinct frames only → no consecutive run → deny
        let noRun = TokenSaverTypedCrushers.crushStacktrace(
            original: "at a\nat b\nat c", store: store, registry: reg, masterEnabled: masterON
        )
        XCTAssertFalse(noRun.accepted)
    }

    func test_diff_requiresUnifiedHeader_collapsesContext() {
        let reg = liveRegistry()
        let store = TokenSaverTypedCrushers.MemoryStore()
        let unified = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,8 +1,8 @@
         c1
         c2
         c3
         c4
        -old
        +new
         c5
         c6
         c7
         c8
        """
        let ok = TokenSaverTypedCrushers.crushDiff(
            original: unified, isBinary: false,
            store: store, registry: reg, masterEnabled: masterON
        )
        XCTAssertTrue(ok.accepted)
        // Property: every +/- change line preserved in order (array equality, not set)
        let origChanges = TokenSaverTypedCrushers.diffChangeLines(unified)
        let collChanges = TokenSaverTypedCrushers.diffChangeLines(ok.collapsed!)
        XCTAssertEqual(origChanges, collChanges)
        // Multi-hunk + ++++ body lines
        let multi = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1 +1 @@
        -old
        +new
        @@ -2 +2 @@
        ----keep
        ++++keep
        -a
        -a
        +b
        """
        let m = TokenSaverTypedCrushers.crushDiff(
            original: multi, isBinary: false, store: store, registry: reg, masterEnabled: masterON
        )
        XCTAssertTrue(m.accepted)
        XCTAssertEqual(
            TokenSaverTypedCrushers.diffChangeLines(multi),
            TokenSaverTypedCrushers.diffChangeLines(m.collapsed!)
        )
        XCTAssertTrue(m.collapsed!.contains("++++keep"))
        XCTAssertTrue(m.collapsed!.contains("----keep"))
        // Tab-delimited headers are headers, not change lines
        let tabbed = "diff --git a/f b/f\n---\ta/f\n+++\tb/f\n@@ -1 +1 @@\n-old\n+new\n"
        XCTAssertTrue(TokenSaverTypedCrushers.isUnifiedDiff(tabbed))
        XCTAssertFalse(TokenSaverTypedCrushers.diffChangeLines(tabbed).contains { $0.hasPrefix("---\t") })
        let tabR = TokenSaverTypedCrushers.crushDiff(
            original: tabbed, isBinary: false, store: store, registry: reg, masterEnabled: masterON
        )
        XCTAssertTrue(tabR.accepted)
        XCTAssertEqual(
            TokenSaverTypedCrushers.diffChangeLines(tabbed),
            TokenSaverTypedCrushers.diffChangeLines(tabR.collapsed!)
        )
        // Not a unified diff → deny
        XCTAssertFalse(TokenSaverTypedCrushers.crushDiff(
            original: "+x\n-y", isBinary: false, store: store, registry: reg, masterEnabled: masterON
        ).accepted)
        XCTAssertFalse(TokenSaverTypedCrushers.crushDiff(
            original: unified, isBinary: true, store: store, registry: reg, masterEnabled: masterON
        ).accepted)
    }

    func test_adaptive_lowCoverageDenied() {
        let reg = liveRegistry()
        let store = TokenSaverTypedCrushers.MemoryStore()
        // 100 elements, window 2 → omit 96% > 80% → deny
        let elems = (0..<100).map { String($0) }.joined(separator: ",")
        let big = "[\(elems)]"
        let r = TokenSaverTypedCrushers.crushAdaptiveJSON(
            original: big, windowElements: 2, store: store, registry: reg, masterEnabled: masterON
        )
        XCTAssertFalse(r.accepted)
    }

    func test_adaptive_diversityGate() {
        // Array of alternating types; window 1 keeps only first and last (both numbers if pattern ends same)
        // [0, "a", 1, "b", 2, "c", 3, "d"] — 8 elems, window 1 → omit 6 = 75% OK for %,
        // kept [0, "d"] has 2 kinds → OK. Force diversity fail: all kinds in middle only.
        // Use window 1 on [0,0,0,0,"s","s","s","s"] with head/tail both 0 → 1 kind while allKinds=2
        let arr = "[0,0,0,0,\"s\",\"s\",\"s\",\"s\"]"
        // window 1: head [0], tail ["s"] → 2 kinds OK. Use window that keeps only zeros:
        // Actually prefix(1)+suffix(1) on this is 0 and "s". Need head and tail same kind.
        let sameEnds = "[0,\"a\",\"b\",\"c\",\"d\",1]" // head 0 tail 1 — both number, middle has strings
        // allKinds = number,string; kept = number only → diversity fail if omit>0
        // 6 elems window 1 → omit 4 = 66% < 80%, kinds kept=1 < 2 → deny
        XCTAssertFalse(TokenSaverTypedCrushers.adaptiveCoverageOK(
            obj: try! JSONSerialization.jsonObject(with: Data(sameEnds.utf8)),
            omitted: 4,
            windowElements: 1
        ))
        let reg = liveRegistry()
        let store = TokenSaverTypedCrushers.MemoryStore()
        let r = TokenSaverTypedCrushers.crushAdaptiveJSON(
            original: sameEnds, windowElements: 1, store: store, registry: reg, masterEnabled: masterON
        )
        XCTAssertFalse(r.accepted)
    }

    func test_search_preservesMatchesWithHandle() {
        let reg = liveRegistry()
        let store = TokenSaverTypedCrushers.MemoryStore()
        let original = "path:1:matchA\npath:2:matchB"
        let r = TokenSaverTypedCrushers.crushSearch(
            original: original,
            matchLines: ["path:1:matchA", "path:2:matchB"],
            store: store,
            registry: reg,
            masterEnabled: masterON
        )
        XCTAssertTrue(r.accepted)
        XCTAssertTrue(r.collapsed!.contains("path:1:matchA"))
        XCTAssertTrue(r.collapsed!.contains("[[rc:"))
        XCTAssertEqual(TokenSaverTypedCrushers.readback(handle: r.handle!, store: store), Data(original.utf8))
    }

    func test_adaptiveJSON_arrayWindowPreservesCount() {
        let reg = liveRegistry()
        let store = TokenSaverTypedCrushers.MemoryStore()
        let elems = (0..<20).map { "\"e\($0)\"" }.joined(separator: ",")
        let big = "[\(elems)]"
        let r = TokenSaverTypedCrushers.crushAdaptiveJSON(
            original: big, windowElements: 2, store: store, registry: reg, masterEnabled: masterON
        )
        XCTAssertTrue(r.accepted)
        XCTAssertTrue(r.collapsed!.contains("omitted"))
        XCTAssertTrue(r.collapsed!.contains("20"))
        XCTAssertTrue(r.collapsed!.contains("[[rc:"))
        XCTAssertEqual(TokenSaverTypedCrushers.readback(handle: r.handle!, store: store), Data(big.utf8))
        // Compact object with whitespace: minify accept, no omission marker
        let objSpaced = "{\n  \"a\" : 1\n}"
        let objR = TokenSaverTypedCrushers.crushAdaptiveJSON(
            original: objSpaced, store: store, registry: reg, masterEnabled: masterON
        )
        XCTAssertTrue(objR.accepted, "whitespace object must minify with gain")
        XCTAssertFalse(objR.collapsed!.contains("omitted"))
        XCTAssertTrue(objR.collapsed!.contains("[[rc:"))
        // Already-minified object: no gain → deny (never char-slice objects)
        let minObj = "{\"a\":1}"
        let noGain = TokenSaverTypedCrushers.crushAdaptiveJSON(
            original: minObj, store: store, registry: reg, masterEnabled: masterON
        )
        XCTAssertFalse(noGain.accepted)
        // Single-header prose is not unified diff
        XCTAssertFalse(TokenSaverTypedCrushers.isUnifiedDiff("--- a/f\n+x"))
        XCTAssertFalse(TokenSaverTypedCrushers.isUnifiedDiff("diff --git only\n+x"))
        XCTAssertTrue(TokenSaverTypedCrushers.isUnifiedDiff("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b"))
    }

    func test_stack_nonFrameProseNotCollapsed() {
        XCTAssertFalse(TokenSaverTypedCrushers.isStackFrameLine("fatal at shutdown"))
        XCTAssertTrue(TokenSaverTypedCrushers.isStackFrameLine("at com.foo.Bar.main"))
        let reg = liveRegistry()
        let store = TokenSaverTypedCrushers.MemoryStore()
        // Prose "at" repeated is not a frame run
        let prose = "fatal at shutdown\nfatal at shutdown\nfatal at shutdown"
        XCTAssertFalse(TokenSaverTypedCrushers.crushStacktrace(
            original: prose, store: store, registry: reg, masterEnabled: masterON
        ).accepted)
    }

    func test_storeFailure_denies() {
        final class FailStore: TokenSaverTypedCrushers.BlobStore {
            func store(id: String, plaintext: Data) throws { throw NSError(domain: "t", code: 1) }
            func retrieve(id: String) throws -> Data { throw NSError(domain: "t", code: 2) }
        }
        let reg = liveRegistry()
        let r = TokenSaverTypedCrushers.crushSearch(
            original: "m", matchLines: ["m"], store: FailStore(), registry: reg, masterEnabled: masterON
        )
        XCTAssertFalse(r.accepted)
        XCTAssertNil(r.handle)
    }

    func test_parsePytestFailedCount() {
        XCTAssertEqual(TokenSaverTypedCrushers.parsePytestFailedCount("===== 2 failed, 3 passed ====="), 2)
        XCTAssertNil(TokenSaverTypedCrushers.parsePytestFailedCount("all green"))
    }

    func test_readback_fullSHA() {
        let store = TokenSaverTypedCrushers.MemoryStore()
        let data = Data("payload".utf8)
        let h = TokenSaverTypedCrushers.handleID(for: data)
        XCTAssertEqual(h.count, 64)
        XCTAssertEqual(TokenSaverTypedCrushers.storeVerified(data, store: store), h)
        XCTAssertEqual(TokenSaverTypedCrushers.readback(handle: h, store: store), data)
    }
}
