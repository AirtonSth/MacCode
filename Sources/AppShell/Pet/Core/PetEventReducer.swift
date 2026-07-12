import Foundation
import CoreModel

public enum PetOperationPhase: Sendable, Equatable {
    case started
    case succeeded
    case failed
}

public enum PetFileActivity: Sendable, Equatable {
    case opened
    case saved(conflictID: String?)
    case conflict(id: String)
    case conflictResolved(id: String)
    case discarded(conflictID: String?)
    case closed(conflictID: String?)
}

public enum PetSSHSessionActivity: Sendable, Equatable {
    case connected
    case connectionFailed
    case unexpectedDisconnect
    case explicitDisconnect
}

public struct PetAttentionHydration: Sendable, Equatable {
    public let approvalIDs: Set<String>
    public let questionIDs: Set<String>
    public let fileConflictIDs: Set<String>
    public let count: Int
    public let isReconnecting: Bool

    public init(
        approvalIDs: Set<String> = [],
        questionIDs: Set<String> = [],
        fileConflictIDs: Set<String> = [],
        count: Int = 0,
        isReconnecting: Bool = false
    ) {
        self.approvalIDs = approvalIDs
        self.questionIDs = questionIDs
        self.fileConflictIDs = fileConflictIDs
        self.count = max(0, count)
        self.isReconnecting = isReconnecting
    }
}

public enum PetTransientTimerDirective: Sendable, Equatable {
    case schedule(milliseconds: Int64)
    case cancel
}

/// Typed input boundary between EventBus payload parsing and deterministic pet policy.
/// EventBus decoding stays outside this type so malformed JSON cannot enter the reducer.
public enum PetDomainEvent: Sendable, Equatable {
    case agentRunStarted(runID: String)
    case agentTurnStarted
    case agentItemStarted(itemID: String, type: AssistantItemType)
    case agentItemCompleted(itemID: String)
    case agentItemDelta
    case agentItemProgress
    case contextCompaction
    case approvalOpened(requestID: String)
    case approvalResolved(requestID: String)
    case questionOpened(requestID: String)
    case questionResolved(requestID: String)
    case agentRunError(runID: String, recoverable: Bool)
    case agentRunFinished(runID: String, status: AgentRunStatus)
    case companionCue(PetCompanionCue)
    case transientExpired
    case attentionHydrated(PetAttentionHydration)
    case attentionCountChanged(Int)
    case git(PetOperationPhase)
    case file(PetFileActivity)
    case projectScript(PetOperationPhase)
    case providerUpdate(PetOperationPhase)
    case sshTransfer(PetOperationPhase)
    case sshSession(PetSSHSessionActivity)
    case browserNavigation
    case reconnectingChanged(Bool)
    case idleTimeout
    case wake
    case screenLockChanged(isLocked: Bool)
    case interactionBegan
    case surfaceOutput
    case tokenUsage
    case layoutChanged
    case filesystemChanged
}

public enum PetIgnoredEventReason: Sendable, Equatable {
    case noise
    case duplicateTerminalOutcome
    case userInitiated
}

public enum PetReductionDisposition: Sendable, Equatable {
    case emitted
    case coalesced
    case unchanged
    case ignored(PetIgnoredEventReason)
}

public struct PetEventReduction: Sendable, Equatable {
    public let state: PetAnimationState
    public let disposition: PetReductionDisposition
    public let shouldRefreshAttention: Bool
    public let transientTimerDirective: PetTransientTimerDirective?

    public init(
        state: PetAnimationState,
        disposition: PetReductionDisposition,
        shouldRefreshAttention: Bool,
        transientTimerDirective: PetTransientTimerDirective? = nil
    ) {
        self.state = state
        self.disposition = disposition
        self.shouldRefreshAttention = shouldRefreshAttention
        self.transientTimerDirective = transientTimerDirective
    }
}

/// Pure value reducer. Callers supply a monotonic millisecond timestamp, which keeps
/// coalescing deterministic and avoids wall-clock changes affecting animation policy.
public struct PetEventReducer: Sendable {
    public private(set) var state: PetAnimationState = .idle
    public let coalescingWindowMilliseconds: Int64

