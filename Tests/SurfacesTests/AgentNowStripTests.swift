import XCTest
import Combine
@testable import Surfaces

/// Tests for the Titio "Now" strip model.
///
/// WHY per test:
///  - Cached snapshot must show before the first load finishes, so the strip
///    never flashes empty on appear.
///  - A→B race: an older slow load must never overwrite a newer fast one.
///  - Failure keeps the last good snapshot; faking an empty strip hides running work.
///  - A burst of Activity changes must collapse to one reload, not one per event.
@MainActor
final class AgentNowStripTests: XCTestCase {

  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
      lock.lock(); defer { lock.unlock() }
      value += 1
      return value
    }
    var current: Int {
      lock.lock(); defer { lock.unlock() }
      return value
    }
  }

  private struct LoadFailure: Error {}

  private func snapshot(running: Int, needsYou: Int = 0) -> AgentNowStripSnapshot {
    let items = (0..<running).map {
      AgentNowStripItem(id: "r\($0)", state: .running, title: "Run \($0)", subtitle: nil, startedAt: nil)
    }
    return AgentNowStripSnapshot(running: running, needsYou: needsYou, items: items)
  }

  private func source(
    changes: AnyPublisher<Void, Never> = Empty<Void, Never>().eraseToAnyPublisher(),
    load: @escaping @Sendable () async throws -> AgentNowStripSnapshot
  ) -> AgentNowStripSource {
    AgentNowStripSource(load: load, changes: changes, open: { _ in })
  }

  private func waitUntil(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  func testCachedSnapshotVisibleBeforeLoadCompletes() async {
    let cached = snapshot(running: 1)
    let fresh = snapshot(running: 3)
    let model = AgentNowStripModel(
      source: source { try await Task.sleep(nanoseconds: 300_000_000); return fresh },
      cached: cached
    )

    model.refresh()
    XCTAssertEqual(model.snapshot, cached, "cached data must render before the load resolves")

    await waitUntil { model.snapshot == fresh }
    XCTAssertEqual(model.snapshot, fresh, "eventual load must replace the cache")
  }

  func testRaceSlowOlderLoadNeverOverwritesNewerLoad() async {
    let calls = Counter()
    let slow = snapshot(running: 1)
    let fast = snapshot(running: 2)
    let model = AgentNowStripModel(source: source {
      if calls.next() == 1 {
        try await Task.sleep(nanoseconds: 300_000_000)
        return slow
      }
      return fast
    })

    model.refresh()
    await waitUntil { calls.current == 1 }
    model.refresh()
    await waitUntil { model.snapshot == fast }
    try? await Task.sleep(nanoseconds: 400_000_000)

    XCTAssertEqual(model.snapshot, fast, "stale slow response must be rejected after newer one applied")
  }

  func testStaleLoadNeverReachesOnAccept() async {
    // WHY: owners commit caches (and routing) in onAccept; a stale A landing after B
    // must not overwrite them.
    let calls = Counter()
    let slow = snapshot(running: 1)
    let fast = snapshot(running: 2)
    var accepted: [AgentNowStripSnapshot] = []
    let src = AgentNowStripSource(
      load: {
        if calls.next() == 1 {
          try await Task.sleep(nanoseconds: 300_000_000)
          return slow
        }
        return fast
      },
      changes: Empty<Void, Never>().eraseToAnyPublisher(),
      open: { _ in },
      onAccept: { accepted.append($0) }
    )
    let model = AgentNowStripModel(source: src)

    model.refresh()
    await waitUntil { calls.current == 1 }
    model.refresh()
    await waitUntil { model.snapshot == fast }
    try? await Task.sleep(nanoseconds: 400_000_000)

    XCTAssertEqual(accepted, [fast], "only the accepted load may reach onAccept")
  }

  func testFailureKeepsPreviousSnapshotAndSetsError() async {
    let calls = Counter()
    let good = snapshot(running: 2)
    let model = AgentNowStripModel(source: source {
      if calls.next() == 1 { return good }
      throw LoadFailure()
    })

    model.refresh()
    await waitUntil { model.snapshot == good }
    model.refresh()
    await waitUntil { model.lastError != nil }

    XCTAssertEqual(model.snapshot, good, "failed refresh must not clear last good list")
    XCTAssertNotNil(model.lastError, "failure must be surfaced, not hidden")
  }

  func testChangeBurstCoalescesToSingleRefresh() async {
    let calls = Counter()
    let changes = PassthroughSubject<Void, Never>()
    let model = AgentNowStripModel(source: source(changes: changes.eraseToAnyPublisher()) {
      _ = calls.next()
      return AgentNowStripSnapshot(running: 0, needsYou: 0, items: [])
    })

    model.start()
    await waitUntil { calls.current == 1 }
    for _ in 0..<5 { changes.send() }
    try? await Task.sleep(nanoseconds: 500_000_000)

    XCTAssertEqual(calls.current, 2, "burst of 5 changes must yield one debounced reload beyond the initial load")
    model.stop()
  }

  func testElapsedLabelFormatsSecondsMinutesHours() {
    let now = Date(timeIntervalSinceReferenceDate: 100_000)
    XCTAssertEqual(AgentNowStrip.elapsedLabel(from: now.addingTimeInterval(-12), now: now), "12s")
    XCTAssertEqual(AgentNowStrip.elapsedLabel(from: now.addingTimeInterval(-240), now: now), "4m")
    XCTAssertEqual(AgentNowStrip.elapsedLabel(from: now.addingTimeInterval(-3700), now: now), "1h")
  }

  func testSummaryOmitsZeroPartsAndPluralizes() {
    XCTAssertEqual(AgentNowStrip.summary(snapshot(running: 2, needsYou: 1)), "2 running · 1 needs you")
    XCTAssertEqual(AgentNowStrip.summary(snapshot(running: 1)), "1 running")
    XCTAssertEqual(AgentNowStrip.summary(snapshot(running: 0, needsYou: 2)), "2 need you")
  }
}
