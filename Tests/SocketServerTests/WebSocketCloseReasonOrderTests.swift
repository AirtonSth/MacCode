import XCTest
@testable import SocketServer

/// A host-initiated close (heartbeat timeout, event gap) shuts the socket down
/// from the writer queue. The read loop then sees EOF and records
/// `peerEOF/1006`. `terminate` reports its reason only after it has queued the
/// shutdown, so a caller preempted there lost the race and the close log and
/// `/v1/health` blamed the peer for a close the host decided. The record keeps
/// the first reason, so the two call sites must record before they terminate.
final class WebSocketCloseReasonOrderTests: XCTestCase {
    func test_reasonRecordedBeforeTheShutdown_isNotReplacedByTheReadLoopEOF() {
        for (terminal, reason) in [("heartbeatTimeout", "heartbeatTimeout"), ("event_gap", "eventGap")] {
            let record = WebSocketCloseRecord(sinceSequence: 0)

            record.recordTerminal(terminal)
            record.recordClose(reason: "peerEOF", code: 1006)
            // terminate's own callback, late on the preempted thread.
            record.recordTerminal(terminal)

            let summary = record.summary()
            XCTAssertEqual(summary.reason, reason)
            XCTAssertEqual(summary.code, 1012, "\(terminal): the code the host put in its closing frame")
        }
    }

    /// The race itself needs a preemption of the terminating thread between
    /// two statements inside the `/v1/ws` handler, which no seam exposes; the
    /// order at the two call sites is pinned on the source instead.
    func test_heartbeatTimeoutAndEventGap_recordTheirReasonBeforeTerminating() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/SocketServer/HTTPServer.swift"),
            encoding: .utf8
        )

        for terminal in ["heartbeatTimeout", "event_gap"] {
            let record = try XCTUnwrap(
                source.range(of: "closeRecord.recordTerminal(\"\(terminal)\")"),
                "\(terminal): the reason must be recorded by the caller"
            )
            let terminate = try XCTUnwrap(
                source.range(of: "outbound.terminate(", range: record.upperBound..<source.endIndex)
            )
            XCTAssertEqual(
                source[record.upperBound..<terminate.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                "_ =",
                "\(terminal): nothing may run between recording the reason and terminating"
            )
            let call = source[terminate.upperBound...].prefix(1_200)
            XCTAssertTrue(
                call.contains("reason: \"\(terminal)\"\n"),
                "\(terminal): the recorded reason must be the one this terminate reports"
            )
        }
    }
}
