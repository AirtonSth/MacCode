import XCTest
@testable import Surfaces

/// WHY: the freeze-class disk diag was TerminalHistoryCoordinator.flushReadyPending
/// enqueueing unbounded SQLite WAL frames (8.6 GB dirty file-backed writes).
final class TerminalHistoryFlushBackpressureTests: XCTestCase {
    func test_oneInFlightWriteBlocksAnotherEnqueue() {
        XCTAssertTrue(
            TerminalHistoryFlushBackpressure.shouldEnqueueWrite(inFlightCount: 0),
            "the first persist must run"
        )
        XCTAssertFalse(
            TerminalHistoryFlushBackpressure.shouldEnqueueWrite(inFlightCount: 1),
            "a second SQLite write must wait until the in-flight chunk finishes"
        )
        XCTAssertFalse(
            TerminalHistoryFlushBackpressure.shouldEnqueueWrite(inFlightCount: 8),
            "backpressure must stay closed under a WAL storm"
        )
        XCTAssertEqual(TerminalHistoryFlushBackpressure.maxInFlightSQLiteWrites, 1)
    }

    func test_coordinatorWiresBeginFlushIfPermitted() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/Surfaces/TerminalHistoryCoordinator.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("beginFlushIfPermitted()"))
        XCTAssertTrue(source.contains("endFlush()"))
        XCTAssertTrue(source.contains("maxInFlightSQLiteWrites"))
    }
}
