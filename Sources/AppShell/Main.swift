import Foundation
import AppKit
import AppLifecycleSupport
import os
import Persistence

@main
@MainActor
struct RemoteCodeMain {
    static func main() {
        // Priority: explicit env override -> bundle-id derivation -> .debug
        let channel: ReleaseChannel
        if let envRaw = ProcessInfo.processInfo.environment["RC2_CHANNEL"],
           let envChannel = ReleaseChannel(rawValue: envRaw) {
            channel = envChannel
        } else {
            let bundleID = Bundle.main.bundleIdentifier ?? ""
            channel = ReleaseChannel.channelFromBundleID(bundleID)
        }
        let appSupportOverride = ProcessInfo.processInfo.environment["RC2_APP_SUPPORT"]
        let dbOverride = ProcessInfo.processInfo.environment["RC2_DB_PATH"]
        let restoreFlag = "--restore-database-backup"
        let restoresDatabase = CommandLine.arguments.contains(restoreFlag)

        if CommandLine.arguments.contains("--scheduled-task-agent-unregister") {
            do {
                try ScheduledTaskAgentServiceManager().unregister()
                print("Scheduled Tasks background agent unregistered.")
            } catch {
                fputs("Unable to unregister Scheduled Tasks background agent: \(error)\n", stderr)
            }
            return
        }

        let app = NSApplication.shared
        RemoteCodeAppearance.apply(to: app)
        let isScheduledTaskAgent = CommandLine.arguments.contains("--scheduled-task-agent")
            || ProcessInfo.processInfo.environment["RC2_SCHEDULED_TASK_AGENT"] == "1"
        if isScheduledTaskAgent {
            // Schedules run in-process in the interactive app. A leftover LaunchAgent
            // install must not dual-claim: unregister and exit immediately.
            do {
                try ScheduledTaskAgentServiceManager().unregister()
                print("Scheduled Tasks now run inside RemoteCode; background agent unregistered.")
            } catch {
                fputs("Unable to unregister legacy Scheduled Tasks agent: \(error)\n", stderr)
            }
            return
        }

        // S-F8: one process per App Support directory. A second instance would
        // share the database, port and run marker; hand focus to the first and
        // exit before touching any of them. The isolated sandbox has its own
        // App Support, so it never contends with the user's app.
        let instanceLock: AppInstanceLock?
        let appSupportDirectory = AppPaths.appSupportDirectory(for: channel, override: appSupportOverride)
        switch AppInstanceLock.acquire(directory: appSupportDirectory) {
        case .acquired(let lock):
            instanceLock = lock
        case .heldByOther(let holderPID):
            let holder = holderPID.map(String.init) ?? "unknown"
            Logger(subsystem: "io.remotecode.app", category: "lifecycle")
                .fault("app.second_instance_exit holder=\(holder, privacy: .public)")
            fputs("RemoteCode is already running for \(appSupportDirectory.path) (pid \(holder)); exiting.\n", stderr)
            if restoresDatabase { exit(EXIT_FAILURE) }
            if let holderPID, !LocalAuthAdapter.isE2EPairingAutoApproveEnabled {
                NSRunningApplication(processIdentifier: holderPID)?.activate()
            }
            return
        case .unavailable(let code):
            Logger(subsystem: "io.remotecode.app", category: "lifecycle")
                .error("app.instance_lock_unavailable errno=\(code, privacy: .public)")
            instanceLock = nil
        }

        if restoresDatabase {
            guard let instanceLock,
                  CommandLine.arguments.filter({ $0 == restoreFlag }).count == 1,
                  let index = CommandLine.arguments.firstIndex(of: restoreFlag),
                  CommandLine.arguments.indices.contains(index + 1) else {
                fputs("Database restore requires an exclusive host lock and one backup path.\n", stderr)
                exit(EXIT_FAILURE)
            }
            withExtendedLifetime(instanceLock) {
                do {
                    let current = URL(fileURLWithPath: dbOverride ?? appSupportDirectory.appendingPathComponent("remotecode.sqlite").path)
                    let backup = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                    let recovery = try HostDatabaseRestore.restore(backupURL: backup, currentURL: current)
                    print("Database restored without starting execution. Recovery backup: \(recovery.path)")
                } catch {
                    fputs("Database restore failed: \(error)\n", stderr)
                    exit(EXIT_FAILURE)
                }
            }
            return
        }

        if LocalAuthAdapter.isE2EPairingAutoApproveEnabled {
            // Isolated iOS E2E: stay accessory and never steal the user's frontmost app.
            app.setActivationPolicy(.accessory)
        } else {
            app.setActivationPolicy(.regular)
        }
        let delegate = AppDelegate(channel: channel, appSupportOverride: appSupportOverride, dbOverride: dbOverride)
        app.delegate = delegate
        if !LocalAuthAdapter.isE2EPairingAutoApproveEnabled {
            app.activate(ignoringOtherApps: true)
        }
        withExtendedLifetime((delegate, instanceLock)) {
            app.run()
        }
    }
}
