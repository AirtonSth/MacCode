import XCTest
@testable import SocketServer

/// Wave 4 pure helpers: incremental domain selection, JSON-RPC detection, C-25 thread policy.
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

    func test_looksLikeJSONRPCRequest_detectsSingleAndBatch() throws {
        let single = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "1",
            "method": "system.ping",
            "params": [:] as [String: Any],
        ])
        XCTAssertTrue(DirectHTTPServer.looksLikeJSONRPCRequest(single))

        let batch = try JSONSerialization.data(withJSONObject: [[
            "jsonrpc": "2.0",
            "id": "1",
            "method": "system.ping",
            "params": [:] as [String: Any],
        ]])
        XCTAssertTrue(DirectHTTPServer.looksLikeJSONRPCRequest(batch))

        let transport = try JSONSerialization.data(withJSONObject: [
            "protocolVersion": 3,
            "type": "welcome",
            "connectionId": "c",
        ])
        XCTAssertFalse(DirectHTTPServer.looksLikeJSONRPCRequest(transport))
    }
}
