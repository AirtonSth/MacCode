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

public final class AgentRunHandle: @unchecked Sendable {
    public let runId: AgentRunID
    public let process: Process?
    private let cancelHandler: @Sendable () -> Void

    public init(runId: AgentRunID, process: Process?, cancel: @escaping @Sendable () -> Void) {
        self.runId = runId
        self.process = process
        self.cancelHandler = cancel
    }

    public func cancel() {
        cancelHandler()
    }
}

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
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
