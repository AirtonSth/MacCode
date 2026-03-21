import XCTest

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

// MARK: - Phase Transition Integration with StateStore

final class WatchPhaseTransitionIntegrationTests: XCTestCase {

  func testStateStoreTracksPhaseTransition_RunningToCompleted() {
    let store = WatchSnapshotStateStore()

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      phase: "running",
      updatedAtMs: 1000
    )))
    XCTAssertNil(store.lastTransition?.oldPhase)
    XCTAssertEqual(store.lastTransition?.newPhase, .running)
    XCTAssertNil(store.lastTransition?.hapticType)

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      elapsedSecondsSnapshot: 60,
      phase: "completed",
      updatedAtMs: 61000
    )))
    XCTAssertEqual(store.lastTransition?.oldPhase, .running)
    XCTAssertEqual(store.lastTransition?.newPhase, .completed)
    XCTAssertEqual(store.lastTransition?.hapticType, .success)
    XCTAssertTrue(store.lastTransition?.shouldNotify == true)
  }

  func testStateStoreTracksPhaseTransition_RunningToFailed() {
    let store = WatchSnapshotStateStore()

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      phase: "running",
      updatedAtMs: 1000
    )))

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      elapsedSecondsSnapshot: 30,
      phase: "failed",
      updatedAtMs: 31000
    )))
    XCTAssertEqual(store.lastTransition?.hapticType, .failure)
    XCTAssertTrue(store.lastTransition?.shouldNotify == true)
  }

  func testStateStoreTracksPhaseTransition_RunningToError() {
    let store = WatchSnapshotStateStore()

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      phase: "running",
      updatedAtMs: 1000
    )))

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      elapsedSecondsSnapshot: 10,
      phase: "error",
      updatedAtMs: 11000
    )))
    XCTAssertEqual(store.lastTransition?.hapticType, .failure)
  }

  func testSamePhaseUpdateNoTransitionHaptic() {
    let store = WatchSnapshotStateStore()

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 1,
      phase: "running",
      updatedAtMs: 1000
    )))

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 3,
      phase: "running",
      updatedAtMs: 2000
    )))

    XCTAssertNil(store.lastTransition?.hapticType)
    XCTAssertFalse(store.lastTransition?.shouldNotify == true)
  }

  func testClearingTracksTransitionToNil() {
    let store = WatchSnapshotStateStore()

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      phase: "running",
      updatedAtMs: 1000
    )))

    XCTAssertTrue(store.applySnapshotJSONString(nil))
    XCTAssertEqual(store.lastTransition?.oldPhase, .running)
    XCTAssertNil(store.lastTransition?.newPhase)
  }

  func testRejectedSnapshotDoesNotChangeTransition() {
    let store = WatchSnapshotStateStore()

    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      phase: "running",
      updatedAtMs: 5000
    )))
    let transitionAfterFirst = store.lastTransition

    // Older snapshot rejected
    XCTAssertFalse(store.applySnapshotJSONString(makeSnapshotJSON(
      phase: "completed",
      updatedAtMs: 1000
    )))

    XCTAssertEqual(store.lastTransition, transitionAfterFirst)
    XCTAssertEqual(store.snapshot?.phase, .running)
  }
}

// MARK: - Deep Link Presentation Integration

final class WatchDeepLinkIntegrationTests: XCTestCase {
  func testPresentationIncludesDeepLink() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      deepLink: "remotecode-mobile://my-chat",
      updatedAtMs: 1000
    )))

    XCTAssertEqual(store.currentPresentation().deepLink, "remotecode-mobile://my-chat")
  }

  func testIdlePresentationHasNilDeepLink() {
    let presentation = makeWatchSnapshotPresentation(snapshot: nil)
    XCTAssertNil(presentation.deepLink)
  }
}

// MARK: - Staleness + Presentation Integration

final class WatchStalenessIntegrationTests: XCTestCase {
  func testPresentationIncludesUpdatedAtMs() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(updatedAtMs: 9000)))

    XCTAssertEqual(store.currentPresentation().updatedAtMs, 9000)
  }

  func testIdlePresentationHasNilUpdatedAtMs() {
    let presentation = makeWatchSnapshotPresentation(snapshot: nil)
    XCTAssertNil(presentation.updatedAtMs)
  }

  func testStalenessComputedFromPresentationUpdatedAtMs() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(updatedAtMs: 100000)))

    let p = store.currentPresentation()
    let staleness = computeStaleness(updatedAtMs: p.updatedAtMs, nowMs: 220000)
    XCTAssertEqual(staleness.label, "Updated 2m ago")
    XCTAssertTrue(staleness.isStale)
  }
}

// MARK: - History + StateStore Integration

