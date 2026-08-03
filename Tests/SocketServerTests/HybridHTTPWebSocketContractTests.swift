import CryptoKit
import XCTest
@testable import SocketServer
import CoreModel
import Persistence

// Hybrid contract: one host/boot/sequence authority; HTTP remains usable when
// WebSocket is absent; duplicate mutations return the original outcome across
// transports. Idempotency storage stays bounded and never caches secrets.

@MainActor
private final class HybridReceiptRouter: FakeRouter, CommandReceiptStateRouting, ConnectionSnapshotRouting {
    private struct Receipt {
        let ownerFingerprint: String
        let paramsHash: String
        var state: String
        var result: JSONValue?
    }

    private var receipts: [String: Receipt] = [:]
    private(set) var createWorkspaceCallCount = 0
    let workspaceID = UUID().uuidString
    let surfaceID = UUID().uuidString

    private func key(method: String, clientRequestId: String) -> String {
        "\(method):\(clientRequestId)"
    }

    override func createWorkspace(name: String, cwd: String) throws -> Workspace {
        createWorkspaceCallCount += 1
        return try super.createWorkspace(name: name, cwd: cwd)
    }

    func claimCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws -> CommandReceiptClaimResult {
        let k = key(method: method, clientRequestId: clientRequestId)
        if let existing = receipts[k] {
            guard existing.ownerFingerprint == ownerFingerprint else { return .ownerMismatch }
            guard existing.paramsHash == paramsHash else { return .requestMismatch }
            switch existing.state {
            case "in_progress": return .inProgress
            case "unknown": return .unknown
            case "committed":
                guard let result = existing.result,
                      let data = try? JSONEncoder().encode(result),
                      let json = String(data: data, encoding: .utf8) else {
                    return .legacyUnverifiable
                }
                return .committed(resultJSON: json)
            default:
                return .legacyUnverifiable
            }
        }
        receipts[k] = Receipt(
            ownerFingerprint: ownerFingerprint,
            paramsHash: paramsHash,
            state: "in_progress",
            result: nil
        )
        return .claimed
    }

    func commitCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue
    ) throws {
        let k = key(method: method, clientRequestId: clientRequestId)
        guard var receipt = receipts[k],
              receipt.ownerFingerprint == ownerFingerprint,
              receipt.paramsHash == paramsHash else {
            throw JSONRPCError.internalError
        }
        receipt.state = "committed"
        receipt.result = result
        receipts[k] = receipt
    }

    func finalizeCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue,
        events: [EventBus.MutationEventIntent],
        minimumEventSequence: Int64
    ) throws -> [EventBus.Event] {
        try commitCommandReceipt(
            method: method,
            clientRequestId: clientRequestId,
            ownerFingerprint: ownerFingerprint,
            paramsHash: paramsHash,
            result: result
        )
        return events.enumerated().map { ordinal, event in
            EventBus.Event(
                seq: minimumEventSequence + Int64(ordinal) + 1,
                kind: event.kind,
                payload: event.payload,
                ts: event.createdAt.timeIntervalSince1970
            )
        }
    }

    func markCommandReceiptUnknown(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws {
        let k = key(method: method, clientRequestId: clientRequestId)
        guard var receipt = receipts[k],
              receipt.ownerFingerprint == ownerFingerprint,
              receipt.paramsHash == paramsHash else { return }
        receipt.state = "unknown"
        receipts[k] = receipt
    }

    func commandReceiptStatus(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String
    ) throws -> CommandReceiptStatusResult {
        let k = key(method: method, clientRequestId: clientRequestId)
        guard let receipt = receipts[k] else { return .absent }
        guard receipt.ownerFingerprint == ownerFingerprint else { return .ownerMismatch }
        switch receipt.state {
        case "in_progress": return .inProgress
        case "committed": return .committed
        case "unknown": return .unknown
        default: return .legacyUnverifiable
        }
    }

    func readConnectionSnapshotState() async throws -> ConnectionSnapshotReadState {
        ConnectionSnapshotReadState(
            selectedWorkspaceId: workspaceID,
            workspaces: [.object(["id": .string(workspaceID), "name": .string("Hybrid")])],
            surfaces: [ConnectionSnapshotWorkspaceItems(
                workspaceId: workspaceID,
                items: [.object(["id": .string(surfaceID), "type": .string("terminal")])]
            )],
            agentThreads: [],
            browserStates: [],
            filesStates: []
        )
    }
}

