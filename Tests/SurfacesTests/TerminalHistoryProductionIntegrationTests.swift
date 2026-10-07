import XCTest

@testable import CoreModel
@testable import Persistence
@testable import Surfaces

@MainActor
final class TerminalHistoryProductionIntegrationTests: XCTestCase {
  func testSubThresholdEnqueuesCoalesceOneTimerFlush() async throws {
    // WHY: repeated PTY callbacks inside the 250 ms batching window must use
    // one delayed flush, otherwise many active terminals compete for main-actor
    // work and can persist the same pending tail in separate UI wakeups.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID().value.uuidString
    let workspaceID = WorkspaceID().value.uuidString
    let coordinator = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: workspaceID
    )
    defer {
      coordinator.beforePersistForTesting = nil
      coordinator.discardAndDeletePersistedHistory()
      _ = TerminalHistoryCoordinator.pendingFinalDeleteBarrier()?.wait(
        until: .now() + 2
      )
    }

    coordinator.prepare(restored: false)
    try await waitForPreparationAsync(coordinator, expected: .ready(nextChunkIndex: 1))
    let persistStarted = DispatchSemaphore(value: 0)
    let persistCount = LockedCounter()
    coordinator.beforePersistForTesting = {
      if persistCount.increment() == 1 {
        persistStarted.signal()
      }
    }

    coordinator.enqueue(Data("RC2_TIMER_FIRST\n".utf8))
    try await Task.sleep(nanoseconds: 50_000_000)
    coordinator.enqueue(Data("RC2_TIMER_SECOND\n".utf8))

    let deadline = Date().addingTimeInterval(2)
    while persistCount.value == 0, Date() < deadline {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertEqual(
      persistStarted.wait(timeout: .now()),
      .success,
      "the delayed timer must eventually hand the coalesced tail to the writer"
    )
    let barrier = coordinator.flushBarrier()
    let drained = await barrier.waitAsync(until: .now() + 2)
    XCTAssertTrue(drained)
    XCTAssertEqual(persistCount.value, 1)
    XCTAssertEqual(
      try repository.readWindow(surfaceID: surfaceID).text,
      "RC2_TIMER_FIRST\nRC2_TIMER_SECOND\n"
    )
  }

  func testClearBeforeFlushTimerDropsPreClearTailAndKeepsPostClearTail() async throws {
    // WHY: clear_history cancels a pending delayed flush. Its eventual timer
    // callback must not resurrect bytes that were intentionally discarded, while
    // output received after the clear remains durable exactly once.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID().value.uuidString
    let coordinator = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: WorkspaceID().value.uuidString
    )
    defer {
      coordinator.discardAndDeletePersistedHistory()
      _ = TerminalHistoryCoordinator.pendingFinalDeleteBarrier()?.wait(
        until: .now() + 2
      )
    }

    coordinator.prepare(restored: false)
    try await waitForPreparationAsync(coordinator, expected: .ready(nextChunkIndex: 1))
    coordinator.enqueue(Data("RC2_CLEAR_BEFORE_TIMER\n".utf8))
    coordinator.clearPersistedHistory()
    coordinator.enqueue(Data("RC2_CLEAR_AFTER_TIMER\n".utf8))

