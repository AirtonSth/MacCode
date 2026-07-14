import XCTest
import Foundation
@testable import AppShell
import AgentRuntime
import CoreModel
import Persistence

final class LiveActivitySyncCoordinatorTests: XCTestCase {
    private final class DeliveryRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [LiveActivitySyncDelivery] = []

        func append(_ delivery: LiveActivitySyncDelivery) async {
            lock.withLock { values.append(delivery) }
        }

        var deliveries: [LiveActivitySyncDelivery] { lock.withLock { values } }
    }

    private func active(_ pairs: [(String, String)]) -> ActiveRunProjection {
        ActiveRunProjection(runs: pairs.map {
            ActiveRunProjection.Run(
                threadId: AgentThreadID(UUID(uuidString: $0.0)!),
                runId: AgentRunID(UUID(uuidString: $0.1)!)
            )
        })
    }

    func testAggregateTransitionsUseOneGenerationAndMonotonicRevision() async {
        let recorder = DeliveryRecorder()
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-1",
            bootEpoch: 12,
            initialActivityGeneration: 40,
            deliver: { delivery in await recorder.append(delivery) }
        )
        let first = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000002")
        let second = ("10000000-0000-0000-0000-000000000002", "20000000-0000-0000-0000-000000000001")

        sync.submit(active([first]), cause: .started, now: Date(timeIntervalSince1970: 100))
        sync.submit(active([first, second]), cause: .started, now: Date(timeIntervalSince1970: 101))
        sync.submit(active([first]), cause: .finished(.completed), now: Date(timeIntervalSince1970: 102))
        sync.submit(active([]), cause: .finished(.completed), now: Date(timeIntervalSince1970: 103))
        await sync.flush()

        let values = recorder.deliveries
        XCTAssertEqual(values.map(\.event), [.start, .update, .update, .end])
        XCTAssertEqual(values.map(\.projection.activeThreadCount), [1, 2, 1, 0])
        XCTAssertEqual(values.map(\.projection.revision), [1, 2, 3, 4])
        XCTAssertEqual(Set(values.map(\.activityGeneration)), [41])
        XCTAssertEqual(values.map(\.projection.epoch), ["12", "12", "12", "12"])
        XCTAssertNil(values[1].projection.threadId,
                       "aggregate cards must not deep-link ambiguously when multiple runs are active")
        XCTAssertEqual(values[2].projection.threadId, first.0.uppercased())
        XCTAssertEqual(
            values.map(\.idempotencyKey),
            [
                "activity.server-1.12.41.1.start",
                "activity.server-1.12.41.2.update",
                "activity.server-1.12.41.3.update",
                "activity.server-1.12.41.4.end"
            ]
        )

        sync.submit(active([first]), cause: .started, now: Date(timeIntervalSince1970: 104))
        await sync.flush()
        XCTAssertEqual(recorder.deliveries.last?.event, .start)
        XCTAssertEqual(recorder.deliveries.last?.activityGeneration, 42)
        XCTAssertEqual(recorder.deliveries.last?.projection.revision, 1,
                       "a new 0-to-N session must advance generation and reset only its revision")
        XCTAssertEqual(recorder.deliveries.last?.projection.sessionId, "server-1:12:42")
    }

    func testHeartbeatUsesSameGenerationAndNextRevision() async {
        let recorder = DeliveryRecorder()
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-1", bootEpoch: 7, initialActivityGeneration: 2,
            deliver: { delivery in await recorder.append(delivery) }
        )
        let run = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000001")
        sync.submit(active([run]), cause: .started, now: Date(timeIntervalSince1970: 200))
        sync.submitHeartbeat(now: Date(timeIntervalSince1970: 260))
        await sync.flush()

        XCTAssertEqual(recorder.deliveries.map(\.event), [.start, .update])
        XCTAssertEqual(recorder.deliveries.map(\.projection.revision), [1, 2])
        XCTAssertEqual(recorder.deliveries.last?.projection.updatedAt, 260)
    }

    func testLaunchReconciliationEmitsEmptyCorrection() async {
        let recorder = DeliveryRecorder()
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-1", bootEpoch: 9, initialActivityGeneration: 5,
            deliver: { delivery in await recorder.append(delivery) }
        )
        sync.submit(active([]), cause: .launchReconciliation, now: Date(timeIntervalSince1970: 300))
        await sync.flush()

        XCTAssertEqual(recorder.deliveries.map(\.event), [.end])
        XCTAssertEqual(recorder.deliveries.first?.projection.activeThreadCount, 0)
        XCTAssertEqual(recorder.deliveries.first?.projection.phase, .failed)
    }

    func testIdentityStorePersistsStableHostAndMonotonicBootAndGeneration() throws {
        let tmp = NSTemporaryDirectory() + "rc2-live-activity-identity-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let settings = SettingsRepository(db: db)

        let first = try LiveActivityIdentityStore.beginBoot(settings: settings)
        try LiveActivityIdentityStore.persistActivityGeneration(7, settings: settings)
        let second = try LiveActivityIdentityStore.beginBoot(settings: settings)

        XCTAssertEqual(second.serverId, first.serverId)
        XCTAssertEqual(second.bootEpoch, first.bootEpoch + 1,
                       "every host boot must advance the ordering epoch before any correction is sent")
        XCTAssertEqual(second.activityGeneration, 7,
                       "activity generations must survive host restarts instead of reusing an old session identity")
    }

    func testTokenRotationsSerializeBeforeImmediateStartDelivery() async throws {
        let recorder = OrderedSyncRecorder()
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-1",
            bootEpoch: 2,
            registerToken: { target in recorder.append("register:\(target.token)") },
            deliver: { delivery in recorder.append("deliver:\(delivery.event.rawValue)") }
        )
        let old = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .pushToStart,
            environment: .sandbox, token: "old-token", contractVersion: 2,
            capabilities: ["live_activity_v2"]
        )
        let newest = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .pushToStart,
            environment: .sandbox, token: "new-token", contractVersion: 2,
            capabilities: ["live_activity_v2"]
        )
        let run = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000001")

        try sync.submitTokenRegistration(old)
        try sync.submitTokenRegistration(newest)
        sync.submit(active([run]), cause: .started, now: Date(timeIntervalSince1970: 100))
        await sync.flush()

        XCTAssertEqual(recorder.events, ["register:old-token", "register:new-token", "deliver:start"],
                       "the backend must persist the newest token before an immediate lifecycle delivery selects it")
    }

    func testAcceptanceOutboxReplaysPersistedDeliveryAfterRelaunch() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-live-activity-outbox-relaunch-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(settings: SettingsRepository(db: db))
        let delivery = makeDelivery(event: .start, generation: 3, revision: 1)
        try store.enqueue(delivery, targets: [makeTarget(for: delivery)])
        let sender = OutboxSender()
        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            send: { record in try await sender.send(record) }
        )

        outbox.resumePending()
        await sender.waitForAttempts(1)
        await outbox.flush()

        XCTAssertEqual(sender.attempts.map(\.idempotencyKey), [delivery.idempotencyKey])
        XCTAssertTrue(try store.pending().isEmpty,
                      "a relaunched Mac must drain durable projections only after backend acceptance")
    }

    func testAcceptanceOutboxRetriesResponseLossWithSameIdempotencyKey() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-live-activity-outbox-response-loss-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(settings: SettingsRepository(db: db))
        let clock = ManualOutboxClock(now: Date(timeIntervalSince1970: 1_000))
        let scheduler = ManualOutboxScheduler()
        let sender = OutboxSender(failedStartAttempts: 1)
        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            now: { clock.read() },
            retryDelay: { _ in 10 },
            schedule: { delay, callback in scheduler.schedule(delay, callback) },
            send: { record in try await sender.send(record) }
        )
        let delivery = makeDelivery(event: .start, generation: 3, revision: 1)

        try outbox.accept(delivery, targets: [makeTarget(for: delivery)])
        await sender.waitForAttempts(1)
        await outbox.flush()
        XCTAssertEqual(try store.pending().map(\.delivery.idempotencyKey), [delivery.idempotencyKey])
        clock.advance(by: 10)
        scheduler.fireAll()
        await sender.waitForAttempts(2)
        await outbox.flush()

        XCTAssertEqual(sender.attempts.map(\.idempotencyKey),
                       [delivery.idempotencyKey, delivery.idempotencyKey],
                       "a lost HTTP response must retry the exact durable idempotency record")
        XCTAssertTrue(try store.pending().isEmpty)
    }

    func testTerminalProjectionBypassesBlackHoledStartAndRetiresItAfterAck() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-live-activity-outbox-terminal-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(settings: SettingsRepository(db: db))
        let clock = ManualOutboxClock(now: Date(timeIntervalSince1970: 2_000))
        let scheduler = ManualOutboxScheduler()
        let sender = OutboxSender(failedStartAttempts: .max)
        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            now: { clock.read() },
            retryDelay: { _ in 30 },
            schedule: { delay, callback in scheduler.schedule(delay, callback) },
            send: { record in try await sender.send(record) }
        )
        let start = makeDelivery(event: .start, generation: 4, revision: 1)
        let end = makeDelivery(event: .end, generation: 4, revision: 2)

        try outbox.accept(start, targets: [makeTarget(for: start)])
        await sender.waitForAttempts(1)
        try outbox.accept(end, targets: [makeTarget(for: end)])
        await sender.waitForAttempts(2)
        await outbox.flush()

        XCTAssertEqual(sender.attempts.map(\.event), [.start, .end],
                       "a terminal event must reach the backend before a black-holed start retries")
        XCTAssertTrue(try store.pending().isEmpty,
                      "terminal acknowledgement must retire superseded records in the same session")
        clock.advance(by: 30)
        scheduler.fireAll()
        await outbox.flush()
        XCTAssertEqual(sender.attempts.count, 2,
                       "a retired start must never retry after the terminal acknowledgement")
    }

    func testAcceptanceOutboxKeepsStartAndCoalescesOnlyUpdates() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-live-activity-outbox-coalesce-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(settings: SettingsRepository(db: db))
        let start = makeDelivery(event: .start, generation: 5, revision: 1)
        let oldUpdate = makeDelivery(event: .update, generation: 5, revision: 2)
        let latestUpdate = makeDelivery(event: .update, generation: 5, revision: 3)
        let target = makeTarget(for: start)
        try store.enqueue(start, targets: [target])
        try store.enqueue(oldUpdate, targets: [target])
        try store.enqueue(latestUpdate, targets: [target])
        let sender = OutboxSender()
        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            send: { record in try await sender.send(record) }
        )

        outbox.resumePending()
        await sender.waitForAttempts(2)
        await outbox.flush()

        XCTAssertEqual(sender.attempts.map(\.event), [.start, .update])
        XCTAssertEqual(sender.attempts.map(\.projection.revision), [1, 3],
                       "updates may coalesce, but a pending start must remain the session barrier")
    }

    func testOlderTerminalBarrierAcksBeforePreservedHigherGeneration() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-live-activity-outbox-generation-barrier-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(settings: SettingsRepository(db: db))
        let oldEnd = makeDelivery(event: .end, generation: 6, revision: 4)
        let newStart = makeDelivery(event: .start, generation: 7, revision: 1)
        try store.enqueue(newStart, targets: [makeTarget(for: newStart)])
        try store.enqueue(oldEnd, targets: [makeTarget(for: oldEnd)])
        let sender = OutboxSender()
        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            send: { record in try await sender.send(record) }
        )

        outbox.resumePending()
        await sender.waitForAttempts(2)
        await outbox.flush()

        XCTAssertEqual(sender.attempts.map(\.activityGeneration), [6, 7],
                       "a higher generation cannot start until the prior terminal barrier is accepted")
        XCTAssertTrue(try store.pending().isEmpty,
                      "acknowledging an older terminal must preserve then deliver the higher generation")
    }

    func testPerDeviceAcceptanceKeepsOnlyTimedOutDevicePending() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-live-activity-outbox-devices-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(settings: SettingsRepository(db: db))
        let clock = ManualOutboxClock(now: Date(timeIntervalSince1970: 3_000))
        let scheduler = ManualOutboxScheduler()
        let sender = DeviceOutboxSender(failingDeviceID: "device-b")
        let delivery = makeDelivery(event: .update, generation: 8, revision: 2)
        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            now: { clock.read() },
            retryDelay: { _ in 10 },
            schedule: { delay, callback in scheduler.schedule(delay, callback) },
            send: { record in try await sender.send(record) }
        )

        try outbox.accept(delivery, targets: [
            makeTarget(for: delivery, deviceId: "device-a"),
            makeTarget(for: delivery, deviceId: "device-b")
        ])
        await sender.waitForAttempts(2)
        await outbox.flush()

        let pending = try store.pending()
        XCTAssertEqual(pending.count, 1)
        guard case .v2(let pendingTarget) = try XCTUnwrap(pending.first).target else {
            return XCTFail("only the timed-out typed target should remain")
        }
        XCTAssertEqual(pendingTarget.deviceId, "device-b",
                       "device A acceptance must never delete or acknowledge device B's failed record")
        XCTAssertEqual(sender.count(for: "device-a"), 1)

        clock.advance(by: 10)
        sender.allowRetries()
        scheduler.fireAll()
        await sender.waitForAttempts(3)
        await outbox.flush()

        XCTAssertTrue(try store.pending().isEmpty)
        XCTAssertEqual(sender.count(for: "device-a"), 1,
                       "retrying device B must not resend or tombstone already accepted device A")
        XCTAssertEqual(sender.count(for: "device-b"), 2)
    }

    func testHigherGenerationWaitsForScheduledOlderTerminalRetry() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-live-activity-outbox-terminal-retry-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(settings: SettingsRepository(db: db))
        let clock = ManualOutboxClock(now: Date(timeIntervalSince1970: 4_000))
        let scheduler = ManualOutboxScheduler()
        let sender = DeviceOutboxSender(failingDeviceID: "device-1")
        let oldEnd = makeDelivery(event: .end, generation: 8, revision: 3)
        let newStart = makeDelivery(event: .start, generation: 9, revision: 1)
        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            now: { clock.read() },
            retryDelay: { _ in 10 },
            schedule: { delay, callback in scheduler.schedule(delay, callback) },
            send: { record in try await sender.send(record) }
        )

        try outbox.accept(oldEnd, targets: [makeTarget(for: oldEnd)])
        try outbox.accept(newStart, targets: [makeTarget(for: newStart)])
        await sender.waitForAttempts(1)
        await outbox.flush()
        XCTAssertEqual(sender.generations, [8],
                       "a ready newer start cannot bypass an older terminal barrier awaiting retry")

        sender.allowRetries()
        clock.advance(by: 10)
        scheduler.fireAll()
        await sender.waitForAttempts(3)
        await outbox.flush()
        XCTAssertEqual(sender.generations, [8, 8, 9])
    }

    func testIosGenerationDriftBindsUpdateTokenToCurrentMacGeneration() async throws {
        let registrations = TargetRegistrationRecorder()
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-1",
            bootEpoch: 9,
            initialActivityGeneration: 4,
            registerToken: { registrations.append($0) },
            deliver: { _ in }
        )
        let run = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000001")
        sync.submit(active([run]), cause: .started)
        await sync.flush()
        let drifted = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "untrusted-ios-host", purpose: .activityUpdate,
            environment: .sandbox, token: "update-token", activityGeneration: 999,
            activityId: "activity-1", contractVersion: 2, capabilities: ["live_activity_v2"]
        )

        let bound = try sync.submitTokenRegistration(drifted)
        await sync.flush()

        XCTAssertEqual(bound.ownership, LiveActivityTokenOwnership(
            activityId: "activity-1", hostId: "server-1", bootEpoch: 9,
            activityGeneration: 5, activitySessionId: "server-1:9:5"
        ), "the Mac projection owns generation; an iOS-local counter cannot replace it")
        XCTAssertEqual(registrations.targets.last, bound)
        let partialAuthority = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .activityUpdate,
            environment: .sandbox, token: "partial-token", activityGeneration: 5,
            activityId: "activity-partial", bootEpoch: 9,
            contractVersion: 2, capabilities: ["live_activity_v2"]
        )
        XCTAssertThrowsError(try sync.submitTokenRegistration(partialAuthority),
                             "partial remote ownership must not be silently rebound to the current generation")
    }

    func testLateOldActivityTokenRetainsOldOwnershipAfterNewGeneration() async throws {
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-1", bootEpoch: 9, initialActivityGeneration: 4,
            registerToken: { _ in }, deliver: { _ in }
        )
        let run = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000001")
        sync.submit(active([run]), cause: .started)
        await sync.flush()
        let old = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .activityUpdate,
            environment: .sandbox, token: "old-token", activityGeneration: 5,
            activityId: "old-activity", bootEpoch: 9, activitySessionId: "server-1:9:5",
            contractVersion: 2, capabilities: ["live_activity_v2"]
        )
        let first = try sync.submitTokenRegistration(old)
        sync.submit(active([]), cause: .finished(.completed))
        sync.submit(active([run]), cause: .started)
        await sync.flush()

        let late = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .activityUpdate,
            environment: .sandbox, token: "rotated-old-token", activityGeneration: 6,
            activityId: "old-activity", contractVersion: 2, capabilities: ["live_activity_v2"]
        )
        let rebound = try sync.submitTokenRegistration(late)
        let otherDevice = PrivatePushTargetRecord(
            deviceId: "device-2", serverId: "server-1", purpose: .activityUpdate,
            environment: .sandbox, token: "other-device-token", activityGeneration: 5,
            activityId: "old-activity", contractVersion: 2, capabilities: ["live_activity_v2"]
        )
        let otherBound = try sync.submitTokenRegistration(otherDevice)

        XCTAssertEqual(first.ownership?.activityGeneration, 5)
        XCTAssertEqual(rebound.ownership, first.ownership,
                       "a late token rotation for an old Activity must not attach to the newest generation")
        XCTAssertEqual(otherBound.ownership?.activityGeneration, 6,
                       "an activity ID mapping from one device must not bind another device to its old generation")
    }

    func testCoordinatorSurfacesAcceptancePersistenceFailure() async {
        let errors = DeliveryErrorRecorder()
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-1",
            bootEpoch: 3,
            onDeliveryError: { error, delivery in errors.append(error, delivery: delivery) },
            deliver: { _ in throw OutboxTestError.persistence }
        )
        let run = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000001")

        sync.submit(active([run]), cause: .started)
        await sync.flush()

        XCTAssertEqual(errors.count, 1,
                       "serialized lifecycle delivery must surface durable-acceptance failure instead of swallowing it")
    }

    func testV2ContractEncodesRootSharedFieldNamesAndEpochIntegers() throws {
        let projection = PrivateLiveActivityProjectionV2(
            statusLine: "1 active run",
            phase: .running,
            activeThreadCount: 1,
            updatedAt: 900,
            runStartDate: 800,
            workspaceId: "workspace-1",
            threadId: "thread-1",
            sessionId: "server-1:8:3",
            hostId: "server-1",
            epoch: "8",
            revision: 4
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(projection)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), [
            "title", "statusLine", "preview", "phase", "activeThreadCount", "updatedAt",
            "runStartDate", "workspaceId", "threadId", "protocolVersion", "activityKey",
            "sessionId", "hostId", "epoch", "revision"
        ])
        XCTAssertEqual(object["protocolVersion"] as? Int, 2)
        XCTAssertEqual(object["activityKey"] as? String, "active-threads")
        XCTAssertEqual(object["sessionId"] as? String, "server-1:8:3")
        XCTAssertEqual(object["hostId"] as? String, "server-1")
        XCTAssertEqual(object["epoch"] as? String, "8")
        XCTAssertEqual(object["revision"] as? Int, 4)
        XCTAssertEqual(object["activeThreadCount"] as? Int, 1)
        XCTAssertEqual(object["updatedAt"] as? Int, 900)

        let target = PrivatePushTargetRecord(
            deviceId: "device-1",
            serverId: "server-1",
            purpose: .pushToStart,
            environment: .sandbox,
            token: "activity-token",
            activityGeneration: 3,
            contractVersion: 2,
            capabilities: ["live_activity_v2"]
        )
        let request = PrivateLiveActivityV2DeliveryRequest(
            delivery: LiveActivitySyncDelivery(
                event: .start,
                projection: projection,
                activityGeneration: 3,
                idempotencyKey: "activity.server-1.8.3.4.start"
            ),
            target: target
        )
        let requestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(Set(requestObject.keys), [
            "protocolVersion", "activityKey", "activitySessionId", "hostId", "bootEpoch", "activityGeneration",
            "revision", "event", "deviceId", "environment", "phase", "activeThreadCount",
            "title", "statusLine", "preview", "updatedAtEpochSeconds", "runStartEpochSeconds",
            "workspaceId", "threadId"
        ])
        XCTAssertEqual(requestObject["bootEpoch"] as? Int, 8)
        XCTAssertEqual(requestObject["activityGeneration"] as? Int, 3)
        XCTAssertEqual(requestObject["updatedAtEpochSeconds"] as? Int, 900,
                       "the canonical backend contract requires an epoch timestamp at the root")
        XCTAssertEqual(requestObject["event"] as? String, "start")
        XCTAssertEqual(requestObject["deviceId"] as? String, "device-1")
        XCTAssertEqual(requestObject["environment"] as? String, "sandbox")
        XCTAssertNil(requestObject["contentState"],
                     "the v2 backend adapter must not send the legacy nested content-state envelope")
        XCTAssertNil(requestObject["liveActivityToken"])
        XCTAssertNil(requestObject["pushToken"])

        let registration = PrivateLiveActivityV2TokenRegistration(
            deviceId: "device-1",
            environment: .sandbox,
            token: "activity-token",
            tokenKind: .pushToStart
        )
        let registrationObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(registration)) as? [String: Any]
        )
        XCTAssertEqual(Set(registrationObject.keys), [
            "protocolVersion", "activityKey", "deviceId", "environment", "token", "tokenKind"
        ])
        XCTAssertEqual(registrationObject["tokenKind"] as? String, "pushToStart")
        XCTAssertEqual(
            URLSessionPrivateAccountAPI.liveActivityV2DeliveryPath,
            "/v1/private/push-notification/live-activities/deliver"
        )
        XCTAssertEqual(
            URLSessionPrivateAccountAPI.liveActivityV2TokensPath,
            "/v1/private/push-notification/live-activities/tokens"
        )

        let legacy = projection.legacyContentState
        XCTAssertEqual(legacy.activeThreadCount, 1)
        XCTAssertEqual(legacy.updatedAt, 900)
        XCTAssertEqual(legacy.threadId, "thread-1",
                       "capability-disabled targets must retain the existing ActivityKit content adapter")
    }

    func testURLSessionAPIUsesCanonicalAuthenticatedV2RoutesAndFlatBody() async throws {
        let recorder = HTTPRequestRecorder()
        HTTPRecordingURLProtocol.setHandler { request in
            recorder.append(request)
            let body = request.url?.path.hasSuffix("/deliver") == true
                ? Data(#"{"accepted":false,"id":"outbox-1","status":"pending","attempts":0,"nextAttemptAt":1783998600000}"#.utf8)
                : Data(#"{"token":{"activityKey":"active-threads","deviceId":"device-1","environment":"sandbox","tokenKind":"pushToStart"}}"#.utf8)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
        defer { HTTPRecordingURLProtocol.setHandler(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPRecordingURLProtocol.self]
        let api = URLSessionPrivateAccountAPI(
            baseURL: URL(string: "https://private.example.test")!,
            session: URLSession(configuration: configuration)
        )
        let target = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .pushToStart,
            environment: .sandbox, token: "start-token", contractVersion: 2,
            capabilities: ["live_activity_v2"]
        )
        let projection = PrivateLiveActivityProjectionV2(
            statusLine: "1 active run", phase: .running, activeThreadCount: 1,
            updatedAt: 900, sessionId: "server-1:8:3", hostId: "server-1",
            epoch: "8", revision: 4
        )
        let delivery = LiveActivitySyncDelivery(
            event: .start, projection: projection, activityGeneration: 3,
            idempotencyKey: "activity.server-1.8.3.4.start"
        )

        try await api.registerLiveActivityTokenV2(
            accessToken: "access-token",
            registration: PrivateLiveActivityV2TokenRegistration(
                deviceId: "device-1", environment: .sandbox,
                token: "start-token", tokenKind: .pushToStart
            )
        )
        let ack = try await api.deliverLiveActivityV2(
            accessToken: "access-token",
            request: PrivateLiveActivityV2DeliveryRequest(delivery: delivery, target: target),
            idempotencyKey: delivery.idempotencyKey
        )
        XCTAssertEqual(ack.status, "pending")
        XCTAssertEqual(ack.accepted, false)
        XCTAssertEqual(ack.nextAttemptAt, "1783998600000.0")

        let requests = recorder.requests
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/v1/private/push-notification/live-activities/tokens",
            "/v1/private/push-notification/live-activities/deliver"
        ])
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer access-token", "Bearer access-token"])
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Idempotency-Key"), delivery.idempotencyKey)
        let deliveryBody = try XCTUnwrap(recorder.bodies[1])
        let bodyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: deliveryBody) as? [String: Any]
        )
        XCTAssertEqual(bodyObject["bootEpoch"] as? Int, 8)
        XCTAssertEqual(bodyObject["activityGeneration"] as? Int, 3)
        XCTAssertEqual(bodyObject["activitySessionId"] as? String, "server-1:8:3")
        XCTAssertNil(bodyObject["contentState"])
    }

    func testTypedTargetsRetainPurposeEnvironmentAndInvalidateOnlyOneActivityToken() throws {
        let tmp = NSTemporaryDirectory() + "rc2-private-target-v2-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = PrivatePushTargetStore(repo: SettingsRepository(db: db))
        let alert = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .alert,
            environment: .sandbox, token: "alert-token"
        )
        let activity = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .activityUpdate,
            environment: .sandbox, token: "activity-token", activityGeneration: 4,
            activityId: "activity-1", contractVersion: 2,
            capabilities: ["live_activity_v2"]
        )
        try store.upsert(alert)
        try store.upsert(activity)

        try store.invalidate(
            deviceId: "device-1", serverId: "server-1", purpose: .activityUpdate,
            environment: .sandbox, activityGeneration: 4, activityId: "activity-1"
        )

        XCTAssertEqual(try store.records(), [alert],
                       "an invalid ActivityKit token must not erase the device alert token")
    }

    func testLateOldEndSelectsExactOldActivityOwnershipNeverLegacyNewestToken() throws {
        let tmp = NSTemporaryDirectory() + "rc2-private-target-old-activity-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let settings = SettingsRepository(db: db)
        let targetStore = PrivatePushTargetStore(repo: settings)
        targetStore.save(
            pushToken: "newest-alert", pushTokenType: "apns",
            liveActivityToken: "newest-legacy-activity", deviceId: "device-1"
        )
        let old = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .activityUpdate,
            environment: .sandbox, token: "old-update", activityGeneration: 8,
            activityId: "old-activity", bootEpoch: 7, activitySessionId: "server-1:7:8",
            contractVersion: 2, capabilities: ["live_activity_v2"]
        )
        let newest = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .activityUpdate,
            environment: .sandbox, token: "new-update", activityGeneration: 9,
            activityId: "new-activity", bootEpoch: 7, activitySessionId: "server-1:7:9",
            contractVersion: 2, capabilities: ["live_activity_v2"]
        )
        try targetStore.upsert(old)
        try targetStore.upsert(newest)
        let bridge = PrivateNotificationBridge(
            accountStore: PrivateAccountSessionStore(repo: settings),
            pushTargetStore: targetStore
        )
        let oldEnd = makeDelivery(event: .end, generation: 8, revision: 4)

        XCTAssertEqual(try bridge.acceptanceTargets(for: oldEnd), [.v2(old)])
        let unknown = makeDelivery(event: .end, generation: 10, revision: 1)
        XCTAssertThrowsError(try bridge.acceptanceTargets(for: unknown),
                             "a missing typed ownership must not fall through to the newest legacy token")
    }

    func testV2CapabilityIsDisabledByDefault() {
        let target = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .pushToStart,
            environment: .sandbox, token: "token", contractVersion: 2
        )

        XCTAssertFalse(target.supportsLiveActivityV2,
                       "legacy devices must not receive the new contract until they advertise the capability")
    }

    func testHTTPPortOverrideIsSharedByListenerBonjourAndPairing() {
        XCTAssertEqual(DirectAccessConfiguration.port(environment: [:]), 18217)
        XCTAssertEqual(DirectAccessConfiguration.port(environment: ["RC2_HTTP_PORT": "18218"]), 18218)
        XCTAssertEqual(DirectAccessConfiguration.port(environment: ["RC2_HTTP_PORT": "invalid"]), 18217)
        XCTAssertEqual(DirectAccessConfiguration.port(environment: ["RC2_HTTP_PORT": "70000"]), 18217)
    }

    private func makeDelivery(
        event: PrivateLiveActivityEvent,
        generation: UInt64,
        revision: Int64
    ) -> LiveActivitySyncDelivery {
        LiveActivitySyncDelivery(
            event: event,
            projection: PrivateLiveActivityProjectionV2(
                statusLine: event == .end ? "0 active runs" : "1 active run",
                phase: event == .end ? .completed : .running,
                activeThreadCount: event == .end ? 0 : 1,
                updatedAt: 1_000,
                sessionId: "server-1:7:\(generation)",
                hostId: "server-1",
                epoch: "7",
                revision: revision
            ),
            activityGeneration: generation,
            idempotencyKey: "activity.server-1.7.\(generation).\(revision).\(event.rawValue)"
        )
    }

    private func makeTarget(
        for delivery: LiveActivitySyncDelivery,
        deviceId: String = "device-1"
    ) -> LiveActivityAcceptanceTarget {
        .v2(PrivatePushTargetRecord(
            deviceId: deviceId,
            serverId: delivery.projection.hostId,
            purpose: delivery.event == .start ? .pushToStart : .activityUpdate,
            environment: .sandbox,
            token: "token-\(deviceId)",
            activityGeneration: delivery.activityGeneration,
            activityId: "activity-\(deviceId)",
            bootEpoch: UInt64(delivery.projection.epoch),
            activitySessionId: delivery.projection.sessionId,
            contractVersion: 2,
            capabilities: ["live_activity_v2"]
        ))
    }
}

