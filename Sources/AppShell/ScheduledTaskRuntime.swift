import Foundation
import AppKit
import CoreModel
import Persistence
import AgentRuntime
import Surfaces
import ServiceManagement
import Darwin
import os

private let scheduledTaskLog = Logger(subsystem: "io.remotecode.appshell", category: "scheduled-tasks")

public struct ScheduledSystemUser: Sendable, Equatable, Identifiable {
    public let name: String
    public let uid: uid_t
    public let homeDirectory: String
    public var id: String { name }
}

public enum ScheduledSystemUserCatalog {
    public static func eligibleUsers() -> [ScheduledSystemUser] {
        var users: [ScheduledSystemUser] = []
        setpwent()
        defer { endpwent() }
        while let entry = getpwent()?.pointee {
            let uid = entry.pw_uid
            guard uid >= 500, uid < UInt32.max - 1,
                  let namePointer = entry.pw_name,
                  let homePointer = entry.pw_dir,
                  let shellPointer = entry.pw_shell else { continue }
            let name = String(cString: namePointer)
            let home = String(cString: homePointer)
            let shell = String(cString: shellPointer)
            guard !name.hasPrefix("_"), shell != "/usr/bin/false", shell != "/bin/false", shell != "/usr/bin/nologin" else { continue }
            users.append(ScheduledSystemUser(name: name, uid: uid, homeDirectory: home))
        }
        return users.sorted { lhs, rhs in
            if lhs.name == NSUserName() { return true }
            if rhs.name == NSUserName() { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public static func user(named name: String) -> ScheduledSystemUser? {
        guard let pointer = getpwnam(name) else { return nil }
        let entry = pointer.pointee
        guard entry.pw_uid >= 500, entry.pw_uid < UInt32.max - 1,
              let namePointer = entry.pw_name, let homePointer = entry.pw_dir,
              let shellPointer = entry.pw_shell else { return nil }
        let shell = String(cString: shellPointer)
        guard shell != "/usr/bin/false", shell != "/bin/false", shell != "/usr/bin/nologin" else { return nil }
        return ScheduledSystemUser(
            name: String(cString: namePointer),
            uid: entry.pw_uid,
            homeDirectory: String(cString: homePointer)
        )
    }
}

public enum ScheduledTaskPreflightError: Error, CustomStringConvertible, LocalizedError, Equatable {
    case invalidTask(String)
    case missingWorkspace
    case inaccessibleWorkspace(String)
    case ineligibleUser(String)
    case sudoUnavailable(String)
    case providerUnavailable(String)
    case unsupportedModel(String)
    case unsupportedReasoning(String)

    public var description: String {
        switch self {
        case .invalidTask(let value): return value
        case .missingWorkspace: return "The selected workspace no longer exists."
        case .inaccessibleWorkspace(let path): return "The workspace is not readable and writable: \(path)"
        case .ineligibleUser(let user): return "The system user is not eligible: \(user)"
        case .sudoUnavailable(let user): return "Passwordless sudo is not available for user \(user). Configure sudoers, then retry."
        case .providerUnavailable(let reason): return reason
        case .unsupportedModel(let model): return "The selected provider does not expose model \(model)."
        case .unsupportedReasoning(let effort): return "The selected model does not support \(effort) reasoning."
        }
    }

    /// WHY: Run Now / XPC failure paths use `error.localizedDescription`. Without
    /// LocalizedError, Foundation bridges to NSError and drops the human message
    /// ("AppShell.ScheduledTaskPreflightError error 0.").
    public var errorDescription: String? { description }
}

@MainActor
public final class ScheduledTaskExecutor {
    private let context: AppContext
    private let router: AppCommandRouter
    private let orchestrationRuntime: AgentOrchestrationRuntime

    public init(
        context: AppContext,
        router: AppCommandRouter,
        orchestrationRuntime: AgentOrchestrationRuntime = AgentOrchestrationRuntime()
    ) {
        self.context = context
        self.router = router
        self.orchestrationRuntime = orchestrationRuntime
    }

    public func preflight(_ task: ScheduledTask) async throws -> Workspace {
        try await prepareExecution(task).workspace
    }

    /// Paste+play through a real Agent App tab — same path as the user opening
    /// Agent App, setting user/provider/model, typing the prompt, and pressing play.
    ///
    /// Ownership stays in the interactive app process (local coordinator). No
    /// LaunchAgent foreign ownership or XPC stop path.
    /// - Parameter onThreadCreated: called after the thread row exists so the
    ///   scheduler can link `scheduled_task_runs.thread_id` before provider start.
    public func execute(
        _ task: ScheduledTask,
        onThreadCreated: ((AgentThreadID) throws -> Void)? = nil
    ) async throws -> (threadID: AgentThreadID, runID: AgentRunID) {
        _ = try await prepareExecution(task)
        try Self.rejectUIOnlySchedulePrompt(task.prompt)

        let surface = try router.openAgentAppForSchedule(workspace: task.workspaceID)
        let vm = surface.viewModel
        vm.setRunAsUser(Self.resolveRunAsUser(task: task) ?? AgentRunAsUser.current())
        // setRunAsUser kicks an async provider refresh; await a full load so the
        // exact saved instance is present before we pin configuration.
        await vm.loadProviderSnapshots()
        guard vm.providerSnapshots.contains(where: {
            $0.id == task.providerInstanceID && $0.provider == task.provider
        }) else {
            throw ScheduledTaskPreflightError.providerUnavailable(
                "Provider instance \(task.providerInstanceID) is not available for \(task.runAsUser)."
            )
        }
        vm.setProviderInstance(task.providerInstanceID)
        // New-thread creation re-applies preferred model; pin exact schedule
        // configuration after create, then fail closed if anything drifted.
        vm.createThread(title: "New thread")
        guard let threadID = vm.selectedThreadId else {
            throw ScheduledTaskPreflightError.invalidTask(
                vm.statusMessage.isEmpty
                    ? "Scheduled task could not create an Agent App thread."
                    : vm.statusMessage
            )
        }
        try onThreadCreated?(threadID)

        vm.setProviderInstance(task.providerInstanceID)
        vm.setModel(task.model)
        vm.setReasoningEffort(task.reasoningEffort)
        vm.setPermissionMode(.fullAccess)
        vm.interactionMode = .default
        _ = vm.setAutoModelRoutingEnabled(task.effectiveRoutingMode == .auto)

        if vm.providerInstanceId != task.providerInstanceID
            || vm.provider != task.provider {
            throw ScheduledTaskPreflightError.providerUnavailable(
                "Could not pin provider \(task.provider.rawValue) / \(task.providerInstanceID) on the Agent App tab."
            )
        }
        if task.effectiveRoutingMode != .auto, vm.model != task.model {
            throw ScheduledTaskPreflightError.unsupportedModel(task.model)
        }
        if vm.permissionMode != .fullAccess {
            throw ScheduledTaskPreflightError.invalidTask(
                "Could not enable Full Access for the scheduled Agent App run."
            )
        }
        if task.effectiveRoutingMode == .auto, vm.routingMode != .auto {
            throw ScheduledTaskPreflightError.invalidTask(
                "Could not enable Auto model routing for the scheduled run."
            )
        }

        // Raw saved prompt — AgentAppViewModel.send() performs the same
        // first-token normalization the play button uses.
        vm.prompt = task.prompt
        vm.attachments = []
        await vm.send()

        guard let runID = vm.currentRunId, vm.selectedThreadId == threadID else {
            let detail = vm.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ScheduledTaskPreflightError.invalidTask(
                detail.isEmpty
                    ? "Scheduled task send did not start a provider run."
                    : detail
            )
        }
        return (threadID, runID)
    }

    /// Local Agent App commands that never start a provider turn. Scheduled
    /// prompts must not silently no-op or create empty threads for these.
    ///
    /// nonisolated: pure string classification; catalog mirrors
    /// `AgentAppViewModel.localSlashCommands` without MainActor hop.
    nonisolated static func rejectUIOnlySchedulePrompt(_ text: String) throws {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = line.first, first == "/" || first == "$" else { return }
        let parts = line.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
        let command = (parts.first ?? "").lowercased()
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        let local = Set(["clear", "default", "fork", "model", "plan", "status"])
        guard local.contains(command) else { return }
        // `/plan body` in Agent App switches mode then sends `body` — schedules
        // are Default interaction only, so require a real provider prompt.
        if command == "plan", !argument.isEmpty {
            throw ScheduledTaskPreflightError.invalidTask(
                "Scheduled tasks run in Default interaction mode. Remove /plan and put the work in the prompt (or use a skill like $sam-work)."
            )
        }
        if argument.isEmpty {
            throw ScheduledTaskPreflightError.invalidTask(
                "Scheduled tasks cannot run the local Agent App command /\(command). Use a full prompt or skill ($name)."
            )
        }
    }

    private static func resolveRunAsUser(task: ScheduledTask) -> AgentRunAsUser? {
        guard let user = ScheduledSystemUserCatalog.user(named: task.runAsUser) else {
            return AgentRunAsUser.current()
        }
        return AgentRunAsUser(
            generatedUID: "",
            shortName: user.name,
            uid: user.uid,
            gid: getgid(),
            homePath: user.homeDirectory
        )
    }

    private struct PreparedExecution {
        let workspace: Workspace
        let manualLaunch: AgentOrchestrationLaunchConfiguration?
        let routingSnapshot: AgentOrchestrationRoutingSnapshot?
    }

    private func prepareExecution(_ task: ScheduledTask) async throws -> PreparedExecution {
        let validation = task.validationErrors()
        guard validation.isEmpty else { throw ScheduledTaskPreflightError.invalidTask(validation.joined(separator: " ")) }
        guard let workspace = try router.listWorkspaces().first(where: { $0.id == task.workspaceID }) else {
            throw ScheduledTaskPreflightError.missingWorkspace
        }
        guard URL(fileURLWithPath: workspace.cwd).standardizedFileURL.path
                == URL(fileURLWithPath: task.workspacePathSnapshot).standardizedFileURL.path else {
            throw ScheduledTaskPreflightError.inaccessibleWorkspace("The selected workspace path changed after this task was saved.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspace.cwd, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: workspace.cwd),
              FileManager.default.isWritableFile(atPath: workspace.cwd) else {
            throw ScheduledTaskPreflightError.inaccessibleWorkspace(workspace.cwd)
        }
        guard let user = ScheduledSystemUserCatalog.user(named: task.runAsUser) else {
            throw ScheduledTaskPreflightError.ineligibleUser(task.runAsUser)
        }
        guard user.uid == task.runAsUID else {
            throw ScheduledTaskPreflightError.ineligibleUser("\(task.runAsUser) changed identity since this task was saved")
        }
        if user.name != NSUserName() { try verifyPasswordlessSudo(user: user) }

        let snapshots = await router.listAgentProviderSnapshots()
        if task.effectiveRoutingMode == .auto {
            return PreparedExecution(
                workspace: workspace,
                manualLaunch: nil,
                routingSnapshot: try await autoRoutingSnapshot(
                    task: task,
                    user: user,
                    snapshots: snapshots
                )
            )
        }

        let snapshot = snapshots.first { $0.id == task.providerInstanceID && $0.provider == task.provider }
        do {
            try AgentProviderRunPreflight.validate(
                snapshot: snapshot,
                interactionMode: .default,
                permissionMode: .fullAccess,
                attachments: []
            )
        } catch {
            throw ScheduledTaskPreflightError.providerUnavailable(String(describing: error))
        }
        guard let snapshot else { throw ScheduledTaskPreflightError.providerUnavailable("Provider capabilities are not loaded yet.") }
        let descriptor = snapshot.models.first { $0.id == task.model }
        guard descriptor != nil || snapshot.models.isEmpty || snapshot.models.contains(where: \.supportsCustomModel) else {
            throw ScheduledTaskPreflightError.unsupportedModel(task.model)
        }
        if let descriptor, descriptor.supportsReasoning,
           !descriptor.supportedReasoningEfforts.isEmpty,
           !descriptor.supportedReasoningEfforts.contains(task.reasoningEffort) {
            throw ScheduledTaskPreflightError.unsupportedReasoning(task.reasoningEffort.displayName)
        }
        let binary = snapshot.binaryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseBinary = binary?.isEmpty == false ? binary! : task.provider.rawValue
        if user.name != NSUserName() {
            try verifyProviderBinary(baseBinary, user: user)
        }
        let probeBinary = try executionBinary(task: task, baseBinary: baseBinary)
        let probeEnvironment = user.name == NSUserName()
            ? router.providerEnvironment(provider: task.provider, instanceId: task.providerInstanceID)
            : [:]
        let authenticated = await Task.detached {
            ProviderCLIProbe.authenticated(
                provider: task.provider,
                binaryPath: probeBinary,
                environment: probeEnvironment
            )
        }.value
        guard authenticated == true else {
            throw ScheduledTaskPreflightError.providerUnavailable(
                "The selected provider is unavailable for system user \(user.name). Sign in as that user and retry."
            )
        }
        return PreparedExecution(
            workspace: workspace,
            manualLaunch: AgentOrchestrationLaunchConfiguration(
                binary: probeBinary,
                environment: probeEnvironment
            ),
            routingSnapshot: nil
        )
    }

    nonisolated static func routingConfiguration(
        for task: ScheduledTask,
        policyDigest: String,
        eligibleProviders: [AgentProvider] = AgentProvider.allCases
    ) -> AgentRoutingConfiguration {
        AgentRoutingConfiguration(
            mode: task.effectiveRoutingMode,
            manualSelection: AgentModelSelection(
                provider: task.provider,
                modelId: task.model,
                reasoningEffort: task.reasoningEffort
            ),
            manualProviderInstanceId: task.providerInstanceID,
            eligibleProviders: eligibleProviders,
            policyDigest: task.effectiveRoutingMode == .auto ? policyDigest : "",
            revision: task.effectiveRoutingMode == .auto ? 1 : 0
        )
    }

    private func autoRoutingSnapshot(
        task: ScheduledTask,
        user: ScheduledSystemUser,
        snapshots: [AgentProviderSnapshot]
    ) async throws -> AgentOrchestrationRoutingSnapshot {
        var verifiedSnapshots: [AgentProviderSnapshot] = []
        var launches: [String: AgentOrchestrationLaunchConfiguration] = [:]

        // Scheduled Auto is host-bound: only the user-chosen provider may run.
        // Never admit other providers or substitute another host when the saved
        // provider is unavailable (SCHED-005).
        let candidateSnapshots = snapshots.filter {
            $0.provider == task.provider
                && $0.id == task.providerInstanceID
                && $0.enabled
                && $0.installed
                && $0.modelDiscoverySource == .live
                && $0.capabilities?.supportsStreaming == true
                && !$0.models.isEmpty
        }
        guard !candidateSnapshots.isEmpty else {
            throw ScheduledTaskPreflightError.providerUnavailable(
                "The selected provider (\(task.provider.rawValue.capitalized)) is unavailable for Auto model routing."
            )
        }

        for snapshot in candidateSnapshots {
            let binary = snapshot.binaryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseBinary = binary?.isEmpty == false ? binary! : snapshot.provider.rawValue
            if user.name != NSUserName() {
                do { try verifyProviderBinary(baseBinary, user: user) }
                catch {
                    throw ScheduledTaskPreflightError.providerUnavailable(
                        "The selected provider is not executable as \(user.name): \(error)"
                    )
                }
            }
            let launchBinary: String
            do {
                launchBinary = try executionBinary(
                    task: task,
                    baseBinary: baseBinary,
                    providerInstanceID: snapshot.id
                )
            } catch {
                throw ScheduledTaskPreflightError.providerUnavailable(
                    "Could not resolve the selected provider binary: \(error)"
                )
            }
            let environment = user.name == NSUserName()
                ? router.providerEnvironment(provider: snapshot.provider, instanceId: snapshot.id)
                : [:]
            let authenticated = await Task.detached {
                ProviderCLIProbe.authenticated(
                    provider: snapshot.provider,
                    binaryPath: launchBinary,
                    environment: environment
                )
            }.value
            guard authenticated == true else {
                throw ScheduledTaskPreflightError.providerUnavailable(
                    "The selected provider is unavailable for system user \(user.name). Sign in as that user and retry."
                )
            }

            let verified = Self.snapshot(snapshot, authenticated: true)
            do {
                try AgentProviderRunPreflight.validate(
                    snapshot: verified,
                    interactionMode: .default,
                    permissionMode: .fullAccess,
                    attachments: []
                )
            } catch {
                throw ScheduledTaskPreflightError.providerUnavailable(String(describing: error))
            }
            verifiedSnapshots.append(verified)
            launches[snapshot.id] = AgentOrchestrationLaunchConfiguration(
                binary: launchBinary,
                environment: environment
            )
        }

        let configuration = Self.routingConfiguration(
            for: task,
            policyDigest: orchestrationRuntime.policyDigest,
            eligibleProviders: [task.provider]
        )
        do {
            _ = try orchestrationRuntime.route(
                configuration: configuration,
                providerSnapshots: verifiedSnapshots
            )
        } catch {
            throw ScheduledTaskPreflightError.providerUnavailable(
                "Auto model routing is unavailable: \(error)"
            )
        }
        return AgentOrchestrationRoutingSnapshot(
            configuration: configuration,
            providerSnapshots: verifiedSnapshots,
            launchConfigurations: launches
        )
    }

    private static func snapshot(
        _ snapshot: AgentProviderSnapshot,
        authenticated: Bool
    ) -> AgentProviderSnapshot {
        AgentProviderSnapshot(
            id: snapshot.id,
            provider: snapshot.provider,
            driverKind: snapshot.driverKind,
            displayName: snapshot.displayName,
            accentColor: snapshot.accentColor,
            continuationGroup: snapshot.continuationGroup,
            interactionModes: snapshot.interactionModes,
            permissionModes: snapshot.permissionModes,
            enabled: snapshot.enabled,
            installed: snapshot.installed,
            version: snapshot.version,
            status: snapshot.status,
            statusDetail: snapshot.statusDetail,
            authenticated: authenticated,
            accountLabel: snapshot.accountLabel,
            accountAuthMethod: snapshot.accountAuthMethod,
            binaryPath: snapshot.binaryPath,
            homePath: snapshot.homePath,
            environmentKeys: snapshot.environmentKeys,
            models: snapshot.models,
            slashCommands: snapshot.slashCommands,
            skills: snapshot.skills,
            advisory: snapshot.advisory,
            updateState: snapshot.updateState,
            capabilities: snapshot.capabilities,
            modelDiscoverySource: snapshot.modelDiscoverySource,
            modelDiscoveryCacheKey: snapshot.modelDiscoveryCacheKey
        )
    }

    private func verifyPasswordlessSudo(user: ScheduledSystemUser) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "-u", "#\(user.uid)", "-H", "--", "/usr/bin/true"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ScheduledTaskPreflightError.sudoUnavailable(user.name) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ScheduledTaskPreflightError.sudoUnavailable(user.name) }
    }

    private func executionBinary(
        task: ScheduledTask,
        baseBinary: String,
        providerInstanceID: String? = nil
    ) throws -> String {
        guard let user = ScheduledSystemUserCatalog.user(named: task.runAsUser) else {
            throw ScheduledTaskPreflightError.ineligibleUser(task.runAsUser)
        }
        guard user.name != NSUserName() else { return baseBinary }
        let directory = context.appSupportDirectory.appendingPathComponent("scheduled-task-runners", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o711], ofItemAtPath: directory.path)
        let wrapper = directory.appendingPathComponent(Self.runnerFilename(
            taskID: task.id,
            providerInstanceID: providerInstanceID ?? task.providerInstanceID
        ))
        let script = "#!/bin/sh\nexec /usr/bin/sudo -n -u '#\(user.uid)' -H -- \(Self.shellQuote(baseBinary)) \"$@\"\n"
        try Data(script.utf8).write(to: wrapper, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return wrapper.path
    }

    nonisolated static func runnerFilename(taskID: UUID, providerInstanceID: String) -> String {
        let suffix = providerInstanceID
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        return "\(taskID.uuidString.lowercased())-\(suffix).sh"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func verifyProviderBinary(_ binary: String, user: ScheduledSystemUser) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "-u", "#\(user.uid)", "-H", "--", "/usr/bin/test", "-x", binary]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            throw ScheduledTaskPreflightError.providerUnavailable("The selected provider binary is unavailable to \(user.name).")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ScheduledTaskPreflightError.providerUnavailable("The selected provider binary is unavailable to \(user.name).")
        }
    }
}

@MainActor
public final class ScheduledTaskScheduler {
    /// Legacy name retained for tests; catch-up of missed fires is intentionally disabled.
    public nonisolated static let catchUpWindow: TimeInterval = 0
    private let store: ScheduledTaskStore
    private let context: AppContext
    private let executor: ScheduledTaskExecutor
    private let owner = UUID().uuidString.lowercased()
    private var tickTask: Task<Void, Never>?
    /// First tick after process start skips every past-due occurrence so reopening
    /// the app never replays work that fired while RemoteCode was closed.
    private var didSkipMissedOnLaunch = false

