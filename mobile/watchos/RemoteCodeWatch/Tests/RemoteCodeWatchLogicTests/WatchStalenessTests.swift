import XCTest

final class WatchStalenessTests: XCTestCase {

  // MARK: - No Data

  func testNilUpdatedAtReturnsEmpty() {
    let s = computeStaleness(updatedAtMs: nil, nowMs: 100000)
    XCTAssertEqual(s.label, "")
    XCTAssertFalse(s.isStale)
  }

  func testZeroUpdatedAtReturnsEmpty() {
    let s = computeStaleness(updatedAtMs: 0, nowMs: 100000)
    XCTAssertEqual(s.label, "")
    XCTAssertFalse(s.isStale)
  }

  // MARK: - Just Now

  func testJustUpdatedShowsJustNow() {
    let s = computeStaleness(updatedAtMs: 100000, nowMs: 100000)
    XCTAssertEqual(s.label, "Updated just now")
    XCTAssertFalse(s.isStale)
  }

  func testFutureTimestampShowsJustNow() {
    let s = computeStaleness(updatedAtMs: 200000, nowMs: 100000)
    XCTAssertEqual(s.label, "Updated just now")
    XCTAssertFalse(s.isStale)
  }

  func testUnder30SecondsShowsJustNow() {
    let s = computeStaleness(updatedAtMs: 100000, nowMs: 125000) // 25s
    XCTAssertEqual(s.label, "Updated just now")
    XCTAssertFalse(s.isStale)
  }

  // MARK: - Seconds

  func test45SecondsShowsSecondsAgo() {
    let s = computeStaleness(updatedAtMs: 100000, nowMs: 145000) // 45s
    XCTAssertEqual(s.label, "Updated 45s ago")
    XCTAssertFalse(s.isStale)
  }

  // MARK: - Minutes

  func test1MinuteNotStale() {
    let s = computeStaleness(updatedAtMs: 100000, nowMs: 160000) // 60s
    XCTAssertEqual(s.label, "Updated 1m ago")
    XCTAssertFalse(s.isStale)
  }

  func test2MinutesIsStale() {
    let s = computeStaleness(updatedAtMs: 100000, nowMs: 220000) // 120s
    XCTAssertEqual(s.label, "Updated 2m ago")
    XCTAssertTrue(s.isStale)
  }

  func test30MinutesStale() {
    let s = computeStaleness(updatedAtMs: 100000, nowMs: 1900000) // 1800s
    XCTAssertEqual(s.label, "Updated 30m ago")
    XCTAssertTrue(s.isStale)
  }

  // MARK: - Hours

  func test1HourStale() {
    let s = computeStaleness(updatedAtMs: 100000, nowMs: 3700000) // 3600s
    XCTAssertEqual(s.label, "Updated 1h ago")
    XCTAssertTrue(s.isStale)
  }

  func test3HoursStale() {
    let s = computeStaleness(updatedAtMs: 100000, nowMs: 10900000) // 10800s
    XCTAssertEqual(s.label, "Updated 3h ago")
    XCTAssertTrue(s.isStale)
  }
}
