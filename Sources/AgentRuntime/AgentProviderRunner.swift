import Foundation
import Darwin
import CoreModel

// MARK: - Spawn tagging

/// Immutable record written when a provider process is spawned.
/// `pgid` retains the historical field name; it stores the exact provider root
/// PID. The persistent ownership sweep reconstructs its current descendant tree.
public struct ProviderProcessStartIdentity: Codable, Sendable, Equatable {
    public let seconds: UInt64
    public let microseconds: UInt64

    public init(seconds: UInt64, microseconds: UInt64) {
        self.seconds = seconds
        self.microseconds = microseconds
    }

    public static func read(pid: pid_t) -> ProviderProcessStartIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_start_tvsec > 0 else {
            return nil
        }
        return ProviderProcessStartIdentity(
            seconds: info.pbi_start_tvsec,
            microseconds: info.pbi_start_tvusec
        )
    }
}

public struct SpawnedProcessTag: Codable, Sendable, Equatable {
    public let pgid: pid_t
    public let spawnedAt: Date
    public let ownerPID: pid_t
    public let ownerStartIdentity: ProviderProcessStartIdentity?
    public let provider: AgentProvider?
    public let executablePath: String
    public let startIdentity: ProviderProcessStartIdentity?
    /// Present only when the spawned root was verified as the leader of its own
    /// process group. The leader start identity above anchors that group to the
    /// exact provider lifetime recorded at spawn.
    public let isolatedProcessGroup: pid_t?

    public init(
        pgid: pid_t,
        spawnedAt: Date,
        ownerPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        ownerStartIdentity: ProviderProcessStartIdentity? = nil,
        provider: AgentProvider? = nil,
        executablePath: String = "",
        startIdentity: ProviderProcessStartIdentity? = nil,
        isolatedProcessGroup: pid_t? = nil
    ) {
        self.pgid = pgid
        self.spawnedAt = spawnedAt
        self.ownerPID = ownerPID
        self.ownerStartIdentity = ownerStartIdentity
        self.provider = provider
        self.executablePath = executablePath
        self.startIdentity = startIdentity
        self.isolatedProcessGroup = isolatedProcessGroup
    }
}

/// Pure helpers for tagging a spawned provider process and deciding
/// reap eligibility. nonisolated static so tests run without @MainActor.
public enum ProcessSpawnTagger {
    /// Default minimum age before a tagged process is eligible for reap.
    public static let defaultMinAge: TimeInterval = 30.0

