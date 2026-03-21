import XCTest

// MARK: - Test Helpers

private func makeSnapshotJSON(
  activeThreadCount: Int = 1,
  chatId: String = "test-chat",
  chatTitle: String = "Test Chat",
  deepLink: String = "remotecode-mobile://test-chat",
  elapsedSecondsSnapshot: Int? = nil,
  finalizingThreadCount: Int = 0,
  phase: String = "running",
  preview: String = "Working...",
  runningThreadCount: Int = 1,
  schemaVersion: Int = 1,
  startedAtMs: Int = 1000,
  statusLine: String = "1 thread active",
  updatedAtMs: Int = 2000
) -> String {
  let elapsedValue: String
  if let elapsed = elapsedSecondsSnapshot {
    elapsedValue = "\(elapsed)"
  } else {
    elapsedValue = "null"
  }
  return """
  {"activeThreadCount":\(activeThreadCount),"chatId":"\(chatId)","chatTitle":"\(chatTitle)","deepLink":"\(deepLink)","elapsedSecondsSnapshot":\(elapsedValue),"finalizingThreadCount":\(finalizingThreadCount),"phase":"\(phase)","preview":"\(preview)","runningThreadCount":\(runningThreadCount),"schemaVersion":\(schemaVersion),"startedAtMs":\(startedAtMs),"statusLine":"\(statusLine)","updatedAtMs":\(updatedAtMs)}
  """
}

// MARK: - Presentation Logic Tests

final class WatchSnapshotPresentationTests: XCTestCase {

  // MARK: - Idle / Nil State

  func testNilSnapshotReturnsIdlePresentation() {
    let presentation = makeWatchSnapshotPresentation(snapshot: nil)
    XCTAssertEqual(presentation.badgeTitle, "Idle")
    XCTAssertEqual(presentation.badgeStyle, .normal)
    XCTAssertEqual(presentation.activeCountLabel, "No active threads")
    XCTAssertEqual(presentation.title, "RemoteCode")
    XCTAssertEqual(presentation.statusLine, "Waiting for a session")
    XCTAssertEqual(presentation.preview, "Open RemoteCode on iPhone to start a session.")
    XCTAssertEqual(presentation.timerState, .frozen(seconds: 0))
  }

  // MARK: - Running Phase