    private var activeRunIDs: Set<String> = []
    private var activeItems: [String: PetAnimationState] = [:]
    private var approvalRequestIDs: Set<String> = []
    private var questionRequestIDs: Set<String> = []
    private var fileConflictIDs: Set<String> = []
    private var attentionCount = 0
    private var isReconnecting = false
    private var isSleeping = false
    private var isScreenLocked = false
    private var transientState: PetAnimationState?
    private var companionReturnState: PetAnimationState?
    private var terminalRunIDs: Set<String> = []
    private var terminalRunOrder: [String] = []
    private var lastEmittedState: PetAnimationState?
    private var lastEmittedAtMilliseconds: Int64?
    private var pendingTransientTimerDirective: PetTransientTimerDirective?

    private static let terminalRunHistoryLimit = 256
    private static let standardTransientMilliseconds: Int64 = 1_200
    private static let shortTransientMilliseconds: Int64 = 600

    public init(coalescingWindowMilliseconds: Int64 = 120) {
        self.coalescingWindowMilliseconds = max(0, coalescingWindowMilliseconds)
    }

    public var activeRunCount: Int { activeRunIDs.count }
    var companionBaseState: PetAnimationState { derivedState(includeTransient: false) }

    public static func mappedState(for event: PetDomainEvent) -> PetAnimationState? {
        switch event {
        case .agentRunStarted:
            return .coding
        case .agentTurnStarted, .contextCompaction:
            return .thinking
        case .agentItemStarted(_, let type):
            return PetAnimationState.state(for: type)
        case .agentRunFinished(_, let status):
            switch status {
            case .completed: return .success
            case .failed: return .failed
            case .cancelled, .interrupted: return .interrupted
                case .pending, .running: return .coding
            }
        case .agentRunError(_, let recoverable):
            return recoverable ? .interrupted : .failed
        case .attentionHydrated:
            return nil
        case .attentionCountChanged(let count):
            return count > 0 ? .waiting : nil
        case .git(let phase):
            switch phase {
            case .started: return .gitReview
            case .succeeded: return .success
            case .failed: return .failed
            }
        case .file(let activity):
            switch activity {
            case .opened, .saved: return .editing
            case .conflict: return .approval
            case .conflictResolved, .discarded, .closed: return nil
            }
        case .projectScript(let phase):
            switch phase {
            case .started: return .terminal
            case .succeeded: return .success
            case .failed: return .failed
            }
        case .providerUpdate(let phase):
            switch phase {
            case .started: return .coding
            case .succeeded: return .success
            case .failed: return .failed
            }
        case .sshTransfer(let phase):
            switch phase {
            case .started: return .terminal
            case .succeeded: return .success
            case .failed: return .failed
            }
        case .sshSession(let activity):
            switch activity {
            case .connected: return .success
            case .connectionFailed: return .failed
            case .unexpectedDisconnect: return .reconnecting
            case .explicitDisconnect: return nil
            }
        case .browserNavigation:
            return .search
        case .reconnectingChanged(let reconnecting):
            return reconnecting ? .reconnecting : nil
        case .idleTimeout, .screenLockChanged(isLocked: true):
            return .sleeping
        case .wake, .screenLockChanged(isLocked: false):
            return .idle
        case .agentItemCompleted, .agentItemDelta, .agentItemProgress,
             .approvalOpened, .approvalResolved, .questionOpened, .questionResolved,
             .companionCue, .transientExpired, .interactionBegan, .surfaceOutput, .tokenUsage,
             .layoutChanged, .filesystemChanged:
            return nil
        }
    }

    public mutating func reduce(
        _ event: PetDomainEvent,
        atMilliseconds timestamp: Int64
    ) -> PetEventReduction {
        pendingTransientTimerDirective = nil
        if Self.isNoise(event) {
            return ignored(.noise)
        }
        if case .sshSession(.explicitDisconnect) = event {
            return ignored(.userInitiated)
        }
        if case .agentRunFinished(let runID, _) = event, terminalRunIDs.contains(runID) {
            return ignored(.duplicateTerminalOutcome)
        }

        let previousState = state
        let mappedState = Self.mappedState(for: event)
        let shouldRefreshAttention = mutateState(for: event)
        if let companionReturnState,
           derivedState(includeTransient: false) != companionReturnState {
            clearTransient()
        }
        let nextState = derivedState()
        state = nextState

        let stateChanged = previousState != nextState
        guard stateChanged || mappedState == nextState else {
            return PetEventReduction(
                state: nextState,
                disposition: .unchanged,
                shouldRefreshAttention: shouldRefreshAttention,
                transientTimerDirective: pendingTransientTimerDirective
            )
        }

        let shouldCoalesce: Bool
        if lastEmittedState == nextState,
           let lastTimestamp = lastEmittedAtMilliseconds,
           timestamp >= lastTimestamp {
            shouldCoalesce = timestamp - lastTimestamp < coalescingWindowMilliseconds
        } else {
            shouldCoalesce = false
        }

        if shouldCoalesce {
            return PetEventReduction(
                state: nextState,
                disposition: .coalesced,
                shouldRefreshAttention: shouldRefreshAttention,
                transientTimerDirective: pendingTransientTimerDirective
            )
        }

        lastEmittedState = nextState
        lastEmittedAtMilliseconds = timestamp
        return PetEventReduction(
            state: nextState,
            disposition: .emitted,
            shouldRefreshAttention: shouldRefreshAttention,
            transientTimerDirective: pendingTransientTimerDirective
        )
    }

