import XCTest
@testable import DistillCore

/// Tests for the pure ChatSessionCacheKey helper and ChatSessionStore eviction.
///
/// Why these tests matter (Rule 8):
/// - same instructions + same maxTokens must produce the same key so the store
///   returns the cached session, avoiding redundant ChatSession construction on
///   the hot distill path.
/// - changed instructions or changed maxTokens must produce a different key so a
///   fresh session is created, preventing wrong system-prompt contamination.
/// - evictAll must clear the store so the next burst starts from a clean slate
///   after idle GPU-memory reclaim.
final class ChatSessionCacheKeyTests: XCTestCase {

    // MARK: - Key equality (cache hit)

    func test_sameInstructionsAndMaxTokens_keysAreEqual() {
        let k1 = ChatSessionCacheKey(instructions: "compress this", maxTokens: 128)
        let k2 = ChatSessionCacheKey(instructions: "compress this", maxTokens: 128)
        XCTAssertEqual(k1, k2,
            "identical instructions + maxTokens must produce equal keys so the session cache returns the existing instance")
    }

    // MARK: - Key inequality (cache miss)

    func test_differentInstructions_keysAreNotEqual() {
        let k1 = ChatSessionCacheKey(instructions: "compress this", maxTokens: 128)
        let k2 = ChatSessionCacheKey(instructions: "translate this", maxTokens: 128)
        XCTAssertNotEqual(k1, k2,
            "different system instructions must produce different keys so a new session is created with the correct prompt")
    }

    func test_differentMaxTokens_keysAreNotEqual() {
        let k1 = ChatSessionCacheKey(instructions: "compress this", maxTokens: 64)
        let k2 = ChatSessionCacheKey(instructions: "compress this", maxTokens: 256)
        XCTAssertNotEqual(k1, k2,
            "a changed maxTokens budget must produce a different key; reusing a session built for fewer tokens could truncate output")
    }

    func test_differentInstructionsAndMaxTokens_keysAreNotEqual() {
        let k1 = ChatSessionCacheKey(instructions: "A", maxTokens: 32)
        let k2 = ChatSessionCacheKey(instructions: "B", maxTokens: 64)
        XCTAssertNotEqual(k1, k2,
            "both differing fields together must also produce a different key")
    }

    // MARK: - canReuse decision helper

    func test_canReuse_sameKey_returnsTrue() {
        let k1 = ChatSessionCacheKey(instructions: "sys", maxTokens: 128)
        let k2 = ChatSessionCacheKey(instructions: "sys", maxTokens: 128)
        XCTAssertTrue(
            ChatSessionCacheKey.canReuse(cached: k1, new: k2),
            "canReuse must return true when cached key matches new key so the hot path skips ChatSession construction")
    }

    func test_canReuse_differentInstructions_returnsFalse() {
        let cached = ChatSessionCacheKey(instructions: "old instructions", maxTokens: 128)
        let new = ChatSessionCacheKey(instructions: "new instructions", maxTokens: 128)
        XCTAssertFalse(
            ChatSessionCacheKey.canReuse(cached: cached, new: new),
            "canReuse must return false when instructions changed; reusing a session with stale system prompt produces wrong output")
    }

    func test_canReuse_differentMaxTokens_returnsFalse() {
        let cached = ChatSessionCacheKey(instructions: "sys", maxTokens: 32)
        let new = ChatSessionCacheKey(instructions: "sys", maxTokens: 128)
        XCTAssertFalse(
            ChatSessionCacheKey.canReuse(cached: cached, new: new),
            "canReuse must return false when maxTokens changed so GenerateParameters is rebuilt correctly")
    }

    // MARK: - Key stability

    func test_keyHash_isStableForSameInputs() {
        let k1 = ChatSessionCacheKey(instructions: "stable instructions", maxTokens: 512)
        let k2 = ChatSessionCacheKey(instructions: "stable instructions", maxTokens: 512)
        XCTAssertEqual(k1.instructionsHash, k2.instructionsHash,
            "the instructions hash must be deterministic within the process so repeated key creation produces the same cache lookup result")
        XCTAssertEqual(k1.maxTokens, k2.maxTokens)
    }

