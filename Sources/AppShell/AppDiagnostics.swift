import Foundation
import Darwin
import AgentRuntime
import AppLifecycleSupport
import CoreModel
import Surfaces
import os

private let appDiagnosticsLog = Logger(subsystem: "io.remotecode.app", category: "diagnostics")

enum AppDiagnostics {
    /// Snapshot of surface-level counters captured on the main actor before
    /// dispatching the blocking process scan to a background task.
    struct SurfaceSnapshot: Sendable {
        let surfaceCount: Int
        let terminalCount: Int
        let runningTerminals: Int
        let pendingBytes: Int
        let droppedBytes: Int
        let historyFailures: Int
    }

    /// Aggregated process stats derived from a list of provider or sidecar processes.
    /// Pure, `nonisolated`-safe: no actor context required.
    ///
    /// WHY: the caller (`heartbeat`) dispatches `currentProviderProcesses()`
    /// to a background queue; the aggregation must therefore be testable in
    /// isolation without any actor or AppKit state.
    struct ProviderStats: Sendable {
        let processCount: Int
        let totalRSSKB: Int
        let orphanCount: Int
    }

    /// Aggregates process stats from a list of processes.
    /// This is the pure helper that runs off the main thread in `heartbeat`.
    nonisolated static func aggregateProviderStats(
        processes: [ProviderRuntimeProcess]
    ) -> ProviderStats {
        ProviderStats(
            processCount: processes.count,
            totalRSSKB: processes.reduce(0) { $0 + $1.rssKB },
            orphanCount: processes.filter { $0.ppid == 1 }.count
        )
    }

    /// Heartbeat entry point — must remain `@MainActor` because it reads
    /// `SurfaceRegistry` (itself `@MainActor`).
    ///
    /// The blocking work (`/bin/ps` via `currentProviderProcesses`) is
    /// dispatched to a background `Task` with `.utility` priority so it
    /// never competes with UI rendering on the main thread. The log entry
    /// is written back on the main actor once the scan completes.
    /// F9: guards against stacking a second `/bin/ps` provider sweep on top of one
    /// still running. Main-actor isolated, so no lock is needed; the detached scan
    /// clears it back on the main actor when it finishes.
    @MainActor private static var providerScanInFlight = false

    @MainActor
    static func heartbeat(
        reason: String,
        activeAgentThreads: Int,
        lifecycleRecorder: AppLifecycleRecorder? = nil
    ) {
        // Snapshot main-actor surface state before leaving the actor.
        let surfaces = SurfaceRegistry.shared.all()
        let terminalHealth = surfaces.compactMap { ($0 as? TerminalSurface)?.runtimeHealth() }
        let snapshot = SurfaceSnapshot(
            surfaceCount: surfaces.count,
            terminalCount: terminalHealth.count,
            runningTerminals: terminalHealth.filter(\.processAlive).count,
            pendingBytes: terminalHealth.reduce(0) { $0 + $1.outputPendingBytes },
            droppedBytes: terminalHealth.reduce(0) { $0 + $1.droppedOutputBytes },
            historyFailures: terminalHealth.reduce(0) { $0 + $1.historyWriteFailures }
        )
        // Cheap mach call; no I/O — sample here while still on the main actor.
        let rssKB = currentProcessFootprintKB()
        let pid = ProcessInfo.processInfo.processIdentifier

        // F9: if a prior /bin/ps sweep is still running, don't launch another — at the
        // 60s cadence this is rare, but two concurrent sweeps would compete for CPU
        // with the UI at the worst moment. Skip the scan this tick (telemetry may miss
        // one sample) while still recording the cheap surface snapshot.
        if providerScanInFlight {
            appDiagnosticsLog.info("app.heartbeat reason=\(reason, privacy: .public) pid=\(pid, privacy: .public) rssKB=\(rssKB, privacy: .public) surfaces=\(snapshot.surfaceCount, privacy: .public) terminals=\(snapshot.terminalCount, privacy: .public) runningTerminals=\(snapshot.runningTerminals, privacy: .public) activeAgentThreads=\(activeAgentThreads, privacy: .public) providerScan=skipped_in_flight terminalPendingBytes=\(snapshot.pendingBytes, privacy: .public) terminalDroppedBytes=\(snapshot.droppedBytes, privacy: .public) terminalHistoryFailures=\(snapshot.historyFailures, privacy: .public)")
            return
        }
        providerScanInFlight = true

        // Dispatch the blocking /bin/ps scan off the main thread.
        Task.detached(priority: .utility) {
            let providerProcesses = ProviderProcessSweeper.currentProviderProcesses()
            let sidecarProcesses = ProviderProcessSweeper.currentSidecarProcesses()
            let stats = aggregateProviderStats(processes: providerProcesses)
            let sidecarStats = aggregateProviderStats(processes: sidecarProcesses)
            await MainActor.run {
                providerScanInFlight = false   // F9: sweep done — allow the next tick
                appDiagnosticsLog.info(
                    "app.heartbeat reason=\(reason, privacy: .public) pid=\(pid, privacy: .public) rssKB=\(rssKB, privacy: .public) surfaces=\(snapshot.surfaceCount, privacy: .public) terminals=\(snapshot.terminalCount, privacy: .public) runningTerminals=\(snapshot.runningTerminals, privacy: .public) activeAgentThreads=\(activeAgentThreads, privacy: .public) providerProcesses=\(stats.processCount, privacy: .public) providerRSSKB=\(stats.totalRSSKB, privacy: .public) orphanProviders=\(stats.orphanCount, privacy: .public) sidecarProcesses=\(sidecarStats.processCount, privacy: .public) sidecarRSSKB=\(sidecarStats.totalRSSKB, privacy: .public) orphanSidecars=\(sidecarStats.orphanCount, privacy: .public) terminalPendingBytes=\(snapshot.pendingBytes, privacy: .public) terminalDroppedBytes=\(snapshot.droppedBytes, privacy: .public) terminalHistoryFailures=\(snapshot.historyFailures, privacy: .public)"
                )
                lifecycleRecorder?.recordHeartbeat(
                    reason: reason,
                    providerProcesses: stats.processCount,
                    providerRSSKB: stats.totalRSSKB,
                    orphanProviders: stats.orphanCount,
                    sidecarProcesses: sidecarStats.processCount,
                    sidecarRSSKB: sidecarStats.totalRSSKB,
                    orphanSidecars: sidecarStats.orphanCount
                )
            }
        }
    }

    // internal (not private) so Tests/@testable can verify the mach call succeeds.
    static func currentProcessFootprintKB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / 1024)
    }
}
