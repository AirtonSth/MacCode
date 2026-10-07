import XCTest
@testable import Persistence

// MARK: - Call-counting test double

/// Tracks how many times get() was called so tests can assert decode count.
/// Pure value — no SQLiteDB, no I/O.
private final class CountingSettingsRepository: SettingsWriteRepository {
    private let lock = NSLock()
    private var store: [String: String] = [:]
    private var _getCallCount = 0
    private var _shouldFailGet = false
    private var _shouldFailSet = false

    var getCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _getCallCount
    }

    var shouldFailSet: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return _shouldFailSet
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _shouldFailSet = newValue
        }
    }

    var shouldFailGet: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return _shouldFailGet
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _shouldFailGet = newValue
        }
    }

    func get(_ key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        _getCallCount += 1
        if _shouldFailGet { throw CountingErr.injected }
        return store[key]
    }

    func set(_ key: String, _ value: String) throws {
        lock.lock(); defer { lock.unlock() }
        if _shouldFailSet { throw CountingErr.injected }
        store[key] = value
    }

    enum CountingErr: Error { case injected }
}

// MARK: - Tests

/// PERF: SettingsStore must decode AppSettings at most once per save/invalidation cycle.
///
/// Why these tests matter:
///   load() was called on every prompt-send; each call allocated a JSONDecoder and
///   decoded the blob unconditionally. With a cache the decode happens once and
///   subsequent load() calls return the in-memory value.
///   A write (save/update) invalidates the cache so the next load() re-decodes the
///   freshly written blob — keeping the cache coherent with the store.
final class SettingsStoreCacheTests: XCTestCase {

    // MARK: load returns cached value after first decode

    func test_loadReturnsCachedAfterFirstDecode() {
        let repo = CountingSettingsRepository()
        let store = SettingsStore(repo: repo)

        _ = store.load()
        _ = store.load()
        _ = store.load()

        XCTAssertEqual(
            repo.getCallCount, 1,
            "load() must decode from the repo only once; subsequent calls must return " +
            "the cached AppSettings without hitting the repo — this is the perf invariant"
        )
    }

    // MARK: write invalidates cache; next load re-decodes

    func test_writeInvalidatesCache_nextLoadReDecodes() {
        let repo = CountingSettingsRepository()
        let store = SettingsStore(repo: repo)

        _ = store.load()                          // decode #1
        store.save(AppSettings(diffWordWrap: true)) // must invalidate
        _ = store.load()                          // decode #2 (cache was cleared)

        XCTAssertEqual(
            repo.getCallCount, 2,
            "save() must invalidate the cache so the next load() re-reads from the repo; " +
            "without invalidation a stale value would be returned after a write"
        )
    }

    // MARK: cached value matches written value

    func test_cachedValueReflectsLastWrite() {
        let repo = CountingSettingsRepository()
        let store = SettingsStore(repo: repo)

        store.save(AppSettings(diffWordWrap: true, terminalFontSize: 14))
        let result = store.load()

        XCTAssertTrue(result.diffWordWrap, "cached load must return the value that was written")
        XCTAssertEqual(result.terminalFontSize, 14, "cached load must return all fields from the last write")
    }

    func test_reloadObservesWriteFromAnotherStoreInstance() {
        let repo = CountingSettingsRepository()
        let observer = SettingsStore(repo: repo)
        let writer = SettingsStore(repo: repo)
        XCTAssertTrue(observer.load().petEnabled)

        writer.update { $0.petEnabled = false }

        XCTAssertTrue(observer.load().petEnabled,
            "ordinary load must retain the per-instance cache until explicitly invalidated")
        XCTAssertFalse(observer.reload().petEnabled,
            "settings-change observers must be able to refresh writes made through another store instance")
    }

    func test_updateReloadsCanonicalValueBeforeMutatingOneField() {
        let repo = CountingSettingsRepository()
        let staleWriter = SettingsStore(repo: repo)
        let petWriter = SettingsStore(repo: repo)
        XCTAssertTrue(staleWriter.load().petEnabled)

        petWriter.update { $0.petEnabled = false }
        staleWriter.update { $0.insomniaEnabled = false }

        let persisted = SettingsStore(repo: repo).load()
        XCTAssertFalse(persisted.petEnabled,
            "a partial update from a stale SettingsStore must preserve fields written by another surface")
        XCTAssertFalse(persisted.insomniaEnabled,
            "the requested field mutation must still persist after reloading canonical settings")
    }