    /// Call immediately after `process.run()` to persist exact ownership.
    /// Foundation exposes no pre-exec group hook, so the post-spawn `setpgid`
    /// attempt is accepted only when the kernel immediately certifies the root
    /// as its own group leader. Failure kills the tree before any ledger row is
    /// written; availability never overrides complete crash-recovery ownership.
    ///
    /// `foreignUserLaunch` relaxes the child-metadata reads for a provider run as
    /// another macOS user via `sudo` (see `RunAsUserProcessBootstrap`): the spawned
    /// child is a root-owned `sudo`, whose `proc_pidinfo`/`proc_pidpath` are
    /// unreadable to this non-root parent (EPERM). We keep the row anchored on the
    /// always-readable OWNER identity (this app's own pid) plus the child pid, and
    /// tolerate a nil child start identity / exec path / process group. Live
    /// teardown is handled separately: the `sudo` root (invoker uid) is signalled
    /// directly and its target-uid descendants are reaped via `ProcessTerminator`'s
    /// sudo-routed path (a non-root app cannot signal a different-uid `claude`
    /// directly). The cost is only crash-recovery reach: the sweep fail-safes such
    /// a row (never signals a PID it cannot identify), so a cross-user orphan
    /// surviving an app crash is retained, never mis-reaped. For a same-user launch
    /// (`foreignUserLaunch: false`) every read stays a hard gate.
    @discardableResult
    public static func tagProcess(
        _ process: Process,
        provider: AgentProvider? = nil,
        foreignUserLaunch: Bool = false,
        now: Date = Date()
    ) throws -> SpawnedProcessTag {
        let pid = process.processIdentifier
        guard pid > 0 else {
            ProcessTerminator.terminateTreeImmediately(process)
            throw ProviderProcessOwnershipError.startIdentityUnavailable(pid)
        }
        // The owner is always this app's own process, so its kernel metadata is
        // readable and anchors the row for crash recovery even when the child is not.
        let ownerPID = ProcessInfo.processInfo.processIdentifier
        guard let ownerStartIdentity = ProviderProcessStartIdentity.read(pid: ownerPID) else {
            ProcessTerminator.terminateTreeImmediately(process)
            throw ProviderProcessOwnershipError.startIdentityUnavailable(ownerPID)
        }
        let startIdentity = ProviderProcessStartIdentity.read(pid: pid)
        guard startIdentity != nil || foreignUserLaunch else {
            ProcessTerminator.terminateTreeImmediately(process)
            throw ProviderProcessOwnershipError.startIdentityUnavailable(pid)
        }
        let executablePath = ProviderProcessExecutablePath.read(pid: pid)
        guard executablePath != nil || foreignUserLaunch else {
            ProcessTerminator.terminateTreeImmediately(process)
            throw ProviderProcessOwnershipError.executablePathUnavailable(pid)
        }
        let processGroup: pid_t?
        do {
            processGroup = try certifyIsolatedProcessGroup(
                pid: pid,
                setProcessGroup: { Darwin.setpgid($0, 0) },
                processGroup: Darwin.getpgid
            )
        } catch {
            // A root `sudo` child's group cannot always be certified from a
            // non-root parent; leave the row owner-anchored without it. For a
            // same-user launch an uncertifiable group is still fail-closed.
            guard foreignUserLaunch else {
                ProcessTerminator.terminateTreeImmediately(process)
                throw error
            }
            processGroup = nil
        }
        let tag = SpawnedProcessTag(
            pgid: pid,
            spawnedAt: now,
            ownerPID: ownerPID,
            ownerStartIdentity: ownerStartIdentity,
            provider: provider,
            executablePath: executablePath ?? "",
            startIdentity: startIdentity,
            isolatedProcessGroup: processGroup
        )
        do {
            try ProviderProcessOwnership.shared.record(tag)
        } catch {
            // A provider without a durable ownership row cannot be certified for
            // cleanup after a host crash. Fail the spawn and synchronously reap
            // the process instead of creating unowned background work.
            ProcessTerminator.terminateTreeImmediately(process)
            throw error
        }
        return tag
    }

    static func certifyIsolatedProcessGroup(
        pid: pid_t,
        setProcessGroup: (pid_t) -> Int32,
        processGroup: (pid_t) -> pid_t
    ) throws -> pid_t {
        _ = setProcessGroup(pid)
        let group = processGroup(pid)
        guard group == pid else {
            throw ProviderProcessOwnershipError.isolatedProcessGroupUnavailable(pid)
        }
        return group
    }

    /// Pure eligibility decision: a tagged process is reapable when
    ///   - it is still alive (process exists)
    ///   - it has lived longer than minAge (not just freshly spawned)
    /// The caller supplies isAlive and now so this stays fully testable.
    public static func isEligibleForReap(
        pgid: pid_t,
        spawnedAt: Date,
        minAge: TimeInterval = defaultMinAge,
        isAlive: (pid_t) -> Bool,
        now: Date = Date()
    ) -> Bool {
        guard isAlive(pgid) else { return false }
        return now.timeIntervalSince(spawnedAt) >= minAge
    }
}

public enum AgentRunEvent: Sendable {
    case event(AssistantEvent)
    case status(AgentRunStatus)
    case finished(AgentRunStatus, finalMessage: String?, providerThreadId: String?)
    case error(String)
}

public protocol AgentProviderRunner: AnyObject {
    var provider: AgentProvider { get }
    func listModels() async -> [AgentModelDescriptor]
    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle
}

public struct AgentProviderSessionSummary: Sendable, Equatable {
    public let threadId: AgentThreadID
    public let provider: AgentProvider
    public let status: AgentRunStatus
    public let providerThreadId: String?

    public init(threadId: AgentThreadID, provider: AgentProvider, status: AgentRunStatus, providerThreadId: String?) {
        self.threadId = threadId
        self.provider = provider
        self.status = status
        self.providerThreadId = providerThreadId
    }
}

public enum AgentProviderRequestResponse: Sendable, Equatable {
    case approve
    case approveForSession
    case decline(String?)
    case cancel
}

