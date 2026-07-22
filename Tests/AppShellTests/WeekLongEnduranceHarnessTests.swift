import Foundation
import XCTest

@testable import AgentRuntime
@testable import AppShell
@testable import CoreModel
@testable import Persistence
@testable import Surfaces

/// Accelerated, deterministic endurance proof for the bounded Agent + Terminal
/// authorities. This never opens the user's database and never inspects or
/// signals user processes. It is not a substitute for a wall-clock soak or a
/// physical 8 GiB canary; those remain release gates outside XCTest.
final class WeekLongEnduranceHarnessTests: XCTestCase {
    private struct Workload {
        let threads: Int
        let surfaces: Int
        let eventsPerThreadPerDay: Int
        let terminalChunksPerSurfacePerDay: Int
        let payloadBytes: Int
        let physicalCeilingBytes: Int64
        let dailyLatencyCeiling: TimeInterval

        static let smoke = Workload(
            threads: 4,
            surfaces: 8,
            eventsPerThreadPerDay: 8,
            terminalChunksPerSurfacePerDay: 2,
            payloadBytes: 8 * 1_024,
            physicalCeilingBytes: 32 * 1_024 * 1_024,
            dailyLatencyCeiling: 5
        )

        static let release = Workload(
            threads: 12,
            surfaces: 24,
            eventsPerThreadPerDay: 24,
            terminalChunksPerSurfacePerDay: 4,
            payloadBytes: 32 * 1_024,
            physicalCeilingBytes: 128 * 1_024 * 1_024,
            dailyLatencyCeiling: 20
        )
    }

    private final class Store {
        let database: SQLiteDB
        let runs: AgentRunRepository
        let terminals: TerminalOutputRepository
        let budget: LocalStorageBudgetManager

        init(path: String) throws {
            database = try SQLiteDB(path: path)
            try Schema.migrate(database)
            runs = AgentRunRepository(db: database)
            terminals = TerminalOutputRepository(db: database)
            budget = LocalStorageBudgetManager(db: database)
        }
    }

    private final class OwnedTestSidecarSpawner: DistillProcessSpawning, @unchecked Sendable {
        private(set) var spawnCount = 0

        func spawn(executableURL: URL, arguments: [String]) throws -> DistillSpawnResult {
            spawnCount += 1
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            return DistillSpawnResult(
                process: process,
                stdoutHandle: stdout.fileHandleForReading,
                stderrHandle: stderr.fileHandleForReading
            )
        }
    }

    func test_virtualFourteenDayEnduranceSmokeStaysBounded() async throws {
        try await runVirtualFourteenDays(.smoke)
    }

    func test_virtualFourteenDayEnduranceReleaseGateStaysBounded() async throws {
        guard ProcessInfo.processInfo.environment["RC_WEEK_LONG_ENDURANCE"] == "1" else {
            throw XCTSkip("Set RC_WEEK_LONG_ENDURANCE=1 for the heavier accelerated release gate.")
        }
        try await runVirtualFourteenDays(.release)
    }

    private func runVirtualFourteenDays(_ workload: Workload) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteCode-WeekLongEndurance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appendingPathComponent("endurance.sqlite").path
        var store: Store? = try Store(path: databasePath)

        var threads: [AgentThread] = []
        var runs: [AgentRun] = []
        do {
            let initialStore = try XCTUnwrap(store)
            let threadRepo = AgentThreadRepository(db: initialStore.database)
            for index in 0..<workload.threads {
                var thread = AgentThread(title: "endurance-\(index)", provider: .codex, model: "test")
                thread.status = .running
                let run = AgentRun(threadId: thread.id, provider: .codex, model: "test", status: .running)
                try threadRepo.upsert(thread)
                try initialStore.runs.upsert(run)
                threads.append(thread)
                runs.append(run)
            }
        }

        let surfaceIDs = (0..<workload.surfaces).map { "endurance-terminal-\($0)" }
        for surfaceID in surfaceIDs {
            _ = try XCTUnwrap(store).terminals.prepareHistory(surfaceID: surfaceID)
        }

