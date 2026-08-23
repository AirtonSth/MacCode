import XCTest
import SQLite3

@testable import Persistence
@testable import Surfaces

@MainActor
final class TerminalHistoryRetentionCadenceTests: XCTestCase {
  private enum TestTimeout: Error {
    case expired
  }

  private let chunkBytes = 64 * 1024

  func testRetentionChecksFirstChunkThenExplicitFinalResidualAfterDrain() throws {
    let fixture = try makeFixture(name: "cadence-final")
    defer { fixture.cleanup() }
    let counter = TerminalRetentionStatementCounter()
    fixture.database.beforeStatementStepForTesting = counter.observe
    defer { fixture.database.beforeStatementStepForTesting = nil }

    let coordinator = TerminalHistoryCoordinator(
      repository: fixture.repository,
      surfaceID: fixture.surfaceID,
      workspaceID: fixture.workspaceID
    )
    coordinator.prepare(restored: false)
    try waitForPreparation(coordinator)
    counter.reset()

    coordinator.enqueue(Data(repeating: 0x41, count: chunkBytes))
    try waitForDrain(coordinator)
    XCTAssertEqual(counter.snapshot().surfaceSUMCalls, 1,
                   "the per-surface hard cap must be checked after every write")
    XCTAssertEqual(counter.snapshot().globalPruneCalls, 1,
                   "the first persisted chunk must establish retention immediately")

    coordinator.enqueue(Data(repeating: 0x42, count: chunkBytes))
    try waitForDrain(coordinator)
    XCTAssertEqual(counter.snapshot().surfaceSUMCalls, 2,
                   "global scan cadence must not weaken the per-surface hard cap")
    XCTAssertEqual(counter.snapshot().globalPruneCalls, 1,
                   "a second 64 KiB chunk must not repeat a 1 MiB global scan")

    counter.reset()
    let barrier = coordinator.flushBarrier(finalizing: true)
    try waitForBarrier(barrier)
    let finalCounts = counter.snapshot()
    XCTAssertEqual(finalCounts.surfaceSUMCalls, 1)
    XCTAssertEqual(finalCounts.globalPruneCalls, 1,
                   "the final barrier must check a drained tail smaller than the interval")
    XCTAssertEqual(
      try fixture.repository.totalBytes(surfaceID: fixture.surfaceID),
      2 * chunkBytes
    )
  }

  func testFinalBarrierDoesNotCompleteWhileItsDrainedTailRetentionCheckIsBlocked() throws {
    let fixture = try makeFixture(name: "concurrent-final")
    defer { fixture.cleanup() }
    let initialCounter = TerminalRetentionStatementCounter()
    fixture.database.beforeStatementStepForTesting = initialCounter.observe
    defer { fixture.database.beforeStatementStepForTesting = nil }

    let coordinator = TerminalHistoryCoordinator(
      repository: fixture.repository,
      surfaceID: fixture.surfaceID,
      workspaceID: fixture.workspaceID
    )
    coordinator.prepare(restored: false)
    try waitForPreparation(coordinator)
    initialCounter.reset()
    coordinator.enqueue(Data(repeating: 0x43, count: chunkBytes))
    try waitForDrain(coordinator)
    coordinator.enqueue(Data(repeating: 0x44, count: chunkBytes))
    try waitForDrain(coordinator)

    let finalCheckStarted = DispatchSemaphore(value: 0)
    let allowFinalCheck = DispatchSemaphore(value: 0)
    let hookLock = NSLock()
    var blocked = false
    fixture.database.beforeStatementStepForTesting = { sql in
      guard TerminalRetentionStatementCounter.isGlobalSUM(sql) else { return }
      hookLock.lock()
      let shouldBlock = !blocked
      blocked = true
      hookLock.unlock()
      guard shouldBlock else { return }
      finalCheckStarted.signal()
      _ = allowFinalCheck.wait(timeout: .now() + 5)
    }
    defer { allowFinalCheck.signal() }

    let barrier = coordinator.flushBarrier(finalizing: true)
    XCTAssertEqual(
      finalCheckStarted.wait(timeout: .now() + 2),
      .success,
      "finalization must enqueue a real retention check even after the last chunk drained"
    )
    XCTAssertFalse(
      barrier.wait(until: .now()),
      "the final barrier must remain open until its serial SQLite retention check completes"
    )
    allowFinalCheck.signal()
    try waitForBarrier(barrier)
  }

