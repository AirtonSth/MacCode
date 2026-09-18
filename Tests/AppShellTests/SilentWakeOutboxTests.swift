import XCTest
import Persistence
@testable import AppShell

/// Durable silent catch-up outbox: enqueue-on-failure, coalesce, backoff, bounds.
final class SilentWakeOutboxTests: XCTestCase {
    private var wakeOutboxFlagBefore: Bool?

    override func setUp() {
        super.setUp()
        wakeOutboxFlagBefore = UserDefaults.standard.object(forKey: ConnectionFeatureFlags.wakeOutboxKey) as? Bool
    }

    override func tearDown() {
        if let wakeOutboxFlagBefore {
            UserDefaults.standard.set(wakeOutboxFlagBefore, forKey: ConnectionFeatureFlags.wakeOutboxKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ConnectionFeatureFlags.wakeOutboxKey)
        }
        super.tearDown()
    }

    // MARK: - Store coalesce + caps

    func testEnqueueCoalescesSameClassToNewest() throws {
        // WHY: silent catch-up only needs the latest material state per class;
        // replaying every superseded failure would 429 the backend.
        let store = try makeStore()
        let older = makeRecord(
            class: .attention,
            hostHint: "agent.run.error",
            idempotencyKey: "catchup.attention.host.1",
            reason: "older"
        )
        let newer = makeRecord(
            class: .attention,
            hostHint: "agent.request.opened",
            idempotencyKey: "catchup.attention.host.2",
            reason: "newer"
        )
        try store.enqueue(older)
        try store.enqueue(newer)

        let pending = try store.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].idempotencyKey, newer.idempotencyKey)
        XCTAssertEqual(pending[0].reason, "newer")
    }

    func testEnqueueKeepsDistinctCoalesceClasses() throws {
        let store = try makeStore()
        try store.enqueue(makeRecord(class: .attention, hostHint: "a", idempotencyKey: "k-a"))
        try store.enqueue(makeRecord(class: .runProgress, hostHint: "b", idempotencyKey: "k-b"))
        try store.enqueue(makeRecord(class: .notification, hostHint: "c", idempotencyKey: "k-c"))

        let pending = try store.pending()
        XCTAssertEqual(Set(pending.map(\.coalesceClass)), [
            MaterialWakeCoalesceClass.attention.rawValue,
            MaterialWakeCoalesceClass.runProgress.rawValue,
            MaterialWakeCoalesceClass.notification.rawValue,
        ])
    }

    func testCountCapDropsOldestFirst() throws {
        // WHY: offline accumulation must stay bounded; oldest superseded-class
        // rows yield first so recent attention still has a chance to deliver.
        let clock = ManualSilentWakeClock(now: Date(timeIntervalSince1970: 1_000))
        let store = try makeStore(
            now: { clock.read() },
            limits: SilentWakeOutboxLimits(
                recordRetention: 10_000,
                recordCap: 2,
                encodedByteCap: 64 * 1024
            )
        )
        try store.enqueue(makeRecord(class: .attention, hostHint: "1", idempotencyKey: "k1"))
        clock.advance(by: 1)
        try store.enqueue(makeRecord(class: .runProgress, hostHint: "2", idempotencyKey: "k2"))
        clock.advance(by: 1)
        try store.enqueue(makeRecord(class: .notification, hostHint: "3", idempotencyKey: "k3"))

        let pending = try store.pending()
        XCTAssertEqual(pending.count, 2)
        XCTAssertFalse(pending.contains(where: { $0.idempotencyKey == "k1" }),
                       "oldest row must drop first under count pressure")
        XCTAssertTrue(pending.contains(where: { $0.idempotencyKey == "k2" }))
        XCTAssertTrue(pending.contains(where: { $0.idempotencyKey == "k3" }))
    }

    func testAgeRetentionDropsStaleRows() throws {
        let clock = ManualSilentWakeClock(now: Date(timeIntervalSince1970: 5_000))
        let store = try makeStore(
            now: { clock.read() },
            limits: SilentWakeOutboxLimits(
                recordRetention: 100,
                recordCap: 32,
                encodedByteCap: 64 * 1024
            )
        )
        try store.enqueue(makeRecord(class: .attention, hostHint: "old", idempotencyKey: "old"))
        clock.advance(by: 101)
        let report = try store.compactBacklog()
        XCTAssertTrue(report.didDrop)
        XCTAssertTrue(try store.pending().isEmpty)
    }

    func testUndecodableSnapshotIsDiscardedAndRewrittenByNextEnqueue() throws {
        // WHY: a snapshot the decoder cannot read can never be delivered or
        // acknowledged, and keeping it failed every enqueue/drain forever —
        // wake delivery stayed wedged with no error the user could act on.
        // Dropping it invents no acknowledgement; it just lets the next write
        // persist a readable backlog again.
        let (store, settings) = try makeStoreWithSettings()
        try settings.set(
            "silent_wake.outbox.v1",
            "{\"schema\":\"from-a-newer-build\"}"
        )

        XCTAssertTrue(
            try store.pending().isEmpty,
            "an undecodable snapshot must read as an empty backlog, not a wedge"
        )

        try store.enqueue(
            makeRecord(class: .attention, hostHint: "h", idempotencyKey: "k-recovered")
        )

        XCTAssertEqual(
            try store.pending().map(\.idempotencyKey),
            ["k-recovered"],
            "the next enqueue must persist a readable snapshot"
        )
    }

    // MARK: - Outbox retry / flag

    func testOutboxRetriesWithSameIdempotencyKeyUntilSuccess() async throws {
        // WHY: backend never caches failed attempts; replaying the exact key is
        // the only correct recovery when the HTTP response is lost.
        let store = try makeStore()
        let clock = ManualSilentWakeClock(now: Date(timeIntervalSince1970: 2_000))
        let scheduler = ManualSilentWakeScheduler()
        let sender = SilentWakeTestSender(failuresBeforeSuccess: 1)
        let outbox = SilentWakeOutbox(
            store: store,
            now: { clock.read() },
            retryDelay: { _ in 10 },
            schedule: { delay, callback in scheduler.schedule(delay, callback) },
            isEnabled: { true },
            send: { record in try await sender.send(record) }
        )
        let record = makeRecord(
            class: .attention,
            hostHint: "agent.run.error",
            idempotencyKey: "catchup.attention.host.42"
        )

        try outbox.accept(record)
        await sender.waitForAttempts(1)
        await outbox.flush()
        XCTAssertEqual(try store.pending().count, 1,
                       "failed send must remain durable until accepted")

        clock.advance(by: 10)
        scheduler.fireAll()
        await sender.waitForAttempts(2)
        await outbox.flush()

        XCTAssertEqual(sender.attempts.map(\.idempotencyKey), [
            "catchup.attention.host.42",
            "catchup.attention.host.42",
        ])
        XCTAssertTrue(try store.pending().isEmpty)
    }

    func testAcceptNoopsWhenFlagDisabled() throws {
        // WHY: wake_outbox default-off must preserve log-and-drop; enqueue must
        // not start building a backlog while the kill switch is engaged.
        let store = try makeStore()
        let outbox = SilentWakeOutbox(
            store: store,
            isEnabled: { false },
            send: { _ in }
        )
        try outbox.accept(makeRecord(
            class: .attention,
            hostHint: "x",
            idempotencyKey: "k"
        ))
        XCTAssertTrue(try store.pending().isEmpty)
    }

    func testInFlightSuccessDoesNotDestroySupersedingSameClassRecord() async throws {
        // WHY: recordID must be unique per enqueued unit. If it were only the
        // coalesce class, R1 success after R2 superseded the stored row would
        // acknowledge (delete) R2 — durable retry silently losing data.
        // Trace: R1 mid-send → R2 enqueued for same class (supersedes store) →
        // R1 succeeds → R2 must still be pending and then delivered.
        let store = try makeStore()
        let sender = HoldingSilentWakeSender()
        let outbox = SilentWakeOutbox(
            store: store,
            isEnabled: { true },
            send: { record in try await sender.send(record) }
        )
        let r1 = makeRecord(
            class: .attention,
            hostHint: "agent.run.error",
            idempotencyKey: "catchup.attention.host.r1",
            reason: "older-in-flight"
        )
        let r2 = makeRecord(
            class: .attention,
            hostHint: "agent.request.opened",
            idempotencyKey: "catchup.attention.host.r2",
            reason: "newer-superseding"
        )

        try outbox.accept(r1)
        await sender.waitForAttempts(1)
        await sender.waitUntilFirstHeld()

        try outbox.accept(r2)
        let midFlightPending = try store.pending()
        XCTAssertEqual(midFlightPending.count, 1)
        XCTAssertEqual(midFlightPending[0].idempotencyKey, r2.idempotencyKey,
                       "newer same-class enqueue must supersede the stored row while R1 is in flight")
        XCTAssertEqual(sender.attempts.count, 1,
                       "R2 must not start while the class lane is occupied by R1")

        sender.releaseFirst()
        await sender.waitForAttempts(2)
        await outbox.flush()

        XCTAssertEqual(sender.attempts.map(\.idempotencyKey), [
            r1.idempotencyKey,
            r2.idempotencyKey,
        ], "R1 may complete, but R2 must still be delivered afterward")
        XCTAssertTrue(try store.pending().isEmpty,
                      "superseding R2 must not be deleted by R1's acknowledge")
    }

    func testDrainNoopsWhileFlagOffThenResumesWhenEnabled() async throws {
        // WHY: the kill switch must freeze drain/send, not only accept. A
        // backlog written while the flag was on must stay durable and idle
        // until the flag is flipped back on.
        let store = try makeStore()
        let flag = ControllableSilentWakeFlag(true)
        let sender = SilentWakeTestSender(failuresBeforeSuccess: 0)
        let outbox = SilentWakeOutbox(
            store: store,
            isEnabled: { flag.read() },
            send: { record in try await sender.send(record) }
        )
        let record = makeRecord(
            class: .runProgress,
            hostHint: "agent.run.completed",
            idempotencyKey: "catchup.run_progress.host.drain"
        )

        // Enqueue while flag is on without waking the scheduler (direct store).
        try store.enqueue(record)
        XCTAssertEqual(try store.pending().count, 1)

        flag.set(false)
        outbox.resumePending()
        await outbox.flush()
        XCTAssertEqual(sender.attempts.count, 0,
                       "drain must not send while the feature flag is off")
        XCTAssertEqual(try store.pending().count, 1,
                       "pending work must remain durable while the kill switch is engaged")

        flag.set(true)
        outbox.resumePending()
        await sender.waitForAttempts(1)
        await outbox.flush()
        XCTAssertEqual(sender.attempts.map(\.idempotencyKey), [record.idempotencyKey])
        XCTAssertTrue(try store.pending().isEmpty)
    }

    func testOutboxReplaysPersistedDeliveryAfterRelaunch() async throws {
        // WHY: failed silent catch-up must survive process death; a new outbox
        // instance against the same store must drain on resumePending.
        let store = try makeStore()
        let record = makeRecord(
            class: .notification,
            hostHint: "notification.received",
            idempotencyKey: "catchup.notification.host.relaunch"
        )
        try store.enqueue(record)
        XCTAssertEqual(try store.pending().count, 1)

        // Simulate relaunch: second outbox instance, same durable store.
        let sender = SilentWakeTestSender(failuresBeforeSuccess: 0)
        let outbox = SilentWakeOutbox(
            store: store,
            isEnabled: { true },
            send: { record in try await sender.send(record) }
        )
        outbox.resumePending()
        await sender.waitForAttempts(1)
        await outbox.flush()

        XCTAssertEqual(sender.attempts.map(\.idempotencyKey), [record.idempotencyKey])
        XCTAssertTrue(try store.pending().isEmpty,
                      "a relaunched Mac must drain durable silent wake only after delivery succeeds")
    }

    // MARK: - Bridge integration (flag on/off)

    func testBridgeEnqueuesOnFailureWhenFlagOn() async throws {
        ConnectionFeatureFlags.wakeOutboxEnabled = true
        UserDefaults.standard.removeObject(forKey: "private.silentCatchUp.lastBucket")
        UserDefaults.standard.removeObject(forKey: "private.silentCatchUp.lastBuckets")

        let tmp = NSTemporaryDirectory() + "rc2-silent-wake-bridge-on-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let settings = SettingsRepository(db: db)
        let accountStore = PrivateAccountSessionStore(repo: settings)
        let targetStore = PrivatePushTargetStore(repo: settings)
        let api = FailingThenSucceedingPrivateAccountAPI(failAlertCount: 100)
        accountStore.save(api.session)
        try targetStore.save(
            pushToken: "apns-token",
            pushTokenType: "apns",
            liveActivityToken: nil,
            deviceId: "device-1"
        )

        let store = SilentWakeOutboxStore(settings: settings)
        let clock = ManualSilentWakeClock(now: Date(timeIntervalSince1970: 3_000))
        let scheduler = ManualSilentWakeScheduler()
        // Capture bridge weakly after construction for the send path.
        var bridgeRef: PrivateNotificationBridge?
        let outbox = SilentWakeOutbox(
            store: store,
            now: { clock.read() },
            retryDelay: { _ in 5 },
            schedule: { delay, callback in scheduler.schedule(delay, callback) },
            isEnabled: { true },
            send: { record in
                guard let bridgeRef else { throw SilentWakeOutboxError.bridgeUnavailable }
                try await bridgeRef.performSilentCatchUpDelivery(record)
            }
        )
        let bridge = PrivateNotificationBridge(
            accountStore: accountStore,
            pushTargetStore: targetStore,
            api: api,
            settings: settings,
            silentWakeOutbox: outbox
        )
        bridgeRef = bridge

        await bridge.deliverSilentCatchUp(
            hostHint: "agent.run.completed",
            force: true,
            payload: SilentCatchUpV1(reason: "agent_run_completed"),
            coalesceClass: .runProgress
        )

        let pending = try store.pending()
        XCTAssertEqual(pending.count, 1, "flag-on failure must enqueue durable retry work")
        XCTAssertEqual(pending[0].coalesceClass, MaterialWakeCoalesceClass.runProgress.rawValue)
        XCTAssertTrue(pending[0].idempotencyKey.hasPrefix("catchup.run_progress."))
    }

    func testBridgeDoesNotEnqueueOnFailureWhenFlagOff() async throws {
        // WHY: default-off is a strict additive change; production behavior must
        // remain log-and-drop until canary flips the flag.
        ConnectionFeatureFlags.wakeOutboxEnabled = false
        UserDefaults.standard.removeObject(forKey: "private.silentCatchUp.lastBucket")
        UserDefaults.standard.removeObject(forKey: "private.silentCatchUp.lastBuckets")

        let tmp = NSTemporaryDirectory() + "rc2-silent-wake-bridge-off-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let settings = SettingsRepository(db: db)
        let accountStore = PrivateAccountSessionStore(repo: settings)
        let targetStore = PrivatePushTargetStore(repo: settings)
        let api = FailingThenSucceedingPrivateAccountAPI(failAlertCount: 100)
        accountStore.save(api.session)
        try targetStore.save(
            pushToken: "apns-token",
            pushTokenType: "apns",
            liveActivityToken: nil,
            deviceId: "device-1"
        )
        let store = SilentWakeOutboxStore(settings: settings)
        let outbox = SilentWakeOutbox(
            store: store,
            isEnabled: { ConnectionFeatureFlags.wakeOutboxEnabled },
            send: { _ in }
        )
        let bridge = PrivateNotificationBridge(
            accountStore: accountStore,
            pushTargetStore: targetStore,
            api: api,
            settings: settings,
            silentWakeOutbox: outbox
        )

        await bridge.deliverSilentCatchUp(
            hostHint: "agent.run.completed",
            force: true,
            payload: SilentCatchUpV1(reason: "agent_run_completed"),
            coalesceClass: .runProgress
        )

        XCTAssertTrue(try store.pending().isEmpty,
                      "flag-off must not enqueue; preserve historical log-and-drop")
    }

    // MARK: - Helpers

    private func makeStore(
        now: @escaping () -> Date = { Date() },
        limits: SilentWakeOutboxLimits = SilentWakeOutboxLimits()
    ) throws -> SilentWakeOutboxStore {
        try makeStoreWithSettings(now: now, limits: limits).store
    }

    private func makeStoreWithSettings(
        now: @escaping () -> Date = { Date() },
        limits: SilentWakeOutboxLimits = SilentWakeOutboxLimits()
    ) throws -> (store: SilentWakeOutboxStore, settings: SettingsRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-silent-wake-store-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let settings = SettingsRepository(db: db)
        return (
            SilentWakeOutboxStore(
                settings: settings,
                now: now,
                limits: limits
            ),
            settings
        )
    }

    private func makeRecord(
        class coalesceClass: MaterialWakeCoalesceClass,
        hostHint: String,
        idempotencyKey: String,
        reason: String? = "catch_up"
    ) -> SilentWakeOutboxRecord {
        SilentWakeOutboxRecord(
            coalesceClass: coalesceClass,
            hostHint: hostHint,
            force: false,
            payload: SilentCatchUpV1(reason: reason),
            idempotencyKey: idempotencyKey
        )
    }
}