  func testRunningWithSingleActiveThread() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 1,
      phase: "running",
      startedAtMs: 1000,
      updatedAtMs: 2000
    )))

    let p = store.currentPresentation()
    XCTAssertEqual(p.activeCountLabel, "1 active thread")
    XCTAssertEqual(p.badgeTitle, "Running")
    XCTAssertEqual(p.badgeStyle, .normal)
    XCTAssertEqual(p.timerState, .live(startedAtMs: 1000))
  }

  func testRunningWithMultipleActiveThreads() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 5,
      phase: "running",
      updatedAtMs: 2000
    )))

    XCTAssertEqual(store.currentPresentation().activeCountLabel, "5 active threads")
  }

  func testRunningWithZeroActiveThreads() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 0,
      phase: "running",
      updatedAtMs: 2000
    )))

    XCTAssertEqual(store.currentPresentation().activeCountLabel, "No active threads")
    XCTAssertEqual(store.currentPresentation().badgeTitle, "Running")
  }

  func testRunningWithFrozenElapsedSeconds() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      elapsedSecondsSnapshot: 120,
      phase: "running",
      updatedAtMs: 2000
    )))

    XCTAssertEqual(store.currentPresentation().timerState, .frozen(seconds: 120))
  }

  func testRunningWithNilElapsedUsesLiveTimer() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      phase: "running",
      startedAtMs: 5000,
      updatedAtMs: 2000
    )))

    XCTAssertEqual(store.currentPresentation().timerState, .live(startedAtMs: 5000))
  }

  // MARK: - Background Phase

  func testBackgroundPhaseShowsRunningBadge() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      phase: "background",
      updatedAtMs: 2000
    )))

    let p = store.currentPresentation()
    XCTAssertEqual(p.badgeTitle, "Running")
    XCTAssertEqual(p.badgeStyle, .normal)
  }

  // MARK: - Finalizing Phase

  func testFinalizingPhasePresentation() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      phase: "finalizing",
      updatedAtMs: 2000
    )))

    let p = store.currentPresentation()
    XCTAssertEqual(p.badgeTitle, "Finalizing")
    XCTAssertEqual(p.badgeStyle, .normal)
  }

  // MARK: - Terminal Phases

  func testCompletedPhaseFreezesTimer() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 0,
      elapsedSecondsSnapshot: 74,
      phase: "completed",
      updatedAtMs: 75000
    )))

    let p = store.currentPresentation()
    XCTAssertEqual(p.badgeTitle, "Completed")
    XCTAssertEqual(p.badgeStyle, .normal)
    XCTAssertEqual(p.activeCountLabel, "No active threads")
    XCTAssertEqual(p.timerState, .frozen(seconds: 74))
  }

  func testCompletedWithNilElapsedFreezesAtZero() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      phase: "completed",
      updatedAtMs: 75000
    )))

    XCTAssertEqual(store.currentPresentation().timerState, .frozen(seconds: 0))
  }

  func testFailedPhaseHasErrorBadgeStyle() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 0,
      elapsedSecondsSnapshot: 30,
      phase: "failed",
      statusLine: "Thread crashed",
      updatedAtMs: 31000
    )))

    let p = store.currentPresentation()
    XCTAssertEqual(p.badgeTitle, "Failed")
    XCTAssertEqual(p.badgeStyle, .error)
    XCTAssertEqual(p.statusLine, "Thread crashed")
    XCTAssertEqual(p.timerState, .frozen(seconds: 30))
  }

  func testErrorPhaseHasErrorBadgeStyle() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 0,
      elapsedSecondsSnapshot: 10,
      phase: "error",
      statusLine: "Connection lost",
      updatedAtMs: 11000
    )))

    let p = store.currentPresentation()
    XCTAssertEqual(p.badgeTitle, "Error")
    XCTAssertEqual(p.badgeStyle, .error)
    XCTAssertEqual(p.statusLine, "Connection lost")
    XCTAssertEqual(p.timerState, .frozen(seconds: 10))
  }

  // MARK: - Chat Title & Preview Pass-through

  func testChatTitleAndPreviewPassedThrough() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      chatTitle: "Deploy Pipeline",
      preview: "Running migration scripts on staging...",
      updatedAtMs: 2000
    )))

    let p = store.currentPresentation()
    XCTAssertEqual(p.title, "Deploy Pipeline")
    XCTAssertEqual(p.preview, "Running migration scripts on staging...")
  }
}

// MARK: - State Store Tests

final class WatchSnapshotStateStoreTests: XCTestCase {

  // MARK: - JSON Parsing

