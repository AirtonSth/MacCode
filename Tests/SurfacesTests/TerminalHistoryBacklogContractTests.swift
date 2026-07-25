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
      "without reclaim, crossing the cap is refused; production enqueue first drops oldest bytes"
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

  func test_oldestBytesToEvict_reclaimsOnlyWhatIsNeededForNewest() {
    XCTAssertEqual(
      TerminalHistoryCoordinator.oldestBytesToEvict(
        queuedBytes: 100,
        incomingBytes: 30,
        maxQueuedBytes: 120
      ),
      10,
      "evict only the excess oldest bytes so the newest chunk fits"
    )
    XCTAssertEqual(
      TerminalHistoryCoordinator.oldestBytesToEvict(
        queuedBytes: 50,
        incomingBytes: 20,
        maxQueuedBytes: 120
      ),
      0,
      "under budget: no eviction"
    )
    XCTAssertEqual(
      TerminalHistoryCoordinator.oldestBytesToEvict(
        queuedBytes: 200,
        incomingBytes: 50,
        maxQueuedBytes: 100
      ),
      150,
      "when incoming itself needs room, drop as much oldest as possible (capped at queued)"
    )
  }
}