// MARK: - Test doubles

private final class ControllableSilentWakeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) { self.value = value }
    func read() -> Bool { lock.withLock { value } }
    func set(_ value: Bool) { lock.withLock { self.value = value } }
}

/// Holds the first send open so a same-class superseding enqueue can land mid-flight.
private final class HoldingSilentWakeSender: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SilentWakeOutboxRecord] = []
    private var attemptWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var firstHoldContinuation: CheckedContinuation<Void, Never>?
    private var firstHeldWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstReleased = false
    private var firstEntered = false

    func send(_ record: SilentWakeOutboxRecord) async throws {
        let isFirst = lock.withLock { () -> Bool in
            values.append(record)
            let count = values.count
            let ready = attemptWaiters.filter { $0.0 <= count }
            attemptWaiters.removeAll { $0.0 <= count }
            ready.forEach { $0.1.resume() }
            if !firstEntered {
                firstEntered = true
                return true
            }
            return false
        }
        if isFirst {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if firstReleased {
                    lock.unlock()
                    continuation.resume()
                } else {
                    firstHoldContinuation = continuation
                    let waiters = firstHeldWaiters
                    firstHeldWaiters.removeAll()
                    lock.unlock()
                    waiters.forEach { $0.resume() }
                }
            }
        }
    }

    func waitForAttempts(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let alreadyReady = lock.withLock { () -> Bool in
                if values.count >= count { return true }
                attemptWaiters.append((count, continuation))
                return false
            }
            if alreadyReady { continuation.resume() }
        }
    }

    func waitUntilFirstHeld() async {
        await withCheckedContinuation { continuation in
            let alreadyHeld = lock.withLock { () -> Bool in
                if firstHoldContinuation != nil || firstReleased { return true }
                firstHeldWaiters.append(continuation)
                return false
            }
            if alreadyHeld { continuation.resume() }
        }
    }

    func releaseFirst() {
        lock.lock()
        firstReleased = true
        let hold = firstHoldContinuation
        firstHoldContinuation = nil
        let waiters = firstHeldWaiters
        firstHeldWaiters.removeAll()
        lock.unlock()
        hold?.resume()
        waiters.forEach { $0.resume() }
    }

    var attempts: [SilentWakeOutboxRecord] { lock.withLock { values } }
}

