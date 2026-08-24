import XCTest
import Darwin
import CoreModel
@testable import Persistence

final class AgentThreadRunningIDsPerformanceTests: XCTestCase {
    private struct Sample {
        let wallMilliseconds: Double
        let cpuMilliseconds: Double
        let rowsDecoded: Int
        let allocationByteProxy: Int
        let result: Set<AgentThreadID>
    }

    func test_runningThreadIdsMatchesFullThreadDecodeForZeroOneAndManyRunningThreads() throws {
        let (repository, _) = try makeRepository(label: "equivalence")

        try assertProjectedIDsMatchLegacy(repository, expected: [])

        let completed = AgentThread(title: "completed", provider: .codex, model: "gpt-5.5")
        try repository.upsert(completed)
        try assertProjectedIDsMatchLegacy(repository, expected: [])

        var firstRunning = AgentThread(title: "first running", provider: .claude, model: "claude-opus-4-7")
        firstRunning.status = .running
        try repository.upsert(firstRunning)
        try assertProjectedIDsMatchLegacy(repository, expected: [firstRunning.id])

        var expected: Set<AgentThreadID> = [firstRunning.id]
        for index in 0..<7 {
            var thread = AgentThread(title: "running \(index)", provider: .codex, model: "gpt-5.5")
            thread.status = .running
            try repository.upsert(thread)
            expected.insert(thread.id)
        }
        try assertProjectedIDsMatchLegacy(repository, expected: expected)
    }

    /// WHY: a malformed persisted ID cannot be represented in the active-ID
    /// protection set. Silently skipping it would let the reaper continue from
    /// an incomplete view, so the repository must fail closed instead.
    func test_runningThreadIdsFailsClosedForMalformedRunningID() throws {
        let (repository, database) = try makeRepository(label: "malformed-id")
        try insertRawThread(database: database, id: "not-a-uuid", status: "running")

        XCTAssertThrowsError(try repository.runningThreadIds()) { error in
            XCTAssertEqual(
                error as? AgentThreadPersistenceError,
                .invalidThreadID("not-a-uuid"),
                "the reaper must abort rather than treat an unrepresentable running row as inactive"
            )
        }
    }

    /// WHY: running routing state is part of the persisted thread record that
    /// the legacy list path validated. If it is corrupt, active-session cleanup
    /// must stop before making any termination decision.
    func test_runningThreadIdsFailsClosedForCorruptRunningRoutingSchema() throws {
        let (repository, database) = try makeRepository(label: "corrupt-routing")
        let routing = AgentRoutingConfiguration(
            mode: .auto,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "gpt-5.5"),
            eligibleProviders: [.codex],
            revision: 3
        )
        var running = AgentThread(
            title: "corrupt running routing",
            provider: .codex,
            model: "gpt-5.5",
            routingConfiguration: routing
        )
        running.status = .running
        try repository.upsert(running)
        try database.execute(
            "UPDATE agent_thread_routing SET configuration_json = '{}' "
                + "WHERE thread_id = '\(running.id.value.uuidString)';"
        )

