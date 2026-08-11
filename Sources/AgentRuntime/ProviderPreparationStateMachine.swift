import Foundation

/// Honest, cancellable pre-provider preparation (S5 / T-003).
///
/// Generation-owned states:
/// `accepting → preparing(cancellable) → providerStarting → running → stopping → terminal`
/// Stop/Escape cancels preparation and prevents late spawn via generation checks.

public enum ProviderPreparationPhase: String, Sendable, Equatable {
    case accepting
    case preparing
    case providerStarting
    case running
    case stopping
    case terminal
}

public enum ProviderPreparationTerminalReason: String, Sendable, Equatable {
    case completed
    case cancelled
    case failed
    case durabilityFailure
    case providerFailure
}

public struct ProviderPreparationState: Sendable, Equatable {
    public var phase: ProviderPreparationPhase
    public var generation: UInt64
    public var draftMessageId: String?
    public var acceptedAtMs: Int64?
    public var terminalReason: ProviderPreparationTerminalReason?
    public var accessibleStatus: String

    public init(
        phase: ProviderPreparationPhase = .accepting,
        generation: UInt64 = 0,
        draftMessageId: String? = nil,
        acceptedAtMs: Int64? = nil,
        terminalReason: ProviderPreparationTerminalReason? = nil,
        accessibleStatus: String = "Ready"
    ) {
        self.phase = phase
        self.generation = generation
        self.draftMessageId = draftMessageId
        self.acceptedAtMs = acceptedAtMs
        self.terminalReason = terminalReason
        self.accessibleStatus = accessibleStatus
    }
}

public enum ProviderPreparationEvent: Sendable, Equatable {
    case accept(draftMessageId: String, atMs: Int64)
    case preparationFinished
    case providerSpawned
    case providerRunning
    case stopRequested
    case providerFinished(ProviderPreparationTerminalReason)
    case lateCallback(generation: UInt64)
}

public struct ProviderPreparationTransition: Sendable, Equatable {
    public var state: ProviderPreparationState
    public var allowProviderSpawn: Bool
    public var suppressLateCallback: Bool
    public var clearComposer: Bool
    public var ignoredReason: String?

    public init(
        state: ProviderPreparationState,
        allowProviderSpawn: Bool = false,
        suppressLateCallback: Bool = false,
        clearComposer: Bool = false,
        ignoredReason: String? = nil
    ) {
        self.state = state
        self.allowProviderSpawn = allowProviderSpawn
        self.suppressLateCallback = suppressLateCallback
        self.clearComposer = clearComposer
        self.ignoredReason = ignoredReason
    }
}

public enum ProviderPreparationStateMachine {
    public static func apply(
        state: ProviderPreparationState,
        event: ProviderPreparationEvent
    ) -> ProviderPreparationTransition {
        var next = state

        switch event {
        case .accept(let draftId, let atMs):
            guard state.phase == .accepting || state.phase == .terminal else {
                return ProviderPreparationTransition(state: state, ignoredReason: "not_accepting")
            }
            next.generation &+= 1
            next.phase = .preparing
            next.draftMessageId = draftId
            next.acceptedAtMs = atMs
            next.terminalReason = nil
            next.accessibleStatus = "Preparing"
            // Composer may clear only after draft identity is persisted (caller duty).
            return ProviderPreparationTransition(state: next, clearComposer: true)

        case .preparationFinished:
            guard state.phase == .preparing else {
                return ProviderPreparationTransition(state: state, ignoredReason: "not_preparing")
            }
            next.phase = .providerStarting
            next.accessibleStatus = "Starting provider"
            return ProviderPreparationTransition(state: next, allowProviderSpawn: true)

        case .providerSpawned:
            guard state.phase == .providerStarting else {
                return ProviderPreparationTransition(state: state, ignoredReason: "not_provider_starting")
            }
            next.phase = .running
            next.accessibleStatus = "Running"
            return ProviderPreparationTransition(state: next)

        case .providerRunning:
            guard state.phase == .providerStarting || state.phase == .running else {
                return ProviderPreparationTransition(state: state, ignoredReason: "invalid_running")
            }
            next.phase = .running
            next.accessibleStatus = "Running"
            return ProviderPreparationTransition(state: next)

        case .stopRequested:
            switch state.phase {
            case .preparing, .providerStarting:
                // Cancel preparation — never spawn.
                next.phase = .terminal
                next.terminalReason = .cancelled
                next.accessibleStatus = "Cancelled"
                next.generation &+= 1
                return ProviderPreparationTransition(state: next, allowProviderSpawn: false)
            case .running:
                next.phase = .stopping
                next.accessibleStatus = "Stopping"
                return ProviderPreparationTransition(state: next)
            case .stopping, .terminal, .accepting:
                return ProviderPreparationTransition(state: state, ignoredReason: "stop_noop")
            }

        case .providerFinished(let reason):
            guard state.phase == .running || state.phase == .stopping || state.phase == .providerStarting else {
                return ProviderPreparationTransition(state: state, ignoredReason: "not_live")
            }
            next.phase = .terminal
            next.terminalReason = reason
            next.accessibleStatus = {
                switch reason {
                case .completed: return "Completed"
                case .cancelled: return "Cancelled"
                case .failed, .providerFailure: return "Failed"
                case .durabilityFailure: return "Durability failure"
                }
            }()
            return ProviderPreparationTransition(state: next)

        case .lateCallback(let generation):
            if generation != state.generation {
                return ProviderPreparationTransition(
                    state: state,
                    suppressLateCallback: true,
                    ignoredReason: "stale_generation"
                )
            }
            if state.phase == .terminal || state.phase == .accepting {
                return ProviderPreparationTransition(
                    state: state,
                    suppressLateCallback: true,
                    ignoredReason: "already_terminal"
                )
            }
            return ProviderPreparationTransition(state: state)
        }
    }

    /// UI must not announce Running before provider ownership (phase >= running).
    public static func isRunningAnnounced(_ state: ProviderPreparationState) -> Bool {
        state.phase == .running || state.phase == .stopping
    }

    public static func maySpawnProvider(_ state: ProviderPreparationState) -> Bool {
        state.phase == .providerStarting
    }
}
