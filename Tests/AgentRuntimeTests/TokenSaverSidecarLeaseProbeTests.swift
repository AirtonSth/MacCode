import XCTest
@testable import AgentRuntime

final class TokenSaverSidecarLeaseProbeTests: XCTestCase {
    func test_readLease_acceptsValidStateAndRejectsGarbage() throws {
        // WHY: admission must only treat a real DistillCLIState lease as readiness.
        let valid = """
        {"base_url":"http://127.0.0.1:50206","runtime":"mlx","pid":4242,"auth_token":"tok","model_id":"m"}
        """.data(using: .utf8)!
        let lease = try XCTUnwrap(TokenSaverSidecarLeaseProbe.readLease(from: valid))
        XCTAssertEqual(lease.pid, 4242)
        XCTAssertEqual(lease.baseURL, "http://127.0.0.1:50206")
        XCTAssertEqual(lease.authToken, "tok")

        XCTAssertNil(TokenSaverSidecarLeaseProbe.readLease(from: Data("{".utf8)))
        let noPid = """
        {"base_url":"http://127.0.0.1:1","auth_token":"t","pid":0}
        """.data(using: .utf8)!
        XCTAssertNil(TokenSaverSidecarLeaseProbe.readLease(from: noPid))
    }

    func test_isHealthy_requiresLivePid() {
        // WHY: a stale state file after sidecar exit must fail open (no distill claim).
        let lease = TokenSaverSidecarLeaseProbe.Lease(
            baseURL: "http://127.0.0.1:9",
            authToken: "t",
            pid: 99
        )
        XCTAssertTrue(TokenSaverSidecarLeaseProbe.isHealthy(lease: lease, processIsAlive: { $0 == 99 }))
        XCTAssertFalse(TokenSaverSidecarLeaseProbe.isHealthy(lease: lease, processIsAlive: { _ in false }))
        XCTAssertFalse(TokenSaverSidecarLeaseProbe.isHealthy(lease: nil, processIsAlive: { _ in true }))
    }

    func test_isHealthy_fromStateFileData() {
        let data = """
        {"base_url":"http://127.0.0.1:1","auth_token":"abc","pid":7}
        """.data(using: .utf8)!
        XCTAssertTrue(
            TokenSaverSidecarLeaseProbe.isHealthy(stateFileData: data, processIsAlive: { $0 == 7 })
        )
        XCTAssertFalse(
            TokenSaverSidecarLeaseProbe.isHealthy(stateFileData: data, processIsAlive: { _ in false })
        )
    }
}