    private mutating func mutateState(for event: PetDomainEvent) -> Bool {
        switch event {
        case .agentRunStarted(let runID):
            activeRunIDs.insert(runID)
            isSleeping = false
            clearTransient()
            return true
        case .agentTurnStarted:
            setTransient(.thinking, milliseconds: Self.standardTransientMilliseconds)
            return false
        case .contextCompaction:
            setTransient(.thinking, milliseconds: Self.shortTransientMilliseconds)
            return false
        case .agentItemStarted(let itemID, let type):
            clearTransient(matching: .thinking)
            if let itemState = PetAnimationState.state(for: type) {
                activeItems[itemID] = itemState
            }
            return false
        case .agentItemCompleted(let itemID):
            activeItems[itemID] = nil
            return false
        case .approvalOpened(let requestID):
            return approvalRequestIDs.insert(requestID).inserted
        case .approvalResolved(let requestID):
            return approvalRequestIDs.remove(requestID) != nil
        case .questionOpened(let requestID):
            return questionRequestIDs.insert(requestID).inserted
        case .questionResolved(let requestID):
            return questionRequestIDs.remove(requestID) != nil
        case .agentRunError:
            guard let state = Self.mappedState(for: event) else { return false }
            setTransient(state, milliseconds: Self.standardTransientMilliseconds)
            return false
        case .agentRunFinished(let runID, let status):
            activeRunIDs.remove(runID)
            if activeRunIDs.isEmpty {
                activeItems.removeAll()
            }
            rememberTerminalRun(runID)
            if let state = Self.mappedState(for: event) {
                setTransient(state, milliseconds: Self.standardTransientMilliseconds)
            }
            return status != .cancelled
        case .companionCue(let cue):
            guard (cue.returnState == state || cue.returnState == companionBaseState),
                  cue.state.isCompanionReaction,
                  state != .approval,
                  state != .question,
                  state != .sleeping else { return false }
            setTransient(
                cue.state,
                milliseconds: cue.durationMilliseconds,
                companionReturnState: cue.returnState
            )
            return false
        case .transientExpired:
            clearTransient()
            return false
        case .interactionBegan:
            clearTransient()
            isSleeping = false
            return false
        case .attentionHydrated(let hydration):
            approvalRequestIDs = hydration.approvalIDs
            questionRequestIDs = hydration.questionIDs
            fileConflictIDs = hydration.fileConflictIDs
            attentionCount = hydration.count
            isReconnecting = hydration.isReconnecting
            return false
        case .attentionCountChanged(let count):
            attentionCount = max(0, count)
            return false
        case .git(let phase):
            guard let state = Self.mappedState(for: event) else { return false }
            switch phase {
            case .started:
                setPersistentTransient(state)
                return false
            case .succeeded, .failed:
                setTransient(state, milliseconds: Self.standardTransientMilliseconds)
                return true
            }
        case .projectScript(let phase), .sshTransfer(let phase):
            guard let state = Self.mappedState(for: event) else { return false }
            switch phase {
            case .started:
                setPersistentTransient(state)
                return false
            case .succeeded, .failed:
                setTransient(state, milliseconds: Self.standardTransientMilliseconds)
                return true
            }
        case .providerUpdate(let phase):
            guard let state = Self.mappedState(for: event) else { return false }
            switch phase {
            case .started:
                setPersistentTransient(state)
            case .succeeded, .failed:
                setTransient(state, milliseconds: Self.standardTransientMilliseconds)
            }
            return false
        case .browserNavigation:
            setTransient(.search, milliseconds: Self.shortTransientMilliseconds)
            return false
        case .file(let activity):
            switch activity {
            case .conflict(let id):
                clearTransient(matching: .editing)
                return fileConflictIDs.insert(id).inserted
            case .conflictResolved(let id):
                let removed = fileConflictIDs.remove(id) != nil
                clearTransient(matching: .editing)
                return removed
            case .opened:
                setTransient(.editing, milliseconds: Self.shortTransientMilliseconds)
                return false
            case .saved(let conflictID):
                let removed = conflictID.map { fileConflictIDs.remove($0) != nil } ?? false
                setTransient(.editing, milliseconds: Self.shortTransientMilliseconds)
                return removed
            case .discarded(let conflictID), .closed(let conflictID):
                let removed = conflictID.map { fileConflictIDs.remove($0) != nil } ?? false
                clearTransient(matching: .editing)
                return removed
            }
        case .sshSession(let activity):
            switch activity {
            case .connected:
                isReconnecting = false
                setTransient(.success, milliseconds: Self.standardTransientMilliseconds)
            case .connectionFailed:
                isReconnecting = false
                setTransient(.failed, milliseconds: Self.standardTransientMilliseconds)
            case .unexpectedDisconnect:
                isReconnecting = true
                clearTransient()
            case .explicitDisconnect:
                break
            }
            return activity == .unexpectedDisconnect || activity == .connectionFailed
        case .reconnectingChanged(let reconnecting):
            isReconnecting = reconnecting
            return false
        case .idleTimeout:
            isSleeping = true
            return false
        case .wake:
            isSleeping = false
            return false
        case .screenLockChanged(let isLocked):
            isScreenLocked = isLocked
            if !isLocked { isSleeping = false }
            return false
        case .agentItemDelta, .agentItemProgress, .surfaceOutput, .tokenUsage,
             .layoutChanged, .filesystemChanged:
            return false
        }
    }