    public init(context: AppContext, router: AppCommandRouter) {
        self.context = context
        self.store = ScheduledTaskStore(db: context.db)
        self.executor = ScheduledTaskExecutor(context: context, router: router)
    }

    public func tick(now: Date = Date()) {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            guard let self else { return }
            defer { tickTask = nil }
            do {
                try observeRunning(now: now)
                _ = try store.recoverStaleLeases(now: now)
                if !didSkipMissedOnLaunch {
                    try skipMissedOccurrencesOnLaunch(now: now)
                    didSkipMissedOnLaunch = true
                }
                try reconcileNextRunDates(now: now)
                // Global travel kill switch — still observe/finish live runs, but
                // do not claim new automatic occurrences while inactive.
                let settings = SettingsStore(db: context.db).load()
                guard settings.scheduledTasksActive else {
                    scheduledTaskLog.debug("scheduler.tick_skipped global_active=false")
                    return
                }
                let claims = try store.claimDue(now: now, owner: owner)
                for claim in claims { await execute(claim) }
            } catch {
                scheduledTaskLog.error("scheduler.tick_failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func runNow(
        taskID: UUID,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        Task {
            do {
                let claim = try store.claimManual(taskID: taskID, owner: owner)
                completion(.success(()))
                await execute(claim)
            } catch {
                scheduledTaskLog.error("scheduler.run_now_failed task=\(taskID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                completion(.failure(error))
            }
        }
    }

    private func execute(_ claim: ScheduledTaskClaim) async {
        do {
            let next = claim.task.calculatedNextRun(after: claim.run.scheduledAt)
            try store.advance(taskID: claim.task.id, nextRunAt: next, lastRunAt: claim.task.lastRunAt)
            ScheduledTaskCrossProcess.notifyStoreChanged(reason: "queued")
            let identifiers = try await executor.execute(claim.task) { [self] threadID in
                // Link ownership before provider start so main-app Stop can route.
                try self.store.attachThread(runID: claim.run.id, threadID: threadID)
                ScheduledTaskCrossProcess.notifyStoreChanged(reason: "thread_linked")
            }
            try store.markStarted(runID: claim.run.id, threadID: identifiers.threadID, agentRunID: identifiers.runID)
            ScheduledTaskCrossProcess.notifyStoreChanged(reason: "started")
        } catch {
            try? store.finish(runID: claim.run.id, status: .failed, errorSummary: String(describing: error))
            ScheduledTaskCrossProcess.notifyStoreChanged(reason: "failed")
            SystemNotifier.shared.post(title: "Scheduled task failed", body: claim.task.title, category: nil)
        }
    }

    /// Stop a scheduled occurrence owned by this process's coordinator.
    public func stop(
        threadID: AgentThreadID,
        agentRunID: AgentRunID?,
        completion: @escaping @MainActor (ScheduledTaskStopResult, String?) -> Void
    ) {
        Task {
            let (result, message) = await stopOwned(threadID: threadID, agentRunID: agentRunID)
            completion(result, message)
        }
    }

    private func stopOwned(
        threadID: AgentThreadID,
        agentRunID: AgentRunID?
    ) async -> (ScheduledTaskStopResult, String?) {
        do {
            guard let occurrence = try store.activeRun(forThreadID: threadID) else {
                return (.notOwned, nil)
            }
            if let expected = agentRunID,
               let owned = occurrence.agentRunID,
               expected != owned {
                return (.notOwned, "Active scheduled run ID does not match.")
            }
            if occurrence.status == .queued {
                try store.finish(runID: occurrence.id, status: .cancelled, errorSummary: "Cancelled before start.")
                ScheduledTaskCrossProcess.notifyStoreChanged(reason: "cancelled")
                return (.alreadyTerminal, nil)
            }
            if let runID = occurrence.agentRunID ?? agentRunID {
                context.coordinator.stopRun(runID)
            }
            context.coordinator.stopRun(threadId: threadID)
            ScheduledTaskCrossProcess.notifyStoreChanged(reason: "stop_requested")
            return (.accepted, nil)
        } catch {
            return (.failed, error.localizedDescription)
        }
    }

    /// On cold start / reopen: advance every past-due `next_run_at` to the next
    /// future occurrence without creating a run. Missed fires are intentionally
    /// ignored — schedules only run while RemoteCode is open.
    private func skipMissedOccurrencesOnLaunch(now: Date) throws {
        for task in try store.list() where task.isEnabled {
            guard let due = task.nextRunAt, due < now else { continue }
            let future = task.calculatedNextRun(after: now)
            try store.advance(
                taskID: task.id,
                nextRunAt: future,
                lastRunAt: task.lastRunAt,
                at: now
            )
            scheduledTaskLog.info(
                "scheduler.skip_missed task=\(task.id.uuidString, privacy: .public) due=\(due.timeIntervalSince1970, privacy: .public)"
            )
        }
    }

    private func observeRunning(now: Date) throws {
        for run in try store.listActiveRuns() where run.status == .running {
            try store.heartbeat(runID: run.id, at: now)
            guard let agentRunID = run.agentRunID, let agentRun = try context.runRepo.get(id: agentRunID) else { continue }
            switch agentRun.status {
            case .completed:
                try store.finish(runID: run.id, status: .completed, at: agentRun.finishedAt ?? now)
                ScheduledTaskCrossProcess.notifyStoreChanged(reason: "completed")
            case .failed, .interrupted:
                try store.finish(runID: run.id, status: .failed, errorSummary: agentRun.errorMessage, at: agentRun.finishedAt ?? now)
                ScheduledTaskCrossProcess.notifyStoreChanged(reason: "failed")
                notifyFailure(for: run)
            case .cancelled:
                try store.finish(runID: run.id, status: .cancelled, errorSummary: agentRun.errorMessage, at: agentRun.finishedAt ?? now)
                ScheduledTaskCrossProcess.notifyStoreChanged(reason: "cancelled")
            case .pending, .running:
                break
            }
        }
    }

    private func notifyFailure(for run: ScheduledTaskRun) {
        let title = (try? store.get(id: run.taskID))?.title ?? "Scheduled task"
        SystemNotifier.shared.post(title: "Scheduled task failed", body: title, category: nil)
    }

    private func reconcileNextRunDates(now: Date) throws {
        for task in try store.list() where task.isEnabled {
            let reconciled = Self.reconciledDueDate(task: task, now: now)
            if reconciled != task.nextRunAt {
                try store.advance(taskID: task.id, nextRunAt: reconciled, lastRunAt: task.lastRunAt, at: now)
            }
        }
    }

    /// Keep future/just-due dates. Never collapse a backlog into a catch-up
    /// claim — missed fires are skipped on launch via `skipMissedOccurrencesOnLaunch`.
    public nonisolated static func reconciledDueDate(task: ScheduledTask, now: Date) -> Date? {
        if let next = task.nextRunAt { return next }
        return task.calculatedNextRun(after: now.addingTimeInterval(-1))
    }
}

/// Cross-process result for scheduled-run stop requests (XPC-friendly strings).
public enum ScheduledTaskStopResult: String, Sendable, Equatable {
    case accepted
    case alreadyTerminal
    case notOwned
    case failed

    public var isSuccess: Bool {
        switch self {
        case .accepted, .alreadyTerminal: return true
        case .notOwned, .failed: return false
        }
    }

    public static func parse(_ raw: String?, message: String?) -> (ScheduledTaskStopResult, String?) {
        if let raw, let known = ScheduledTaskStopResult(rawValue: raw) {
            return (known, message)
        }
        return (.failed, message ?? raw ?? "Unknown stop result")
    }
}

/// Posts/observes Darwin distributed notifications so the interactive app can
/// reload rails after LaunchAgent SQLite commits (EventBus is in-process only).
public enum ScheduledTaskCrossProcess {
    public static let storeChangedName = Notification.Name("io.remotecode.scheduled-tasks.store-changed")

    public static func notifyStoreChanged(reason: String) {
        DistributedNotificationCenter.default().postNotificationName(
            storeChangedName,
            object: reason,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    @discardableResult
    public static func observeStoreChanged(
        queue: OperationQueue? = .main,
        handler: @escaping (String?) -> Void
    ) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: storeChangedName,
            object: nil,
            queue: queue
        ) { note in
            handler(note.object as? String)
        }
    }

    public static func removeObserver(_ token: NSObjectProtocol) {
        DistributedNotificationCenter.default().removeObserver(token)
    }
}

@objc public protocol ScheduledTaskAgentXPCProtocol {
    func ping(withReply reply: @escaping (String) -> Void)
    func wake(taskID: String?, withReply reply: @escaping (Bool, String?) -> Void)
    /// Stop a LaunchAgent-owned scheduled provider run. Replies with
    /// (statusRaw: accepted|alreadyTerminal|notOwned|failed, message?).
    func stop(threadID: String, agentRunID: String?, withReply reply: @escaping (String, String?) -> Void)
}

@MainActor
private final class ScheduledTaskAgentXPCEndpoint: NSObject, @preconcurrency ScheduledTaskAgentXPCProtocol {
    private let scheduler: ScheduledTaskScheduler
    init(scheduler: ScheduledTaskScheduler) { self.scheduler = scheduler }

    func ping(withReply reply: @escaping (String) -> Void) {
        reply(ScheduledTaskAgentServiceManager.serviceVersion)
    }

    func wake(taskID: String?, withReply reply: @escaping (Bool, String?) -> Void) {
        if let taskID {
            guard let id = UUID(uuidString: taskID) else { reply(false, "Invalid task ID."); return }
            scheduler.runNow(taskID: id) { result in
                switch result {
                case .success:
                    reply(true, nil)
                case .failure(let error):
                    reply(false, error.localizedDescription)
                }
            }
            return
        } else {
            scheduler.tick()
        }
        reply(true, nil)
    }

    func stop(threadID: String, agentRunID: String?, withReply reply: @escaping (String, String?) -> Void) {
        guard let tid = UUID(uuidString: threadID).map(AgentThreadID.init) else {
            reply(ScheduledTaskStopResult.failed.rawValue, "Invalid thread ID.")
            return
        }
        let runID = agentRunID.flatMap(UUID.init(uuidString:)).map(AgentRunID.init)
        scheduler.stop(threadID: tid, agentRunID: runID) { result, message in
            reply(result.rawValue, message)
        }
    }
}

@MainActor
public final class ScheduledTaskAgentXPCListener: NSObject, @preconcurrency NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let endpoint: ScheduledTaskAgentXPCEndpoint

    public init(serviceName: String, scheduler: ScheduledTaskScheduler) {
        self.listener = NSXPCListener(machServiceName: serviceName)
        self.endpoint = ScheduledTaskAgentXPCEndpoint(scheduler: scheduler)
        super.init()
        listener.delegate = self
    }

    public func resume() { listener.resume() }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ScheduledTaskAgentXPCProtocol.self)
        connection.exportedObject = endpoint
        connection.resume()
        return true
    }
}

@MainActor
public final class ScheduledTaskAgentServiceManager {
    /// Bump when XPC methods change. Clients re-register a mismatched agent.
    public static let protocolVersion = 2
    public static var serviceBaseName: String { (Bundle.main.bundleIdentifier ?? "io.remotecode.desktop") + ".scheduled-tasks" }
    public static var plistName: String { serviceBaseName + ".plist" }
    public static var machServiceName: String { serviceBaseName }
    public static var serviceVersion: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        return "\(protocolVersion):\(build)"
    }

