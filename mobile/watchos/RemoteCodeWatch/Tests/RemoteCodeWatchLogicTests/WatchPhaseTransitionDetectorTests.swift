import XCTest

final class WatchPhaseTransitionDetectorTests: XCTestCase {

  // MARK: - No Transition (Same Phase)

  func testSamePhaseNoTransition() {
    let t = detectPhaseTransition(oldPhase: .running, newPhase: .running)
    XCTAssertNil(t.hapticType)
    XCTAssertFalse(t.shouldNotify)
  }

  func testBothNilNoTransition() {
    let t = detectPhaseTransition(oldPhase: nil, newPhase: nil)
    XCTAssertNil(t.hapticType)
    XCTAssertFalse(t.shouldNotify)
  }

  // MARK: - Haptic: Success

  func testRunningToCompletedTriggersSuccess() {
    let t = detectPhaseTransition(oldPhase: .running, newPhase: .completed)
    XCTAssertEqual(t.hapticType, .success)
    XCTAssertTrue(t.shouldNotify)
  }

  func testFinalizingToCompletedTriggersSuccess() {
    let t = detectPhaseTransition(oldPhase: .finalizing, newPhase: .completed)
    XCTAssertEqual(t.hapticType, .success)
    XCTAssertTrue(t.shouldNotify)
  }

  func testNilToCompletedTriggersSuccess() {
    let t = detectPhaseTransition(oldPhase: nil, newPhase: .completed)
    XCTAssertEqual(t.hapticType, .success)
    XCTAssertTrue(t.shouldNotify)
  }

  // MARK: - Haptic: Failure

  func testRunningToFailedTriggersFailure() {
    let t = detectPhaseTransition(oldPhase: .running, newPhase: .failed)
    XCTAssertEqual(t.hapticType, .failure)
    XCTAssertTrue(t.shouldNotify)
  }

  func testRunningToErrorTriggersFailure() {
    let t = detectPhaseTransition(oldPhase: .running, newPhase: .error)
    XCTAssertEqual(t.hapticType, .failure)
    XCTAssertTrue(t.shouldNotify)
  }

  // MARK: - No Haptic for Non-Terminal Transitions

  func testNilToRunningNoHaptic() {
    let t = detectPhaseTransition(oldPhase: nil, newPhase: .running)
    XCTAssertNil(t.hapticType)
    XCTAssertFalse(t.shouldNotify)
  }

  func testRunningToFinalizingNoHaptic() {
    let t = detectPhaseTransition(oldPhase: .running, newPhase: .finalizing)
    XCTAssertNil(t.hapticType)
    XCTAssertFalse(t.shouldNotify)
  }

  func testRunningToBackgroundNoHaptic() {
    let t = detectPhaseTransition(oldPhase: .running, newPhase: .background)
    XCTAssertNil(t.hapticType)
    XCTAssertFalse(t.shouldNotify)
  }

  func testRunningToNilNoHaptic() {
    let t = detectPhaseTransition(oldPhase: .running, newPhase: nil)
    XCTAssertNil(t.hapticType)
    XCTAssertFalse(t.shouldNotify)
  }

  // MARK: - Phase Values Passed Through

  func testTransitionCarriesOldAndNewPhase() {
    let t = detectPhaseTransition(oldPhase: .running, newPhase: .completed)
    XCTAssertEqual(t.oldPhase, .running)
    XCTAssertEqual(t.newPhase, .completed)
  }
}

// MARK: - Notification Content Tests

final class WatchNotificationContentTests: XCTestCase {
  func testCompletedNotification() {
    let content = makeNotificationContent(chatId: "c1", chatTitle: "Deploy", phase: .completed)
    XCTAssertNotNil(content)
    XCTAssertEqual(content?.identifier, "c1")
    XCTAssertEqual(content?.title, "Session Completed")
    XCTAssertTrue(content?.body.contains("Deploy") == true)
  }

  func testFailedNotification() {
    let content = makeNotificationContent(chatId: "c2", chatTitle: "Build", phase: .failed)
    XCTAssertNotNil(content)
    XCTAssertEqual(content?.title, "Session Failed")
  }

  func testErrorNotification() {
    let content = makeNotificationContent(chatId: "c3", chatTitle: "Test", phase: .error)
    XCTAssertNotNil(content)
    XCTAssertEqual(content?.title, "Session Error")
  }

  func testRunningReturnsNil() {
    XCTAssertNil(makeNotificationContent(chatId: "c4", chatTitle: "Run", phase: .running))
  }

  func testFinalizingReturnsNil() {
    XCTAssertNil(makeNotificationContent(chatId: "c5", chatTitle: "Fin", phase: .finalizing))
  }

  func testBackgroundReturnsNil() {
    XCTAssertNil(makeNotificationContent(chatId: "c6", chatTitle: "Bg", phase: .background))
  }

  func testNotificationUsedChatIdAsIdentifierForDedup() {
    let c1 = makeNotificationContent(chatId: "same-id", chatTitle: "A", phase: .completed)
    let c2 = makeNotificationContent(chatId: "same-id", chatTitle: "B", phase: .failed)
    XCTAssertEqual(c1?.identifier, c2?.identifier)
  }
}
