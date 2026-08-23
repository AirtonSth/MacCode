import Foundation
import Darwin

public struct ProviderRuntimeProcess: Sendable, Equatable {
    public let pid: Int32
    public let ppid: Int32
    public let pgid: Int32?
    public let rssKB: Int
    public let command: String

    public init(pid: Int32, ppid: Int32, pgid: Int32? = nil, rssKB: Int, command: String) {
        self.pid = pid
        self.ppid = ppid
        self.pgid = pgid
        self.rssKB = rssKB
        self.command = command
    }
}

public typealias ProviderProcessList = @Sendable () throws -> [ProviderRuntimeProcess]

/// One process-table read produced by the ownership sweep and then consumed as
/// an immutable diagnostics snapshot. Telemetry waits so it can never make the
/// sweep act on rows that were captured earlier by a delayed consumer.
public final class ProviderProcessListSnapshot: @unchecked Sendable {
    private enum State {
        case pending
        case loading
        case finished(Result<[ProviderRuntimeProcess], Error>)
    }

    private let condition = NSCondition()
    private let loader: ProviderProcessList
    private var state: State = .pending

    public init(
        loader: @escaping ProviderProcessList = { try ProviderProcessSweeper.psRowsThrowing() }
    ) {
        self.loader = loader
    }

    public func rows() throws -> [ProviderRuntimeProcess] {
        condition.lock()
        while true {
            switch state {
            case .pending:
                state = .loading
                condition.unlock()
                let result = Result { try loader() }
                condition.lock()
                state = .finished(result)
                condition.broadcast()
                condition.unlock()
                return try result.get()
            case .loading:
                condition.wait()
            case .finished(let result):
                condition.unlock()
                return try result.get()
            }
        }
    }

    /// Waits for the sweep-owned first read. A failed first read is retried once
    /// for telemetry, preserving the two independent chances from the old path.
    public func rowsAfterSweepLoad() throws -> [ProviderRuntimeProcess] {
        condition.lock()
        while true {
            switch state {
            case .pending, .loading:
                condition.wait()
            case .finished(let result):
                condition.unlock()
                do {
                    return try result.get()
                } catch {
                    return try loader()
                }
            }
        }
    }
}

public struct ManagedProcessScan: Sendable, Equatable {
    public let providerProcesses: [ProviderRuntimeProcess]
    public let sidecarProcesses: [ProviderRuntimeProcess]
    public let providerRootCount: Int
    public let sidecarRootCount: Int
    public let isComplete: Bool
    public let incompleteRootPIDs: [Int32]

