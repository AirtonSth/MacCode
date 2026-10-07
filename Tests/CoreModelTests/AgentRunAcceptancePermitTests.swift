import XCTest
import os
@testable import CoreModel

final class AgentRunAcceptancePermitTests: XCTestCase {
    func test_invalidationDoesNotBlockMainActorBehindClaimedNonReadingPipeWrite() async {
        let pipe = Pipe()
        let permit = AgentRunAcceptancePermit()
        var enteredContinuation: AsyncStream<Void>.Continuation!
        let entered = AsyncStream<Void> { enteredContinuation = $0 }
        let writer = Task.detached {
            do {
                try permit.withAcceptance {
                    enteredContinuation.yield()
                    try pipe.fileHandleForWriting.write(
                        contentsOf: Data(repeating: 0x41, count: 1_048_576)
                    )
                }
                return false
            } catch {
                return true
            }
        }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        let attempt = await MainActor.run {
            permit.invalidate()
        }
        XCTAssertNotNil(attempt, "invalidation must expose completion for the claimed write")
        XCTAssertEqual(
            permit.outcome,
            .unknown,
            "a claimed write linearizes before invalidation without blocking the MainActor"
        )

        let drainer = Task.detached {
            pipe.fileHandleForReading.readDataToEndOfFile()
        }
        let writeFailed = await writer.value
        try? pipe.fileHandleForWriting.close()
        _ = await drainer.value
        await attempt?.wait()
        XCTAssertFalse(writeFailed)
    }

    func test_onInvalidateFiresOnceForAStopBeforeAcceptance_andNeverAfterAClaim() throws {
        // WHY: a guest run's launch preparation stops itself on this signal;
        // it must fire for Stop on a start still preparing (also when Stop
        // came first), and never cancel a run whose prompt was already sent.
        let stopped = AgentRunAcceptancePermit()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        stopped.onInvalidate { calls.withLock { $0 += 1 } }
        XCTAssertEqual(calls.withLock { $0 }, 0)
        stopped.invalidate()
        stopped.invalidate()
        XCTAssertEqual(calls.withLock { $0 }, 1)
        stopped.onInvalidate { calls.withLock { $0 += 1 } }
        XCTAssertEqual(calls.withLock { $0 }, 2, "registering after Stop runs at once")

        let sent = AgentRunAcceptancePermit()
        let sentCalls = OSAllocatedUnfairLock(initialState: 0)
        sent.onInvalidate { sentCalls.withLock { $0 += 1 } }
        try sent.withAcceptance {}
        sent.invalidate()
        sent.onInvalidate { sentCalls.withLock { $0 += 1 } }
        XCTAssertEqual(sentCalls.withLock { $0 }, 0)
    }
}