  func testFinalResidualEnforcesHardCapAndKeepsNewestChunk() throws {
    let fixture = try makeFixture(name: "hard-cap")
    defer { fixture.cleanup() }
    let originalOldestMarker = Data("RC2_RETENTION_OLDEST\n".utf8)
    let preexistingChunks =
      (TerminalHistoryCoordinator.maxPersistedBytes - chunkBytes) / chunkBytes
    for index in 0..<preexistingChunks {
      var data = Data(repeating: 0x4f, count: chunkBytes)
      if index == 0 {
        data.replaceSubrange(0..<originalOldestMarker.count, with: originalOldestMarker)
      }
      try fixture.repository.append(
        surfaceID: fixture.surfaceID,
        workspaceID: fixture.workspaceID,
        chunkIndex: Int64(index + 1),
        data: data
      )
    }

    let coordinator = TerminalHistoryCoordinator(
      repository: fixture.repository,
      surfaceID: fixture.surfaceID,
      workspaceID: fixture.workspaceID
    )
    coordinator.prepare(restored: false)
    try waitForPreparation(coordinator)
    coordinator.enqueue(Data(repeating: 0x50, count: chunkBytes))
    try waitForDrain(coordinator)

    let newestMarker = Data("RC2_RETENTION_NEWEST\n".utf8)
    var newest = Data(repeating: 0x4e, count: chunkBytes)
    newest.replaceSubrange(0..<newestMarker.count, with: newestMarker)
    coordinator.enqueue(newest)
    try waitForDrain(coordinator)
    XCTAssertLessThanOrEqual(
      try fixture.repository.totalBytes(surfaceID: fixture.surfaceID),
      TerminalHistoryCoordinator.maxPersistedBytes,
      "a drained live write must not leave the surface above its hard cap"
    )

    try waitForBarrier(coordinator.flushBarrier(finalizing: true))
    XCTAssertLessThanOrEqual(
      try fixture.repository.totalBytes(surfaceID: fixture.surfaceID),
      TerminalHistoryCoordinator.maxPersistedBytes
    )
    let retained = try fixture.repository.readWindow(
      surfaceID: fixture.surfaceID,
      maxBytes: TerminalHistoryCoordinator.maxPersistedBytes
    )
    XCTAssertEqual(retained.chunks.first?.chunkIndex, 2,
                   "retention must delete the oldest chunk first")
    XCTAssertNotNil(retained.chunks.last?.data.range(of: newestMarker),
                  "the newest drained chunk must survive final retention")
    XCTAssertEqual(
      try fixture.repository.partialHistoryState(surfaceID: fixture.surfaceID)?.reason,
      "history_retention_cap"
    )
  }

