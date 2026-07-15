import CryptoKit
import XCTest
@testable import SocketServer

@MainActor
private final class Phase3SnapshotFakeRouter: FakeRouter, ConnectionSnapshotRouting {
    let workspaceID = UUID().uuidString
    let surfaceID = UUID().uuidString
    let threadID = UUID().uuidString
    private(set) var snapshotReadCount = 0

    func readConnectionSnapshotState() throws -> ConnectionSnapshotReadState {
        snapshotReadCount += 1
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
    func test_syncSnapshot_requiresSameAuthenticatedOwnerAsWebSocket() async throws {
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

        let wrongOwner = try await rpc(
            port: port,
            id: "wrong-owner",
            params: params,
            bearerToken: tokenB
        )
        XCTAssertEqual((wrongOwner["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertEqual(router.snapshotReadCount, 0)

        let correctOwner = try await rpc(
            port: port,
            id: "correct-owner",
            params: params,
            bearerToken: tokenA
        )
        XCTAssertNil(correctOwner["error"])
        XCTAssertEqual(router.snapshotReadCount, 1)
        XCTAssertNotEqual(DirectHTTPServer.connectionOwnerFingerprint(token: tokenA), tokenA)
        XCTAssertNotEqual(
            DirectHTTPServer.connectionOwnerFingerprint(token: tokenA),
            DirectHTTPServer.connectionOwnerFingerprint(token: tokenB)
        )
    }

    @MainActor
    func test_syncSnapshot_requiresActiveExactConnectionIdentityAndExactRequestKeys() async throws {
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
        XCTAssertEqual(welcome["capabilities"] as? [String], [
            "events.replay", "jsonrpc.batch", "snapshot.v3",
        ])

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

        for invalid in [
            validParams.merging(["connectionId": "not-active"]) { _, new in new },
            validParams.merging(["expectedHostId": "other-host"]) { _, new in new },
            validParams.merging(["expectedBootEpoch": 74]) { _, new in new },
            validParams.merging(["supportedStateVersion": 2]) { _, new in new },
            validParams.merging(["criticalFutureKey": true]) { _, new in new },
        ] {
            let response = try await rpc(port: port, id: "invalid", params: invalid)
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602)
        }
        for rawBody in [
            #"{"jsonrpc":"2.0","id":"float-boot","method":"sync.snapshot","params":{"connectionId":"\#(connectionID)","expectedHostId":"phase3-host","expectedBootEpoch":73.0,"supportedStateVersion":3}}"#,
            #"{"jsonrpc":"2.0","id":"float-version","method":"sync.snapshot","params":{"connectionId":"\#(connectionID)","expectedHostId":"phase3-host","expectedBootEpoch":73,"supportedStateVersion":3.0}}"#,
        ] {
            let response = try await rpc(port: port, rawBody: Data(rawBody.utf8))
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602)
        }
        XCTAssertEqual(router.snapshotReadCount, 1,
                       "identity/schema rejection must occur before reading host state")
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
        XCTAssertEqual(firstResult["connectionId"] as? String, connectionID)
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
