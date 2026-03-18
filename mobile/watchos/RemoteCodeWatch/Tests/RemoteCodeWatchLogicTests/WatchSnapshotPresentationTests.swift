import XCTest

final class WatchSnapshotPresentationTests: XCTestCase {
  func testRunningSnapshotPresentationReflectsSingleActiveThread() {
    let store = WatchSnapshotStateStore()

    XCTAssertTrue(store.applySnapshotJSONString("""
    {"activeThreadCount":1,"chatId":"active-threads","chatTitle":"Active Threads","deepLink":"remotecode-mobile://active-threads","elapsedSecondsSnapshot":null,"finalizingThreadCount":0,"phase":"running","preview":"RemoteCode is working on 1 active thread.","runningThreadCount":1,"schemaVersion":1,"startedAtMs":1000,"statusLine":"1 thread active","updatedAtMs":2000}
    """))

    let presentation = store.currentPresentation()
    XCTAssertEqual(presentation.activeCountLabel, "1 active thread")
    XCTAssertEqual(presentation.badgeTitle, "Running")
    XCTAssertEqual(presentation.statusLine, "1 thread active")
    XCTAssertEqual(presentation.timerState, .live(startedAtMs: 1000))
  }

  func testStateStoreHandlesStaleToAuthoritativeCountTransition() {
    let store = WatchSnapshotStateStore()

    XCTAssertTrue(store.applySnapshotJSONString("""
    {"activeThreadCount":4,"chatId":"active-threads","chatTitle":"Active Threads","deepLink":"remotecode-mobile://active-threads","elapsedSecondsSnapshot":null,"finalizingThreadCount":0,"phase":"running","preview":"RemoteCode is working on 4 active threads.","runningThreadCount":4,"schemaVersion":1,"startedAtMs":1000,"statusLine":"4 threads active","updatedAtMs":2000}
    """))
    XCTAssertEqual(store.currentPresentation().activeCountLabel, "4 active threads")

    XCTAssertTrue(store.applySnapshotJSONString("""
    {"activeThreadCount":1,"chatId":"active-threads","chatTitle":"Active Threads","deepLink":"remotecode-mobile://active-threads","elapsedSecondsSnapshot":null,"finalizingThreadCount":0,"phase":"running","preview":"RemoteCode is working on 1 active thread.","runningThreadCount":1,"schemaVersion":1,"startedAtMs":1000,"statusLine":"1 thread active","updatedAtMs":3000}
    """))

    XCTAssertEqual(store.currentPresentation().activeCountLabel, "1 active thread")
    XCTAssertEqual(store.currentPresentation().preview, "RemoteCode is working on 1 active thread.")
  }

  func testTerminalSnapshotFreezesTimer() {
    let store = WatchSnapshotStateStore()

    XCTAssertTrue(store.applySnapshotJSONString("""
    {"activeThreadCount":0,"chatId":"active-threads","chatTitle":"Active Threads","deepLink":"remotecode-mobile://active-threads","elapsedSecondsSnapshot":74,"finalizingThreadCount":0,"phase":"completed","preview":"No active threads right now.","runningThreadCount":0,"schemaVersion":1,"startedAtMs":1000,"statusLine":"All threads completed","updatedAtMs":75000}
    """))

    let presentation = store.currentPresentation()
    XCTAssertEqual(presentation.badgeTitle, "Completed")
    XCTAssertEqual(presentation.activeCountLabel, "No active threads")
    XCTAssertEqual(presentation.timerState, .frozen(seconds: 74))
  }

  func testClearingSnapshotReturnsIdlePresentation() {
    let store = WatchSnapshotStateStore()

    XCTAssertTrue(store.applySnapshotJSONString(nil))
    XCTAssertEqual(store.currentPresentation().badgeTitle, "Idle")
    XCTAssertEqual(store.currentPresentation().activeCountLabel, "No active threads")
  }
}
