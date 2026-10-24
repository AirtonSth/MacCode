import Foundation
import CoreModel
import Dispatch
import Darwin

public enum DistillGuestRecoveryAction: String, Codable, Sendable {
    case resynchronizeGuest
    case refreshGuestCatalog
    case stop
}

public enum DistillGuestRecoveryCategory: String, Codable, Sendable {
    case catalog
    case transport
}

public struct DistillGuestRecoveryContext: Codable, Sendable {
    public let category: DistillGuestRecoveryCategory
    public let availableActions: [DistillGuestRecoveryAction]

    public init(category: DistillGuestRecoveryCategory, availableActions: [DistillGuestRecoveryAction]) {
        self.category = category
        self.availableActions = availableActions
    }
}

public enum DistillGuestHostDiagnosis {
    static let outputLimit = 64 * 1024
    static let prompt = "Choose the safest allowed recovery action. Do not use tools. A missing guest catalog has already failed refresh; resynchronize the guest's credential copy when allowed, then the host will verify the selected model again. Return only the required JSON object."
    enum Failure: Error { case unavailable, invalidOutput, timedOut, outputLimit }

    public static func diagnose(_ context: DistillGuestRecoveryContext, request: AgentRunRequest) async throws -> DistillGuestRecoveryAction {
        try Task.checkCancellation()
        guard request.runAsUser.map({ $0.uid == getuid() }) ?? true else { throw Failure.unavailable }
        let processEnvironment = ProcessInfo.processInfo.environment.merging(request.environment) { _, requestValue in requestValue }
        let hostHome = DistillProvisioner.homeURL(environment: processEnvironment)
        guard let binary = DistillProvisioner.resolveInstalledBinary(override: request.providerBinary, environmentPath: processEnvironment["PATH"], homeDirectory: hostHome.deletingLastPathComponent().path) else { throw Failure.unavailable }
        return try await diagnose(context, request: request, binary: binary, hostHome: hostHome, temporaryHome: nil, timeout: 30)
    }

    static func diagnose(_ context: DistillGuestRecoveryContext, request: AgentRunRequest, binary: String, hostHome: URL, temporaryHome suppliedHome: URL?, timeout: TimeInterval) async throws -> DistillGuestRecoveryAction {
        try Task.checkCancellation()
        let temporaryHome = suppliedHome ?? FileManager.default.temporaryDirectory.appendingPathComponent("distill-diagnosis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporaryHome) }
        try Task.checkCancellation()
        try DistillGuestCredentials.sync(hostHome: hostHome, guestDistillHome: temporaryHome.appendingPathComponent(".distill", isDirectory: true))
        try Task.checkCancellation()
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "GROK_CLAUDE_MCPS_ENABLED": "0", "GROK_CURSOR_MCPS_ENABLED": "0", "HOME": temporaryHome.path, "CFFIXED_USER_HOME": temporaryHome.path, "DISTILL_HOME": temporaryHome.appendingPathComponent(".distill", isDirectory: true).path]
        let encoded = try JSONEncoder().encode(context)
        let contextText = String(decoding: encoded, as: UTF8.self)
        let model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let args = ["--no-auto-update", "--no-subagents", "--disable-web-search", "--tools", "", "--deny", "*", "--max-turns", "1", "--output-format", "json", "--model", model.isEmpty ? "auto" : model, "--print", "\(prompt)\nRequired JSON schema: \(schema(allowedActions: context.availableActions))\n\(contextText)"]
        try Task.checkCancellation()
        let result = try await run(binary: binary, arguments: args, environment: environment, cwd: temporaryHome, timeout: timeout)
        guard result.status == 0 else { throw Failure.unavailable }
        return try parse(result.stdout, allowedActions: context.availableActions)
    }

