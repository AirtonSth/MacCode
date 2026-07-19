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

    public static func currentSidecarProcesses(
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> [ProviderRuntimeProcess] {
        currentSidecarProcesses(
            processes: psRows(),
            currentPID: currentPID
        )
    }

    static func currentSidecarProcesses(
        processes: [ProviderRuntimeProcess],
        currentPID: Int32
    ) -> [ProviderRuntimeProcess] {
        let roots = processes
            .filter { isRemoteCodeSidecarRuntime($0, currentPID: currentPID) }
            .map(\.pid)
        let sidecarTree = Set(roots + roots.flatMap { descendants(of: $0, in: processes) })
        return processes
            .filter { sidecarTree.contains($0.pid) }
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

    /// Reap launchd-reparented `RemoteCodeDistillService` processes.
    ///
    /// WHY: Token Saver MLX sidecars can exceed multi-GB RSS. When the owning
    /// RemoteCode host dies without `stop()`, the sidecar is reparented to
    /// launchd (ppid=1) and keeps the model resident forever. Heartbeat only
    /// *counted* these orphans; it never terminated them. Memory pressure from
    /// multi-GB orphan sidecars freezes the whole Mac (including a healthy
    /// RemoteCode UI). Only ppid==1 roots are candidates so the current app's
    /// live child Distill process is never touched.
    @discardableResult
    public static func terminateOrphanedSidecarRuntimes(
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> ProviderProcessSweepResult {
        terminateOrphanedSidecarRuntimes(
            processes: psRows(),
            currentPID: currentPID
        ) { pid in
            Darwin.kill(pid, SIGTERM) == 0 || errno == ESRCH
        }
    }

    @discardableResult
    static func terminateOrphanedSidecarRuntimes(
        processes: [ProviderRuntimeProcess],
        currentPID: Int32,
        terminate: (Int32) -> Bool
    ) -> ProviderProcessSweepResult {
        let roots = processes
            .filter { isOrphanSidecarRoot($0, currentPID: currentPID) }
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
        return isRemoteCodeClaudeRuntime(command)
            || isCodexAppServerRuntime(command)
    }

    static func isRemoteCodeSidecarRuntime(
        _ process: ProviderRuntimeProcess,
        currentPID: Int32
    ) -> Bool {
        guard process.pid != currentPID else { return false }
        return isRemoteCodeDistillService(process.command)
    }

    private static func isOrphanRoot(
        _ process: ProviderRuntimeProcess,
        currentPID: Int32
    ) -> Bool {
        guard process.ppid == 1 else { return false }
        guard isRemoteCodeProviderRuntime(process, currentPID: currentPID) else { return false }
        return isRemoteCodeClaudeRuntime(process.command)
            || process.command.contains("/claude ")
            || process.command.hasSuffix("/claude")
            || isCodexAppServerRuntime(process.command)
    }

    /// Pure eligibility for Distill sidecar orphan reaping.
    /// internal so unit tests can pin the contract without process-table noise.
    static func isOrphanSidecarRoot(
        _ process: ProviderRuntimeProcess,
        currentPID: Int32
    ) -> Bool {
        guard process.pid != currentPID else { return false }
        guard process.ppid == 1 else { return false }
        return isRemoteCodeDistillService(process.command)
    }

    // MARK: - Single Distill MLX server policy

    /// True when `command` is the long-running Token Saver Distill HTTP/MLX
    /// server (auth-token / host / port), not a short-lived `mcp` CLI helper.
    ///
    /// WHY: agents invoke `RemoteCodeDistillService mcp` as the managed `| distill`
    /// pipe. Those helpers must stay multi-instance. Only the multi-GB MLX server
    /// is singleton-scoped.
    public static func isRemoteCodeDistillServerCommand(_ command: String) -> Bool {
        guard isRemoteCodeDistillService(command) else { return false }
        return !isRemoteCodeDistillMCPCommand(command)
    }

    /// True when argv mode is `mcp` (managed distill CLI helper).
    public static func isRemoteCodeDistillMCPCommand(_ command: String) -> Bool {
        guard isRemoteCodeDistillService(command) else { return false }
        let parts = command.split(whereSeparator: \.isWhitespace).map(String.init)
        // executable [mode] …
        return parts.count >= 2 && parts[1] == "mcp"
    }

    /// Kill every Distill MLX server except an optional keepPID (the controller's
    /// live child). Used before start (single-instance) and on app quit.
    @discardableResult
    public static func terminateDistillServers(
        keeping keepPID: Int32? = nil,
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> ProviderProcessSweepResult {
        terminateDistillServers(
            processes: psRows(),
            keepPID: keepPID,
            currentPID: currentPID
        ) { pid in
            Darwin.kill(pid, SIGTERM) == 0 || errno == ESRCH
        }
    }

    @discardableResult
    static func terminateDistillServers(
        processes: [ProviderRuntimeProcess],
        keepPID: Int32?,
        currentPID: Int32,
        terminate: (Int32) -> Bool
    ) -> ProviderProcessSweepResult {
        let roots = processes
            .filter { isDistillServerRoot($0, keepPID: keepPID, currentPID: currentPID) }
            .map(\.pid)
            .sorted()
        let descendantPIDs = Set(roots.flatMap { Self.descendants(of: $0, in: processes) })
        // Never signal the host app itself if it somehow matched.
        let ordered = Array(
            (descendantPIDs.union(roots))
                .filter { $0 != currentPID && $0 != keepPID }
                .sorted()
                .reversed()
        )
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

    /// Pure root selection for single-server policy.
    static func isDistillServerRoot(
        _ process: ProviderRuntimeProcess,
        keepPID: Int32?,
        currentPID: Int32
    ) -> Bool {
        guard process.pid != currentPID else { return false }
        if let keepPID, process.pid == keepPID { return false }
        return isRemoteCodeDistillServerCommand(process.command)
    }

    static func descendants(
        of pid: Int32,
        in processes: [ProviderRuntimeProcess]
    ) -> [Int32] {
        var pending = processes.filter { $0.ppid == pid }.map(\.pid)
        var seen = Set<Int32>()
        var result: [Int32] = []

        while let child = pending.popLast() {
            guard seen.insert(child).inserted else { continue }
            result.append(child)
            pending.append(contentsOf: processes.filter { $0.ppid == child }.map(\.pid))
        }

        return result
    }

    private static func isRemoteCodeClaudeRuntime(_ command: String) -> Bool {
        command.contains("/RemoteCode/AgentRuntime/ClaudeAgentSDKBridge/")
    }

    private static func isCodexAppServerRuntime(_ command: String) -> Bool {
        let parts = command.split(maxSplits: 2, whereSeparator: \.isWhitespace)
        guard parts.count >= 2 else { return false }
        let executable = String(parts[0])
        return (executable == "codex" || executable.hasSuffix("/codex"))
            && parts[1] == "app-server"
    }

    /// Shared binary-name gate (server + mcp). public for pure unit tests of the
    /// single-server policy without process-table noise.
    public static func isRemoteCodeDistillService(_ command: String) -> Bool {
        guard let executable = command.split(maxSplits: 1, whereSeparator: \.isWhitespace).first else {
            return false
        }
        let name = (String(executable) as NSString).lastPathComponent
        return name == "RemoteCodeDistillService"
    }

    static func psRows() -> [ProviderRuntimeProcess] {
        (try? psRowsThrowing()) ?? []
    }

    public static func psRowsThrowing() throws -> [ProviderRuntimeProcess] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,rss=,command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ProviderProcessOwnershipError.processListFailed(error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ProviderProcessOwnershipError.processListFailed(
                "ps exited with status \(process.terminationStatus)"
            )
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap(parsePSRow)
    }

    // MARK: - Tagged-orphan periodic sweep

    /// Entry point for the periodic sweeper.
    /// Accepts `SpawnedProcessTag` records written by `ProcessSpawnTagger.tagProcess`
    /// at spawn time. Injectable predicates keep the logic pure and fully testable.
    ///
    /// A tag is reapable when `ProcessSpawnTagger.isEligibleForReap` returns true
    /// (alive AND older than minAge). `terminate(pgid)` is called for every eligible
    /// pgid; the caller should use `killpg(pgid, SIGTERM/SIGKILL)` to reap the
    /// whole process-group.
    @discardableResult
    public static func sweepTaggedOrphans(
        tags: [SpawnedProcessTag],
        minAge: TimeInterval = ProcessSpawnTagger.defaultMinAge,
        isAlive: (pid_t) -> Bool,
        now: Date = Date(),
        terminate: (pid_t) -> Bool
    ) -> ProviderProcessSweepResult {
        var orphanRoots: [Int32] = []
        var terminated: [Int32] = []
        var failed: [Int32] = []
        for tag in tags.sorted(by: { $0.pgid < $1.pgid }) {
            guard ProcessSpawnTagger.isEligibleForReap(
                pgid: tag.pgid,
                spawnedAt: tag.spawnedAt,
                minAge: minAge,
                isAlive: isAlive,
                now: now
            ) else { continue }
            orphanRoots.append(tag.pgid)
            if terminate(tag.pgid) {
                terminated.append(tag.pgid)
            } else {
                failed.append(tag.pgid)
            }
        }
        return ProviderProcessSweepResult(
            orphanRootPIDs: orphanRoots,
            terminatedPIDs: terminated,
            failedPIDs: failed
        )
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