  func testSurfaceHardCapReclaimsMoreThanOneSmallChunkQuantumAfterEveryWrite() throws {
    let fixture = try makeFixture(name: "many-small-chunks")
    defer { fixture.cleanup() }
    let smallChunkCount = 1024
    let smallChunkBytes = 64
    for index in 0..<smallChunkCount {
      try fixture.repository.append(
        surfaceID: fixture.surfaceID,
        workspaceID: fixture.workspaceID,
        chunkIndex: Int64(index + 1),
        data: Data(repeating: 0x61, count: smallChunkBytes)
      )
    }
    try fixture.repository.append(
      surfaceID: fixture.surfaceID,
      workspaceID: fixture.workspaceID,
      chunkIndex: Int64(smallChunkCount + 1),
      data: Data(
        repeating: 0x62,
        count: TerminalHistoryCoordinator.maxPersistedBytes
          - (smallChunkCount * smallChunkBytes)
      )
    )

    let coordinator = TerminalHistoryCoordinator(
      repository: fixture.repository,
      surfaceID: fixture.surfaceID,
      workspaceID: fixture.workspaceID
    )
    coordinator.prepare(restored: false)
    try waitForPreparation(coordinator)
    coordinator.enqueue(Data(repeating: 0x63, count: chunkBytes))
    try waitForDrain(coordinator)

    XCTAssertEqual(
      try fixture.repository.totalBytes(surfaceID: fixture.surfaceID),
      TerminalHistoryCoordinator.maxPersistedBytes,
      "a write must reclaim every required 512-row quantum before it completes"
    )
    XCTAssertEqual(
      try fixture.repository.readWindow(
        surfaceID: fixture.surfaceID,
        maxBytes: TerminalHistoryCoordinator.maxPersistedBytes + chunkBytes
      ).chunks.map(\.chunkIndex),
      [Int64(smallChunkCount + 1), Int64(smallChunkCount + 2)],
      "multi-quantum retention must preserve the large tail and newest write"
    )
  }

  func testSubIntervalWriteCrossingGlobalCapPrunesBeforeDrainCompletes() throws {
    let fixture = try makeFixture(name: "global-hard-cap")
    defer { fixture.cleanup() }
    let globalCap = 3 * chunkBytes
    let coordinator = TerminalHistoryCoordinator(
      repository: fixture.repository,
      surfaceID: fixture.surfaceID,
      workspaceID: fixture.workspaceID,
      globalRetentionByteCapForTesting: globalCap
    )
    coordinator.prepare(restored: false)
    try waitForPreparation(coordinator)

    coordinator.enqueue(Data(repeating: 0x51, count: chunkBytes))
    try waitForDrain(coordinator)
    let dormantSurfaceID = UUID().uuidString
    try fixture.repository.append(
      surfaceID: dormantSurfaceID,
      workspaceID: fixture.workspaceID,
      chunkIndex: 1,
      data: Data(repeating: 0x52, count: chunkBytes)
    )
    try fixture.repository.append(
      surfaceID: dormantSurfaceID,
      workspaceID: fixture.workspaceID,
      chunkIndex: 2,
      data: Data(repeating: 0x53, count: chunkBytes)
    )

    coordinator.enqueue(Data(repeating: 0x54, count: chunkBytes))
    try waitForDrain(coordinator)

    XCTAssertLessThanOrEqual(
      try fixture.repository.totalBytesAllSurfaces(),
      globalCap,
      "a sub-interval live write must force global retention at the hard cap"
    )
    XCTAssertEqual(
      try fixture.repository.readWindow(surfaceID: fixture.surfaceID).chunks.map(\.chunkIndex),
      [1, 2],
      "global pruning must protect the active writer and its newest chunk"
    )
    XCTAssertEqual(
      try fixture.repository.partialHistoryState(surfaceID: dormantSurfaceID)?.reason,
      "history_global_retention_cap"
    )
  }

  func testPrepareGlobalMaintenanceKeepsCustomCapAcrossDeleteQuanta() throws {
    let fixture = try makeFixture(name: "prepare-global-quanta")
    defer { fixture.cleanup() }
    let dormantSurfaceID = UUID().uuidString
    let dormantChunkBytes = 1024
    for index in 0..<300 {
      try fixture.repository.append(
        surfaceID: dormantSurfaceID,
        workspaceID: fixture.workspaceID,
        chunkIndex: Int64(index + 1),
        data: Data(repeating: 0x58, count: dormantChunkBytes)
      )
    }
    let globalCap = 32 * dormantChunkBytes
    let coordinator = TerminalHistoryCoordinator(
      repository: fixture.repository,
      surfaceID: fixture.surfaceID,
      workspaceID: fixture.workspaceID,
      globalRetentionByteCapForTesting: globalCap
    )
    coordinator.prepare(restored: false)
    try waitForPreparation(coordinator)

    let deadline = Date().addingTimeInterval(2)
    while try fixture.repository.totalBytesAllSurfaces() > globalCap, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertLessThanOrEqual(
      try fixture.repository.totalBytesAllSurfaces(),
      globalCap,
      "every prepare maintenance quantum must keep the coordinator's effective cap"
    )
  }

