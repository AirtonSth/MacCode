import XCTest

final class WatchBackgroundRefreshPolicyTests: XCTestCase {
  func testRunningRefreshes5Minutes() {
    XCTAssertEqual(backgroundRefreshInterval(for: .running), 5 * 60)
  }

  func testBackgroundRefreshes5Minutes() {
    XCTAssertEqual(backgroundRefreshInterval(for: .background), 5 * 60)
  }

  func testFinalizingRefreshes2Minutes() {
    XCTAssertEqual(backgroundRefreshInterval(for: .finalizing), 2 * 60)
  }

  func testCompletedNoRefresh() {
    XCTAssertNil(backgroundRefreshInterval(for: .completed))
  }

  func testFailedNoRefresh() {
    XCTAssertNil(backgroundRefreshInterval(for: .failed))
  }

  func testErrorNoRefresh() {
    XCTAssertNil(backgroundRefreshInterval(for: .error))
  }

  func testNilPhaseRefreshes15Minutes() {
    XCTAssertEqual(backgroundRefreshInterval(for: nil), 15 * 60)
  }
}