private final class ManualSilentWakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(now: Date) { value = now }
    func read() -> Date { lock.withLock { value } }
    func advance(by interval: TimeInterval) { lock.withLock { value.addTimeInterval(interval) } }
}

private final class ManualSilentWakeScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@Sendable () -> Void] = []

    func schedule(_ delay: TimeInterval, _ callback: @escaping @Sendable () -> Void) {
        lock.withLock { callbacks.append(callback) }
    }

    func fireAll() {
        let values = lock.withLock { () -> [@Sendable () -> Void] in
            defer { callbacks.removeAll() }
            return callbacks
        }
        values.forEach { $0() }
    }
}

private final class SilentWakeTestSender: @unchecked Sendable {
    private let lock = NSLock()
    private let failuresBeforeSuccess: Int
    private var values: [SilentWakeOutboxRecord] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func send(_ record: SilentWakeOutboxRecord) async throws {
        let count = lock.withLock { () -> Int in
            values.append(record)
            let count = values.count
            let ready = waiters.filter { $0.0 <= count }
            waiters.removeAll { $0.0 <= count }
            ready.forEach { $0.1.resume() }
            return count
        }
        if count <= failuresBeforeSuccess {
            throw SilentWakeOutboxError.notDelivered("test")
        }
    }

    func waitForAttempts(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let alreadyReady = lock.withLock { () -> Bool in
                if values.count >= count { return true }
                waiters.append((count, continuation))
                return false
            }
            if alreadyReady { continuation.resume() }
        }
    }

    var attempts: [SilentWakeOutboxRecord] { lock.withLock { values } }
}

