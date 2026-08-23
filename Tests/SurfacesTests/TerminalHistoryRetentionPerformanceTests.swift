import Darwin
import XCTest

@testable import Persistence
@testable import Surfaces

@MainActor
final class TerminalHistoryRetentionPerformanceTests: XCTestCase {
  private struct Ledger: Equatable {
    let totalBytes: Int
    let chunkCount: Int
    let firstChunkIndex: Int64?
    let lastChunkIndex: Int64?
    let partialReason: String?
    let partialNextChunkIndex: Int64?
  }

  private struct Sample {
    let wallMilliseconds: Double
    let cpuMilliseconds: Double
    let surfaceSUMCalls: Int
    let globalPruneCalls: Int
    let ledger: Ledger
  }

  private enum TestTimeout: Error {
    case expired
  }

  /// Same-process A/B using real file-backed SQLite and production writes.
  /// Sixteen MiB represents 256 production-sized chunks and crosses the 8 MiB
  /// rolling cap, so both steady cadence and actual pruning are measured.
  func testMicrobenchIntervalGlobalRetentionAvoidsPerChunkGlobalPrune() throws {
    let warmup = 2
    let sampleCount = 5
    let chunkBytes = 64 * 1024
    let chunkCount = 256
    let eagerInterval = 1
    let candidateInterval = 1024 * 1024

    for _ in 0..<warmup {
      _ = try measure(
        retentionInterval: eagerInterval,
        chunkBytes: chunkBytes,
        chunkCount: chunkCount
      )
      _ = try measure(
        retentionInterval: candidateInterval,
        chunkBytes: chunkBytes,
        chunkCount: chunkCount
      )
    }

    var before: [Sample] = []
    var after: [Sample] = []
    for sampleIndex in 0..<sampleCount {
      if sampleIndex.isMultiple(of: 2) {
        before.append(try measure(
          retentionInterval: eagerInterval,
          chunkBytes: chunkBytes,
          chunkCount: chunkCount
        ))
        after.append(try measure(
          retentionInterval: candidateInterval,
          chunkBytes: chunkBytes,
          chunkCount: chunkCount
        ))
      } else {
        after.append(try measure(
          retentionInterval: candidateInterval,
          chunkBytes: chunkBytes,
          chunkCount: chunkCount
        ))
        before.append(try measure(
          retentionInterval: eagerInterval,
          chunkBytes: chunkBytes,
          chunkCount: chunkCount
        ))
      }
    }

    let beforeWall = median(before.map(\.wallMilliseconds))
    let afterWall = median(after.map(\.wallMilliseconds))
    let beforeCPU = median(before.map(\.cpuMilliseconds))
    let afterCPU = median(after.map(\.cpuMilliseconds))
    let wallImprovement = (beforeWall - afterWall) / beforeWall * 100
    let cpuImprovement = (beforeCPU - afterCPU) / beforeCPU * 100
    let expectedLedger = try XCTUnwrap(before.first?.ledger)

    XCTAssertTrue(before.allSatisfy { $0.globalPruneCalls == chunkCount },
                  "eager baseline checks every completed write")
    XCTAssertTrue(after.allSatisfy { $0.globalPruneCalls == 16 },
                  "first + fifteen full 1 MiB intervals")
    XCTAssertTrue(before.allSatisfy { $0.surfaceSUMCalls == 383 })
    XCTAssertTrue(after.allSatisfy { $0.surfaceSUMCalls == 383 },
                  "the optimization must preserve per-write surface hard-cap checks")
    XCTAssertTrue(before.allSatisfy { $0.ledger == expectedLedger })
    XCTAssertTrue(after.allSatisfy { $0.ledger == expectedLedger })
    XCTAssertEqual(expectedLedger.totalBytes, TerminalHistoryCoordinator.maxPersistedBytes)
    XCTAssertEqual(expectedLedger.chunkCount, 129)
    XCTAssertEqual(expectedLedger.firstChunkIndex, 128)
    XCTAssertEqual(expectedLedger.lastChunkIndex, 256)
    XCTAssertEqual(expectedLedger.partialReason, "history_retention_cap")
    XCTAssertEqual(expectedLedger.partialNextChunkIndex, 257)

    NSLog(
      "[perf-proof] terminalHistoryRetention volume_mib=16 chunks=%d warmup=%d n=%d eager_wall_ms=%@ interval_wall_ms=%@ wall_improvement_pct=%.2f eager_cpu_ms=%@ interval_cpu_ms=%@ cpu_improvement_pct=%.2f eager_surface_sum=%@ interval_surface_sum=%@ eager_global_prune=%@ interval_global_prune=%@ before_wall=%@ after_wall=%@ before_cpu=%@ after_cpu=%@",
      chunkCount, warmup, sampleCount,
      String(beforeWall), String(afterWall), wallImprovement,
      String(beforeCPU), String(afterCPU), cpuImprovement,
      String(describing: before.map(\.surfaceSUMCalls)),
      String(describing: after.map(\.surfaceSUMCalls)),
      String(describing: before.map(\.globalPruneCalls)),
      String(describing: after.map(\.globalPruneCalls)),
      String(describing: before.map(\.wallMilliseconds)),
      String(describing: after.map(\.wallMilliseconds)),
      String(describing: before.map(\.cpuMilliseconds)),
      String(describing: after.map(\.cpuMilliseconds))
    )
    XCTAssertGreaterThan(
      wallImprovement,
      5,
      "1 MiB retention cadence must improve 256 real SQLite chunk writes by >5%"
    )
    XCTAssertGreaterThan(
      cpuImprovement,
      5,
      "1 MiB retention cadence must reduce process CPU for the same SQLite ledger by >5%"
    )
  }

