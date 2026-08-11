import XCTest
@testable import CoreModel

/// Integration-style test of the dual-channel applicator used by AgentRunCoordinator
/// after `tokenSaverHumanizeSR1Response` returns. Drives the shipped
/// `SR2WirePolicy.dualChannelPersistPlan` end-to-end with a real store function
/// (content-addressed handle map), asserting history ≠ monologue.
final class SR2DualChannelApplicatorTests: XCTestCase {
    final class ProseStore: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var values: [String: String] = [:]

        func store(_ prose: String) -> String {
            lock.lock()
            defer { lock.unlock() }
            let handle = String(prose.utf8.prefix(8).map { String(format: "%02x", $0) }.joined().prefix(16))
            values[handle] = prose
            return handle
        }
    }

    /// Mirrors AppContext + coordinator: humanize passthrough for free prose,
    /// then dual-channel plan with store-before-stub.
    func applyTokenSaverDualChannel(
        modelOutput: String,
        tokenSaverOn: Bool,
        store: ProseStore
    ) -> (history: String, ui: String, original: String, rewritten: String) {
        // Phase 1: humanize (free prose returns prose unchanged — same as AppContext).
        let classified = SR2WirePolicy.classifyForTokenSaver(
            response: modelOutput,
            tokenSaverOn: tokenSaverOn,
            isSR1: { _ in false }
        )
        let humanizeOut: String
        if classified.wasEnforced {
            humanizeOut = classified.uiSourceText
        } else if classified.needsHumanize {
            humanizeOut = "HUMANIZED:" + classified.providerHistoryText
        } else {
            humanizeOut = modelOutput
        }

        // Phase 2: dual-channel persist plan (coordinator).
        let plan = SR2WirePolicy.dualChannelPersistPlan(
            modelOutput: modelOutput,
            humanizeOutput: humanizeOut,
            tokenSaverOn: tokenSaverOn,
            isSR1: { _ in false },
            storeProse: { prose in store.store(prose) }
        )
        return (
            history: plan.historyText,
            ui: plan.uiText,
            original: plan.historyText,
            rewritten: plan.uiText
        )
    }

    func testFreeProseMonologueDoesNotRemainInHistory() {
        let monologue = """
        A verificação revelou um segundo caso real: mesmo após corrigir os botões,
        acessar diretamente a URL sem / final ainda produz 301 para http://...:8080.
        Vou tratar isso no .htaccess com rewrite interno.
        """
        let store = ProseStore()
        let result = applyTokenSaverDualChannel(
            modelOutput: monologue,
            tokenSaverOn: true,
            store: store
        )

        // Provider-facing history must be wire stub, not monologue.
        XCTAssertTrue(SR2WirePolicy.isSR2(result.history), result.history)
        XCTAssertFalse(result.history.contains("verificação revelou"), result.history)
        XCTAssertTrue(result.history.contains("[[rc:"), result.history)
        XCTAssertFalse(result.history.contains("ans_"), "marker must be bare [[rc:<sha>]]")

        // UI leg keeps natural language.
        XCTAssertTrue(result.ui.contains("verificação revelou"))
        XCTAssertEqual(result.original, result.history)
        XCTAssertEqual(result.rewritten, result.ui)

        // Recovery store holds full prose under handle referenced by stub.
        XCTAssertFalse(store.values.isEmpty)
        let recovered = store.values.values.contains { $0.contains("verificação revelou") }
        XCTAssertTrue(recovered, "store must hold full prose for [[rc:]] recovery")

        XCTAssertTrue(SR2WirePolicy.dualChannelAllows(
            providerHistoryText: result.history,
            uiHumanizedText: result.ui
        ))
    }

    func testTokenSaverOffKeepsMonologue() {
        let monologue = "Ordinary assistant chat without Token Saver."
        let store = ProseStore()
        let result = applyTokenSaverDualChannel(
            modelOutput: monologue,
            tokenSaverOn: false,
            store: store
        )
        XCTAssertEqual(result.history, monologue)
        XCTAssertEqual(result.ui, monologue)
        XCTAssertTrue(store.values.isEmpty)
    }
}