    public init(
        providerProcesses: [ProviderRuntimeProcess],
        sidecarProcesses: [ProviderRuntimeProcess],
        providerRootCount: Int,
        sidecarRootCount: Int,
        isComplete: Bool,
        incompleteRootPIDs: [Int32]
    ) {
        self.providerProcesses = providerProcesses
        self.sidecarProcesses = sidecarProcesses
        self.providerRootCount = providerRootCount
        self.sidecarRootCount = sidecarRootCount
        self.isComplete = isComplete
        self.incompleteRootPIDs = incompleteRootPIDs
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

    /// Shared binary-name gate (server + mcp). public for pure unit tests of the
    /// single-server policy without process-table noise.
    public static func isRemoteCodeDistillService(_ command: String) -> Bool {
        guard let executable = command.split(maxSplits: 1, whereSeparator: \.isWhitespace).first else {
            return false
        }
        let name = (String(executable) as NSString).lastPathComponent
        return name == "RemoteCodeDistillService"
    }

    /// Builds one process-accounting snapshot exclusively from durable spawn
    /// ownership. Command text can corroborate the exact root executable, but it
    /// never grants ownership on its own.
    public static func managedProcessScan(
        tags: [SpawnedProcessTag],
        processes: [ProviderRuntimeProcess],
        processStartIdentity: (pid_t) -> ProviderProcessStartIdentity?
    ) -> ManagedProcessScan {
        let rowsByPID = Dictionary(grouping: processes, by: \.pid)
        var providerByPID: [pid_t: ProviderRuntimeProcess] = [:]
        var sidecarByPID: [pid_t: ProviderRuntimeProcess] = [:]
        var providerRoots = 0
        var sidecarRoots = 0
        var incomplete: [pid_t] = []

        for tag in tags.sorted(by: { $0.pgid < $1.pgid }) {
            let kind = tag.managedKind ?? (tag.provider == nil ? nil : .provider)
            guard let kind else {
                incomplete.append(tag.pgid)
                continue
            }

            // Owner-anchored run-as-user rows (`foreignUserLaunch`) legitimately
            // have no child start identity: a non-root parent cannot read a root
            // `sudo` child's kernel metadata (EPERM). They must never poison scan
            // completeness — one run-as-user turn otherwise blocks EVERY later
            // provider admission with processAccountingUnavailable until the row
            // ages out. Account them fail-safe instead: a live root PID and its
            // ppid-descendants are counted (PID reuse can only overcount memory;
            // the row is never signalled from a scan), an exited root counts 0.
            if tag.startIdentity == nil {
                guard rowsByPID[tag.pgid] != nil else { continue }
                let treePIDs = Set([tag.pgid] + descendants(of: tag.pgid, in: processes))
                let tree = processes.filter { treePIDs.contains($0.pid) }
                switch kind {
                case .provider:
                    providerRoots += 1
                    for row in tree { providerByPID[row.pid] = row }
                case .sidecar, .graphify:
                    // Graphify CLI children account under sidecar tree RSS.
                    sidecarRoots += 1
                    for row in tree { sidecarByPID[row.pid] = row }
                }
                continue
            }

            guard let expectedIdentity = tag.startIdentity,
                  tag.isolatedProcessGroup == tag.pgid,
                  !tag.executablePath.isEmpty else {
                incomplete.append(tag.pgid)
                continue
            }

            let root = rowsByPID[tag.pgid]?.first
            if root != nil {
                guard let liveIdentity = processStartIdentity(tag.pgid) else {
                    incomplete.append(tag.pgid)
                    continue
                }
                // A reused PID exhausts this old tag; it does not make the new
                // unrelated process managed and is never counted or signalled.
                guard liveIdentity == expectedIdentity else { continue }
                // Identity already certifies the exact process lifetime. Executable
                // path is corroboration only: shebang launchers (`#!/usr/bin/env node`,
                // npm shims, etc.) re-exec in-place so `ps` shows `node …` while the
                // ledger still holds `/usr/bin/env` or the original script path.
                // Treating that drift as incomplete blocked EVERY later provider
                // admission with processAccountingUnavailable on any Mac that runs
                // Codex/Homebrew-style CLI scripts — never fail-closed the host for
                // path drift when the kernel start identity still matches.
            }

            var tree = processes.filter { $0.pgid == tag.pgid }
            if tree.isEmpty, root != nil {
                let treePIDs = Set([tag.pgid] + descendants(of: tag.pgid, in: processes))
                tree = processes.filter { treePIDs.contains($0.pid) }
            }
            // No exact root and no surviving member of its certified process
            // group means this lifetime is gone; a stale ledger row contributes 0.
            guard !tree.isEmpty else { continue }

            switch kind {
            case .provider:
                providerRoots += 1
                for row in tree { providerByPID[row.pid] = row }
            case .sidecar, .graphify:
                sidecarRoots += 1
                for row in tree { sidecarByPID[row.pid] = row }
            }
        }

        return ManagedProcessScan(
            providerProcesses: providerByPID.values.sorted { $0.pid < $1.pid },
            sidecarProcesses: sidecarByPID.values.sorted { $0.pid < $1.pid },
            providerRootCount: providerRoots,
            sidecarRootCount: sidecarRoots,
            isComplete: incomplete.isEmpty,
            incompleteRootPIDs: incomplete.sorted()
        )
    }

    public static func managedProcessScan(
        store: ProviderProcessOwnershipStore,
        processList: () throws -> [ProviderRuntimeProcess] = psRowsThrowing,
        processStartIdentity: (pid_t) -> ProviderProcessStartIdentity? = {
            ProviderProcessStartIdentity.read(pid: $0)
        }
    ) throws -> ManagedProcessScan {
        let tags = try store.load()
        let processes = try processList()
        return managedProcessScan(
            tags: tags,
            processes: processes,
            processStartIdentity: processStartIdentity
        )
    }

    public static func psRowsThrowing() throws -> [ProviderRuntimeProcess] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,pgid=,rss=,command="]
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
    /// A tag is reapable only while the kernel start identity still matches the
    /// recorded lifetime and it is old enough. The production path uses the
    /// stronger persisted-owner sweep; this pure helper cannot signal by PID age
    /// alone.
    @discardableResult
    public static func sweepTaggedOrphans(
        tags: [SpawnedProcessTag],
        minAge: TimeInterval = ProcessSpawnTagger.defaultMinAge,
        isAlive: (pid_t) -> Bool,
        processStartIdentity: (pid_t) -> ProviderProcessStartIdentity?,
        now: Date = Date(),
        terminate: (pid_t) -> Bool
    ) -> ProviderProcessSweepResult {
        var orphanRoots: [Int32] = []
        var terminated: [Int32] = []
        var failed: [Int32] = []
        for tag in tags.sorted(by: { $0.pgid < $1.pgid }) {
            guard let expectedIdentity = tag.startIdentity,
                  processStartIdentity(tag.pgid) == expectedIdentity else { continue }
            guard ProcessSpawnTagger.isEligibleForReap(
                pgid: tag.pgid,
                spawnedAt: tag.spawnedAt,
                minAge: minAge,
                isAlive: isAlive,
                now: now
            ) else { continue }
            orphanRoots.append(tag.pgid)
            if processStartIdentity(tag.pgid) == expectedIdentity,
               terminate(tag.pgid) {
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
        let parts = trimmed.split(maxSplits: 4, whereSeparator: \.isWhitespace)
        guard parts.count == 5,
              let pid = Int32(parts[0]),
              let ppid = Int32(parts[1]),
              let pgid = Int32(parts[2]),
              let rssKB = Int(parts[3]) else {
            return nil
        }
        return ProviderRuntimeProcess(pid: pid, ppid: ppid, pgid: pgid, rssKB: rssKB, command: String(parts[4]))
    }

    /// Corroborates a live `ps` command against the ownership ledger path.
    /// Intentionally unused by completeness gates: shebang re-exec makes path
    /// drift common while the kernel start identity still certifies the lifetime.
    /// Kept for focused matching tests and future soft telemetry.
    static func managedExecutableMatches(command: String, expectedPath: String) -> Bool {
        guard !expectedPath.isEmpty else { return false }
        if command == expectedPath || command.hasPrefix(expectedPath + " ") { return true }
        guard let commandPath = command.split(separator: " ", maxSplits: 1).first else { return false }
        if !commandPath.contains("/") {
            return URL(fileURLWithPath: expectedPath).lastPathComponent == commandPath
        }
        let expectedResolved = URL(fileURLWithPath: expectedPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let commandResolved = URL(fileURLWithPath: String(commandPath))
            .resolvingSymlinksInPath().standardizedFileURL.path
        return commandResolved == expectedResolved
    }
}