  private func measure(
    retentionInterval: Int,
    chunkBytes: Int,
    chunkCount: Int
  ) throws -> Sample {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RC2TerminalRetentionPerf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try SQLiteDB(path: directory.appendingPathComponent("history.sqlite").path)
    try Schema.migrate(database)
    let repository = TerminalOutputRepository(db: database)
    let surfaceID = UUID().uuidString
    let coordinator = TerminalHistoryCoordinator(
      repository: repository,
      surfaceID: surfaceID,
      workspaceID: UUID().uuidString,
      retentionCheckIntervalForTesting: retentionInterval
    )
    coordinator.prepare(restored: false)
    try waitForPreparation(coordinator)
    let counter = TerminalRetentionPerformanceStatementCounter()
    database.beforeStatementStepForTesting = counter.observe
    let chunk = Data(repeating: 0x58, count: chunkBytes)

    let cpuStart = processCPUSeconds()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<chunkCount {
      coordinator.enqueue(chunk)
      if coordinator.outstandingBytes >= 3 * 1024 * 1024 {
        try waitForOutstanding(coordinator, atMost: 1024 * 1024)
      }
    }
    try waitForOutstanding(coordinator, atMost: 0)
    let wallEnd = DispatchTime.now().uptimeNanoseconds
    let cpuEnd = processCPUSeconds()
    let counts = counter.snapshot()
    database.beforeStatementStepForTesting = nil
    let retained = try repository.readWindow(
      surfaceID: surfaceID,
      maxBytes: TerminalHistoryCoordinator.maxPersistedBytes + chunkBytes
    )
    let partial = try repository.partialHistoryState(surfaceID: surfaceID)
    return Sample(
      wallMilliseconds: Double(wallEnd - wallStart) / 1_000_000,
      cpuMilliseconds: (cpuEnd - cpuStart) * 1_000,
      surfaceSUMCalls: counts.surfaceSUMCalls,
      globalPruneCalls: counts.globalPruneCalls,
      ledger: Ledger(
        totalBytes: try repository.totalBytes(surfaceID: surfaceID),
        chunkCount: retained.chunks.count,
        firstChunkIndex: retained.chunks.first?.chunkIndex,
        lastChunkIndex: retained.chunks.last?.chunkIndex,
        partialReason: partial?.reason,
        partialNextChunkIndex: partial?.nextChunkIndex
      )
    )
  }

  private func processCPUSeconds() -> Double {
    var usage = rusage()
    _ = getrusage(RUSAGE_SELF, &usage)
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
    let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    return user + system
  }

  private func median(_ values: [Double]) -> Double {
    values.sorted()[values.count / 2]
  }

  private func waitForPreparation(
    _ coordinator: TerminalHistoryCoordinator,
    timeout: TimeInterval = 5
  ) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if case .ready = coordinator.preparationStateForTesting { return }
      RunLoop.main.run(until: Date().addingTimeInterval(0.002))
    }
    throw TestTimeout.expired
  }

  private func waitForOutstanding(
    _ coordinator: TerminalHistoryCoordinator,
    atMost target: Int,
    timeout: TimeInterval = 10
  ) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while coordinator.outstandingBytes > target, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.002))
    }
    guard coordinator.outstandingBytes <= target else { throw TestTimeout.expired }
  }

}

private final class TerminalRetentionPerformanceStatementCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var surfaceSUMCalls = 0
  private var globalPruneCalls = 0

  func observe(_ sql: String) {
    let isSurface = sql.contains(
      "SELECT COALESCE(SUM(byte_count), 0) FROM terminal_output_chunks WHERE surface_id = ?"
    )
    let isGlobal = sql.contains(
      "SELECT COALESCE(SUM(byte_count), 0) FROM terminal_output_chunks;"
    )
    guard isSurface || isGlobal else { return }
    lock.lock()
    if isSurface { surfaceSUMCalls += 1 }
    if isGlobal { globalPruneCalls += 1 }
    lock.unlock()
  }

  func snapshot() -> (surfaceSUMCalls: Int, globalPruneCalls: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (surfaceSUMCalls, globalPruneCalls)
  }
}
