import Foundation
import Darwin
import AgentRuntime
import CoreModel
import Surfaces
import os

private let appDiagnosticsLog = Logger(subsystem: "io.remotecode.app", category: "diagnostics")

enum AppDiagnostics {
    @MainActor
    static func heartbeat(reason: String, activeAgentThreads: Int) {
        let surfaces = SurfaceRegistry.shared.all()
        let terminalHealth = surfaces.compactMap { ($0 as? TerminalSurface)?.runtimeHealth() }
        let runningTerminals = terminalHealth.filter(\.processAlive).count
        let pendingBytes = terminalHealth.reduce(0) { $0 + $1.outputPendingBytes }
        let droppedBytes = terminalHealth.reduce(0) { $0 + $1.droppedOutputBytes }
        let historyFailures = terminalHealth.reduce(0) { $0 + $1.historyWriteFailures }
        let providerProcesses = ProviderProcessSweeper.currentProviderProcesses()
        let providerRSSKB = providerProcesses.reduce(0) { $0 + $1.rssKB }
        let orphanProviders = providerProcesses.filter { $0.ppid == 1 }.count
        let rssKB = currentProcessFootprintKB()

        appDiagnosticsLog.info(
            "app.heartbeat reason=\(reason, privacy: .public) pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public) rssKB=\(rssKB, privacy: .public) surfaces=\(surfaces.count, privacy: .public) terminals=\(terminalHealth.count, privacy: .public) runningTerminals=\(runningTerminals, privacy: .public) activeAgentThreads=\(activeAgentThreads, privacy: .public) providerProcesses=\(providerProcesses.count, privacy: .public) providerRSSKB=\(providerRSSKB, privacy: .public) orphanProviders=\(orphanProviders, privacy: .public) terminalPendingBytes=\(pendingBytes, privacy: .public) terminalDroppedBytes=\(droppedBytes, privacy: .public) terminalHistoryFailures=\(historyFailures, privacy: .public)"
        )
    }

    private static func currentProcessFootprintKB() -> Int {
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
