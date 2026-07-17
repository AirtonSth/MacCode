import Foundation
import Persistence

@MainActor
protocol TerminalHistoryCoordinatorDelegate: AnyObject {
    var terminalHistoryIsClosing: Bool { get }

    func terminalHistoryCoordinator(
        _ coordinator: TerminalHistoryCoordinator,
        didEncounter issue: TerminalHistoryCoordinator.Issue
    )
    func terminalHistoryCoordinator(
        _ coordinator: TerminalHistoryCoordinator,
        didPrepareReplay data: Data
    )
}

public enum TerminalHistoryReadError: Error {
    case unavailable
    case busy
    case timedOut
}

private final class TerminalHistoryBarrierState: @unchecked Sendable {
    let group = DispatchGroup()
    private let lock = NSLock()
    private var completed = false
    private var successful = false

    init() {
        group.enter()
    }

    func complete(success: Bool) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        successful = success
        lock.unlock()
        group.leave()
    }

    func succeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed && successful
    }

    func surfaceBarrier() -> SurfaceTerminationBarrier {
        SurfaceTerminationBarrier(
            groups: [group],
            completionChecks: [{ [self] in succeeded() }]
        )
    }
}

/// Final deletes can outlive their tab because the router unregisters the
/// surface immediately. Retain only bounded disposition state, never the
/// coordinator or surface, so application termination can still join it.
private final class TerminalHistoryPendingDeleteRegistry: @unchecked Sendable {
    static let shared = TerminalHistoryPendingDeleteRegistry()

    private struct Key: Hashable {
        let id: String
    }

    private final class Entry: @unchecked Sendable {
        let key: Key
        let repository: TerminalOutputRepository
        let pendingDelete: TerminalHistoryPendingDelete
        let queue: DispatchQueue
        let isRetryable: (Error) -> Bool
        let retryTimeout: TimeInterval
        var state = TerminalHistoryBarrierState()
        var isRunning = false

        init(
            key: Key,
            repository: TerminalOutputRepository,
            pendingDelete: TerminalHistoryPendingDelete,
            queue: DispatchQueue,
            retryTimeout: TimeInterval,
            isRetryable: @escaping (Error) -> Bool
        ) {
            self.key = key
            self.repository = repository
            self.pendingDelete = pendingDelete
            self.queue = queue
            self.retryTimeout = retryTimeout
            self.isRetryable = isRetryable
        }
    }

    private final class Source: @unchecked Sendable {
        let repository: TerminalOutputRepository
        let replayQueue: DispatchQueue
        let isRetryable: (Error) -> Bool
        let retryTimeout: TimeInterval

        init(
            repository: TerminalOutputRepository,
            replayQueue: DispatchQueue,
            retryTimeout: TimeInterval,
            isRetryable: @escaping (Error) -> Bool
        ) {
            self.repository = repository
            self.replayQueue = replayQueue
            self.retryTimeout = retryTimeout
            self.isRetryable = isRetryable
        }
    }

    private static let maximumEntries = 512
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var sources: [ObjectIdentifier: Source] = [:]
    private var drainState: TerminalHistoryBarrierState?
    private var pumpScheduled = false
    private var beforeAttemptForTesting: (@Sendable () -> Void)?
    private let managementQueue = DispatchQueue(
        label: "rc2.terminal.history.pending-delete-registry",
        qos: .utility
    )

    /// Registers one durable disposition. The cap bounds resident workers, not
    /// ownership: overflow remains in the metadata-only ledger and is admitted
    /// when a slot opens.
    @discardableResult
    func register(
        repository: TerminalOutputRepository,
        pendingDelete: TerminalHistoryPendingDelete,
        queue: DispatchQueue,
        replayQueue: DispatchQueue,
        retryTimeout: TimeInterval,
        isRetryable: @escaping (Error) -> Bool
    ) -> SurfaceTerminationBarrier {
        let key = Key(id: pendingDelete.id)
        lock.lock()
        sources[ObjectIdentifier(repository)] = Source(
            repository: repository,
            replayQueue: replayQueue,
            retryTimeout: retryTimeout,
            isRetryable: isRetryable
        )
        let drain = activeDrainStateLocked()
        if let existing = entries[key] {
            let launch = prepareAttemptIfNeeded(existing)
            lock.unlock()
            launch?()
            return drain.surfaceBarrier()
        }
        let launch: (() -> Void)?
        if entries.count < Self.maximumEntries {
            let entry = Entry(
                key: key,
                repository: repository,
                pendingDelete: pendingDelete,
                queue: queue,
                retryTimeout: retryTimeout,
                isRetryable: isRetryable
            )
            entries[key] = entry
            launch = prepareAttemptIfNeeded(entry)
        } else {
            launch = nil
        }
        lock.unlock()
        launch?()
        if launch == nil { schedulePump() }
        return drain.surfaceBarrier()
    }

    @discardableResult
    func replay(
        repository: TerminalOutputRepository,
        queue: DispatchQueue,
        retryTimeout: TimeInterval,
        isRetryable: @escaping (Error) -> Bool
    ) -> SurfaceTerminationBarrier? {
        do {
            guard !(try repository.pendingDeletes()).isEmpty else { return nil }
        } catch {
            NSLog(
                "RemoteCode terminal history pending delete replay scan failed error=%@",
                String(describing: error)
            )
        }
        lock.lock()
        sources[ObjectIdentifier(repository)] = Source(
            repository: repository,
            replayQueue: queue,
            retryTimeout: retryTimeout,
            isRetryable: isRetryable
        )
        let drain = activeDrainStateLocked()
        lock.unlock()
        schedulePump()
        return drain.surfaceBarrier()
    }

    func snapshot() -> SurfaceTerminationBarrier? {
        lock.lock()
        guard !entries.isEmpty || !sources.isEmpty else {
            lock.unlock()
            return nil
        }
        var launches: [() -> Void] = []
        for entry in entries.values {
            if let launch = prepareAttemptIfNeeded(entry) {
                launches.append(launch)
            }
        }
        let drain = activeDrainStateLocked()
        lock.unlock()
        launches.forEach { $0() }
        schedulePump()
        return drain.surfaceBarrier()
    }

    func resetForTesting() {
        lock.lock()
        precondition(
            entries.values.allSatisfy { !$0.isRunning },
            "pending delete attempts must be quiescent before simulating process exit"
        )
        entries.removeAll(keepingCapacity: false)
        sources.removeAll(keepingCapacity: false)
        drainState?.complete(success: false)
        drainState = nil
        lock.unlock()
    }

    func setBeforeAttemptForTesting(_ hook: (@Sendable () -> Void)?) {
        lock.lock()
        beforeAttemptForTesting = hook
        lock.unlock()
    }

    private func activeDrainStateLocked() -> TerminalHistoryBarrierState {
        if let drainState { return drainState }
        let state = TerminalHistoryBarrierState()
        drainState = state
        return state
    }

    /// Must be called with `lock` held. The returned closure starts work only
    /// after the caller releases the registry lock.
    private func prepareAttemptIfNeeded(_ entry: Entry) -> (() -> Void)? {
        guard !entry.isRunning else { return nil }
        entry.state = TerminalHistoryBarrierState()
        entry.isRunning = true
        let state = entry.state
        return { [self, entry, state] in
            entry.queue.async { [self, entry, state] in
                runAttempt(entry, state: state)
            }
        }
    }

    private func runAttempt(_ entry: Entry, state: TerminalHistoryBarrierState) {
        lock.lock()
        let beforeAttemptForTesting = beforeAttemptForTesting
        lock.unlock()
        beforeAttemptForTesting?()
        let deadline = Date().addingTimeInterval(max(0, entry.retryTimeout))
        var succeeded = false
        var finalError: Error?
        repeat {
            do {
                try entry.repository.performPendingDelete(entry.pendingDelete)
                if let generation = entry.pendingDelete.expectedWriterGeneration {
                    TerminalHistoryUnresolvedFailureRegistry.shared.resolve(
                        surfaceID: entry.pendingDelete.surfaceID,
                        writerGeneration: generation
                    )
                } else {
                    TerminalHistoryUnresolvedFailureRegistry.shared.resolveAll(
                        surfaceID: entry.pendingDelete.surfaceID
                    )
                }
                succeeded = true
                break
            } catch {
                finalError = error
                guard entry.isRetryable(error), Date() < deadline else { break }
                Thread.sleep(forTimeInterval: 0.025)
            }
        } while Date() < deadline

        lock.lock()
        if entries[entry.key] === entry {
            if succeeded {
                entries.removeValue(forKey: entry.key)
            } else {
                entry.isRunning = false
            }
        }
        lock.unlock()

        if !succeeded, let finalError {
            NSLog(
                "RemoteCode terminal history final delete failed surface=%@ error=%@",
                entry.pendingDelete.surfaceID,
                String(describing: finalError)
            )
        }
        state.complete(success: succeeded)
        schedulePump()
    }

    private func schedulePump() {
        lock.lock()
        guard !pumpScheduled else {
            lock.unlock()
            return
        }
        pumpScheduled = true
        lock.unlock()
        managementQueue.async { [self] in pumpDurableOverflow() }
    }