    public init() {}

    public var status: SMAppService.Status { SMAppService.agent(plistName: Self.plistName).status }

    public var statusDescription: String {
        switch status {
        case .enabled: return "Background scheduler active"
        case .requiresApproval: return "Approval required in Login Items"
        case .notFound: return "Background scheduler is ready to register"
        case .notRegistered: return "Background scheduler is not registered"
        @unknown default: return "Background scheduler status unknown"
        }
    }

    public func register() throws {
        let service = SMAppService.agent(plistName: Self.plistName)
        guard Self.registrationIsRequired(for: service.status) else { return }
        try service.register()
    }

    public func unregister() throws {
        try SMAppService.agent(plistName: Self.plistName).unregister()
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    public static func registrationIsRequired(for status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled, .requiresApproval:
            return false
        case .notRegistered, .notFound:
            return true
        @unknown default:
            return true
        }
    }

    public func wake(taskID: UUID? = nil, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        withReadyProxy { proxy, connection, fail in
            proxy.wake(taskID: taskID?.uuidString) { ok, message in
                Task { @MainActor in
                    if ok { completion(.success(())) }
                    else {
                        completion(.failure(ScheduledTaskPreflightError.invalidTask(
                            message ?? "Background scheduler rejected the request."
                        )))
                    }
                    connection.invalidate()
                }
            }
        } onFailure: { error in
            completion(.failure(error))
        }
    }