        try exerciseSimulatedPersistenceFailures(
            databasePath: databasePath,
            store: try XCTUnwrap(store),
            run: try XCTUnwrap(runs.first)
        )
        try exerciseBoundedUIIngress()

        let eightGiB = UInt64(8) * 1_024 * 1_024 * 1_024
        let profile = ManagedProcessMemoryProfile.resolve(physicalMemoryBytes: eightGiB)
        XCTAssertEqual(profile.name, "low-memory-8g")
        XCTAssertNil(profile.providerRootCap)
        XCTAssertEqual(profile.sidecarMaxConcurrentRequests, 1)
        XCTAssertEqual(profile.sidecarMaxQueueDepth, 4)

        let admissionGate = ManagedProviderAdmissionGate(reservationLifetime: 60)
        let emptyProcessScan = ManagedProcessScan(
            providerProcesses: [],
            sidecarProcesses: [],
            providerRootCount: 0,
            sidecarRootCount: 0,
            isComplete: true,
            incompleteRootPIDs: []
        )
        let sidecarSpawner = OwnedTestSidecarSpawner()
        let sidecar = await MainActor.run {
            TokenSaverDistillServiceController(
                appSupportDirectory: directory,
                executableURLResolver: { URL(fileURLWithPath: "/not-executed/in-memory-sidecar") },
                processSpawner: sidecarSpawner,
                terminateForeignServers: { _ in
                    ProviderProcessSweepResult(orphanRootPIDs: [], terminatedPIDs: [], failedPIDs: [])
                },
                memoryProfileProvider: { profile }
            )
        }
        defer {
            Task { @MainActor in sidecar.stop() }
        }

        let eventPolicy = AgentEventRetentionPolicy(
            streamEventCountPerThread: 24,
            streamEventBytesPerThread: 96 * 1_024,
            providerLogCountPerThread: 24,
            providerLogBytesPerThread: 96 * 1_024,
            streamEventBytesGlobal: 256 * 1_024,
            providerLogBytesGlobal: 256 * 1_024,
            pruneQuantumRows: 512,
            pruneQuantumBytes: 2 * 1_024 * 1_024
        )
        let perSurfaceTerminalBytes = 64 * 1_024
        let globalTerminalBytes = 512 * 1_024
        let terminalChunkBytes = 16 * 1_024
        let encodedPayload = try payloadJSON(byteCount: workload.payloadBytes)
        var dailyPhysicalBytes: [Int64] = []
        var maxDailyDuration: TimeInterval = 0
        var nextSequence = Array(repeating: 10, count: runs.count)
        var providerAdmissionChecks = 0