public enum AgentProviderAdapterError: Error, CustomStringConvertible {
    case unsupported(String)
    case sessionNotFound(AgentThreadID)

    public var description: String {
        switch self {
        case .unsupported(let operation): return "Provider adapter operation unsupported: \(operation)"
        case .sessionNotFound(let threadId): return "Provider session not found: \(threadId.value.uuidString)"
        }
    }
}

/// Provider-side fork is only safe to expose when repeating the same request
/// key is guaranteed to return the same provider child. Without that contract,
/// a crash after the provider response but before the local SQLite commit can
/// orphan one child and create another on retry.
public enum AgentProviderForkSafety: Sendable, Equatable {
    case unsupported
    case keyedIdempotent(compensationSupported: Bool)

    public var supportsDurableFork: Bool {
        if case .keyedIdempotent(let compensationSupported) = self {
            return compensationSupported
        }
        return false
    }

    public var supportsCompensation: Bool {
        if case .keyedIdempotent(let compensationSupported) = self {
            return compensationSupported
        }
        return false
    }
}

public struct AgentProviderForkRequest: Sendable, Equatable {
    public let sourceThreadId: AgentThreadID
    public let childThreadId: AgentThreadID
    public let idempotencyKey: String
    public let workingDirectory: String?
    public let sourceProviderThreadId: String?

    public init(
        sourceThreadId: AgentThreadID,
        childThreadId: AgentThreadID,
        idempotencyKey: String,
        workingDirectory: String? = nil,
        sourceProviderThreadId: String? = nil
    ) {
        self.sourceThreadId = sourceThreadId
        self.childThreadId = childThreadId
        self.idempotencyKey = idempotencyKey
        self.workingDirectory = workingDirectory
        self.sourceProviderThreadId = sourceProviderThreadId
    }
}

public protocol AgentProviderAdapter: AnyObject {
    var provider: AgentProvider { get }
    var forkSafety: AgentProviderForkSafety { get }
    func forkSafety(threadId: AgentThreadID) -> AgentProviderForkSafety
    func listModels() async -> [AgentModelDescriptor]
    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle
    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle
    func interruptTurn(threadId: AgentThreadID) throws
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws
    func respondToUserInput(threadId: AgentThreadID, requestId: String, verbatimText: String, outboundText: String) throws
    func cancelUserInput(threadId: AgentThreadID, requestId: String) throws
    func stopSession(threadId: AgentThreadID) throws
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws
    func listSessions() -> [AgentProviderSessionSummary]
    func hasSession(threadId: AgentThreadID) -> Bool
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent]
    func forkThread(threadId: AgentThreadID) async throws -> String
    func forkThread(_ request: AgentProviderForkRequest) async throws -> String
    func compensateFork(_ request: AgentProviderForkRequest, providerChildThreadId: String) async throws
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws
    func stopAll()
    func stopAllForAppTermination()
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws
}

public extension AgentProviderAdapter {
    var forkSafety: AgentProviderForkSafety { .unsupported }

    func forkSafety(threadId: AgentThreadID) -> AgentProviderForkSafety {
        forkSafety
    }

    func respondToUserInput(threadId: AgentThreadID, requestId: String, verbatimText: String, outboundText: String) throws {
        try respondToUserInput(threadId: threadId, requestId: requestId, text: verbatimText)
    }

    func cancelUserInput(threadId: AgentThreadID, requestId: String) throws {
        throw AgentProviderAdapterError.unsupported("User input cancellation is not available for this provider session.")
    }

    func forkThread(threadId: AgentThreadID) async throws -> String {
        throw AgentProviderAdapterError.unsupported("provider-native fork")
    }

    func forkThread(_ request: AgentProviderForkRequest) async throws -> String {
        throw AgentProviderAdapterError.unsupported("crash-safe keyed provider fork")
    }

    func compensateFork(_ request: AgentProviderForkRequest, providerChildThreadId: String) async throws {
        throw AgentProviderAdapterError.unsupported("idempotent provider fork compensation")
    }

    func stopAllForAppTermination() {
        stopAll()
    }
}

public final class OneShotProviderAdapter: AgentProviderAdapter, @unchecked Sendable {
    public let runner: AgentProviderRunner
    private let lock = NSLock()
    private var sessions: [AgentThreadID: AgentProviderSessionSummary] = [:]
    private var handles: [AgentThreadID: AgentRunHandle] = [:]

