import Foundation
import AppKit
import CoreModel
import Persistence
import AgentRuntime
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

public enum ScheduledTaskPreflightError: Error, CustomStringConvertible, Equatable {
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

    public func execute(_ task: ScheduledTask) async throws -> (threadID: AgentThreadID, runID: AgentRunID) {
        let prepared = try await prepareExecution(task)
        let selection = AgentModelSelection(
            provider: task.provider,
            modelId: task.model,
            reasoningEffort: task.reasoningEffort
        )
        let routingConfiguration = prepared.routingSnapshot?.configuration
            ?? AgentRoutingConfiguration.legacyManual(
                selection: selection,
                providerInstanceId: task.providerInstanceID
            )
        let thread = AgentThread(
            workspaceId: task.workspaceID,
            title: task.title,
            provider: task.provider,
            providerInstanceId: task.providerInstanceID,
            model: task.model,
            permissionMode: .fullAccess,
            reasoningEffort: task.reasoningEffort,
            serviceTier: .auto,
            modelSelection: selection,
            routingConfiguration: routingConfiguration
        )
        try context.threadRepo.upsert(thread)
        let request = AgentRunRequest(
            threadId: thread.id,
            provider: task.provider,
            providerInstanceId: task.providerInstanceID,
            model: task.model,
            cwd: prepared.workspace.cwd,
            prompt: task.prompt,
            permissionMode: .fullAccess,
            reasoningEffort: task.reasoningEffort,
            providerBinary: prepared.manualLaunch?.binary,
            environment: prepared.manualLaunch?.environment ?? [:]
        )
        let runID = try await context.coordinator.startRun(
            request,
            routingSnapshot: prepared.routingSnapshot
        )
        return (thread.id, runID)
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
                "The selected provider account is unavailable for system user \(user.name). Sign in as that user and retry."
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

        // Scheduled Auto is host-bound: only the user-chosen provider account may
        // run. Never admit other providers or substitute another account of the
        // same provider when the saved instance is unavailable (SCHED-005).
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
                "The selected provider account (\(task.provider.rawValue) · \(task.providerInstanceID)) is unavailable for Auto model routing."
            )
        }

        for snapshot in candidateSnapshots {
            let binary = snapshot.binaryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseBinary = binary?.isEmpty == false ? binary! : snapshot.provider.rawValue
            if user.name != NSUserName() {
                do { try verifyProviderBinary(baseBinary, user: user) }
                catch {
                    throw ScheduledTaskPreflightError.providerUnavailable(
                        "The selected provider account is not executable as \(user.name): \(error)"
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
                    "The selected provider account is unavailable for system user \(user.name). Sign in as that user and retry."
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
    public nonisolated static let catchUpWindow: TimeInterval = 24 * 60 * 60
    private let store: ScheduledTaskStore
    private let context: AppContext
    private let executor: ScheduledTaskExecutor
    private let owner = UUID().uuidString.lowercased()
    private var tickTask: Task<Void, Never>?

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
                try reconcileCatchUp(now: now)
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
            let identifiers = try await executor.execute(claim.task)
            try store.markStarted(runID: claim.run.id, threadID: identifiers.threadID, agentRunID: identifiers.runID)
        } catch {
            try? store.finish(runID: claim.run.id, status: .failed, errorSummary: String(describing: error))
            SystemNotifier.shared.post(title: "Scheduled task failed", body: claim.task.title, category: nil)
        }
    }

    private func observeRunning(now: Date) throws {
        for run in try store.listActiveRuns() where run.status == .running {
            try store.heartbeat(runID: run.id, at: now)
            guard let agentRunID = run.agentRunID, let agentRun = try context.runRepo.get(id: agentRunID) else { continue }
            switch agentRun.status {
            case .completed:
                try store.finish(runID: run.id, status: .completed, at: agentRun.finishedAt ?? now)
            case .failed, .interrupted:
                try store.finish(runID: run.id, status: .failed, errorSummary: agentRun.errorMessage, at: agentRun.finishedAt ?? now)
                notifyFailure(for: run)
            case .cancelled:
                try store.finish(runID: run.id, status: .cancelled, errorSummary: agentRun.errorMessage, at: agentRun.finishedAt ?? now)
            case .pending, .running:
                break
            }
        }
    }

    private func notifyFailure(for run: ScheduledTaskRun) {
        let title = (try? store.get(id: run.taskID))?.title ?? "Scheduled task"
        SystemNotifier.shared.post(title: "Scheduled task failed", body: title, category: nil)
    }

    private func reconcileCatchUp(now: Date) throws {
        for task in try store.list() where task.isEnabled {
            let reconciled = Self.reconciledDueDate(task: task, now: now)
            if reconciled != task.nextRunAt {
                try store.advance(taskID: task.id, nextRunAt: reconciled, lastRunAt: task.lastRunAt, at: now)
            }
        }
    }

    public nonisolated static func reconciledDueDate(task: ScheduledTask, now: Date) -> Date? {
        guard let candidate = task.nextRunAt ?? task.calculatedNextRun(after: now.addingTimeInterval(-1)) else { return nil }
        guard candidate <= now else { return candidate }
        var latest = candidate
        var iterations = 0
        while iterations < 10_000, let next = task.calculatedNextRun(after: latest), next <= now {
            latest = next
            iterations += 1
        }
        if latest >= now.addingTimeInterval(-catchUpWindow) { return latest }
        return task.calculatedNextRun(after: now)
    }
}

@objc public protocol ScheduledTaskAgentXPCProtocol {
    func ping(withReply reply: @escaping (String) -> Void)
    func wake(taskID: String?, withReply reply: @escaping (Bool, String?) -> Void)
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
    public static let protocolVersion = 1
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
        let connection = NSXPCConnection(machServiceName: Self.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: ScheduledTaskAgentXPCProtocol.self)
        connection.interruptionHandler = { connection.invalidate() }
        connection.invalidationHandler = {}
        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            Task { @MainActor in completion(.failure(error)); connection.invalidate() }
        } as? ScheduledTaskAgentXPCProtocol
        guard let proxy else {
            completion(.failure(ScheduledTaskPreflightError.providerUnavailable("Background scheduler is unavailable.")))
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
                        completion(.failure(error))
                        connection.invalidate()
                        return
                    }
                    completion(.failure(ScheduledTaskPreflightError.invalidTask(
                        "Scheduler version mismatch. The background scheduler was re-registered; retry when its status becomes active."
                    )))
                    connection.invalidate()
                    return
                }
                proxy.wake(taskID: taskID?.uuidString) { ok, message in
                    Task { @MainActor in
                        if ok { completion(.success(())) }
                        else { completion(.failure(ScheduledTaskPreflightError.invalidTask(message ?? "Background scheduler rejected the request."))) }
                        connection.invalidate()
                    }
                }
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
