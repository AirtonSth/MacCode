import XCTest
@testable import AppShell
import CoreModel
import Persistence
import RemoteCodeTreaty
@testable import SocketServer

/// WHY (C4 / M5): iOS re-sends its push token on most reconnects. Each one ran
/// the full durable receipt claim, three settings writes, a persisted
/// `private.push_token.updated` event and a receipt finalize on MainActor;
/// 5094 of 6989 live receipts were these. When the host already holds exactly
/// that registration the request must be answered before the claim, with the
/// same result, and anything that changed (token rotation, sign-out clearing
/// the target, a lost binding) must still take the full path.
@MainActor
final class PushTokenUnchangedShortCircuitTests: XCTestCase {
    private var temporaryDirectories: [String] = []
    private let mutationContext = MutationRequestContext(
        ownerFingerprint: "owner-c4",
        hostId: "host-c4",
        bootEpoch: 1
    )

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Immediate path + exact completion

    func test_unchangedLegacyToken_answersBeforeClaimWithSameResultAndNoWriteOrEvent() async throws {
        let (context, router, dispatcher) = try make()
        let token = ["push_token": JSONValue.string("apns-legacy"), "push_token_type": .string("apns"),
                     "device_id": .string("device-1"), "live_activity_token": .string("la-1")]
        let recorder = EventKindRecorder(kind: "private.push_token.updated")
        defer { recorder.stop() }

        let first = await send(dispatcher, requestId: "legacy-1", token)
        XCTAssertNil(first.error)
        XCTAssertEqual(try receiptStatus(context, "legacy-1"), .committed)
        let storedAfterFirst = try XCTUnwrap(PrivatePushTargetStore(repo: context.settingsRepo).load())

        let second = await send(dispatcher, requestId: "legacy-2", token)

        XCTAssertNil(second.error)
        XCTAssertEqual(second.result, first.result, "the short-circuit must answer exactly what the full path answered")
        XCTAssertEqual(try receiptStatus(context, "legacy-2"), .absent, "an unchanged token must not create a receipt")
        XCTAssertEqual(
            try XCTUnwrap(PrivatePushTargetStore(repo: context.settingsRepo).load()),
            storedAfterFirst,
            "no settings rewrite: updatedAt is untouched"
        )
        XCTAssertEqual(recorder.count, 1, "private.push_token.updated is published once, by the first registration only")
        XCTAssertEqual(dispatcher.commandReceiptMetrics.snapshot().pushTokenUnchangedSkipsTotal, 1)
        _ = router
    }

    func test_unchangedTypedAlertWithProfileBinding_echoesNewRevisionWithoutReceipt() async throws {
        let (context, _, dispatcher) = try make()
        var params = typedAlert(token: "apns-alert")
        params["profile_id"] = .string("profile-1")
        params["registration_revision"] = .number(3)
        let first = await send(dispatcher, requestId: "alert-1", params)
        XCTAssertNil(first.error)
        XCTAssertEqual(try receiptStatus(context, "alert-1"), .committed)

        params["registration_revision"] = .number(4)
        let second = await send(dispatcher, requestId: "alert-2", params)

        XCTAssertNil(second.error)
        XCTAssertEqual(try receiptStatus(context, "alert-2"), .absent)
        let result = try XCTUnwrap(second.result?.objectValue)
        XCTAssertEqual(result["ok"], .bool(true))
        XCTAssertEqual(result["registration_revision"], .number(4), "iOS validates the ack against the revision it sent")
        XCTAssertEqual(result["profile_id"], .string("profile-1"))
        XCTAssertEqual(result["host_id"], .string(mutationContext.hostId))
        XCTAssertEqual(result["device_id"], .string("device-1"))
        XCTAssertNil(result["push_token"], "the token is never echoed")
        var expected = try XCTUnwrap(first.result?.objectValue)
        expected["registration_revision"] = .number(4)
        XCTAssertEqual(result, expected, "same shape as the full path, revision aside")
    }

    // MARK: - A -> B stale rejection

    func test_rotatedTokenThenOldTokenAgain_eachTakesTheFullPathAndTheLatestWins() async throws {
        let (context, _, dispatcher) = try make()
        let a = typedAlert(token: "apns-A")
        let b = typedAlert(token: "apns-B")

        _ = await send(dispatcher, requestId: "rot-1", a)
        _ = await send(dispatcher, requestId: "rot-2", b)
        let backToA = await send(dispatcher, requestId: "rot-3", a)

        XCTAssertNil(backToA.error)
        XCTAssertEqual(try receiptStatus(context, "rot-2"), .committed, "a rotated token is a real change")
        XCTAssertEqual(
            try receiptStatus(context, "rot-3"),
            .committed,
            "A re-sent after B is compared with the durable state (B), not with an earlier request"
        )
        let store = PrivatePushTargetStore(repo: context.settingsRepo)
        XCTAssertEqual(store.load()?.pushToken, "apns-A")
        XCTAssertEqual(try store.records().filter { $0.purpose == .alert }.map(\.token), ["apns-A"])
        XCTAssertEqual(dispatcher.commandReceiptMetrics.snapshot().pushTokenUnchangedSkipsTotal, 0)
    }