    func test_updateDoesNotOverwriteValidSettingsWhenCanonicalReadFails() {
        let repo = CountingSettingsRepository()
        let store = SettingsStore(repo: repo)
        store.save(AppSettings(diffWordWrap: true, petEnabled: true))
        XCTAssertTrue(store.load().petEnabled, "precondition: persisted settings must be readable")

        var receivedError = false
        store.onWriteError = { _ in receivedError = true }
        repo.shouldFailGet = true
        store.update { $0.insomniaEnabled = true }
        repo.shouldFailGet = false

        let persisted = SettingsStore(repo: repo).load()
        XCTAssertTrue(receivedError, "a failed canonical read must be surfaced to the caller")
        XCTAssertTrue(persisted.diffWordWrap)
        XCTAssertTrue(persisted.petEnabled)
        XCTAssertFalse(persisted.insomniaEnabled,
            "the requested mutation must not save defaults when the canonical read fails")
    }

    // MARK: failed write does NOT invalidate cache

    func test_failedWriteDoesNotInvalidateCache() {
        let repo = CountingSettingsRepository()
        let store = SettingsStore(repo: repo)

        _ = store.load()                          // decode #1; cache is warm

        repo.shouldFailSet = true
        store.save(AppSettings(diffWordWrap: true)) // write fails; cache must stay

        _ = store.load()                          // should still use cache — no extra decode

        XCTAssertEqual(
            repo.getCallCount, 1,
            "a failed save() must NOT invalidate the cache; the cache remains valid " +
            "because the underlying repo was not mutated — an extra decode would be wasted work"
        )
    }

    // MARK: update() also invalidates cache

    func test_updateInvalidatesCache_nextLoadReDecodes() {
        let repo = CountingSettingsRepository()
        let store = SettingsStore(repo: repo)

        _ = store.load()                                // decode #1
        store.update { $0.terminalFontSize = 14 }       // read-modify-write; must invalidate
        _ = store.load()                                // decode #2

        XCTAssertEqual(
            repo.getCallCount, 3,
            "update() must reload canonical settings before mutation, then invalidate " +
            "its cache so the next load() re-reads the persisted value"
        )
    }

    // MARK: cache returns defaults when repo has no stored value

    func test_saveBumpsProcessWideRevision() {
        // WHY: agent itemDelta used to construct a new SettingsStore (empty
        // cache → SQLite) per chunk. Hot readers key their gate on this
        // revision so a write from any instance invalidates them.
        let before = SettingsStore.revision
        let repo = CountingSettingsRepository()
        SettingsStore(repo: repo).save(AppSettings(terminalFontSize: 14))
        XCTAssertEqual(
            SettingsStore.revision,
            before + 1,
            "successful save must bump SettingsStore.revision for cross-instance readers"
        )
    }

    func test_cacheReturnsDefaults_whenRepoEmpty() {
        let repo = CountingSettingsRepository()
        let store = SettingsStore(repo: repo)

        let first = store.load()
        let second = store.load()

        XCTAssertEqual(first, AppSettings(), "empty repo must produce default AppSettings")
        XCTAssertEqual(second, AppSettings(), "cached default must equal documented defaults")
        XCTAssertEqual(repo.getCallCount, 1, "defaults must also be cached after first miss")
    }

    // MARK: concurrent get/set/invalidate does not crash

    func test_concurrentAccessDoesNotCrash() {
        let repo = CountingSettingsRepository()
        let store = SettingsStore(repo: repo)

        let iterations = 200
        let group = DispatchGroup()

        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                if i % 3 == 0 {
                    _ = store.load()
                } else if i % 3 == 1 {
                    store.save(AppSettings(diffWordWrap: i % 2 == 0))
                } else {
                    store.update { $0.diffIgnoreWhitespace = i % 2 == 0 }
                }
                group.leave()
            }
        }

        let completed = group.wait(timeout: .now() + 5)
        XCTAssertEqual(completed, .success, "concurrent load/save/update must not deadlock or crash")
    }
}