  func testValidJSONAppliesSuccessfully() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(updatedAtMs: 2000)))
    XCTAssertNotNil(store.snapshot)
  }

  func testNilInputClearsSnapshot() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(updatedAtMs: 2000)))
    XCTAssertNotNil(store.snapshot)

    XCTAssertTrue(store.applySnapshotJSONString(nil))
    XCTAssertNil(store.snapshot)
  }

  func testEmptyStringClearsSnapshot() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(updatedAtMs: 2000)))
    XCTAssertTrue(store.applySnapshotJSONString(""))
    XCTAssertNil(store.snapshot)
  }

  func testWhitespaceOnlyStringClearsSnapshot() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(updatedAtMs: 2000)))
    XCTAssertTrue(store.applySnapshotJSONString("   \n\t  "))
    XCTAssertNil(store.snapshot)
  }

  func testMalformedJSONReturnsFalse() {
    let store = WatchSnapshotStateStore()
    XCTAssertFalse(store.applySnapshotJSONString("{invalid json"))
    XCTAssertNil(store.snapshot)
  }

  func testPartialJSONMissingRequiredFieldReturnsFalse() {
    let store = WatchSnapshotStateStore()
    XCTAssertFalse(store.applySnapshotJSONString("""
    {"activeThreadCount":1,"chatId":"test"}
    """))
    XCTAssertNil(store.snapshot)
  }

  func testMalformedJSONDoesNotClearExistingSnapshot() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(updatedAtMs: 2000)))
    let original = store.snapshot

    XCTAssertFalse(store.applySnapshotJSONString("{broken"))
    XCTAssertEqual(store.snapshot, original)
  }

  func testJSONWithExtraFieldsDecodesSuccessfully() {
    let store = WatchSnapshotStateStore()
    let json = """
    {"activeThreadCount":1,"chatId":"test","chatTitle":"Test","deepLink":"remotecode-mobile://test","elapsedSecondsSnapshot":null,"finalizingThreadCount":0,"phase":"running","preview":"Working","runningThreadCount":1,"schemaVersion":1,"startedAtMs":1000,"statusLine":"active","updatedAtMs":2000,"futureField":"ignored"}
    """
    XCTAssertTrue(store.applySnapshotJSONString(json))
    XCTAssertNotNil(store.snapshot)
  }

  // MARK: - Schema Version Validation

  func testUnsupportedSchemaVersionIsRejected() {
    let store = WatchSnapshotStateStore()
    XCTAssertFalse(store.applySnapshotJSONString(makeSnapshotJSON(
      schemaVersion: 2,
      updatedAtMs: 2000
    )))
    XCTAssertNil(store.snapshot)
  }

  func testSchemaVersionZeroIsRejected() {
    let store = WatchSnapshotStateStore()
    XCTAssertFalse(store.applySnapshotJSONString(makeSnapshotJSON(
      schemaVersion: 0,
      updatedAtMs: 2000
    )))
    XCTAssertNil(store.snapshot)
  }

  func testSchemaVersion1IsAccepted() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      schemaVersion: 1,
      updatedAtMs: 2000
    )))
    XCTAssertNotNil(store.snapshot)
  }

  func testUnsupportedSchemaDoesNotClearExistingSnapshot() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      schemaVersion: 1,
      updatedAtMs: 2000
    )))

    XCTAssertFalse(store.applySnapshotJSONString(makeSnapshotJSON(
      schemaVersion: 99,
      updatedAtMs: 3000
    )))
    XCTAssertNotNil(store.snapshot)
    XCTAssertEqual(store.snapshot?.updatedAtMs, 2000)
  }

  // MARK: - Out-of-Order Protection (updatedAtMs)

  func testNewerSnapshotOverwritesOlder() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 1,
      updatedAtMs: 2000
    )))
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 3,
      updatedAtMs: 3000
    )))

    XCTAssertEqual(store.snapshot?.activeThreadCount, 3)
    XCTAssertEqual(store.snapshot?.updatedAtMs, 3000)
  }

  func testOlderSnapshotIsRejected() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 3,
      updatedAtMs: 5000
    )))
    XCTAssertFalse(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 1,
      updatedAtMs: 2000
    )))

    XCTAssertEqual(store.snapshot?.activeThreadCount, 3)
    XCTAssertEqual(store.snapshot?.updatedAtMs, 5000)
  }

  func testSameTimestampIsRejected() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 2,
      updatedAtMs: 3000
    )))
    XCTAssertFalse(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 5,
      updatedAtMs: 3000
    )))

    XCTAssertEqual(store.snapshot?.activeThreadCount, 2)
  }

  func testForceBypassesTimestampCheck() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 3,
      updatedAtMs: 5000
    )))
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 1,
      updatedAtMs: 1000
    ), force: true))

    XCTAssertEqual(store.snapshot?.activeThreadCount, 1)
    XCTAssertEqual(store.snapshot?.updatedAtMs, 1000)
  }

  func testFirstSnapshotAlwaysApplies() {
    let store = WatchSnapshotStateStore()
    XCTAssertNil(store.snapshot)

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(updatedAtMs: 1)))
    XCTAssertNotNil(store.snapshot)
  }

  // MARK: - State Transitions

  func testTransitionFromRunningToCompleted() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 2,
      phase: "running",
      updatedAtMs: 1000
    )))
    XCTAssertEqual(store.currentPresentation().badgeTitle, "Running")

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 0,
      elapsedSecondsSnapshot: 60,
      phase: "completed",
      updatedAtMs: 61000
    )))

    let p = store.currentPresentation()
    XCTAssertEqual(p.badgeTitle, "Completed")
    XCTAssertEqual(p.badgeStyle, .normal)
    XCTAssertEqual(p.timerState, .frozen(seconds: 60))
    XCTAssertEqual(p.activeCountLabel, "No active threads")
  }

  func testTransitionFromRunningToFailed() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      phase: "running",
      updatedAtMs: 1000
    )))

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 0,
      elapsedSecondsSnapshot: 45,
      phase: "failed",
      statusLine: "Process exited with code 1",
      updatedAtMs: 46000
    )))

    let p = store.currentPresentation()
    XCTAssertEqual(p.badgeTitle, "Failed")
    XCTAssertEqual(p.badgeStyle, .error)
    XCTAssertEqual(p.statusLine, "Process exited with code 1")
  }

  func testTransitionFromRunningToError() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      phase: "running",
      updatedAtMs: 1000
    )))

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 0,
      elapsedSecondsSnapshot: 5,
      phase: "error",
      statusLine: "Network timeout",
      updatedAtMs: 6000
    )))

    let p = store.currentPresentation()
    XCTAssertEqual(p.badgeTitle, "Error")
    XCTAssertEqual(p.badgeStyle, .error)
  }

  func testTransitionFromRunningToFinalizing() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      phase: "running",
      updatedAtMs: 1000
    )))

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      finalizingThreadCount: 2,
      phase: "finalizing",
      updatedAtMs: 2000
    )))

    XCTAssertEqual(store.currentPresentation().badgeTitle, "Finalizing")
  }

  func testTransitionFromRunningToBackground() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      phase: "running",
      updatedAtMs: 1000
    )))

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      phase: "background",
      updatedAtMs: 2000
    )))

    XCTAssertEqual(store.currentPresentation().badgeTitle, "Running")
  }

  func testClearingAfterRunningReturnsIdle() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      phase: "running",
      updatedAtMs: 1000
    )))
    XCTAssertEqual(store.currentPresentation().badgeTitle, "Running")

    XCTAssertTrue(store.applySnapshotJSONString(nil))
    XCTAssertEqual(store.currentPresentation().badgeTitle, "Idle")
  }

  // MARK: - Thread Count Transitions

  func testThreadCountIncreasingDuringSession() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 1,
      updatedAtMs: 1000
    )))
    XCTAssertEqual(store.currentPresentation().activeCountLabel, "1 active thread")

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 4,
      updatedAtMs: 2000
    )))
    XCTAssertEqual(store.currentPresentation().activeCountLabel, "4 active threads")
  }

  func testThreadCountDecreasingDuringSession() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 4,
      updatedAtMs: 2000
    )))

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 1,
      updatedAtMs: 3000
    )))

    XCTAssertEqual(store.currentPresentation().activeCountLabel, "1 active thread")
  }

  func testThreadCountDropToZero() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 3,
      updatedAtMs: 2000
    )))

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 0,
      updatedAtMs: 3000
    )))

    XCTAssertEqual(store.currentPresentation().activeCountLabel, "No active threads")
  }
}