  func testGlobalEstimateIsSharedAcrossRepositoriesAndDeleteOrReopenFailsClosed() throws {
    let fixture = try makeFixture(name: "shared-global-estimate")
    defer { fixture.cleanup() }
    let compatibleResult = TerminalHistoryGlobalPruneResult(
      deletedRows: 0,
      deletedBytes: 0,
      truncatedSurfaceIDs: [],
      remainsOverBudget: false
    )
    XCTAssertFalse(compatibleResult.remainsOverBudget,
                   "the established public initializer must remain source-compatible")
    let secondRepository = TerminalOutputRepository(db: fixture.database)
    try fixture.repository.append(
      surfaceID: fixture.surfaceID,
      workspaceID: fixture.workspaceID,
      chunkIndex: 1,
      data: Data(repeating: 0x56, count: chunkBytes)
    )
    _ = try fixture.repository.pruneGlobalByteCapAndMarkHistoryPartial(
      maxBytes: 10 * chunkBytes,
      protectedSurfaceID: fixture.surfaceID
    )
    XCTAssertFalse(fixture.repository.terminalGlobalRetentionRequired(maxBytes: chunkBytes))

    let secondSurfaceID = UUID().uuidString
    try secondRepository.append(
      surfaceID: secondSurfaceID,
      workspaceID: fixture.workspaceID,
      chunkIndex: 1,
      data: Data(repeating: 0x57, count: chunkBytes)
    )
    XCTAssertTrue(
      fixture.repository.terminalGlobalRetentionRequired(maxBytes: chunkBytes),
      "a repository sharing the SQLite authority must advance the same estimate"
    )

    _ = try fixture.repository.pruneGlobalByteCapAndMarkHistoryPartial(
      maxBytes: 10 * chunkBytes,
      protectedSurfaceID: fixture.surfaceID
    )
    XCTAssertFalse(secondRepository.terminalGlobalRetentionRequired(maxBytes: 10 * chunkBytes))
    try secondRepository.delete(surfaceID: secondSurfaceID)
    XCTAssertTrue(
      fixture.repository.terminalGlobalRetentionRequired(maxBytes: 10 * chunkBytes),
      "delete must invalidate rather than leave an estimate that another repository can trust"
    )
    _ = try fixture.repository.pruneGlobalByteCapAndMarkHistoryPartial(
      maxBytes: 0,
      protectedSurfaceID: fixture.surfaceID
    )
    XCTAssertTrue(
      fixture.repository.terminalGlobalRetentionRequired(maxBytes: Int.max),
      "a zero-cap no-op must stay unknown instead of caching a false zero total"
    )

    let reopenedDatabase = try SQLiteDB(path: fixture.database.path)
    let reopenedRepository = TerminalOutputRepository(db: reopenedDatabase)
    XCTAssertTrue(
      reopenedRepository.terminalGlobalRetentionRequired(maxBytes: Int.max),
      "a reopened connection must start unknown and reconcile against SQLite"
    )
  }