    let barrier = coordinator.flushBarrier()
    let cleared = await barrier.waitAsync(until: .now() + 2)
    XCTAssertTrue(cleared)
    try await Task.sleep(nanoseconds: 350_000_000)
    XCTAssertEqual(
      try repository.readWindow(surfaceID: surfaceID).text,
      "RC2_CLEAR_AFTER_TIMER\n"
    )
  }

  func testFinalizeBeforeFlushTimerDoesNotResurrectOrDuplicateTail() async throws {
    // WHY: finalization drains a sub-threshold tail immediately, then rejects
    // later output. The old delayed callback must become a no-op after that
    // drain rather than replaying or duplicating the tail.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID().value.uuidString
    let coordinator = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: WorkspaceID().value.uuidString
    )
    defer {
      coordinator.discardAndDeletePersistedHistory()
      _ = TerminalHistoryCoordinator.pendingFinalDeleteBarrier()?.wait(
        until: .now() + 2
      )
    }

    coordinator.prepare(restored: false)
    try await waitForPreparationAsync(coordinator, expected: .ready(nextChunkIndex: 1))
    let persistCount = LockedCounter()
    coordinator.beforePersistForTesting = {
      _ = persistCount.increment()
    }
    coordinator.enqueue(Data("RC2_FINALIZE_BEFORE_TIMER\n".utf8))
    let barrier = coordinator.flushBarrier(finalizing: true)
    let finalized = await barrier.waitAsync(until: .now() + 2)
    XCTAssertTrue(finalized)

    coordinator.enqueue(Data("RC2_LATE_AFTER_FINALIZE\n".utf8))
    try await Task.sleep(nanoseconds: 350_000_000)
    XCTAssertEqual(persistCount.value, 1)
    XCTAssertEqual(
      try repository.readWindow(surfaceID: surfaceID).text,
      "RC2_FINALIZE_BEFORE_TIMER\n"
    )
  }

  func testPrepareRetriesOnlyTransientLocksAndPreservesPreflightUntilAuthoritativeIndex() throws {
    // WHY: falling back to chunk 1 after a temporary lock can collide with
    // durable history and silently discard new terminal bytes.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let attempts = LockedCounter()
    let surfaceID = SurfaceID().value.uuidString
    let marker = Data("PREPARE_RETRY_PRESERVED\n".utf8)
    let coordinator = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: WorkspaceID().value.uuidString,
      prepareIndex: { _ in
        let attempt = attempts.increment()
        if attempt <= 2 { throw SQLiteError.step("database is locked") }
        return 7
      }
    )

    coordinator.prepare(restored: false)
    coordinator.enqueue(marker)
    XCTAssertEqual(coordinator.preflightBytesForTesting, marker.count)
    try waitForPreparation(coordinator, expected: .ready(nextChunkIndex: 8))
    coordinator.flush(wait: true)

    let chunks = try repository.readWindow(surfaceID: surfaceID).chunks
    XCTAssertEqual(attempts.value, 3)
    XCTAssertEqual(chunks.map(\.chunkIndex), [7])
    XCTAssertEqual(chunks.first?.data, marker)
    XCTAssertEqual(coordinator.preflightBytesForTesting, 0)
  }

  func testPrepareDoesNotRetryPermanentFailureAndReleasesPreflightAndBarrier() throws {
    // WHY: non-lock failures do not become healthier through retry. Retaining a
    // 4 MiB preflight and deferred barriers forever leaks one surface per tab.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let attempts = LockedCounter()
    let coordinator = TerminalHistoryCoordinator(
      repository: TerminalOutputRepository(db: database),
      surfaceID: SurfaceID().value.uuidString,
      workspaceID: WorkspaceID().value.uuidString,
      prepareIndex: { _ in
        _ = attempts.increment()
        throw SQLiteError.step("disk I/O error")
      }
    )

    coordinator.prepare(restored: false)
    coordinator.enqueue(Data(repeating: 0x50, count: 4 * 1024 * 1024))
    let barriers = (0..<100).map { _ in coordinator.flushBarrier() }
    XCTAssertEqual(coordinator.deferredBarrierCountForTesting, 1)
    try waitForPreparation(coordinator, expected: .failed)

    XCTAssertEqual(attempts.value, 1)
    XCTAssertEqual(coordinator.preflightBytesForTesting, 0)
    XCTAssertEqual(coordinator.outstandingBytes, 0)
    XCTAssertEqual(coordinator.deferredBarrierCountForTesting, 0)
    XCTAssertTrue(barriers.allSatisfy { !$0.wait(until: .now()) })
  }

  func testFinalizingPrepareCapsTransientRetriesAndReleasesOwnedPreflight() throws {
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let attempts = LockedCounter()
    let coordinator = TerminalHistoryCoordinator(
      repository: TerminalOutputRepository(db: database),
      surfaceID: SurfaceID().value.uuidString,
      workspaceID: WorkspaceID().value.uuidString,
      prepareIndex: { _ in
        _ = attempts.increment()
        throw SQLiteError.step("database is locked")
      }
    )
    coordinator.prepare(restored: false)
    coordinator.enqueue(Data(repeating: 0x51, count: 4 * 1024 * 1024))
    let barrier = coordinator.flushBarrier(finalizing: true, retryTimeout: 0.12)

    try waitForPreparation(coordinator, expected: .failed, timeout: 1)
    let attemptsAtFailure = attempts.value
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))

    XCTAssertFalse(barrier.wait(until: .now()))
    XCTAssertLessThanOrEqual(attemptsAtFailure, 4)
    XCTAssertEqual(attempts.value, attemptsAtFailure)
    XCTAssertEqual(coordinator.preflightBytesForTesting, 0)
    XCTAssertEqual(coordinator.outstandingBytes, 0)
  }

  func testClearRequestedDuringPrepareRotatesBeforePostClearWriteReadAndBarrier() async throws {
    // WHY: output and RPCs accepted after clear_history must never run against
    // the generation that is about to be deleted when preparation completes.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID().value.uuidString
    try repository.append(
      surfaceID: surfaceID,
      workspaceID: nil,
      chunkIndex: 1,
      data: Data("DURABLE_BEFORE_CLEAR\n".utf8)
    )
    let originalGeneration = try repository.prepareHistory(
      surfaceID: surfaceID
    ).writerGeneration
    let prepareStarted = DispatchSemaphore(value: 0)
    let allowPrepare = DispatchSemaphore(value: 0)
    let coordinator = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: WorkspaceID().value.uuidString,
      prepareIndex: { _ in
        prepareStarted.signal()
        _ = allowPrepare.wait(timeout: .now() + 3)
        return 2
      }
    )
    defer {
      allowPrepare.signal()
      coordinator.discardAndDeletePersistedHistory()
    }

    coordinator.prepare(restored: true)
    XCTAssertEqual(waitForSemaphore(prepareStarted, timeout: 2), .success)
    coordinator.enqueue(Data("OLD_PRE_CLEAR_ENQUEUE\n".utf8))
    coordinator.clearPersistedHistory()
    coordinator.enqueue(Data("NEW_POST_CLEAR_ENQUEUE\n".utf8))
    let readTask = Task { @MainActor in
      try await coordinator.readPersistedWindow(
        beforeChunkID: nil,
        maxBytes: 256 * 1024,
        timeout: 3
      )
    }
    await Task.yield()
    let barrier = coordinator.flushBarrier()
    XCTAssertFalse(barrier.wait(until: .now()))

    allowPrepare.signal()
    let clearDeadline = Date().addingTimeInterval(2)
    while coordinator.writerGenerationForTesting != nil,
          coordinator.writerGenerationForTesting == originalGeneration,
          Date() < clearDeadline {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    while coordinator.writerGenerationForTesting == nil, Date() < clearDeadline {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    try await waitForLiveClearCompletionAsync(coordinator)
    XCTAssertTrue(barrier.wait(until: .now() + 2))
    let readWindow = try await readTask.value
    let finalPreparation = try repository.prepareHistory(surfaceID: surfaceID)
    let finalText = try repository.readWindow(
      surfaceID: surfaceID,
      maxBytes: 256 * 1024
    ).text

    XCTAssertNotEqual(finalPreparation.writerGeneration, originalGeneration)
    XCTAssertFalse(finalText.contains("DURABLE_BEFORE_CLEAR"))
    XCTAssertFalse(finalText.contains("OLD_PRE_CLEAR_ENQUEUE"))
    XCTAssertTrue(finalText.contains("NEW_POST_CLEAR_ENQUEUE"))
    XCTAssertFalse(readWindow.text.contains("DURABLE_BEFORE_CLEAR"))
    XCTAssertFalse(readWindow.text.contains("OLD_PRE_CLEAR_ENQUEUE"))
    XCTAssertTrue(readWindow.text.contains("NEW_POST_CLEAR_ENQUEUE"))
  }

  func testPersistentWriteLockTerminatesRetryAndResolvesFinalBarrierFalse() throws {
    // WHY: an unbounded BUSY loop pins the serial history queue, one Data payload,
    // read_history, final delete, and every shutdown barrier behind it.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RC2TerminalPersistentLock-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("history.sqlite").path
    let database = try SQLiteDB(path: path)
    try Schema.migrate(database)
    // This test pins the coordinator's own retry chain against its finalizing
    // deadline. SQLiteDB layers its own bounded wait under every call (the
    // busy handler plus up to 8 transient-lock attempts per transaction,
    // covered by SQLiteBusyRetryTests), which the coordinator deadline cannot
    // interrupt. Make each SQLite call one immediate attempt so the timing
    // below measures the coordinator, not SQLite's busy waits.
    try database.execute("PRAGMA busy_timeout=0;")
    database.busyRetryMaxAttemptsForTesting = 1
    let lockDatabase = try SQLiteDB(path: path)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID().value.uuidString
    let coordinator = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: WorkspaceID().value.uuidString
    )
    coordinator.prepare(restored: false)
    try waitForPreparation(coordinator, expected: .ready(nextChunkIndex: 1))
    // Every history write is a BEGIN IMMEDIATE transaction, and under the lock
    // it fails before any INSERT steps, so count transaction attempts. The
    // unresolved-failure marker fallback deliberately keeps retrying on its own
    // queue until the partial marker is durable; it does not occupy the history
    // queue and is not part of the payload retry chain this test bounds.
    let attempts = LockedCounter()
    database.beforeExecuteForTesting = { sql in
      guard sql.hasPrefix("BEGIN IMMEDIATE") else { return }
      let fromUnresolvedFallback = Thread.callStackSymbols.contains {
        $0.contains("scheduleUnresolvedFailureRetry")
      }
      if !fromUnresolvedFallback {
        _ = attempts.increment()
      }
    }
    defer { database.beforeExecuteForTesting = nil }
    try lockDatabase.execute("BEGIN IMMEDIATE;")
    var lockHeld = true
    defer {
      if lockHeld { try? lockDatabase.execute("ROLLBACK;") }
      coordinator.discardAndDeletePersistedHistory()
      let cleanupBarrier = TerminalHistoryCoordinator.pendingFinalDeleteBarrier()
      XCTAssertNotNil(
        cleanupBarrier,
        "discard must publish durable final-delete ownership before returning"
      )
      XCTAssertTrue(
        cleanupBarrier?.wait(until: .now() + 2) ?? false,
        "fixture cleanup must finish its durable final delete before removing the database"
      )
      XCTAssertNil(
        TerminalHistoryCoordinator.pendingFinalDeleteBarrier(),
        "fixture cleanup must not contaminate later quit barriers"
      )
    }

    coordinator.enqueue(Data(repeating: 0x52, count: 64 * 1024))
    let startedAt = ProcessInfo.processInfo.systemUptime
    let barrier = coordinator.flushBarrier(finalizing: true, retryTimeout: 0.18)
    XCTAssertFalse(barrier.wait(until: .now() + 1))
    let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let attemptsAfterBarrier = attempts.value
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))

    XCTAssertLessThan(
      elapsed,
      0.8,
      "the final barrier must resolve shortly after the 0.18 s finalizing deadline"
    )
    XCTAssertGreaterThan(attemptsAfterBarrier, 0)
    // prepareRetryDelays starts [0.05, 0.1, 0.2, ...]: inside 0.18 s the payload
    // gets at most three append attempts (t = 0, 0.05, 0.15). The failure path
    // then makes one partial-marker attempt and one retention check before the
    // barrier, all on the serial history queue.
    XCTAssertLessThanOrEqual(attemptsAfterBarrier, 5)
    XCTAssertEqual(
      attempts.value,
      attemptsAfterBarrier,
      "no history-queue write may retry after the finalizing barrier resolved"
    )
    XCTAssertEqual(coordinator.outstandingBytes, 0)
    XCTAssertGreaterThan(coordinator.writeFailures, 0)
    XCTAssertEqual(try repository.totalBytes(surfaceID: surfaceID), 0)
    try lockDatabase.execute("ROLLBACK;")
    lockHeld = false
  }

  func testUnconfirmedLockedWriteRemainsPartialAcrossCoordinatorRelaunch() async throws {
    // WHY: when both the payload and its fallback marker are blocked, releasing
    // the coordinator must not let the next runtime claim an empty, complete
    // history and reuse the lost chunk index.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RC2TerminalUnconfirmedRelaunch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("history.sqlite").path
    var database: SQLiteDB? = try SQLiteDB(path: path)
    try Schema.migrate(try XCTUnwrap(database))
    // SQLiteDB layers its own transient-lock retry (up to 8 attempts per
    // transaction, covered by SQLiteBusyRetryTests) under every call, which the
    // coordinator's 0.18 s finalizing deadline cannot interrupt; under the held
    // lock each call then takes about 1 s and the backlog cannot drain in this
    // test's window. One immediate attempt per call pins the coordinator path.
    try database?.execute("PRAGMA busy_timeout=0;")
    database?.busyRetryMaxAttemptsForTesting = 1
    let lockDatabase = try SQLiteDB(path: path)
    var repository: TerminalOutputRepository? = TerminalOutputRepository(
      db: try XCTUnwrap(database)
    )
    let surfaceID = SurfaceID().value.uuidString
    var failedCoordinator: TerminalHistoryCoordinator? = TerminalHistoryCoordinator(
      repository: try XCTUnwrap(repository),
      surfaceID: surfaceID,
      workspaceID: WorkspaceID().value.uuidString
    )
    failedCoordinator?.prepare(restored: false)
    try await waitForPreparationAsync(
      try XCTUnwrap(failedCoordinator),
      expected: .ready(nextChunkIndex: 1)
    )
    let failedGeneration = try XCTUnwrap(
      failedCoordinator?.writerGenerationForTesting
    )

    try lockDatabase.execute("BEGIN IMMEDIATE;")
    var lockHeld = true
    defer {
      if lockHeld { try? lockDatabase.execute("ROLLBACK;") }
    }
    failedCoordinator?.enqueue(Data(repeating: 0x53, count: 64 * 1024))
    let failedBarrier = try XCTUnwrap(failedCoordinator).flushBarrier(
      finalizing: true,
      retryTimeout: 0.18
    )
    XCTAssertFalse(failedBarrier.wait(until: .now() + 1))
    try await waitForCoordinatorHistoryDrainAsync(try XCTUnwrap(failedCoordinator))
    XCTAssertGreaterThan(try XCTUnwrap(failedCoordinator).writeFailures, 0)
    let durableAnchors = try XCTUnwrap(repository).failureAnchors(surfaceID: surfaceID)
    let ledgerRoot = try XCTUnwrap(
      try XCTUnwrap(repository).failureLedgerRootURLForTesting
    )
    let anchorURL = try XCTUnwrap(
      try XCTUnwrap(repository).failureAnchorURLForTesting(
        surfaceID: surfaceID,
        writerGeneration: failedGeneration
      )
    )
    XCTAssertEqual(durableAnchors.count, 1)
    XCTAssertEqual(durableAnchors.first?.minimumNextChunkIndex, 2)
    XCTAssertEqual(try posixPermissions(at: ledgerRoot), 0o700)
    XCTAssertEqual(try posixPermissions(at: anchorURL), 0o600)
    failedCoordinator = nil
    repository = nil
    database = nil
    TerminalHistoryCoordinator.resetUnresolvedFailureMemoryForTesting(
      surfaceID: surfaceID
    )
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertNil(
      try TerminalOutputRepository(db: lockDatabase)
        .partialHistoryState(surfaceID: surfaceID)
    )

    try lockDatabase.execute("ROLLBACK;")
    lockHeld = false

    let relaunchedDatabase = try SQLiteDB(path: path)
    try relaunchedDatabase.execute("PRAGMA busy_timeout=25;")
    let relaunchedRepository = TerminalOutputRepository(db: relaunchedDatabase)
    XCTAssertEqual(
      try relaunchedRepository.failureAnchors(surfaceID: surfaceID).count,
      1,
      "the cross-process fence must survive after every in-memory owner is reset"
    )
    let restoredCoordinator = TerminalHistoryCoordinator(
      repository: relaunchedRepository,
      surfaceID: surfaceID,
      workspaceID: WorkspaceID().value.uuidString
    )
    defer {
      restoredCoordinator.discardAndDeletePersistedHistory()
      _ = TerminalHistoryCoordinator.pendingFinalDeleteBarrier()?.wait(
        until: .now() + 2
      )
    }
    restoredCoordinator.prepare(restored: true)
    let restoredIndex = try await waitForAnyPreparationReadyAsync(restoredCoordinator)
    let restoredPartial = try relaunchedRepository.partialHistoryState(surfaceID: surfaceID)

    XCTAssertEqual(restoredCoordinator.writerGenerationForTesting, failedGeneration)
    XCTAssertEqual(restoredIndex, 2)
    XCTAssertEqual(restoredPartial?.reason, "history_persistence_failed")
    XCTAssertEqual(restoredPartial?.nextChunkIndex, 2)
    do {
      _ = try await restoredCoordinator.readPersistedWindow(
        beforeChunkID: nil,
        maxBytes: 256 * 1024,
        timeout: 1
      )
      XCTFail("restored history with a known lost write must fail closed")
    } catch TerminalHistoryReadError.unavailable {
      // Expected durable partial contract.
    }

    restoredCoordinator.enqueue(Data("RECOVERED_AFTER_LOCK\n".utf8))
    restoredCoordinator.flush(wait: true)
    let chunks = try relaunchedRepository.readWindow(surfaceID: surfaceID).chunks
    XCTAssertEqual(chunks.map(\.chunkIndex), [2])
    XCTAssertTrue(
      try relaunchedRepository.failureAnchors(surfaceID: surfaceID).isEmpty
    )
  }

  func testFailureLedgerRejectsTraversalBeforeCreatingFilesystemState() throws {
    // WHY: surface identifiers cross RPC and persistence boundaries. A malformed
    // identifier must never become a relative sidecar path.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RC2TerminalLedgerTraversal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try SQLiteDB(path: directory.appendingPathComponent("history.sqlite").path)
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let ledgerRoot = try XCTUnwrap(repository.failureLedgerRootURLForTesting)

    XCTAssertThrowsError(
      try repository.recordFailureAnchor(
        surfaceID: "../../escape",
        writerGeneration: UUID().uuidString,
        reason: "history_persistence_failed",
        minimumNextChunkIndex: 2
      )
    ) { error in
      XCTAssertEqual(
        error as? TerminalHistoryFailureLedgerError,
        .invalidIdentifier
      )
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerRoot.path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.deletingLastPathComponent()
          .appendingPathComponent("escape").path
      )
    )
  }

  func testFailureLedgerBoundsOneAnchorPerSurfaceGenerationAtHighWater() throws {
    // WHY: repeated failures must raise one durable high-water fence, not leave
    // an ever-growing file per terminal chunk.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RC2TerminalLedgerBound-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try SQLiteDB(path: directory.appendingPathComponent("history.sqlite").path)
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID().value.uuidString
    let writerGeneration = UUID().uuidString

    try repository.recordFailureAnchor(
      surfaceID: surfaceID,
      writerGeneration: writerGeneration,
      reason: "history_persistence_failed",
      minimumNextChunkIndex: 2
    )
    try repository.recordFailureAnchor(
      surfaceID: surfaceID,
      writerGeneration: writerGeneration,
      reason: "history_persistence_failed",
      minimumNextChunkIndex: 5
    )
    var anchors = try repository.failureAnchors(surfaceID: surfaceID)
    XCTAssertEqual(anchors.count, 1)
    XCTAssertEqual(anchors.first?.minimumNextChunkIndex, 5)

    try repository.clearFailureAnchor(
      surfaceID: surfaceID,
      writerGeneration: writerGeneration,
      throughNextChunkIndex: 4
    )
    XCTAssertEqual(try repository.failureAnchors(surfaceID: surfaceID).count, 1)
    try repository.clearFailureAnchor(
      surfaceID: surfaceID,
      writerGeneration: writerGeneration,
      throughNextChunkIndex: 5
    )
    anchors = try repository.failureAnchors(surfaceID: surfaceID)
    XCTAssertTrue(anchors.isEmpty)
  }

  func testFailureLedgerWriteErrorFailsClosedBeforePayloadAppend() async throws {
    // WHY: if the process-durable fence itself cannot be created, attempting the
    // SQLite payload would reintroduce the cross-process index-reuse window.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RC2TerminalLedgerWriteFailure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try SQLiteDB(path: directory.appendingPathComponent("history.sqlite").path)
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID().value.uuidString
    let coordinator = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: WorkspaceID().value.uuidString
    )
    coordinator.prepare(restored: false)
    try await waitForPreparationAsync(
      coordinator,
      expected: .ready(nextChunkIndex: 1)
    )
    let ledgerRoot = try XCTUnwrap(repository.failureLedgerRootURLForTesting)
    try Data("not-a-directory".utf8).write(to: ledgerRoot, options: .atomic)

    coordinator.enqueue(Data(repeating: 0x54, count: 64 * 1024))
    let barrier = coordinator.flushBarrier(finalizing: true, retryTimeout: 0.5)
    XCTAssertFalse(barrier.wait(until: .now() + 1))
    try await waitForCoordinatorHistoryDrainAsync(coordinator)

    XCTAssertEqual(try repository.totalBytes(surfaceID: surfaceID), 0)
    XCTAssertGreaterThan(coordinator.writeFailures, 0)
    let partial = try repository.partialHistoryState(surfaceID: surfaceID)
    XCTAssertEqual(partial?.reason, "history_persistence_failed")
    XCTAssertEqual(partial?.nextChunkIndex, 2)

    try FileManager.default.removeItem(at: ledgerRoot)
    coordinator.discardAndDeletePersistedHistory()
    try await Task.sleep(nanoseconds: 50_000_000)
  }

  func testReadHistoryTimeoutsShareOneWorkerAndRemainSingleFlight() async throws {
    // WHY: each timed-out RPC must not add another blocked SQLite worker. One
    // held query owns the surface until its actual DB operation completes.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID().value.uuidString
    try repository.append(
      surfaceID: surfaceID,
      workspaceID: nil,
      chunkIndex: 1,
      data: Data("SINGLE_FLIGHT_HISTORY\n".utf8)
    )
    let coordinator = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: WorkspaceID().value.uuidString
    )
    coordinator.prepare(restored: false)
    try await waitForPreparationAsync(coordinator, expected: .ready(nextChunkIndex: 2))
    let readStarted = DispatchSemaphore(value: 0)
    let releaseRead = DispatchSemaphore(value: 0)
    let reads = LockedCounter()
    database.beforeStatementStepForTesting = { sql in
      guard sql.contains("ORDER BY id DESC"), reads.claimFirst() else { return }
      readStarted.signal()
      _ = releaseRead.wait(timeout: .now() + 3)
    }
    defer {
      releaseRead.signal()
      database.beforeStatementStepForTesting = nil
    }

    let first = Task { @MainActor in
      try await coordinator.readPersistedWindow(
        beforeChunkID: nil,
        maxBytes: 256 * 1024,
        timeout: 0.03
      )
    }
    for _ in 0..<100 where coordinator.activeReadWorkerCountForTesting == 0 {
      await Task.yield()
    }
    XCTAssertEqual(coordinator.activeReadWorkerCountForTesting, 1)
    XCTAssertEqual(readStarted.wait(timeout: .now() + 1), .success)
    do {
      _ = try await first.value
      XCTFail("the held read must time out")
    } catch TerminalHistoryReadError.timedOut {
      // Expected. The DB worker remains owned until releaseRead is signalled.
    }

    var busyCount = 0
    for _ in 0..<100 {
      do {
        _ = try await coordinator.readPersistedWindow(
          beforeChunkID: nil,
          maxBytes: 256 * 1024,
          timeout: 0.001
        )
        XCTFail("a timed-out in-flight worker must reject concurrent reads")
      } catch TerminalHistoryReadError.busy {
        busyCount += 1
      }
    }
    XCTAssertEqual(busyCount, 100)
    XCTAssertEqual(coordinator.activeReadWorkerCountForTesting, 1)
    XCTAssertEqual(reads.value, 1)

    releaseRead.signal()
    let deadline = Date().addingTimeInterval(1)
    while coordinator.activeReadWorkerCountForTesting != 0, Date() < deadline {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertEqual(coordinator.activeReadWorkerCountForTesting, 0)
    XCTAssertEqual(reads.value, 1)
  }

  func testReadHistoryFailsClosedAfterPrecedingWriteFailure() async throws {
    // WHY: returning persisted text plus a cursor after a known failed write
    // lets iOS treat an incomplete prefix as authoritative and skip missing bytes.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID().value.uuidString
    let coordinator = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: WorkspaceID().value.uuidString
    )
    coordinator.prepare(restored: false)
    try await waitForPreparationAsync(coordinator, expected: .ready(nextChunkIndex: 1))
    try repository.append(
      surfaceID: surfaceID,
      workspaceID: nil,
      chunkIndex: 1,
      data: Data("DUPLICATE_BLOCKER\n".utf8)
    )
    coordinator.enqueue(Data(repeating: 0x53, count: 64 * 1024))
    let barrier = coordinator.flushBarrier(finalizing: true)
    XCTAssertFalse(barrier.wait(until: .now() + 1))
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertGreaterThan(coordinator.writeFailures, 0)

    do {
      _ = try await coordinator.readPersistedWindow(
        beforeChunkID: nil,
        maxBytes: 256 * 1024,
        timeout: 1
      )
      XCTFail("known missing history must not return text or a sequence cursor")
    } catch TerminalHistoryReadError.unavailable {
      // Exact fail-closed contract.
    }
  }

  func testPartialHistoryFailureSurvivesRelaunchWithoutReusingLostChunkIndexUntilExplicitDelete() async throws {
    // WHY: a failed append leaves a permanent gap. Relaunching the same surface
    // must not forget that gap, claim complete history, or reuse its chunk index.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID().value.uuidString
    let workspaceID = WorkspaceID().value.uuidString
    try repository.append(
      surfaceID: surfaceID,
      workspaceID: workspaceID,
      chunkIndex: 1,
      data: Data("DURABLE_PREFIX\n".utf8)
    )
    try database.execute("""
      CREATE TRIGGER reject_terminal_chunk_two
      BEFORE INSERT ON terminal_output_chunks
      WHEN NEW.surface_id = '\(surfaceID)' AND NEW.chunk_index = 2
      BEGIN
        SELECT RAISE(ABORT, 'intentional lost terminal chunk');
      END;
      """)

    let failedCoordinator = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: workspaceID
    )
    failedCoordinator.prepare(restored: false)
    try await waitForPreparationAsync(
      failedCoordinator,
      expected: .ready(nextChunkIndex: 2)
    )
    failedCoordinator.enqueue(Data(repeating: 0x47, count: 64 * 1024))
    let failedBarrier = failedCoordinator.flushBarrier(finalizing: true)
    XCTAssertFalse(failedBarrier.wait(until: .now() + 1))
    try await Task.sleep(nanoseconds: 50_000_000)
    try database.execute("DROP TRIGGER reject_terminal_chunk_two;")

    let marker = try XCTUnwrap(repository.partialHistoryState(surfaceID: surfaceID))
    XCTAssertEqual(marker.reason, "history_persistence_failed")
    XCTAssertEqual(
      marker.nextChunkIndex,
      3,
      "the durable high-water mark must reserve the index of the lost chunk"
    )

    let restoredDelegate = HistoryCoordinatorDelegateSpy()
    let restoredCoordinator = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: workspaceID
    )
    restoredCoordinator.delegate = restoredDelegate
    restoredCoordinator.prepare(restored: true)
    try await waitForPreparationAsync(
      restoredCoordinator,
      expected: .ready(nextChunkIndex: 3)
    )
    XCTAssertEqual(restoredDelegate.durablePartialReasons, ["history_persistence_failed"])
    do {
      _ = try await restoredCoordinator.readPersistedWindow(
        beforeChunkID: nil,
        maxBytes: 256 * 1024,
        timeout: 1
      )
      XCTFail("a relaunched surface with a durable gap must fail history reads closed")
    } catch TerminalHistoryReadError.unavailable {
      // Exact fail-closed contract.
    }

    restoredCoordinator.discardAndDeletePersistedHistory()
    let deleteDeadline = Date().addingTimeInterval(1)
    while try repository.partialHistoryState(surfaceID: surfaceID) != nil,
          Date() < deleteDeadline {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertNil(try repository.partialHistoryState(surfaceID: surfaceID))

    let afterExplicitDelete = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: workspaceID
    )
    afterExplicitDelete.prepare(restored: true)
    try await waitForPreparationAsync(
      afterExplicitDelete,
      expected: .ready(nextChunkIndex: 1)
    )
    let empty = try await afterExplicitDelete.readPersistedWindow(
      beforeChunkID: nil,
      maxBytes: 256 * 1024,
      timeout: 1
    )
    XCTAssertTrue(empty.chunks.isEmpty)
  }

  func testLiveClearBuffersConcurrentOutputAndReturnsWriterToReusableState() async throws {
    // WHY: clear_history is a live operation, not terminal teardown. Output that
    // arrives while SQLite deletes the old prefix must become the first durable
    // bytes of the new epoch instead of being rejected by a finalized writer.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surface = try TerminalSurface(
      workspaceID: WorkspaceID(),
      title: "reusable live clear",
      launch: .sshPlaceholder(cwd: NSTemporaryDirectory()),
      historyRepo: repository,
      outputBus: SurfaceOutputBus(flushDelay: 0)
    )
    defer {
      database.beforeStatementStepForTesting = nil
      surface.close()
    }
    _ = try await waitForSurfacePreparationReadyAsync(surface)
    let surfaceID = surface.descriptor.id.value.uuidString
    let oldMarker = "RC2_CLEAR_OLD_\(UUID().uuidString)"
    surface.appendSystemText(oldMarker + String(repeating: "o", count: 64 * 1024))
    surface.flushPersistedHistory()
    try await waitForHistoryDrainAsync(surface)

    let deleteStarted = DispatchSemaphore(value: 0)
    let allowDelete = DispatchSemaphore(value: 0)
    let hookLock = NSLock()
    var heldDelete = false
    database.beforeStatementStepForTesting = { sql in
      guard sql.contains("DELETE FROM terminal_output_chunks") else { return }
      hookLock.lock()
      let shouldHold = !heldDelete
      heldDelete = true
      hookLock.unlock()
      guard shouldHold else { return }
      deleteStarted.signal()
      _ = allowDelete.wait(timeout: .now() + 3)
    }

    surface.clearPersistedHistory()
    XCTAssertEqual(waitForSemaphore(deleteStarted, timeout: 1), .success)
    let newMarker = "RC2_CLEAR_NEW_\(UUID().uuidString)"
    surface.appendSystemText(newMarker + "\n")
    allowDelete.signal()
    surface.flushPersistedHistory()
    try await waitForHistoryDrainAsync(surface)

    let persisted = try repository.readWindow(
      surfaceID: surfaceID,
      maxBytes: 256 * 1024
    ).text
    XCTAssertFalse(persisted.contains(oldMarker))
    XCTAssertTrue(
      persisted.contains(newMarker),
      "bytes accepted during live clear must persist after delete acknowledgement"
    )
    XCTAssertEqual(surface.historyOutstandingBytesForTesting, 0)
  }

  func testAppendFailureHasDurableHighWaterBeforeTheFailingDatabaseWrite() async throws {
    // WHY: trying to create the partial marker only after an append fails uses
    // the same unhealthy database and can fail a second time. A committed dirty
    // reservation must already protect the lost index before the append begins.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RC2TerminalDirtyReservation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("history.sqlite").path
    let database = try SQLiteDB(path: path)
    try Schema.migrate(database)
    try database.execute("PRAGMA busy_timeout=25;")
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID().value.uuidString
    let coordinator = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: WorkspaceID().value.uuidString
    )
    coordinator.prepare(restored: false)
    try await waitForPreparationAsync(coordinator, expected: .ready(nextChunkIndex: 1))

    try database.execute("""
      CREATE TRIGGER reject_reserved_terminal_append
      BEFORE INSERT ON terminal_output_chunks
      WHEN NEW.surface_id = '\(surfaceID)' AND NEW.chunk_index = 1
      BEGIN
        SELECT RAISE(ABORT, 'intentional reserved append failure');
      END;
      """)
    defer {
      coordinator.discardAndDeletePersistedHistory()
      _ = TerminalHistoryCoordinator.pendingFinalDeleteBarrier()?.wait(
        until: .now() + 2
      )
    }

    coordinator.enqueue(Data(repeating: 0x44, count: 64 * 1024))
    let barrier = coordinator.flushBarrier(finalizing: true, retryTimeout: 0.18)
    XCTAssertFalse(barrier.wait(until: .now() + 1))
    let partial = try repository.partialHistoryState(surfaceID: surfaceID)
    XCTAssertEqual(partial?.reason, "history_persistence_failed")
    XCTAssertEqual(
      partial?.nextChunkIndex,
      2,
      "the reservation must survive while the later append and fallback marker share a failed database"
    )
  }

  func testFailedLiveClearKeepsDurableTruthAndBufferedOutputThenCanRetry() async throws {
    // WHY: a failed DELETE must not report a successful clear or drop output
    // accepted concurrently. The same live writer must remain retryable after
    // the storage fault is removed.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID()
    let rawSurfaceID = surfaceID.value.uuidString
    try repository.append(
      surfaceID: rawSurfaceID,
      workspaceID: nil,
      chunkIndex: 1,
      data: Data("PRE_CLEAR_DURABLE\n".utf8)
    )
    try repository.markHistoryPartial(
      surfaceID: rawSurfaceID,
      reason: "history_persistence_failed",
      nextChunkIndex: 2
    )
    let surface = try TerminalSurface(
      workspaceID: WorkspaceID(),
      title: "failed reusable clear",
      launch: .sshPlaceholder(cwd: NSTemporaryDirectory()),
      restoredSurfaceID: surfaceID,
      historyRepo: repository,
      outputBus: SurfaceOutputBus(flushDelay: 0)
    )
    defer { surface.close() }
    _ = try await waitForSurfacePreparationReadyAsync(surface)
    XCTAssertTrue(surface.runtimeHealth().outputPartial)

    try database.execute("""
      CREATE TRIGGER reject_terminal_live_clear
      BEFORE DELETE ON terminal_output_chunks
      WHEN OLD.surface_id = '\(rawSurfaceID)'
      BEGIN
        SELECT RAISE(ABORT, 'intentional live clear failure');
      END;
      """)
    surface.clearPersistedHistory()
    let bufferedMarker = "RC2_BUFFERED_AFTER_FAILED_CLEAR_\(UUID().uuidString)"
    surface.appendSystemText(bufferedMarker + "\n")
    try await waitForLiveClearCompletionAsync(surface)
    try await waitForHistoryDrainAsync(surface)

    let afterFailure = try repository.readWindow(
      surfaceID: rawSurfaceID,
      maxBytes: 256 * 1024
    ).text
    XCTAssertTrue(afterFailure.contains("PRE_CLEAR_DURABLE"))
    XCTAssertTrue(afterFailure.contains(bufferedMarker))
    XCTAssertEqual(surface.readTextSnapshot().partialReason, "history_clear_failed")
    XCTAssertNotNil(try repository.partialHistoryState(surfaceID: rawSurfaceID))

    try database.execute("DROP TRIGGER reject_terminal_live_clear;")
    surface.clearPersistedHistory()
    try await waitForLiveClearCompletionAsync(surface)
    XCTAssertFalse(surface.runtimeHealth().outputPartial)
    let retryMarker = "RC2_AFTER_CLEAR_RETRY_\(UUID().uuidString)"
    surface.appendSystemText(retryMarker + "\n")
    try await waitForHistoryDrainAsync(surface)
    let afterRetry = try repository.readWindow(
      surfaceID: rawSurfaceID,
      maxBytes: 256 * 1024
    ).text
    XCTAssertFalse(afterRetry.contains("PRE_CLEAR_DURABLE"))
    XCTAssertFalse(afterRetry.contains(bufferedMarker))
    XCTAssertTrue(afterRetry.contains(retryMarker))
    XCTAssertNil(try repository.partialHistoryState(surfaceID: rawSurfaceID))
  }

  func testFailedLiveClearRetainsConcurrentOutputAfterEarlierWriterFailure() async throws {
    // WHY: a storage fault can disable ordinary history writes before a live
    // clear also fails. Output accepted while that clear is in flight must stay
    // bounded in memory and become durable when the user retries the clear.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID()
    let rawSurfaceID = surfaceID.value.uuidString
    try repository.append(
      surfaceID: rawSurfaceID,
      workspaceID: nil,
      chunkIndex: 1,
      data: Data("PRE_CLEAR_DURABLE\n".utf8)
    )
    let surface = try TerminalSurface(
      workspaceID: WorkspaceID(),
      title: "failed writer then failed clear",
      launch: .sshPlaceholder(cwd: NSTemporaryDirectory()),
      restoredSurfaceID: surfaceID,
      historyRepo: repository,
      outputBus: SurfaceOutputBus(flushDelay: 0)
    )
    defer { surface.close() }
    _ = try await waitForSurfacePreparationReadyAsync(surface)

    try database.execute("""
      CREATE TRIGGER reject_terminal_append_before_clear
      BEFORE INSERT ON terminal_output_chunks
      WHEN NEW.surface_id = '\(rawSurfaceID)'
      BEGIN
        SELECT RAISE(ABORT, 'intentional append failure before clear');
      END;
      """)
    surface.appendSystemText("FORCE_WRITER_FAILURE\n")
    try await waitForHistoryDrainAsync(surface)
    XCTAssertGreaterThan(surface.runtimeHealth().historyWriteFailures, 0)

    try database.execute("""
      CREATE TRIGGER reject_terminal_clear_after_append_failure
      BEFORE DELETE ON terminal_output_chunks
      WHEN OLD.surface_id = '\(rawSurfaceID)'
      BEGIN
        SELECT RAISE(ABORT, 'intentional clear failure after append failure');
      END;
      """)
    surface.clearPersistedHistory()
    XCTAssertTrue(surface.historyLiveClearInFlightForTesting)
    let bufferedMarker = "RC2_BUFFERED_AFTER_COMBINED_FAILURE_\(UUID().uuidString)"
    surface.appendSystemText(bufferedMarker + "\n")
    try await waitForLiveClearCompletionAsync(surface)

    let afterFailure = try repository.readWindow(
      surfaceID: rawSurfaceID,
      maxBytes: 256 * 1024
    ).text
    XCTAssertTrue(afterFailure.contains("PRE_CLEAR_DURABLE"))
    XCTAssertFalse(afterFailure.contains(bufferedMarker))

    try database.execute("DROP TRIGGER reject_terminal_append_before_clear;")
    try database.execute("DROP TRIGGER reject_terminal_clear_after_append_failure;")
    surface.clearPersistedHistory()
    try await waitForLiveClearCompletionAsync(surface)
    try await waitForHistoryDrainAsync(surface)

    let afterRetry = try repository.readWindow(
      surfaceID: rawSurfaceID,
      maxBytes: 256 * 1024
    ).text
    XCTAssertFalse(afterRetry.contains("PRE_CLEAR_DURABLE"))
    XCTAssertTrue(afterRetry.contains(bufferedMarker))
  }

  func testRetentionPruneAndPartialHighWaterRollBackAsOneTransaction() throws {
    // WHY: pruning without its partial marker can leave a shortened history that
    // relaunch later advertises as complete. The delete and marker are one commit.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID().value.uuidString
    for index in 1...3 {
      try repository.append(
        surfaceID: surfaceID,
        workspaceID: nil,
        chunkIndex: Int64(index),
        data: Data(repeating: UInt8(index), count: 10)
      )
    }
    let preparation = try repository.prepareHistory(surfaceID: surfaceID)
    try database.execute("""
      CREATE TRIGGER reject_terminal_retention_marker
      BEFORE INSERT ON settings
      WHEN NEW.key = 'terminal.history.partial.\(surfaceID)'
      BEGIN
        SELECT RAISE(ABORT, 'intentional retention marker failure');
      END;
      """)

    XCTAssertThrowsError(
      try repository.pruneByteCapAndMarkHistoryPartial(
        surfaceID: surfaceID,
        maxBytes: 15,
        reason: "history_retention_cap",
        nextChunkIndex: 4,
        expectedWriterGeneration: preparation.writerGeneration
      )
    )
    XCTAssertEqual(try repository.totalBytes(surfaceID: surfaceID), 30)
    XCTAssertEqual(
      try repository.readWindow(surfaceID: surfaceID).chunks.map(\.chunkIndex),
      [1, 2, 3],
      "marker failure must roll the preceding oldest-row deletes back"
    )
    XCTAssertNil(try repository.partialHistoryState(surfaceID: surfaceID))

    try database.execute("DROP TRIGGER reject_terminal_retention_marker;")
    XCTAssertTrue(
      try repository.pruneByteCapAndMarkHistoryPartial(
        surfaceID: surfaceID,
        maxBytes: 15,
        reason: "history_retention_cap",
        nextChunkIndex: 4,
        expectedWriterGeneration: preparation.writerGeneration
      )
    )
    XCTAssertEqual(try repository.totalBytes(surfaceID: surfaceID), 10)
    XCTAssertEqual(try repository.readWindow(surfaceID: surfaceID).chunks.map(\.chunkIndex), [3])
    XCTAssertEqual(
      try repository.partialHistoryState(surfaceID: surfaceID),
      TerminalHistoryPartialState(reason: "history_retention_cap", nextChunkIndex: 4)
    )
  }

  func testOldCoordinatorCannotRepopulateAfterNewCoordinatorAcknowledgesClear() async throws {
    // WHY: reconnect temporarily leaves two coordinators behind one stable
    // surface ID. An old delayed writer must be rejected after clear rotates
    // ownership, even if its insert begins after the DELETE commits.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID().value.uuidString
    let workspaceID = WorkspaceID().value.uuidString
    let old = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: workspaceID
    )
    let current = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: workspaceID
    )
    old.prepare(restored: false)
    current.prepare(restored: false)
    try await waitForPreparationAsync(old, expected: .ready(nextChunkIndex: 1))
    try await waitForPreparationAsync(current, expected: .ready(nextChunkIndex: 1))
    XCTAssertEqual(old.writerGenerationForTesting, current.writerGenerationForTesting)

    let oldWriterStarted = DispatchSemaphore(value: 0)
    let releaseOldWriter = DispatchSemaphore(value: 0)
    old.beforePersistForTesting = {
      oldWriterStarted.signal()
      _ = releaseOldWriter.wait(timeout: .now() + 3)
    }
    defer {
      releaseOldWriter.signal()
      old.discardAndDeletePersistedHistory()
      current.discardAndDeletePersistedHistory()
    }
    let oldMarker = Data("RC2_STALE_OLD_WRITER\n".utf8)
    old.enqueue(
      Data(repeating: 0x4F, count: 64 * 1024 - oldMarker.count) + oldMarker
    )
    let oldBarrier = old.flushBarrier()
    XCTAssertEqual(oldWriterStarted.wait(timeout: .now() + 1), .success)
    old.enqueue(Data(repeating: 0x58, count: 4 * 1024 * 1024))

    current.clearPersistedHistory()
    let clearBarrier = current.flushBarrier()
    let clearSucceeded = await clearBarrier.waitAsync(until: .now() + 2)
    XCTAssertTrue(clearSucceeded)
    let currentMarker = Data("RC2_CURRENT_AFTER_CLEAR\n".utf8)
    current.enqueue(currentMarker)
    let currentBarrier = current.flushBarrier()
    let currentWriteSucceeded = await currentBarrier.waitAsync(until: .now() + 2)
    XCTAssertTrue(currentWriteSucceeded)

    releaseOldWriter.signal()
    let oldWriteSucceeded = await oldBarrier.waitAsync(until: .now() + 2)
    XCTAssertFalse(oldWriteSucceeded)
    let completionDeadline = Date().addingTimeInterval(1)
    while old.outstandingBytes != 0, Date() < completionDeadline {
      try await Task.sleep(nanoseconds: 5_000_000)
    }

    let persisted = try repository.readWindow(surfaceID: surfaceID).text
    XCTAssertFalse(persisted.contains("RC2_STALE_OLD_WRITER"))
    XCTAssertTrue(persisted.contains("RC2_CURRENT_AFTER_CLEAR"))
    XCTAssertNil(try repository.partialHistoryState(surfaceID: surfaceID))
    XCTAssertEqual(old.outstandingBytes, 0)
    XCTAssertGreaterThan(old.writeFailures, 0)
  }

  func testRepeatedClearCoalescesOneDeleteAndBoundsConcurrentBufferAndBarrier() async throws {
    // WHY: clear storms and a busy terminal must not create one task/buffer per
    // RPC. One serialized delete, one barrier, and the 4 MiB history budget are
    // hard bounds.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID().value.uuidString
    let coordinator = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: WorkspaceID().value.uuidString
    )
    coordinator.prepare(restored: false)
    try await waitForPreparationAsync(coordinator, expected: .ready(nextChunkIndex: 1))
    try repository.append(
      surfaceID: surfaceID,
      workspaceID: nil,
      chunkIndex: 1,
      data: Data("ROW_FOR_BOUNDED_CLEAR".utf8)
    )

    let deleteStarted = DispatchSemaphore(value: 0)
    let releaseDelete = DispatchSemaphore(value: 0)
    let deleteCount = LockedCounter()
    database.beforeStatementStepForTesting = { sql in
      guard sql.contains("DELETE FROM terminal_output_chunks") else { return }
      let count = deleteCount.increment()
      if count == 1 {
        deleteStarted.signal()
        _ = releaseDelete.wait(timeout: .now() + 3)
      }
    }
    defer {
      releaseDelete.signal()
      database.beforeStatementStepForTesting = nil
      coordinator.discardAndDeletePersistedHistory()
    }

    coordinator.clearPersistedHistory()
    XCTAssertEqual(deleteStarted.wait(timeout: .now() + 1), .success)
    for _ in 0..<4 {
      coordinator.enqueue(Data(repeating: 0x42, count: 1024 * 1024))
    }
    coordinator.enqueue(Data(repeating: 0x58, count: 1))
    XCTAssertLessThanOrEqual(coordinator.liveClearBufferedBytesForTesting, 4 * 1024 * 1024)
    XCTAssertLessThanOrEqual(coordinator.outstandingBytes, 4 * 1024 * 1024)
    let barriers = (0..<100).map { _ in coordinator.flushBarrier() }
    XCTAssertEqual(coordinator.liveClearBarrierCountForTesting, 1)

    for _ in 0..<100 { coordinator.clearPersistedHistory() }
    XCTAssertEqual(coordinator.liveClearBufferedBytesForTesting, 0)
    XCTAssertEqual(coordinator.outstandingBytes, 0)
    let finalMarker = Data("RC2_BOUNDED_CLEAR_FINAL\n".utf8)
    coordinator.enqueue(finalMarker)
    releaseDelete.signal()
    let clearSucceeded = await barriers[0].waitAsync(until: .now() + 2)
    XCTAssertTrue(clearSucceeded)
    let drainDeadline = Date().addingTimeInterval(1)
    while coordinator.outstandingBytes != 0, Date() < drainDeadline {
      try await Task.sleep(nanoseconds: 5_000_000)
    }

    XCTAssertEqual(deleteCount.value, 1)
    XCTAssertEqual(coordinator.liveClearBarrierCountForTesting, 0)
    XCTAssertEqual(coordinator.liveClearBufferedBytesForTesting, 0)
    XCTAssertEqual(coordinator.outstandingBytes, 0)
    XCTAssertEqual(try repository.readWindow(surfaceID: surfaceID).text, String(decoding: finalMarker, as: UTF8.self))
  }

  func testRestoredTerminalPublishesDurablePartialHealthAcrossRuntimeRelaunchUntilClear() async throws {
    // WHY: the durable repository marker is useful only if the actual restored
    // TerminalSurface exposes complete=false to every mirror/health consumer.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID()
    let rawSurfaceID = surfaceID.value.uuidString
    try repository.markHistoryPartial(
      surfaceID: rawSurfaceID,
      reason: "history_persistence_failed",
      nextChunkIndex: 4
    )

    let first = try TerminalSurface(
      workspaceID: WorkspaceID(),
      title: "first restored runtime",
      launch: .sshPlaceholder(cwd: NSTemporaryDirectory()),
      restoredSurfaceID: surfaceID,
      historyRepo: repository,
      outputBus: SurfaceOutputBus()
    )
    let firstNextIndex = try await waitForSurfacePreparationReadyAsync(first)
    XCTAssertGreaterThanOrEqual(firstNextIndex, 4)
    XCTAssertTrue(first.runtimeHealth().outputPartial)
    XCTAssertEqual(first.readTextSnapshot().partialReason, "history_persistence_failed")
    if let barrier = first.closeForRuntimeRestart() {
      let closed = await barrier.waitAsync(until: .now() + 2)
      XCTAssertTrue(closed)
    }

    let second = try TerminalSurface(
      workspaceID: WorkspaceID(),
      title: "second restored runtime",
      launch: .sshPlaceholder(cwd: NSTemporaryDirectory()),
      restoredSurfaceID: surfaceID,
      historyRepo: repository,
      outputBus: SurfaceOutputBus()
    )
    let secondNextIndex = try await waitForSurfacePreparationReadyAsync(second)
    XCTAssertGreaterThanOrEqual(secondNextIndex, firstNextIndex)
    XCTAssertTrue(second.runtimeHealth().outputPartial)
    XCTAssertEqual(second.readTextSnapshot().partialReason, "history_persistence_failed")

    second.clearPersistedHistory()
    let deleteDeadline = Date().addingTimeInterval(1)
    while try repository.partialHistoryState(surfaceID: rawSurfaceID) != nil,
          Date() < deleteDeadline {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertNil(try repository.partialHistoryState(surfaceID: rawSurfaceID))
    XCTAssertFalse(second.runtimeHealth().outputPartial)
    second.close()
  }

  func testFirstReplayMergesPersistedHistoryBeforePreexistingLiveTailExactlyOnce() throws {
    // WHY: a restored shell can emit a prompt before its first history replay.
    // Treating that live tail as evidence of an earlier failed read skips the
    // persisted scrollback; clearing it before the read also loses the prompt.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID().value.uuidString
    let workspaceID = WorkspaceID().value.uuidString
    let persistedMarker = Data("PERSISTED_BEFORE_FIRST_REPLAY\n".utf8)
    let liveMarker = Data("LIVE_BEFORE_FIRST_REPLAY\n".utf8)
    var liveTail = Data(repeating: 0x4C, count: 320 * 1024)
    liveTail.append(liveMarker)
    try repository.append(
      surfaceID: surfaceID,
      workspaceID: workspaceID,
      chunkIndex: 1,
      data: persistedMarker
    )
    let delegate = HistoryCoordinatorDelegateSpy()
    let coordinator = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: workspaceID
    )
    coordinator.delegate = delegate
    coordinator.prepare(restored: true)
    try waitForPreparationReady(coordinator)

    delegate.renderedData.append(liveTail)
    coordinator.recordLiveReplayData(liveTail, maxBytes: 4 * 1024 * 1024)
    coordinator.enqueue(liveTail)
    coordinator.flush(wait: true)
    XCTAssertEqual(
      occurrences(
        of: liveMarker,
        in: TerminalHistoryCoordinator.assembleReplayPayload(
          from: try repository.readWindow(surfaceID: surfaceID).chunks.map(\.data)
        )
      ),
      1,
      "the production-equivalent fixture must persist the live tail before replay"
    )
    coordinator.replayIfNeeded()
    try waitForReplayCompletion(coordinator)

    var expected = persistedMarker
    expected.append(TerminalHistoryCoordinator.restoredModeReset)
    expected.append(liveTail)
    XCTAssertEqual(
      delegate.renderedData,
      expected,
      "the first canonical replay must preserve persisted-then-live byte order"
    )
    XCTAssertEqual(occurrences(of: persistedMarker, in: delegate.renderedData), 1)
    XCTAssertEqual(occurrences(of: liveMarker, in: delegate.renderedData), 1)
    XCTAssertEqual(delegate.replayReadFailureCount, 0)
    XCTAssertEqual(delegate.replayReadRecoveryCount, 0)
  }

  func testRestoredReplayDisablesDeadProcessModesBeforeLiveBytes() throws {
    // WHY: persisted history may leave mouse tracking on from a dead TUI while
    // the restored PTY is a fresh shell; mouse moves would print at the prompt.
    // The reset must sit before live bytes so the new shell can re-enable modes.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID().value.uuidString
    let workspaceID = WorkspaceID().value.uuidString
    let payload = Data("\u{1B}[?1003h\u{1B}[?1006hDEAD_TUI\n".utf8)
    let liveData = Data("\u{1B}[?2004hNEW_SHELL_PROMPT$ ".utf8)
    try repository.append(
      surfaceID: surfaceID,
      workspaceID: workspaceID,
      chunkIndex: 1,
      data: payload
    )
    let delegate = HistoryCoordinatorDelegateSpy()
    let coordinator = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: workspaceID
    )
    coordinator.delegate = delegate
    coordinator.prepare(restored: true, deferReplay: true)
    try waitForPreparationReady(coordinator)

    coordinator.recordLiveReplayData(liveData, maxBytes: 4 * 1024 * 1024)
    coordinator.requestReplayIfNeeded()
    try waitForReplayCompletion(coordinator)

    var expected = payload
    expected.append(TerminalHistoryCoordinator.restoredModeReset)
    expected.append(liveData)
    XCTAssertEqual(delegate.renderedData, expected)
  }

  func testCombinedReplayOverBoundPreservesLiveParserInsteadOfResettingFromPartialBytes() throws {
    // WHY: the bounded Ghostty replay reserves one 256 KiB PTY handoff. If the
    // persisted prefix plus captured live tail cannot fit, keeping the current
    // live parser is semantically safe; truncating or rebuilding it is not.
    let surfaceID = SurfaceID().value.uuidString
    let workspaceID = WorkspaceID().value.uuidString
    let persisted = Data("P".utf8)
    let window = TerminalOutputWindow(
      chunks: [TerminalOutputChunk(
        id: 1,
        surfaceID: surfaceID,
        workspaceID: workspaceID,
        chunkIndex: 0,
        data: persisted,
        createdAt: Date()
      )],
      hasMoreOlder: false,
      nextBeforeChunkID: nil
    )
    let delegate = HistoryCoordinatorDelegateSpy()
    let liveView = Data("LIVE_PARSER_MUST_SURVIVE".utf8)
    delegate.renderedData = liveView
    let coordinator = TerminalHistoryCoordinator(
      repository: nil,
      surfaceID: surfaceID,
      workspaceID: workspaceID,
      readWindow: { _ in window }
    )
    coordinator.delegate = delegate
    coordinator.prepare(restored: true)
    coordinator.recordLiveReplayData(
      Data(repeating: 0x4C, count: TerminalHistoryCoordinator.maxCanonicalReplayBytes),
      maxBytes: 4 * 1024 * 1024
    )

    coordinator.replayIfNeeded()
    try waitForReplayCompletion(coordinator)

    XCTAssertEqual(delegate.renderedData, liveView)
    XCTAssertEqual(delegate.replayLiveCapCount, 1)
  }

  func testHeadlessDemandReplayKeepsPTYReaderMovingAndPreservesPersistedThenLiveOrder() async throws {
    // WHY: automation can demand read_text for a restored, unselected terminal
    // before any user-visible pane exists. Replay must improve the mirror without
    // suspending the producer until a future UI attachment that may never happen.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID()
    let workspaceID = WorkspaceID()
    let persistedMarker = "RC2_HEADLESS_PERSISTED_\(UUID().uuidString)"
    let liveMarker = "RC2_HEADLESS_LIVE_\(UUID().uuidString)"
    try repository.append(
      surfaceID: surfaceID.value.uuidString,
      workspaceID: workspaceID.value.uuidString,
      chunkIndex: 1,
      data: Data("\(persistedMarker)\n".utf8)
    )
    let surface = try TerminalSurface(
      workspaceID: workspaceID,
      title: "headless demand replay",
      launch: .shell(cwd: NSTemporaryDirectory()),
      restoredSurfaceID: surfaceID,
      historyRepo: repository,
      outputBus: SurfaceOutputBus(flushDelay: 0)
    )
    defer { surface.close() }
    _ = try await waitForSurfacePreparationReadyAsync(surface)
    XCTAssertFalse(surface.ghosttyHasLiveSurfaceForTesting)

    _ = surface.readTextSnapshot()
    XCTAssertEqual(surface.sendTextStatus("printf '\\n\(liveMarker)\\n'\n"), .accepted)
    let deadline = Date().addingTimeInterval(6)
    var final = surface.readTextSnapshot()
    while Date() < deadline,
          !(final.text.contains(persistedMarker) && final.text.contains(liveMarker)) {
      XCTAssertFalse(surface.readerPausedForHistoryReplayForTesting)
      try await Task.sleep(nanoseconds: 10_000_000)
      final = surface.readTextSnapshot()
    }

    XCTAssertTrue(final.text.contains(persistedMarker))
    XCTAssertTrue(final.text.contains(liveMarker))
    XCTAssertLessThan(
      final.text.range(of: persistedMarker)!.lowerBound,
      final.text.range(of: liveMarker)!.lowerBound
    )
    XCTAssertFalse(surface.readerPausedForHistoryReplayForTesting)
    XCTAssertTrue(surface.hasDeferredUnhostedGhosttyReplayForTesting)
    XCTAssertTrue(surface.runtimeHealth().processAlive)
  }

  func testFinalDeleteRunsAfterBlockedWriterAndRejectsPostDeleteChurn() throws {
    // WHY: user-close must be the final queue disposition. A queued append that
    // lands after router deletion would recreate ownerless history rows forever.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID().value.uuidString
    let workspaceID = WorkspaceID().value.uuidString
    try repository.append(
      surfaceID: surfaceID,
      workspaceID: workspaceID,
      chunkIndex: 1,
      data: Data("OLD_ROW_TO_DELETE".utf8)
    )
    let coordinator = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: workspaceID
    )
    coordinator.prepare(restored: false)
    try waitForPreparationReady(coordinator)

    let writeStarted = DispatchSemaphore(value: 0)
    let allowWrite = DispatchSemaphore(value: 0)
    let hookLock = NSLock()
    var didBlockWrite = false
    database.beforeStatementStepForTesting = { sql in
      guard sql.contains("INSERT INTO terminal_output_chunks") else { return }
      hookLock.lock()
      let shouldBlock = !didBlockWrite
      didBlockWrite = true
      hookLock.unlock()
      guard shouldBlock else { return }
      writeStarted.signal()
      _ = allowWrite.wait(timeout: .now() + 10)
    }
    defer {
      allowWrite.signal()
      database.beforeStatementStepForTesting = nil
    }

    coordinator.enqueue(Data(repeating: 0x41, count: 64 * 1024))
    XCTAssertEqual(waitForSemaphore(writeStarted, timeout: 3), .success)
    coordinator.discardAndDeletePersistedHistory()
    for _ in 0..<128 {
      coordinator.enqueue(Data("POST_CLOSE_CHURN".utf8))
    }
    allowWrite.signal()
    coordinator.flush(wait: true)

    XCTAssertEqual(
      try repository.totalBytes(surfaceID: surfaceID),
      0,
      "the same serial queue must run final delete after the already-started writer"
    )
    for _ in 0..<128 {
      coordinator.enqueue(Data("POST_DELETE_CHURN".utf8))
    }
    coordinator.flush(wait: true)
    XCTAssertEqual(
      try repository.totalBytes(surfaceID: surfaceID),
      0,
      "a finalized coordinator must reject every post-delete enqueue"
    )
  }

  func testReplayRetryCannotReplaceNewerLiveViewWhenFirstReadAndPersistenceFail() throws {
    // WHY: a retry after a failed restore read must not reset the terminal from
    // an older persisted prefix when live output from the failed attempt was
    // never durable. That reset would erase the user's newest visible output.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID().value.uuidString
    let workspaceID = WorkspaceID().value.uuidString
    try repository.append(
      surfaceID: surfaceID,
      workspaceID: workspaceID,
      chunkIndex: 1,
      data: Data("OLD_PERSISTED_PREFIX\n".utf8)
    )
    let readController = FailingFirstHistoryRead(repository: repository)
    let delegate = HistoryCoordinatorDelegateSpy()
    let coordinator = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: workspaceID,
      readWindow: { surfaceID in try readController.read(surfaceID: surfaceID) }
    )
    coordinator.delegate = delegate
    coordinator.prepare(restored: true)
    try waitForPreparationReady(coordinator)
    coordinator.replayIfNeeded()
    XCTAssertEqual(waitForSemaphore(readController.firstReadStarted, timeout: 3), .success)

    let liveMarker = Data("NEW_LIVE_NOT_DURABLE\n".utf8)
    delegate.renderedData.append(liveMarker)
    coordinator.recordLiveReplayData(liveMarker, maxBytes: 4 * 1024 * 1024)
    readController.allowFirstReadToFail.signal()
    try waitForReplayCompletion(coordinator)

    coordinator.replayIfNeeded()
    try waitForReplayCompletion(coordinator)

    XCTAssertTrue(
      delegate.renderedData.contains(liveMarker),
      "a successful retry must not destructively reset away newer live bytes that were not persisted"
    )
    XCTAssertGreaterThan(
      delegate.replayReadFailureCount,
      0,
      "the unsafe retry must remain explicitly partial instead of claiming complete restored history"
    )
    XCTAssertEqual(delegate.replayReadRecoveryCount, 0)
  }

  func testReplayRetryDoesNotDuplicateLiveBytesWhenPersistenceCatchesUp() throws {
    // WHY: preserving live bytes across a failed read cannot blindly append
    // them after retry if the same bytes became durable in the meantime.
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID().value.uuidString
    let workspaceID = WorkspaceID().value.uuidString
    try repository.append(
      surfaceID: surfaceID,
      workspaceID: workspaceID,
      chunkIndex: 1,
      data: Data("OLD_PERSISTED_PREFIX\n".utf8)
    )
    let readController = FailingFirstHistoryRead(repository: repository)
    let delegate = HistoryCoordinatorDelegateSpy()
    let coordinator = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: workspaceID,
      readWindow: { surfaceID in try readController.read(surfaceID: surfaceID) }
    )
    coordinator.delegate = delegate
    coordinator.prepare(restored: true)
    try waitForPreparationReady(coordinator)
    coordinator.replayIfNeeded()
    XCTAssertEqual(waitForSemaphore(readController.firstReadStarted, timeout: 3), .success)

    let liveMarker = Data("NEW_LIVE_LATER_DURABLE\n".utf8)
    delegate.renderedData.append(liveMarker)
    coordinator.recordLiveReplayData(liveMarker, maxBytes: 4 * 1024 * 1024)
    readController.allowFirstReadToFail.signal()
    try waitForReplayCompletion(coordinator)
    try repository.append(
      surfaceID: surfaceID,
      workspaceID: workspaceID,
      chunkIndex: 2,
      data: liveMarker
    )

    coordinator.replayIfNeeded()
    try waitForReplayCompletion(coordinator)

    XCTAssertEqual(
      occurrences(of: liveMarker, in: delegate.renderedData),
      1,
      "a retry must not duplicate live bytes that became durable after the first read failed"
    )
    XCTAssertGreaterThan(delegate.replayReadFailureCount, 0)
    XCTAssertEqual(
      delegate.replayReadRecoveryCount,
      0,
      "a retry that spans live output is intentionally partial and must not report exact recovery"
    )
  }

  func testReplayRetryWithNoInterveningLiveOutputRecoversExactHistory() throws {
    let database = try SQLiteDB(path: ":memory:")
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID().value.uuidString
    let workspaceID = WorkspaceID().value.uuidString
    let persisted = Data("EXACT_RECOVERED_HISTORY\n".utf8)
    try repository.append(
      surfaceID: surfaceID,
      workspaceID: workspaceID,
      chunkIndex: 1,
      data: persisted
    )
    let readController = FailingFirstHistoryRead(repository: repository)
    let delegate = HistoryCoordinatorDelegateSpy()
    let coordinator = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: workspaceID,
      readWindow: { surfaceID in try readController.read(surfaceID: surfaceID) }
    )
    coordinator.delegate = delegate
    coordinator.prepare(restored: true)
    try waitForPreparationReady(coordinator)
    coordinator.replayIfNeeded()
    XCTAssertEqual(waitForSemaphore(readController.firstReadStarted, timeout: 3), .success)
    readController.allowFirstReadToFail.signal()
    try waitForReplayCompletion(coordinator)

    coordinator.replayIfNeeded()
    try waitForReplayCompletion(coordinator)

    var expectedReplay = persisted
    expectedReplay.append(TerminalHistoryCoordinator.restoredModeReset)
    XCTAssertEqual(delegate.renderedData, expectedReplay)
    XCTAssertEqual(delegate.replayReadFailureCount, 1)
    XCTAssertEqual(
      delegate.replayReadRecoveryCount,
      1,
      "a retry with no intervening live bytes can prove canonical replay is exact"
    )
  }

  func testReplayReadFailureMakesProductionSnapshotExplicitlyPartial() throws {
    let surface = try TerminalSurface(
      workspaceID: WorkspaceID(),
      title: "failed replay health",
      launch: .sshPlaceholder(cwd: NSTemporaryDirectory()),
      outputBus: SurfaceOutputBus(flushDelay: 0)
    )
    defer { surface.close() }
    let coordinator = TerminalHistoryCoordinator(
      repository: nil,
      surfaceID: surface.descriptor.id.value.uuidString,
      workspaceID: WorkspaceID().value.uuidString
    )

    surface.terminalHistoryCoordinator(coordinator, didEncounter: .replayReadFailure)

    let snapshot = surface.readTextSnapshot()
    XCTAssertFalse(snapshot.complete)
    XCTAssertEqual(
      snapshot.partialReason,
      "history_replay_failed",
      "a failed restore read must remain visible to macOS and mirrored iOS consumers"
    )

    let recovered = Data("EXACT_RECOVERED_HISTORY\n".utf8)
    surface.terminalHistoryCoordinator(coordinator, didPrepareReplay: recovered)
    surface.terminalHistoryCoordinator(coordinator, didEncounter: .replayReadRecovered)
    XCTAssertFalse(
      surface.runtimeHealth().outputPartial,
      "an exact safe retry must clear only the transient replay-read failure"
    )
    XCTAssertTrue(surface.readTextSnapshot().text.contains("EXACT_RECOVERED_HISTORY"))
  }

  func testReplayOverflowPreservesNewestLiveTailInsteadOfDestructiveReset() throws {
    // WHY: restored history is read off-main. If live output exceeds the replay
    // merge cap during that read, resetting from the capped prefix erases the
    // newest bytes that were already rendered.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RC2TerminalReplayOverflow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try SQLiteDB(path: directory.appendingPathComponent("history.sqlite").path)
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = SurfaceID()
    let workspaceID = WorkspaceID()
    try repository.append(
      surfaceID: surfaceID.value.uuidString,
      workspaceID: workspaceID.value.uuidString,
      chunkIndex: 1,
      data: Data("PERSISTED_PREFIX\n".utf8)
    )

    let readStarted = DispatchSemaphore(value: 0)
    let allowRead = DispatchSemaphore(value: 0)
    let hookLock = NSLock()
    var didBlockReplayRead = false
    database.beforeStatementStepForTesting = { sql in
      guard sql.contains("FROM terminal_output_chunks"),
            sql.contains("ORDER BY id DESC") else { return }
      hookLock.lock()
      let shouldBlock = !didBlockReplayRead
      didBlockReplayRead = true
      hookLock.unlock()
      guard shouldBlock else { return }
      readStarted.signal()
      _ = allowRead.wait(timeout: .now() + 10)
    }

    let surface = try TerminalSurface(
      workspaceID: workspaceID,
      title: "restored replay overflow",
      launch: .sshPlaceholder(cwd: NSTemporaryDirectory()),
      restoredSurfaceID: surfaceID,
      historyRepo: repository,
      outputBus: SurfaceOutputBus(flushDelay: 0)
    )
    defer {
      allowRead.signal()
      database.beforeStatementStepForTesting = nil
      surface.closeAndDeletePersistedHistory()
      // Close registers the final delete synchronously, but the delete can
      // finish and drain the registry before this line runs. A nil barrier
      // then means "already done", so prove completion by the deleted rows.
      if let cleanupBarrier = TerminalHistoryCoordinator.pendingFinalDeleteBarrier() {
        XCTAssertTrue(
          cleanupBarrier.wait(until: .now() + 2),
          "fixture cleanup must quiesce replay-overflow persistence before removing its database"
        )
      }
      XCTAssertEqual(
        try? repository.totalBytes(surfaceID: surfaceID.value.uuidString),
        0,
        "close must run its final delete before the fixture removes the database"
      )
      XCTAssertNil(
        TerminalHistoryCoordinator.pendingFinalDeleteBarrier(),
        "replay-overflow cleanup must not retain a global quit barrier"
      )
    }
    // Restored terminals defer history replay until a demand path (visibility /
    // read). Unlock replay so this fixture can interleave live overflow with the
    // blocked SQLite read — the production hang fix under test.
    surface.didBecomeVisible()
    XCTAssertEqual(
      waitForSemaphore(readStarted, timeout: 3),
      .success,
      "the test must hold the real persisted-history read before producing live output"
    )

    // 4 MiB of live output in handoff-sized slices (256 KiB). A single larger
    // payload streams through the system-output lease, which pauses while the
    // replay owns the renderer, so it could never overflow the merge during
    // the blocked read; handoff slices take the synchronous live path that
    // records replay-time live bytes.
    let liveLine = String(repeating: "L", count: 63) + "\n"
    let handoffSlice = String(repeating: liveLine, count: 4_096)
    for _ in 0..<16 {
      XCTAssertTrue(surface.appendSystemText(handoffSlice))
    }
    let newestMarker = "RC2_REPLAY_NEWEST_TAIL_\(UUID().uuidString)"
    surface.appendSystemText(newestMarker + "\n")
    XCTAssertTrue(
      surface.readTextSnapshot().text.contains(newestMarker),
      "the fixture must prove the newest marker reached the live renderer before history completes"
    )
    allowRead.signal()
    try waitForReplayCompletion(surface)

    let snapshot = surface.readTextSnapshot()
    XCTAssertTrue(
      snapshot.text.contains(newestMarker),
      "overflow handling must preserve the newest already-rendered live bytes"
    )
    XCTAssertFalse(
      snapshot.complete,
      "when the persisted prefix cannot be merged without loss, read_text must remain explicitly partial"
    )
  }

  func testLockedFileDatabaseCapsBacklogWithoutBlockingOutputAndRecoversAfterUnlock() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RC2TerminalHistoryLock-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databasePath = directory.appendingPathComponent("history.sqlite").path
    let writerDatabase = try SQLiteDB(path: databasePath)
    try Schema.migrate(writerDatabase)
    let lockDatabase = try SQLiteDB(path: databasePath)
    let repository = TerminalOutputRepository(db: writerDatabase)
    let bus = SurfaceOutputBus(flushDelay: 0, maxBatchBytes: 64 * 1024)
    let collector = OutputCollector()
    bus.sink = { frame in collector.append(frame) }
    _ = bus.currentSequence(SurfaceID())
    let surface = try TerminalSurface(
      workspaceID: WorkspaceID(),
      title: "locked history database",
      launch: .sshPlaceholder(cwd: NSTemporaryDirectory()),
      historyRepo: repository,
      outputBus: bus
    )
    defer { surface.close() }
    let surfaceID = surface.descriptor.id.value.uuidString

    surface.flushPersistedHistory()
    try waitForHistoryDrain(surface)
    collector.reset()

    try lockDatabase.execute("BEGIN IMMEDIATE;")
    var lockIsHeld = true
    defer {
      if lockIsHeld { try? lockDatabase.execute("ROLLBACK;") }
    }

    // Payloads above one PTY handoff (256 KiB) stream through a single
    // system-output lease and a concurrent one is refused as
    // `system_output_busy` before history sees it. Handoff-sized slices take the
    // synchronous live write path, which is the layer this test pins.
    // The backlog admits newest-first: crossing the cap evicts the oldest
    // buffered bytes (423c0f9c5). Mark an early slice (not the first, whose
    // first chunk may already be the one in-flight write blocked on the lock)
    // and push 5 MiB so that slice is evicted while the newest tail is kept.
    let handoffSlice = String(repeating: "x", count: 256 * 1024)
    let evictedMarker = "RC2_OUTPUT_EVICTED_BY_HISTORY_CAP_\(UUID().uuidString)"
    let newestMarker = "RC2_OUTPUT_AFTER_HISTORY_CAP_\(UUID().uuidString)"
    let startedAt = ProcessInfo.processInfo.systemUptime
    for index in 0..<20 {
      let slice = index == 1
        ? evictedMarker + String(handoffSlice.dropFirst(evictedMarker.utf8.count))
        : handoffSlice
      XCTAssertTrue(surface.appendSystemText(slice))
    }
    surface.appendSystemText(newestMarker)
    let appendElapsed = ProcessInfo.processInfo.systemUptime - startedAt
    bus.flushNow(surface.descriptor.id)

    XCTAssertLessThan(
      appendElapsed,
      1,
      "a locked SQLite writer must never block live terminal output on the main actor"
    )
    XCTAssertLessThanOrEqual(
      surface.historyOutstandingBytesForTesting,
      4 * 1024 * 1024,
      "a held database write lock must not grow accepted history memory past its hard cap"
    )
    XCTAssertGreaterThan(
      surface.runtimeHealth().historyWriteFailures,
      0,
      "output beyond the locked-writer backlog cap must fail loud instead of claiming durability"
    )
    XCTAssertTrue(surface.runtimeHealth().outputPartial)
    XCTAssertEqual(
      surface.readTextSnapshot().partialReason,
      "history_backlog_cap",
      "the mirror snapshot must expose why history is partial while live output continues"
    )
    XCTAssertTrue(
      collector.data(for: surface.descriptor.id).contains(Data(evictedMarker.utf8)),
      "history backpressure must not suppress the same bytes from the real-time mirror stream"
    )
    XCTAssertTrue(
      collector.data(for: surface.descriptor.id).contains(Data(newestMarker.utf8)),
      "live output past the history cap must keep reaching the real-time mirror stream"
    )
    print(
      "TerminalLockedHistory appendElapsed=\(appendElapsed) "
        + "outstandingBytes=\(surface.historyOutstandingBytesForTesting) "
        + "historyFailures=\(surface.runtimeHealth().historyWriteFailures)"
    )

    try lockDatabase.execute("COMMIT;")
    lockIsHeld = false
    surface.flushPersistedHistory()
    try waitForHistoryDrain(surface, timeout: 10)

    let recoveryMarker = "RC2_HISTORY_RECOVERED_\(UUID().uuidString)"
    surface.appendSystemText(recoveryMarker)
    surface.flushPersistedHistory()
    try waitForHistoryDrain(surface)
    let persisted = try repository.readWindow(
      surfaceID: surfaceID,
      maxBytes: 8 * 1024 * 1024
    ).text

    XCTAssertFalse(
      persisted.contains(evictedMarker),
      "bytes evicted at the explicit memory cap must not be misrepresented as durable"
    )
    XCTAssertTrue(
      persisted.contains(newestMarker),
      "the cap evicts oldest bytes first, so the newest output admitted under the lock must persist"
    )
    XCTAssertTrue(
      persisted.contains(recoveryMarker),
      "history persistence must accept new output after the external database lock is released"
    )
  }

  func testLiveWritePathBoundsOutstandingHistoryMemory() throws {
    let db = try SQLiteDB(path: ":memory:")
    try Schema.migrate(db)
    let surface = try TerminalSurface(
      workspaceID: WorkspaceID(),
      title: "history backlog",
      launch: .sshPlaceholder(cwd: NSTemporaryDirectory()),
      historyRepo: TerminalOutputRepository(db: db),
      outputBus: SurfaceOutputBus(flushDelay: 0)
    )
    defer {
      surface.flushPersistedHistory()
      surface.close()
    }
    // Handoff-sized slices (256 KiB) take the synchronous live write path;
    // larger payloads stream through one system-output lease and a concurrent
    // one is refused as `system_output_busy` before reaching history.
    let handoffSlice = String(repeating: "x", count: 256 * 1024)

    for _ in 0..<32 {
      XCTAssertTrue(surface.appendSystemText(handoffSlice))
    }

    XCTAssertLessThanOrEqual(
      surface.historyOutstandingBytesForTesting,
      4 * 1024 * 1024,
      "the live writer must bound accepted-but-unpersisted bytes even when output outruns SQLite callbacks"
    )
    XCTAssertGreaterThan(
      surface.runtimeHealth().historyWriteFailures,
      0,
      "crossing the history backlog budget must fail loud instead of claiming every byte was durable"
    )
    XCTAssertTrue(surface.runtimeHealth().outputPartial)
  }

  func testWeeksOfHighVolumeLiveWritesStayBoundedAndRetainNewestBytes() async throws {
    let db = try SQLiteDB(path: ":memory:")
    try Schema.migrate(db)
    let repository = TerminalOutputRepository(db: db)
    let surface = try TerminalSurface(
      workspaceID: WorkspaceID(),
      title: "history retention",
      launch: .sshPlaceholder(cwd: NSTemporaryDirectory()),
      historyRepo: repository,
      outputBus: SurfaceOutputBus(flushDelay: 0)
    )
    defer { surface.close() }
    let surfaceID = surface.descriptor.id.value.uuidString
    let payloadBytes = 1024 * 1024

    // Model more than a month of daily 1 MiB bursts without a restart. The
    // storage ceiling must depend on the rolling window, not session age.
    // Each burst is fed as four handoff-sized slices (256 KiB): a single
    // larger payload streams through the one system-output lease, and the next
    // burst would be refused as `system_output_busy` before history sees it.
    let handoffBytes = 256 * 1024
    for index in 0..<34 {
      let marker = String(format: "RC2_HISTORY_%03d|", index)
      let burst = marker + String(repeating: "x", count: payloadBytes - marker.utf8.count)
      var offset = burst.startIndex
      while offset < burst.endIndex {
        let end = burst.index(offset, offsetBy: handoffBytes, limitedBy: burst.endIndex) ?? burst.endIndex
        XCTAssertTrue(surface.appendSystemText(String(burst[offset..<end])))
        offset = end
      }
      // Bytes parked behind the one in-flight SQLite write drain on the main
      // actor, so a blocking main-thread wait cannot see them land; await the
      // barrier the way the app's quit flush does.
      let flushed = await surface.flushPersistedHistoryAsync(timeout: 10)
      XCTAssertTrue(flushed, "burst \(index) must be durable before the next one")
    }

    XCTAssertLessThanOrEqual(
      try repository.totalBytes(surfaceID: surfaceID),
      TerminalHistoryCoordinator.maxPersistedBytes,
      "the production append path must enforce the declared per-surface disk cap while the tab remains open"
    )
    let retained = try repository.readWindow(
      surfaceID: surfaceID,
      maxBytes: TerminalHistoryCoordinator.maxPersistedBytes
    ).text
    XCTAssertTrue(
      retained.contains("RC2_HISTORY_033"), "the newest retained output must survive pruning")
    XCTAssertFalse(
      retained.contains("RC2_HISTORY_000"), "retention must remove oldest chunks first")
    XCTAssertTrue(
      surface.runtimeHealth().outputPartial,
      "retention truncation must be explicit instead of presenting bounded history as complete"
    )
  }

  func testLegacyOversizedHistoryIsPrunedBeforeBoundedReplay() throws {
    let db = try SQLiteDB(path: ":memory:")
    try Schema.migrate(db)
    let repository = TerminalOutputRepository(db: db)
    let surfaceID = SurfaceID().value.uuidString
    let workspaceID = WorkspaceID().value.uuidString
    let chunkBytes = 64 * 1024
    let chunkCount = 160
    let newestMarker = Data("RC2_LEGACY_NEWEST_SCROLLBACK\n".utf8)

    for index in 0..<chunkCount {
      var data = Data(repeating: UInt8(ascii: "x"), count: chunkBytes)
      if index == chunkCount - 1 {
        data.replaceSubrange(0..<newestMarker.count, with: newestMarker)
      }
      try repository.append(
        surfaceID: surfaceID,
        workspaceID: workspaceID,
        chunkIndex: Int64(index + 1),
        data: data
      )
    }
    XCTAssertGreaterThan(
      try repository.totalBytes(surfaceID: surfaceID),
      TerminalHistoryCoordinator.maxPersistedBytes
    )

    let delegate = HistoryCoordinatorDelegateSpy()
    let coordinator = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: workspaceID
    )
    coordinator.delegate = delegate
    coordinator.prepare(restored: true)
    try waitForPreparationReady(coordinator)
    try waitForReplayCompletion(coordinator)

    XCTAssertLessThanOrEqual(
      try repository.totalBytes(surfaceID: surfaceID),
      TerminalHistoryCoordinator.maxPersistedBytes,
      "legacy databases must be normalized during background preparation, before new output arrives"
    )
    XCTAssertLessThanOrEqual(
      delegate.renderedData.count,
      256 * 1024 + TerminalHistoryCoordinator.restoredModeReset.count,
      "startup must never hydrate the complete oversized legacy transcript"
    )
    XCTAssertTrue(delegate.renderedData.contains(newestMarker))
    XCTAssertEqual(
      try repository.partialHistoryState(surfaceID: surfaceID)?.reason,
      "history_retention_cap"
    )
  }

  func testGlobalLegacyHistoryContinuesPruningWithoutAnotherTerminalWrite() throws {
    let db = try SQLiteDB(path: ":memory:")
    try Schema.migrate(db)
    let repository = TerminalOutputRepository(db: db)
    let active = "active-writer"
    let dormant = "dormant-history"
    for index in 0..<20 {
      try repository.append(
        surfaceID: active, workspaceID: nil, chunkIndex: Int64(index + 1),
        data: Data(repeating: 0x41, count: 10))
      try repository.append(
        surfaceID: dormant, workspaceID: nil, chunkIndex: Int64(index + 1),
        data: Data(repeating: 0x42, count: 10))
    }

    let finished = DispatchSemaphore(value: 0)
    TerminalHistoryCoordinator.drainGlobalRetentionForTesting(
      repository: repository,
      protectedSurfaceID: active,
      maxBytes: 220,
      maxRows: 1,
      maxDeleteBytes: 10
    ) { _ in
      finished.signal()
    }

    XCTAssertEqual(
      finished.wait(timeout: .now() + 3), .success,
      "bounded maintenance quanta must self-schedule to completion without another PTY write")
    XCTAssertLessThanOrEqual(try repository.totalBytesAllSurfaces(), 220)
    XCTAssertEqual(try repository.totalBytes(surfaceID: active), 200,
                   "the active writer remains protected while dormant history is drained")
    XCTAssertNotNil(try repository.partialHistoryState(surfaceID: dormant))
  }

  func testHiddenTerminalMemoryReclaimKeepsNewestOrderedOutputAndRebuildsOnReveal() throws {
    // WHY: an inactive tab may run for weeks. Reclaim must drop old screen rows
    // and native scrollback, keep accepting ordered output, and restore a usable
    // active parser/mirror when the tab is selected again.
    let surface = try TerminalSurface(
      workspaceID: WorkspaceID(),
      title: "aggregate memory reclaim",
      launch: .sshPlaceholder(cwd: NSTemporaryDirectory()),
      outputBus: SurfaceOutputBus(flushDelay: 0)
    )
    defer { surface.close() }
    let beforeMarker = "RC2_BEFORE_RECLAIM_\(UUID().uuidString)"
    let hiddenMarker = "RC2_AFTER_RECLAIM_\(UUID().uuidString)"
    surface.appendSystemText(
      (0..<600).map { "screen row \($0) " + String(repeating: "x", count: 80) }
        .joined(separator: "\r\n") + "\r\n\(beforeMarker)\r\n"
    )
    _ = surface.readTextSnapshot()
    surface.didBecomeHidden()
    let retainedBefore = surface.terminalMemoryRetainedBytesForTesting

    surface.reclaimTerminalMemoryForTesting()

    XCTAssertTrue(surface.terminalMemoryWasReclaimedForTesting)
    XCTAssertLessThan(surface.terminalMemoryRetainedBytesForTesting, retainedBefore)
    surface.appendSystemText("\r\n\(hiddenMarker)\r\n")
    XCTAssertTrue(surface.readTextSnapshot().text.contains(hiddenMarker))

    surface.didBecomeVisible()

    XCTAssertFalse(surface.terminalMemoryWasReclaimedForTesting)
    let rebuilt = surface.readTextSnapshot().text
    XCTAssertTrue(rebuilt.contains(beforeMarker))
    XCTAssertTrue(rebuilt.contains(hiddenMarker))
    XCTAssertLessThan(
      rebuilt.range(of: beforeMarker)!.lowerBound,
      rebuilt.range(of: hiddenMarker)!.lowerBound
    )
  }

  func testVisibleTerminalMemoryCompactionKeepsCurrentFrameAndInputOwner() throws {
    // WHY: visible is a priority, not an exemption. Its pressure pass may drop
    // old scrollback, but must leave the current frame and PTY input ownership.
    let surface = try TerminalSurface(
      workspaceID: WorkspaceID(),
      title: "visible aggregate memory compaction",
      launch: .sshPlaceholder(cwd: NSTemporaryDirectory()),
      outputBus: SurfaceOutputBus(flushDelay: 0)
    )
    defer { surface.close() }
    let frameMarker = "RC2_VISIBLE_FRAME_\(UUID().uuidString)"
    surface.appendSystemText(
      (0..<600).map { "visible row \($0) " + String(repeating: "v", count: 80) }
        .joined(separator: "\r\n") + "\r\n\(frameMarker)\r\n"
    )
    _ = surface.readTextSnapshot()
    let retainedBefore = surface.terminalMemoryRetainedBytesForTesting
    var input = Data()
    surface.replaceInputCaptureForTesting { input.append($0) }

    surface.reclaimTerminalMemoryForTesting()
    surface.injectGhosttyInputWriteForTesting(Data("typed-after-compaction".utf8))

    XCTAssertLessThan(surface.terminalMemoryRetainedBytesForTesting, retainedBefore)
    XCTAssertTrue(surface.readTextSnapshot().text.contains(frameMarker))
    XCTAssertEqual(String(decoding: input, as: UTF8.self), "typed-after-compaction")
    XCTAssertTrue(surface.ghosttyInputHandlerPresentForTesting)
  }

  private func waitForPreparationReady(
    _ coordinator: TerminalHistoryCoordinator,
    timeout: TimeInterval = 3
  ) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if case .ready = coordinator.preparationStateForTesting { return }
      if case .failed = coordinator.preparationStateForTesting {
        XCTFail("history prepare failed before becoming ready")
        throw HistoryWaitTimeout()
      }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    XCTFail("timed out waiting for history prepare to become ready")
    throw HistoryWaitTimeout()
  }

  @discardableResult
  private func waitForSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: TimeInterval
  ) -> DispatchTimeoutResult {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if semaphore.wait(timeout: .now()) == .success {
        return .success
      }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return semaphore.wait(timeout: .now())
  }

  private func posixPermissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
    return permissions.intValue & 0o777
  }

  private func waitForPreparation(
    _ coordinator: TerminalHistoryCoordinator,
    expected: TerminalHistoryCoordinator.PreparationState,
    timeout: TimeInterval = 2
  ) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if coordinator.preparationStateForTesting == expected { return }
      RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    XCTFail(
      "timed out waiting for history preparation \(expected); current=\(coordinator.preparationStateForTesting)"
    )
    throw HistoryWaitTimeout()
  }

  private func waitForPreparationAsync(
    _ coordinator: TerminalHistoryCoordinator,
    expected: TerminalHistoryCoordinator.PreparationState,
    timeout: TimeInterval = 2
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if coordinator.preparationStateForTesting == expected { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail(
      "timed out waiting for history preparation \(expected); current=\(coordinator.preparationStateForTesting)"
    )
    throw HistoryWaitTimeout()
  }

  private func waitForAnyPreparationReadyAsync(
    _ coordinator: TerminalHistoryCoordinator,
    timeout: TimeInterval = 2
  ) async throws -> Int64 {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if case .ready(let nextChunkIndex) = coordinator.preparationStateForTesting {
        return nextChunkIndex
      }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail(
      "timed out waiting for any ready history preparation; current=\(coordinator.preparationStateForTesting)"
    )
    throw HistoryWaitTimeout()
  }

  private func waitForSurfacePreparationReadyAsync(
    _ surface: TerminalSurface,
    timeout: TimeInterval = 2
  ) async throws -> Int64 {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if case .ready(let nextChunkIndex) = surface.historyPreparationStateForTesting {
        return nextChunkIndex
      }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail(
      "timed out waiting for surface history preparation; current=\(surface.historyPreparationStateForTesting)"
    )
    throw HistoryWaitTimeout()
  }

  private func waitForHistoryDrain(
    _ surface: TerminalSurface,
    timeout: TimeInterval = 6
  ) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if surface.historyOutstandingBytesForTesting == 0 { return }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    XCTFail(
      "timed out waiting for history backlog to drain; remaining=\(surface.historyOutstandingBytesForTesting)"
    )
    throw HistoryWaitTimeout()
  }

  private func waitForHistoryDrainAsync(
    _ surface: TerminalSurface,
    timeout: TimeInterval = 6
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if surface.historyOutstandingBytesForTesting == 0 { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail(
      "timed out waiting for async history backlog to drain; remaining=\(surface.historyOutstandingBytesForTesting)"
    )
    throw HistoryWaitTimeout()
  }

  private func waitForCoordinatorHistoryDrainAsync(
    _ coordinator: TerminalHistoryCoordinator,
    timeout: TimeInterval = 2
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if coordinator.outstandingBytes == 0 { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail(
      "timed out waiting for coordinator history backlog; remaining=\(coordinator.outstandingBytes)"
    )
    throw HistoryWaitTimeout()
  }

  private func waitForLiveClearCompletionAsync(
    _ surface: TerminalSurface,
    timeout: TimeInterval = 2
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while surface.historyLiveClearInFlightForTesting, Date() < deadline {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    guard !surface.historyLiveClearInFlightForTesting else {
      XCTFail("timed out waiting for live history clear acknowledgement")
      throw HistoryWaitTimeout()
    }
  }

  private func waitForLiveClearCompletionAsync(
    _ coordinator: TerminalHistoryCoordinator,
    timeout: TimeInterval = 2
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while coordinator.liveClearInFlightForTesting, Date() < deadline {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    guard !coordinator.liveClearInFlightForTesting else {
      XCTFail("timed out waiting for coordinator live history clear acknowledgement")
      throw HistoryWaitTimeout()
    }
  }

  private func waitForReplayCompletion(
    _ surface: TerminalSurface,
    timeout: TimeInterval = 6
  ) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !surface.historyReplayInFlightForTesting { return }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    XCTFail("timed out waiting for restored history replay completion")
    throw HistoryWaitTimeout()
  }

  private func waitForReplayCompletion(
    _ coordinator: TerminalHistoryCoordinator,
    timeout: TimeInterval = 6
  ) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !coordinator.replayInFlight { return }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    XCTFail("timed out waiting for coordinator history replay completion")
    throw HistoryWaitTimeout()
  }

  private func occurrences(of needle: Data, in haystack: Data) -> Int {
    guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
    var count = 0
    var searchStart = haystack.startIndex
    while searchStart <= haystack.endIndex - needle.count,
          let range = haystack.range(of: needle, in: searchStart..<haystack.endIndex) {
      count += 1
      searchStart = range.upperBound
    }
    return count
  }

  private struct HistoryWaitTimeout: Error {}

  private final class FailingFirstHistoryRead: @unchecked Sendable {
    enum Failure: Error { case intentionalFirstReadFailure }

    let firstReadStarted = DispatchSemaphore(value: 0)
    let allowFirstReadToFail = DispatchSemaphore(value: 0)
    private let repository: TerminalOutputRepository
    private let lock = NSLock()
    private var attempts = 0

    init(repository: TerminalOutputRepository) {
      self.repository = repository
    }

    func read(surfaceID: String) throws -> TerminalOutputWindow {
      lock.lock()
      attempts += 1
      let attempt = attempts
      lock.unlock()
      if attempt == 1 {
        firstReadStarted.signal()
        _ = allowFirstReadToFail.wait(timeout: .now() + 10)
        throw Failure.intentionalFirstReadFailure
      }
      return try repository.readWindow(surfaceID: surfaceID)
    }
  }

  private final class HistoryCoordinatorDelegateSpy: TerminalHistoryCoordinatorDelegate {
    var terminalHistoryIsClosing = false
    var renderedData = Data()
    var replayReadFailureCount = 0
    var replayReadRecoveryCount = 0
    var replayLiveCapCount = 0
    var durablePartialReasons: [String] = []

    func terminalHistoryCoordinator(
      _ coordinator: TerminalHistoryCoordinator,
      didEncounter issue: TerminalHistoryCoordinator.Issue
    ) {
      if case .replayReadFailure = issue {
        replayReadFailureCount += 1
      }
      if case .replayReadRecovered = issue {
        replayReadRecoveryCount += 1
      }
      if case .replayLiveCap = issue {
        replayLiveCapCount += 1
      }
      if case .durablePartial(let reason) = issue {
        durablePartialReasons.append(reason)
      }
    }

    func terminalHistoryCoordinator(
      _ coordinator: TerminalHistoryCoordinator,
      didPrepareReplay data: Data
    ) {
      renderedData = data
    }
  }

  private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [SurfaceOutputBus.OutputFrame] = []

    func append(_ frame: SurfaceOutputBus.OutputFrame) {
      lock.lock()
      frames.append(frame)
      lock.unlock()
    }

    func reset() {
      lock.lock()
      frames.removeAll(keepingCapacity: true)
      lock.unlock()
    }

    func data(for surfaceID: SurfaceID) -> Data {
      lock.lock()
      defer { lock.unlock() }
      return frames.lazy
        .filter { $0.surfaceID == surfaceID }
        .reduce(into: Data()) { $0.append($1.data) }
    }
  }

  private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
      lock.lock()
      defer { lock.unlock() }
      count += 1
      return count
    }

    func claimFirst() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard count == 0 else { return false }
      count = 1
      return true
    }

    var value: Int {
      lock.lock()
      defer { lock.unlock() }
      return count
    }
  }
}