/// Fails alert delivery N times, then succeeds (delivered=true).
private final class FailingThenSucceedingPrivateAccountAPI: PrivateAccountAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int
    let session: PrivateAccountSession

    init(failAlertCount: Int) {
        remainingFailures = failAlertCount
        session = PrivateAccountSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            user: PrivateAccountUser(
                daysRemaing: 30,
                daysRemaining: 30,
                email: "test@example.com",
                id: "user-1",
                subscribed: true
            )
        )
    }

    func login(email: String, password: String) async throws -> PrivateAccountSession { session }
    func currentUser(accessToken: String) async throws -> PrivateAccountUser { session.user }
    func refresh(refreshToken: String) async throws -> PrivateAccountSession { session }
    func logout(refreshToken: String) async throws {}
    func billingOverview(accessToken: String) async throws -> PrivateBillingOverview {
        PrivateBillingOverview(
            plan: .init(billingPeriod: "monthly", priceUsd: 4.99, provider: "test", trialDays: 0),
            subscription: PrivateSubscriptionSnapshot(
                daysRemaing: 30,
                daysRemaining: 30,
                email: "test@example.com",
                endsAt: nil,
                portalUrl: nil,
                renewsAt: nil,
                status: "active",
                subscribed: true,
                trialEndsAt: nil
            )
        )
    }
    func createPortal(accessToken: String) async throws -> URL {
        URL(string: "https://example.com")!
    }
    func deliverLiveActivity(
        accessToken: String,
        event: String,
        contentState: PrivateLiveActivityContentState,
        timestampSeconds: Int64,
        liveActivityToken: String,
        pushToken: String,
        pushTokenType: String,
        idempotencyKey: String
    ) async throws -> PrivatePushDeliveryResult {
        PrivatePushDeliveryResult(delivered: true, errorCode: nil, shouldDropSubscription: false)
    }

    func deliverAlert(
        accessToken: String,
        title: String,
        body: String,
        data: [String: String],
        pushToken: String,
        pushTokenType: String,
        idempotencyKey: String,
        silent: Bool
    ) async throws -> PrivatePushDeliveryResult {
        let shouldFail = lock.withLock { () -> Bool in
            if remainingFailures > 0 {
                remainingFailures -= 1
                return true
            }
            return false
        }
        if shouldFail {
            throw PrivateAccountAPIError.http(500)
        }
        return PrivatePushDeliveryResult(
            delivered: true,
            errorCode: nil,
            shouldDropSubscription: false
        )
    }
}
