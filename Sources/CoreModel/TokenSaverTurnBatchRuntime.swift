import Foundation

/// Host-owned agent_turn_batch executor (task-17). Default OFF.
/// Read-only live gate is separate from mutation gate (AC-08).
public final class TokenSaverTurnBatchRuntime: @unchecked Sendable {
    public static let taskID = "task-17"

    public enum ActionKind: String, Sendable, Equatable {
        case read
        case mutation
    }

    public struct Action: Sendable, Equatable {
        public let id: String
        public let kind: ActionKind
        public let dependsOn: [String]
        public let requiresPriorOutput: Bool
        public let approved: Bool
        public let idempotencyKey: String?
        public let proposedByMLX: Bool
        public let preconditionOK: Bool
        /// Per-action timeout budget in ms (0 = none). Enforced around executor.perform.
        public let timeoutMs: Int

        public init(
            id: String,
            kind: ActionKind,
            dependsOn: [String] = [],
            requiresPriorOutput: Bool = false,
            approved: Bool = false,
            idempotencyKey: String? = nil,
            proposedByMLX: Bool = false,
            preconditionOK: Bool = true,
            timeoutMs: Int = 0
        ) {
            self.id = id
            self.kind = kind
            self.dependsOn = dependsOn
            self.requiresPriorOutput = requiresPriorOutput
            self.approved = approved
            self.idempotencyKey = idempotencyKey
            self.proposedByMLX = proposedByMLX
            self.preconditionOK = preconditionOK
            self.timeoutMs = max(0, timeoutMs)
        }
    }

    public enum Outcome: String, Sendable, Equatable {
        case completed
        case skippedUnknownDep
        case deniedNoApproval
        case deniedMutationGate
        case rejectedMLXMutation
        case preconditionFailed
        case failed
        case cancelled
        case timedOut
        case duplicateIdempotent
        case notLive
        case missingExecutor
    }

    public struct ActionReceipt: Sendable, Equatable {
        public let actionID: String
        public let outcome: Outcome
        public let approved: Bool
        public let preconditionOK: Bool
        public let outputKnown: Bool
        public let timedOut: Bool
        public let cancelled: Bool
        public let idempotencyKey: String?
    }

    public struct BatchResult: Sendable, Equatable {
        public let outcomes: [String: Outcome]
        public let receipts: [ActionReceipt]
        public let completedIDs: [String]
        public let knownOutputIDs: [String]
        public let aborted: Bool
    }

    public protocol IdempotencyStore: AnyObject {
        func seen(_ key: String) -> Bool
        /// Atomically reserve key before execution. Returns false if already reserved/seen.
        func tryReserve(_ key: String) -> Bool
        /// Release reservation after failed execution so retries are allowed.
        func release(_ key: String)
        @discardableResult
        func mark(_ key: String) -> Bool
    }

    public final class MemoryIdempotencyStore: IdempotencyStore, @unchecked Sendable {
        private let lock = NSLock()
        private var keys = Set<String>()
        public init() {}
        public func seen(_ key: String) -> Bool {
            lock.lock(); defer { lock.unlock() }; return keys.contains(key)
        }
        public func tryReserve(_ key: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if keys.contains(key) { return false }
            keys.insert(key)
            return true
        }
        public func release(_ key: String) {
            lock.lock(); keys.remove(key); lock.unlock()
        }
        @discardableResult
        public func mark(_ key: String) -> Bool {
            lock.lock(); keys.insert(key); lock.unlock()
            return true
        }
    }

    /// Durable store for relaunch proof (file-backed keys).
    public final class FileIdempotencyStore: IdempotencyStore, @unchecked Sendable {
        private let lock = NSLock()
        private let directory: URL
        public init(directory: URL) throws {
            self.directory = directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        private func url(for key: String) -> URL {
            let safe = key.data(using: .utf8)!.base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
            return directory.appendingPathComponent(safe)
        }
        public func seen(_ key: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return FileManager.default.fileExists(atPath: url(for: key).path)
        }
        public func tryReserve(_ key: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let path = url(for: key).path
            if FileManager.default.fileExists(atPath: path) { return false }
            return FileManager.default.createFile(atPath: path, contents: Data("reserved".utf8))
        }
        public func release(_ key: String) {
            lock.lock(); defer { lock.unlock() }
            try? FileManager.default.removeItem(at: url(for: key))
        }
        @discardableResult
        public func mark(_ key: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let path = url(for: key).path
            if FileManager.default.fileExists(atPath: path) { return true }
            return FileManager.default.createFile(atPath: path, contents: Data("done".utf8))
        }
    }