  func testFailedGlobalCheckIsRetriedByFinalBarrierWithoutResidualBytes() throws {
    let fixture = try makeFixture(name: "global-retry")
    defer { fixture.cleanup() }
    let counter = TerminalRetentionStatementCounter()
    let coordinator = TerminalHistoryCoordinator(
      repository: fixture.repository,
      surfaceID: fixture.surfaceID,
      workspaceID: fixture.workspaceID
    )
    coordinator.prepare(restored: false)
    try waitForPreparation(coordinator)
    counter.reset()
    fixture.database.beforeStatementStepForTesting = { sql in
      counter.observe(sql)
      guard TerminalRetentionStatementCounter.isGlobalSUM(sql) else { return }
      fixture.database.injectedResultCodesForTesting = [SQLITE_BUSY]
    }
    coordinator.enqueue(Data(repeating: 0x55, count: chunkBytes))
    try waitForDrain(coordinator)
    XCTAssertGreaterThan(counter.snapshot().globalPruneCalls, 0)

    counter.reset()
    fixture.database.injectedResultCodesForTesting = []
    fixture.database.beforeStatementStepForTesting = counter.observe
    let barrier = coordinator.flushBarrier(finalizing: true)
    try waitForBarrierGroups(barrier)
    XCTAssertEqual(
      counter.snapshot().globalPruneCalls,
      1,
      "finalization must retry a failed global check even when cadence bytes were consumed"
    )
    XCTAssertFalse(
      barrier.completionChecksSucceeded(),
      "the prior retention failure must remain visible to the termination barrier"
    )
  }

  private func waitForPreparation(
    _ coordinator: TerminalHistoryCoordinator,
    timeout: TimeInterval = 5
  ) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if case .ready = coordinator.preparationStateForTesting { return }
      RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    XCTFail("terminal history preparation timed out")
    throw TestTimeout.expired
  }

  private func waitForDrain(
    _ coordinator: TerminalHistoryCoordinator,
    timeout: TimeInterval = 5
  ) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while coordinator.outstandingBytes > 0, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    guard coordinator.outstandingBytes == 0 else {
      XCTFail("terminal history writer did not drain")
      throw TestTimeout.expired
    }
  }

  private func waitForBarrier(
    _ barrier: SurfaceTerminationBarrier,
    timeout: TimeInterval = 5
  ) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if barrier.wait(until: .now()) { return }
      RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    XCTFail("terminal history barrier timed out")
    throw TestTimeout.expired
  }

  private func waitForBarrierGroups(
    _ barrier: SurfaceTerminationBarrier,
    timeout: TimeInterval = 5
  ) throws {
    let deadline = DispatchTime.now() + timeout
    guard barrier.waitForGroups(until: deadline) else {
      XCTFail("terminal history barrier groups timed out")
      throw TestTimeout.expired
    }
  }

  private func makeFixture(name: String) throws -> TerminalHistoryRetentionFixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RC2TerminalRetention-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try SQLiteDB(path: directory.appendingPathComponent("history.sqlite").path)
    try Schema.migrate(database)
    return TerminalHistoryRetentionFixture(
      directory: directory,
      database: database,
      repository: TerminalOutputRepository(db: database),
      surfaceID: UUID().uuidString,
      workspaceID: UUID().uuidString
    )
  }
}

private struct TerminalHistoryRetentionFixture {
  let directory: URL
  let database: SQLiteDB
  let repository: TerminalOutputRepository
  let surfaceID: String
  let workspaceID: String

  func cleanup() {
    database.beforeStatementStepForTesting = nil
    try? FileManager.default.removeItem(at: directory)
  }
}

private final class TerminalRetentionStatementCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var surfaceSUMCalls = 0
  private var globalPruneCalls = 0

  func observe(_ sql: String) {
    let isSurface = Self.isSurfaceSUM(sql)
    let isGlobal = Self.isGlobalSUM(sql)
    guard isSurface || isGlobal else { return }
    lock.lock()
    if isSurface { surfaceSUMCalls += 1 }
    if isGlobal { globalPruneCalls += 1 }
    lock.unlock()
  }

  func reset() {
    lock.lock()
    surfaceSUMCalls = 0
    globalPruneCalls = 0
    lock.unlock()
  }

  func snapshot() -> (surfaceSUMCalls: Int, globalPruneCalls: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (surfaceSUMCalls, globalPruneCalls)
  }

  static func isSurfaceSUM(_ sql: String) -> Bool {
    sql.contains("SELECT COALESCE(SUM(byte_count), 0) FROM terminal_output_chunks WHERE surface_id = ?")
  }

  static func isGlobalSUM(_ sql: String) -> Bool {
    sql.contains("SELECT COALESCE(SUM(byte_count), 0) FROM terminal_output_chunks;")
  }
}