private final class HybridAuth: DirectAuthProvider {
    private let tokens: Set<String>
    init(tokens: Set<String>) { self.tokens = tokens }
    func verify(token: String) -> Bool { tokens.contains(token) }
    func createPairingCode() -> String? { nil }
    func redeemPairingCode(
        _ code: String,
        deviceName: String
    ) -> (deviceId: String, token: String)? { nil }
    func listDevices() -> [[String: Any]] { [] }
    func revokeDevice(_ id: String) {}
}

@MainActor
final class HybridHTTPWebSocketContractTests: XCTestCase {
    private let ownerToken = "hybrid-owner-token"
    private let hostId = "hybrid-host"

    func test_hybridConnectionAuthorized_liveWSPinsConnection_httpFallbackWhenNoLiveWS() {
        // WHY: live connection_id is owner-pinned; wrong id while live fails closed;
        // foreign owner cannot borrow a live connection; after WS is gone HTTP works.
        XCTAssertTrue(DirectHTTPServer.hybridConnectionAuthorized(
            connectionID: "conn-a",
            ownerFingerprint: "owner-a",
            registeredOwner: { "owner-a" },
            ownerHasLiveConnection: { true }
        ))
        XCTAssertFalse(DirectHTTPServer.hybridConnectionAuthorized(
            connectionID: "conn-b",
            ownerFingerprint: "owner-a",
            registeredOwner: { nil },
            ownerHasLiveConnection: { true }
        ), "wrong connection_id while live WS exists must reject")
        XCTAssertFalse(DirectHTTPServer.hybridConnectionAuthorized(
            connectionID: "conn-a",
            ownerFingerprint: "owner-b",
            registeredOwner: { "owner-a" },
            ownerHasLiveConnection: { false }
        ), "non-owner must not use another device's live connection_id")
        XCTAssertTrue(DirectHTTPServer.hybridConnectionAuthorized(
            connectionID: "conn-stale",
            ownerFingerprint: "owner-a",
            registeredOwner: { nil },
            ownerHasLiveConnection: { false }
        ), "HTTP hybrid path must authorize when owner has no live WebSocket")
    }

