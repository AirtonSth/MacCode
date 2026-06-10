import XCTest
@testable import AppShell
@testable import AgentRuntime

/// Tests for the off-main-thread diagnostics heartbeat refactor.
///
/// Business rules:
///   R1 — `aggregateProviderStats` is `nonisolated`: it must be callable
///        without any actor context so the background `Task.detached` in
///        `heartbeat` can use it without hopping back to the main thread.
///   R2 — Provider RSS and orphan count are summed correctly so the heartbeat
///        log accurately reflects process-table state; incorrect totals would
///        mask memory growth or leaked orphan runtimes.
///   R3 — `currentProcessFootprintKB` must return a positive value (>= 0) in
///        a healthy process; -1 indicates a mach-kernel failure and would log
///        useless footprint data, hiding out-of-memory kill evidence.
///   R4 — `aggregateProviderStats` with an empty process list returns all-zero
///        fields; the heartbeat must log "0 providers" rather than crashing or
///        returning stale counts when no provider runtimes are running.
final class DiagnosticsHeartbeatOffMainTests: XCTestCase {

    // MARK: - R1: pure helper is callable without actor context

    func test_aggregateProviderStats_isCallableOffMainActor() {
        // R1: `aggregateProviderStats` must not require the main actor so that
        // `heartbeat` can dispatch the /bin/ps scan + aggregation to a background
        // Task.detached without blocking the main run loop.
        //
        // Compile-level proof: this test function carries no @MainActor annotation
        // and no explicit actor hop; if `aggregateProviderStats` were @MainActor
        // (or nonisolated were removed) the compiler would reject this call site.
        let processes = [
            ProviderRuntimeProcess(pid: 100, ppid: 1,   rssKB: 512, command: "/usr/bin/node"),
            ProviderRuntimeProcess(pid: 200, ppid: 100, rssKB: 256, command: "/usr/bin/node worker"),
        ]
        // Call without any actor annotation — compile error if not nonisolated.
        let stats = AppDiagnostics.aggregateProviderStats(processes: processes)
        XCTAssertEqual(stats.processCount, 2,
            "processCount must reflect the number of processes passed in")
    }

    // MARK: - R2: aggregation correctness

    func test_aggregateProviderStats_sumsRSSAndCountsOrphans() {
        // R2: rssKB must be the sum of all process RSS values; orphanCount must
        // equal the number of processes whose ppid == 1.  Incorrect totals would
        // cause the heartbeat log to underreport memory or hide leaked runtimes.
        let processes = [
            ProviderRuntimeProcess(pid: 10, ppid: 1,  rssKB: 1024, command: "/claude"),
            ProviderRuntimeProcess(pid: 11, ppid: 10, rssKB: 512,  command: "/claude worker"),
            ProviderRuntimeProcess(pid: 12, ppid: 1,  rssKB: 2048, command: "/codex app-server"),
        ]
        let stats = AppDiagnostics.aggregateProviderStats(processes: processes)

        XCTAssertEqual(stats.processCount, 3,
            "processCount must equal the number of processes in the list")
        XCTAssertEqual(stats.totalRSSKB, 3584,
            "totalRSSKB must be the sum of all rssKB values (1024+512+2048=3584) so memory totals in the heartbeat log are correct")
        XCTAssertEqual(stats.orphanCount, 2,
            "orphanCount must equal the number of processes with ppid==1 (pids 10 and 12) so leaked orphan runtimes are counted accurately")
    }

    // MARK: - R4: empty list boundary

    func test_aggregateProviderStats_emptyList_returnsZeros() {
        // R4: when no provider processes are running the heartbeat must log
        // "0 providers / 0 KB / 0 orphans" rather than crashing or returning
        // stale state from a previous call.
        let stats = AppDiagnostics.aggregateProviderStats(processes: [])

        XCTAssertEqual(stats.processCount, 0,
            "processCount must be 0 when the process list is empty")
        XCTAssertEqual(stats.totalRSSKB, 0,
            "totalRSSKB must be 0 when there are no provider processes")
        XCTAssertEqual(stats.orphanCount, 0,
            "orphanCount must be 0 when there are no orphan processes")
    }

    // MARK: - R3: footprint sampling

    func test_currentProcessFootprintKB_returnsNonNegativeValue() {
        // R3: the mach task_info call must succeed in a normal test process and
        // return a footprint >= 0.  A return of -1 means KERN_FAILURE, which
        // would write "rssKB=-1" to every heartbeat log line and make
        // out-of-memory kill evidence invisible.
        let footprint = AppDiagnostics.currentProcessFootprintKB()
        XCTAssertGreaterThanOrEqual(footprint, 0,
            "currentProcessFootprintKB must return >= 0; -1 indicates a mach-kernel failure that would corrupt all heartbeat footprint log entries")
    }
}
