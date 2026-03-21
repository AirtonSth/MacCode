import XCTest

private func makeSnapshot(
  activeThreadCount: Int = 1,
  chatId: String = "chat-1",
  chatTitle: String = "Test Chat",
  deepLink: String = "remotecode-mobile://test",
  elapsedSecondsSnapshot: Int? = nil,
  finalizingThreadCount: Int = 0,
  phase: LiveActivitySharedPhase = .running,
  preview: String = "Working...",
  runningThreadCount: Int = 1,
  schemaVersion: Int = 1,
  startedAtMs: Int = 1000,
  statusLine: String = "active",
  updatedAtMs: Int = 2000
) -> LiveActivitySharedSnapshot {
  LiveActivitySharedSnapshot(
    activeThreadCount: activeThreadCount,
    chatId: chatId,
    chatTitle: chatTitle,
    deepLink: deepLink,
    elapsedSecondsSnapshot: elapsedSecondsSnapshot,
    finalizingThreadCount: finalizingThreadCount,
    phase: phase,
    preview: preview,
    runningThreadCount: runningThreadCount,
    schemaVersion: schemaVersion,
    startedAtMs: startedAtMs,
    statusLine: statusLine,
    updatedAtMs: updatedAtMs
  )
}

final class WatchSessionHistoryStoreTests: XCTestCase {

  private func makeSuiteDefaults() -> (UserDefaults, String) {
    let name = "test.history.\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
  }

  // MARK: - Basic Operations

  func testEmptyHistoryOnInit() {
    let (defaults, name) = makeSuiteDefaults()
    let store = WatchSessionHistoryStore(defaults: defaults)
    XCTAssertTrue(store.history.isEmpty)
    defaults.removePersistentDomain(forName: name)
  }

  func testAddSnapshotCreatesHistoryEntry() {
    let (defaults, name) = makeSuiteDefaults()
    let store = WatchSessionHistoryStore(defaults: defaults)

    store.addOrUpdate(snapshot: makeSnapshot(chatId: "c1", chatTitle: "Chat 1"))
    XCTAssertEqual(store.history.count, 1)
    XCTAssertEqual(store.history[0].chatId, "c1")
    XCTAssertEqual(store.history[0].chatTitle, "Chat 1")
    XCTAssertEqual(store.history[0].phase, .running)

    defaults.removePersistentDomain(forName: name)
  }

  func testUpdateExistingSession() {
    let (defaults, name) = makeSuiteDefaults()
    let store = WatchSessionHistoryStore(defaults: defaults)

    store.addOrUpdate(snapshot: makeSnapshot(chatId: "c1", phase: .running))
    store.addOrUpdate(snapshot: makeSnapshot(
      chatId: "c1",
      elapsedSecondsSnapshot: 60,
      phase: .completed,
      updatedAtMs: 61000
    ))

    XCTAssertEqual(store.history.count, 1)
    XCTAssertEqual(store.history[0].phase, .completed)
    XCTAssertEqual(store.history[0].elapsedSeconds, 60)
    XCTAssertEqual(store.history[0].endedAtMs, 61000)

    defaults.removePersistentDomain(forName: name)
  }

  func testRunningSessionHasNoEndTime() {
    let (defaults, name) = makeSuiteDefaults()
    let store = WatchSessionHistoryStore(defaults: defaults)

    store.addOrUpdate(snapshot: makeSnapshot(chatId: "c1", phase: .running))
    XCTAssertNil(store.history[0].endedAtMs)

    defaults.removePersistentDomain(forName: name)
  }

  // MARK: - History Cap

  func testMaxFiveEntries() {
    let (defaults, name) = makeSuiteDefaults()
    let store = WatchSessionHistoryStore(defaults: defaults)

    for i in 1...7 {
      store.addOrUpdate(snapshot: makeSnapshot(
        chatId: "chat-\(i)",
        chatTitle: "Chat \(i)"
      ))
    }

    XCTAssertEqual(store.history.count, 5)
    XCTAssertEqual(store.history[0].chatId, "chat-7")
    XCTAssertEqual(store.history[4].chatId, "chat-3")

    defaults.removePersistentDomain(forName: name)
  }

  // MARK: - Persistence

  func testPersistsAndRestoresFromDefaults() {
    let (defaults, name) = makeSuiteDefaults()

    let store1 = WatchSessionHistoryStore(defaults: defaults)
    store1.addOrUpdate(snapshot: makeSnapshot(chatId: "c1", chatTitle: "Persisted"))

    let store2 = WatchSessionHistoryStore(defaults: defaults)
    XCTAssertEqual(store2.history.count, 1)
    XCTAssertEqual(store2.history[0].chatTitle, "Persisted")

    defaults.removePersistentDomain(forName: name)
  }

  func testClearRemovesAllHistory() {
    let (defaults, name) = makeSuiteDefaults()
    let store = WatchSessionHistoryStore(defaults: defaults)

    store.addOrUpdate(snapshot: makeSnapshot(chatId: "c1"))
    store.addOrUpdate(snapshot: makeSnapshot(chatId: "c2"))
    XCTAssertEqual(store.history.count, 2)

    store.clear()
    XCTAssertTrue(store.history.isEmpty)

    let store2 = WatchSessionHistoryStore(defaults: defaults)
    XCTAssertTrue(store2.history.isEmpty)

    defaults.removePersistentDomain(forName: name)
  }

  // MARK: - Multiple Sessions Lifecycle

  func testMultipleSessionsTrackedIndependently() {
    let (defaults, name) = makeSuiteDefaults()
    let store = WatchSessionHistoryStore(defaults: defaults)

    store.addOrUpdate(snapshot: makeSnapshot(chatId: "c1", chatTitle: "A", phase: .running))
    store.addOrUpdate(snapshot: makeSnapshot(chatId: "c2", chatTitle: "B", phase: .running))
    store.addOrUpdate(snapshot: makeSnapshot(
      chatId: "c1",
      chatTitle: "A",
      elapsedSecondsSnapshot: 30,
      phase: .completed
    ))

    XCTAssertEqual(store.history.count, 2)

    let c1 = store.history.first(where: { $0.chatId == "c1" })
    let c2 = store.history.first(where: { $0.chatId == "c2" })

    XCTAssertEqual(c1?.phase, .completed)
    XCTAssertEqual(c2?.phase, .running)

    defaults.removePersistentDomain(forName: name)
  }
}