    public var provider: AgentProvider { runner.provider }

    public init(runner: AgentProviderRunner) {
        self.runner = runner
    }

    public func listModels() async -> [AgentModelDescriptor] {
        await runner.listModels()
    }

    public func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }

    public func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        lock.lock()
        sessions[request.threadId] = AgentProviderSessionSummary(threadId: request.threadId, provider: provider, status: .running, providerThreadId: request.providerThreadId)
        lock.unlock()
        let handle = try await runner.startRun(request) { [weak self] event in
            self?.record(event: event, threadId: request.threadId)
            onEvent(event)
        }
        lock.lock()
        handles[request.threadId] = handle
        lock.unlock()
        return handle
    }

    public func interruptTurn(threadId: AgentThreadID) throws {
        lock.lock()
        let handle = handles[threadId]
        lock.unlock()
        guard let handle else { throw AgentProviderAdapterError.sessionNotFound(threadId) }
        handle.cancel()
    }

    public func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        throw AgentProviderAdapterError.unsupported("Approvals are not available in one-shot CLI mode. Use supervised or streaming mode to approve tool requests.")
    }

    public func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        throw AgentProviderAdapterError.unsupported("User input responses are not available in one-shot CLI mode. Use supervised or streaming mode.")
    }

    public func stopSession(threadId: AgentThreadID) throws {
        try interruptTurn(threadId: threadId)
        lock.lock()
        sessions.removeValue(forKey: threadId)
        handles.removeValue(forKey: threadId)
        lock.unlock()
    }

    public func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {
        guard request.providerThreadId?.isEmpty == false else {
            throw AgentProviderAdapterError.unsupported("recoverSession requires providerThreadId")
        }
        lock.lock()
        sessions[request.threadId] = AgentProviderSessionSummary(threadId: request.threadId, provider: provider, status: .completed, providerThreadId: request.providerThreadId)
        lock.unlock()
    }

    public func listSessions() -> [AgentProviderSessionSummary] {
        lock.lock(); defer { lock.unlock() }
        return Array(sessions.values)
    }

    public func hasSession(threadId: AgentThreadID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId] != nil
    }

    public func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] {
        throw AgentProviderAdapterError.unsupported("readThread")
    }

    public func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {
        throw AgentProviderAdapterError.unsupported("rollbackThread")
    }

    public func stopAll() {
        lock.lock()
        let activeHandles = Array(handles.values)
        sessions.removeAll()
        handles.removeAll()
        lock.unlock()
        activeHandles.forEach { $0.cancel() }
    }

    public func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {
        throw AgentProviderAdapterError.unsupported("streamEvents")
    }

    private func record(event: AgentRunEvent, threadId: AgentThreadID) {
        guard case .finished(let status, _, let providerThreadId) = event else { return }
        lock.lock()
        sessions[threadId] = AgentProviderSessionSummary(threadId: threadId, provider: provider, status: status, providerThreadId: providerThreadId)
        handles.removeValue(forKey: threadId)
        lock.unlock()
    }
}

public final class AgentRunHandle: @unchecked Sendable {
    public let runId: AgentRunID
    public let process: Process?
    private let cancelHandler: () -> Void

    public init(runId: AgentRunID, process: Process?, cancel: @escaping () -> Void) {
        self.runId = runId
        self.process = process
        self.cancelHandler = cancel
    }

    public func cancel() {
        cancelHandler()
    }
}

final class AgentCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

struct ProcessTerminationStep: Equatable {
    let pid: Int32
    let signal: Int32
}

enum ProcessTerminator {
    // Grace window between SIGTERM and SIGKILL escalation.
    static let graceInterval: TimeInterval = 2.0

