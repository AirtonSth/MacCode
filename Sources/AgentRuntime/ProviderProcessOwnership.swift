import Foundation
import Darwin

public enum ProviderProcessOwnershipError: Error, LocalizedError, Equatable {
    case storeNotConfigured
    case startIdentityUnavailable(pid_t)
    case executablePathUnavailable(pid_t)
    case isolatedProcessGroupUnavailable(pid_t)
    case processListFailed(String)
    case ownershipLedgerCapacityExceeded(Int)

    public var errorDescription: String? {
        switch self {
        case .storeNotConfigured:
            return "Provider process ownership store is not configured."
        case .startIdentityUnavailable(let pid):
            return "Could not identify provider process lifetime for pid \(pid)."
        case .executablePathUnavailable(let pid):
            return "Could not identify provider process executable for pid \(pid)."
        case .isolatedProcessGroupUnavailable(let pid):
            return "Could not certify an isolated provider process group for pid \(pid)."
        case .processListFailed(let reason):
            return "Could not list provider processes: \(reason)"
        case .ownershipLedgerCapacityExceeded(let limit):
            return "Managed process ownership ledger reached its \(limit)-record safety limit."
        }
    }
}

public enum ProviderProcessExecutablePath {
    public static func read(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}

public final class ProviderProcessOwnershipStore: @unchecked Sendable {
    public static let defaultMaxRecords = 256
    public let fileURL: URL
    public let maxRecords: Int
    private let lock = NSLock()

    public init(fileURL: URL, maxRecords: Int = defaultMaxRecords) {
        self.fileURL = fileURL
        self.maxRecords = max(1, maxRecords)
    }

    public func load() throws -> [SpawnedProcessTag] {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    public func replace(_ tags: [SpawnedProcessTag]) throws {
        lock.lock()
        defer { lock.unlock() }
        try replaceUnlocked(tags)
    }

    public func append(_ tag: SpawnedProcessTag) throws {
        lock.lock()
        defer { lock.unlock() }
        // A corrupt/unreadable ledger is evidence, not an empty ledger. Never
        // overwrite it while appending a newly spawned provider.
        let existing = try loadUnlocked()
        let next = existing.filter { $0.pgid != tag.pgid } + [tag]
        guard next.count <= maxRecords else {
            throw ProviderProcessOwnershipError.ownershipLedgerCapacityExceeded(maxRecords)
        }
        try replaceUnlocked(next)
    }

    /// Remove only the exact process lifetime supplied by its owner. A reused
    /// PID or concurrently appended replacement row is preserved.
    public func removeExact(_ tag: SpawnedProcessTag) throws {
        lock.lock()
        defer { lock.unlock() }
        let current = try loadUnlocked()
        try replaceUnlocked(current.filter { $0 != tag })
    }

    /// Commit decisions made from one sweep snapshot without erasing process
    /// tags recorded while the sweep was signalling and waiting. An exact tag
    /// from `snapshot` follows the sweep decision; additions and a new process
    /// lifetime that reused the same PID are preserved.
    func commitSweep(snapshot: [SpawnedProcessTag], retainedFromSnapshot: [SpawnedProcessTag]) throws {
        lock.lock()
        defer { lock.unlock() }
        let current = try loadUnlocked()
        var snapshotByPID: [pid_t: SpawnedProcessTag] = [:]
        for tag in snapshot { snapshotByPID[tag.pgid] = tag }
        let next = current.filter { currentTag in
            guard let snapshotTag = snapshotByPID[currentTag.pgid] else {
                return true
            }
            guard currentTag == snapshotTag else {
                return true
            }
            return retainedFromSnapshot.contains(currentTag)
        }
        try replaceUnlocked(next)
    }

    private func loadUnlocked() throws -> [SpawnedProcessTag] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([SpawnedProcessTag].self, from: Data(contentsOf: fileURL))
    }