final class WatchHistoryIntegrationTests: XCTestCase {
  func testHistoryUpdatedOnSnapshotApply() {
    let suiteName = "test.integration.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let store = WatchSnapshotStateStore()
    let history = WatchSessionHistoryStore(defaults: defaults)

    // Apply running snapshot
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      chatId: "deploy",
      chatTitle: "Deploy v3",
      phase: "running",
      updatedAtMs: 1000
    )))
    history.addOrUpdate(snapshot: store.snapshot!)
    XCTAssertEqual(history.history.count, 1)
    XCTAssertEqual(history.history[0].chatTitle, "Deploy v3")
    XCTAssertEqual(history.history[0].phase, .running)

    // Apply completed snapshot
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      chatId: "deploy",
      chatTitle: "Deploy v3",
      elapsedSecondsSnapshot: 90,
      phase: "completed",
      updatedAtMs: 91000
    )))
    history.addOrUpdate(snapshot: store.snapshot!)
    XCTAssertEqual(history.history.count, 1)
    XCTAssertEqual(history.history[0].phase, .completed)
    XCTAssertEqual(history.history[0].elapsedSeconds, 90)

    defaults.removePersistentDomain(forName: suiteName)
  }
}

// MARK: - Complication + StateStore Integration

final class WatchComplicationIntegrationTests: XCTestCase {
  func testComplicationSnapshotDerivedFromStoreState() {
    let store = WatchSnapshotStateStore()
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 3,
      chatTitle: "Build",
      deepLink: "remotecode-mobile://build",
      phase: "running",
      startedAtMs: 5000,
      updatedAtMs: 6000
    )))

    let comp = makeComplicationSnapshot(from: store.snapshot)
    XCTAssertNotNil(comp)
    XCTAssertEqual(comp?.activeThreadCount, 3)
    XCTAssertEqual(comp?.badgeTitle, "Running")
    XCTAssertEqual(comp?.timerStartedAtMs, 5000)
    XCTAssertFalse(comp!.isTerminal)
  }

  func testComplicationNilWhenStoreEmpty() {
    let store = WatchSnapshotStateStore()
    XCTAssertNil(makeComplicationSnapshot(from: store.snapshot))
  }
}

// MARK: - Background Refresh + StateStore Integration

final class WatchBackgroundRefreshIntegrationTests: XCTestCase {
  func testRefreshIntervalMatchesCurrentPhase() {
    let store = WatchSnapshotStateStore()

    // Running -> 5 min
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      phase: "running",
      updatedAtMs: 1000
    )))
    XCTAssertEqual(backgroundRefreshInterval(for: store.snapshot?.phase), 5 * 60)

    // Finalizing -> 2 min
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      phase: "finalizing",
      updatedAtMs: 2000
    )))
    XCTAssertEqual(backgroundRefreshInterval(for: store.snapshot?.phase), 2 * 60)

    // Completed -> nil
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      elapsedSecondsSnapshot: 60,
      phase: "completed",
      updatedAtMs: 3000
    )))
    XCTAssertNil(backgroundRefreshInterval(for: store.snapshot?.phase))

    // Clear -> 15 min
    XCTAssertTrue(store.applySnapshotJSONString(nil))
    XCTAssertEqual(backgroundRefreshInterval(for: store.snapshot?.phase), 15 * 60)
  }
}

// MARK: - Full E2E: Session Lifecycle with All Features

