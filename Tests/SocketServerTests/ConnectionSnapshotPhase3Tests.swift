import CryptoKit
import XCTest
@testable import SocketServer

@MainActor
private final class Phase3SnapshotFakeRouter: FakeRouter, ConnectionSnapshotRouting {
    let workspaceID = UUID().uuidString
    let surfaceID = UUID().uuidString
    let threadID = UUID().uuidString
    private(set) var snapshotReadCount = 0
    var snapshotReadStarted: DispatchSemaphore?
    var snapshotReadRelease: DispatchSemaphore?
    /// When set, the expensive portion of the read runs off MainActor (mirrors
    /// production AgentThreadListGateway hop) so MainActor/HTTP stay free.
    var offMainDelayNanoseconds: UInt64 = 0
    nonisolated(unsafe) private(set) var threadQueryOnMainCount = 0
    nonisolated(unsafe) private(set) var threadQueryOffMainCount = 0

    func readConnectionSnapshotState() async throws -> ConnectionSnapshotReadState {
        snapshotReadCount += 1
        if snapshotReadCount == 1,
           let snapshotReadStarted,
           let snapshotReadRelease {
            snapshotReadStarted.signal()
            _ = snapshotReadRelease.wait(timeout: .now() + 2)
        }
        let delay = offMainDelayNanoseconds
        if delay > 0 {
            // Capture probe counters off MainActor like AgentThreadListGateway.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue(label: "io.remotecode.test.connection-snapshot-thread-list").async {
                    if Thread.isMainThread {
                        self.threadQueryOnMainCount += 1
                    } else {
                        self.threadQueryOffMainCount += 1
                    }
                    Thread.sleep(forTimeInterval: TimeInterval(delay) / 1_000_000_000)
                    continuation.resume()
                }
            }
        }
        return ConnectionSnapshotReadState(
            selectedWorkspaceId: workspaceID,
            workspaces: [.object(["id": .string(workspaceID), "name": .string("Snapshot")])],
            surfaces: [ConnectionSnapshotWorkspaceItems(
                workspaceId: workspaceID,
                items: [.object(["id": .string(surfaceID), "type": .string("browser")])]
            )],
            agentThreads: [ConnectionSnapshotWorkspaceItems(
                workspaceId: workspaceID,
                items: [.object([
                    "id": .string(threadID),
                    "workspaceId": .string(workspaceID),
                    "title": .string("Thread"),
                ])]
            )],
            browserStates: [ConnectionSnapshotSurfaceState(
                workspaceId: workspaceID,
                surfaceId: surfaceID,
                state: .object(["url": .string("https://example.test")])
            )],
            filesStates: []
        )
    }
}

private final class Phase3SnapshotAuth: DirectAuthProvider {
    private let acceptedTokens: Set<String>

    init(acceptedTokens: Set<String>) {
        self.acceptedTokens = acceptedTokens
    }

    func verify(token: String) -> Bool { acceptedTokens.contains(token) }
    func createPairingCode() -> String? { nil }
    func redeemPairingCode(
        _ code: String,
        deviceName: String
    ) -> (deviceId: String, token: String)? { nil }
    func listDevices() -> [[String: Any]] { [] }
    func revokeDevice(_ id: String) {}
}

final class ConnectionSnapshotPhase3Tests: XCTestCase {
    func test_dispatcherSnapshotRead_doesNotHoldEventBusBarrierAcrossSlowStateRead() async throws {
        let router = await MainActor.run { Phase3SnapshotFakeRouter() }
        let stateReadStarted = DispatchSemaphore(value: 0)
        let releaseStateRead = DispatchSemaphore(value: 0)
        await MainActor.run {
            router.snapshotReadStarted = stateReadStarted
            router.snapshotReadRelease = releaseStateRead
        }

        let snapshotTask = Task { @MainActor in
            try await JSONRPCDispatcher(router: router).readConnectionSnapshot()
        }
        XCTAssertEqual(stateReadStarted.wait(timeout: .now() + 2), .success)

        let publishDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            EventBus.shared.publish(kind: "snapshot.responsiveness", payload: .object([:]))
            publishDone.signal()
        }
        XCTAssertEqual(
            publishDone.wait(timeout: .now() + 0.05),
            .success,
            "snapshot construction must not block EventBus publication"
        )