// MARK: - Timer Formatting Tests

final class WatchTimerFormattingTests: XCTestCase {
  func testZeroSeconds() {
    XCTAssertEqual(formatFrozenDuration(seconds: 0), "00:00")
  }

  func testUnderOneMinute() {
    XCTAssertEqual(formatFrozenDuration(seconds: 45), "00:45")
  }

  func testExactlyOneMinute() {
    XCTAssertEqual(formatFrozenDuration(seconds: 60), "01:00")
  }

  func testUnderOneHour() {
    XCTAssertEqual(formatFrozenDuration(seconds: 754), "12:34")
  }

  func testExactlyOneHour() {
    XCTAssertEqual(formatFrozenDuration(seconds: 3600), "1:00:00")
  }

  func testOverOneHour() {
    XCTAssertEqual(formatFrozenDuration(seconds: 5423), "1:30:23")
  }

  func testMultipleHours() {
    XCTAssertEqual(formatFrozenDuration(seconds: 36000), "10:00:00")
  }

  func testNegativeSecondsClampsToZero() {
    XCTAssertEqual(formatFrozenDuration(seconds: -100), "00:00")
  }

  func testLargeDuration() {
    XCTAssertEqual(formatFrozenDuration(seconds: 360000), "100:00:00")
  }
}