    public struct ExecutionResult: Sendable, Equatable {
        public let success: Bool
        /// When false, dependents with requiresPriorOutput must skip (unknown-output boundary).
        public let outputKnown: Bool
        public let timedOut: Bool
        public init(success: Bool, outputKnown: Bool = true, timedOut: Bool = false) {
            self.success = success
            self.outputKnown = outputKnown
            self.timedOut = timedOut
        }
    }

    public protocol ActionExecutor: AnyObject {
        func perform(_ action: Action) -> ExecutionResult
    }

    private let lock = NSLock()
    private var _readOnlyLive: Bool = false
    private var _mutationsEnabled: Bool = false
    private var completed: Set<String> = []
    /// Separate from completed: only actions whose executor reported outputKnown.
    private var knownOutputs: Set<String> = []
    private var outcomes: [String: Outcome] = [:]
    private var receipts: [ActionReceipt] = []
    private var cancelled = false
    private var timedOut = false
    private var aborted = false
    private let idempotency: IdempotencyStore
    public var executor: ActionExecutor?
    public var onAfterAction: ((String) -> Void)?

    public init(idempotency: IdempotencyStore = MemoryIdempotencyStore()) {
        self.idempotency = idempotency
    }

    public var live: Bool {
        get { readOnlyLive }
        set { readOnlyLive = newValue }
    }

