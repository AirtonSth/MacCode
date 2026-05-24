import Foundation
import Darwin
import CoreModel

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

enum ProcessTerminator {
    static func terminateTree(_ process: Process) {
        let root = process.processIdentifier
        for pid in childPIDs(of: root).reversed() {
            kill(pid, SIGTERM)
        }
        if process.isRunning {
            process.terminate()
        }
    }

    private static func childPIDs(of pid: Int32) -> [Int32] {
        let direct = directChildPIDs(of: pid)
        return direct + direct.flatMap(childPIDs(of:))
    }

    private static func directChildPIDs(of pid: Int32) -> [Int32] {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", "\(pid)"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return []
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }
}
