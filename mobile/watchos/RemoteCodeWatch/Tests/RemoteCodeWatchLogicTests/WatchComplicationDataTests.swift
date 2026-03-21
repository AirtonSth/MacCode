import XCTest

final class WatchComplicationDataTests: XCTestCase {
  func testNilSnapshotReturnsNil() {
    XCTAssertNil(makeComplicationSnapshot(from: nil))
  }

  func testRunningSnapshotProducesLiveTimer() {
    let snapshot = LiveActivitySharedSnapshot(
      activeThreadCount: 2,
      chatId: "c1",
      chatTitle: "Deploy",
      deepLink: "remotecode-mobile://c1",
      elapsedSecondsSnapshot: nil,
      finalizingThreadCount: 0,
      phase: .running,
      preview: "Working",
      runningThreadCount: 2,
      schemaVersion: 1,
      startedAtMs: 5000,
      statusLine: "active",
      updatedAtMs: 6000
    )

    let comp = makeComplicationSnapshot(from: snapshot)
    XCTAssertNotNil(comp)
    XCTAssertEqual(comp?.activeThreadCount, 2)
    XCTAssertEqual(comp?.badgeTitle, "Running")
    XCTAssertEqual(comp?.phase, .running)
    XCTAssertFalse(comp!.isTerminal)
    XCTAssertNil(comp?.timerFrozenSeconds)
    XCTAssertEqual(comp?.timerStartedAtMs, 5000)
    XCTAssertEqual(comp?.deepLink, "remotecode-mobile://c1")
    XCTAssertEqual(comp?.updatedAtMs, 6000)
  }

  func testCompletedSnapshotProducesFrozenTimer() {
    let snapshot = LiveActivitySharedSnapshot(
      activeThreadCount: 0,
      chatId: "c2",
      chatTitle: "Build",
      deepLink: "remotecode-mobile://c2",
      elapsedSecondsSnapshot: 90,
      finalizingThreadCount: 0,
      phase: .completed,
      preview: "Done",
      runningThreadCount: 0,
      schemaVersion: 1,
      startedAtMs: 1000,
      statusLine: "completed",
      updatedAtMs: 91000
    )

    let comp = makeComplicationSnapshot(from: snapshot)
    XCTAssertNotNil(comp)
    XCTAssertTrue(comp!.isTerminal)
    XCTAssertEqual(comp?.timerFrozenSeconds, 90)
    XCTAssertNil(comp?.timerStartedAtMs)
    XCTAssertEqual(comp?.badgeTitle, "Completed")
  }

  func testFailedSnapshotIsTerminal() {
    let snapshot = LiveActivitySharedSnapshot(
      activeThreadCount: 0,
      chatId: "c3",
      chatTitle: "Test",
      deepLink: "remotecode-mobile://c3",
      elapsedSecondsSnapshot: 10,
      finalizingThreadCount: 0,
      phase: .failed,
      preview: "Failed",
      runningThreadCount: 0,
      schemaVersion: 1,
      startedAtMs: 1000,
      statusLine: "failed",
      updatedAtMs: 11000
    )

    let comp = makeComplicationSnapshot(from: snapshot)
    XCTAssertTrue(comp!.isTerminal)
    XCTAssertEqual(comp?.phase, .failed)
  }

  func testNegativeElapsedClampedToZero() {
    let snapshot = LiveActivitySharedSnapshot(
      activeThreadCount: 0,
      chatId: "c4",
      chatTitle: "X",
      deepLink: "remotecode-mobile://c4",
      elapsedSecondsSnapshot: -5,
      finalizingThreadCount: 0,
      phase: .completed,
      preview: "",
      runningThreadCount: 0,
      schemaVersion: 1,
      startedAtMs: 1000,
      statusLine: "",
      updatedAtMs: 2000
    )

    let comp = makeComplicationSnapshot(from: snapshot)
    XCTAssertEqual(comp?.timerFrozenSeconds, 0)
  }

  // MARK: - Persistence Round-Trip

  func testPersistAndLoadRoundTrip() {
    let suiteName = "test.complication.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!

    let snapshot = LiveActivitySharedSnapshot(
      activeThreadCount: 3,
      chatId: "rt",
      chatTitle: "Round Trip",
      deepLink: "remotecode-mobile://rt",
      elapsedSecondsSnapshot: nil,
      finalizingThreadCount: 0,
      phase: .running,
      preview: "Working",
      runningThreadCount: 3,
      schemaVersion: 1,
      startedAtMs: 1000,
      statusLine: "active",
      updatedAtMs: 2000
    )

    let comp = makeComplicationSnapshot(from: snapshot)!
    persistComplicationSnapshot(comp, to: defaults)

    let loaded = loadComplicationSnapshot(from: defaults)
    XCTAssertEqual(loaded, comp)
    XCTAssertEqual(loaded?.activeThreadCount, 3)
    XCTAssertEqual(loaded?.badgeTitle, "Running")

    defaults.removePersistentDomain(forName: suiteName)
  }

  func testPersistNilClearsDefaults() {
    let suiteName = "test.complication.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!

    let snapshot = LiveActivitySharedSnapshot(
      activeThreadCount: 1,
      chatId: "cl",
      chatTitle: "Clear",
      deepLink: "remotecode-mobile://cl",
      elapsedSecondsSnapshot: nil,
      finalizingThreadCount: 0,
      phase: .running,
      preview: "",
      runningThreadCount: 1,
      schemaVersion: 1,
      startedAtMs: 1000,
      statusLine: "",
      updatedAtMs: 2000
    )

    persistComplicationSnapshot(makeComplicationSnapshot(from: snapshot), to: defaults)
    XCTAssertNotNil(loadComplicationSnapshot(from: defaults))

    persistComplicationSnapshot(nil, to: defaults)
    XCTAssertNil(loadComplicationSnapshot(from: defaults))

    defaults.removePersistentDomain(forName: suiteName)
  }
}