    func test_differentProfileBinding_takesTheFullPathAndRebinds() async throws {
        let (context, _, dispatcher) = try make()
        var params = typedAlert(token: "apns-alert")
        params["profile_id"] = .string("profile-1")
        _ = await send(dispatcher, requestId: "bind-1", params)
        params["profile_id"] = .string("profile-2")

        let second = await send(dispatcher, requestId: "bind-2", params)

        XCTAssertNil(second.error)
        XCTAssertEqual(try receiptStatus(context, "bind-2"), .committed)
        XCTAssertTrue(BotAttentionPushBindingStore(db: context.db).contains(
            profileID: "profile-2", hostID: mutationContext.hostId, deviceID: "device-1"
        ))
    }

    // MARK: - Failure / lost durable state

    func test_targetClearedAfterRegistration_reRegistersInsteadOfSkipping() async throws {
        let (context, _, dispatcher) = try make()
        let params = typedAlert(token: "apns-alert")
        _ = await send(dispatcher, requestId: "clear-1", params)
        // Account sign-out / drop-subscription paths clear the legacy target.
        PrivatePushTargetStore(repo: context.settingsRepo).clear()

        let second = await send(dispatcher, requestId: "clear-2", params)

        XCTAssertNil(second.error)
        XCTAssertEqual(try receiptStatus(context, "clear-2"), .committed)
        XCTAssertEqual(PrivatePushTargetStore(repo: context.settingsRepo).load()?.pushToken, "apns-alert")
    }

    func test_unreadableStoredTarget_failsOpenToTheFullPath() async throws {
        let (context, _, dispatcher) = try make()
        let params = typedAlert(token: "apns-alert")
        _ = await send(dispatcher, requestId: "corrupt-1", params)
        try context.settingsRepo.set("private.push.target", "{not json")

        let second = await send(dispatcher, requestId: "corrupt-2", params)

        XCTAssertNil(second.error)
        XCTAssertEqual(try receiptStatus(context, "corrupt-2"), .committed)
        XCTAssertEqual(
            PrivatePushTargetStore(repo: context.settingsRepo).load()?.pushToken,
            "apns-alert",
            "an unreadable target is never treated as current; the full path rewrites it"
        )
    }

    func test_requestTheProbeCannotVouchForTakesTheFullPathUnchanged() async throws {
        let (context, _, dispatcher) = try make()
        var params = typedAlert(token: "apns-alert")
        let first = await send(dispatcher, requestId: "odd-1", params)
        // The full path accepts a whitespace profile_id (the binding store
        // ignores it); the probe refuses to vouch for it, so it is not skipped.
        params["profile_id"] = .string("   ")

        let second = await send(dispatcher, requestId: "odd-2", params)

        XCTAssertNil(first.error)
        XCTAssertNil(second.error)
        XCTAssertEqual(try receiptStatus(context, "odd-2"), .committed)
        XCTAssertEqual(dispatcher.commandReceiptMetrics.snapshot().pushTokenUnchangedSkipsTotal, 0)
    }

    // MARK: - Helpers

    private func typedAlert(token: String) -> [String: JSONValue] {
        [
            "push_token": .string(token),
            "push_token_type": .string("apns"),
            "device_id": .string("device-1"),
            "token_purpose": .string("alert"),
            "environment": .string("sandbox"),
            "server_id": .string(mutationContext.hostId),
            "contract_version": .number(1),
        ]
    }

    private func send(
        _ dispatcher: JSONRPCDispatcher,
        requestId: String,
        _ extra: [String: JSONValue]
    ) async -> JSONRPCResponse {
        var params: [String: JSONValue] = [
            "client_request_id": .string(Self.wireRequestId(requestId)),
            "connection_id": .string("c4-connection"),
            "expected_host_id": .string(mutationContext.hostId),
            "expected_boot_epoch": .number(1),
        ]
        for (key, value) in extra { params[key] = value }
        return await dispatcher.dispatch(
            JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "private.push_token.update", params: params),
            mutationContext: mutationContext
        )
    }

    private func receiptStatus(_ context: AppContext, _ requestId: String) throws -> CommandReceiptStatusResult {
        try context.commandReceiptRepo.status(
            method: "private.push_token.update",
            clientRequestId: Self.wireRequestId(requestId),
            ownerFingerprint: mutationContext.ownerFingerprint
        )
    }

    /// client_request_id must be 8-128 chars.
    private static func wireRequestId(_ name: String) -> String { "c4-req-\(name)" }

    private func make() throws -> (AppContext, AppCommandRouter, JSONRPCDispatcher) {
        let directory = NSTemporaryDirectory() + "RC2PushTokenC4-" + UUID().uuidString
        temporaryDirectories.append(directory)
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        return (context, router, JSONRPCDispatcher(router: router))
    }
}

private final class EventKindRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var matched = 0
    private var subscription: UUID?

    init(kind: String) {
        subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { [weak self] event in
            guard event.kind == kind else { return }
            self?.lock.lock(); self?.matched += 1; self?.lock.unlock()
        }
    }

    var count: Int {
        EventBus.shared.flushPersistenceSubmissions()
        lock.lock(); defer { lock.unlock() }
        return matched
    }

    func stop() {
        if let subscription { EventBus.shared.unsubscribe(subscription) }
    }
}