    static func schema(allowedActions: [DistillGuestRecoveryAction]) -> String {
        let encoded = (try? JSONSerialization.data(withJSONObject: allowedActions.map(\.rawValue), options: [.fragmentsAllowed])) ?? Data("[]".utf8)
        return "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":\(String(decoding: encoded, as: UTF8.self))}},\"required\":[\"action\"],\"additionalProperties\":false}"
    }

    static func parse(_ data: Data, allowedActions: [DistillGuestRecoveryAction]) throws -> DistillGuestRecoveryAction {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidOutput }
        var object: [String: Any]?
        if let structured = envelope["structuredOutput"] {
            guard (envelope["structuredOutputError"] == nil || envelope["structuredOutputError"] is NSNull),
                  (envelope["stopReason"] == nil || ["end_turn", "normal"].contains(envelope["stopReason"] as? String ?? "")),
                  let value = structured as? [String: Any] else { throw Failure.invalidOutput }
            object = value
        } else if let result = envelope["result"] as? [String: Any] {
            object = result
        } else if let text = envelope["text"] as? String,
                  let reason = envelope["stopReason"] as? String,
                  ["end_turn", "normal"].contains(reason),
                  let bytes = text.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
            object = parsed
        } else if envelope["action"] != nil {
            object = envelope
        }
        guard let object, Set(object.keys) == ["action"], let raw = object["action"] as? String,
              let action = DistillGuestRecoveryAction(rawValue: raw), allowedActions.contains(action) else { throw Failure.invalidOutput }
        return action
    }

    static func run(binary: String, arguments: [String], environment: [String: String], cwd: URL, timeout: TimeInterval) async throws -> (stdout: Data, status: Int32) {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = cwd
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let owner = ProcessOwner(process: process)
        process.terminationHandler = { [owner] _ in owner.markExited() }
        do { try process.run() } catch { process.terminationHandler = nil; throw Failure.unavailable }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in owner.begin(out: out, err: err, timeout: timeout, continuation: continuation) }
        }, onCancel: { owner.stop(CancellationError()) })
    }

    private final class ProcessOwner: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var stdout = Data()
        private var total = 0
        private var stdoutEOF = false
        private var stderrEOF = false
        private var exited = false
        private var failure: Error?
        private var continuation: CheckedContinuation<(stdout: Data, status: Int32), Error>?
        private var timer: DispatchWorkItem?
        init(process: Process) { self.process = process }

        func begin(out: Pipe, err: Pipe, timeout: TimeInterval, continuation: CheckedContinuation<(stdout: Data, status: Int32), Error>) {
            lock.lock(); self.continuation = continuation
            let timer = DispatchWorkItem { [weak self] in self?.stop(Failure.timedOut) }
            self.timer = timer
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            out.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.read(handle, stdout: true) }
            err.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.read(handle, stdout: false) }
        }

        private func read(_ handle: FileHandle, stdout isStdout: Bool) {
            let bytes = handle.availableData
            lock.lock()
            if bytes.isEmpty {
                if isStdout { stdoutEOF = true } else { stderrEOF = true }
            } else if failure == nil {
                total += bytes.count
                if total > DistillGuestHostDiagnosis.outputLimit { failure = Failure.outputLimit }
                else if isStdout { stdout.append(bytes) }
            }
            let mustStop = failure != nil && !exited
            lock.unlock()
            if bytes.isEmpty { handle.readabilityHandler = nil }
            if mustStop { terminateOwnedProcess() }
            completeIfReady()
        }

        func markExited() {
            lock.lock(); exited = true; lock.unlock()
            completeIfReady()
        }

        func stop(_ error: Error) {
            lock.lock()
            guard failure == nil else { lock.unlock(); return }
            failure = error
            let pid = process.processIdentifier
            lock.unlock()
            if pid > 0, process.isRunning { _ = kill(pid, SIGTERM) }
            escalateKill(pid: pid)
        }

        private func terminateOwnedProcess() {
            let pid = process.processIdentifier
            guard pid > 0, process.isRunning else { return }
            _ = kill(pid, SIGTERM)
            escalateKill(pid: pid)
        }

        private func escalateKill(pid: Int32) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let stillRunning = !self.exited; let currentPID = self.process.processIdentifier; self.lock.unlock()
                if stillRunning, currentPID == pid, self.process.isRunning { _ = kill(pid, SIGKILL) }
            }
        }

        private func completeIfReady() {
            lock.lock()
            guard exited, stdoutEOF, stderrEOF, let continuation else { lock.unlock(); return }
            self.continuation = nil
            timer?.cancel(); timer = nil
            process.terminationHandler = nil
            let error = failure
            let result = (stdout, process.terminationStatus)
            lock.unlock()
            if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: result) }
        }
    }
}