        for day in 0..<14 {
            if day == 7 {
                // Simulate app restart/reopen without changing the isolated path.
                store = nil
                store = try Store(path: databasePath)
            }
            let dayStarted = ProcessInfo.processInfo.systemUptime
            let current = try XCTUnwrap(store)

            for index in runs.indices {
                var intents: [AgentRunRepository.StreamWriteIntent] = []
                intents.reserveCapacity(workload.eventsPerThreadPerDay)
                for eventIndex in 0..<workload.eventsPerThreadPerDay {
                    let sequence = nextSequence[index]
                    nextSequence[index] += 1
                    let providerEvent = eventIndex.isMultiple(of: 2)
                        ? ProviderRuntimeEvent(
                            id: "provider-\(day)-\(index)-\(eventIndex)",
                            provider: .codex,
                            source: "endurance",
                            method: "item/completed",
                            payloadJSON: encodedPayload,
                            receivedAtMs: Int64(day * 100_000 + index * 1_000 + eventIndex)
                        )
                        : nil
                    intents.append(.init(
                        seq: sequence,
                        kind: eventIndex == 0 ? "endurance.oversized" : "endurance.delta",
                        payloadJSON: encodedPayload,
                        providerEvent: providerEvent
                    ))
                }
                try current.runs.persistStreamBatch(
                    runId: runs[index].id,
                    threadId: threads[index].id,
                    items: intents,
                    shouldPruneStreamEvents: false
                )
                try current.runs.pruneStreamEvents(
                    threadId: threads[index].id,
                    keepLatest: eventPolicy.streamEventCountPerThread,
                    maxPayloadBytes: eventPolicy.streamEventBytesPerThread
                )
                try current.runs.pruneProviderEventLogs(
                    threadId: threads[index].id,
                    keepLatest: eventPolicy.providerLogCountPerThread,
                    maxPayloadBytes: eventPolicy.providerLogBytesPerThread
                )
            }
            let globalAgentPrune = try current.runs.pruneGlobalEventPayloads(policy: eventPolicy)
            XCTAssertLessThanOrEqual(globalAgentPrune.streamThreads.count, eventPolicy.pruneQuantumRows)
            XCTAssertLessThanOrEqual(globalAgentPrune.providerRows, eventPolicy.pruneQuantumRows)

            for (surfaceIndex, surfaceID) in surfaceIDs.enumerated() {
                for chunkOffset in 0..<workload.terminalChunksPerSurfacePerDay {
                    let next = try current.terminals.nextChunkIndex(surfaceID: surfaceID)
                    var data = Data(repeating: UInt8((day + surfaceIndex + chunkOffset) % 251), count: terminalChunkBytes)
                    let marker = Data("day=\(day);surface=\(surfaceIndex);chunk=\(chunkOffset)".utf8)
                    data.replaceSubrange(0..<marker.count, with: marker)
                    try current.terminals.append(
                        surfaceID: surfaceID,
                        workspaceID: "endurance-workspace",
                        chunkIndex: next,
                        data: data
                    )
                }
                if try current.terminals.totalBytes(surfaceID: surfaceID) > perSurfaceTerminalBytes {
                    let preparation = try current.terminals.prepareHistory(surfaceID: surfaceID)
                    _ = try current.terminals.pruneByteCapAndMarkHistoryPartial(
                        surfaceID: surfaceID,
                        maxBytes: perSurfaceTerminalBytes,
                        reason: "history_retention_cap",
                        nextChunkIndex: preparation.nextChunkIndex,
                        expectedWriterGeneration: preparation.writerGeneration
                    )
                }
            }
            let terminalPrune = try current.terminals.pruneGlobalByteCapAndMarkHistoryPartial(
                maxBytes: globalTerminalBytes,
                protectedSurfaceID: surfaceIDs[day % surfaceIDs.count],
                maxRows: 256,
                maxDeleteBytes: 2 * 1_024 * 1_024
            )
            XCTAssertLessThanOrEqual(terminalPrune.deletedRows, 256)
            XCTAssertLessThanOrEqual(terminalPrune.deletedBytes, 2 * 1_024 * 1_024)
            XCTAssertFalse(terminalPrune.remainsOverBudget)

            let now = Date(timeIntervalSince1970: TimeInterval(day * 86_400))
            let firstAdmission = await admissionGate.decide(profile: profile, scan: emptyProcessScan, appFootprintKB: 256 * 1_024, key: ManagedProviderAdmissionKey(provider: .codex, threadId: AgentThreadID()), now: now)
            let secondAdmission = await admissionGate.decide(profile: profile, scan: emptyProcessScan, appFootprintKB: 256 * 1_024, key: ManagedProviderAdmissionKey(provider: .codex, threadId: AgentThreadID()), now: now)
            let thirdAdmission = await admissionGate.decide(profile: profile, scan: emptyProcessScan, appFootprintKB: 256 * 1_024, key: ManagedProviderAdmissionKey(provider: .codex, threadId: AgentThreadID()), now: now)
            XCTAssertEqual(firstAdmission, .admit)
            XCTAssertEqual(secondAdmission, .admit)
            XCTAssertEqual(thirdAdmission, .admit,
                           "session count is unlimited; only memory ceilings may block")
            providerAdmissionChecks += 3

            await MainActor.run {
                sidecar.startIfEligible(
                    session: paidSession(),
                    settings: AppSettings(tokenSaverEnabled: true),
                    modelValidation: .installed
                )
            }

            let checkpoint = try current.budget.passiveCheckpoint(now: now)
            XCTAssertEqual(checkpoint.busyReaders, 0)
            XCTAssertLessThanOrEqual(checkpoint.snapshot.walBytes, 17 * 1_024 * 1_024)
            XCTAssertLessThan(checkpoint.snapshot.physicalBytes, workload.physicalCeilingBytes)
            dailyPhysicalBytes.append(checkpoint.snapshot.physicalBytes)

            let dayDuration = ProcessInfo.processInfo.systemUptime - dayStarted
            maxDailyDuration = max(maxDailyDuration, dayDuration)
            XCTAssertLessThan(dayDuration, workload.dailyLatencyCeiling)

        }

