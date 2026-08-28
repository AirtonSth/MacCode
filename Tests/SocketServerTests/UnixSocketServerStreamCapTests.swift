import XCTest
@testable import SocketServer

/// Byte ceiling for Unix-domain agent/local IPC stream queues.
///
/// WHY: maxStreamQueuedBytes bounds per-connection outbound EventBus stream
/// backlog. Was 1 MiB and could pin multi-MB buffers per connected local client
/// during agent tool storms. 512 KiB matches LineBuffer / provider pipe ceilings.
final class UnixSocketServerStreamCapTests: XCTestCase {

    func test_maxStreamQueuedBytes_is512KiB() {
        XCTAssertEqual(UnixSocketServer.maxStreamQueuedBytes, 512 * 1024)
    }

    func test_maxClientLineBytes_stays1MiB_forLegacyFullBodyRPCs() {
        // WHY: plan-notes and other host-catalog RPCs still use full-body lines
        // up to 1 MiB; a shared 512 KiB ceiling would EOF those clients.
        XCTAssertEqual(UnixSocketServer.maxClientLineBytes, 1024 * 1024)
    }

    func test_retentionEstimate_streamQueue_1MiBTo512KiB() {
        let prior = 1024 * 1024
        let streamLimit = UnixSocketServer.maxStreamQueuedBytes
        XCTAssertEqual(streamLimit, 512 * 1024)
        let reduction = Double(prior - streamLimit) / Double(prior)
        XCTAssertEqual(reduction, 0.5, accuracy: 0.001)
        XCTAssertEqual(UnixSocketServer.maxClientLineBytes, 1024 * 1024)
    }
}