    func test_activeWebSocketRegistry_sameOwnerReplaceKeepsPhysicalLivenessUntilRemoved() {
        // WHY: same-owner reconnect must make the new id the only hybrid authority
        // while the half-closed predecessor stays physically live. Removing the
        // successor alone must not open WS-absent HTTP fallback (hasConnection
        // false) because HTTPServer.hybridConnectionAuthorized allows unregistered
        // ids only when the owner has no live WS.
        let registry = ActiveWebSocketConnectionRegistry()
        let watermark = ConnectionSequenceWatermark(initialSequence: 1)
        let otherWatermark = ConnectionSequenceWatermark(initialSequence: 9)

        // 1. Insert old same-owner WS, insert new same-owner WS.
        registry.insert("conn-old", ownerFingerprint: "owner-a", watermark: watermark)
        XCTAssertTrue(registry.hasConnection(ownedBy: "owner-a"))
        XCTAssertEqual(registry.ownerFingerprint(for: "conn-old"), "owner-a")

        registry.insert("conn-other", ownerFingerprint: "owner-b", watermark: otherWatermark)
        registry.insert("conn-new", ownerFingerprint: "owner-a", watermark: watermark)

        // 2. New is the only current hybrid authority; old is unauthorized.
        XCTAssertNil(
            registry.ownerFingerprint(for: "conn-old"),
            "predecessor must lose hybrid authority after same-owner replace"
        )
        XCTAssertEqual(registry.ownerFingerprint(for: "conn-new"), "owner-a")
        XCTAssertTrue(registry.hasConnection(ownedBy: "owner-a"))
        XCTAssertTrue(
            DirectHTTPServer.hybridConnectionAuthorized(
                connectionID: "conn-new",
                ownerFingerprint: "owner-a",
                registeredOwner: { registry.ownerFingerprint(for: "conn-new") },
                ownerHasLiveConnection: { registry.hasConnection(ownedBy: "owner-a") }
            ),
            "new live connection_id must authorize hybrid snapshot after supersede"
        )
        XCTAssertFalse(
            DirectHTTPServer.hybridConnectionAuthorized(
                connectionID: "conn-old",
                ownerFingerprint: "owner-a",
                registeredOwner: { registry.ownerFingerprint(for: "conn-old") },
                ownerHasLiveConnection: { registry.hasConnection(ownedBy: "owner-a") }
            ),
            "demoted predecessor connection_id must not authorize hybrid HTTP"
        )
        XCTAssertFalse(
            DirectHTTPServer.hybridConnectionAuthorized(
                connectionID: "conn-stale",
                ownerFingerprint: "owner-a",
                registeredOwner: { registry.ownerFingerprint(for: "conn-stale") },
                ownerHasLiveConnection: { registry.hasConnection(ownedBy: "owner-a") }
            ),
            "unregistered id must stay fail-closed while any same-owner WS is physically live"
        )

        // 5. Different owners remain unaffected through the replace.
        XCTAssertEqual(registry.ownerFingerprint(for: "conn-other"), "owner-b")
        XCTAssertTrue(registry.hasConnection(ownedBy: "owner-b"))
        XCTAssertTrue(
            DirectHTTPServer.hybridConnectionAuthorized(
                connectionID: "conn-other",
                ownerFingerprint: "owner-b",
                registeredOwner: { registry.ownerFingerprint(for: "conn-other") },
                ownerHasLiveConnection: { registry.hasConnection(ownedBy: "owner-b") }
            )
        )

        // 3. Remove new while old remains physically live: hasConnection stays true;
        //    stale/unregistered HTTP authorization remains false.
        registry.remove("conn-new")
        XCTAssertTrue(
            registry.hasConnection(ownedBy: "owner-a"),
            "demoted predecessor must keep physical liveness after successor remove"
        )
        XCTAssertNil(registry.ownerFingerprint(for: "conn-new"))
        XCTAssertNil(registry.ownerFingerprint(for: "conn-old"))
        XCTAssertFalse(
            DirectHTTPServer.hybridConnectionAuthorized(
                connectionID: "conn-stale",
                ownerFingerprint: "owner-a",
                registeredOwner: { registry.ownerFingerprint(for: "conn-stale") },
                ownerHasLiveConnection: { registry.hasConnection(ownedBy: "owner-a") }
            ),
            "WS-absent fallback must not open while a demoted predecessor is still live"
        )
        XCTAssertFalse(
            DirectHTTPServer.hybridConnectionAuthorized(
                connectionID: "conn-old",
                ownerFingerprint: "owner-a",
                registeredOwner: { registry.ownerFingerprint(for: "conn-old") },
                ownerHasLiveConnection: { registry.hasConnection(ownedBy: "owner-a") }
            ),
            "demoted predecessor remains unauthorized after successor remove"
        )
        // Other owner still live and authorized.
        XCTAssertTrue(registry.hasConnection(ownedBy: "owner-b"))
        XCTAssertEqual(registry.ownerFingerprint(for: "conn-other"), "owner-b")

        // 4. Remove old: only then WS-absent fallback can become true.
        registry.remove("conn-old")
        XCTAssertFalse(registry.hasConnection(ownedBy: "owner-a"))
        XCTAssertTrue(
            DirectHTTPServer.hybridConnectionAuthorized(
                connectionID: "conn-stale",
                ownerFingerprint: "owner-a",
                registeredOwner: { registry.ownerFingerprint(for: "conn-stale") },
                ownerHasLiveConnection: { registry.hasConnection(ownedBy: "owner-a") }
            ),
            "authenticated HTTP hybrid path may proceed once no physical WS remains for owner"
        )
        // 5 (cont). Different owners remain unaffected after owner-a drain.
        XCTAssertTrue(registry.hasConnection(ownedBy: "owner-b"))
        XCTAssertEqual(registry.ownerFingerprint(for: "conn-other"), "owner-b")
    }