    private func pumpDurableOverflow() {
        lock.lock()
        let sourceSnapshot = Array(sources.values)
        lock.unlock()

        var loaded: [(Source, [TerminalHistoryPendingDelete])] = []
        var scanFailed = false
        for source in sourceSnapshot {
            do {
                loaded.append((source, try source.repository.pendingDeletes()))
            } catch {
                scanFailed = true
                NSLog(
                    "RemoteCode terminal history pending delete replay scan failed error=%@",
                    String(describing: error)
                )
            }
        }

        lock.lock()
        var launches: [() -> Void] = []
        var remainingDurable = false
        for (source, pendingDeletes) in loaded {
            for pendingDelete in pendingDeletes {
                let key = Key(id: pendingDelete.id)
                if entries[key] != nil {
                    remainingDurable = true
                    continue
                }
                guard entries.count < Self.maximumEntries else {
                    remainingDurable = true
                    continue
                }
                let entry = Entry(
                    key: key,
                    repository: source.repository,
                    pendingDelete: pendingDelete,
                    queue: source.replayQueue,
                    retryTimeout: source.retryTimeout,
                    isRetryable: source.isRetryable
                )
                entries[key] = entry
                remainingDurable = true
                if let launch = prepareAttemptIfNeeded(entry) {
                    launches.append(launch)
                }
            }
        }
        if !scanFailed, !remainingDurable, entries.isEmpty {
            let completedDrain = drainState
            drainState = nil
            sources.removeAll(keepingCapacity: false)
            completedDrain?.complete(success: true)
        }
        pumpScheduled = false
        lock.unlock()
        launches.forEach { $0() }
    }
}

private final class TerminalHistoryReadOperation: @unchecked Sendable {
    let group = DispatchGroup()
    private let lock = NSLock()
    private var result: Result<TerminalOutputWindow, Error>?

    init() {
        group.enter()
    }

    func complete(_ result: Result<TerminalOutputWindow, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        lock.unlock()
        group.leave()
    }

    func value(timeout: TimeInterval) async throws -> TerminalOutputWindow {
        let timeout = max(0, timeout)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                guard group.wait(timeout: .now() + timeout) == .success else {
                    continuation.resume(throwing: TerminalHistoryReadError.timedOut)
                    return
                }
                lock.lock()
                let result = self.result
                lock.unlock()
                continuation.resume(with: result ?? .failure(TerminalHistoryReadError.unavailable))
            }
        }
    }
}

private final class TerminalHistoryQueueState: @unchecked Sendable {
    private let condition = NSCondition()
    private var failureGeneration: UInt64 = 0
    private var durablePartial = false
    private var retentionMaintenanceScheduled = false
    private var retryDeadline = Date.distantFuture
    private var retriesCancelled = false

    func recordFailure() {
        condition.lock()
        failureGeneration &+= 1
        condition.unlock()
    }

    func currentFailureGeneration() -> UInt64 {
        condition.lock()
        defer { condition.unlock() }
        return failureGeneration
    }

    func recordDurablePartial() {
        condition.lock()
        durablePartial = true
        condition.unlock()
    }

    func hasDurablePartial() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return durablePartial
    }

    func resetAfterAcknowledgedClear() {
        condition.lock()
        failureGeneration = 0
        durablePartial = false
        retentionMaintenanceScheduled = false
        retryDeadline = .distantFuture
        retriesCancelled = false
        condition.broadcast()
        condition.unlock()
    }

    func beginRetentionMaintenanceIfNeeded() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !retriesCancelled, !retentionMaintenanceScheduled else { return false }
        retentionMaintenanceScheduled = true
        return true
    }

    func finishRetentionMaintenance() {
        condition.lock()
        retentionMaintenanceScheduled = false
        condition.unlock()
    }

    func shortenRetryDeadline(to deadline: Date) {
        condition.lock()
        retryDeadline = min(retryDeadline, deadline)
        condition.broadcast()
        condition.unlock()
    }

    func cancelRetries() {
        condition.lock()
        retriesCancelled = true
        retryDeadline = Date.distantPast
        condition.broadcast()
        condition.unlock()
    }

    func retriesAreCancelled() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return retriesCancelled
    }

    func permitsRetry(operationStartedAt: Date, maxDuration: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let operationDeadline = operationStartedAt.addingTimeInterval(maxDuration)
        return !retriesCancelled && Date() < min(retryDeadline, operationDeadline)
    }

    /// Waits without pinning the history queue in an uncancellable sleep. Final
    /// close/delete wakes this condition immediately, releasing any retained
    /// append payload instead of allowing a retry chain to outlive its surface.
    func waitBeforeRetry(
        delay: TimeInterval,
        operationStartedAt: Date,
        maxDuration: TimeInterval
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let operationDeadline = operationStartedAt.addingTimeInterval(maxDuration)
        let deadline = min(retryDeadline, operationDeadline)
        guard !retriesCancelled, Date() < deadline else { return false }
        _ = condition.wait(until: min(Date().addingTimeInterval(delay), deadline))
        return !retriesCancelled && Date() < deadline
    }
}

/// Process-lifetime ownership of a write gap that SQLite could not record while
/// locked. The entry is removed only after the partial marker becomes durable
/// or its writer generation is retired by clear/delete. A replacement
/// coordinator therefore cannot declare the same surface complete meanwhile.
private final class TerminalHistoryUnresolvedFailureRegistry: @unchecked Sendable {
    struct Entry: Equatable, Sendable {
        let writerGeneration: String
        let reason: String
        var minimumNextChunkIndex: Int64
    }

    static let shared = TerminalHistoryUnresolvedFailureRegistry()

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var retryGenerationBySurface: [String: String] = [:]

    func record(
        surfaceID: String,
        writerGeneration: String,
        reason: String,
        minimumNextChunkIndex: Int64
    ) {
        lock.lock()
        if var current = entries[surfaceID],
           current.writerGeneration == writerGeneration {
            current.minimumNextChunkIndex = max(
                current.minimumNextChunkIndex,
                minimumNextChunkIndex
            )
            entries[surfaceID] = current
        } else {
            entries[surfaceID] = Entry(
                writerGeneration: writerGeneration,
                reason: reason,
                minimumNextChunkIndex: minimumNextChunkIndex
            )
        }
        lock.unlock()
    }

    func beginRetry(surfaceID: String, writerGeneration: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard entries[surfaceID]?.writerGeneration == writerGeneration else { return false }
        guard retryGenerationBySurface[surfaceID] != writerGeneration else { return false }
        retryGenerationBySurface[surfaceID] = writerGeneration
        return true
    }

    func entry(surfaceID: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[surfaceID]
    }

    func resolve(surfaceID: String, writerGeneration: String) {
        lock.lock()
        if entries[surfaceID]?.writerGeneration == writerGeneration {
            entries.removeValue(forKey: surfaceID)
            if retryGenerationBySurface[surfaceID] == writerGeneration {
                retryGenerationBySurface.removeValue(forKey: surfaceID)
            }
        }
        lock.unlock()
    }

    func resolveAll(surfaceID: String) {
        lock.lock()
        entries.removeValue(forKey: surfaceID)
        retryGenerationBySurface.removeValue(forKey: surfaceID)
        lock.unlock()
    }

    func stopRetry(surfaceID: String, writerGeneration: String) {
        lock.lock()
        if entries[surfaceID]?.writerGeneration == writerGeneration {
            if retryGenerationBySurface[surfaceID] == writerGeneration {
                retryGenerationBySurface.removeValue(forKey: surfaceID)
            }
        }
        lock.unlock()
    }

    func resetForTesting(surfaceID: String) {
        lock.lock()
        entries.removeValue(forKey: surfaceID)
        retryGenerationBySurface.removeValue(forKey: surfaceID)
        lock.unlock()
    }
}

/// Owns persisted terminal history replay, write backlog, and disk retention.
/// Renderer mutations remain on `TerminalSurface`, which receives only the
/// completed canonical replay payload and explicit persistence outcomes.
@MainActor
final class TerminalHistoryCoordinator {
    typealias ReadWindow = @Sendable (String, Int64?) throws -> TerminalOutputWindow
    typealias PrepareIndex = @Sendable (String) throws -> Int64
    typealias PrepareHistory = @Sendable (String) throws -> TerminalHistoryPreparation

    enum Issue {
        case backlogCap(outstandingBytes: Int, incomingBytes: Int)
        case persistenceFailure
        case persistenceRecovered
        case retentionCap
        case retentionMaintenanceFailure
        case retentionMaintenanceRecovered
        case replayReadFailure
        case replayReadRecovered
        case replayLiveCap
        case durablePartial(reason: String)
        case liveClearCompleted(outputIsPartial: Bool)
        case liveClearFailed
        case staleWriterGeneration
    }

    enum PreparationState: Equatable {
        case idle
        case preparing(attempt: Int)
        case failedRetryable(attempt: Int)
        case failed
        case ready(nextChunkIndex: Int64)
    }

    private enum DeferredOperation {
        case read(
            TerminalHistoryReadOperation,
            beforeChunkID: Int64?,
            maxBytes: Int,
            failureGeneration: UInt64
        )
    }

    private nonisolated static let maxChunkBytes = 64 * 1024
    private nonisolated static let maxOutstandingBytes = 4 * 1024 * 1024
    private nonisolated static let finalDeleteRetryTimeout: TimeInterval = 2
    private nonisolated static let maxPersistedBytes = 32 * 1024 * 1024
    private nonisolated static let retentionCheckInterval = 1024 * 1024
    private nonisolated static let prepareRetryDelays: [TimeInterval] = [0.05, 0.1, 0.2, 0.4, 0.8]
    private nonisolated static let maxRetryDuration: TimeInterval = 30
    private nonisolated static let unresolvedFailureRetryQueue = DispatchQueue(
        label: "rc2.terminal.history.unresolved",
        qos: .utility
    )
    private nonisolated static let ownerlessFinalDeleteQueue = DispatchQueue(
        label: "rc2.terminal.history.ownerless-delete",
        qos: .utility,
        attributes: .concurrent
    )

