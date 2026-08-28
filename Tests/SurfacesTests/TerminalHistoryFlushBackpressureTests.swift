import XCTest
@testable import Persistence
@testable import Surfaces

/// WHY: the freeze-class disk diag was TerminalHistoryCoordinator.flushReadyPending
/// enqueueing unbounded SQLite WAL frames (8.6 GB dirty file-backed writes).
/// Backpressure must also keep ingestReadyData from trapping when a full 64 KiB
/// chunk is waiting and more PTY bytes arrive.
@MainActor
final class TerminalHistoryFlushBackpressureTests: XCTestCase {
    private enum TestTimeout: Error { case expired }

    private let chunkBytes = 64 * 1024

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

    func test_enqueueOverTwoChunksWhilePersistBlocked_doesNotTrapAndPersistsAllBytes() throws {
        // WHY: beginFlushIfPermitted can refuse a full pending chunk. ingestReadyData
        // used to precondition(available > 0) and crash on the next 64 KiB. A PTY
        // burst >128 KiB while persist is in-flight must stay in deferredReadyData
        // and drain after the writer finishes.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RC2HistoryBackpressure-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLiteDB(path: directory.appendingPathComponent("history.sqlite").path)
        try Schema.migrate(database)
        let repository = TerminalOutputRepository(db: database)
        let surfaceID = UUID().uuidString
        let workspaceID = UUID().uuidString
        let coordinator = TerminalHistoryCoordinator(
            repository: repository,
            surfaceID: surfaceID,
            workspaceID: workspaceID
        )
        coordinator.prepare(restored: false)
        try waitForPreparation(coordinator)

        let enteredPersist = DispatchSemaphore(value: 0)
        let releasePersist = DispatchSemaphore(value: 0)
        let firstPersistHold = FirstPersistHold()
        coordinator.beforePersistForTesting = {
            guard firstPersistHold.claim() else { return }
            enteredPersist.signal()
            releasePersist.wait()
        }

        coordinator.enqueue(Data(repeating: 0x41, count: chunkBytes))
        XCTAssertEqual(enteredPersist.wait(timeout: .now() + 5), .success,
                       "the first 64 KiB chunk must reach persist so the second enqueue races it")
        XCTAssertEqual(coordinator.pendingReadyBytesForTesting, 0,
                       "the in-flight persist must have taken the first full chunk")

        coordinator.enqueue(Data(repeating: 0x42, count: chunkBytes * 2))
        XCTAssertEqual(coordinator.pendingReadyBytesForTesting, chunkBytes,
                       "the next full chunk waits in pending while persist is held")
        XCTAssertEqual(coordinator.deferredReadyBytesForTesting, chunkBytes,
                       "overflow past the full pending chunk must park, not trap")
        XCTAssertEqual(coordinator.outstandingBytes, chunkBytes * 3)

        releasePersist.signal()
        try waitForDrain(coordinator)
        XCTAssertEqual(coordinator.deferredReadyBytesForTesting, 0)
        XCTAssertEqual(coordinator.pendingReadyBytesForTesting, 0)
        XCTAssertEqual(
            try repository.totalBytes(surfaceID: surfaceID),
            chunkBytes * 3,
            "all three 64 KiB slices must become durable after the writer unblocks"
        )
    }

    private func waitForPreparation(
        _ coordinator: TerminalHistoryCoordinator,
        timeout: TimeInterval = 5
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .ready = coordinator.preparationStateForTesting { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        XCTFail("terminal history preparation timed out")
        throw TestTimeout.expired
    }

    private func waitForDrain(
        _ coordinator: TerminalHistoryCoordinator,
        timeout: TimeInterval = 5
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while coordinator.outstandingBytes > 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        guard coordinator.outstandingBytes == 0 else {
            XCTFail("terminal history writer did not drain outstandingBytes=\(coordinator.outstandingBytes)")
            throw TestTimeout.expired
        }
    }
}

private final class FirstPersistHold: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
