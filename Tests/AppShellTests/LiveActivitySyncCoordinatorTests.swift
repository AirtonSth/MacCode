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

    func testTokenRotationsSerializeBeforeImmediateStartDelivery() async {
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

        sync.submitTokenRegistration(old)
        sync.submitTokenRegistration(newest)
        sync.submit(active([run]), cause: .started, now: Date(timeIntervalSince1970: 100))
        await sync.flush()

        XCTAssertEqual(recorder.events, ["register:old-token", "register:new-token", "deliver:start"],
                       "the backend must persist the newest token before an immediate lifecycle delivery selects it")
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
                ? Data(#"{"delivered":true,"shouldDropSubscription":false}"#.utf8)
                : Data()
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
        _ = try await api.deliverLiveActivityV2(
            accessToken: "access-token",
            request: PrivateLiveActivityV2DeliveryRequest(delivery: delivery, target: target),
            idempotencyKey: delivery.idempotencyKey
        )

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
