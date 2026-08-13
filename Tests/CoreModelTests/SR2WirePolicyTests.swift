import XCTest
import CryptoKit
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
        XCTAssertFalse(SR2WirePolicy.isCurrentSR2(wire),
                       "legacy v0 stays readable but is not current provider compliance")
        XCTAssertEqual(
            SR2WirePolicy.channelKind(of: wire, isSR1: { _ in false }),
            .sr2
        )
    }

    func testAcceptsExactR9FinalWireAndRejectsWireSyntaxAnywhereInHumanizedText() {
        // WHY: the live R9 provider used `o:done`. Treating that terminal outcome
        // as free prose routed the source through the wrong fallback and allowed a
        // partial local-model rendering to become the durable UI translation.
        let wire = "@sr2 v0\no:done\np:1=/Users/samuelfajreldines/.remote-code/bin/swift;/Users/samuelfajreldines/.remote-code/bin/distill\np:2=3:UNIQUE_EXACT_MATCH=sr2-e2e-20260811\np:3=swift noisy.swift completed"
        XCTAssertEqual(wire.utf8.count, 190, "the regression fixture must stay byte-exact")
        XCTAssertEqual(
            SHA256.hash(data: Data(wire.utf8)).map { String(format: "%02x", $0) }.joined(),
            "62fa521bfb14b851a5065616001e514a74f34b120ac7684a74b985ffd2bf39f0",
            "the frozen live R9 fixture must not drift"
        )
        XCTAssertTrue(SR2WirePolicy.isSR2(wire), wire)

        let leaked = "done\n@sr2 v0\n1=/Users/samuelfajreldines/.remote-code/bin/swift;/Users/samuelfajreldines/.remote-code/bin/distill"
        XCTAssertTrue(SR2WirePolicy.containsHumanizationWireSyntax(leaked))
        XCTAssertTrue(SR2WirePolicy.containsHumanizationWireSyntax("Looks good\nP:tests green"))
        XCTAssertFalse(SR2WirePolicy.containsHumanizationWireSyntax("O Snake game foi criado."))
        XCTAssertFalse(SR2WirePolicy.containsHumanizationWireSyntax("O jogo foi verificado com sucesso."))
        XCTAssertTrue(SR2WirePolicy.containsHumanizationWireSyntax("O Snake criado.\nP browser smoke passou."))
        XCTAssertFalse(
            SR2WirePolicy.containsHumanizationWireSyntax("Here is a concise natural-language result."),
            "ordinary prose must remain eligible as a humanizer result"
        )
        let rendered = try? XCTUnwrap(SR2WirePolicy.deterministicHumanizedWire(wire))
        XCTAssertEqual(
            rendered,
            "Completed.\nEvidence 1: /Users/samuelfajreldines/.remote-code/bin/swift;/Users/samuelfajreldines/.remote-code/bin/distill.\nEvidence 2: 3:UNIQUE_EXACT_MATCH=sr2-e2e-20260811.\nEvidence 3: swift noisy.swift completed."
        )
        XCTAssertFalse(rendered?.contains("@sr2") == true)
        XCTAssertFalse(rendered?.contains("p:1=") == true)
    }

    func testExactR17BanneredWireNeverBecomesDefaultDisplay() {
        // WHY: the live R17 Codex final used an `o:` value outside the strict
        // outcome grammar. It is still provider-originated, bannered SR2-like
        // text, so a humanizer leak/timeout must not make the wire the UI leg.
        let wire = "@sr2 v1\ng:run-summary\no:swift=/tmp/RemoteCodeAgentCanary-r17.9NjZ6W/state/Application Support/RemoteCodeAgentCanary/ManagedIntegrationHome/.remote-code/bin/swift; distill=/tmp/RemoteCodeAgentCanary-r17.9NjZ6W/state/Application Support/RemoteCodeAgentCanary/ManagedIntegrationHome/.remote-code/bin/distill\\nREADME.md:3 UNIQUE_EXACT_MATCH=sr2-e2e-20260811; noisy.swift=200 lines\nd:exit=0; files-edited=0"
        XCTAssertEqual(wire.count, 401, "the live R17 fixture must stay character-exact")
        XCTAssertEqual(
            SHA256.hash(data: Data(wire.utf8)).map { String(format: "%02x", $0) }.joined(),
            "f1e7839008cd5493b45b4dc9d861396773c2720b1ca3957f2c332de64c16d99a",
            "the frozen live R17 provider final must not drift"
        )
        XCTAssertFalse(SR2WirePolicy.isSR2(wire),
                       "strict grammar must continue reporting the invalid outcome")

        let plan = SR2WirePolicy.dualChannelPersistPlan(
            modelOutput: wire,
            humanizeOutput: wire,
            tokenSaverOn: true,
            isSR1: { _ in false },
            storeProse: { _ in "f1e7839008cd5493b45b4dc9d861396773c2720b1ca3957f2c332de64c16d99a" }
        )

        XCTAssertTrue(plan.complianceMiss)
        XCTAssertTrue(plan.shouldEmitTranslation)
        XCTAssertNotEqual(plan.uiText, wire)
        XCTAssertFalse(plan.uiText.localizedCaseInsensitiveContains("@sr2"), plan.uiText)
        XCTAssertTrue(plan.uiText.contains("swift"), plan.uiText)
        XCTAssertTrue(plan.uiText.contains("distill"), plan.uiText)
        XCTAssertTrue(plan.uiText.contains("UNIQUE_EXACT_MATCH=sr2-e2e-20260811"), plan.uiText)
        XCTAssertEqual(plan.historyText.count, 160)
        XCTAssertEqual(
            SHA256.hash(data: Data(plan.historyText.utf8)).map { String(format: "%02x", $0) }.joined(),
            "01002a5dc11d0005ddc0dbbe06f889bf7f919b00e871542503c4b1077a49087c",
            "the canonical R17 provider-history stub must remain exact"
        )
        XCTAssertEqual(
            SR2WirePolicy.providerOriginal(in: plan.historyText) { marker in
                marker == "[[rc:f1e7839008cd5493b45b4dc9d861396773c2720b1ca3957f2c332de64c16d99a]]"
                    ? wire
                    : nil
            },
            wire,
            "View original must resolve the byte-exact provider final"
        )
    }

    func testMalformedBanneredProviderOutputFailsToSafeNaturalDisplay() {
        let malformed = "@sr2 v1\nthis line is not SR2\nraw control-like payload"
        let plan = SR2WirePolicy.dualChannelPersistPlan(
            modelOutput: malformed,
            humanizeOutput: malformed,
            tokenSaverOn: true,
            isSR1: { _ in false },
            storeProse: nil
        )

        XCTAssertTrue(plan.complianceMiss)
        XCTAssertTrue(plan.shouldEmitTranslation)
        XCTAssertEqual(plan.uiText, "I could not expand the SR2 response.")
        XCTAssertFalse(plan.uiText.contains("@sr2"))
        XCTAssertEqual(SR2WirePolicy.providerOriginal(in: plan.historyText), malformed)
    }

    func testDualChannelRejectsLeakedHumanizerWireButPreservesNaturalQuotedExampleByProvenance() throws {
        let wire = "@sr2 v0\no:done\np:1=first proof\np:2=second proof\np:3=third proof"
        let leaked = "done\n@sr2 v0\n1=first proof"
        let wirePlan = SR2WirePolicy.dualChannelPersistPlan(
            modelOutput: wire,
            humanizeOutput: leaked,
            tokenSaverOn: true,
            isSR1: { _ in false },
            storeProse: nil
        )
        XCTAssertEqual(
            wirePlan.uiText,
            "Completed.\nEvidence 1: first proof.\nEvidence 2: second proof.\nEvidence 3: third proof."
        )
        XCTAssertTrue(wirePlan.shouldEmitTranslation)

        let natural = "Here is the user-requested example:\n@sr2 v1\ng:example"
        let naturalPlan = SR2WirePolicy.dualChannelPersistPlan(
            modelOutput: natural,
            humanizeOutput: natural,
            tokenSaverOn: true,
            isSR1: { _ in false },
            storeProse: { _ in "verified-handle" }
        )
        XCTAssertEqual(
            naturalPlan.uiText,
            natural,
            "trusted natural source provenance must preserve a legitimate marker example verbatim"
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

    func testAcceptsSR2V1SemanticWorkflowFields() {
        let wire = """
        @sr2 v1
        g:admin-foundation-v3|star-api-v3
        flow:/sam-task>verify>gh:merge-main>green>deploy>retest
        done:flow
        tools:Chrome|ComputerUse
        """
        XCTAssertTrue(SR2WirePolicy.isSR2(wire), wire)
        XCTAssertTrue(SR2WirePolicy.isCurrentSR2(wire), wire)
    }

    func testAcceptsTrackerDeliveryV1Sample() {
        let wire = SR2WirePolicy.trackerDeliveryV1Sample
        XCTAssertTrue(SR2WirePolicy.isSR2(wire), wire)
        XCTAssertTrue(SR2WirePolicy.isCurrentSR2(wire), wire)
        XCTAssertTrue(SR2WirePolicy.alwaysOnInstructBlock.contains(wire), wire)
        XCTAssertTrue(SR2WirePolicy.structuredFieldKeys.contains("goal"))
        XCTAssertTrue(SR2WirePolicy.structuredFieldKeys.contains("trello-comment"))
    }

    func testAcceptsCanonicalExactCommandV1Fields() {
        let wire = """
        @sr2 v1
        run:command -v swift;command -v distill
        out:=2lines
        !file-edit
        """

        XCTAssertTrue(SR2WirePolicy.isSR2(wire), wire)
        XCTAssertTrue(SR2WirePolicy.isCurrentSR2(wire), wire)
        XCTAssertTrue(SR2WirePolicy.alwaysOnInstructBlock.contains("run:a;b"))
        XCTAssertTrue(SR2WirePolicy.alwaysOnInstructBlock.contains("!file-edit"))
    }

    func testAcceptsIndexedPerCommandOutputCardinalityV1Field() {
        let wire = """
        @sr2 v1
        run:[command -v swift;command -v distill]>[rg -n UNIQUE_EXACT_MATCH README.md]>[swift noisy.swift]
        out:1=2lines,2=1line
        !file-edit
        done:run+summary
        """

        XCTAssertTrue(SR2WirePolicy.isSR2(wire), wire)
        XCTAssertTrue(SR2WirePolicy.isCurrentSR2(wire), wire)
        XCTAssertTrue(SR2WirePolicy.alwaysOnInstructBlock.contains("run:[a;b]>[c]"))
        XCTAssertTrue(SR2WirePolicy.alwaysOnInstructBlock.contains("separate ordered shell tool calls"))
        XCTAssertTrue(SR2WirePolicy.alwaysOnInstructBlock.contains("explicit `| distill`"))
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
        XCTAssertEqual(plan.uiText, "ok.")
        XCTAssertFalse(plan.uiText.localizedCaseInsensitiveContains("@sr2"), plan.uiText)
        XCTAssertEqual(
            SR2WirePolicy.providerOriginal(in: plan.historyText) { marker in
                marker == "[[rc:deadbeef]]" ? malformed : nil
            },
            malformed,
            "malformed provider wire must remain available only through View original"
        )
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

    func testUserInstructionWireRoundTripsMultilinePrompt() {
        // WHY: user prompts may contain exact paths, quotes, and newlines. The
        // paid provider may receive SR2 only when that envelope is lossless.
        let prompt = "Fix /tmp/Foo.swift:42\nKeep \"abc-123\" exact."
        let wire = SR2WirePolicy.userInstructionWire(prompt)

        XCTAssertTrue(SR2WirePolicy.isSR2(wire), wire)
        XCTAssertTrue(SR2WirePolicy.isCurrentSR2(wire), wire)
        XCTAssertEqual(SR2WirePolicy.userInstruction(in: wire), prompt)
    }

    func testTrustedHostInstructionWireIsSeparateFromCanonicalUserWire() {
        let host = "REMOTE_CODE_AUTO_ORCHESTRATION_V1\nSESSION_LEARN_EXACT_SCOPE:\n- preserve command output"
        let hostWire = SR2WirePolicy.trustedHostInstructionWire(host)
        XCTAssertEqual(SR2WirePolicy.trustedHostInstruction(in: hostWire), host)
        XCTAssertNil(SR2WirePolicy.userInstruction(in: hostWire))

        let userWire = """
        @sr2 v1
        run:command -v swift;command -v distill;command -v git
        out:=3lines
        !file-edit
        done:run
        """
        XCTAssertNil(SR2WirePolicy.trustedHostInstruction(in: userWire))
        XCTAssertTrue(SR2WirePolicy.isSR2(userWire))
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
        XCTAssertTrue(SR2WirePolicy.isCurrentSR2(plan.historyText))
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
        XCTAssertEqual(
            SR2WirePolicy.providerOriginal(in: plan.historyText) { marker in
                stored[marker.replacingOccurrences(of: "[[rc:", with: "")
                    .replacingOccurrences(of: "]]", with: "")]
            },
            prose
        )
        XCTAssertTrue(SR2WirePolicy.dualChannelAllows(
            providerHistoryText: plan.historyText,
            uiHumanizedText: plan.uiText
        ))
    }

    func testDualChannelPersistPlanStoreFailureUsesLosslessInlineV1History() {
        let prose = "  Short answer that must remain recoverable.\nLinha dois.  "
        let plan = SR2WirePolicy.dualChannelPersistPlan(
            modelOutput: prose,
            humanizeOutput: prose,
            tokenSaverOn: true,
            isSR1: { _ in false },
            storeProse: { _ in nil }
        )

        XCTAssertTrue(SR2WirePolicy.isCurrentSR2(plan.historyText), plan.historyText)
        XCTAssertEqual(SR2WirePolicy.providerOriginal(in: plan.historyText), prose,
                       "inline v1 must recover the exact pre-normalization provider bytes")
        XCTAssertEqual(plan.uiText, prose)
        XCTAssertTrue(plan.wasEnforced)
        XCTAssertTrue(plan.shouldEmitTranslation)
        XCTAssertTrue(plan.complianceMiss,
                      "a failed admission remains observable without losing the original")
        XCTAssertTrue(plan.historyText.contains("h:inline-base64:"))

        let tampered = plan.historyText.replacingOccurrences(of: "p:sha256=", with: "p:sha256=0")
        XCTAssertNil(SR2WirePolicy.providerOriginal(in: tampered),
                     "raw disclosure must fail closed when the digest binding is changed")
    }

    func testRecoveryMarkerExtractionReturnsStoreCompatibleMarker() {
        let wire = "@sr2 v0\no:ok\nh:[[rc:deadbeef]]"
        XCTAssertEqual(SR2WirePolicy.recoveryMarker(in: wire), "[[rc:deadbeef]]")
        XCTAssertNil(SR2WirePolicy.recoveryMarker(in: "@sr2 v0\no:ok"))
    }

    func testActionOnlyAndAnswerAsHandleWires() {
        let cont = SR2WirePolicy.actionOnlyWire(paths: ["a.swift:1"])
        XCTAssertTrue(SR2WirePolicy.isCurrentSR2(cont))
        XCTAssertTrue(cont.contains("o:cont"))
        XCTAssertTrue(cont.contains("p:a.swift:1"))

        let ans = SR2WirePolicy.answerAsHandleWire(handle: "abc123", outcome: "ok", paths: ["b.swift:2"])
        XCTAssertTrue(SR2WirePolicy.isCurrentSR2(ans))
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

    func testDualChannelPersistPlanLegacySR2UpgradesHistoryAndPreservesExactRaw() {
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
        XCTAssertTrue(SR2WirePolicy.isCurrentSR2(plan.historyText), plan.historyText)
        XCTAssertFalse(plan.historyText.contains("@sr2 v0"))
        XCTAssertEqual(SR2WirePolicy.providerOriginal(in: plan.historyText), wire)
        XCTAssertEqual(plan.uiText, human)
        XCTAssertTrue(plan.shouldEmitTranslation)
        XCTAssertTrue(plan.wasEnforced)
        XCTAssertTrue(plan.complianceMiss)
    }
}
