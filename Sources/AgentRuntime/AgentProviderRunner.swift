import Foundation
import Darwin
import CoreModel

// MARK: - Spawn tagging

/// Immutable record written when a provider process is spawned.
/// The pgid is set to the child pid via setpgid(0,0) so the periodic
/// sweeper can identify and reap the process-group by its leader pid.
public struct SpawnedProcessTag: Sendable, Equatable {
    public let pgid: pid_t
    public let spawnedAt: Date

    public init(pgid: pid_t, spawnedAt: Date) {
        self.pgid = pgid
        self.spawnedAt = spawnedAt
    }
}

/// Pure helpers for tagging a spawned provider process and deciding
/// reap eligibility. nonisolated static so tests run without @MainActor.
public enum ProcessSpawnTagger {
    /// Default minimum age before a tagged process is eligible for reap.
    public static let defaultMinAge: TimeInterval = 30.0

    /// Call immediately after `proc.run()` to tag the child as a new
    /// process-group leader (setpgid(pid, 0) == setpgid(pid, pid)).
    /// Returns a tag on success, nil if the call fails (e.g. ESRCH race).
    @discardableResult
    public static func tagProcess(_ process: Process, now: Date = Date()) -> SpawnedProcessTag? {
        let pid = process.processIdentifier
        guard pid > 0 else { return nil }
        let rc = Darwin.setpgid(pid, 0)
        guard rc == 0 || errno == EPERM else { return nil }
        return SpawnedProcessTag(pgid: pid, spawnedAt: now)
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

public protocol AgentProviderAdapter: AnyObject {
    var provider: AgentProvider { get }
    func listModels() async -> [AgentModelDescriptor]
    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle
    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle
    func interruptTurn(threadId: AgentThreadID) throws
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) throws
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws
    func stopSession(threadId: AgentThreadID) throws
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws
    func listSessions() -> [AgentProviderSessionSummary]
    func hasSession(threadId: AgentThreadID) -> Bool
    func readThread(threadId: AgentThreadID) throws -> [AssistantEvent]
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) throws
    func stopAll()
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws
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

    public func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) throws {
        throw AgentProviderAdapterError.unsupported("respondToRequest")
    }

    public func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        throw AgentProviderAdapterError.unsupported("respondToUserInput")
    }

    public func stopSession(threadId: AgentThreadID) throws {
        try interruptTurn(threadId: threadId)
        lock.lock()
        sessions.removeValue(forKey: threadId)
        handles.removeValue(forKey: threadId)
        lock.unlock()
    }

    public func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {
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

    public func readThread(threadId: AgentThreadID) throws -> [AssistantEvent] {
        throw AgentProviderAdapterError.unsupported("readThread")
    }

    public func rollbackThread(threadId: AgentThreadID, toTurnId: String) throws {
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

    static func terminateTree(_ process: Process) {
        let root = process.processIdentifier
        // Enumerate the tree once (children first so leaves die before parents),
        // including the root, then signal each node.
        let pids = processTreePIDs(root: root)

        for step in terminationPlan(pids: pids, isAlive: { _ in true }, graceElapsed: false) {
            kill(step.pid, step.signal)
        }

        // Cancel must always win: give SIGTERM a brief grace period, then
        // escalate any survivors to SIGKILL.
        Thread.sleep(forTimeInterval: graceInterval)

        let escalation = terminationPlan(pids: pids, isAlive: Self.isAlive(_:), graceElapsed: true)
        for step in escalation {
            kill(step.pid, step.signal)
        }
    }

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

    // Returns the full process subtree rooted at `root` (children-first, root last)
    // using libproc, enumerating once instead of recursive pgrep subprocesses.
    private static func processTreePIDs(root: Int32) -> [Int32] {
        directChildPIDs(of: root).flatMap(processTreePIDs(root:)) + [root]
    }

    private static func directChildPIDs(of pid: Int32) -> [Int32] {
        let size = proc_listchildpids(pid, nil, 0)
        guard size > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(size))
        let written = proc_listchildpids(pid, &buffer, size * Int32(MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        let count = min(Int(written), buffer.count)
        return buffer.prefix(count).filter { $0 > 0 }
    }
}