    /// Ask the LaunchAgent to stop a scheduled provider run it owns.
    public func stop(
        threadID: AgentThreadID,
        agentRunID: AgentRunID?,
        completion: @escaping @MainActor (ScheduledTaskStopResult, String?) -> Void
    ) {
        withReadyProxy { proxy, connection, _ in
            proxy.stop(
                threadID: threadID.value.uuidString,
                agentRunID: agentRunID?.value.uuidString
            ) { statusRaw, message in
                Task { @MainActor in
                    let parsed = ScheduledTaskStopResult.parse(statusRaw, message: message)
                    completion(parsed.0, parsed.1)
                    connection.invalidate()
                }
            }
        } onFailure: { error in
            completion(.failed, error.localizedDescription)
        }
    }

    private func withReadyProxy(
        _ body: @escaping (ScheduledTaskAgentXPCProtocol, NSXPCConnection, @escaping (Error) -> Void) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        let connection = NSXPCConnection(machServiceName: Self.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: ScheduledTaskAgentXPCProtocol.self)
        connection.interruptionHandler = { connection.invalidate() }
        connection.invalidationHandler = {}
        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            Task { @MainActor in onFailure(error); connection.invalidate() }
        } as? ScheduledTaskAgentXPCProtocol
        guard let proxy else {
            Task { @MainActor in
                onFailure(ScheduledTaskPreflightError.providerUnavailable("Background scheduler is unavailable."))
            }
            connection.invalidate()
            return
        }
        proxy.ping { version in
            Task { @MainActor in
                guard version == Self.serviceVersion else {
                    do {
                        try self.unregister()
                        try self.register()
                    } catch {
                        onFailure(error)
                        connection.invalidate()
                        return
                    }
                    onFailure(ScheduledTaskPreflightError.invalidTask(
                        "Scheduler version mismatch. The background scheduler was re-registered; retry when its status becomes active."
                    ))
                    connection.invalidate()
                    return
                }
                body(proxy, connection, { error in
                    Task { @MainActor in onFailure(error) }
                })
            }
        }
    }
}