// MARK: - LiveActivitySharedPhase Tests

final class LiveActivitySharedPhaseTests: XCTestCase {
  func testRunningIsNotTerminal() {
    XCTAssertFalse(LiveActivitySharedPhase.running.isTerminal)
  }

  func testFinalizingIsNotTerminal() {
    XCTAssertFalse(LiveActivitySharedPhase.finalizing.isTerminal)
  }

  func testBackgroundIsNotTerminal() {
    XCTAssertFalse(LiveActivitySharedPhase.background.isTerminal)
  }

  func testCompletedIsTerminal() {
    XCTAssertTrue(LiveActivitySharedPhase.completed.isTerminal)
  }

  func testFailedIsTerminal() {
    XCTAssertTrue(LiveActivitySharedPhase.failed.isTerminal)
  }

  func testErrorIsTerminal() {
    XCTAssertTrue(LiveActivitySharedPhase.error.isTerminal)
  }

  func testBadgeTitles() {
    XCTAssertEqual(LiveActivitySharedPhase.running.badgeTitle, "Running")
    XCTAssertEqual(LiveActivitySharedPhase.background.badgeTitle, "Running")
    XCTAssertEqual(LiveActivitySharedPhase.finalizing.badgeTitle, "Finalizing")
    XCTAssertEqual(LiveActivitySharedPhase.completed.badgeTitle, "Completed")
    XCTAssertEqual(LiveActivitySharedPhase.failed.badgeTitle, "Failed")
    XCTAssertEqual(LiveActivitySharedPhase.error.badgeTitle, "Error")
  }
}

// MARK: - E2E Scenario Tests

final class WatchSnapshotE2EScenarioTests: XCTestCase {

  // MARK: - Full Session Lifecycle