    func test_boundedUnknownReceiptCache_evictsOldestWithoutStoringPayloads() {
        // WHY: unknown fences must not grow unbounded or cache secret payloads.
        var cache = BoundedUnknownReceiptCache(cap: 2)
        cache.insert(key: "a", ownerFingerprint: "o1", paramsHash: "h1")
        cache.insert(key: "b", ownerFingerprint: "o2", paramsHash: "h2")
        cache.insert(key: "c", ownerFingerprint: "o3", paramsHash: "h3")
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache["a"], "oldest unknown fence must be evicted at cap")
        XCTAssertEqual(cache["b"]?.paramsHash, "h2")
        XCTAssertEqual(cache["c"]?.ownerFingerprint, "o3")
    }

    func test_httpSnapshotAndEventsRecentWorkWithoutLiveWebSocket() async throws {
        // WHY: when WS is down the client must still rebaseline via HTTP snapshot
        // and advance by HTTP replay against the same EventBus sequence authority,
        // under the same bearer auth gate used by hybrid mutations (not loopback-open).
        let router = HybridReceiptRouter()
        let port = UInt16.random(in: 33_000...44_000)
        let bootEpoch: UInt64 = 901
        // DirectHTTPServer.auth is weak; retain for the server's lifetime.
        let auth = HybridAuth(tokens: [ownerToken])
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: false,
            dispatcher: JSONRPCDispatcher(router: router),
            auth: auth,
            serverId: hostId,
            bootEpoch: bootEpoch
        )
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        let snapshotParams: [String: Any] = [
            "connectionId": "http-only-session",
            "expectedHostId": hostId,
            "expectedBootEpoch": bootEpoch,
            "supportedStateVersion": 3,
        ]

        let missingAuth = try await rpcHTTP(
            port: port,
            method: "sync.snapshot",
            params: snapshotParams,
            token: nil
        )
        XCTAssertEqual(missingAuth.status, 401,
                       "sync.snapshot over gated HTTP must reject a missing bearer")

        let wrongAuth = try await rpcHTTP(
            port: port,
            method: "sync.snapshot",
            params: snapshotParams,
            token: "wrong-token"
        )
        XCTAssertEqual(wrongAuth.status, 401,
                       "sync.snapshot over gated HTTP must reject an invalid bearer")

        let before = EventBus.shared.currentSeq
        EventBus.shared.publish(
            kind: "hybrid.http.probe",
            payload: .object(["marker": .string("without-ws")])
        )

        let snapshot = try await rpc(
            port: port,
            method: "sync.snapshot",
            params: snapshotParams,
            token: ownerToken
        )
        XCTAssertNil(snapshot["error"], "HTTP snapshot must succeed without a live WebSocket: \(snapshot)")
        let snapResult = try XCTUnwrap(snapshot["result"] as? [String: Any])
        XCTAssertEqual(snapResult["hostId"] as? String, hostId)
        XCTAssertEqual(snapResult["bootEpoch"] as? Int ?? Int(snapResult["bootEpoch"] as? Int64 ?? -1), Int(bootEpoch))
        let sequence = try XCTUnwrap(snapResult["sequence"] as? Int ?? (snapResult["sequence"] as? Int64).map(Int.init))
        XCTAssertGreaterThanOrEqual(sequence, Int(before + 1),
                                    "snapshot sequence must come from the shared EventBus authority")

        let replay = try await rpc(
            port: port,
            method: "events.recent",
            params: ["since_seq": before],
            token: ownerToken
        )
        XCTAssertNil(replay["error"], "HTTP events.recent must work without WebSocket: \(replay)")
        let replayResult = try XCTUnwrap(replay["result"] as? [String: Any])
        let events = try XCTUnwrap(replayResult["events"] as? [[String: Any]])
        XCTAssertTrue(
            events.contains { ($0["kind"] as? String) == "hybrid.http.probe" },
            "HTTP replay must return the EventBus event published while WS was absent"
        )
        XCTAssertEqual(replayResult["last_seq"] as? Int ?? Int(replayResult["last_seq"] as? Int64 ?? -1),
                       Int(EventBus.shared.currentSeq))
    }

    func test_duplicateMutationSharedAcrossHTTPWithoutWSAndLaterRetry() async throws {
        // WHY: retries after a dropped socket must return the original outcome
        // from the shared receipt authority (not re-execute, not invent a second sequence).
        let router = HybridReceiptRouter()
        let port = UInt16.random(in: 33_000...44_000)
        let bootEpoch: UInt64 = 902
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: false,
            dispatcher: JSONRPCDispatcher(router: router),
            auth: HybridAuth(tokens: [ownerToken]),
            serverId: hostId,
            bootEpoch: bootEpoch
        )
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        let requestId = "hybrid-cross-transport-\(UUID().uuidString.prefix(8))"
        let params: [String: Any] = [
            "client_request_id": requestId,
            "connection_id": "http-session-after-ws-drop",
            "expected_host_id": hostId,
            "expected_boot_epoch": bootEpoch,
            "name": "Hybrid Workspace",
            "cwd": "/tmp/hybrid",
        ]

        let first = try await rpc(
            port: port,
            method: "workspace.create",
            params: params,
            token: ownerToken
        )
        XCTAssertNil(first["error"], "first HTTP mutation without WS must succeed: \(first)")
        let firstResult = try XCTUnwrap(canonicalJSON(first["result"]))
        XCTAssertEqual(router.createWorkspaceCallCount, 1)

        let duplicate = try await rpc(
            port: port,
            method: "workspace.create",
            params: params,
            token: ownerToken
        )
        XCTAssertNil(duplicate["error"], "duplicate must return original committed outcome: \(duplicate)")
        let duplicateResult = try XCTUnwrap(canonicalJSON(duplicate["result"]))
        XCTAssertEqual(firstResult, duplicateResult,
                       "HTTP retry of the same client_request_id must replay the original result")
        XCTAssertEqual(router.createWorkspaceCallCount, 1,
                       "shared receipt authority must prevent a second mutation effect")
    }

    func test_liveWSStillRejectsWrongConnectionId_butAcceptsOwnedConnectionOverHTTP() async throws {
        // WHY: hybrid fallback must not weaken the live-connection ownership gate.
        let router = HybridReceiptRouter()
        let port = UInt16.random(in: 33_000...44_000)
        let bootEpoch: UInt64 = 903
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: false,
            dispatcher: JSONRPCDispatcher(router: router),
            auth: HybridAuth(tokens: [ownerToken]),
            serverId: hostId,
            bootEpoch: bootEpoch
        )
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        var wsRequest = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        wsRequest.setValue("Bearer \(ownerToken)", forHTTPHeaderField: "Authorization")
        wsRequest.setValue("\(EventBus.shared.currentSeq)", forHTTPHeaderField: "x-rc2-since-seq")
        let socket = URLSession.shared.webSocketTask(with: wsRequest)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let welcome = try await receiveObject(socket)
        let connectionId = try XCTUnwrap(welcome["connectionId"] as? String)

        let wrong = try await rpc(
            port: port,
            method: "workspace.create",
            params: [
                "client_request_id": "wrong-conn-\(UUID().uuidString.prefix(8))",
                "connection_id": "not-the-live-connection",
                "expected_host_id": hostId,
                "expected_boot_epoch": bootEpoch,
                "name": "Should Fail",
                "cwd": "/tmp",
            ],
            token: ownerToken
        )
        XCTAssertEqual((wrong["error"] as? [String: Any])?["code"] as? Int, -32097,
                       "live WS must still reject foreign connection_id")
        XCTAssertEqual(router.createWorkspaceCallCount, 0)

        let owned = try await rpc(
            port: port,
            method: "workspace.create",
            params: [
                "client_request_id": "owned-conn-\(UUID().uuidString.prefix(8))",
                "connection_id": connectionId,
                "expected_host_id": hostId,
                "expected_boot_epoch": bootEpoch,
                "name": "Owned",
                "cwd": "/tmp",
            ],
            token: ownerToken
        )
        XCTAssertNil(owned["error"], "HTTP mutation with the live owned connection_id must succeed: \(owned)")
        XCTAssertEqual(router.createWorkspaceCallCount, 1)
    }

    // MARK: - Helpers

    private func rpcHTTP(
        port: UInt16,
        method: String,
        params: [String: Any],
        token: String? = nil
    ) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (status, data)
    }

    private func rpc(
        port: UInt16,
        method: String,
        params: [String: Any],
        token: String? = nil
    ) async throws -> [String: Any] {
        let (_, data) = try await rpcHTTP(port: port, method: method, params: params, token: token)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func receiveObject(_ socket: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw URLError(.cannotDecodeContentData)
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func canonicalJSON(_ value: Any?) throws -> Data {
        try JSONSerialization.data(withJSONObject: value as Any, options: [.sortedKeys])
    }
}