    private mutating func setTransient(
        _ state: PetAnimationState,
        milliseconds: Int64,
        companionReturnState: PetAnimationState? = nil
    ) {
        transientState = state
        self.companionReturnState = companionReturnState
        pendingTransientTimerDirective = .schedule(milliseconds: milliseconds)
    }

    private mutating func setPersistentTransient(_ state: PetAnimationState) {
        transientState = state
        companionReturnState = nil
        pendingTransientTimerDirective = .cancel
    }

    private mutating func clearTransient(matching state: PetAnimationState? = nil) {
        guard transientState != nil, state == nil || transientState == state else { return }
        transientState = nil
        companionReturnState = nil
        pendingTransientTimerDirective = .cancel
    }

    private func derivedState(includeTransient: Bool = true) -> PetAnimationState {
        if isScreenLocked { return .sleeping }

        var candidates: [PetAnimationState] = [.idle]
        if !approvalRequestIDs.isEmpty || !fileConflictIDs.isEmpty { candidates.append(.approval) }
        if !questionRequestIDs.isEmpty { candidates.append(.question) }
        if includeTransient, let transientState { candidates.append(transientState) }
        candidates.append(contentsOf: activeItems.values)
        if !activeRunIDs.isEmpty { candidates.append(.coding) }
        if isReconnecting { candidates.append(.reconnecting) }
        if attentionCount > 0 { candidates.append(.waiting) }
        if isSleeping { candidates.append(.sleeping) }
        return PetAnimationState.highestPriority(in: candidates) ?? .idle
    }

    private static func isNoise(_ event: PetDomainEvent) -> Bool {
        switch event {
        case .agentItemDelta, .agentItemProgress, .surfaceOutput, .tokenUsage,
             .layoutChanged, .filesystemChanged:
            return true
        default:
            return false
        }
    }

    private mutating func rememberTerminalRun(_ runID: String) {
        guard terminalRunIDs.insert(runID).inserted else { return }
        terminalRunOrder.append(runID)
        if terminalRunOrder.count > Self.terminalRunHistoryLimit {
            let removed = terminalRunOrder.removeFirst()
            terminalRunIDs.remove(removed)
        }
    }

    private func ignored(_ reason: PetIgnoredEventReason) -> PetEventReduction {
        PetEventReduction(
            state: state,
            disposition: .ignored(reason),
            shouldRefreshAttention: false
        )
    }
}