  func testFullSessionLifecycle_StartRunComplete() {
    let store = WatchSnapshotStateStore()

    // 1. Initial idle state
    XCTAssertEqual(store.currentPresentation().badgeTitle, "Idle")
    XCTAssertEqual(store.currentPresentation().timerState, .frozen(seconds: 0))

    // 2. Session starts - 1 thread
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 1,
      chatTitle: "Deploy v2.1",
      phase: "running",
      preview: "Starting deployment...",
      startedAtMs: 1000,
      statusLine: "1 thread active",
      updatedAtMs: 1000
    )))
    var p = store.currentPresentation()
    XCTAssertEqual(p.badgeTitle, "Running")
    XCTAssertEqual(p.title, "Deploy v2.1")
    XCTAssertEqual(p.activeCountLabel, "1 active thread")
    XCTAssertEqual(p.timerState, .live(startedAtMs: 1000))

    // 3. More threads spin up
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 3,
      chatTitle: "Deploy v2.1",
      phase: "running",
      preview: "Running migrations...",
      runningThreadCount: 3,
      startedAtMs: 1000,
      statusLine: "3 threads active",
      updatedAtMs: 10000
    )))
    p = store.currentPresentation()
    XCTAssertEqual(p.activeCountLabel, "3 active threads")
    XCTAssertEqual(p.preview, "Running migrations...")

    // 4. Threads start finishing
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 1,
      chatTitle: "Deploy v2.1",
      finalizingThreadCount: 1,
      phase: "finalizing",
      preview: "Wrapping up...",
      startedAtMs: 1000,
      statusLine: "Finalizing",
      updatedAtMs: 50000
    )))
    p = store.currentPresentation()
    XCTAssertEqual(p.badgeTitle, "Finalizing")
    XCTAssertEqual(p.activeCountLabel, "1 active thread")

    // 5. Session completes
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 0,
      chatTitle: "Deploy v2.1",
      elapsedSecondsSnapshot: 60,
      phase: "completed",
      preview: "All done.",
      startedAtMs: 1000,
      statusLine: "All threads completed",
      updatedAtMs: 61000
    )))
    p = store.currentPresentation()
    XCTAssertEqual(p.badgeTitle, "Completed")
    XCTAssertEqual(p.badgeStyle, .normal)
    XCTAssertEqual(p.timerState, .frozen(seconds: 60))
    XCTAssertEqual(p.activeCountLabel, "No active threads")
    XCTAssertEqual(p.title, "Deploy v2.1")

    // 6. Cleared back to idle
    XCTAssertTrue(store.applySnapshotJSONString(nil))
    p = store.currentPresentation()
    XCTAssertEqual(p.badgeTitle, "Idle")
    XCTAssertEqual(p.title, "RemoteCode")
  }

  func testFullSessionLifecycle_StartRunFail() {
    let store = WatchSnapshotStateStore()

    // 1. Session starts
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 2,
      chatTitle: "Build CI",
      phase: "running",
      preview: "Compiling...",
      startedAtMs: 1000,
      updatedAtMs: 1000
    )))
    XCTAssertEqual(store.currentPresentation().badgeTitle, "Running")

    // 2. Session fails
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 0,
      chatTitle: "Build CI",
      elapsedSecondsSnapshot: 30,
      phase: "failed",
      preview: "Build failed: exit code 1",
      startedAtMs: 1000,
      statusLine: "Build failed",
      updatedAtMs: 31000
    )))

    let p = store.currentPresentation()
    XCTAssertEqual(p.badgeTitle, "Failed")
    XCTAssertEqual(p.badgeStyle, .error)
    XCTAssertEqual(p.timerState, .frozen(seconds: 30))
    XCTAssertEqual(p.preview, "Build failed: exit code 1")
  }

  func testFullSessionLifecycle_StartRunError() {
    let store = WatchSnapshotStateStore()

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      phase: "running",
      updatedAtMs: 1000
    )))

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 0,
      elapsedSecondsSnapshot: 12,
      phase: "error",
      preview: "Lost connection to server",
      statusLine: "Connection error",
      updatedAtMs: 13000
    )))

    let p = store.currentPresentation()
    XCTAssertEqual(p.badgeTitle, "Error")
    XCTAssertEqual(p.badgeStyle, .error)
    XCTAssertEqual(p.timerState, .frozen(seconds: 12))
  }

  // MARK: - Out-of-Order Delivery Scenarios

  func testOutOfOrderDelivery_OlderSnapshotIgnored() {
    let store = WatchSnapshotStateStore()

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 3,
      statusLine: "3 threads active",
      updatedAtMs: 5000
    )))

    XCTAssertFalse(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 1,
      statusLine: "1 thread active",
      updatedAtMs: 2000
    )))

    XCTAssertEqual(store.currentPresentation().activeCountLabel, "3 active threads")
    XCTAssertEqual(store.snapshot?.updatedAtMs, 5000)
  }

  func testOutOfOrderDelivery_ClearAlwaysWorks() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(updatedAtMs: 5000)))
    XCTAssertNotNil(store.snapshot)

    XCTAssertTrue(store.applySnapshotJSONString(nil))
    XCTAssertNil(store.snapshot)
  }

  // MARK: - Rapid Updates

  func testRapidUpdatesInCorrectOrder() {
    let store = WatchSnapshotStateStore()

    for i in 1...10 {
      XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
        activeThreadCount: i,
        updatedAtMs: i * 1000
      )))
    }

    XCTAssertEqual(store.snapshot?.activeThreadCount, 10)
    XCTAssertEqual(store.snapshot?.updatedAtMs, 10000)
    XCTAssertEqual(store.currentPresentation().activeCountLabel, "10 active threads")
  }

  func testRapidUpdatesWithSomeOutOfOrder() {
    let store = WatchSnapshotStateStore()

    let updates: [(threads: Int, ts: Int)] = [
      (1, 1000), (3, 3000), (2, 2000), (5, 5000), (4, 4000)
    ]

    for update in updates {
      _ = store.applySnapshotJSONString(makeSnapshotJSON(
        activeThreadCount: update.threads,
        updatedAtMs: update.ts
      ))
    }

    XCTAssertEqual(store.snapshot?.activeThreadCount, 5)
    XCTAssertEqual(store.snapshot?.updatedAtMs, 5000)
  }

  // MARK: - Session Switch (Different ChatIDs)

  func testSwitchingBetweenDifferentChats() {
    let store = WatchSnapshotStateStore()

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      chatId: "chat-a",
      chatTitle: "Chat A",
      updatedAtMs: 1000
    )))
    XCTAssertEqual(store.currentPresentation().title, "Chat A")

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      chatId: "chat-b",
      chatTitle: "Chat B",
      updatedAtMs: 5000
    )))
    XCTAssertEqual(store.currentPresentation().title, "Chat B")

    XCTAssertFalse(store.applySnapshotJSONString(makeSnapshotJSON(
      chatId: "chat-a",
      chatTitle: "Chat A Updated",
      updatedAtMs: 2000
    )))
    XCTAssertEqual(store.currentPresentation().title, "Chat B")
  }

  // MARK: - Edge Cases

  func testVeryLargeTimestampValues() {
    let store = WatchSnapshotStateStore()
    let largeMs = 2208988800000
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      startedAtMs: largeMs,
      updatedAtMs: largeMs
    )))

    XCTAssertEqual(store.snapshot?.startedAtMs, largeMs)
    XCTAssertEqual(store.currentPresentation().timerState, .live(startedAtMs: largeMs))
  }

  func testSnapshotWithZeroStartedAtMs() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      startedAtMs: 0,
      updatedAtMs: 1000
    )))

    XCTAssertEqual(store.currentPresentation().timerState, .live(startedAtMs: 0))
  }

  func testSnapshotWithNegativeElapsedSecondsClamped() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      elapsedSecondsSnapshot: -5,
      phase: "completed",
      updatedAtMs: 1000
    )))

    XCTAssertEqual(store.currentPresentation().timerState, .frozen(seconds: 0))
  }

  func testEmptyStringsInTextFields() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      chatTitle: "",
      preview: "",
      statusLine: "",
      updatedAtMs: 1000
    )))

    let p = store.currentPresentation()
    XCTAssertEqual(p.title, "")
    XCTAssertEqual(p.preview, "")
    XCTAssertEqual(p.statusLine, "")
  }

  func testUnicodeInTextFields() {
    let store = WatchSnapshotStateStore()
    let json = """
    {"activeThreadCount":1,"chatId":"unicode","chatTitle":"Deploy \\u2728","deepLink":"remotecode-mobile://test","elapsedSecondsSnapshot":null,"finalizingThreadCount":0,"phase":"running","preview":"Running tests \\u2705","runningThreadCount":1,"schemaVersion":1,"startedAtMs":1000,"statusLine":"Active \\ud83d\\udfe2","updatedAtMs":2000}
    """
    XCTAssertTrue(store.applySnapshotJSONString(json))

    let p = store.currentPresentation()
    XCTAssertTrue(p.title.contains("\u{2728}"))
    XCTAssertTrue(p.preview.contains("\u{2705}"))
  }

  // MARK: - Persistence Simulation

  func testPersistAndRestoreFromUserDefaults() {
    let suiteName = "test.watch.e2e.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!

    let originalJSON = makeSnapshotJSON(
      activeThreadCount: 2,
      chatTitle: "Persisted Session",
      phase: "running",
      updatedAtMs: 5000
    )

    defaults.set(originalJSON, forKey: "remotecode.live_activity.shared_snapshot.watch")

    let store = WatchSnapshotStateStore()
    let restored = defaults.string(forKey: "remotecode.live_activity.shared_snapshot.watch")
    XCTAssertTrue(store.applySnapshotJSONString(restored, force: true))

    let p = store.currentPresentation()
    XCTAssertEqual(p.title, "Persisted Session")
    XCTAssertEqual(p.activeCountLabel, "2 active threads")
    XCTAssertEqual(p.badgeTitle, "Running")

    defaults.removePersistentDomain(forName: suiteName)
  }

  func testPersistThenReceiveNewerFromWCSession() {
    let store = WatchSnapshotStateStore()
    let persisted = makeSnapshotJSON(
      activeThreadCount: 1,
      chatTitle: "Old State",
      phase: "running",
      updatedAtMs: 1000
    )
    XCTAssertTrue(store.applySnapshotJSONString(persisted, force: true))
    XCTAssertEqual(store.currentPresentation().title, "Old State")

    let wcSessionData = makeSnapshotJSON(
      activeThreadCount: 3,
      chatTitle: "Current State",
      phase: "running",
      updatedAtMs: 5000
    )
    XCTAssertTrue(store.applySnapshotJSONString(wcSessionData))
    XCTAssertEqual(store.currentPresentation().title, "Current State")
    XCTAssertEqual(store.currentPresentation().activeCountLabel, "3 active threads")
  }

  func testPersistThenReceiveOlderFromWCSession() {
    let store = WatchSnapshotStateStore()

    let persisted = makeSnapshotJSON(
      activeThreadCount: 3,
      chatTitle: "Newer State",
      phase: "running",
      updatedAtMs: 5000
    )
    XCTAssertTrue(store.applySnapshotJSONString(persisted, force: true))

    let wcSessionData = makeSnapshotJSON(
      activeThreadCount: 1,
      chatTitle: "Stale State",
      phase: "running",
      updatedAtMs: 2000
    )
    XCTAssertFalse(store.applySnapshotJSONString(wcSessionData))
    XCTAssertEqual(store.currentPresentation().title, "Newer State")
  }

  // MARK: - Multiple Clears and Restarts

  func testMultipleSessionStartsAndClears() {
    let store = WatchSnapshotStateStore()

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      chatTitle: "Session 1",
      updatedAtMs: 1000
    )))
    XCTAssertEqual(store.currentPresentation().title, "Session 1")

    XCTAssertTrue(store.applySnapshotJSONString(nil))
    XCTAssertEqual(store.currentPresentation().badgeTitle, "Idle")

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      chatTitle: "Session 2",
      updatedAtMs: 500
    )))
    XCTAssertEqual(store.currentPresentation().title, "Session 2")

    XCTAssertTrue(store.applySnapshotJSONString(nil))

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      chatTitle: "Session 3",
      updatedAtMs: 100
    )))
    XCTAssertEqual(store.currentPresentation().title, "Session 3")
  }
}
