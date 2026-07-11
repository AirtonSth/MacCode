import Foundation

public enum PetCareAction: String, CaseIterable, Sendable, Equatable {
    case feed
    case giveWater
    case pet
    case play
    case cheerUp

    public var title: String {
        switch self {
        case .feed: return "Feed"
        case .giveWater: return "Give water"
        case .pet: return "Pet"
        case .play: return "Play"
        case .cheerUp: return "Cheer up"
        }
    }

    var animationState: PetAnimationState {
        switch self {
        case .feed: return .eating
        case .giveWater: return .drinking
        case .pet: return .purring
        case .play: return .playing
        case .cheerUp: return .comfort
        }
    }
}

public struct PetCompanionCue: Sendable, Equatable {
    public let state: PetAnimationState
    public let returnState: PetAnimationState

    public init(state: PetAnimationState, returnState: PetAnimationState) {
        self.state = state
        self.returnState = returnState
    }
}

public struct PetCompanionEligibility: Sendable, Equatable {
    public let baseState: PetAnimationState
    public let attentionCount: Int
    public let activeRunCount: Int
    public let isVisible: Bool
    public let animationsEnabled: Bool
    public let reducedMotion: Bool
    public let screenLocked: Bool

    public init(
        baseState: PetAnimationState,
        attentionCount: Int,
        activeRunCount: Int,
        isVisible: Bool,
        animationsEnabled: Bool,
        reducedMotion: Bool,
        screenLocked: Bool
    ) {
        self.baseState = baseState
        self.attentionCount = max(0, attentionCount)
        self.activeRunCount = max(0, activeRunCount)
        self.isVisible = isVisible
        self.animationsEnabled = animationsEnabled
        self.reducedMotion = reducedMotion
        self.screenLocked = screenLocked
    }

    private var allowsCompanionMotion: Bool {
        isVisible && animationsEnabled && !reducedMotion && !screenLocked && attentionCount == 0
    }

    var allowsAmbientCue: Bool {
        allowsCompanionMotion && activeRunCount == 0 && baseState == .idle
    }

    var allowsWorkCue: Bool {
        guard allowsCompanionMotion, activeRunCount > 0 else { return false }
        switch baseState {
        case .coding, .editing, .terminal, .search, .gitReview, .thinking, .listening:
            return true
        default:
            return false
        }
    }
}

public struct PetCompanionDirector: Sendable {
    public static let ambientDelayRange = 300...600
    public static let workDelayRange = 25...50

    private static let ambientStates: [PetAnimationState] = [
        .idleBall, .idleScratch, .idleGroom, .idleStretch,
        .idleBox, .idleButterfly, .eating,
    ]
    private static let workStates: [PetAnimationState] = [
        .workingMouse, .workingBug, .workingEngineer,
    ]

    private var lastAmbientState: PetAnimationState?
    private var lastWorkState: PetAnimationState?
    private var successfulOutcomeCount = 0

    public init() {}

    public mutating func nextAmbientCue(
        eligibility: PetCompanionEligibility,
        preferredIndex: Int
    ) -> PetCompanionCue? {
        guard eligibility.allowsAmbientCue else { return nil }
        let state = Self.nonRepeatingState(
            from: Self.ambientStates,
            preferredIndex: preferredIndex,
            previous: lastAmbientState
        )
        lastAmbientState = state
        return PetCompanionCue(state: state, returnState: eligibility.baseState)
    }

    public mutating func nextWorkCue(
        eligibility: PetCompanionEligibility,
        preferredIndex: Int
    ) -> PetCompanionCue? {
        guard eligibility.allowsWorkCue else { return nil }
        let state = Self.nonRepeatingState(
            from: Self.workStates,
            preferredIndex: preferredIndex,
            previous: lastWorkState
        )
        lastWorkState = state
        return PetCompanionCue(state: state, returnState: eligibility.baseState)
    }

    public mutating func notificationCue(
        previousCount: Int,
        newCount: Int,
        baseState: PetAnimationState
    ) -> PetCompanionCue? {
        guard previousCount == 0, newCount > 0, baseState != .approval, baseState != .question else {
            return nil
        }
        return PetCompanionCue(state: .notificationPounce, returnState: baseState)
    }

    public mutating func successCue(returnState: PetAnimationState) -> PetCompanionCue? {
        successfulOutcomeCount += 1
        guard successfulOutcomeCount.isMultiple(of: 3) else { return nil }
        return PetCompanionCue(state: .celebrateTreat, returnState: returnState)
    }

    public static func careCue(
        action: PetCareAction,
        returnState: PetAnimationState
    ) -> PetCompanionCue {
        PetCompanionCue(state: action.animationState, returnState: returnState)
    }

    private static func nonRepeatingState(
        from states: [PetAnimationState],
        preferredIndex: Int,
        previous: PetAnimationState?
    ) -> PetAnimationState {
        let normalizedIndex = ((preferredIndex % states.count) + states.count) % states.count
        let candidate = states[normalizedIndex]
        guard candidate == previous else { return candidate }
        return states[(normalizedIndex + 1) % states.count]
    }
}