    public var readOnlyLive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _readOnlyLive }
        set { lock.lock(); _readOnlyLive = newValue; lock.unlock() }
    }

    public var mutationsEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _mutationsEnabled }
        set { lock.lock(); _mutationsEnabled = newValue; lock.unlock() }
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    public func markTimedOut() {
        lock.lock(); timedOut = true; lock.unlock()
    }

    public func readyActions(from actions: [Action]) -> [Action] {
        lock.lock()
        let done = completed
        let isLive = _readOnlyLive
        lock.unlock()
        guard isLive else { return [] }
        return actions.filter { action in
            guard !done.contains(action.id) else { return false }
            return action.dependsOn.allSatisfy { done.contains($0) }
        }
    }

    public func admit(_ action: Action) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        return admitLocked(action)
    }

    public func run(actions: [Action], failingIDs: Set<String> = []) -> BatchResult {
        lock.lock()
        cancelled = false
        timedOut = false
        aborted = false
        completed = []
        knownOutputs = []
        outcomes = [:]
        receipts = []
        lock.unlock()

        var remaining = actions
        var safety = 0
        while safety < actions.count + 2 {
            safety += 1
            lock.lock()
            if cancelled || timedOut || aborted {
                for a in remaining where outcomes[a.id] == nil {
                    let o: Outcome = cancelled ? .cancelled : (timedOut ? .timedOut : .failed)
                    outcomes[a.id] = o
                    receipts.append(makeReceipt(a, o, outputKnown: false))
                }
                let snap = snapshotLocked()
                lock.unlock()
                return snap
            }
            let isLive = _readOnlyLive
            let done = completed
            let known = knownOutputs
            lock.unlock()

            if !isLive {
                lock.lock()
                for a in remaining where outcomes[a.id] == nil {
                    outcomes[a.id] = .notLive
                    receipts.append(makeReceipt(a, .notLive, outputKnown: false))
                }
                let snap = snapshotLocked()
                lock.unlock()
                return snap
            }

            // Ready: structural deps completed. requiresPriorOutput also needs known output.
            let ready = remaining.filter { action in
                guard !done.contains(action.id) else { return false }
                guard action.dependsOn.allSatisfy({ done.contains($0) }) else { return false }
                if action.requiresPriorOutput {
                    return action.dependsOn.allSatisfy { known.contains($0) }
                }
                return true
            }
            if ready.isEmpty {
                lock.lock()
                for a in remaining where outcomes[a.id] == nil {
                    let missingCompleted = a.dependsOn.contains { !completed.contains($0) }
                    let missingKnown = a.requiresPriorOutput && a.dependsOn.contains { !knownOutputs.contains($0) }
                    let o: Outcome = (missingCompleted || missingKnown) ? .skippedUnknownDep : .failed
                    outcomes[a.id] = o
                    receipts.append(makeReceipt(a, o, outputKnown: false))
                }
                let snap = snapshotLocked()
                lock.unlock()
                return snap
            }

            // Same-step independent reads execute concurrently; mutations stay serial.
            let stepReads = ready.filter { $0.kind == .read }.sorted { $0.id < $1.id }
            let stepMuts = ready.filter { $0.kind == .mutation }.sorted { $0.id < $1.id }
            let step = stepReads + stepMuts

            var progressed = false
            var concurrentWork: [(Action, ActionExecutor)] = []
            for action in step {
                let isRead = action.kind == .read
                lock.lock()
                if cancelled {
                    outcomes[action.id] = .cancelled
                    receipts.append(makeReceipt(action, .cancelled, outputKnown: false))
                    lock.unlock()
                    onAfterAction?(action.id)
                    continue
                }
                if timedOut {
                    outcomes[action.id] = .timedOut
                    receipts.append(makeReceipt(action, .timedOut, outputKnown: false))
                    lock.unlock()
                    onAfterAction?(action.id)
                    continue
                }
                let outcome = admitLocked(action)
                if outcome != .completed {
                    outcomes[action.id] = outcome
                    receipts.append(makeReceipt(action, outcome, outputKnown: false))
                    lock.unlock()
                    onAfterAction?(action.id)
                    continue
                }
                if failingIDs.contains(action.id) {
                    outcomes[action.id] = .failed
                    receipts.append(makeReceipt(action, .failed, outputKnown: false))
                    aborted = true
                    failDependentsLocked(of: action.id, remaining: remaining)
                    let snap = snapshotLocked()
                    lock.unlock()
                    onAfterAction?(action.id)
                    return snap
                }
                guard let exec = executor else {
                    outcomes[action.id] = .missingExecutor
                    receipts.append(makeReceipt(action, .missingExecutor, outputKnown: false))
                    lock.unlock()
                    onAfterAction?(action.id)
                    continue
                }
                // Reserve idempotency before any perform (blocks concurrent double-exec).
                if let key = action.idempotencyKey, !key.isEmpty {
                    if !idempotency.tryReserve(key) {
                        outcomes[action.id] = .duplicateIdempotent
                        receipts.append(makeReceipt(action, .duplicateIdempotent, outputKnown: false))
                        lock.unlock()
                        onAfterAction?(action.id)
                        continue
                    }
                }
                if isRead {
                    concurrentWork.append((action, exec))
                    lock.unlock()
                    continue
                }
                // Mutations: serial perform
                lock.unlock()
                let execResult = performWithTimeout(action, exec: exec)
                let abort = applyExecutionResult(action, execResult, remaining: remaining, progressed: &progressed, reservedKey: action.idempotencyKey)
                onAfterAction?(action.id)
                if abort { return snapshotUnlocked() }
            }

            if !concurrentWork.isEmpty {
                let box = ConcurrentExecBox()
                DispatchQueue.concurrentPerform(iterations: concurrentWork.count) { i in
                    let (action, exec) = concurrentWork[i]
                    box.set(action.id, performWithTimeout(action, exec: exec))
                }
                // Record outcomes for ALL concurrent reads before aborting (completed-results envelope).
                var shouldAbort = false
                for (action, _) in concurrentWork {
                    let execResult = box.get(action.id) ?? ExecutionResult(success: false, outputKnown: false)
                    let abort = applyExecutionResult(
                        action, execResult, remaining: remaining, progressed: &progressed,
                        reservedKey: action.idempotencyKey
                    )
                    onAfterAction?(action.id)
                    if abort { shouldAbort = true }
                }
                if shouldAbort { return snapshotUnlocked() }
            }
            _ = step

            remaining = remaining.filter { outcomes[$0.id] == nil }
            if !progressed && remaining.isEmpty { break }
            if !progressed {
                lock.lock()
                for a in remaining where outcomes[a.id] == nil {
                    let o: Outcome = a.requiresPriorOutput ? .skippedUnknownDep : .failed
                    outcomes[a.id] = o
                    receipts.append(makeReceipt(a, o, outputKnown: false))
                }
                let snap = snapshotLocked()
                lock.unlock()
                return snap
            }
        }

        lock.lock()
        let snap = snapshotLocked()
        lock.unlock()
        return snap
    }

    private func failDependentsLocked(of id: String, remaining: [Action]) {
        var queue = [id]
        var seen = Set<String>([id])
        while let cur = queue.popLast() {
            for a in remaining where outcomes[a.id] == nil && a.dependsOn.contains(cur) {
                if seen.insert(a.id).inserted {
                    outcomes[a.id] = .failed
                    receipts.append(makeReceipt(a, .failed, outputKnown: false))
                    queue.append(a.id)
                }
            }
        }
    }

    private func performWithTimeout(_ action: Action, exec: ActionExecutor) -> ExecutionResult {
        if action.timeoutMs <= 0 {
            return exec.perform(action)
        }
        let box = ConcurrentExecBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(action.id, exec.perform(action))
            group.leave()
        }
        let wait = group.wait(timeout: .now() + .milliseconds(action.timeoutMs))
        if wait == .timedOut {
            return ExecutionResult(success: false, outputKnown: false, timedOut: true)
        }
        return box.get(action.id) ?? ExecutionResult(success: false, outputKnown: false)
    }

    /// Apply executor result under lock. Returns true if batch should abort (fail-fast).
    /// Always records an outcome/receipt for the action.
    private func applyExecutionResult(
        _ action: Action,
        _ execResult: ExecutionResult,
        remaining: [Action],
        progressed: inout Bool,
        reservedKey: String?
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // Timed out globally?
        if timedOut {
            if let key = reservedKey, !key.isEmpty { idempotency.release(key) }
            outcomes[action.id] = .timedOut
            receipts.append(makeReceipt(action, .timedOut, outputKnown: false))
            return true
        }
        if cancelled {
            if let key = reservedKey, !key.isEmpty { idempotency.release(key) }
            outcomes[action.id] = .cancelled
            receipts.append(makeReceipt(action, .cancelled, outputKnown: false))
            return true
        }
        if !execResult.success {
            if let key = reservedKey, !key.isEmpty { idempotency.release(key) }
            let o: Outcome = execResult.timedOut ? .timedOut : .failed
            outcomes[action.id] = o
            receipts.append(makeReceipt(action, o, outputKnown: false))
            aborted = true
            failDependentsLocked(of: action.id, remaining: remaining)
            return true
        }
        // Success: reservation already holds the key; mark is idempotent confirm.
        if let key = reservedKey, !key.isEmpty {
            if !idempotency.mark(key) {
                // Reservation held but mark failed — treat as durable failure, keep key reserved.
                outcomes[action.id] = .failed
                receipts.append(makeReceipt(action, .failed, outputKnown: false))
                aborted = true
                failDependentsLocked(of: action.id, remaining: remaining)
                return true
            }
        }
        completed.insert(action.id)
        if execResult.outputKnown {
            knownOutputs.insert(action.id)
        }
        outcomes[action.id] = .completed
        receipts.append(makeReceipt(action, .completed, outputKnown: execResult.outputKnown))
        progressed = true
        return false
    }

    private func snapshotUnlocked() -> BatchResult {
        lock.lock()
        let snap = snapshotLocked()
        lock.unlock()
        return snap
    }

    private func admitLocked(_ action: Action) -> Outcome {
        if !_readOnlyLive { return .notLive }
        if cancelled { return .cancelled }
        if timedOut { return .timedOut }
        if aborted { return .failed }
        if !action.preconditionOK { return .preconditionFailed }
        if let key = action.idempotencyKey, !key.isEmpty, idempotency.seen(key) {
            return .duplicateIdempotent
        }
        if action.proposedByMLX && action.kind == .mutation {
            return .rejectedMLXMutation
        }
        if action.kind == .mutation {
            if !_mutationsEnabled { return .deniedMutationGate }
            if !action.approved { return .deniedNoApproval }
        }
        if action.requiresPriorOutput {
            let missingKnown = action.dependsOn.contains { !knownOutputs.contains($0) }
            if missingKnown { return .skippedUnknownDep }
        } else if action.dependsOn.contains(where: { !completed.contains($0) }) {
            return .skippedUnknownDep
        }
        // Idempotency marked only after successful execute in run().
        return .completed
    }

    private func makeReceipt(_ action: Action, _ outcome: Outcome, outputKnown: Bool) -> ActionReceipt {
        ActionReceipt(
            actionID: action.id,
            outcome: outcome,
            approved: action.approved,
            preconditionOK: action.preconditionOK,
            outputKnown: outputKnown,
            timedOut: outcome == .timedOut,
            cancelled: outcome == .cancelled,
            idempotencyKey: action.idempotencyKey
        )
    }

    private func snapshotLocked() -> BatchResult {
        BatchResult(
            outcomes: outcomes,
            receipts: receipts,
            completedIDs: completed.sorted(),
            knownOutputIDs: knownOutputs.sorted(),
            aborted: aborted || cancelled || timedOut
        )
    }
}

/// Thread-safe bag for concurrent read execution results.
private final class ConcurrentExecBox: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: TokenSaverTurnBatchRuntime.ExecutionResult] = [:]
    func set(_ id: String, _ result: TokenSaverTurnBatchRuntime.ExecutionResult) {
        lock.lock(); map[id] = result; lock.unlock()
    }
    func get(_ id: String) -> TokenSaverTurnBatchRuntime.ExecutionResult? {
        lock.lock(); defer { lock.unlock() }; return map[id]
    }
}
