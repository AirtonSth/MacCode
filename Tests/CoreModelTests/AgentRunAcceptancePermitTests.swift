import XCTest
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
}