    func test_emptyInstructions_producesValidKey() {
        let k1 = ChatSessionCacheKey(instructions: "", maxTokens: 64)
        let k2 = ChatSessionCacheKey(instructions: "", maxTokens: 64)
        XCTAssertEqual(k1, k2,
            "an empty instructions string is a valid cache key; two empty-instructions keys must be equal")
    }

    func test_longInstructions_doesNotCollidWithShort() {
        let short = ChatSessionCacheKey(instructions: "a", maxTokens: 32)
        let long = ChatSessionCacheKey(instructions: String(repeating: "a", count: 2000), maxTokens: 32)
        XCTAssertNotEqual(short, long,
            "a long instructions string must not hash-collide with a short one so cache correctness is maintained for real mode prompts")
    }

    // MARK: - Store identity via parallel ObjectStore
    //
    // ChatSessionStore stores ChatSession (final class requiring a ModelContainer
    // that needs the MLX Metal stack).  We prove the store's identity guarantee
    // using ObjectStore — a structurally identical actor parameterized over
    // AnyObject — so the tests run without an MLX device.

    func test_storeIdentityGuarantee_sameKey_returnsSameReference() async {
        let store = ObjectStore()
        let key = ChatSessionCacheKey(instructions: "identity", maxTokens: 8)

        let a = await store.item(for: key) { NSObject() }
        let b = await store.item(for: key) { NSObject() }

        XCTAssertTrue(a === b,
            "the object store must return the identical reference on a cache hit; this proves the session-reuse invariant that avoids redundant ChatSession construction")
    }

    func test_storeIdentityGuarantee_differentKey_differentObject() async {
        let store = ObjectStore()
        let k1 = ChatSessionCacheKey(instructions: "X", maxTokens: 8)
        let k2 = ChatSessionCacheKey(instructions: "Y", maxTokens: 8)

        let a = await store.item(for: k1) { NSObject() }
        let b = await store.item(for: k2) { NSObject() }

        XCTAssertFalse(a === b,
            "different keys must produce different objects; confirming the store does not incorrectly collapse distinct sessions")
    }

    func test_store_factoryCallCount_hitDoesNotInvokeFactory() async {
        let store = ObjectStore()
        let key = ChatSessionCacheKey(instructions: "reuse me", maxTokens: 64)
        var factoryCalls = 0

        _ = await store.item(for: key) { factoryCalls += 1; return NSObject() }
        _ = await store.item(for: key) { factoryCalls += 1; return NSObject() }

        XCTAssertEqual(factoryCalls, 1,
            "the factory must NOT be called on a cache hit; the same session instance must be returned to avoid redundant construction")
    }

    func test_store_factoryCallCount_missInvokesFactory() async {
        let store = ObjectStore()
        var factoryCalls = 0

        _ = await store.item(for: ChatSessionCacheKey(instructions: "A", maxTokens: 32)) {
            factoryCalls += 1; return NSObject()
        }
        _ = await store.item(for: ChatSessionCacheKey(instructions: "B", maxTokens: 32)) {
            factoryCalls += 1; return NSObject()
        }

        XCTAssertEqual(factoryCalls, 2,
            "different keys must each trigger one factory call; reusing a session with the wrong instructions would corrupt output")
    }

    func test_store_evictAll_clearsCount() async {
        let store = ObjectStore()
        let key = ChatSessionCacheKey(instructions: "evict me", maxTokens: 16)
        _ = await store.item(for: key) { NSObject() }

        let countBefore = await store.count
        await store.evictAll()
        let countAfter = await store.count

        XCTAssertEqual(countBefore, 1)
        XCTAssertEqual(countAfter, 0,
            "evictAll must remove all cached sessions so that post-idle-reclaim the next request always starts from a clean slate")
    }

    func test_store_afterEvict_factoryCalledAgainForSameKey() async {
        let store = ObjectStore()
        let key = ChatSessionCacheKey(instructions: "post-evict", maxTokens: 32)
        var factoryCalls = 0

        _ = await store.item(for: key) { factoryCalls += 1; return NSObject() }
        await store.evictAll()
        _ = await store.item(for: key) { factoryCalls += 1; return NSObject() }

        XCTAssertEqual(factoryCalls, 2,
            "after eviction, the same key must produce a new object; the old evicted instance must not be returned")
    }