private final class HTTPRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    private var bodyValues: [Data?] = []

    func append(_ request: URLRequest) {
        let body = request.httpBody ?? request.httpBodyStream.flatMap(Self.readBody)
        lock.withLock {
            values.append(request)
            bodyValues.append(body)
        }
    }

    var requests: [URLRequest] { lock.withLock { values } }
    var bodies: [Data?] { lock.withLock { bodyValues } }

    private static func readBody(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class OrderedSyncRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) { lock.withLock { values.append(value) } }
    var events: [String] { lock.withLock { values } }
}

private enum OutboxTestError: Error {
    case responseLost
    case persistence
}

private final class OutboxSender: @unchecked Sendable {
    private let lock = NSLock()
    private let failedStartAttempts: Int
    private var values: [LiveActivitySyncDelivery] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(failedStartAttempts: Int = 0) {
        self.failedStartAttempts = failedStartAttempts
    }

    func send(_ record: LiveActivityAcceptanceRecord) async throws -> PrivateLiveActivityV2DeliveryAck {
        let delivery = record.delivery
        let result = lock.withLock { () -> (Int, [CheckedContinuation<Void, Never>]) in
            values.append(delivery)
            let count = values.count
            let ready = waiters.filter { $0.0 <= count }
            waiters.removeAll { $0.0 <= count }
            return (values.filter { $0.event == .start }.count, ready.map(\.1))
        }
        result.1.forEach { $0.resume() }
        if delivery.event == .start, result.0 <= failedStartAttempts {
            throw OutboxTestError.responseLost
        }
        return PrivateLiveActivityV2DeliveryAck(
            id: "ack-\(delivery.idempotencyKey)",
            status: "queued",
            attempts: 0,
            nextAttemptAt: nil
        )
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

    var attempts: [LiveActivitySyncDelivery] { lock.withLock { values } }
}

private final class ManualOutboxClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(now: Date) { value = now }
    func read() -> Date { lock.withLock { value } }
    func advance(by interval: TimeInterval) { lock.withLock { value.addTimeInterval(interval) } }
}

