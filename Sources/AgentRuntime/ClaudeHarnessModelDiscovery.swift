import Foundation
import CoreModel

/// Reads Claude Code's account-local model catalog from the CLI control
/// channel. The initialize request is control metadata only; it never sends a
/// user prompt or starts an agent turn.
public enum ClaudeHarnessModelDiscovery {
    public static let launchArguments = [
        "--print",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--no-session-persistence"
    ]

    private final class ProbeState: @unchecked Sendable {
        let completion = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private let lineBuffer = LineBuffer()
        private var result: [AgentModelDescriptor]?

        func consume(_ data: Data) {
            for line in lineBuffer.take(data) {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let models = ClaudeHarnessModelDiscovery.modelDescriptors(from: object) else { continue }
                lock.lock()
                if result == nil {
                    result = models
                    completion.signal()
                }
                lock.unlock()
            }
        }

        var models: [AgentModelDescriptor] {
            lock.lock()
            defer { lock.unlock() }
            return result ?? []
        }
    }

    public static func listModels(
        binary: String = "claude",
        cwd: String = FileManager.default.currentDirectoryPath,
        environment: [String: String] = [:],
        runAsUser: AgentRunAsUser? = nil,
        timeout: TimeInterval = 10
    ) async -> [AgentModelDescriptor] {
        await Task.detached(priority: .utility) {
            Self.probe(
                binary: binary,
                cwd: cwd,
                environment: environment,
                runAsUser: runAsUser,
                timeout: timeout
            )
        }.value
    }

    static func modelDescriptors(from response: [String: Any]) -> [AgentModelDescriptor]? {
        guard response["type"] as? String == "control_response",
              let outer = response["response"] as? [String: Any],
              outer["subtype"] as? String == "success",
              let payload = outer["response"] as? [String: Any],
              let rawModels = payload["models"] as? [[String: Any]] else {
            return nil
        }

        return rawModels.compactMap { raw in
            guard let rawID = raw["value"] as? String else { return nil }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            let rawLabel = (raw["displayName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let label = rawLabel?.isEmpty == false ? rawLabel! : displayName(for: id)
            let efforts = (raw["supportedEffortLevels"] as? [String] ?? [])
                .compactMap { AgentReasoningEffort(rawValue: $0.lowercased()) }
                .reduce(into: [AgentReasoningEffort]()) { result, effort in
                    if !result.contains(effort) { result.append(effort) }
                }
            let supportsEffort = raw["supportsEffort"] as? Bool ?? !efforts.isEmpty
            return AgentModelDescriptor(
                id: id,
                label: label,
                provider: .claude,
                supportsReasoning: supportsEffort || !efforts.isEmpty,
                supportedReasoningEfforts: efforts,
                supportsCustomModel: true
            )
        }
    }

    private static func probe(
        binary: String,
        cwd: String,
        environment: [String: String],
        runAsUser: AgentRunAsUser?,
        timeout: TimeInterval
    ) -> [AgentModelDescriptor] {
        guard let executable = ProcessLocator.resolveForRunAsUser(binary, runAsUser: runAsUser) else {
            return []
        }

        var probeEnvironment = CodexRunner.processEnvironment(
            overrides: environment,
            purpose: .supportProcess
        )
        if let runAsUser, runAsUser.uid != getuid() {
            probeEnvironment["HOME"] = runAsUser.homePath
        }

        let process: Process
        do {
            let plan = try RunAsUserProcessBootstrap.plan(
                executablePath: executable,
                arguments: launchArguments,
                environment: probeEnvironment,
                currentDirectory: cwd,
                provider: .claude,
                runAsUser: runAsUser
            )
            process = Process()
            RunAsUserProcessBootstrap.apply(plan, to: process)
        } catch {
            return []
        }

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let state = ProbeState()
        var started = false
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            if started, process.isRunning {
                ProcessTerminator.terminateTreeImmediately(
                    process,
                    foreignUserUID: runAsUser.flatMap { $0.uid == getuid() ? nil : $0.uid }
                )
            }
            if started { process.waitUntilExit() }
        }

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            state.consume(data)
        }

        do {
            try process.run()
            started = true
            let request: [String: Any] = [
                "type": "control_request",
                "request_id": "rc-model-discovery",
                "request": ["subtype": "initialize"]
            ]
            let requestData = try JSONSerialization.data(withJSONObject: request)
            var requestLine = requestData
            requestLine.append(0x0A)
            try stdin.fileHandleForWriting.write(contentsOf: requestLine)
            try stdin.fileHandleForWriting.close()
        } catch {
            return []
        }

        _ = state.completion.wait(timeout: .now() + max(0.1, timeout))
        return state.models
    }

    private static func displayName(for id: String) -> String {
        id.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