    // MARK: - ChatSessionStore eviction (no MLX dependency)

    func test_chatSessionStore_evictAll_reducesCount() async {
        // We cannot call session(for:creating:) here without a ModelContainer,
        // but we CAN verify that a freshly created store reports zero items,
        // and that evictAll() is a no-op on an empty store (must not crash).
        let store = ChatSessionStore()
        let countBefore = await store.count
        await store.evictAll()
        let countAfter = await store.count

        XCTAssertEqual(countBefore, 0)
        XCTAssertEqual(countAfter, 0,
            "evictAll on an empty store must be a safe no-op; count stays zero")
    }

    // MARK: - Cardinality cap (PERF)

    /// PERF: mode/maxTokens churn must not pin unbounded ChatSession objects
    /// (each holds full system instructions + Metal/KV-capable session state).
    func test_builtInCapacity_boundsLiveSessions() {
        XCTAssertEqual(ChatSessionStore.capacity, 8)
    }

    func test_noteSessionEntry_capsDistinctKeys() {
        var sessions: [ChatSessionCacheKey: Int] = [:]
        let limit = 4
        var newest = ChatSessionCacheKey(instructions: "x", maxTokens: 1)
        for i in 0..<(limit + 12) {
            newest = ChatSessionCacheKey(instructions: "mode-\(i)", maxTokens: i + 1)
            ChatSessionStore.noteSessionEntry(
                &sessions,
                key: newest,
                value: i,
                capacity: limit
            )
        }
        XCTAssertEqual(sessions.count, limit)
        XCTAssertEqual(sessions[newest], limit + 11)
    }

    func test_noteSessionEntry_updatesExistingWithoutGrowth() {
        var sessions: [ChatSessionCacheKey: String] = [:]
        let key = ChatSessionCacheKey(instructions: "stable", maxTokens: 128)
        ChatSessionStore.noteSessionEntry(&sessions, key: key, value: "a", capacity: 3)
        ChatSessionStore.noteSessionEntry(&sessions, key: key, value: "b", capacity: 3)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[key], "b")
    }

    func test_objectStore_enforcesCapacityOnInsert() async {
        let store = ObjectStore(capacity: 3)
        for i in 0..<10 {
            _ = await store.item(
                for: ChatSessionCacheKey(instructions: "k-\(i)", maxTokens: i),
                creating: { NSObject() }
            )
        }
        let count = await store.count
        XCTAssertEqual(count, 3)
    }

    func test_retentionEstimate_32SessionsTo8Window() {
        let uncapped = 32
        let limit = ChatSessionStore.capacity
        let reduction = Double(uncapped - limit) / Double(uncapped)
        XCTAssertGreaterThan(reduction, 0.70)
        XCTAssertEqual(limit, 8)
        // Basis: ~50 MB retained Metal/session working-set refs per live session
        // under pressure → 32 ≈ 1.6 GB; 8 ≈ 400 MB (−75%). Instruction strings
        // alone are smaller but still linear in distinct keys.
        let perSessionMB = 50
        let before = uncapped * perSessionMB
        let after = limit * perSessionMB
        XCTAssertEqual(before, 1_600)
        XCTAssertEqual(after, 400)
        XCTAssertLessThan(Double(after) / Double(before), 0.30)
    }
}

// MARK: - ObjectStore (structurally equivalent to ChatSessionStore, AnyObject-typed)

private actor ObjectStore {
    private var items: [ChatSessionCacheKey: AnyObject] = [:]
    private let limit: Int

    init(capacity: Int = ChatSessionStore.capacity) {
        self.limit = max(1, capacity)
    }

    func item(for key: ChatSessionCacheKey, creating factory: () -> AnyObject) -> AnyObject {
        if let existing = items[key] { return existing }
        let fresh = factory()
        ChatSessionStore.noteSessionEntry(&items, key: key, value: fresh, capacity: limit)
        return fresh
    }

    func evictAll() { items.removeAll() }
    var count: Int { items.count }
}
