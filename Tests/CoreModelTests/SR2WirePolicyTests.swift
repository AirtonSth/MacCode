import XCTest
@testable import CoreModel

final class SR2WirePolicyTests: XCTestCase {
    func testDetectsSR2BannerAndFields() {
        let wire = """
        @sr2 v0
        o:ok
        p:Sources/Foo.swift:12
        h:[[rc:ans_abc]]
        """
        XCTAssertTrue(SR2WirePolicy.isSR2(wire))
        XCTAssertEqual(
            SR2WirePolicy.channelKind(of: wire, isSR1: { _ in false }),
            .sr2
        )
    }

    func testRejectsBannerFollowedByFreeMonologue() {
        let malformed = """
        @sr2 v0
        o:ok
        The provider continued with a normal prose explanation.
        """
        XCTAssertFalse(SR2WirePolicy.isSR2(malformed))
        XCTAssertEqual(
            SR2WirePolicy.channelKind(of: malformed, isSR1: { _ in false }),
            .freeProse
        )
    }

    func testRejectsBannerWithoutValidOutcome() {
        XCTAssertFalse(SR2WirePolicy.isSR2("@sr2 v0\ng:goal\np:Sources/Foo.swift:12"))
        XCTAssertFalse(SR2WirePolicy.isSR2("@sr2 v0\no:maybe\np:Sources/Foo.swift:12"))
    }

    func testMalformedBannerFallsIntoFreeProseEnforcement() {
        let malformed = "@sr2 v0\no:ok\nThe provider continued with a normal prose explanation."
        let plan = SR2WirePolicy.dualChannelPersistPlan(
            modelOutput: malformed,
            humanizeOutput: malformed,
            tokenSaverOn: true,
            isSR1: { _ in false },
            storeProse: { _ in "deadbeef" }
        )

        XCTAssertEqual(plan.kind, .freeProse)
        XCTAssertTrue(plan.wasEnforced)
        XCTAssertTrue(SR2WirePolicy.isSR2(plan.historyText), plan.historyText)
        XCTAssertFalse(plan.historyText.contains("normal prose explanation"))
        XCTAssertEqual(plan.uiText, malformed)
    }