        let finalStore = try XCTUnwrap(store)
        XCTAssertEqual(providerAdmissionChecks, 42)
        XCTAssertEqual(sidecarSpawner.spawnCount, 1, "repeated lifecycle checks must retain one sidecar instance")
        await MainActor.run { sidecar.stop() }
        XCTAssertLessThanOrEqual(try finalStore.terminals.totalBytesAllSurfaces(), globalTerminalBytes)
        XCTAssertTrue(try threads.contains { try finalStore.runs.streamHistoryWasPruned(threadId: $0.id) })
        XCTAssertTrue(try surfaceIDs.contains { try finalStore.terminals.partialHistoryState(surfaceID: $0) != nil })

        for thread in threads {
            XCTAssertLessThanOrEqual(
                try finalStore.runs.streamEventPayloadBytes(threadId: thread.id),
                eventPolicy.streamEventBytesPerThread
            )
            XCTAssertLessThanOrEqual(
                try finalStore.runs.providerEventPayloadBytes(threadId: thread.id),
                eventPolicy.providerLogBytesPerThread
            )
        }
        for surfaceID in surfaceIDs {
            XCTAssertLessThanOrEqual(try finalStore.terminals.totalBytes(surfaceID: surfaceID), perSurfaceTerminalBytes)
            let restored = try finalStore.terminals.readWindow(surfaceID: surfaceID, maxBytes: perSurfaceTerminalBytes)
            XCTAssertLessThanOrEqual(restored.chunks.reduce(0) { $0 + $1.data.count }, perSurfaceTerminalBytes)
        }