    private let repository: TerminalOutputRepository?
    private let prepareIndex: PrepareIndex?
    private let prepareHistory: PrepareHistory?
    private let readWindow: ReadWindow?
    private let surfaceID: String
    private let workspaceID: String
    private let queue: DispatchQueue
    private let queueState = TerminalHistoryQueueState()

    /// Bytes accepted before the authoritative chunk index is available. This
    /// is intentionally separate from the 64 KiB ready-state accumulator: its
    /// next index does not exist yet, so trying to flush it can neither advance
    /// nor make progress.
    private var preflightData = Data()
    private var pendingData = Data()
    private var backlogOverflowed = false
    private var flushScheduled = false
    private var bytesSinceRetentionCheck = TerminalHistoryCoordinator.retentionCheckInterval
    private var nextChunkIndex: Int64?
    private var preparationState: PreparationState = .idle
    private var deferredOperations: [DeferredOperation] = []
    private var deferredBarrier: (state: TerminalHistoryBarrierState, failureGeneration: UInt64)?
    private var finalBarrier: TerminalHistoryBarrierState?
    private var prepareStartedAt: Date?
    private var activeReadOperation: TerminalHistoryReadOperation?
    private var prepareFailureReported = false
    private var replayPersistedBeforeChunkIndex: Int64?
    private var needsReplay = false
    private var replayLiveData = Data()
    private var replayLiveOverflowed = false
    private var retryMustPreserveLiveView = false
    private var replayReadFailurePending = false
    private var acceptsWrites = true
    private var finalFlushScheduled = false
    private var finalDeleteScheduled = false
    private var finalDeleteEnqueued = false
    private var durablePartialState: TerminalHistoryPartialState?
    private var writerGeneration: String?
    private var liveClearInFlight = false
    private var liveClearRequestedBeforePreparation = false
    private var liveClearBuffer = Data()
    private var liveClearOverflowed = false
    private var liveClearRecoveryPending = false
    private var liveClearBarrier: (state: TerminalHistoryBarrierState, failureGeneration: UInt64)?

    /// Deterministic test seam. It runs on the serial history queue immediately
    /// before the repository reservation, without holding the SQLite lock.
    var beforePersistForTesting: (@Sendable () -> Void)?
    var beforeLiveClearForTesting: (@Sendable () -> Void)?

    weak var delegate: (any TerminalHistoryCoordinatorDelegate)?

    private(set) var outstandingBytes = 0
    private(set) var writeFailures = 0
    private(set) var replayInFlight = false

    var preparationStateForTesting: PreparationState { preparationState }
    var preflightBytesForTesting: Int { preflightData.count }
    var activeReadWorkerCountForTesting: Int { activeReadOperation == nil ? 0 : 1 }
    var deferredBarrierCountForTesting: Int { deferredBarrier == nil ? 0 : 1 }
    var liveClearInFlightForTesting: Bool { liveClearInFlight }
    var liveClearBufferedBytesForTesting: Int { liveClearBuffer.count }
    var liveClearBarrierCountForTesting: Int { liveClearBarrier == nil ? 0 : 1 }
    var writerGenerationForTesting: String? { writerGeneration }

    static func resetUnresolvedFailureMemoryForTesting(surfaceID: String) {
        TerminalHistoryUnresolvedFailureRegistry.shared.resetForTesting(
            surfaceID: surfaceID
        )
    }

    init(
        repository: TerminalOutputRepository?,
        surfaceID: String,
        workspaceID: String,
        prepareIndex: PrepareIndex? = nil,
        readWindow: (@Sendable (String) throws -> TerminalOutputWindow)? = nil
    ) {
        self.repository = repository
        self.prepareIndex = prepareIndex
        if let repository {
            self.prepareHistory = { @Sendable surfaceID in
                try repository.prepareHistory(surfaceID: surfaceID)
            }
        } else {
            self.prepareHistory = nil
        }
        if let readWindow {
            self.readWindow = { surfaceID, _ in try readWindow(surfaceID) }
        } else if let repository {
            self.readWindow = { @Sendable surfaceID, beforeChunkIndex in
                try repository.readWindow(
                    surfaceID: surfaceID,
                    beforeChunkIndex: beforeChunkIndex
                )
            }
        } else {
            self.readWindow = nil
        }
        self.surfaceID = surfaceID
        self.workspaceID = workspaceID
        self.queue = DispatchQueue(label: "rc2.terminal.history", qos: .utility)
    }

    func prepare(restored: Bool) {
        guard case .idle = preparationState else { return }
        needsReplay = restored
        guard repository != nil, prepareHistory != nil else {
            preparationState = .ready(nextChunkIndex: 1)
            nextChunkIndex = 1
            replayPersistedBeforeChunkIndex = restored ? 1 : nil
            return
        }
        preparationState = .preparing(attempt: 0)
        prepareStartedAt = Date()
        schedulePrepareAttempt(0, delay: 0)
    }