@MainActor
public final class ScheduledTaskAgentAppDelegate: NSObject, NSApplicationDelegate {
    private let channel: ReleaseChannel
    private let appSupportOverride: String?
    private let dbOverride: String?
    private var context: AppContext?
    private var router: AppCommandRouter?
    private var scheduler: ScheduledTaskScheduler?
    private var xpcListener: ScheduledTaskAgentXPCListener?
    private var timer: Timer?
    private var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []

    public init(channel: ReleaseChannel, appSupportOverride: String?, dbOverride: String?) {
        self.channel = channel
        self.appSupportOverride = appSupportOverride
        self.dbOverride = dbOverride
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let appSupportDirectory = AppPaths.appSupportDirectory(
                for: channel,
                override: appSupportOverride
            )
            ProviderProcessOwnership.shared.configure(
                fileURL: Self.providerOwnershipFile(in: appSupportDirectory)
            )
            // Share the interactive app's SQLite, but do not run launch
            // reconciliation that marks every live Agent App run interrupted.
            let context = try AppContext(
                channel: channel,
                dbPathOverride: dbOverride,
                appSupportOverride: appSupportOverride,
                performLaunchRunReconciliation: false
            )
            let router = AppCommandRouter(context: context)
            context.router = router
            let scheduler = ScheduledTaskScheduler(context: context, router: router)
            let listener = ScheduledTaskAgentXPCListener(
                serviceName: ScheduledTaskAgentServiceManager.machServiceName,
                scheduler: scheduler
            )
            self.context = context
            self.router = router
            self.scheduler = scheduler
            self.xpcListener = listener
            SystemNotifier.shared.bootstrap()
            listener.resume()
            scheduler.tick()
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak scheduler] _ in
                Task { @MainActor in scheduler?.tick() }
            }
            observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.didWakeNotification) { scheduler.tick() }
            observe(NotificationCenter.default, name: .NSSystemClockDidChange) { scheduler.tick() }
            observe(NotificationCenter.default, name: .NSSystemTimeZoneDidChange) { scheduler.tick() }
        } catch {
            scheduledTaskLog.fault("scheduler.launch_failed error=\(error.localizedDescription, privacy: .public)")
            NSApp.terminate(nil)
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        for (center, token) in notificationTokens { center.removeObserver(token) }
        notificationTokens.removeAll()
        context?.coordinator.stopAllProviderSessionsForAppTermination()
    }

    private func observe(_ center: NotificationCenter, name: Notification.Name, handler: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in handler() }
        }
        notificationTokens.append((center, token))
    }

    public nonisolated static func providerOwnershipFile(in appSupportDirectory: URL) -> URL {
        appSupportDirectory
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent("provider-process-ownership.json", isDirectory: false)
    }
}