    private func replaceUnlocked(_ tags: [SpawnedProcessTag]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(tags).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public final class ProviderProcessOwnership: @unchecked Sendable {
    public static let shared = ProviderProcessOwnership()
    private let lock = NSLock()
    private var configuredStore: ProviderProcessOwnershipStore?

    init() {}

    public func configure(fileURL: URL) {
        lock.lock()
        configuredStore = ProviderProcessOwnershipStore(fileURL: fileURL)
        lock.unlock()
    }

    public func record(_ tag: SpawnedProcessTag) throws {
        lock.lock()
        let store = configuredStore
        lock.unlock()
        guard let store else {
            throw ProviderProcessOwnershipError.storeNotConfigured
        }
        try store.append(tag)
    }

    public func store() -> ProviderProcessOwnershipStore? {
        lock.lock()
        defer { lock.unlock() }
        return configuredStore
    }
}

public extension ProviderProcessSweeper {
    @discardableResult
    static func sweepPersistedOrphans(
        store: ProviderProcessOwnershipStore,
        currentPID: pid_t,
        minAge: TimeInterval = ProcessSpawnTagger.defaultMinAge,
        now: Date = Date(),
        ownerIsAlive: (pid_t) -> Bool,
        ownerStartIdentity: (pid_t) -> ProviderProcessStartIdentity? = {
            ProviderProcessStartIdentity.read(pid: $0)
        },
        processCommand: (pid_t) -> String?,
        processStartIdentity: (pid_t) -> ProviderProcessStartIdentity?,
        descendantPIDs: (pid_t) -> [pid_t],
        processGroupMembers: (pid_t) -> [pid_t] = { _ in [] },
        processIsAlive: (pid_t) -> Bool,
        graceInterval: TimeInterval,
        wait: (TimeInterval) -> Void,
        sendSignal: (pid_t, Int32) -> Bool
    ) throws -> ProviderProcessSweepResult {
        let tags = try store.load().sorted { $0.pgid < $1.pgid }
        var retained: [SpawnedProcessTag] = []
        var roots: [Int32] = []
        var terminated: [Int32] = []
        var failed: [Int32] = []

        for tag in tags {
            let rootIsAlive = processIsAlive(tag.pgid)
            let hasVerifiedGroupIdentity = tag.isolatedProcessGroup == tag.pgid
                && tag.startIdentity != nil
            let groupMembers = hasVerifiedGroupIdentity
                ? processGroupMembers(tag.pgid).filter { $0 > 0 && $0 != currentPID }
                : []

            if tag.ownerPID == currentPID,
               let expectedOwnerIdentity = tag.ownerStartIdentity,
               ownerStartIdentity(currentPID) == expectedOwnerIdentity {
                if rootIsAlive {
                    // Keep only the exact recorded root lifetime. A recycled PID
                    // exhausts this row and must not inherit its ownership.
                    if tag.startIdentity == nil
                        || processStartIdentity(tag.pgid) == tag.startIdentity {
                        retained.append(tag)
                    }
                } else if !groupMembers.isEmpty {
                    // The root exited, but its certified group still has late
                    // descendants. Retain ownership until the group drains.
                    retained.append(tag)
                }
                continue
            } else if tag.ownerPID == currentPID && tag.ownerStartIdentity == nil {
                // Legacy current-owner rows cannot be tied to this app lifetime.
                // Preserve them rather than erasing the only cleanup evidence.
                retained.append(tag)
                continue
            }
            if ownerIsAlive(tag.ownerPID) {
                // Legacy rows without an owner lifetime remain fail-safe. New
                // rows compare the kernel start time so a recycled owner PID
                // cannot protect an orphan forever.
                guard let expectedOwnerIdentity = tag.ownerStartIdentity,
                      let currentOwnerIdentity = ownerStartIdentity(tag.ownerPID) else {
                    retained.append(tag)
                    continue
                }
                if currentOwnerIdentity == expectedOwnerIdentity {
                    retained.append(tag)
                    continue
                }
            }
            if rootIsAlive {
                guard let command = processCommand(tag.pgid) else {
                    failed.append(tag.pgid)
                    retained.append(tag)
                    continue
                }
                guard let expectedStartIdentity = tag.startIdentity else {
                    failed.append(tag.pgid)
                    retained.append(tag)
                    continue
                }
                guard let currentStartIdentity = processStartIdentity(tag.pgid) else {
                    failed.append(tag.pgid)
                    retained.append(tag)
                    continue
                }
                guard currentStartIdentity == expectedStartIdentity else { continue }
                guard executableMatches(command: command, expectedPath: tag.executablePath) else {
                    // The PID still identifies the exact recorded lifetime, but its
                    // executable cannot be verified. Never signal it and never erase
                    // the only evidence required for a later retry.
                    failed.append(tag.pgid)
                    retained.append(tag)
                    continue
                }
            } else if groupMembers.isEmpty {
                // The exact root lifetime and its verified group are both gone.
                // The ownership row is now exhausted and may be removed.
                continue
            }
            guard now.timeIntervalSince(tag.spawnedAt) >= minAge else {
                retained.append(tag)
                continue
            }
            roots.append(tag.pgid)

            var seen = Set<pid_t>()
            let rootTargets = rootIsAlive ? [tag.pgid] : []
            let targets = (
                Array(descendantPIDs(tag.pgid).reversed())
                    + Array(groupMembers.reversed())
                    + rootTargets
            ).filter {
                seen.insert($0).inserted
            }
            var identities: [(pid: pid_t, identity: ProviderProcessStartIdentity)] = []
            var unidentifiedLivePIDs: [pid_t] = []
            for pid in targets {
                if let identity = processStartIdentity(pid) {
                    identities.append((pid, identity))
                } else if processIsAlive(pid) {
                    unidentifiedLivePIDs.append(pid)
                }
            }

            for target in identities where processStartIdentity(target.pid) == target.identity {
                _ = sendSignal(target.pid, SIGTERM)
            }
            wait(max(0, graceInterval))

            let termSurvivors = identities.filter {
                originalIdentityMayStillBeAlive(
                    pid: $0.pid,
                    expected: $0.identity,
                    processStartIdentity: processStartIdentity,
                    processIsAlive: processIsAlive
                )
            }
            for target in termSurvivors where processStartIdentity(target.pid) == target.identity {
                _ = sendSignal(target.pid, SIGKILL)
            }
            wait(max(0, graceInterval))

            let survivors = identities.filter {
                originalIdentityMayStillBeAlive(
                    pid: $0.pid,
                    expected: $0.identity,
                    processStartIdentity: processStartIdentity,
                    processIsAlive: processIsAlive
                )
            }
            let unidentifiedSurvivors = unidentifiedLivePIDs.filter(processIsAlive)
            if survivors.isEmpty && unidentifiedSurvivors.isEmpty {
                terminated.append(tag.pgid)
            } else {
                failed.append(tag.pgid)
                retained.append(tag)
            }
        }
        try store.commitSweep(snapshot: tags, retainedFromSnapshot: retained)
        return ProviderProcessSweepResult(orphanRootPIDs: roots, terminatedPIDs: terminated, failedPIDs: failed)
    }

    @discardableResult
    static func terminatePersistedOrphanedProviderRuntimes(
        currentPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        minAge: TimeInterval = ProcessSpawnTagger.defaultMinAge,
        store explicitStore: ProviderProcessOwnershipStore? = nil,
        processList: () throws -> [ProviderRuntimeProcess] = ProviderProcessSweeper.psRowsThrowing
    ) throws -> ProviderProcessSweepResult {
        guard let store = explicitStore ?? ProviderProcessOwnership.shared.store() else {
            return ProviderProcessSweepResult(orphanRootPIDs: [], terminatedPIDs: [], failedPIDs: [])
        }
        let processes = try processList()
        let commandByPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0.command) })
        return try sweepPersistedOrphans(
            store: store,
            currentPID: currentPID,
            minAge: minAge,
            ownerIsAlive: { pid in Darwin.kill(pid, 0) == 0 || errno == EPERM },
            ownerStartIdentity: { ProviderProcessStartIdentity.read(pid: $0) },
            processCommand: { commandByPID[$0] },
            processStartIdentity: { ProviderProcessStartIdentity.read(pid: $0) },
            descendantPIDs: { Array(descendants(of: $0, in: processes)) },
            processGroupMembers: ProcessTerminator.processGroupPIDs,
            processIsAlive: ProcessTerminator.isAlive,
            graceInterval: 0.25,
            wait: Thread.sleep(forTimeInterval:),
            sendSignal: { pid, signal in Darwin.kill(pid, signal) == 0 || errno == ESRCH }
        )
    }

    private static func executableMatches(command: String, expectedPath: String) -> Bool {
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

    private static func originalIdentityMayStillBeAlive(
        pid: pid_t,
        expected: ProviderProcessStartIdentity,
        processStartIdentity: (pid_t) -> ProviderProcessStartIdentity?,
        processIsAlive: (pid_t) -> Bool
    ) -> Bool {
        if let current = processStartIdentity(pid) {
            return current == expected
        }
        return processIsAlive(pid)
    }
}