final class WatchFullFeatureE2ETests: XCTestCase {
  func testCompleteSessionWithAllFeatures() {
    let suiteName = "test.e2e.full.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let store = WatchSnapshotStateStore()
    let history = WatchSessionHistoryStore(defaults: defaults)

    // 1. IDLE: no data
    XCTAssertNil(store.snapshot)
    XCTAssertNil(store.currentPresentation().deepLink)
    XCTAssertNil(store.currentPresentation().updatedAtMs)
    XCTAssertEqual(backgroundRefreshInterval(for: store.snapshot?.phase), 15 * 60)

    // 2. SESSION STARTS
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 1,
      chatId: "e2e-deploy",
      chatTitle: "E2E Deploy",
      deepLink: "remotecode-mobile://e2e-deploy",
      phase: "running",
      startedAtMs: 1000,
      updatedAtMs: 1000
    )))
    history.addOrUpdate(snapshot: store.snapshot!)

    var p = store.currentPresentation()
    XCTAssertEqual(p.badgeTitle, "Running")
    XCTAssertEqual(p.deepLink, "remotecode-mobile://e2e-deploy")
    XCTAssertEqual(p.updatedAtMs, 1000)
    XCTAssertNil(store.lastTransition?.hapticType)
    XCTAssertEqual(backgroundRefreshInterval(for: store.snapshot?.phase), 5 * 60)

    let comp1 = makeComplicationSnapshot(from: store.snapshot)
    XCTAssertEqual(comp1?.activeThreadCount, 1)
    XCTAssertEqual(comp1?.timerStartedAtMs, 1000)

    // 3. THREADS INCREASE
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 4,
      chatId: "e2e-deploy",
      chatTitle: "E2E Deploy",
      deepLink: "remotecode-mobile://e2e-deploy",
      phase: "running",
      startedAtMs: 1000,
      updatedAtMs: 10000
    )))
    history.addOrUpdate(snapshot: store.snapshot!)

    p = store.currentPresentation()
    XCTAssertEqual(p.activeCountLabel, "4 active threads")
    XCTAssertNil(store.lastTransition?.hapticType) // same phase

    // 4. FINALIZING
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 1,
      chatId: "e2e-deploy",
      chatTitle: "E2E Deploy",
      deepLink: "remotecode-mobile://e2e-deploy",
      finalizingThreadCount: 1,
      phase: "finalizing",
      startedAtMs: 1000,
      updatedAtMs: 50000
    )))
    history.addOrUpdate(snapshot: store.snapshot!)

    XCTAssertEqual(store.lastTransition?.oldPhase, .running)
    XCTAssertEqual(store.lastTransition?.newPhase, .finalizing)
    XCTAssertNil(store.lastTransition?.hapticType)
    XCTAssertEqual(backgroundRefreshInterval(for: store.snapshot?.phase), 2 * 60)

    // 5. COMPLETED
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 0,
      chatId: "e2e-deploy",
      chatTitle: "E2E Deploy",
      deepLink: "remotecode-mobile://e2e-deploy",
      elapsedSecondsSnapshot: 60,
      phase: "completed",
      startedAtMs: 1000,
      updatedAtMs: 61000
    )))
    history.addOrUpdate(snapshot: store.snapshot!)

    p = store.currentPresentation()
    XCTAssertEqual(p.badgeTitle, "Completed")
    XCTAssertEqual(p.badgeStyle, .normal)
    XCTAssertEqual(p.timerState, .frozen(seconds: 60))
    XCTAssertEqual(store.lastTransition?.hapticType, .success)
    XCTAssertTrue(store.lastTransition?.shouldNotify == true)
    XCTAssertNil(backgroundRefreshInterval(for: store.snapshot?.phase))

    let notification = makeNotificationContent(
      chatId: store.snapshot!.chatId,
      chatTitle: store.snapshot!.chatTitle,
      phase: store.snapshot!.phase
    )
    XCTAssertEqual(notification?.title, "Session Completed")
    XCTAssertTrue(notification?.body.contains("E2E Deploy") == true)

    let comp2 = makeComplicationSnapshot(from: store.snapshot)
    XCTAssertTrue(comp2!.isTerminal)
    XCTAssertEqual(comp2?.timerFrozenSeconds, 60)

    // 6. CHECK HISTORY
    XCTAssertEqual(history.history.count, 1)
    XCTAssertEqual(history.history[0].chatId, "e2e-deploy")
    XCTAssertEqual(history.history[0].phase, .completed)
    XCTAssertEqual(history.history[0].elapsedSeconds, 60)

    // 7. STALENESS CHECK
    let staleness = computeStaleness(updatedAtMs: p.updatedAtMs, nowMs: 181000) // 2 min later
    XCTAssertEqual(staleness.label, "Updated 2m ago")
    XCTAssertTrue(staleness.isStale)

    // 8. CLEAR
    XCTAssertTrue(store.applySnapshotJSONString(nil))
    p = store.currentPresentation()
    XCTAssertEqual(p.badgeTitle, "Idle")
    XCTAssertNil(p.deepLink)
    XCTAssertNil(p.updatedAtMs)

    // History persists after clear
    XCTAssertEqual(history.history.count, 1)

    defaults.removePersistentDomain(forName: suiteName)
  }

  func testSessionFailureWithAllFeatures() {
    let suiteName = "test.e2e.fail.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let store = WatchSnapshotStateStore()
    let history = WatchSessionHistoryStore(defaults: defaults)

    // Start
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      chatId: "fail-build",
      chatTitle: "Build CI",
      phase: "running",
      updatedAtMs: 1000
    )))
    history.addOrUpdate(snapshot: store.snapshot!)

    // Fail
    XCTAssertTrue(store.applySnapshotJSONString(makeSnapshotJSON(
      activeThreadCount: 0,
      chatId: "fail-build",
      chatTitle: "Build CI",
      elapsedSecondsSnapshot: 20,
      phase: "failed",
      preview: "Exit code 1",
      updatedAtMs: 21000
    )))
    history.addOrUpdate(snapshot: store.snapshot!)

    let p = store.currentPresentation()
    XCTAssertEqual(p.badgeTitle, "Failed")
    XCTAssertEqual(p.badgeStyle, .error)
    XCTAssertEqual(store.lastTransition?.hapticType, .failure)
    XCTAssertTrue(store.lastTransition?.shouldNotify == true)

    let notification = makeNotificationContent(
      chatId: "fail-build",
      chatTitle: "Build CI",
      phase: .failed
    )
    XCTAssertEqual(notification?.title, "Session Failed")

    XCTAssertEqual(history.history[0].phase, .failed)

    defaults.removePersistentDomain(forName: suiteName)
  }
}