        releaseStateRead.signal()
        let result = try await snapshotTask.value
        XCTAssertEqual(result.metadata.sequence, EventBus.shared.currentSeq)
    }

    func test_dispatcherSnapshotRead_offMainThreadQueryKeepsMainActorAndEventBusResponsive() async throws {
        // WHY: production hops AgentThread list/decode off MainActor. While that
        // work is delayed, EventBus publish and MainActor heartbeats must still
        // progress (HTTP/RPC acceptance shares MainActor with the dispatcher).
        let router = await MainActor.run {
            let router = Phase3SnapshotFakeRouter()
            router.offMainDelayNanoseconds = 40_000_000
            return router
        }

        var heartbeats = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                heartbeats += 1
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        let snapshotTask = Task { @MainActor in
            try await JSONRPCDispatcher(router: router).readConnectionSnapshot()
        }

        // Give the off-main hop a moment to start, then prove EventBus is free.
        try await Task.sleep(nanoseconds: 5_000_000)
        let publishDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            EventBus.shared.publish(kind: "snapshot.off_main.responsiveness", payload: .object([:]))
            publishDone.signal()
        }
        XCTAssertEqual(
            publishDone.wait(timeout: .now() + 0.05),
            .success,
            "metadata fence must not hold EventBus while thread list runs off-main"
        )

        let result = try await snapshotTask.value
        heartbeat.cancel()
        _ = await heartbeat.result

        let offMain = await MainActor.run { router.threadQueryOffMainCount }
        let onMain = await MainActor.run { router.threadQueryOnMainCount }
        XCTAssertEqual(onMain, 0)
        XCTAssertGreaterThanOrEqual(
            offMain,
            1,
            "each snapshot attempt must enumerate threads off MainActor"
        )
        XCTAssertGreaterThan(
            heartbeats,
            3,
            "MainActor must keep pumping while snapshot thread query is delayed off-main"
        )
        XCTAssertEqual(result.metadata.sequence, EventBus.shared.currentSeq)
    }

    func test_dispatcherSnapshotRead_timeoutIsFailFastAndSingleFlight() async throws {
        let router = await MainActor.run {
            let router = Phase3SnapshotFakeRouter()
            router.offMainDelayNanoseconds = 200_000_000
            return router
        }
        let dispatcher = await MainActor.run { JSONRPCDispatcher(router: router) }

        let first: Task<Int?, Never> = Task { @MainActor in
            do {
                _ = try await dispatcher.readConnectionSnapshot(timeoutNanoseconds: 5_000_000)
                return nil
            } catch let error as JSONRPCError {
                return error.code
            } catch {
                return nil
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let firstCode = await first.value
        XCTAssertEqual(firstCode, JSONRPCDispatcher.snapshotTimedOut.code)

        let secondStarted = DispatchTime.now().uptimeNanoseconds
        let second: Task<Int?, Never> = Task { @MainActor in
            do {
                _ = try await dispatcher.readConnectionSnapshot(timeoutNanoseconds: 5_000_000)
                return nil
            } catch let error as JSONRPCError {
                return error.code
            } catch {
                return nil
            }
        }
        let secondCode = await second.value
        XCTAssertEqual(secondCode, JSONRPCDispatcher.snapshotTimedOut.code)
        XCTAssertLessThan(
            HTTPRequestPhaseMetrics.elapsedMilliseconds(since: secondStarted),
            50,
            "a stale physical read must not make later callers wait or spawn another read"
        )

        try await Task.sleep(nanoseconds: 250_000_000)
        let readCount = await MainActor.run { router.snapshotReadCount }
        XCTAssertEqual(readCount, 1)
    }

    func test_requestPhaseMetrics_areSecretFreeAndJSONSerializable() throws {
        let metrics = HTTPRequestPhaseMetrics()
        metrics.record(.admit, latencyMilliseconds: 2)
        metrics.record(.snapshotRead, latencyMilliseconds: 3)
        metrics.record(.snapshotEncode, latencyMilliseconds: 4)
        metrics.record(.responseWrite, latencyMilliseconds: 5)
        metrics.recordCancelled()
        metrics.recordTimedOut()
        metrics.recordFenceRetry()
        metrics.recordFenceExhausted()
        metrics.recordWriteAborted()

        let snapshot = metrics.snapshot()
        XCTAssertEqual(snapshot.snapshotRead.count, 1)
        XCTAssertEqual(snapshot.snapshotEncode.maxMilliseconds, 4)
        XCTAssertEqual(snapshot.cancelledTotal, 1)
        XCTAssertEqual(snapshot.timedOutTotal, 1)
        XCTAssertEqual(snapshot.fenceRetryTotal, 1)
        XCTAssertEqual(snapshot.fenceExhaustedTotal, 1)
        XCTAssertEqual(snapshot.writeAbortedTotal, 1)

        let object = DirectHTTPServer.requestPhaseMetricsJSON(snapshot)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: object))
        let text = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("token"))
        XCTAssertFalse(text.contains("owner"))
        XCTAssertFalse(text.contains("payload"))
    }

    @MainActor
    func test_syncSnapshotImmediatelyAfterWelcomeSeesRegisteredConnection() async throws {
        let router = Phase3SnapshotFakeRouter()
        let port = UInt16.random(in: 33_000...44_000)
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: router),
            serverId: "phase3-host",
            bootEpoch: 73
        )
        let releaseWelcomeHandler = DispatchSemaphore(value: 0)
        server.afterWelcomeWriteForTests = { _ in
            _ = releaseWelcomeHandler.wait(timeout: .now() + 2)
        }
        try server.start()
        try await Task.sleep(nanoseconds: 80_000_000)

        let socket = webSocketTask(port: port)
        socket.resume()
        defer {
            releaseWelcomeHandler.signal()
            socket.cancel(with: .normalClosure, reason: nil)
            server.stop()
        }
        let welcome = try await receiveObject(socket)
        let connectionID = try XCTUnwrap(welcome["connectionId"] as? String)

        let snapshot = try await rpc(
            port: port,
            id: "immediate-after-welcome",
            params: [
                "connectionId": connectionID,
                "expectedHostId": "phase3-host",
                "expectedBootEpoch": 73,
                "supportedStateVersion": 3,
            ]
        )

        XCTAssertNil(snapshot["error"],
                     "welcome ownership must be registered before the client can act on that welcome")
        XCTAssertEqual(router.snapshotReadCount, 1)
    }

    @MainActor
    func test_syncSnapshot_admitsAnyAuthenticatedBearerIndependentOfLiveWSOwner() async throws {
        // WHY: HTTP snapshot is bearer-gated only. Live WS connection ownership
        // must not block another authenticated bearer (or the same owner under a
        // different connection id).
        let tokenA = "phase3-owner-token-a"
        let tokenB = "phase3-owner-token-b"
        let auth = Phase3SnapshotAuth(acceptedTokens: [tokenA, tokenB])
        let router = Phase3SnapshotFakeRouter()
        let port = UInt16.random(in: 33_000...44_000)
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: false,
            dispatcher: JSONRPCDispatcher(router: router),
            auth: auth,
            serverId: "phase3-host",
            bootEpoch: 73
        )
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        request.setValue("Bearer \(tokenA)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "\(EventBus.shared.currentSeq)",
            forHTTPHeaderField: "x-rc2-since-seq"
        )
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let welcome = try await receiveObject(socket)
        let connectionID = try XCTUnwrap(welcome["connectionId"] as? String)
        let params: [String: Any] = [
            "connectionId": connectionID,
            "expectedHostId": "phase3-host",
            "expectedBootEpoch": 73,
            "supportedStateVersion": 3,
        ]

        let otherBearer = try await rpc(
            port: port,
            id: "other-bearer",
            params: params,
            bearerToken: tokenB
        )
        XCTAssertNil(otherBearer["error"],
                     "authenticated bearer B must snapshot while WS is owned by A: \(otherBearer)")
        XCTAssertEqual(router.snapshotReadCount, 1)

        let ownerA = try await rpc(
            port: port,
            id: "owner-a",
            params: params,
            bearerToken: tokenA
        )
        XCTAssertNil(ownerA["error"])
        XCTAssertEqual(router.snapshotReadCount, 2)

        // Unauthorized requests fail at the HTTP bearer gate (status 401), not
        // via JSON-RPC connection ownership — verify status without assuming body shape.
        for token in [Optional<String>.none, Optional("not-a-token")] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": "auth-gate", "method": "sync.snapshot", "params": params,
            ])
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        }
        XCTAssertEqual(router.snapshotReadCount, 2,
                       "token rejection must not read host state")
        XCTAssertNotEqual(DirectHTTPServer.connectionOwnerFingerprint(token: tokenA), tokenA)
        XCTAssertNotEqual(
            DirectHTTPServer.connectionOwnerFingerprint(token: tokenA),
            DirectHTTPServer.connectionOwnerFingerprint(token: tokenB)
        )
    }

    @MainActor
    func test_syncSnapshot_acceptsLegacyIdentityFieldsAndRejectsSchemaOnly() async throws {
        let router = Phase3SnapshotFakeRouter()
        let port = UInt16.random(in: 33_000...44_000)
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: router),
            serverId: "phase3-host",
            bootEpoch: 73
        )
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        let socket = webSocketTask(port: port)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let welcome = try await receiveObject(socket)
        let connectionID = try XCTUnwrap(welcome["connectionId"] as? String)
        XCTAssertEqual(welcome["capabilities"] as? [String], DirectHTTPServer.welcomeCapabilities())

        let validParams: [String: Any] = [
            "connectionId": connectionID,
            "expectedHostId": "phase3-host",
            "expectedBootEpoch": 73,
            "supportedStateVersion": 3,
        ]
        let valid = try await rpc(port: port, id: "snapshot", params: validParams)
        XCTAssertNil(valid["error"])
        XCTAssertEqual(router.snapshotReadCount, 1,
                       "one sync.snapshot request must perform one synchronous router read")

        // Stale/wrong-typed connection/host/boot are optional ignored legacy — never parsed.
        for allowedLegacy in [
            validParams.merging(["connectionId": "not-active"]) { _, new in new },
            validParams.merging(["expectedHostId": "other-host"]) { _, new in new },
            validParams.merging(["expectedBootEpoch": 74]) { _, new in new },
            // Non-string / non-int legacy values must still be ignored (not type-validated).
            validParams.merging(["connectionId": 12345]) { _, new in new },
            validParams.merging(["expectedHostId": false]) { _, new in new },
            ["supportedStateVersion": 3] as [String: Any],
        ] {
            let response = try await rpc(port: port, id: "legacy-ok", params: allowedLegacy)
            XCTAssertNil(response["error"], "legacy connection/host/boot must not block: \(response)")
        }
        XCTAssertEqual(router.snapshotReadCount, 7)

        for invalid in [
            validParams.merging(["supportedStateVersion": 2]) { _, new in new },
            validParams.merging(["criticalFutureKey": true]) { _, new in new },
        ] {
            let response = try await rpc(port: port, id: "invalid", params: invalid)
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602)
        }
        // Float supportedStateVersion still rejected; float boot is ignored legacy.
        let floatBoot = try await rpc(
            port: port,
            rawBody: Data(#"{"jsonrpc":"2.0","id":"float-boot","method":"sync.snapshot","params":{"connectionId":"\#(connectionID)","expectedHostId":"phase3-host","expectedBootEpoch":73.0,"supportedStateVersion":3}}"#.utf8)
        )
        XCTAssertNil(floatBoot["error"], "float expectedBootEpoch is ignored legacy: \(floatBoot)")
        let floatVersion = try await rpc(
            port: port,
            rawBody: Data(#"{"jsonrpc":"2.0","id":"float-version","method":"sync.snapshot","params":{"connectionId":"\#(connectionID)","expectedHostId":"phase3-host","expectedBootEpoch":73,"supportedStateVersion":3.0}}"#.utf8)
        )
        XCTAssertEqual((floatVersion["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertEqual(router.snapshotReadCount, 8,
                       "only schema rejections must skip host state reads")
    }

    @MainActor
    func test_syncSnapshot_returnsExactV3EnvelopeStateAndStableNormalizedStateHash() async throws {
        let router = Phase3SnapshotFakeRouter()
        let port = UInt16.random(in: 33_000...44_000)
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: router),
            serverId: "phase3-host",
            bootEpoch: 73
        )
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        let socket = webSocketTask(port: port)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let welcome = try await receiveObject(socket)
        let connectionID = try XCTUnwrap(welcome["connectionId"] as? String)
        let params: [String: Any] = [
            "connectionId": connectionID,
            "expectedHostId": "phase3-host",
            "expectedBootEpoch": 73,
            "supportedStateVersion": 3,
        ]

        let first = try await rpc(port: port, id: "one", params: params)
        let second = try await rpc(port: port, id: "two", params: params)
        let firstResult = try XCTUnwrap(first["result"] as? [String: Any])
        let secondResult = try XCTUnwrap(second["result"] as? [String: Any])
        XCTAssertEqual(Set(firstResult.keys), [
            "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
            "sequence", "snapshotId", "generatedAtEpochMs", "stateVersion", "state",
        ])
        XCTAssertEqual(firstResult["type"] as? String, "snapshot")
        XCTAssertEqual(firstResult["stateVersion"] as? Int, 3)
        // HTTP snapshots mint non-empty connectionId for frame decoding only;
        // it is not the live WS id and is not client-echoed identity.
        let responseConnectionId = try XCTUnwrap(firstResult["connectionId"] as? String)
        XCTAssertFalse(responseConnectionId.isEmpty)
        XCTAssertNotEqual(responseConnectionId, connectionID)
        XCTAssertEqual(firstResult["hostId"] as? String, "phase3-host")
        XCTAssertEqual((firstResult["bootEpoch"] as? NSNumber)?.uint64Value, 73)

        let firstState = try XCTUnwrap(firstResult["state"] as? [String: Any])
        let secondState = try XCTUnwrap(secondResult["state"] as? [String: Any])
        XCTAssertEqual(Set(firstState.keys), [
            "selectedWorkspaceId", "workspaces", "surfaces", "agentThreads",
            "browserStates", "filesStates", "domainRevisions",
        ])
        let revisions = try XCTUnwrap(firstState["domainRevisions"] as? [String: Any])
        XCTAssertEqual(Set(revisions.keys), ["shell", "surfaces", "agentThreads", "browser", "files"])
        XCTAssertTrue(revisions.values.allSatisfy {
            (($0 as? NSNumber)?.int64Value ?? -1) >= 0
        })
        XCTAssertEqual(try normalizedStateHash(firstState), try normalizedStateHash(secondState),
                       "envelope timestamps/ids must not perturb the normalized state-only hash")
    }

    func test_snapshotFrame_rejectsBadRevisionsDuplicateIDsAndDanglingReferences() throws {
        let valid = validState()
        XCTAssertNoThrow(try snapshotFrame(state: valid).encoded())

        try assertSnapshotRejected(valid) { state in
            state["unknownCritical"] = .bool(true)
        }
        try assertSnapshotRejected(valid) { state in
            guard case .object(var revisions)? = state["domainRevisions"] else { return }
            revisions["browser"] = .number(-1)
            state["domainRevisions"] = .object(revisions)
        }
        try assertSnapshotRejected(valid) { state in
            guard case .array(let workspaces)? = state["workspaces"] else { return }
            state["workspaces"] = .array(workspaces + workspaces)
        }
        try assertSnapshotRejected(valid) { state in
            state["surfaces"] = .array([.object([
                "workspaceId": .string("missing-workspace"),
                "items": .array([]),
            ])])
        }
        try assertSnapshotRejected(valid) { state in
            let duplicate = JSONValue.object([
                "id": .string("surface-1"), "type": .string("browser"),
            ])
            state["surfaces"] = .array([.object([
                "workspaceId": .string("workspace-1"),
                "items": .array([duplicate, duplicate]),
            ])])
        }
        try assertSnapshotRejected(valid) { state in
            state["filesStates"] = state["browserStates"]
        }
        try assertSnapshotRejected(valid) { state in
            state["browserStates"] = .array([])
        }
        try assertSnapshotRejected(valid) { state in
            state["filesStates"] = .array([])
        }
        try assertSnapshotRejected(valid) { state in
            guard case .array(var values)? = state["browserStates"],
                  case .object(var child) = values[0] else { return }
            child["workspaceId"] = .string("workspace-2")
            values[0] = .object(child)
            state["browserStates"] = .array(values)
        }
        try assertSnapshotRejected(valid) { state in
            guard case .array(var groups)? = state["surfaces"],
                  case .object(var group) = groups[0],
                  case .array(var items)? = group["items"],
                  case .object(var browser) = items[0] else { return }
            browser["type"] = .string("terminal")
            items[0] = .object(browser)
            group["items"] = .array(items)
            groups[0] = .object(group)
            state["surfaces"] = .array(groups)
        }
    }

    func test_snapshotFrame_requiresAgentThreadWorkspaceToMatchItsGroup() throws {
        let valid = validState()
        XCTAssertNoThrow(try snapshotFrame(state: valid).encoded(),
                         "a thread whose workspaceId matches its group must be accepted")

        try assertSnapshotRejected(valid) { state in
            guard case .array(var groups)? = state["agentThreads"],
                  case .object(var group) = groups[0],
                  case .array(var items)? = group["items"],
                  case .object(var thread) = items[0] else { return }
            thread.removeValue(forKey: "workspaceId")
            items[0] = .object(thread)
            group["items"] = .array(items)
            groups[0] = .object(group)
            state["agentThreads"] = .array(groups)
        }
        try assertSnapshotRejected(valid) { state in
            guard case .array(var groups)? = state["agentThreads"],
                  case .object(var group) = groups[0],
                  case .array(var items)? = group["items"],
                  case .object(var thread) = items[0] else { return }
            thread["workspaceId"] = .string("workspace-2")
            items[0] = .object(thread)
            group["items"] = .array(items)
            groups[0] = .object(group)
            state["agentThreads"] = .array(groups)
        }
    }

    func test_eventBusSnapshotBarrier_assignsConcurrentEventImmediatelyAfterWatermark() {
        let bus = EventBus()
        bus.publish(kind: "workspace.created", payload: .object([:]))
        let stateRead = DispatchSemaphore(value: 0)
        let releaseRead = DispatchSemaphore(value: 0)
        let snapshotDone = expectation(description: "snapshot done")
        let publishDone = DispatchSemaphore(value: 0)
        let captured = LockedSnapshotMetadata()

        DispatchQueue.global().async {
            let result = bus.withSnapshotBarrier {
                stateRead.signal()
                _ = releaseRead.wait(timeout: .now() + 2)
                return JSONValue.object([:])
            }
            captured.set(result.metadata)
            snapshotDone.fulfill()
        }
        XCTAssertEqual(stateRead.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            bus.publish(kind: "surface.created", payload: .object([:]))
            publishDone.signal()
        }
        XCTAssertEqual(publishDone.wait(timeout: .now() + 0.05), .timedOut,
                       "publish must remain behind the active snapshot barrier")
        releaseRead.signal()
        wait(for: [snapshotDone], timeout: 2)
        XCTAssertEqual(publishDone.wait(timeout: .now() + 2), .success)

        let metadata = captured.value
        let event = bus.snapshot().recent.last
        XCTAssertEqual(event?.seq, metadata.map { $0.sequence + 1 })
        XCTAssertEqual(metadata?.domainRevisions.shell, 1)
        XCTAssertEqual(bus.snapshotMetadata().oldestReplaySequence, 1)
    }

    func test_connectionWatermark_buffersNPlusOneUntilSnapshotAdoptionThenDrainsAtomically() {
        let watermark = ConnectionSequenceWatermark(initialSequence: 8)

        XCTAssertEqual(
            watermark.recordEnqueuedEvent(sequence: 10),
            .gap(expected: 9, received: 10)
        )
        XCTAssertEqual(watermark.value, 8, "a missing sequence must remain visible")

        XCTAssertTrue(watermark.beginSnapshot())
        XCTAssertEqual(watermark.recordEnqueuedEvent(sequence: 11), .bufferedForSnapshot,
                       "N+1 can reach the outbound queue before HTTP adopts snapshot N")
        XCTAssertEqual(watermark.adoptSnapshot(sequence: 10), .adopted(sequence: 11))
        XCTAssertEqual(watermark.value, 11)
        XCTAssertEqual(
            watermark.recordEnqueuedEvent(sequence: 10),
            .coveredBySnapshot,
            "an event delayed behind HTTP adoption is already represented by snapshot N"
        )
    }

    func test_connectionWatermark_failsLoudWhenSnapshotCannotClosePendingGap() {
        let watermark = ConnectionSequenceWatermark(initialSequence: 8)
        XCTAssertTrue(watermark.beginSnapshot())
        XCTAssertEqual(watermark.recordEnqueuedEvent(sequence: 12), .bufferedForSnapshot)

        XCTAssertEqual(
            watermark.adoptSnapshot(sequence: 10),
            .gap(expected: 11, received: 12)
        )
        XCTAssertEqual(watermark.value, 8,
                       "a rejected snapshot must not advance the connection watermark")
    }

    func test_connectionWatermark_filteredSequenceAdvancesExpectationWithoutAFrame() {
        let watermark = ConnectionSequenceWatermark(initialSequence: 8)

        watermark.recordFilteredEvent(sequence: 9)
        XCTAssertEqual(watermark.value, 9,
                       "a seq dropped by the connection's filter was never sent and must not be awaited")
        XCTAssertEqual(watermark.recordEnqueuedEvent(sequence: 10), .advanced,
                       "the first delivered event after a filtered hole must not read as a gap")
    }

    func test_connectionWatermark_buffersFilteredSequenceRecordedAheadOfBatchedKeptEvent() {
        // Filtered seqs are recorded synchronously on the EventBus delivery
        // queue while kept events cross the per-connection batcher hop, so a
        // filtered N+2 can be recorded before kept N+1.
        let watermark = ConnectionSequenceWatermark(initialSequence: 8)

        watermark.recordFilteredEvent(sequence: 10)
        XCTAssertEqual(watermark.value, 8,
                       "an out-of-order filtered seq must wait for the kept event ahead of it")
        XCTAssertEqual(watermark.recordEnqueuedEvent(sequence: 9), .advanced)
        XCTAssertEqual(watermark.value, 10,
                       "the buffered filtered seq must drain once the kept event advances the watermark")
        XCTAssertEqual(watermark.recordEnqueuedEvent(sequence: 11), .advanced)
    }

    func test_connectionWatermark_adoptSnapshotRetainsFilteredSeqAheadOfInFlightKeptEvent() {
        // Filtered seqs are recorded synchronously on the EventBus delivery
        // queue, so filtered 11 can land before kept 10 clears the batcher.
        // A hole below a remaining FILTERED-only seq means a kept event still
        // in flight, not a lost frame, and must not reject the snapshot.
        let watermark = ConnectionSequenceWatermark(initialSequence: 8)
        XCTAssertTrue(watermark.beginSnapshot())

        watermark.recordFilteredEvent(sequence: 11)
        XCTAssertEqual(watermark.adoptSnapshot(sequence: 9), .adopted(sequence: 9),
                       "a filtered seq above an in-flight kept event must not read as a gap at adoption")

        XCTAssertEqual(watermark.recordEnqueuedEvent(sequence: 10), .advanced,
                       "the in-flight kept event lands after adoption and stays contiguous")
        XCTAssertEqual(watermark.value, 11,
                       "the retained filtered seq must drain once the kept event advances the watermark")
        XCTAssertEqual(watermark.recordEnqueuedEvent(sequence: 12), .advanced)
    }

    func test_connectionWatermark_adoptSnapshotStillFailsLoudWhenKeptSeqProvesGap() {
        // Kept events cross one serial batcher in seq order, so a hole below a
        // remaining KEPT seq proves a lost frame; a co-pending filtered seq
        // further ahead must not mask it.
        let watermark = ConnectionSequenceWatermark(initialSequence: 8)
        XCTAssertTrue(watermark.beginSnapshot())

        XCTAssertEqual(watermark.recordEnqueuedEvent(sequence: 12), .bufferedForSnapshot)
        watermark.recordFilteredEvent(sequence: 14)

        XCTAssertEqual(
            watermark.adoptSnapshot(sequence: 10),
            .gap(expected: 11, received: 12)
        )
        XCTAssertEqual(watermark.value, 8,
                       "a rejected snapshot must not advance the connection watermark")
    }

    func test_connectionWatermark_filteredSeqSurvivesBeginSnapshotIntoTheAdoptionWalk() {
        // The filter hole is a fact about the live stream, not the snapshot
        // lifecycle: filtered 10 recorded before sync.snapshot begins must
        // still count toward adoption, or the walk stops below it and the
        // next kept event re-reports the filter hole as a gap.
        let watermark = ConnectionSequenceWatermark(initialSequence: 8)

        watermark.recordFilteredEvent(sequence: 10)
        XCTAssertTrue(watermark.beginSnapshot())
        XCTAssertEqual(watermark.adoptSnapshot(sequence: 9), .adopted(sequence: 10),
                       "the adoption walk must consume a filtered seq recorded before beginSnapshot")

        XCTAssertEqual(watermark.recordEnqueuedEvent(sequence: 9), .coveredBySnapshot,
                       "the kept event delayed behind adoption is already represented by the snapshot")
        XCTAssertEqual(watermark.recordEnqueuedEvent(sequence: 11), .advanced)
    }

    func test_connectionWatermark_filteredSeqSurvivesCancelSnapshot() {
        // An aborted snapshot drops kept seqs buffered for it (the hole below
        // them stays unproven), but filtered seqs were never sent at all and
        // must survive, or the kept event still in flight drains short and the
        // one after it reads as a spurious gap.
        let watermark = ConnectionSequenceWatermark(initialSequence: 8)

        watermark.recordFilteredEvent(sequence: 10)
        XCTAssertTrue(watermark.beginSnapshot())
        watermark.cancelSnapshot()

        XCTAssertEqual(watermark.recordEnqueuedEvent(sequence: 9), .advanced)
        XCTAssertEqual(watermark.value, 10,
                       "the filtered seq must still drain after the snapshot was cancelled")
        XCTAssertEqual(watermark.recordEnqueuedEvent(sequence: 11), .advanced)
    }

    func test_connectionWatermark_expiredReplayReanchorAdvancesButNeverRollsBack() {
        let watermark = ConnectionSequenceWatermark(initialSequence: 0)

        watermark.reanchorForExpiredReplay(sequence: 514)
        XCTAssertEqual(watermark.value, 514,
                       "replay expiry re-anchors delivery to the live head; the gap expectation must follow")
        XCTAssertEqual(watermark.recordEnqueuedEvent(sequence: 515), .advanced,
                       "the first live event after baselineRequired must not read as a gap")

        watermark.reanchorForExpiredReplay(sequence: 100)
        XCTAssertEqual(watermark.value, 515,
                       "re-anchoring must never roll the watermark back behind recorded events")
    }

    func test_domainRevision_classifiesEverySnapshotDomainAndMultiDomainIntent() {
        let cases: [(kind: String, expected: ConnectionDomainRevisions)] = [
            ("workspace.updated", .init(shell: 1, surfaces: 0, agentThreads: 0, browser: 0, files: 0)),
            ("surface.updated", .init(shell: 0, surfaces: 1, agentThreads: 0, browser: 0, files: 0)),
            ("agent.thread.updated", .init(shell: 0, surfaces: 0, agentThreads: 1, browser: 0, files: 0)),
            ("browser.updated", .init(shell: 0, surfaces: 0, agentThreads: 0, browser: 1, files: 0)),
            ("files.updated", .init(shell: 0, surfaces: 0, agentThreads: 0, browser: 0, files: 1)),
            ("surface.browser", .init(shell: 0, surfaces: 1, agentThreads: 0, browser: 1, files: 0)),
            ("diagnostic.updated", .init(shell: 0, surfaces: 0, agentThreads: 0, browser: 0, files: 0)),
        ]

        for testCase in cases {
            let bus = EventBus()
            bus.publish(kind: testCase.kind, payload: .object([:]))
            XCTAssertEqual(bus.snapshotMetadata().domainRevisions, testCase.expected,
                           "unexpected domain revision intent for \(testCase.kind)")
        }
    }

    func test_domainRevision_neverMovesBackwardDuringPersistenceReload() {
        let cases: [(kind: String, expected: ConnectionDomainRevisions)] = [
            ("workspace.updated", .init(shell: 10, surfaces: 0, agentThreads: 0, browser: 0, files: 0)),
            ("surface.updated", .init(shell: 0, surfaces: 10, agentThreads: 0, browser: 0, files: 0)),
            ("agent.thread.updated", .init(shell: 0, surfaces: 0, agentThreads: 10, browser: 0, files: 0)),
            ("browser.updated", .init(shell: 0, surfaces: 0, agentThreads: 0, browser: 10, files: 0)),
            ("files.updated", .init(shell: 0, surfaces: 0, agentThreads: 0, browser: 0, files: 10)),
            ("surface.browser", .init(shell: 0, surfaces: 10, agentThreads: 0, browser: 10, files: 0)),
        ]

        for testCase in cases {
            let bus = EventBus()
            bus.reloadFromPersistence(lastSeq: 10, recent: [
                EventBus.Event(seq: 10, kind: testCase.kind, payload: .object([:]), ts: 0),
            ])
            bus.reloadFromPersistence(lastSeq: 10, recent: [
                EventBus.Event(seq: 5, kind: testCase.kind, payload: .object([:]), ts: 0),
            ])

            XCTAssertEqual(bus.snapshotMetadata().domainRevisions, testCase.expected,
                           "persistence reload moved \(testCase.kind) backward")
        }
    }

    func test_expiredReplay_emitsBaselineBeforeFutureLiveEvent() {
        let bus = EventBus(recentLimit: 2)
        bus.publish(kind: "workspace.created", payload: .object([:]))
        bus.publish(kind: "workspace.updated", payload: .object([:]))
        bus.publish(kind: "workspace.updated", payload: .object([:]))
        let observed = LockedPhase3Strings()

        let subscription = bus.subscribeDetectingReplayExpiry(
            since: 0,
            onReplayExpired: { metadata in
                observed.append("baseline:\(metadata.sequence)")
            },
            { event in observed.append("event:\(event.seq)") }
        )
        defer { bus.unsubscribe(subscription) }
        bus.publish(kind: "workspace.updated", payload: .object([:]))

        XCTAssertEqual(observed.value, ["baseline:3", "event:4"])
    }

    func test_filteredInternalReplayGapRequiresBaselineInsteadOfSkippingSequence() {
        let bus = EventBus(recentLimit: 8)
        bus.shouldRetainRecentEvent = { $0.kind != "internal.filtered" }
        bus.publish(kind: "workspace.created", payload: .object([:]))
        bus.publish(kind: "internal.filtered", payload: .object([:]))
        bus.publish(kind: "workspace.updated", payload: .object([:]))

        let replay = bus.recentEvents(since: 1, maxBytes: nil)
        XCTAssertEqual(replay.lastSeq, 3)
        XCTAssertEqual(replay.events.map(\.seq), [3])
        XCTAssertTrue(replay.requiresBaseline,
                      "retained events after an internal gap cannot form a complete replay")
        XCTAssertEqual(bus.snapshotMetadata().oldestReplaySequence, 3)

        let observed = LockedPhase3Strings()
        let subscription = bus.subscribeDetectingReplayExpiry(
            since: 1,
            onReplayExpired: { metadata in observed.append("baseline:\(metadata.sequence)") },
            { event in observed.append("event:\(event.seq)") }
        )
        defer { bus.unsubscribe(subscription) }
        bus.publish(kind: "workspace.updated", payload: .object([:]))

        XCTAssertEqual(observed.value, ["baseline:3", "event:4"])
    }

    func test_persistedTailGapRequiresBaselineUntilClientReachesHonestWatermark() {
        let bus = EventBus(recentLimit: 8)
        bus.reloadFromPersistence(lastSeq: 3, recent: [
            EventBus.Event(seq: 1, kind: "workspace.created", payload: .object([:]), ts: 0),
            EventBus.Event(seq: 2, kind: "workspace.updated", payload: .object([:]), ts: 0),
        ])

        let missingTail = bus.recentEvents(since: 2, maxBytes: nil)
        XCTAssertTrue(missingTail.events.isEmpty)
        XCTAssertTrue(missingTail.requiresBaseline,
                      "a missing retained tail event cannot be treated as replayable")
        XCTAssertEqual(bus.snapshotMetadata().oldestReplaySequence, 3)

        let atWatermark = bus.recentEvents(since: 3, maxBytes: nil)
        XCTAssertFalse(atWatermark.requiresBaseline)
        XCTAssertTrue(atWatermark.events.isEmpty)
    }

    private func validState() -> JSONValue {
        .object([
            "selectedWorkspaceId": .string("workspace-1"),
            "workspaces": .array([
                .object(["id": .string("workspace-1")]),
                .object(["id": .string("workspace-2")]),
            ]),
            "surfaces": .array([.object([
                "workspaceId": .string("workspace-1"),
                "items": .array([
                    .object(["id": .string("surface-1"), "type": .string("browser")]),
                    .object(["id": .string("surface-2"), "type": .string("files")]),
                ]),
            ])]),
            "agentThreads": .array([.object([
                "workspaceId": .string("workspace-1"),
                "items": .array([.object([
                    "id": .string("thread-1"),
                    "workspaceId": .string("workspace-1"),
                ])]),
            ])]),
            "browserStates": .array([.object([
                "workspaceId": .string("workspace-1"),
                "surfaceId": .string("surface-1"),
                "state": .object([:]),
            ])]),
            "filesStates": .array([.object([
                "workspaceId": .string("workspace-1"),
                "surfaceId": .string("surface-2"),
                "state": .object([:]),
            ])]),
            "domainRevisions": .object([
                "shell": .number(1), "surfaces": .number(1),
                "agentThreads": .number(1), "browser": .number(1), "files": .number(1),
            ]),
        ])
    }

    private func snapshotFrame(state: JSONValue) -> ConnectionTransportFrame {
        .snapshot(ConnectionSnapshotFrame(
            protocolVersion: 3,
            type: "snapshot",
            connectionId: "connection",
            hostId: "host",
            bootEpoch: 1,
            sequence: 1,
            snapshotId: "snapshot-1",
            generatedAtEpochMs: 1,
            stateVersion: 3,
            state: state
        ))
    }

    private func assertSnapshotRejected(
        _ valid: JSONValue,
        mutate: (inout [String: JSONValue]) -> Void
    ) throws {
        guard case .object(var state) = valid else { return XCTFail("fixture must be object") }
        mutate(&state)
        XCTAssertThrowsError(try snapshotFrame(state: .object(state)).encoded())
    }

    @MainActor
    private func receiveObject(_ task: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await task.receive()
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: data = Data()
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor
    private func webSocketTask(port: UInt16) -> URLSessionWebSocketTask {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        request.setValue(
            "\(EventBus.shared.currentSeq)",
            forHTTPHeaderField: "x-rc2-since-seq"
        )
        return URLSession.shared.webSocketTask(with: request)
    }

    @MainActor
    private func rpc(
        port: UInt16,
        id: String,
        params: [String: Any],
        bearerToken: String? = nil
    ) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": "sync.snapshot", "params": params,
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor
    private func rpc(port: UInt16, rawBody: Data) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = rawBody
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func normalizedStateHash(_ state: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class LockedSnapshotMetadata: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: EventBus.SnapshotMetadata?

    func set(_ value: EventBus.SnapshotMetadata) {
        lock.lock(); storage = value; lock.unlock()
    }

    var value: EventBus.SnapshotMetadata? {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

private final class LockedPhase3Strings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock(); storage.append(value); lock.unlock()
    }

    var value: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