    func testFreeProseEnforcementProducesStubNotMonologue() {
        let prose = """
        A verificação revelou um segundo caso real: mesmo após corrigir os botões,
        acessar diretamente a URL sem / final ainda produz 301. Vou tratar isso no .htaccess.
        """
        let enforced = SR2WirePolicy.enforceFreeProse(prose, handle: "deadbeef")
        XCTAssertTrue(SR2WirePolicy.isSR2(enforced.wireStub))
        XCTAssertEqual(enforced.recoveryHandlePlaceholder, "[[rc:deadbeef]]")
        XCTAssertTrue(enforced.wireStub.contains("[[rc:deadbeef]]"))
        XCTAssertFalse(enforced.wireStub.contains("ans_"), "must not use ans_ prefix inside [[rc:]]")
        XCTAssertFalse(enforced.wireStub.contains("verificação revelou"))
        XCTAssertEqual(enforced.fullProse.trimmingCharacters(in: .whitespacesAndNewlines),
                       prose.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testClassifyTokenSaverOnFreeProseIsComplianceMiss() {
        let prose = String(repeating: "Long free monologue about apache rewrite. ", count: 4)
        let c = SR2WirePolicy.classifyForTokenSaver(
            response: prose,
            tokenSaverOn: true,
            isSR1: { _ in false },
            recoveryHandle: "h1"
        )
        XCTAssertEqual(c.kind, .freeProse)
        XCTAssertTrue(c.wasEnforced)
        XCTAssertTrue(c.complianceMiss)
        XCTAssertTrue(SR2WirePolicy.isSR2(c.providerHistoryText))
        XCTAssertEqual(c.uiSourceText.trimmingCharacters(in: .whitespacesAndNewlines),
                       prose.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(SR2WirePolicy.dualChannelAllows(
            providerHistoryText: c.providerHistoryText,
            uiHumanizedText: c.uiSourceText
        ))
    }

    func testClassifyTokenSaverOffLeavesProse() {
        let prose = "Hello world this is ordinary chat."
        let c = SR2WirePolicy.classifyForTokenSaver(
            response: prose,
            tokenSaverOn: false,
            isSR1: { _ in false }
        )
        XCTAssertFalse(c.wasEnforced)
        XCTAssertEqual(c.providerHistoryText, prose)
        XCTAssertEqual(c.uiSourceText, prose)
    }

    func testDualChannelRejectsHumanizedEqualsHistoryMonologue() {
        let monologue = "Here is a long explanation of the bug and the fix in prose form."
        XCTAssertFalse(SR2WirePolicy.dualChannelAllows(
            providerHistoryText: monologue,
            uiHumanizedText: monologue
        ))
        let wire = "@sr2 v0\no:ok\np:a.swift:1"
        XCTAssertTrue(SR2WirePolicy.dualChannelAllows(
            providerHistoryText: wire,
            uiHumanizedText: "Fixed the bug in a.swift line 1."
        ))
    }

    func testAlwaysOnInstructAppendsOnce() {
        let once = SR2WirePolicy.appendingAlwaysOnInstruct(to: "", tokenSaverHintOn: true)
        XCTAssertTrue(once.contains(SR2WirePolicy.instructBlockMarker))
        XCTAssertTrue(once.contains("Claude"))
        XCTAssertTrue(once.contains("Codex"))
        XCTAssertTrue(once.contains("Grok"))
        let twice = SR2WirePolicy.appendingAlwaysOnInstruct(to: once, tokenSaverHintOn: true)
        XCTAssertEqual(
            twice.components(separatedBy: SR2WirePolicy.instructBlockMarker).count - 1,
            1
        )
        let off = SR2WirePolicy.appendingAlwaysOnInstruct(to: "base", tokenSaverHintOn: false)
        XCTAssertEqual(off, "base")
    }

    func testProviderMatrixRequiresAllThree() {
        XCTAssertFalse(SR2WirePolicy.matrixIsComplete(coveredProviders: ["claude", "codex"]))
        XCTAssertTrue(SR2WirePolicy.matrixIsComplete(coveredProviders: ["claude", "codex", "grok"]))
        XCTAssertTrue(SR2WirePolicy.matrixIsComplete(coveredProviders: ["Claude", "CODEX", "Grok"]))
        XCTAssertEqual(Set(SR2WirePolicy.requiredProviders), Set(["claude", "codex", "grok"]))
    }

    func testComplianceScoreboardPerProvider() {
        let board = SR2WirePolicy.ComplianceScoreboard()
        board.record(.init(provider: "claude", kind: .sr2, wasEnforced: false, complianceMiss: false))
        board.record(.init(provider: "codex", kind: .freeProse, wasEnforced: true, complianceMiss: true))
        board.record(.init(provider: "codex", kind: .sr2, wasEnforced: false, complianceMiss: false))
        board.record(.init(provider: "grok", kind: .sr1, wasEnforced: false, complianceMiss: false))
        XCTAssertEqual(board.missRate(provider: "claude"), 0)
        XCTAssertEqual(board.missRate(provider: "codex"), 0.5, accuracy: 0.001)
        XCTAssertEqual(board.missRate(provider: "grok"), 0)
        let snap = board.snapshot()
        XCTAssertEqual(snap["codex"]?.enforced, 1)
        XCTAssertEqual(snap["claude"]?.turns, 1)
    }

    func testSR2PreferredOverSR1WhenBothSignals() {
        let wire = """
        @sr2 v0
        o:ok
        g:goal
        """
        // Even if isSR1 would return true, channel prefers SR2 when banner present.
        let kind = SR2WirePolicy.channelKind(of: wire, isSR1: { _ in true })
        XCTAssertEqual(kind, .sr2)
    }

    func testDualChannelPersistPlanFreeProseStoresAndHistoryIsStub() {
        let prose = String(repeating: "Monologue about apache rewrite and htaccess. ", count: 3)
        var stored: [String: String] = [:]
        let plan = SR2WirePolicy.dualChannelPersistPlan(
            modelOutput: prose,
            humanizeOutput: prose,
            tokenSaverOn: true,
            isSR1: { _ in false },
            storeProse: { text in
                let handle = "deadbeef\(stored.count)"
                stored[handle] = text
                return handle
            }
        )
        XCTAssertTrue(plan.wasEnforced)
        XCTAssertTrue(plan.shouldEmitTranslation)
        XCTAssertTrue(SR2WirePolicy.isSR2(plan.historyText), "history must be wire stub not monologue")
        XCTAssertFalse(plan.historyText.contains("Monologue about apache"))
        XCTAssertTrue(plan.historyText.contains("[[rc:"), plan.historyText)
        XCTAssertFalse(plan.historyText.contains("ans_"), plan.historyText)
        // Marker must embed the store handle so normalize("[[rc:<h>]]") == h.
        for (handle, _) in stored {
            XCTAssertTrue(
                plan.historyText.contains(SR2WirePolicy.recoveryMarker(for: handle)),
                "stub must embed recoveryMarker for handle \(handle)"
            )
        }
        XCTAssertEqual(plan.uiText.trimmingCharacters(in: .whitespacesAndNewlines),
                       prose.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertFalse(stored.isEmpty, "prose must be stored under handle")
        XCTAssertTrue(SR2WirePolicy.dualChannelAllows(
            providerHistoryText: plan.historyText,
            uiHumanizedText: plan.uiText
        ))
    }

    func testDualChannelPersistPlanStoreFailureFailsOpenWithOriginalHistory() {
        let prose = "Short answer that must remain recoverable when the durable store is unavailable."
        let plan = SR2WirePolicy.dualChannelPersistPlan(
            modelOutput: prose,
            humanizeOutput: prose,
            tokenSaverOn: true,
            isSR1: { _ in false },
            storeProse: { _ in nil }
        )

        XCTAssertEqual(plan.historyText, prose,
                       "storage failure must never replace provider history with an unresolved stub")
        XCTAssertEqual(plan.uiText, prose)
        XCTAssertFalse(plan.wasEnforced)
        XCTAssertFalse(plan.shouldEmitTranslation)
        XCTAssertTrue(plan.complianceMiss,
                      "a failed admission remains observable without losing the original")
        XCTAssertFalse(plan.historyText.contains("[[rc:"))
    }

    func testRecoveryMarkerExtractionReturnsStoreCompatibleMarker() {
        let wire = "@sr2 v0\no:ok\nh:[[rc:deadbeef]]"
        XCTAssertEqual(SR2WirePolicy.recoveryMarker(in: wire), "[[rc:deadbeef]]")
        XCTAssertNil(SR2WirePolicy.recoveryMarker(in: "@sr2 v0\no:ok"))
    }

    func testActionOnlyAndAnswerAsHandleWires() {
        let cont = SR2WirePolicy.actionOnlyWire(paths: ["a.swift:1"])
        XCTAssertTrue(SR2WirePolicy.isSR2(cont))
        XCTAssertTrue(cont.contains("o:cont"))
        XCTAssertTrue(cont.contains("p:a.swift:1"))

        let ans = SR2WirePolicy.answerAsHandleWire(handle: "abc123", outcome: "ok", paths: ["b.swift:2"])
        XCTAssertTrue(SR2WirePolicy.isSR2(ans))
        XCTAssertTrue(ans.contains(SR2WirePolicy.recoveryMarker(for: "abc123")))
        XCTAssertTrue(ans.contains("p:b.swift:2"))
        XCTAssertFalse(ans.contains("ans_"))
    }

    func testComplianceExportIncludesAllRecordedProviders() {
        SR2WirePolicy.sharedCompliance.reset()
        SR2WirePolicy.sharedCompliance.record(.init(provider: "claude", kind: .sr2, wasEnforced: false, complianceMiss: false))
        SR2WirePolicy.sharedCompliance.record(.init(provider: "codex", kind: .freeProse, wasEnforced: true, complianceMiss: true))
        SR2WirePolicy.sharedCompliance.record(.init(provider: "grok", kind: .sr1, wasEnforced: false, complianceMiss: false))
        let json = SR2WirePolicy.complianceExportJSON()
        XCTAssertTrue(json.contains("claude"))
        XCTAssertTrue(json.contains("codex"))
        XCTAssertTrue(json.contains("grok"))
        XCTAssertTrue(json.contains("miss_rate"))
        XCTAssertTrue(SR2WirePolicy.matrixIsComplete(coveredProviders: ["claude", "codex", "grok"]))
    }

    func testDualChannelPersistPlanSR2KeepsWireInHistory() {
        let wire = """
        @sr2 v0
        o:ok
        p:a.swift:1
        """
        let human = "Fixed a.swift line 1."
        let plan = SR2WirePolicy.dualChannelPersistPlan(
            modelOutput: wire,
            humanizeOutput: human,
            tokenSaverOn: true,
            isSR1: { _ in false },
            storeProse: nil
        )
        XCTAssertEqual(plan.historyText.trimmingCharacters(in: .whitespacesAndNewlines),
                       wire.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(plan.uiText, human)
        XCTAssertTrue(plan.shouldEmitTranslation)
        XCTAssertFalse(plan.wasEnforced)
    }
}
