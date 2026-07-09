import XCTest
import CoreModel
import Persistence

/// Proves PlanNotesStore: key derivation is stable + thread-scoped;
/// absent key returns default ""; save/load round-trips text;
/// two threads are isolated (one save never bleeds into another).
///
/// Rule 8 intent: business-invariant is per-thread persistence isolation —
/// tests would fail if key generation merged two thread IDs, if load silently
/// returned stale data from another thread, or if the serialisation dropped text.
final class PlanNotesStoreTests: XCTestCase {

    // MARK: - fake repo for pure in-memory testing

    private final class FakeRepo: SettingsWriteRepository {
        enum Failure: Error { case read, write }

        var store: [String: String] = [:]
        var readFails = false
        var writeFails = false

        func get(_ key: String) throws -> String? {
            if readFails { throw Failure.read }
            return store[key]
        }

        func set(_ key: String, _ value: String) throws {
            if writeFails { throw Failure.write }
            store[key] = value
        }
    }

    // MARK: - key derivation

    func test_storageKey_containsThreadUUID() {
        let id = AgentThreadID()
        let key = PlanNotesStore.storageKey(for: id)
        XCTAssertTrue(key.contains(id.value.uuidString),
                      "storage key must embed the thread UUID so keys are stable across restarts")
    }

    func test_storageKey_distinctForDifferentThreads() {
        let a = AgentThreadID()
        let b = AgentThreadID()
        XCTAssertNotEqual(PlanNotesStore.storageKey(for: a),
                          PlanNotesStore.storageKey(for: b),
                          "different thread IDs must produce different storage keys to prevent cross-thread bleed")
    }

    // MARK: - absent key returns default

    func test_load_returnsEmptyStringWhenAbsent() throws {
        let store = PlanNotesStore(repo: FakeRepo())
        let id = AgentThreadID()
        let result = try store.load(threadId: id)
        XCTAssertEqual(result, "",
                       "an absent notes key must return empty string, not nil or a crash, so new threads show a blank editor")
    }

    // MARK: - round-trip

    func test_saveAndLoad_roundTripsText() throws {
        let store = PlanNotesStore(repo: FakeRepo())
        let id = AgentThreadID()
        let text = "- step 1\n- step 2"
        try store.save(text, threadId: id)
        XCTAssertEqual(try store.load(threadId: id), text,
                       "notes saved for a thread must be loadable back verbatim — silent loss would break the persist-and-restore contract")
    }

    func test_saveEmpty_roundTripsAsEmpty() throws {
        let store = PlanNotesStore(repo: FakeRepo())
        let id = AgentThreadID()
        try store.save("some text", threadId: id)
        try store.save("", threadId: id)
        XCTAssertEqual(try store.load(threadId: id), "",
                       "saving empty string must overwrite prior notes, not keep stale content")
    }

    // MARK: - thread isolation

    func test_save_doesNotBleedToOtherThread() throws {
        let store = PlanNotesStore(repo: FakeRepo())
        let a = AgentThreadID()
        let b = AgentThreadID()
        try store.save("thread A notes", threadId: a)
        XCTAssertEqual(try store.load(threadId: b), "",
                       "saving notes for thread A must not affect thread B — threads must be fully isolated in the notes store")
    }

    func test_twoThreads_independentlyPersisted() throws {
        let store = PlanNotesStore(repo: FakeRepo())
        let a = AgentThreadID()
        let b = AgentThreadID()
        try store.save("notes for A", threadId: a)
        try store.save("notes for B", threadId: b)
        XCTAssertEqual(try store.load(threadId: a), "notes for A",
                       "thread A notes must survive after thread B is also saved")
        XCTAssertEqual(try store.load(threadId: b), "notes for B",
                       "thread B notes must be independently stored from thread A")
    }

    func test_load_propagatesRepositoryFailureInsteadOfReturningEmptyCASValue() {
        let repo = FakeRepo()
        let store = PlanNotesStore(repo: repo)
        repo.readFails = true

        XCTAssertThrowsError(try store.load(threadId: AgentThreadID())) { error in
            XCTAssertTrue(error is FakeRepo.Failure,
                          "a CAS read failure must reach the RPC instead of looking like absent notes")
        }
    }

    func test_save_propagatesRepositoryFailureInsteadOfReportingDurableSuccess() {
        let repo = FakeRepo()
        let store = PlanNotesStore(repo: repo)
        repo.writeFails = true

        XCTAssertThrowsError(try store.save("must persist", threadId: AgentThreadID())) { error in
            XCTAssertTrue(error is FakeRepo.Failure,
                          "a failed write must reach the caller so no RPC success or mirror event can be emitted")
        }
    }
}
