import XCTest
@testable import CoreModel

final class ComputerUseHostQueueTests: XCTestCase {
    private func makeQueue() -> ComputerUseHostQueue {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-cu-lock-\(UUID().uuidString).lock")
        return ComputerUseHostQueue(lockURL: url)
    }

    func test_twoOverlappingMutationsNeverInterleave_firstPair() async throws {
        try await assertExclusivePair(label: "pair-1")
    }

    func test_twoOverlappingMutationsNeverInterleave_secondPair() async throws {
        try await assertExclusivePair(label: "pair-2")
    }

    func test_differentTargetPIDsCanProgressConcurrently() async throws {
        let queue = makeQueue()
        let leases = LockBox<[ComputerUseHostQueue.Lease]>([])

        try await withThrowingTaskGroup(of: Void.self) { group in
            for pid in [Int32(101), Int32(202)] {
                group.addTask {
                    let (_, lease) = try await queue.withExclusiveLease(
                        kind: .mutation,
                        targetPID: pid
                    ) {
                        try await Task.sleep(nanoseconds: 40_000_000)
                        return pid
                    }
                    leases.append(lease)
                }
            }
            try await group.waitForAll()
        }

        let recorded = leases.value
        XCTAssertEqual(recorded.count, 2)
        XCTAssertTrue(
            recorded[0].overlaps(recorded[1]),
            "different host PIDs must not share one global FIFO"
        )
    }

    func test_separateQueueInstancesShareTargetPIDFileLock() async throws {
        let lockURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-cu-shared-lock-\(UUID().uuidString).lock")
        let firstQueue = ComputerUseHostQueue(lockURL: lockURL)
        let secondQueue = ComputerUseHostQueue(lockURL: lockURL)
        let firstAcquired = expectation(description: "first queue acquired")
        let leases = LockBox<[ComputerUseHostQueue.Lease]>([])
        let targetPID: Int32 = 303

        let first = Task.detached {
            let (_, lease) = try await firstQueue.withExclusiveLease(
                kind: .mutation,
                targetPID: targetPID
            ) {
                firstAcquired.fulfill()
                try await Task.sleep(nanoseconds: 80_000_000)
            }
            leases.append(lease)
        }

        await fulfillment(of: [firstAcquired], timeout: 1)
        let second = Task.detached {
            let (_, lease) = try await secondQueue.withExclusiveLease(
                kind: .mutation,
                targetPID: targetPID
            ) {
            }
            leases.append(lease)
        }

        _ = try await first.value
        _ = try await second.value
        let recorded = leases.value
        XCTAssertEqual(recorded.count, 2, "each queue must complete one body and record its lease")
        XCTAssertFalse(
            recorded[0].overlaps(recorded[1]),
            "separate queue instances sharing one PID lock must remain exclusive"
        )
    }

    func test_cancelledWaiterNeverEntersCriticalSection() async throws {
        let queue = makeQueue()
        let firstStarted = expectation(description: "first acquired")
        let firstHold = expectation(description: "first still holding")
        firstHold.isInverted = false

        let first = Task {
            try await queue.withExclusive(kind: .mutation) {
                firstStarted.fulfill()
                try await Task.sleep(nanoseconds: 80_000_000)
            }
        }

        await fulfillment(of: [firstStarted], timeout: 1)
        let waiter = Task {
            try await queue.withExclusive(kind: .mutation) {
                XCTFail("cancelled waiter must not enter the critical section")
            }
        }
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("cancelled waiter must throw")
        } catch is CancellationError {
            // expected
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        _ = try await first.value
        firstHold.fulfill()
        await fulfillment(of: [firstHold], timeout: 1)
    }

    private func assertExclusivePair(label: String) async throws {
        let queue = makeQueue()
        let leases = LockBox<[ComputerUseHostQueue.Lease]>([])

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    let (_, lease) = try await queue.withExclusiveLease(kind: .mutation) {
                        try await Task.sleep(nanoseconds: 40_000_000)
                        return label
                    }
                    leases.append(lease)
                }
            }
            try await group.waitForAll()
        }

        let recorded = leases.value
        XCTAssertEqual(recorded.count, 2, "\(label) must record both leases from the shipped queue")
        XCTAssertFalse(
            recorded[0].overlaps(recorded[1]),
            "\(label): overlapping mutating computer-use calls must not share the host lock"
        )
        XCTAssertTrue(
            recorded[0].releasedAtNs <= recorded[1].acquiredAtNs
                || recorded[1].releasedAtNs <= recorded[0].acquiredAtNs,
            "\(label): second critical section starts only after the first ends"
        )
    }
}

private final class LockBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        get {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private extension LockBox where Value == [ComputerUseHostQueue.Lease] {
    func append(_ lease: ComputerUseHostQueue.Lease) {
        lock.lock()
        storage.append(lease)
        lock.unlock()
    }
}