        let firstWeekHighWater = try XCTUnwrap(dailyPhysicalBytes.prefix(7).max())
        let secondWeekHighWater = try XCTUnwrap(dailyPhysicalBytes.suffix(7).max())
        XCTAssertLessThanOrEqual(
            secondWeekHighWater,
            firstWeekHighWater + 4 * 1_024 * 1_024,
            "the second virtual week must plateau instead of adding one unbounded DB/WAL segment per day"
        )
        XCTAssertLessThan(maxDailyDuration, workload.dailyLatencyCeiling)
    }

    private func payloadJSON(byteCount: Int) throws -> String {
        let event = AssistantEvent.error(
            message: String(repeating: "x", count: max(1, byteCount)),
            recoverable: true
        )
        return String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
    }

    private func exerciseBoundedUIIngress() throws {
        let limits = StreamEventBatch.Limits(
            maxBufferedCount: 32,
            maxBufferedBytes: 128 * 1_024,
            drainCount: 8,
            drainBytes: 32 * 1_024
        )
        let batch = StreamEventBatch(limits: limits)
        let thread = AgentThreadID()
        let run = AgentRunID()
        let oversized = AssistantEvent.error(
            message: String(repeating: "u", count: 192 * 1_024),
            recoverable: true
        )
        XCTAssertEqual(
            batch.appendBounded(event: oversized, run: run, threadId: thread),
            .saturated,
            "an event larger than one UI quantum must be rejected before it enters memory"
        )
        XCTAssertEqual(
            batch.appendBounded(event: oversized, run: run, threadId: thread),
            .saturationAlreadyReported,
            "one oversized-event episode may request at most one controlled stop"
        )
        let oversizedDrain = batch.drainQuantum()
        XCTAssertTrue(
            oversizedDrain.entries.isEmpty,
            "the hard ceiling must not retain the oversized payload while the stop is being reported"
        )
        XCTAssertEqual(oversizedDrain.encodedByteCount, 0)
        XCTAssertFalse(oversizedDrain.hasMore)

        for index in 0..<limits.maxBufferedCount {
            let outcome = batch.appendBounded(
                event: .turnStarted(turnId: "ui-\(index)"),
                run: run,
                threadId: thread
            )
            XCTAssertNotEqual(outcome, .saturated)
        }
        XCTAssertEqual(
            batch.appendBounded(event: .turnStarted(turnId: "ui-overflow"), run: run, threadId: thread),
            .saturated
        )
        XCTAssertEqual(
            batch.appendBounded(event: .turnStarted(turnId: "ui-overflow-repeat"), run: run, threadId: thread),
            .saturationAlreadyReported,
            "a full-queue episode must also request only one controlled stop"
        )
        var drained = 0
        repeat {
            let quantum = batch.drainQuantum()
            XCTAssertLessThanOrEqual(quantum.entries.count, limits.drainCount)
            XCTAssertLessThanOrEqual(quantum.encodedByteCount, limits.drainBytes)
            drained += quantum.entries.count
            if !quantum.hasMore { break }
        } while true
        XCTAssertEqual(drained, limits.maxBufferedCount)
    }

    private func exerciseSimulatedPersistenceFailures(
        databasePath: String,
        store: Store,
        run: AgentRun
    ) throws {
        try store.database.execute("PRAGMA busy_timeout=25;")
        let lockDatabase = try SQLiteDB(path: databasePath)
        try lockDatabase.execute("BEGIN IMMEDIATE;")
        XCTAssertThrowsError(
            try store.runs.appendStreamEvent(
                runId: run.id,
                seq: 1,
                kind: "endurance.simulated_busy",
                payloadJSON: #"{"state":"simulated busy"}"#
            ),
            "the harness deliberately holds a second-connection write lock; this is a simulated SQLITE_BUSY"
        )
        try lockDatabase.execute("ROLLBACK;")
        XCTAssertNoThrow(
            try store.runs.appendStreamEvent(
                runId: run.id,
                seq: 1,
                kind: "endurance.simulated_busy",
                payloadJSON: #"{"state":"simulated busy"}"#
            ),
            "the exact retry must succeed after the simulated lock is released"
        )

        try store.database.execute("""
            CREATE TRIGGER endurance_simulated_disk_full
            BEFORE INSERT ON agent_stream_events
            WHEN NEW.event_kind = 'endurance.simulated_disk_full'
            BEGIN
                SELECT RAISE(ABORT, 'simulated disk full');
            END;
            """)
        XCTAssertThrowsError(
            try store.runs.appendStreamEvent(
                runId: run.id,
                seq: 2,
                kind: "endurance.simulated_disk_full",
                payloadJSON: #"{"state":"simulated disk full"}"#
            ),
            "this trigger simulates a write failure; it is not a physical disk-full test"
        )
        XCTAssertEqual(try store.runs.maxStreamEventSeq(runId: run.id), 1)
        try store.database.execute("DROP TRIGGER endurance_simulated_disk_full;")
        XCTAssertNoThrow(
            try store.runs.appendStreamEvent(
                runId: run.id,
                seq: 2,
                kind: "endurance.simulated_disk_full",
                payloadJSON: #"{"state":"simulated disk full"}"#
            )
        )
    }

    @MainActor
    private func paidSession() -> PrivateAccountSession {
        PrivateAccountSession(
            accessToken: "endurance-access-token",
            refreshToken: "endurance-refresh-token",
            user: PrivateAccountUser(
                daysRemaing: nil,
                daysRemaining: 30,
                email: "endurance@example.com",
                id: "endurance-user",
                subscribed: true
            )
        )
    }
}
