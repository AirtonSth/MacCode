import Foundation
import Darwin

public struct ProviderRuntimeProcess: Sendable, Equatable {
    public let pid: Int32
    public let ppid: Int32
    public let rssKB: Int
    public let command: String

    public init(pid: Int32, ppid: Int32, rssKB: Int, command: String) {
        self.pid = pid
        self.ppid = ppid
        self.rssKB = rssKB
        self.command = command
    }
}

public struct ProviderProcessSweepResult: Sendable, Equatable {
    public let orphanRootPIDs: [Int32]
    public let terminatedPIDs: [Int32]
    public let failedPIDs: [Int32]

    public init(orphanRootPIDs: [Int32], terminatedPIDs: [Int32], failedPIDs: [Int32]) {
        self.orphanRootPIDs = orphanRootPIDs
        self.terminatedPIDs = terminatedPIDs
        self.failedPIDs = failedPIDs
    }
}

public enum ProviderProcessSweeper {
    public static func currentProviderProcesses(
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> [ProviderRuntimeProcess] {
        currentProviderProcesses(
            processes: psRows(),
            currentPID: currentPID
        )
    }

    static func currentProviderProcesses(
        processes: [ProviderRuntimeProcess],
        currentPID: Int32
    ) -> [ProviderRuntimeProcess] {
        let roots = processes
            .filter { isRemoteCodeProviderRuntime($0, currentPID: currentPID) }
            .map(\.pid)
        let providerTree = Set(roots + roots.flatMap { descendants(of: $0, in: processes) })
        return processes
            .filter { providerTree.contains($0.pid) }
            .sorted { $0.pid < $1.pid }
    }

    @discardableResult
    public static func terminateOrphanedProviderRuntimes(
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> ProviderProcessSweepResult {
        terminateOrphanedProviderRuntimes(
            processes: psRows(),
            currentPID: currentPID
        ) { pid in
            Darwin.kill(pid, SIGTERM) == 0 || errno == ESRCH
        }
    }

    @discardableResult
    static func terminateOrphanedProviderRuntimes(
        processes: [ProviderRuntimeProcess],
        currentPID: Int32,
        terminate: (Int32) -> Bool
    ) -> ProviderProcessSweepResult {
        let roots = processes
            .filter { isOrphanRoot($0, currentPID: currentPID) }
            .map(\.pid)
            .sorted()
        let descendantPIDs = Set(roots.flatMap { Self.descendants(of: $0, in: processes) })
        let ordered = Array((descendantPIDs.union(roots)).sorted().reversed())
        var terminated: [Int32] = []
        var failed: [Int32] = []

        for pid in ordered {
            if terminate(pid) {
                terminated.append(pid)
            } else {
                failed.append(pid)
            }
        }

        return ProviderProcessSweepResult(
            orphanRootPIDs: roots,
            terminatedPIDs: terminated,
            failedPIDs: failed
        )
    }

    static func isRemoteCodeProviderRuntime(
        _ process: ProviderRuntimeProcess,
        currentPID: Int32
    ) -> Bool {
        guard process.pid != currentPID else { return false }
        let command = process.command
        return command.contains("/RemoteCode/AgentRuntime/ClaudeAgentSDKBridge/")
            || command.contains("ClaudeAgentSDKBridge.mjs")
            || command.contains("codex app-server")
    }

    private static func isOrphanRoot(
        _ process: ProviderRuntimeProcess,
        currentPID: Int32
    ) -> Bool {
        guard process.ppid == 1 else { return false }
        guard isRemoteCodeProviderRuntime(process, currentPID: currentPID) else { return false }
        return process.command.contains("ClaudeAgentSDKBridge.mjs")
            || process.command.contains("/claude ")
            || process.command.hasSuffix("/claude")
            || process.command.contains("codex app-server")
    }

    private static func descendants(
        of pid: Int32,
        in processes: [ProviderRuntimeProcess]
    ) -> [Int32] {
        let children = processes.filter { $0.ppid == pid }.map(\.pid)
        return children + children.flatMap { descendants(of: $0, in: processes) }
    }

    private static func psRows() -> [ProviderRuntimeProcess] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,rss=,command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap(parsePSRow)
    }

    static func parsePSRow(_ row: Substring) -> ProviderRuntimeProcess? {
        let trimmed = row.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(maxSplits: 3, whereSeparator: \.isWhitespace)
        guard parts.count == 4,
              let pid = Int32(parts[0]),
              let ppid = Int32(parts[1]),
              let rssKB = Int(parts[2]) else {
            return nil
        }
        return ProviderRuntimeProcess(pid: pid, ppid: ppid, rssKB: rssKB, command: String(parts[3]))
    }
}
