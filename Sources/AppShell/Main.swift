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
        if CommandLine.arguments == [CommandLine.arguments[0], "--database-schema-version"] {
            print(Persistence.Schema.currentVersion)
            return
        }
        let rollbackFlag = "--rollback-host"
        let rollingBack = CommandLine.arguments.contains(rollbackFlag)
        if rollingBack && (CommandLine.arguments.contains("--inspect-database-backup") || CommandLine.arguments.contains("--restore-database-backup")) {
            fputs("Host rollback cannot combine with database inspect or restore.\n", stderr)
            exit(EXIT_FAILURE)
        }
        let appSupportOverride = ProcessInfo.processInfo.environment["RC2_APP_SUPPORT"]
        let dbOverride = ProcessInfo.processInfo.environment["RC2_DB_PATH"]
        let restoreFlag = "--restore-database-backup"
        let restoresDatabase = CommandLine.arguments.contains(restoreFlag)
        let inspectFlag = "--inspect-database-backup"
        let inspectsDatabase = CommandLine.arguments.contains(inspectFlag)

        if !rollingBack && CommandLine.arguments.contains("--scheduled-task-agent-unregister") {
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
        if isScheduledTaskAgent && !rollingBack {
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
            if restoresDatabase || inspectsDatabase || rollingBack { exit(EXIT_FAILURE) }
            if let holderPID, !LocalAuthAdapter.isE2EPairingAutoApproveEnabled {
                NSRunningApplication(processIdentifier: holderPID)?.activate()
            }
            return
        case .unavailable(let code):
            Logger(subsystem: "io.remotecode.app", category: "lifecycle")
                .error("app.instance_lock_unavailable errno=\(code, privacy: .public)")
            instanceLock = nil
        }

        if rollingBack {
            guard let instanceLock, CommandLine.arguments.count >= 3,
                  CommandLine.arguments[1] == rollbackFlag,
                  !CommandLine.arguments.dropFirst(2).contains(rollbackFlag),
                  !CommandLine.arguments.dropFirst(2).contains("--restore-database-backup"),
                  !CommandLine.arguments.dropFirst(2).contains("--inspect-database-backup") else {
                fputs("Host rollback requires an exclusive host lock, one target app path, and no mixed database operation.\n", stderr)
                exit(EXIT_FAILURE)
            }
            let separator: Int?
            if CommandLine.arguments.count == 3 {
                separator = nil
            } else if CommandLine.arguments[3] == "--" {
                separator = 3
            } else {
                fputs("Host rollback accepts only explicit -- before forwarded arguments.\n", stderr)
                exit(EXIT_FAILURE)
            }
            withExtendedLifetime(instanceLock) {
                do {
                    let target = URL(fileURLWithPath: CommandLine.arguments[2])
                    let database = URL(fileURLWithPath: dbOverride ?? appSupportDirectory.appendingPathComponent("remotecode.sqlite").path)
                    let executable = try HostDatabaseRollback.validate(databaseURL: database, targetURL: target, currentBundleURL: Bundle.main.bundleURL, currentBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                    let forwarded = separator.map { Array(CommandLine.arguments[($0 + 1)...]) } ?? []
                    let args = [executable.path] + forwarded
                    let cargs = args.map { strdup($0) } + [nil]
                    cargs.withUnsafeBufferPointer { buffer in _ = execv(executable.path, buffer.baseAddress!) }
                    fputs("Unable to execute rollback target.\n", stderr)
                    exit(EXIT_FAILURE)
                } catch {
                    fputs("Host rollback refused: \(error)\n", stderr)
                    exit(EXIT_FAILURE)
                }
            }
            exit(EXIT_FAILURE)
        }

        if restoresDatabase || inspectsDatabase {
            let operationFlag = restoresDatabase ? restoreFlag : inspectFlag
            guard let instanceLock, !(restoresDatabase && inspectsDatabase),
                  CommandLine.arguments.filter({ $0 == operationFlag }).count == 1,
                  let index = CommandLine.arguments.firstIndex(of: operationFlag),
                  CommandLine.arguments.indices.contains(index + 1) else {
                fputs("Database restore requires an exclusive host lock and one backup path.\n", stderr)
                exit(EXIT_FAILURE)
            }
            withExtendedLifetime(instanceLock) {
                do {
                    let current = URL(fileURLWithPath: dbOverride ?? appSupportDirectory.appendingPathComponent("remotecode.sqlite").path)
                    let backup = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                    if inspectsDatabase {
                        let review = try HostDatabaseRestore.inspect(backupURL: backup)
                        let output: [String: Any] = [
                            "schema_version": review.schemaVersion, "review_fingerprint": review.fingerprint,
                            "agent_queue_ids": review.agentQueueIDs, "bot_queue_ids": review.botQueueIDs,
                            "routine_ids": review.routineIDs, "scheduled_task_ids": review.scheduledTaskIDs,
                            "requires_confirmation": review.requiresConfirmation,
                            "adoption_policy": "Queues require an explicit force-send action. Schedules remain disabled until explicitly enabled."
                        ]
                        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
                        print(String(decoding: data, as: UTF8.self))
                        return
                    }
                    var token: String?
                    if let reviewIndex = CommandLine.arguments.firstIndex(of: "--restore-review") {
                        guard CommandLine.arguments.filter({ $0 == "--restore-review" }).count == 1,
                              CommandLine.arguments.indices.contains(reviewIndex + 1) else {
                            throw SQLiteError.open("restore review requires one fingerprint")
                        }
                        token = CommandLine.arguments[reviewIndex + 1]
                    }
                    let recovery = try HostDatabaseRestore.restore(backupURL: backup, currentURL: current, reviewToken: token)
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