private final class ManualOutboxScheduler: @unchecked Sendable {
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

private final class DeliveryErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ error: Error, delivery: LiveActivitySyncDelivery) {
        lock.withLock { values.append(delivery.idempotencyKey + ":" + String(describing: error)) }
    }

    var count: Int { lock.withLock { values.count } }
}

private final class TargetRegistrationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PrivatePushTargetRecord] = []
    func append(_ target: PrivatePushTargetRecord) { lock.withLock { values.append(target) } }
    var targets: [PrivatePushTargetRecord] { lock.withLock { values } }
}

private final class DeviceOutboxSender: @unchecked Sendable {
    private let lock = NSLock()
    private let failingDeviceID: String
    private var retryAllowed = false
    private var deviceIDs: [String] = []
    private var generationValues: [UInt64] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(failingDeviceID: String) { self.failingDeviceID = failingDeviceID }

    func send(_ record: LiveActivityAcceptanceRecord) async throws -> PrivateLiveActivityV2DeliveryAck {
        guard case .v2(let target) = record.target else { throw OutboxTestError.responseLost }
        let result = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
            deviceIDs.append(target.deviceId)
            generationValues.append(record.delivery.activityGeneration)
            let ready = waiters.filter { $0.0 <= deviceIDs.count }
            waiters.removeAll { $0.0 <= deviceIDs.count }
            return (retryAllowed, ready.map(\.1))
        }
        result.1.forEach { $0.resume() }
        if target.deviceId == failingDeviceID, !result.0 { throw OutboxTestError.responseLost }
        return PrivateLiveActivityV2DeliveryAck(id: record.recordID, status: "pending", attempts: 0, nextAttemptAt: nil)
    }

    func allowRetries() { lock.withLock { retryAllowed = true } }
    func count(for deviceID: String) -> Int { lock.withLock { deviceIDs.filter { $0 == deviceID }.count } }
    var generations: [UInt64] { lock.withLock { generationValues } }
    func waitForAttempts(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if deviceIDs.count >= count { return true }
                waiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

private final class HTTPRecordingURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: Handler?

    static func setHandler(_ value: Handler?) {
        lock.withLock { handler = value }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.lock.withLock { Self.handler })
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
