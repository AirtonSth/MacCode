import XCTest
@testable import SocketServer

/// Wave 4 pure helpers: incremental domain selection and C-25 thread policy.
final class Wave4ConnectionArchitectureTests: XCTestCase {

    func test_domainRevisions_domainsChanged_sinceKnown() {
        // WHY: reconnect must download only domains whose host watermark advanced.
        let known = ConnectionDomainRevisions(
            shell: 10, surfaces: 20, agentThreads: 30, browser: 5, files: 1
        )
        let host = ConnectionDomainRevisions(
            shell: 10, surfaces: 25, agentThreads: 30, browser: 5, files: 8
        )
        XCTAssertEqual(
            host.domainsChanged(since: known),
            Set(["surfaces", "files"])
        )
        XCTAssertTrue(
            host.domainsChanged(since: host).isEmpty,
            "identical watermarks must request empty/no-op delta"
        )
    }

    func test_snapshotReadState_partialOmitsUnchangedDomains() throws {
        let state = ConnectionSnapshotReadState(
            selectedWorkspaceId: "w1",
            workspaces: [.object(["id": .string("w1")])],
            surfaces: [
                ConnectionSnapshotWorkspaceItems(
                    workspaceId: "w1",
                    items: [.object(["id": .string("s1"), "type": .string("terminal")])]
                )
            ],
            agentThreads: [
                ConnectionSnapshotWorkspaceItems(workspaceId: "w1", items: [])
            ],
            browserStates: [],
            filesStates: []
        )
        let revisions = ConnectionDomainRevisions(
            shell: 1, surfaces: 2, agentThreads: 3, browser: 0, files: 0
        )
        let json = state.jsonValue(
            domainRevisions: revisions,
            includeDomains: ["surfaces"]
        )
        guard case .object(let object) = json else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(object["partial"], .bool(true))
        XCTAssertNil(object["workspaces"], "shell domain omitted")
        XCTAssertNil(object["agentThreads"], "agent domain omitted")
        XCTAssertNotNil(object["surfaces"])
        XCTAssertNotNil(object["domainRevisions"])
        let frame = ConnectionTransportFrame.snapshot(ConnectionSnapshotFrame(
            protocolVersion: ConnectionTransportFrame.protocolVersion,
            type: "snapshot",
            connectionId: "c1",
            hostId: "h1",
            bootEpoch: 1,
            sequence: 2,
            snapshotId: "snap",
            generatedAtEpochMs: 0,
            stateVersion: 3,
            state: json
        ))
        XCTAssertGreaterThan(try frame.encoded().count, 0)
    }

    func test_welcomeDoesNotAdvertiseRPCOverEventWebSocket() {
        // WHY: HTTP must remain the single request/response transport. If this
        // capability returns, clients may silently couple mutations to WS state.
        XCTAssertFalse(
            DirectHTTPServer.welcomeCapabilities().contains("rpc.websocket")
        )
    }

    func test_interestControl_parseAndApplyUpdatesCellularSafeOnly() throws {
        // WHY: mid-session interest must rebind host admission without reconnect;
        // full filters fail open; non-control payloads return nil (no protocol error).
        let control = try JSONSerialization.data(withJSONObject: [
            "type": "rc2.interest",
            "thread_ids": ["t-live", ""],
        ])
        XCTAssertEqual(EventStreamFilter.parseInterestControl(control), Set(["t-live"]))
        XCTAssertNil(EventStreamFilter.parseInterestControl(Data(#"{"type":"welcome"}"#.utf8)))

        let cellular = EventStreamFilter.cellularSafe(interestThreadIds: ["old"])
        let updated = cellular.applyingInterestThreadIds(["new"])
        if case .cellularSafe(let ids) = updated {
            XCTAssertEqual(ids, Set(["new"]))
        } else {
            XCTFail("expected cellularSafe")
        }
        XCTAssertEqual(EventStreamFilter.full.applyingInterestThreadIds(["x"]), .full)
    }

    func test_eventBus_updateSubscriberFilter_changesAdmissionMidSession() {
        // WHY: after rc2.interest, high-volume deltas for other threads must drop
        // without tearing down the WebSocket subscriber.
        let bus = EventBus(recentLimit: 32, recentByteLimit: 1_000_000)
        var admitted: [String] = []
        let id = bus.subscribe(since: nil, filter: .cellularSafe(interestThreadIds: ["t1"])) { event in
            admitted.append(event.kind)
        }
        bus.publish(kind: "agent.item.delta", payload: .object([
            "thread_id": .string("t1"),
            "item_id": .string("i1"),
            "text": .string("a"),
        ]))
        bus.publish(kind: "agent.item.delta", payload: .object([
            "thread_id": .string("t2"),
            "item_id": .string("i2"),
            "text": .string("b"),
        ]))
        XCTAssertEqual(admitted.filter { $0 == "agent.item.delta" }.count, 1,
                       "t2 deltas must be dropped under t1 interest")

        bus.updateSubscriberFilter(id, filter: .cellularSafe(interestThreadIds: ["t2"]))
        admitted.removeAll()
        bus.publish(kind: "agent.item.delta", payload: .object([
            "thread_id": .string("t2"),
            "item_id": .string("i3"),
            "text": .string("c"),
        ]))
        bus.publish(kind: "agent.item.delta", payload: .object([
            "thread_id": .string("t1"),
            "item_id": .string("i4"),
            "text": .string("d"),
        ]))
        XCTAssertEqual(admitted.filter { $0 == "agent.item.delta" }.count, 1,
                       "after mid-session interest, only t2 high-volume admits")
        bus.unsubscribe(id)
    }
}