        XCTAssertThrowsError(try repository.runningThreadIds()) { error in
            XCTAssertEqual(
                error as? AgentRoutingPersistenceError,
                .invalidConfigurationJSON,
                "running routing schema corruption must retain the legacy typed failure"
            )
        }
    }

    /// WHY: routing is not an activity signal. Corrupt routing attached to a
    /// non-running row must not force the 30-second reaper back to decoding all
    /// retained history; only corrupt running persistence is safety-critical.
    func test_runningThreadIdsDoesNotDecodeCorruptRoutingForNonrunningThread() throws {
        let (repository, database) = try makeRepository(label: "terminal-corrupt-routing")
        let routing = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "gpt-5.5"),
            eligibleProviders: [.codex],
            revision: 1
        )
        let completed = AgentThread(
            title: "completed corrupt routing",
            provider: .codex,
            model: "gpt-5.5",
            routingConfiguration: routing
        )
        try repository.upsert(completed)
        try database.execute(
            "UPDATE agent_thread_routing SET configuration_json = '{}' "
                + "WHERE thread_id = '\(completed.id.value.uuidString)';"
        )

        XCTAssertEqual(
            try repository.runningThreadIds(),
            [],
            "terminal routing corruption cannot make a persisted thread active"
        )
    }

    /// Same-process, warmed A/B for the 30-second provider-session reaper tick.
    /// The legacy side executes the exact full list/filter path removed from
    /// AppContext; the candidate decodes only matching IDs and their routing
    /// invariants from the same SQLite connection/page cache. Process CPU
    /// corroborates the primary wall gate.
    func test_benchmarkRunningThreadIDProjectionImprovesTenThousandRowReaperTick() throws {
        guard ProcessInfo.processInfo.environment["RC2_PROVIDER_REAPER_BENCHMARK"] == "1" else {
            throw XCTSkip("Set RC2_PROVIDER_REAPER_BENCHMARK=1 to run the provider reaper A/B benchmark.")
        }

        let historyCount = 10_000
        let runningCount = 8
        let warmupCount = 2
        let measuredCount = 7
        let iterationsPerSample = 3
        let (repository, database) = try makeRepository(label: "benchmark")
        let expected = try seedHistory(
            database: database,
            historyCount: historyCount,
            runningCount: runningCount
        )

        for _ in 0..<warmupCount {
            _ = try measureLegacy(repository, iterations: iterationsPerSample)
            _ = try measureProjection(repository, iterations: iterationsPerSample)
        }

        var legacy: [Sample] = []
        var projected: [Sample] = []
        for index in 0..<measuredCount {
            if index.isMultiple(of: 2) {
                legacy.append(try measureLegacy(repository, iterations: iterationsPerSample))
                projected.append(try measureProjection(repository, iterations: iterationsPerSample))
            } else {
                projected.append(try measureProjection(repository, iterations: iterationsPerSample))
                legacy.append(try measureLegacy(repository, iterations: iterationsPerSample))
            }
        }

        XCTAssertTrue(legacy.allSatisfy { $0.result == expected })
        XCTAssertTrue(projected.allSatisfy { $0.result == expected })
        XCTAssertTrue(legacy.allSatisfy { $0.rowsDecoded == historyCount })
        XCTAssertTrue(projected.allSatisfy { $0.rowsDecoded == runningCount })

        let legacyWall = median(legacy.map(\.wallMilliseconds))
        let projectedWall = median(projected.map(\.wallMilliseconds))
        let legacyCPU = median(legacy.map(\.cpuMilliseconds))
        let projectedCPU = median(projected.map(\.cpuMilliseconds))
        let wallImprovement = improvement(before: legacyWall, after: projectedWall)
        let cpuImprovement = improvement(before: legacyCPU, after: projectedCPU)
        let legacyAllocationProxy = legacy[0].allocationByteProxy
        let projectedAllocationProxy = projected[0].allocationByteProxy
        let allocationProxyReduction = improvement(
            before: Double(legacyAllocationProxy),
            after: Double(projectedAllocationProxy)
        )

        print("PROVIDER_REAPER_BENCHMARK warmups=\(warmupCount) n=\(measuredCount) history_rows=\(historyCount) running_rows=\(runningCount) iterations_per_sample=\(iterationsPerSample)")
        print("PROVIDER_REAPER_BENCHMARK legacy_wall_ms=\(legacy.map(\.wallMilliseconds))")
        print("PROVIDER_REAPER_BENCHMARK projected_wall_ms=\(projected.map(\.wallMilliseconds))")
        print("PROVIDER_REAPER_BENCHMARK legacy_cpu_ms=\(legacy.map(\.cpuMilliseconds))")
        print("PROVIDER_REAPER_BENCHMARK projected_cpu_ms=\(projected.map(\.cpuMilliseconds))")
        print("PROVIDER_REAPER_BENCHMARK legacy_wall_median_ms=\(legacyWall) projected_wall_median_ms=\(projectedWall) wall_improvement_percent=\(wallImprovement)")
        print("PROVIDER_REAPER_BENCHMARK legacy_cpu_median_ms=\(legacyCPU) projected_cpu_median_ms=\(projectedCPU) cpu_improvement_percent=\(cpuImprovement)")
        print("PROVIDER_REAPER_BENCHMARK legacy_rows_decoded=\(legacy[0].rowsDecoded) projected_rows_decoded=\(projected[0].rowsDecoded)")
        print("PROVIDER_REAPER_BENCHMARK legacy_allocation_byte_proxy=\(legacyAllocationProxy) projected_allocation_byte_proxy=\(projectedAllocationProxy) allocation_proxy_reduction_percent=\(allocationProxyReduction)")

        XCTAssertGreaterThan(
            wallImprovement,
            5,
            "the production ID projection must improve median 10k-history reaper wall time by more than 5%"
        )
    }

    private func assertProjectedIDsMatchLegacy(
        _ repository: AgentThreadRepository,
        expected: Set<AgentThreadID>
    ) throws {
        let legacy = Set(try repository.list().filter { $0.status == .running }.map(\.id))
        XCTAssertEqual(legacy, expected)
        XCTAssertEqual(try repository.runningThreadIds(), legacy)
    }

    private func measureLegacy(
        _ repository: AgentThreadRepository,
        iterations: Int
    ) throws -> Sample {
        let cpuStart = processCPUNanoseconds()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        var result: Set<AgentThreadID> = []
        var rowsDecoded = 0
        for _ in 0..<iterations {
            let threads = try repository.list()
            rowsDecoded += threads.count
            result = Set(threads.lazy.filter { $0.status == .running }.map(\.id))
        }
        let wallEnd = DispatchTime.now().uptimeNanoseconds
        let cpuEnd = processCPUNanoseconds()
        return Sample(
            wallMilliseconds: milliseconds(wallEnd - wallStart) / Double(iterations),
            cpuMilliseconds: milliseconds(cpuEnd - cpuStart) / Double(iterations),
            rowsDecoded: rowsDecoded / iterations,
            allocationByteProxy: rowsDecoded * MemoryLayout<AgentThread>.stride / iterations,
            result: result
        )
    }

    private func measureProjection(
        _ repository: AgentThreadRepository,
        iterations: Int
    ) throws -> Sample {
        let cpuStart = processCPUNanoseconds()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        var result: Set<AgentThreadID> = []
        var rowsDecoded = 0
        for _ in 0..<iterations {
            result = try repository.runningThreadIds()
            rowsDecoded += result.count
        }
        let wallEnd = DispatchTime.now().uptimeNanoseconds
        let cpuEnd = processCPUNanoseconds()
        return Sample(
            wallMilliseconds: milliseconds(wallEnd - wallStart) / Double(iterations),
            cpuMilliseconds: milliseconds(cpuEnd - cpuStart) / Double(iterations),
            rowsDecoded: rowsDecoded / iterations,
            allocationByteProxy: rowsDecoded * MemoryLayout<AgentThreadID>.stride / iterations,
            result: result
        )
    }

    private func seedHistory(
        database: SQLiteDB,
        historyCount: Int,
        runningCount: Int
    ) throws -> Set<AgentThreadID> {
        let routing = AgentRoutingConfiguration(
            mode: .auto,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "gpt-5.5"),
            eligibleProviders: [.codex, .claude],
            policyDigest: String(repeating: "b", count: 64),
            revision: 4,
            updatedAt: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let routingData = try JSONEncoder().encode(routing)
        guard let routingJSON = String(data: routingData, encoding: .utf8) else {
            throw AgentRoutingPersistenceError.invalidConfigurationJSON
        }
        var running: Set<AgentThreadID> = []
        try database.performSync { database in
            try database.transaction {
                let statement = try database.prepare("""
                    INSERT INTO agent_threads(id, title, provider, model, provider_thread_id, status, created_at, updated_at)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?);
                """)
                let routingStatement = try database.prepare("""
                    INSERT INTO agent_thread_routing(thread_id, mode, configuration_json, revision, updated_at)
                    VALUES(?, ?, ?, ?, ?);
                """)
                for index in 0..<historyCount {
                    let rawID = String(format: "00000000-0000-0000-0000-%012d", index + 1)
                    let id = AgentThreadID(UUID(uuidString: rawID)!)
                    let isRunning = index < runningCount
                    if isRunning { running.insert(id) }
                    statement.reset()
                    try statement.bind(1, rawID)
                    try statement.bind(2, "Historical provider thread \(index) " + String(repeating: "x", count: 64))
                    try statement.bind(3, index.isMultiple(of: 2) ? "codex" : "claude")
                    try statement.bind(4, index.isMultiple(of: 2) ? "gpt-5.5" : "claude-opus-4-7")
                    try statement.bind(5, "provider-session-\(index)")
                    try statement.bind(6, isRunning ? "running" : "completed")
                    try statement.bind(7, "2026-01-01T00:00:00.000Z")
                    try statement.bind(8, "2026-01-01T00:00:00.000Z")
                    _ = try statement.step()
                    if isRunning {
                        routingStatement.reset()
                        try routingStatement.bind(1, rawID)
                        try routingStatement.bind(2, routing.mode.rawValue)
                        try routingStatement.bind(3, routingJSON)
                        try routingStatement.bind(4, routing.revision)
                        try routingStatement.bind(5, "2026-01-01T00:00:00.000Z")
                        _ = try routingStatement.step()
                    }
                }
            }
        }
        return running
    }

    private func insertRawThread(database: SQLiteDB, id: String, status: String) throws {
        let statement = try database.prepare("""
            INSERT INTO agent_threads(id, title, provider, model, status, created_at, updated_at)
            VALUES(?, ?, ?, ?, ?, ?, ?);
        """)
        try statement.bind(1, id)
        try statement.bind(2, "raw persistence fixture")
        try statement.bind(3, "codex")
        try statement.bind(4, "gpt-5.5")
        try statement.bind(5, status)
        try statement.bind(6, "2026-01-01T00:00:00.000Z")
        try statement.bind(7, "2026-01-01T00:00:00.000Z")
        _ = try statement.step()
    }

    private func makeRepository(label: String) throws -> (AgentThreadRepository, SQLiteDB) {
        let fallback = FileManager.default.temporaryDirectory.path
        let root = ProcessInfo.processInfo.environment["RC2_SANDBOX_APP_SUPPORT"] ?? fallback
        let directory = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("ProviderReaperTests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let (_, database) = try Bootstrap(channel: .debug, appSupportOverride: directory.path).run()
        return (AgentThreadRepository(db: database), database)
    }

    private func processCPUNanoseconds() -> UInt64 {
        var value = timespec()
        precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    private func milliseconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }

    private func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    private func improvement(before: Double, after: Double) -> Double {
        guard before > 0 else { return 0 }
        return 100 * (before - after) / before
    }
}
