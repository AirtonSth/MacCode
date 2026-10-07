import XCTest
@testable import Persistence

/// C3: every paired-device request resolves its bearer. The principal cache
/// keeps that off SQLite on the hot path, but a revoke must still lock a device
/// out on its very next request, and last_seen_at telemetry must never hold a
/// request behind a write lock.
final class DeviceTrustPrincipalCacheTests: XCTestCase {
    private final class StepCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [String] = []
        func record(_ sql: String) { lock.lock(); steps.append(sql); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return steps.count }
        func reset() { lock.lock(); steps.removeAll(); lock.unlock() }
    }

    private func makeDB() throws -> SQLiteDB {
        let tmp = NSTemporaryDirectory() + "RC2PrincipalCache-" + UUID().uuidString
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return db
    }

    private func pair(_ repo: DeviceTrustRepository, name: String = "phone") throws -> (DeviceTrust, token: String) {
        let code = try repo.createPairingCode()
        return try XCTUnwrap(try repo.redeemPairingCode(code.code, deviceName: name))
    }

    private func lastSeen(_ db: SQLiteDB, id: String) throws -> String? {
        try db.performSync { database in
            let st = try database.prepare("SELECT last_seen_at FROM device_trust WHERE id = ?;")
            try st.bind(1, id)
            guard try st.step() else { return nil }
            return st.columnText(0)
        }
    }

    // MARK: - Immediate path

    /// WHY: the reconnect burst authenticates every request. A verified bearer
    /// inside the cache window must not prepare or step a single statement, so
    /// auth can never queue behind the writer connection.
    func test_cacheHit_runsZeroSQLiteStatements() throws {
        let db = try makeDB()
        let repo = DeviceTrustRepository(db: db)
        let paired = try pair(repo)
        let now = Date()
        XCTAssertEqual(try repo.verifyCached(token: paired.token, now: now)?.id, paired.0.id)
        repo.drainLastSeenWritesForTesting()

        let counter = StepCounter()
        db.beforeStatementStepForTesting = { counter.record($0) }
        defer { db.beforeStatementStepForTesting = nil }
        let hit = try repo.verifyCached(token: paired.token, now: now.addingTimeInterval(5))
        repo.drainLastSeenWritesForTesting()

        XCTAssertEqual(hit?.id, paired.0.id)
        XCTAssertEqual(hit?.tokenHash, paired.0.tokenHash)
        XCTAssertEqual(counter.count, 0, "a cache hit inside the last_seen window must not touch SQLite")
        XCTAssertEqual(repo.principalCacheHitCountForTesting, 1)
        XCTAssertEqual(repo.principalCacheMissCountForTesting, 1)
    }

    // MARK: - Invalidation

    /// WHY: Settings revokes through its own repository instance. The HTTP
    /// auth cache lives in another instance and must refuse the revoked token
    /// on the next request, not up to a TTL later.
    func test_revokeFromAnotherRepository_invalidatesCachedPrincipalImmediately() throws {
        let db = try makeDB()
        let httpAuthRepo = DeviceTrustRepository(db: db)
        let settingsRepo = DeviceTrustRepository(db: db)
        let paired = try pair(httpAuthRepo)
        XCTAssertNotNil(try httpAuthRepo.verifyCached(token: paired.token))
        XCTAssertNotNil(try httpAuthRepo.verifyCached(token: paired.token))
        XCTAssertEqual(httpAuthRepo.principalCacheHitCountForTesting, 1)

        try settingsRepo.revoke(id: paired.0.id)

        XCTAssertNil(try httpAuthRepo.verifyCached(token: paired.token),
                     "a revoked device must be refused on its very next request")
        XCTAssertNil(try httpAuthRepo.verifyCached(token: paired.token),
                     "a refused token must not be cached as valid afterwards")
    }

    func test_deleteRevokedAndAlwaysAllowChanges_invalidateCache() throws {
        let db = try makeDB()
        let repo = DeviceTrustRepository(db: db)
        let paired = try pair(repo)
        XCTAssertNotNil(try repo.verifyCached(token: paired.token))

        let before = DeviceTrustRepository.trustGeneration
        try repo.deleteRevoked()
        XCTAssertGreaterThan(DeviceTrustRepository.trustGeneration, before)
        let misses = repo.principalCacheMissCountForTesting
        XCTAssertNotNil(try repo.verifyCached(token: paired.token))
        XCTAssertEqual(repo.principalCacheMissCountForTesting, misses + 1,
                       "any trust write re-reads the row instead of trusting the old entry")

        let beforeAllow = DeviceTrustRepository.trustGeneration
        try repo.setAlwaysAllowPairing(id: paired.0.id, enabled: true)
        XCTAssertGreaterThan(DeviceTrustRepository.trustGeneration, beforeAllow)
    }

    /// WHY: the plan invalidates on pair as well as revoke. A new device
    /// verifies immediately, and an existing device's cached entry is re-read.
    func test_pairing_invalidatesCacheAndNewTokenVerifiesImmediately() throws {
        let db = try makeDB()
        let repo = DeviceTrustRepository(db: db)
        let first = try pair(repo, name: "first")
        XCTAssertNotNil(try repo.verifyCached(token: first.token))

        let request = try repo.createPairingRequest(deviceName: "second")
        let before = DeviceTrustRepository.trustGeneration
        let second = try XCTUnwrap(try repo.approvePairingRequest(id: request.id))
        XCTAssertGreaterThan(DeviceTrustRepository.trustGeneration, before)

        XCTAssertEqual(try repo.verifyCached(token: second.token)?.id, second.0.id)
        let misses = repo.principalCacheMissCountForTesting
        XCTAssertEqual(try repo.verifyCached(token: first.token)?.id, first.0.id)
        XCTAssertEqual(repo.principalCacheMissCountForTesting, misses + 1)
    }

    func test_entryExpiresAfterTTL_andRereadsTheRow() throws {
        let db = try makeDB()
        let repo = DeviceTrustRepository(db: db)
        let paired = try pair(repo)
        let t0 = Date()
        XCTAssertNotNil(try repo.verifyCached(token: paired.token, now: t0))
        XCTAssertNotNil(try repo.verifyCached(token: paired.token,
                                              now: t0.addingTimeInterval(DeviceTrustRepository.principalCacheTTL - 1)))
        XCTAssertEqual(repo.principalCacheMissCountForTesting, 1)
        XCTAssertNotNil(try repo.verifyCached(token: paired.token,
                                              now: t0.addingTimeInterval(DeviceTrustRepository.principalCacheTTL + 1)))
        XCTAssertEqual(repo.principalCacheMissCountForTesting, 2,
                       "a change made by another process is seen within the TTL")
    }

    // MARK: - Stale fill (A→B race)

    /// WHY: a lookup that read the row before a concurrent trust write commits
    /// must not install a result that outlives that write. The generation is
    /// captured before the SELECT, so a write that lands during the lookup
    /// leaves the entry unusable and the next request re-reads.
    func test_trustWriteDuringLookup_rejectsTheStaleEntry() throws {
        let db = try makeDB()
        let repo = DeviceTrustRepository(db: db)
        let paired = try pair(repo)
        let settingsRepo = DeviceTrustRepository(db: db)
        var fired = false
        db.beforeStatementStepForTesting = { sql in
            guard !fired, sql.contains("FROM device_trust WHERE token_hash") else { return }
            fired = true
            // Another writer's commit lands while this lookup is in flight.
            DeviceTrustRepository.bumpTrustGeneration()
        }
        XCTAssertNotNil(try repo.verifyCached(token: paired.token),
                        "the in-flight request itself still sees the row it read")
        db.beforeStatementStepForTesting = nil
        XCTAssertTrue(fired)

        XCTAssertNotNil(try repo.verifyCached(token: paired.token))
        XCTAssertEqual(repo.principalCacheHitCountForTesting, 0,
                       "an entry filled across a trust write must never serve a hit")
        XCTAssertEqual(repo.principalCacheMissCountForTesting, 2)

        try settingsRepo.revoke(id: paired.0.id)
        XCTAssertNil(try repo.verifyCached(token: paired.token))
    }

    // MARK: - last_seen_at (eventual exact completion + failure)

    func test_lastSeen_isWrittenOnceOffTheCallerAndDebounced() throws {
        let db = try makeDB()
        let repo = DeviceTrustRepository(db: db)
        let paired = try pair(repo)
        XCTAssertNil(try lastSeen(db, id: paired.0.id))
        let t0 = Date()
        _ = try repo.verifyCached(token: paired.token, now: t0)
        repo.drainLastSeenWritesForTesting()
        let first = try XCTUnwrap(try lastSeen(db, id: paired.0.id))

        let counter = StepCounter()
        db.beforeStatementStepForTesting = { counter.record($0) }
        _ = try repo.verifyCached(token: paired.token, now: t0.addingTimeInterval(30))
        repo.drainLastSeenWritesForTesting()
        db.beforeStatementStepForTesting = nil
        XCTAssertEqual(counter.count, 0, "inside the debounce window there is no last_seen write")
        XCTAssertEqual(try lastSeen(db, id: paired.0.id), first)

        _ = try repo.verifyCached(token: paired.token, now: t0.addingTimeInterval(61))
        repo.drainLastSeenWritesForTesting()
        XCTAssertNotEqual(try lastSeen(db, id: paired.0.id), first,
                          "a cache hit past the debounce window still records last_seen once")
    }

    /// WHY: on 2026-07-14 a failed last_seen write turned into 401 for every
    /// paired iPhone. The write is telemetry: a read-only/locked DB must not
    /// de-authorize, and must not delay the request.
    func test_lastSeenWriteFailure_staysAuthorized() throws {
        let db = try makeDB()
        let repo = DeviceTrustRepository(db: db)
        let paired = try pair(repo)
        try db.execute("PRAGMA query_only=ON;")
        defer { try? db.execute("PRAGMA query_only=OFF;") }
        XCTAssertEqual(try repo.verifyCached(token: paired.token)?.id, paired.0.id)
        repo.drainLastSeenWritesForTesting()
        XCTAssertEqual(try repo.verifyCached(token: paired.token)?.id, paired.0.id)
    }

    /// WHY: another connection (a helper process, or the app's second
    /// connection) holding the write lock used to stall the first request of
    /// every minute in the inline last_seen UPDATE.
    func test_lookupMissDoesNotWaitForAnotherConnectionsWriteLock() throws {
        let db = try makeDB()
        let repo = DeviceTrustRepository(db: db)
        let paired = try pair(repo)
        let other = try SQLiteDB(path: db.path)
        let started = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            other.performSync { connection in
                try? connection.execute("BEGIN IMMEDIATE;")
                started.signal()
                Thread.sleep(forTimeInterval: 0.8)
                try? connection.execute("COMMIT;")
            }
            released.signal()
        }
        started.wait()
        let t0 = DispatchTime.now()
        let trust = try repo.verifyCached(token: paired.token)
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1_000_000
        XCTAssertEqual(trust?.id, paired.0.id)
        XCTAssertLessThan(ms, 300, "auth must not wait for another connection's write lock (took \(ms) ms)")
        released.wait()
        repo.drainLastSeenWritesForTesting()
        XCTAssertNotNil(try lastSeen(db, id: paired.0.id),
                        "the deferred last_seen write still lands once the lock is released")
    }

    func test_unknownToken_isRefusedAndNeverCached() throws {
        let db = try makeDB()
        let repo = DeviceTrustRepository(db: db)
        _ = try pair(repo)
        XCTAssertNil(try repo.verifyCached(token: "not-a-token"))
        XCTAssertNil(try repo.verifyCached(token: "not-a-token"))
        XCTAssertEqual(repo.principalCacheHitCountForTesting, 0)
        XCTAssertEqual(repo.principalCacheMissCountForTesting, 2)
    }
}