    /// When `foreignUserUID` is set the root is a `sudo` wrapper (invoker uid,
    /// directly signalable) and every descendant carries that target uid, which
    /// this non-root app cannot `SIGKILL` and `sudo` will not relay a `SIGKILL`
    /// for. The direct signals below still drive the graceful path — `SIGTERM`
    /// to the `sudo` root is relayed to the child — but the `SIGKILL` escalation
    /// of a stuck child is routed back through `sudo` as the target uid.
    static func terminateTree(_ process: Process, grace: TimeInterval = graceInterval, foreignUserUID: uid_t? = nil) {
        let root = process.processIdentifier
        // Enumerate the tree once (children first so leaves die before parents),
        // including the root, then signal each node.
        let pids = processTreePIDs(root: root)

        for step in terminationPlan(pids: pids, isAlive: { _ in true }, graceElapsed: false) {
            kill(step.pid, step.signal)
        }

        // Cancel must always win: give SIGTERM a grace period, then escalate any
        // survivors to SIGKILL. The grace wait is scheduled on a background
        // queue — every cancel path (Stop button, queue drain, idle reap) runs
        // on the main thread, so sleeping here froze the UI for the whole
        // grace window (F15). Never block the calling thread.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + grace) {
            let escalation = terminationPlan(pids: pids, isAlive: Self.isAlive(_:), graceElapsed: true)
            for step in escalation {
                kill(step.pid, step.signal)
            }
            if let foreignUserUID {
                let survivors = pids.filter { $0 != root && Self.isAlive($0) }
                killAsUserProvider(foreignUserUID, SIGKILL, survivors)
            }
        }
    }

    /// App termination cannot rely on the deferred escalation above: the app
    /// process may exit before its asyncAfter block runs, leaving a provider
    /// child alive for the next launch to rejoin. Preserve TERM-before-KILL,
    /// but deliver both phases synchronously without sleeping on the main actor.
    static func terminateTreeImmediately(_ process: Process, foreignUserUID: uid_t? = nil) {
        let root = process.processIdentifier
        let pids = processTreePIDs(root: root)
        for step in terminationPlan(pids: pids, isAlive: { _ in true }, graceElapsed: false) {
            kill(step.pid, step.signal)
        }
        // Reap the target-uid descendants via sudo BEFORE SIGKILLing the sudo
        // root: once sudo is killed it can neither relay signals nor reap its
        // child, so the child would orphan to launchd. `-n` sudo is fast (no
        // prompt) so this stays synchronous even on the app-termination path.
        if let foreignUserUID {
            let targets = pids.filter { $0 != root }
            killAsUserProvider(foreignUserUID, SIGKILL, targets)
        }
        for pid in pids {
            kill(pid, SIGKILL)
        }
    }

    /// The real sudo-routed reaper. Named so tests can restore it after swapping
    /// in a capture double (mirrors `LibprocChildPIDProvider` for childPIDProvider).
    static let defaultKillAsUserProvider: (uid_t, Int32, [pid_t]) -> Void = { uid, signal, pids in
        guard let plan = RunAsUserProcessBootstrap.sudoKillArguments(uid: uid, signal: signal, pids: pids) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executablePath)
        process.arguments = plan.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Best-effort teardown; a failed reap leaves an orphan we could not
            // have signalled directly anyway.
        }
    }

    /// Delivers `signal` to `pids` as the target uid via non-interactive `sudo`.
    /// Injectable so tests can assert the routing without spawning `sudo`.
    static var killAsUserProvider: (uid_t, Int32, [pid_t]) -> Void = defaultKillAsUserProvider

    // Pure helper: builds the signal plan for a set of pids.
    // graceElapsed == false  -> phase 1: SIGTERM every pid.
    // graceElapsed == true   -> phase 2: SIGKILL only pids still alive (skip dead).
    static func terminationPlan(
        pids: [Int32],
        isAlive: (Int32) -> Bool,
        graceElapsed: Bool
    ) -> [ProcessTerminationStep] {
        if !graceElapsed {
            return pids.map { ProcessTerminationStep(pid: $0, signal: SIGTERM) }
        }
        return pids
            .filter { isAlive($0) }
            .map { ProcessTerminationStep(pid: $0, signal: SIGKILL) }
    }

    // Liveness probe via signal 0 (no signal sent, only error checking).
    static func isAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        // EPERM means the process exists but we lack permission; still alive.
        return errno == EPERM
    }

    // Returns the full process subtree rooted at `root` (children-first, root last).
    // Uses the injected `childPIDProvider` so tests can supply fake process trees
    // without spawning real processes.
    // `internal` (not `private`) so tests can call it directly to verify provider wiring.
    static func processTreePIDs(root: Int32) -> [Int32] {
        childPIDProvider.directChildren(of: root).flatMap(processTreePIDs(root:)) + [root]
    }

    /// Tracks a provider tree across repeated teardown polls. `knownPIDs`
    /// retains children after reparenting; an isolated process group catches a
    /// child that forks during the root's TERM trap before the next tree scan.
    struct TreeTracker {
        let root: pid_t
        let isolatedProcessGroup: pid_t?
        private(set) var startIdentities: [pid_t: ProviderProcessStartIdentity] = [:]

        init(root: pid_t) {
            self.root = root
            let group = Darwin.getpgid(root)
            self.isolatedProcessGroup = group == root ? group : nil
            refresh()
        }

        init(
            root: pid_t,
            isolatedProcessGroup: pid_t?,
            initialPIDs: [pid_t],
            identity: (pid_t) -> ProviderProcessStartIdentity?
        ) {
            self.root = root
            self.isolatedProcessGroup = isolatedProcessGroup
            for pid in initialPIDs {
                if let value = identity(pid) { startIdentities[pid] = value }
            }
        }

        mutating func refresh() {
            refresh(
                descendants: { ProcessTerminator.processTreePIDs(root: $0) },
                processGroupMembers: ProcessTerminator.processGroupPIDs,
                identity: { ProviderProcessStartIdentity.read(pid: $0) }
            )
        }

        mutating func refresh(
            descendants: (pid_t) -> [pid_t],
            processGroupMembers: (pid_t) -> [pid_t],
            identity: (pid_t) -> ProviderProcessStartIdentity?
        ) {
            var candidates = descendants(root)
            if let isolatedProcessGroup {
                candidates.append(contentsOf: processGroupMembers(isolatedProcessGroup))
            }
            candidates.append(root)
            for pid in Set(candidates) where pid > 0 && pid != ProcessInfo.processInfo.processIdentifier {
                if startIdentities[pid] == nil, let value = identity(pid) {
                    startIdentities[pid] = value
                }
            }
        }

        func survivingPIDs(
            identity: (pid_t) -> ProviderProcessStartIdentity? = {
                ProviderProcessStartIdentity.read(pid: $0)
            }
        ) -> [pid_t] {
            startIdentities.compactMap { pid, expected in
                identity(pid) == expected ? pid : nil
            }.sorted()
        }

        func signalSurvivors(_ signal: Int32) {
            for pid in survivingPIDs().reversed() {
                _ = Darwin.kill(pid, signal)
            }
        }
    }

    static func processGroupPIDs(_ group: pid_t) -> [pid_t] {
        guard group > 0 else { return [] }
        let estimatedCount = max(1, Int(proc_listallpids(nil, 0)))
        var pids = [pid_t](repeating: 0, count: estimatedCount * 2)
        let count = proc_listallpids(
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.size)
        )
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 && Darwin.getpgid($0) == group }
    }

    // MARK: - Child-PID provider seam

    /// Abstracts the kernel lookup of direct child PIDs so termination ordering
    /// and escalation logic can be exercised in unit tests with a fake tree,
    /// without spawning real processes (Rule 8). The default implementation
    /// calls `proc_listchildpids` directly (libproc, single enumeration).
    /// `internal` so `@testable import AgentRuntime` exposes it to tests.
    protocol ChildPIDProviding: Sendable {
        func directChildren(of pid: Int32) -> [Int32]
    }

    /// Real (production) provider backed by `proc_listchildpids`.
    struct LibprocChildPIDProvider: ChildPIDProviding {
        func directChildren(of pid: Int32) -> [Int32] {
            let size = proc_listchildpids(pid, nil, 0)
            guard size > 0 else { return [] }
            var buffer = [pid_t](repeating: 0, count: Int(size))
            let written = proc_listchildpids(pid, &buffer, size * Int32(MemoryLayout<pid_t>.size))
            guard written > 0 else { return [] }
            let count = min(Int(written), buffer.count)
            return buffer.prefix(count).filter { $0 > 0 }
        }
    }

    /// Injected provider; defaults to the real `proc_listchildpids` implementation.
    /// Tests replace this with a `FakeChildPIDProvider` that returns a pre-wired tree.
    /// Written only in tests (before concurrent access begins) and read on a
    /// single thread from `terminateTree`.  There is no concurrent mutation in production.
    static var childPIDProvider: any ChildPIDProviding = LibprocChildPIDProvider()
}
