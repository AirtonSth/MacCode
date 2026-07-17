import XCTest

@testable import Surfaces

final class TerminalPTYReadFairnessContractTests: XCTestCase {
  func test_readerYieldsWhenPerEventByteBudgetIsReached() {
    let maxBytes = 256 * 1024

    XCTAssertFalse(
      TerminalSurface.shouldYieldPTYReadEvent(
        bytesRead: maxBytes - 1,
        readCalls: 8,
        maxBytes: maxBytes,
        maxReadCalls: 64
      ),
      "a normal PTY burst below both limits may stay in the current dispatch-source event"
    )
    XCTAssertTrue(
      TerminalSurface.shouldYieldPTYReadEvent(
        bytesRead: maxBytes,
        readCalls: 8,
        maxBytes: maxBytes,
        maxReadCalls: 64
      ),
      "a continuous producer must yield at the byte budget so one PTY cannot monopolize its reader queue or build an unbounded main-thread handoff"
    )
  }

  func test_readerYieldsAtReadCallBudgetEvenForTinyChunks() {
    XCTAssertTrue(
      TerminalSurface.shouldYieldPTYReadEvent(
        bytesRead: 64,
        readCalls: 64,
        maxBytes: 256 * 1024,
        maxReadCalls: 64
      ),
      "many tiny reads must still yield; byte-only limits do not guarantee fairness when a writer continuously refills the PTY"
    )
  }
}
