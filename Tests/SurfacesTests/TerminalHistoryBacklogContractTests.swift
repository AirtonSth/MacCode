import XCTest

@testable import Surfaces

final class TerminalHistoryBacklogContractTests: XCTestCase {
  func test_historyWriterAcceptsBytesOnlyWithinItsOutstandingBudget() {
    let maxQueuedBytes = 4 * 1024 * 1024

    XCTAssertTrue(
      TerminalSurface.shouldAcceptHistoryBacklog(
        queuedBytes: maxQueuedBytes - 64,
        incomingBytes: 64,
        maxQueuedBytes: maxQueuedBytes
      ),
      "history output exactly at the outstanding-byte cap may remain queued without data loss"
    )
    XCTAssertFalse(
      TerminalSurface.shouldAcceptHistoryBacklog(
        queuedBytes: maxQueuedBytes - 64,
        incomingBytes: 65,
        maxQueuedBytes: maxQueuedBytes
      ),
      "a slow or blocked database must not retain unlimited 64 KiB work items; crossing the cap must trigger the explicit backpressure/spool failure path"
    )
  }

  func test_historyBudgetArithmeticCannotOverflowIntoAnAcceptedBacklog() {
    XCTAssertFalse(
      TerminalSurface.shouldAcceptHistoryBacklog(
        queuedBytes: Int.max,
        incomingBytes: 1,
        maxQueuedBytes: 4 * 1024 * 1024
      ),
      "saturated queue accounting must reject additional history safely instead of overflowing and appearing below the memory limit"
    )
  }
}