    private func schedulePrepareAttempt(_ attempt: Int, delay: TimeInterval) {
        guard let prepareHistory else { return }
        let prepareIndex = prepareIndex
        let repository = repository
        let surfaceID = surfaceID
        let queueState = queueState
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard !queueState.retriesAreCancelled() else { return }
            do {
                let injectedIndex = try prepareIndex?(surfaceID)
                let memoryFailure = TerminalHistoryUnresolvedFailureRegistry.shared.entry(
                    surfaceID: surfaceID
                )
                let durableFailures = try repository?.failureAnchors(
                    surfaceID: surfaceID
                ) ?? []
                var preparation = try prepareHistory(surfaceID)
                if let repository {
                    preparation = try Self.reconcileUnresolvedFailure(
                        repository: repository,
                        surfaceID: surfaceID,
                        preparation: preparation,
                        memoryFailure: memoryFailure,
                        durableFailures: durableFailures
                    )
                }
                let authoritativeIndex = max(
                    injectedIndex ?? preparation.nextChunkIndex,
                    preparation.nextChunkIndex
                )
                let partialState = preparation.partialState
                if partialState != nil {
                    queueState.recordDurablePartial()
                }
                DispatchQueue.main.async { [weak self] in
                    self?.completePrepare(
                        nextChunkIndex: max(
                            authoritativeIndex,
                            partialState?.nextChunkIndex ?? authoritativeIndex
                        ),
                        partialState: partialState,
                        writerGeneration: preparation.writerGeneration
                    )
                }
            } catch {
                NSLog(
                    "RemoteCode terminal history prepare failed surface=%@ attempt=%d error=%@",
                    surfaceID,
                    attempt,
                    String(describing: error)
                )
                DispatchQueue.main.async { [weak self] in
                    self?.completePrepareFailure(attempt: attempt, error: error)
                }
            }
        }
    }

    private func completePrepare(
        nextChunkIndex authoritativeIndex: Int64,
        partialState: TerminalHistoryPartialState?,
        writerGeneration: String
    ) {
        // A final runtime flush stops new enqueues but must still complete the
        // authoritative preflight and persist bytes accepted before close.
        guard !finalDeleteScheduled else { return }
        let recovered = prepareFailureReported
        prepareStartedAt = nil
        preparationState = .ready(nextChunkIndex: authoritativeIndex)
        nextChunkIndex = authoritativeIndex
        self.writerGeneration = writerGeneration
        replayPersistedBeforeChunkIndex = needsReplay ? authoritativeIndex : nil
        durablePartialState = partialState
        if let partialState {
            delegate?.terminalHistoryCoordinator(
                self,
                didEncounter: .durablePartial(reason: partialState.reason)
            )
        }

        if liveClearRequestedBeforePreparation {
            liveClearRequestedBeforePreparation = false
            outstandingBytes = max(0, outstandingBytes - preflightData.count)
            preflightData = Data()
            beginLiveClear(preservingBufferedOutput: true)
            if recovered {
                prepareFailureReported = false
                delegate?.terminalHistoryCoordinator(self, didEncounter: .persistenceRecovered)
            }
            return
        }

        let acceptedBeforeReady = preflightData
        preflightData = Data()
        if !acceptedBeforeReady.isEmpty {
            ingestReadyData(acceptedBeforeReady)
        }
        flushReadyPending()

        let operations = deferredOperations
        deferredOperations.removeAll(keepingCapacity: false)
        let barrier = deferredBarrier
        deferredBarrier = nil
        for operation in operations {
            scheduleDeferredOperation(operation)
        }
        if let barrier {
            scheduleBarrier(
                barrier.state,
                failureGeneration: barrier.failureGeneration,
                cancelRetriesOnCompletion: finalFlushScheduled
            )
        }
        if !finalFlushScheduled {
            replayIfNeeded()
        }
        if recovered {
            prepareFailureReported = false
            delegate?.terminalHistoryCoordinator(self, didEncounter: .persistenceRecovered)
        }
    }

    private func completePrepareFailure(attempt: Int, error: Error) {
        // Finalization rejects new bytes but still owns the accepted preflight
        // and its deferred barrier until prepare either succeeds or fails.
        guard !finalDeleteScheduled else { return }
        let startedAt = prepareStartedAt ?? Date()
        guard Self.isRetryableDatabaseLock(error),
              queueState.permitsRetry(
                operationStartedAt: startedAt,
                maxDuration: Self.maxRetryDuration
              ) else {
            failPreparationPermanently()
            return
        }
        let nextAttempt = attempt + 1
        preparationState = .failedRetryable(attempt: nextAttempt)
        let delays = Self.prepareRetryDelays
        let delay = delays[min(attempt, delays.count - 1)]
        preparationState = .preparing(attempt: nextAttempt)
        schedulePrepareAttempt(nextAttempt, delay: delay)
    }

    private func failPreparationPermanently() {
        preparationState = .failed
        prepareStartedAt = nil
        queueState.cancelRetries()
        if !prepareFailureReported {
            prepareFailureReported = true
            writeFailures += 1
            recordDurablePartial(
                reason: "history_persistence_failed",
                minimumNextChunkIndex: nextChunkIndex ?? 1
            )
            delegate?.terminalHistoryCoordinator(self, didEncounter: .persistenceFailure)
        }
        if let barrier = deferredBarrier {
            barrier.state.complete(success: false)
            deferredBarrier = nil
        }
        for operation in deferredOperations {
            switch operation {
            case .read(let operation, _, _, _):
                operation.complete(.failure(TerminalHistoryReadError.unavailable))
            }
        }
        deferredOperations.removeAll(keepingCapacity: false)
        activeReadOperation = nil
        outstandingBytes = max(0, outstandingBytes - preflightData.count)
        preflightData = Data()
        if liveClearRequestedBeforePreparation {
            outstandingBytes = max(0, outstandingBytes - liveClearBuffer.count)
            liveClearRequestedBeforePreparation = false
            liveClearBuffer = Data()
            liveClearOverflowed = false
        }
    }

    func enqueue(_ data: Data) {
        guard repository != nil, !data.isEmpty else { return }
        if liveClearInFlight
            || liveClearRecoveryPending
            || liveClearRequestedBeforePreparation {
            guard !finalFlushScheduled, !finalDeleteScheduled else { return }
            guard Self.shouldAcceptBacklog(
                queuedBytes: outstandingBytes,
                incomingBytes: data.count,
                maxQueuedBytes: Self.maxOutstandingBytes
            ) else {
                if !liveClearOverflowed {
                    liveClearOverflowed = true
                    backlogOverflowed = true
                    writeFailures += 1
                    queueState.recordFailure()
                    delegate?.terminalHistoryCoordinator(
                        self,
                        didEncounter: .backlogCap(
                            outstandingBytes: outstandingBytes,
                            incomingBytes: data.count
                        )
                    )
                }
                return
            }
            outstandingBytes += data.count
            liveClearBuffer.append(data)
            return
        }
        guard acceptsWrites else { return }
        guard preparationState != .failed else {
            if !backlogOverflowed {
                backlogOverflowed = true
                delegate?.terminalHistoryCoordinator(self, didEncounter: .persistenceFailure)
            }
            return
        }
        guard Self.shouldAcceptBacklog(
            queuedBytes: outstandingBytes,
            incomingBytes: data.count,
            maxQueuedBytes: Self.maxOutstandingBytes
        ) else {
            if !backlogOverflowed {
                backlogOverflowed = true
                writeFailures += 1
                queueState.recordFailure()
                recordDurablePartial(
                    reason: "history_backlog_cap",
                    minimumNextChunkIndex: nextChunkIndex ?? 1
                )
                delegate?.terminalHistoryCoordinator(
                    self,
                    didEncounter: .backlogCap(
                        outstandingBytes: outstandingBytes,
                        incomingBytes: data.count
                    )
                )
            }
            return
        }

        outstandingBytes += data.count
        if case .ready = preparationState {
            ingestReadyData(data)
            if !pendingData.isEmpty {
                scheduleFlush()
            }
        } else {
            preflightData.append(data)
        }
    }

    private func ingestReadyData(_ data: Data) {
        var offset = data.startIndex
        while offset < data.endIndex {
            let available = Self.maxChunkBytes - pendingData.count
            precondition(available > 0, "ready history accumulator must make progress")
            let end = min(data.endIndex, offset + available)
            pendingData.append(data[offset..<end])
            offset = end
            if pendingData.count == Self.maxChunkBytes {
                flushReadyPending()
            }
        }
    }

    func flush(wait: Bool) {
        let barrier = flushBarrier()
        guard wait else { return }
        // Prepare completions hop to the main actor. A bare DispatchGroup.wait
        // on main deadlocks while those completions remain queued, so pump the
        // run loop when the caller is already on the main thread.
        if Thread.isMainThread {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if barrier.wait(until: .now() + .milliseconds(5)) {
                    return
                }
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
            }
            return
        }
        _ = barrier.wait(until: .now() + 10)
    }

    func flushBarrier(
        finalizing: Bool = false,
        retryTimeout: TimeInterval = 2
    ) -> SurfaceTerminationBarrier {
        if finalizing {
            acceptsWrites = false
            finalFlushScheduled = true
            queueState.shortenRetryDeadline(
                to: Date().addingTimeInterval(max(0, retryTimeout))
            )
            if let finalBarrier {
                return finalBarrier.surfaceBarrier()
            }
        }
        guard repository != nil else {
            let state = TerminalHistoryBarrierState()
            state.complete(success: true)
            return state.surfaceBarrier()
        }
        if preparationState == .failed {
            let state = TerminalHistoryBarrierState()
            state.complete(success: false)
            return state.surfaceBarrier()
        }
        if liveClearInFlight {
            if let liveClearBarrier {
                if finalizing {
                    finalBarrier = liveClearBarrier.state
                }
                return liveClearBarrier.state.surfaceBarrier()
            }
            let state = TerminalHistoryBarrierState()
            let barrier = (
                state: state,
                failureGeneration: queueState.currentFailureGeneration()
            )
            liveClearBarrier = barrier
            if finalizing {
                finalBarrier = state
            }
            return state.surfaceBarrier()
        }
        if let deferredBarrier {
            if finalizing {
                finalBarrier = deferredBarrier.state
            }
            return deferredBarrier.state.surfaceBarrier()
        }
        let state = TerminalHistoryBarrierState()
        if finalizing {
            finalBarrier = state
        }
        let failureGeneration = queueState.currentFailureGeneration()
        if case .ready = preparationState {
            flushReadyPending()
            scheduleBarrier(
                state,
                failureGeneration: failureGeneration,
                cancelRetriesOnCompletion: finalizing
            )
        } else {
            deferredBarrier = (state, failureGeneration)
        }
        return state.surfaceBarrier()
    }

    func readPersistedWindow(
        beforeChunkID: Int64?,
        maxBytes: Int,
        timeout: TimeInterval
    ) async throws -> TerminalOutputWindow {
        guard repository != nil else { throw TerminalHistoryReadError.unavailable }
        guard preparationState != .failed else { throw TerminalHistoryReadError.unavailable }
        guard !liveClearInFlight else { throw TerminalHistoryReadError.busy }
        guard durablePartialState == nil else { throw TerminalHistoryReadError.unavailable }
        guard activeReadOperation == nil else { throw TerminalHistoryReadError.busy }
        let operation = TerminalHistoryReadOperation()
        activeReadOperation = operation
        let failureGeneration = queueState.currentFailureGeneration()
        if case .ready = preparationState {
            flushReadyPending()
            scheduleRead(
                operation,
                beforeChunkID: beforeChunkID,
                maxBytes: maxBytes,
                failureGeneration: failureGeneration
            )
        } else {
            deferredOperations.append(.read(
                operation,
                beforeChunkID: beforeChunkID,
                maxBytes: maxBytes,
                failureGeneration: failureGeneration
            ))
        }
        return try await operation.value(timeout: timeout)
    }

    private func flushReadyPending() {
        guard let repository,
              case .ready = preparationState,
              let chunkIndex = nextChunkIndex,
              let writerGeneration,
              !pendingData.isEmpty else { return }

        let data = pendingData
        pendingData = Data()
        nextChunkIndex = chunkIndex + 1
        preparationState = .ready(nextChunkIndex: chunkIndex + 1)
        // Cap enforcement is cheap relative to the write and must not miss a
        // final partial MiB just because the sampling interval has not elapsed.
        bytesSinceRetentionCheck += data.count
        let shouldCheckRetention = true
        if bytesSinceRetentionCheck >= Self.retentionCheckInterval {
            bytesSinceRetentionCheck = 0
        }
        let surfaceID = surfaceID
        let workspaceID = workspaceID
        let queueState = queueState
        let historyQueue = queue
        let beforePersistForTesting = beforePersistForTesting

        queue.async { [weak self] in
            let reportFailure: @Sendable (Error) -> Void = { [weak self] error in
                queueState.recordFailure()
                let staleWriter = error as? TerminalHistoryRepositoryError
                    == .staleWriterGeneration
                var durablePartialConfirmed = false
                if !staleWriter {
                    let unresolvedRegistry =
                        TerminalHistoryUnresolvedFailureRegistry.shared
                    unresolvedRegistry.record(
                        surfaceID: surfaceID,
                        writerGeneration: writerGeneration,
                        reason: "history_persistence_failed",
                        minimumNextChunkIndex: chunkIndex + 1
                    )
                    let shouldScheduleDurableRetry = unresolvedRegistry.beginRetry(
                        surfaceID: surfaceID,
                        writerGeneration: writerGeneration
                    )
                    durablePartialConfirmed = Self.confirmDurablePartialState(
                        repository: repository,
                        surfaceID: surfaceID,
                        reason: "history_persistence_failed",
                        minimumNextChunkIndex: chunkIndex + 1,
                        expectedWriterGeneration: writerGeneration,
                        queueState: queueState
                    )
                    if durablePartialConfirmed {
                        queueState.recordDurablePartial()
                        do {
                            try repository.clearFailureAnchor(
                                surfaceID: surfaceID,
                                writerGeneration: writerGeneration,
                                throughNextChunkIndex: chunkIndex + 1
                            )
                        } catch {
                            NSLog(
                                "RemoteCode terminal history durable anchor cleanup failed surface=%@ error=%@",
                                surfaceID,
                                String(describing: error)
                            )
                        }
                        TerminalHistoryUnresolvedFailureRegistry.shared.resolve(
                            surfaceID: surfaceID,
                            writerGeneration: writerGeneration
                        )
                    } else if shouldScheduleDurableRetry {
                        Self.scheduleUnresolvedFailureRetry(
                            repository: repository,
                            surfaceID: surfaceID,
                            writerGeneration: writerGeneration,
                            attempt: 0
                        )
                    }
                } else {
                    do {
                        try repository.clearFailureAnchor(
                            surfaceID: surfaceID,
                            writerGeneration: writerGeneration
                        )
                    } catch {
                        NSLog(
                            "RemoteCode terminal history stale anchor cleanup failed surface=%@ error=%@",
                            surfaceID,
                            String(describing: error)
                        )
                    }
                    TerminalHistoryUnresolvedFailureRegistry.shared.resolve(
                        surfaceID: surfaceID,
                        writerGeneration: writerGeneration
                    )
                }
                NSLog(
                    "RemoteCode terminal history write failed surface=%@ chunk=%lld error=%@",
                    surfaceID,
                    chunkIndex,
                    String(describing: error)
                )
                DispatchQueue.main.async { [weak self] in
                    self?.completeWrite(
                        byteCount: data.count,
                        failed: true,
                        retentionTruncated: false,
                        retentionMaintenanceFailed: false,
                        staleWriter: staleWriter,
                        durablePartialConfirmed: durablePartialConfirmed
                    )
                }
            }
            let operationStartedAt = Date()
            var retryAttempt = 0
            TerminalHistoryUnresolvedFailureRegistry.shared.record(
                surfaceID: surfaceID,
                writerGeneration: writerGeneration,
                reason: "history_persistence_failed",
                minimumNextChunkIndex: chunkIndex + 1
            )
            do {
                try repository.recordFailureAnchor(
                    surfaceID: surfaceID,
                    writerGeneration: writerGeneration,
                    reason: "history_persistence_failed",
                    minimumNextChunkIndex: chunkIndex + 1
                )
            } catch {
                reportFailure(error)
                return
            }
            beforePersistForTesting?()
            while true {
                do {
                    try repository.appendWithHighWaterReservation(
                        surfaceID: surfaceID,
                        workspaceID: workspaceID,
                        chunkIndex: chunkIndex,
                        data: data,
                        expectedWriterGeneration: writerGeneration
                    )
                    break
                } catch where Self.isRetryableDatabaseLock(error) {
                    guard queueState.permitsRetry(
                        operationStartedAt: operationStartedAt,
                        maxDuration: Self.maxRetryDuration
                    ) else {
                        if !queueState.retriesAreCancelled() {
                            reportFailure(error)
                        }
                        return
                    }
                    let delays = Self.prepareRetryDelays
                    guard queueState.waitBeforeRetry(
                        delay: delays[min(retryAttempt, delays.count - 1)],
                        operationStartedAt: operationStartedAt,
                        maxDuration: Self.maxRetryDuration
                    ) else {
                        if !queueState.retriesAreCancelled() {
                            reportFailure(error)
                        }
                        return
                    }
                    retryAttempt += 1
                } catch {
                    if queueState.retriesAreCancelled() { return }
                    reportFailure(error)
                    return
                }
            }

            do {
                try repository.clearFailureAnchor(
                    surfaceID: surfaceID,
                    writerGeneration: writerGeneration,
                    throughNextChunkIndex: chunkIndex + 1
                )
                TerminalHistoryUnresolvedFailureRegistry.shared.resolve(
                    surfaceID: surfaceID,
                    writerGeneration: writerGeneration
                )
            } catch {
                let registry = TerminalHistoryUnresolvedFailureRegistry.shared
                if registry.beginRetry(
                    surfaceID: surfaceID,
                    writerGeneration: writerGeneration
                ) {
                    Self.scheduleUnresolvedFailureRetry(
                        repository: repository,
                        surfaceID: surfaceID,
                        writerGeneration: writerGeneration,
                        attempt: 0
                    )
                }
                NSLog(
                    "RemoteCode terminal history failure anchor cleanup deferred surface=%@ error=%@",
                    surfaceID,
                    String(describing: error)
                )
            }

            var retentionTruncated = false
            if shouldCheckRetention {
                do {
                    let total = try repository.totalBytes(surfaceID: surfaceID)
                    retentionTruncated = total > Self.maxPersistedBytes
                    if retentionTruncated {
                        retentionTruncated = try repository.pruneByteCapAndMarkHistoryPartial(
                            surfaceID: surfaceID,
                            maxBytes: Self.maxPersistedBytes,
                            reason: "history_retention_cap",
                            nextChunkIndex: chunkIndex + 1,
                            expectedWriterGeneration: writerGeneration
                        )
                        if retentionTruncated {
                            queueState.recordDurablePartial()
                        }
                    }
                } catch {
                    NSLog(
                        "RemoteCode terminal history retention maintenance failed surface=%@ error=%@",
                        surfaceID,
                        String(describing: error)
                    )
                    if Self.isRetryableDatabaseLock(error),
                       queueState.beginRetentionMaintenanceIfNeeded() {
                        Self.scheduleRetentionMaintenance(
                            repository: repository,
                            surfaceID: surfaceID,
                            queue: historyQueue,
                            queueState: queueState,
                            writerGeneration: writerGeneration,
                            minimumNextChunkIndex: chunkIndex + 1,
                            operationStartedAt: Date(),
                            attempt: 0,
                            onRecovered: { [weak self] truncated in
                                guard let self else { return }
                                self.delegate?.terminalHistoryCoordinator(
                                    self,
                                    didEncounter: truncated
                                        ? .retentionCap
                                        : .retentionMaintenanceRecovered
                                )
                            }
                        )
                    }
                    DispatchQueue.main.async { [weak self] in
                        self?.completeWrite(
                            byteCount: data.count,
                            failed: false,
                            retentionTruncated: false,
                            retentionMaintenanceFailed: true
                        )
                    }
                    return
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.completeWrite(
                    byteCount: data.count,
                    failed: false,
                    retentionTruncated: retentionTruncated,
                    retentionMaintenanceFailed: false
                )
            }
        }
    }

    private func completeWrite(
        byteCount: Int,
        failed: Bool,
        retentionTruncated: Bool,
        retentionMaintenanceFailed: Bool,
        staleWriter: Bool = false,
        durablePartialConfirmed: Bool = false
    ) {
        outstandingBytes = max(0, outstandingBytes - byteCount)
        if outstandingBytes == 0 {
            backlogOverflowed = false
        }
        if failed {
            writeFailures += 1
            acceptsWrites = false
            if durablePartialConfirmed,
               durablePartialState == nil {
                durablePartialState = TerminalHistoryPartialState(
                    reason: "history_persistence_failed",
                    nextChunkIndex: nextChunkIndex ?? 1
                )
            }
            delegate?.terminalHistoryCoordinator(
                self,
                didEncounter: staleWriter ? .staleWriterGeneration : .persistenceFailure
            )
        } else if retentionMaintenanceFailed {
            writeFailures += 1
            delegate?.terminalHistoryCoordinator(self, didEncounter: .retentionMaintenanceFailure)
        } else if retentionTruncated {
            delegate?.terminalHistoryCoordinator(self, didEncounter: .retentionCap)
        }
    }

    private nonisolated static func reconcileUnresolvedFailure(
        repository: TerminalOutputRepository,
        surfaceID: String,
        preparation: TerminalHistoryPreparation,
        memoryFailure: TerminalHistoryUnresolvedFailureRegistry.Entry?,
        durableFailures: [TerminalHistoryFailureAnchor]
    ) throws -> TerminalHistoryPreparation {
        let registry = TerminalHistoryUnresolvedFailureRegistry.shared
        for anchor in durableFailures
        where anchor.writerGeneration != preparation.writerGeneration {
            try repository.clearFailureAnchor(
                surfaceID: surfaceID,
                writerGeneration: anchor.writerGeneration
            )
            registry.resolve(
                surfaceID: surfaceID,
                writerGeneration: anchor.writerGeneration
            )
        }
        if let memoryFailure,
           memoryFailure.writerGeneration != preparation.writerGeneration {
            registry.resolve(
                surfaceID: surfaceID,
                writerGeneration: memoryFailure.writerGeneration
            )
        }

        let durableFailure = durableFailures
            .filter { $0.writerGeneration == preparation.writerGeneration }
            .max { $0.minimumNextChunkIndex < $1.minimumNextChunkIndex }
        let memoryFailure = memoryFailure.flatMap {
            $0.writerGeneration == preparation.writerGeneration ? $0 : nil
        }
        guard durableFailure != nil || memoryFailure != nil else { return preparation }
        let entry = TerminalHistoryUnresolvedFailureRegistry.Entry(
            writerGeneration: preparation.writerGeneration,
            reason: durableFailure?.reason
                ?? memoryFailure?.reason
                ?? "history_persistence_failed",
            minimumNextChunkIndex: max(
                durableFailure?.minimumNextChunkIndex ?? 1,
                memoryFailure?.minimumNextChunkIndex ?? 1
            )
        )
        let anchor = TerminalHistoryFailureAnchor(
            surfaceID: surfaceID,
            writerGeneration: entry.writerGeneration,
            reason: entry.reason,
            minimumNextChunkIndex: entry.minimumNextChunkIndex
        )

        do {
            if try repository.failureAnchorIsCovered(anchor) {
                try repository.clearFailureAnchor(
                    surfaceID: surfaceID,
                    writerGeneration: entry.writerGeneration,
                    throughNextChunkIndex: entry.minimumNextChunkIndex
                )
                registry.resolve(
                    surfaceID: surfaceID,
                    writerGeneration: entry.writerGeneration
                )
                return try repository.prepareHistory(surfaceID: surfaceID)
            }
            try repository.markHistoryPartial(
                surfaceID: surfaceID,
                reason: entry.reason,
                nextChunkIndex: entry.minimumNextChunkIndex,
                expectedWriterGeneration: entry.writerGeneration
            )
            let reconciled = try repository.prepareHistory(surfaceID: surfaceID)
            guard reconciled.partialState != nil,
                  reconciled.nextChunkIndex >= entry.minimumNextChunkIndex else {
                throw TerminalHistoryRepositoryError.unresolvedWriteReservation
            }
            try repository.clearFailureAnchor(
                surfaceID: surfaceID,
                writerGeneration: entry.writerGeneration,
                throughNextChunkIndex: entry.minimumNextChunkIndex
            )
            registry.resolve(
                surfaceID: surfaceID,
                writerGeneration: entry.writerGeneration
            )
            return reconciled
        } catch TerminalHistoryRepositoryError.staleWriterGeneration {
            try repository.clearFailureAnchor(
                surfaceID: surfaceID,
                writerGeneration: entry.writerGeneration
            )
            registry.resolve(
                surfaceID: surfaceID,
                writerGeneration: entry.writerGeneration
            )
            return try repository.prepareHistory(surfaceID: surfaceID)
        }
    }

    private nonisolated static func scheduleUnresolvedFailureRetry(
        repository: TerminalOutputRepository,
        surfaceID: String,
        writerGeneration: String,
        attempt: Int
    ) {
        let delays = prepareRetryDelays
        unresolvedFailureRetryQueue.asyncAfter(
            deadline: .now() + delays[min(attempt, delays.count - 1)]
        ) {
            let registry = TerminalHistoryUnresolvedFailureRegistry.shared
            guard let entry = registry.entry(surfaceID: surfaceID),
                  entry.writerGeneration == writerGeneration else { return }
            do {
                let anchor = TerminalHistoryFailureAnchor(
                    surfaceID: surfaceID,
                    writerGeneration: writerGeneration,
                    reason: entry.reason,
                    minimumNextChunkIndex: entry.minimumNextChunkIndex
                )
                if try repository.failureAnchorIsCovered(anchor) {
                    try repository.clearFailureAnchor(
                        surfaceID: surfaceID,
                        writerGeneration: writerGeneration,
                        throughNextChunkIndex: entry.minimumNextChunkIndex
                    )
                    registry.resolve(
                        surfaceID: surfaceID,
                        writerGeneration: writerGeneration
                    )
                    return
                }
                try repository.markHistoryPartial(
                    surfaceID: surfaceID,
                    reason: entry.reason,
                    nextChunkIndex: entry.minimumNextChunkIndex,
                    expectedWriterGeneration: writerGeneration
                )
                guard try repository.partialHistoryState(
                    surfaceID: surfaceID,
                    expectedWriterGeneration: writerGeneration
                ) != nil else {
                    scheduleUnresolvedFailureRetry(
                        repository: repository,
                        surfaceID: surfaceID,
                        writerGeneration: writerGeneration,
                        attempt: attempt + 1
                    )
                    return
                }
                try repository.clearFailureAnchor(
                    surfaceID: surfaceID,
                    writerGeneration: writerGeneration,
                    throughNextChunkIndex: entry.minimumNextChunkIndex
                )
                registry.resolve(
                    surfaceID: surfaceID,
                    writerGeneration: writerGeneration
                )
            } catch TerminalHistoryRepositoryError.staleWriterGeneration {
                registry.resolve(
                    surfaceID: surfaceID,
                    writerGeneration: writerGeneration
                )
            } catch where isRetryableDatabaseLock(error) {
                scheduleUnresolvedFailureRetry(
                    repository: repository,
                    surfaceID: surfaceID,
                    writerGeneration: writerGeneration,
                    attempt: attempt + 1
                )
            } catch {
                registry.stopRetry(
                    surfaceID: surfaceID,
                    writerGeneration: writerGeneration
                )
                NSLog(
                    "RemoteCode terminal history unresolved marker stopped surface=%@ error=%@",
                    surfaceID,
                    String(describing: error)
                )
            }
        }
    }

    private nonisolated static func confirmDurablePartialState(
        repository: TerminalOutputRepository,
        surfaceID: String,
        reason: String,
        minimumNextChunkIndex: Int64,
        expectedWriterGeneration: String,
        queueState: TerminalHistoryQueueState
    ) -> Bool {
        let startedAt = Date()
        let maxAttempts = 6
        for attempt in 0..<maxAttempts {
            if (try? repository.partialHistoryState(
                surfaceID: surfaceID,
                expectedWriterGeneration: expectedWriterGeneration
            )) != nil {
                return true
            }
            do {
                try repository.markHistoryPartial(
                    surfaceID: surfaceID,
                    reason: reason,
                    nextChunkIndex: minimumNextChunkIndex,
                    expectedWriterGeneration: expectedWriterGeneration
                )
                if (try? repository.partialHistoryState(
                    surfaceID: surfaceID,
                    expectedWriterGeneration: expectedWriterGeneration
                )) != nil {
                    return true
                }
            } catch {
                if error as? TerminalHistoryRepositoryError == .staleWriterGeneration {
                    return false
                }
                NSLog(
                    "RemoteCode terminal history partial marker retry failed surface=%@ attempt=%d error=%@",
                    surfaceID,
                    attempt,
                    String(describing: error)
                )
            }
            guard attempt + 1 < maxAttempts,
                  queueState.waitBeforeRetry(
                    delay: prepareRetryDelays[min(attempt, prepareRetryDelays.count - 1)],
                    operationStartedAt: startedAt,
                    maxDuration: maxRetryDuration
                  ) else { break }
        }
        return false
    }

    private nonisolated static func scheduleRetentionMaintenance(
        repository: TerminalOutputRepository,
        surfaceID: String,
        queue: DispatchQueue,
        queueState: TerminalHistoryQueueState,
        writerGeneration: String,
        minimumNextChunkIndex: Int64,
        operationStartedAt: Date,
        attempt: Int,
        onRecovered: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let delays = prepareRetryDelays
        queue.asyncAfter(deadline: .now() + delays[min(attempt, delays.count - 1)]) {
            guard queueState.permitsRetry(
                operationStartedAt: operationStartedAt,
                maxDuration: maxRetryDuration
            ) else {
                queueState.finishRetentionMaintenance()
                return
            }
            do {
                let truncated = try repository.pruneByteCapAndMarkHistoryPartial(
                    surfaceID: surfaceID,
                    maxBytes: maxPersistedBytes,
                    reason: "history_retention_cap",
                    nextChunkIndex: minimumNextChunkIndex,
                    expectedWriterGeneration: writerGeneration
                )
                if truncated { queueState.recordDurablePartial() }
                queueState.finishRetentionMaintenance()
                DispatchQueue.main.async { onRecovered(truncated) }
            } catch where isRetryableDatabaseLock(error)
                          && queueState.permitsRetry(
                            operationStartedAt: operationStartedAt,
                            maxDuration: maxRetryDuration
                          ) {
                scheduleRetentionMaintenance(
                    repository: repository,
                    surfaceID: surfaceID,
                    queue: queue,
                    queueState: queueState,
                    writerGeneration: writerGeneration,
                    minimumNextChunkIndex: minimumNextChunkIndex,
                    operationStartedAt: operationStartedAt,
                    attempt: attempt + 1,
                    onRecovered: onRecovered
                )
            } catch {
                queueState.finishRetentionMaintenance()
            }
        }
    }

    private func scheduleDeferredOperation(_ operation: DeferredOperation) {
        switch operation {
        case .read(let operation, let beforeChunkID, let maxBytes, let generation):
            scheduleRead(
                operation,
                beforeChunkID: beforeChunkID,
                maxBytes: maxBytes,
                failureGeneration: generation
            )
        }
    }

    private func scheduleBarrier(
        _ state: TerminalHistoryBarrierState,
        failureGeneration: UInt64,
        cancelRetriesOnCompletion: Bool = false
    ) {
        let queueState = queueState
        queue.async {
            let currentFailureGeneration = queueState.currentFailureGeneration()
            let success = currentFailureGeneration == 0
                && currentFailureGeneration == failureGeneration
            if cancelRetriesOnCompletion {
                queueState.cancelRetries()
            }
            state.complete(success: success)
        }
    }

    private func scheduleRead(
        _ operation: TerminalHistoryReadOperation,
        beforeChunkID: Int64?,
        maxBytes: Int,
        failureGeneration: UInt64
    ) {
        guard let repository else {
            operation.complete(.failure(TerminalHistoryReadError.unavailable))
            return
        }
        let surfaceID = surfaceID
        let queueState = queueState
        queue.async {
            // Any prior failed write means persisted history cannot prove a
            // complete prefix. Fail closed: RPC callers receive no stale text or
            // sequence cursor that could be mistaken for an exact mirror state.
            if failureGeneration != 0
                || queueState.currentFailureGeneration() != failureGeneration
                || queueState.hasDurablePartial() {
                operation.complete(.failure(TerminalHistoryReadError.unavailable))
            } else {
                do {
                    let window = try repository.readWindow(
                        surfaceID: surfaceID,
                        beforeChunkID: beforeChunkID,
                        maxBytes: maxBytes
                    )
                    operation.complete(.success(window))
                } catch {
                    operation.complete(.failure(error))
                }
            }
            DispatchQueue.main.async { [weak self, weak operation] in
                guard let self, let operation,
                      self.activeReadOperation === operation else { return }
                self.activeReadOperation = nil
            }
        }
    }

    /// Reusable live clear. Existing queued writes drain before the delete;
    /// output accepted during that window is held under the normal 4 MiB cap
    /// and becomes the first durable bytes only after SQLite acknowledges the
    /// new writer generation.
    func clearPersistedHistory() {
        guard repository != nil, !finalDeleteScheduled else { return }
        if liveClearInFlight {
            // A second clear applies to the live bytes accumulated since the
            // first request. They have not reached SQLite yet, so discard them
            // in memory and keep one bounded delete operation.
            outstandingBytes = max(0, outstandingBytes - liveClearBuffer.count)
            liveClearBuffer = Data()
            liveClearOverflowed = false
            return
        }
        if liveClearRequestedBeforePreparation {
            outstandingBytes = max(0, outstandingBytes - liveClearBuffer.count)
            liveClearBuffer = Data()
            liveClearOverflowed = false
            return
        }
        guard case .ready = preparationState, writerGeneration != nil else {
            liveClearRequestedBeforePreparation = true
            outstandingBytes = max(0, outstandingBytes - preflightData.count)
            preflightData = Data()
            liveClearBuffer = Data()
            liveClearOverflowed = false
            return
        }
        beginLiveClear()
    }

    private func beginLiveClear(preservingBufferedOutput: Bool = false) {
        guard let repository,
              let expectedWriterGeneration = writerGeneration,
              !liveClearInFlight,
              !finalDeleteScheduled else { return }
        let preservesRecoveryBuffer = liveClearRecoveryPending
            || preservingBufferedOutput
        liveClearRecoveryPending = false
        liveClearInFlight = true
        if !preservesRecoveryBuffer {
            liveClearOverflowed = false
            liveClearBuffer = Data()
        }
        flushScheduled = false
        let discardedBytes = pendingData.count + preflightData.count
        outstandingBytes = max(0, outstandingBytes - discardedBytes)
        pendingData = Data()
        preflightData = Data()
        let surfaceID = surfaceID
        let beforeLiveClearForTesting = beforeLiveClearForTesting
        queue.async { [weak self] in
            beforeLiveClearForTesting?()
            let result = Result {
                try repository.clearForReuse(
                    surfaceID: surfaceID,
                    expectedWriterGeneration: expectedWriterGeneration
                )
            }
            DispatchQueue.main.async { [weak self] in
                self?.completeLiveClear(result)
            }
        }
    }

    private func completeLiveClear(_ result: Result<String, Error>) {
        guard liveClearInFlight else { return }
        liveClearInFlight = false
        let bufferedData = liveClearBuffer
        let overflowed = liveClearOverflowed
        liveClearBuffer = Data()
        liveClearOverflowed = false
        let barrier = liveClearBarrier
        liveClearBarrier = nil
        let clearSucceeded: Bool
        let previousWriterGeneration = writerGeneration

        switch result {
        case .success(let nextWriterGeneration):
            clearSucceeded = true
            if let previousWriterGeneration {
                TerminalHistoryUnresolvedFailureRegistry.shared.resolve(
                    surfaceID: surfaceID,
                    writerGeneration: previousWriterGeneration
                )
            }
            if let previousWriterGeneration {
                do {
                    try repository?.clearFailureAnchor(
                        surfaceID: surfaceID,
                        writerGeneration: previousWriterGeneration
                    )
                } catch {
                    NSLog(
                        "RemoteCode terminal history clear anchor cleanup failed surface=%@ error=%@",
                        surfaceID,
                        String(describing: error)
                    )
                }
            }
            liveClearRecoveryPending = false
            writerGeneration = nextWriterGeneration
            nextChunkIndex = 1
            preparationState = .ready(nextChunkIndex: 1)
            replayPersistedBeforeChunkIndex = nil
            needsReplay = false
            replayLiveData = Data()
            replayLiveOverflowed = false
            replayReadFailurePending = false
            retryMustPreserveLiveView = false
            durablePartialState = nil
            backlogOverflowed = false
            queueState.resetAfterAcknowledgedClear()
            acceptsWrites = !finalFlushScheduled && !finalDeleteScheduled

            if finalDeleteScheduled {
                outstandingBytes = max(0, outstandingBytes - bufferedData.count)
                scheduleFinalDelete(expectedWriterGeneration: nextWriterGeneration)
            } else {
                if !bufferedData.isEmpty {
                    ingestReadyData(bufferedData)
                    flushReadyPending()
                }
                if overflowed {
                    let state = TerminalHistoryPartialState(
                        reason: "history_backlog_cap",
                        nextChunkIndex: nextChunkIndex ?? 1
                    )
                    durablePartialState = state
                    queueState.recordDurablePartial()
                    recordDurablePartial(
                        reason: state.reason,
                        minimumNextChunkIndex: state.nextChunkIndex
                    )
                }
            }
            delegate?.terminalHistoryCoordinator(
                self,
                didEncounter: .liveClearCompleted(outputIsPartial: overflowed)
            )

        case .failure(let error):
            clearSucceeded = false
            if finalDeleteScheduled {
                outstandingBytes = max(0, outstandingBytes - bufferedData.count)
                scheduleFinalDelete(expectedWriterGeneration: writerGeneration)
            } else if !bufferedData.isEmpty,
               case .ready = preparationState,
               acceptsWrites {
                ingestReadyData(bufferedData)
                flushReadyPending()
            } else if !bufferedData.isEmpty || overflowed {
                liveClearBuffer = bufferedData
                liveClearOverflowed = overflowed
                liveClearRecoveryPending = true
            }
            writeFailures += 1
            delegate?.terminalHistoryCoordinator(self, didEncounter: .liveClearFailed)
            NSLog(
                "RemoteCode terminal history live clear failed surface=%@ error=%@",
                surfaceID,
                String(describing: error)
            )
        }

        resolveDeferredOperationsAfterLiveClear(succeeded: clearSucceeded)
        if let barrier {
            if clearSucceeded {
                flushReadyPending()
                scheduleBarrier(
                    barrier.state,
                    failureGeneration: queueState.currentFailureGeneration(),
                    cancelRetriesOnCompletion: finalFlushScheduled
                )
            } else {
                if finalFlushScheduled { queueState.cancelRetries() }
                barrier.state.complete(success: false)
            }
        }
    }

    private func resolveDeferredOperationsAfterLiveClear(succeeded: Bool) {
        let operations = deferredOperations
        deferredOperations.removeAll(keepingCapacity: false)
        let barrier = deferredBarrier
        deferredBarrier = nil

        if succeeded {
            for operation in operations {
                scheduleDeferredOperation(operation)
            }
            if let barrier {
                scheduleBarrier(
                    barrier.state,
                    failureGeneration: queueState.currentFailureGeneration(),
                    cancelRetriesOnCompletion: finalFlushScheduled
                )
            }
            return
        }

        for operation in operations {
            switch operation {
            case .read(let operation, _, _, _):
                operation.complete(.failure(TerminalHistoryReadError.unavailable))
            }
        }
        if !operations.isEmpty { activeReadOperation = nil }
        if finalFlushScheduled { queueState.cancelRetries() }
        barrier?.state.complete(success: false)
    }

    /// Final user-close disposition. Pending bytes are intentionally discarded,
    /// already-queued writes drain first, then deletion runs last on the same
    /// serial queue. `acceptsWrites=false` guarantees no callback can enqueue a
    /// post-delete orphan row while the surface is being torn down.
    func discardAndDeletePersistedHistory() {
        guard !finalDeleteScheduled else { return }
        finalDeleteScheduled = true
        acceptsWrites = false
        queueState.cancelRetries()
        finalBarrier?.complete(success: false)
        flushScheduled = false
        outstandingBytes = 0
        pendingData = Data()
        preflightData = Data()
        liveClearBuffer = Data()
        liveClearOverflowed = false
        liveClearRecoveryPending = false
        needsReplay = false
        replayLiveData = Data()
        replayLiveOverflowed = false
        if let barrier = deferredBarrier {
            barrier.state.complete(success: false)
            deferredBarrier = nil
        }
        for operation in deferredOperations {
            switch operation {
            case .read(let operation, _, _, _):
                operation.complete(.failure(TerminalHistoryReadError.unavailable))
            }
        }
        deferredOperations.removeAll(keepingCapacity: false)
        activeReadOperation = nil
        guard repository != nil else { return }
        // A permanent close has no successor writer. If live clear already owns
        // the queue, enqueue one unconditional delete behind it now; waiting for
        // its weak MainActor callback would make the unregistered delete ownerless.
        scheduleFinalDelete(
            expectedWriterGeneration: liveClearInFlight ? nil : writerGeneration
        )
    }

    private func scheduleFinalDelete(expectedWriterGeneration: String?) {
        guard let repository, !finalDeleteEnqueued else { return }
        let surfaceID = surfaceID
        let pendingDelete: TerminalHistoryPendingDelete
        do {
            pendingDelete = try repository.recordPendingDelete(
                surfaceID: surfaceID,
                expectedWriterGeneration: expectedWriterGeneration
            )
        } catch {
            NSLog(
                "RemoteCode terminal history final delete tombstone failed surface=%@ error=%@",
                surfaceID,
                String(describing: error)
            )
            return
        }
        finalDeleteEnqueued = true
        TerminalHistoryPendingDeleteRegistry.shared.register(
            repository: repository,
            pendingDelete: pendingDelete,
            queue: queue,
            replayQueue: Self.ownerlessFinalDeleteQueue,
            retryTimeout: Self.finalDeleteRetryTimeout,
            isRetryable: Self.isRetryableDatabaseLock
        )
    }

    @discardableResult
    nonisolated static func scheduleOwnerlessFinalDelete(
        repository: TerminalOutputRepository,
        surfaceID: String
    ) -> SurfaceTerminationBarrier {
        let pendingDelete: TerminalHistoryPendingDelete
        do {
            pendingDelete = try repository.recordPendingDelete(
                surfaceID: surfaceID,
                expectedWriterGeneration: nil
            )
        } catch {
            NSLog(
                "RemoteCode terminal history ownerless delete tombstone failed surface=%@ error=%@",
                surfaceID,
                String(describing: error)
            )
            let state = TerminalHistoryBarrierState()
            state.complete(success: false)
            return state.surfaceBarrier()
        }
        return TerminalHistoryPendingDeleteRegistry.shared.register(
            repository: repository,
            pendingDelete: pendingDelete,
            queue: ownerlessFinalDeleteQueue,
            replayQueue: ownerlessFinalDeleteQueue,
            retryTimeout: finalDeleteRetryTimeout,
            isRetryable: isRetryableDatabaseLock
        )
    }

    @discardableResult
    nonisolated static func scheduleOwnerlessClearForReuse(
        repository: TerminalOutputRepository,
        surfaceID: String
    ) -> SurfaceTerminationBarrier {
        let pendingDelete: TerminalHistoryPendingDelete
        do {
            pendingDelete = try repository.recordPendingClearForReuse(
                surfaceID: surfaceID
            )
        } catch {
            NSLog(
                "RemoteCode terminal history ownerless reusable clear tombstone failed surface=%@ error=%@",
                surfaceID,
                String(describing: error)
            )
            let state = TerminalHistoryBarrierState()
            state.complete(success: false)
            return state.surfaceBarrier()
        }
        return TerminalHistoryPendingDeleteRegistry.shared.register(
            repository: repository,
            pendingDelete: pendingDelete,
            queue: ownerlessFinalDeleteQueue,
            replayQueue: ownerlessFinalDeleteQueue,
            retryTimeout: finalDeleteRetryTimeout,
            isRetryable: isRetryableDatabaseLock
        )
    }

    @discardableResult
    nonisolated static func replayPendingFinalDeletes(
        repository: TerminalOutputRepository
    ) -> SurfaceTerminationBarrier? {
        TerminalHistoryPendingDeleteRegistry.shared.replay(
            repository: repository,
            queue: ownerlessFinalDeleteQueue,
            retryTimeout: finalDeleteRetryTimeout,
            isRetryable: isRetryableDatabaseLock
        )
    }

    nonisolated static func pendingFinalDeleteBarrier() -> SurfaceTerminationBarrier? {
        TerminalHistoryPendingDeleteRegistry.shared.snapshot()
    }

    nonisolated static func resetPendingFinalDeleteMemoryForTesting() {
        TerminalHistoryPendingDeleteRegistry.shared.resetForTesting()
    }

    nonisolated static func setBeforePendingFinalDeleteAttemptForTesting(
        _ hook: (@Sendable () -> Void)?
    ) {
        TerminalHistoryPendingDeleteRegistry.shared.setBeforeAttemptForTesting(hook)
    }

    private func recordDurablePartial(
        reason: String,
        minimumNextChunkIndex: Int64
    ) {
        let state = TerminalHistoryPartialState(
            reason: durablePartialState?.reason ?? reason,
            nextChunkIndex: max(
                durablePartialState?.nextChunkIndex ?? 1,
                minimumNextChunkIndex
            )
        )
        durablePartialState = state
        queueState.recordDurablePartial()
        guard let repository, let expectedWriterGeneration = writerGeneration else { return }
        let surfaceID = surfaceID
        let queueState = queueState
        queue.async {
            guard Self.confirmDurablePartialState(
                repository: repository,
                surfaceID: surfaceID,
                reason: state.reason,
                minimumNextChunkIndex: state.nextChunkIndex,
                expectedWriterGeneration: expectedWriterGeneration,
                queueState: queueState
            ) else {
                NSLog(
                    "RemoteCode terminal history partial marker was not confirmed surface=%@ generation=%@",
                    surfaceID,
                    expectedWriterGeneration
                )
                return
            }
        }
    }

    func recordLiveReplayData(_ data: Data, maxBytes: Int) {
        guard (needsReplay || replayInFlight), !data.isEmpty else { return }
        guard !replayLiveOverflowed else { return }
        let remaining = max(0, maxBytes - replayLiveData.count)
        if remaining >= data.count {
            replayLiveData.append(data)
        } else {
            if remaining > 0 {
                replayLiveData.append(data.prefix(remaining))
            }
            replayLiveOverflowed = true
        }
    }

    func replayIfNeeded() {
        guard case .ready = preparationState,
              needsReplay,
              !replayInFlight,
              let readWindow else { return }
        // Consume `needsReplay` only after a successful read. A transient
        // failure remains retryable on the next window attach.
        if replayReadFailurePending,
           (!replayLiveData.isEmpty || replayLiveOverflowed) {
            // These bytes already reached the renderers after a previous read
            // failed. A later retry cannot prove whether they also reached disk,
            // so replacing the live view from persisted data is destructive.
            retryMustPreserveLiveView = true
        }
        replayInFlight = true
        if replayReadFailurePending {
            // Live bytes captured after a failed read are already present in the
            // renderer and cannot be merged safely on retry. Before the first
            // read, however, they must stay buffered so the canonical reset can
            // restore persisted scrollback followed by the newer live tail.
            replayLiveData = Data()
            replayLiveOverflowed = false
        }
        let surfaceID = surfaceID
        let persistedBeforeChunkIndex = replayPersistedBeforeChunkIndex
        queue.async { [weak self] in
            var readFailed = false
            let window: TerminalOutputWindow?
            do {
                window = try readWindow(surfaceID, persistedBeforeChunkIndex)
            } catch {
                NSLog(
                    "RemoteCode terminal history restore failed surface=%@ error=%@",
                    surfaceID,
                    String(describing: error)
                )
                window = nil
                readFailed = true
            }
            // `prepare` captures the first chunk index owned by this restored
            // runtime. Live bytes may flush before an attached window starts
            // replay; exclude those newer chunks here because replayLiveData
            // supplies the same bytes after the persisted pre-restore prefix.
            let payload = window.map { window in
                let persistedChunks = window.chunks.filter { chunk in
                    guard let persistedBeforeChunkIndex else { return true }
                    return chunk.chunkIndex < persistedBeforeChunkIndex
                }
                return Self.assembleReplayPayload(from: persistedChunks.map(\.data))
            }
                ?? Data()
            DispatchQueue.main.async { [weak self] in
                self?.completeReplay(payload: payload, readFailed: readFailed)
            }
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            if case .ready = self.preparationState {
                self.flushReadyPending()
            }
        }
    }

    private func completeReplay(payload: Data, readFailed: Bool) {
        replayInFlight = false
        if readFailed {
            replayReadFailurePending = true
            if !replayLiveData.isEmpty || replayLiveOverflowed {
                retryMustPreserveLiveView = true
            }
            replayLiveData = Data()
            replayLiveOverflowed = false
            if let delegate, !delegate.terminalHistoryIsClosing {
                delegate.terminalHistoryCoordinator(self, didEncounter: .replayReadFailure)
            }
            return
        }
        guard let delegate, !delegate.terminalHistoryIsClosing else { return }

        let liveData = replayLiveData
        let liveOverflowed = replayLiveOverflowed
        let recoveredFromReadFailure = replayReadFailurePending
        replayLiveData = Data()
        replayLiveOverflowed = false
        needsReplay = false
        replayPersistedBeforeChunkIndex = nil
        if retryMustPreserveLiveView {
            // The current renderers already contain bytes captured across a
            // failed read. Skip reset whether or not a later write caught up:
            // appending risks duplication; replacing risks erasing undurable
            // bytes. The read-failure issue keeps the snapshot explicitly partial.
            retryMustPreserveLiveView = false
            replayReadFailurePending = false
            return
        }
        if liveOverflowed {
            replayReadFailurePending = false
            delegate.terminalHistoryCoordinator(self, didEncounter: .replayLiveCap)
            return
        }

        var canonical = payload
        canonical.append(liveData)
        delegate.terminalHistoryCoordinator(self, didPrepareReplay: canonical)
        replayReadFailurePending = false
        if recoveredFromReadFailure {
            delegate.terminalHistoryCoordinator(self, didEncounter: .replayReadRecovered)
        }
    }

    private nonisolated static func isRetryableDatabaseLock(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        return message.contains("database is locked")
            || message.contains("database is busy")
            || message.contains("database table is locked")
    }

    nonisolated static func shouldAcceptBacklog(
        queuedBytes: Int,
        incomingBytes: Int,
        maxQueuedBytes: Int
    ) -> Bool {
        guard queuedBytes >= 0, incomingBytes >= 0, maxQueuedBytes >= 0 else { return false }
        let (total, overflowed) = queuedBytes.addingReportingOverflow(incomingBytes)
        return !overflowed && total <= maxQueuedBytes
    }

    nonisolated static func assembleReplayPayload(from chunkData: [Data]) -> Data {
        chunkData.reduce(into: Data()) { $0.append($1) }
    }
}
