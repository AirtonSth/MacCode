import XCTest
import Darwin
import Foundation
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

    func test_separateQueueInstancesPreserveSameTargetTicketArrivalOrder() async throws {
        // WHY: the OS file lock only provides exclusion; the ticket directory
        // must preserve the order in which independent host queues arrive.
        let lockURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-cu-fifo-lock-\(UUID().uuidString).lock")
        let firstQueue = ComputerUseHostQueue(lockURL: lockURL)
        let secondQueue = ComputerUseHostQueue(lockURL: lockURL)
        let thirdQueue = ComputerUseHostQueue(lockURL: lockURL)
        let targetPID: Int32 = 505
        let firstStarted = expectation(description: "first queue acquired")
        let order = LockBox<[String]>([])

        let first = Task.detached {
            try await firstQueue.withExclusive(targetPID: targetPID, kind: .mutation) {
                order.append("first")
                firstStarted.fulfill()
                try await Task.sleep(nanoseconds: 80_000_000)
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)
        let second = Task.detached {
            try await secondQueue.withExclusive(targetPID: targetPID, kind: .mutation) {
                order.append("second")
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        let third = Task.detached {
            try await thirdQueue.withExclusive(targetPID: targetPID, kind: .mutation) {
                order.append("third")
            }
        }
        _ = try await first.value
        _ = try await second.value
        _ = try await third.value
        XCTAssertEqual(order.value, ["first", "second", "third"])
    }

    func test_realSubprocessesPreserveSameTargetTicketArrivalOrder() throws {
        // WHY: this compiles only the shipped queue with a tiny temporary
        // helper and proves FIFO across independent OS processes, where an
        // in-process lock or XCTest task scheduler cannot mask the ordering.
        let helper = try compileQueueHelper()
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent()) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-cu-subprocess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("host.lock")
        let orderURL = directory.appendingPathComponent("order.log")

        let first = Process()
        first.executableURL = helper
        first.arguments = [lockURL.path, orderURL.path, "first", "707", "140"]
        try first.run()
        for _ in 0..<200 {
            if (try? String(contentsOf: orderURL, encoding: .utf8)) == "first\n" { break }
            usleep(10_000)
        }
        XCTAssertEqual(try String(contentsOf: orderURL, encoding: .utf8), "first\n")
        let second = Process()
        second.executableURL = helper
        second.arguments = [lockURL.path, orderURL.path, "second", "707", "10"]
        try second.run()
        first.waitUntilExit()
        second.waitUntilExit()
        XCTAssertEqual(first.terminationStatus, 0)
        XCTAssertEqual(second.terminationStatus, 0)
        let lines = try String(contentsOf: orderURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["first", "second"])
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

    func test_cancelledCrossProcessTicketNeverAcquiresAfterPredecessorReleases() async throws {
        // WHY: a process-equivalent queue can be waiting on an earlier ticket
        // without being in the local waiter array. Cancellation must remove
        // that active ticket, not resume the cancelled body later.
        let lockURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-cu-cancel-ticket-\(UUID().uuidString).lock")
        let firstQueue = ComputerUseHostQueue(lockURL: lockURL)
        let secondQueue = ComputerUseHostQueue(lockURL: lockURL)
        let firstStarted = expectation(description: "first ticket acquired")
        let secondBodies = LockBox<Int>(0)
        let first = Task {
            try await firstQueue.withExclusive(targetPID: 606, kind: .mutation) {
                firstStarted.fulfill()
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)
        let second = Task {
            try await secondQueue.withExclusive(targetPID: 606, kind: .mutation) {
                secondBodies.value += 1
            }
        }
        try await Task.sleep(nanoseconds: 25_000_000)
        second.cancel()
        do {
            _ = try await second.value
            XCTFail("cancelled cross-process ticket must throw")
        } catch is CancellationError {
            // expected
        }
        _ = try await first.value
        try await secondQueue.withExclusive(targetPID: 606, kind: .mutation) {
            secondBodies.value += 1
        }
        XCTAssertEqual(secondBodies.value, 1, "only the post-cancellation lease may enter")
    }

    func test_excessiveSameTargetWaitersFailExplicitly() async throws {
        let queue = makeQueue()
        let firstStarted = expectation(description: "first acquired")
        let first = Task {
            try await queue.withExclusive(kind: .mutation) {
                firstStarted.fulfill()
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)

        let waiterCount = ComputerUseHostQueue.maximumWaitersPerTarget + 1
        let waiters = (0..<waiterCount).map { _ in
            Task { () -> ComputerUseHostQueueError? in
                do {
                    try await queue.withExclusive(kind: .mutation) {}
                    return nil
                } catch let error as ComputerUseHostQueueError {
                    return error
                } catch {
                    return nil
                }
            }
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        _ = try await first.value

        var fullCount = 0
        for waiter in waiters {
            if case .queueFull? = await waiter.value {
                fullCount += 1
            }
        }
        XCTAssertEqual(fullCount, 1, "the bounded queue must reject excess waiters explicitly")
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

    private func compileQueueHelper() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-cu-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helperSource = directory.appendingPathComponent("QueueHelper.swift")
        let helperBinary = directory.appendingPathComponent("queue-helper")
        let queueSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CoreModel/ComputerUseHostQueue.swift")
        let source = #"""
import Darwin
import Foundation

@main
struct QueueHelper {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 6 else { exit(3) }
        let queue = ComputerUseHostQueue(lockURL: URL(fileURLWithPath: args[1]))
        do {
            try await queue.withExclusive(targetPID: Int32(args[4])!, kind: .mutation) {
                let fd = open(args[2], O_CREAT | O_WRONLY | O_APPEND, S_IRUSR | S_IWUSR)
                guard fd >= 0 else { throw POSIXError(.EIO) }
                let data = Data((args[3] + "\n").utf8)
                data.withUnsafeBytes { bytes in _ = write(fd, bytes.baseAddress, bytes.count) }
                close(fd)
                try await Task.sleep(nanoseconds: UInt64(args[5])! * 1_000_000)
            }
        } catch {
            exit(2)
        }
    }
}
"""#
        try source.write(to: helperSource, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        compiler.arguments = [queueSource.path, helperSource.path, "-o", helperBinary.path]
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else {
            throw NSError(domain: "ComputerUseHostQueueTests", code: Int(compiler.terminationStatus))
        }
        return helperBinary
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

private extension LockBox where Value == [String] {
    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
