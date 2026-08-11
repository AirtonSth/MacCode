import XCTest
@testable import Persistence
@testable import CoreModel

/// Proves free-prose enforcement marker format round-trips through the real
/// reversible store: store prose → embed recoveryMarker in wire stub → retrieveText.
/// Guards against `[[rc:ans_<sha>]]` regressions (normalize would look up ans_<sha>).
final class SR2FreeProseRecoveryRoundTripTests: XCTestCase {
    private func makeStore() throws -> ReversibleContentStore {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return ReversibleContentStore(db: db)
    }

    func testStoreProseEnforceStubRetrieveViaMarker() throws {
        let store = try makeStore()
        let monologue = """
        A verificação revelou um segundo caso real: mesmo após corrigir os botões,
        acessar diretamente a URL sem / final ainda produz 301. Vou tratar no .htaccess.
        """

        // Same path as AppContext.reversibleProseStore + dualChannelPersistPlan.
        let handle = try store.store(monologue)
        let plan = SR2WirePolicy.dualChannelPersistPlan(
            modelOutput: monologue,
            humanizeOutput: monologue,
            tokenSaverOn: true,
            isSR1: { _ in false },
            storeProse: { _ in handle } // content-addressed: same prose → same handle
        )

        XCTAssertTrue(SR2WirePolicy.isSR2(plan.historyText))
        XCTAssertFalse(plan.historyText.contains("verificação revelou"))
        XCTAssertFalse(plan.historyText.contains("ans_"), "must not use ans_ inside [[rc:]]")

        let expectedMarker = ReversibleContentStore.marker(for: handle)
        XCTAssertEqual(SR2WirePolicy.recoveryMarker(for: handle), expectedMarker)
        XCTAssertTrue(
            plan.historyText.contains(expectedMarker),
            "stub must embed store-compatible marker: \(plan.historyText)"
        )

        // Extract marker from stub (h:[[rc:...]] line) and retrieve.
        let markerFromStub = plan.recoveryHandleFromHistory ?? expectedMarker
        let recovered = try store.retrieveText(markerFromStub)
        XCTAssertEqual(recovered, monologue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? monologue
            : monologue) // store keeps exact UTF-8
        XCTAssertEqual(recovered, monologue)

        // Also retrieve via bare handle and via SR2 recoveryMarker helper.
        XCTAssertEqual(try store.retrieveText(handle), monologue)
        XCTAssertEqual(try store.retrieveText(SR2WirePolicy.recoveryMarker(for: handle)), monologue)

        // Prove ans_ prefix would fail (the bug we fixed).
        let brokenMarker = "[[rc:ans_\(handle)]]"
        XCTAssertNil(
            try store.retrieveText(brokenMarker),
            "ans_ prefix must not resolve — that was the prior bug"
        )
    }

    func testEnforceFreeProseMarkerMatchesStoreNormalize() throws {
        let handle = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let enforced = SR2WirePolicy.enforceFreeProse("hello world monologue text", handle: handle)
        let marker = enforced.recoveryHandlePlaceholder
        XCTAssertEqual(marker, "[[rc:\(handle)]]")
        XCTAssertEqual(ReversibleContentStore.marker(for: handle), marker)
        // normalize path used by retrieve
        XCTAssertEqual(
            ReversibleContentStore.normalize(marker),
            handle.lowercased()
        )
        XCTAssertNotEqual(
            ReversibleContentStore.normalize("[[rc:ans_\(handle)]]"),
            handle.lowercased(),
            "ans_ prefix changes the looked-up key"
        )
    }

    /// WHY: Translation stream rows may be pruned while the assistant message
    /// and its recovery marker remain durable. Reopening must still recover the
    /// user-facing prose from the message-owned wire text.
    func testPersistedStubRecoversWithoutTranslationEvent() throws {
        let store = try makeStore()
        let prose = "The durable message survives after its translation event is pruned."
        let handle = try store.store(prose)
        let plan = SR2WirePolicy.dualChannelPersistPlan(
            modelOutput: prose,
            humanizeOutput: prose,
            tokenSaverOn: true,
            isSR1: { _ in false },
            storeProse: { _ in handle }
        )

        let persistedMessage = plan.historyText
        let marker = try XCTUnwrap(SR2WirePolicy.recoveryMarker(in: persistedMessage))
        XCTAssertEqual(try store.retrieveText(marker), prose)
    }
}

// Small helper: pull h:[[rc:...]] from wire stub for the round-trip test.
private extension SR2WirePolicy.DualChannelPersistPlan {
    var recoveryHandleFromHistory: String? {
        for line in historyText.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("h:") {
                return String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
