import Foundation

/// Wave C rollover / handoff / lossy / verbosity / visual (task-19). Default OFF.
public enum TokenSaverRolloverHandoff {
    public static let taskID = "task-19"
    public static let defaultEnabled = false
}

public final class TokenSaverRolloverHandoffRuntime: @unchecked Sendable {
    public static let taskID = "task-19"

    public enum ForkKind: String, Sendable { case manual, rollover }

    public struct ForkOperationID: Sendable, Equatable, Hashable {
        public let id: String
        public let parentHead: String
        public let kind: ForkKind
        public init(id: String = UUID().uuidString, parentHead: String, kind: ForkKind) {
            self.id = id
            self.parentHead = parentHead
            self.kind = kind
        }
    }

    public enum ParentState: String, Sendable {
        case parentActive
        case childPrepared
        case childActivated
        case cancelled
        case fenced
    }

    public struct Branch: Sendable, Equatable {
        public let forkID: ForkOperationID
        public let runAsUser: String
        public let childHead: String
    }

    private let lock = NSLock()
    private var _live = TokenSaverRolloverHandoff.defaultEnabled
    private var parentState: ParentState = .parentActive
    private var branches: [String: Branch] = [:] // fork id -> branch
    private var replayed: Set<String> = []
    private var lossyValidatorPresent = false
    private var handoffConsent = false
    private var handoffDestinationBinding = ""

    public init() {}

    public var live: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _live }
        set { lock.lock(); _live = newValue; lock.unlock() }
    }

    public func setLossyValidatorPresent(_ v: Bool) {
        lock.lock(); lossyValidatorPresent = v; lock.unlock()
    }

    public func setHandoff(consent: Bool, destinationBinding: String) {
        lock.lock()
        handoffConsent = consent
        handoffDestinationBinding = destinationBinding.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()
    }

    /// Two manuals on same parent head → distinct IDs/branches. Replay reuses same ForkOperationID.
    public func fork(
        op: ForkOperationID,
        runAsUser: String,
        replay: Bool = false
    ) -> Branch? {
        lock.lock(); defer { lock.unlock() }
        guard _live else { return nil }
        if replay {
            if let existing = branches[op.id] { return existing }
            // first replay recording
        } else if branches[op.id] != nil {
            return branches[op.id]
        }
        if op.kind == .manual {
            // Manual keeps parent active; never inherits rollover fence as active fence for new manuals
            if parentState == .fenced && op.kind == .manual {
                // Manual still allowed but parent stays fenced for new turns (AC-03)
            }
        } else {
            // Rollover path
            if parentState == .fenced { return nil }
            parentState = .childPrepared
        }
        let child = Branch(
            forkID: op,
            runAsUser: runAsUser,
            childHead: "child-\(op.id.prefix(8))"
        )
        branches[op.id] = child
        if op.kind == .rollover {
            parentState = .childActivated
            // Fence parent for new turns
            parentState = .fenced
        }
        return child
    }

    public func parentAllowsNewTurns() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard _live else { return true } // fail-open when OFF
        return parentState != .fenced
    }

    public func parentStateValue() -> ParentState {
        lock.lock(); defer { lock.unlock() }
        return parentState
    }

    /// Lossy lanes require validator + corpus (AC-05).
    public func admitLossy(corpusOK: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _live && lossyValidatorPresent && corpusOK
    }

    public func rejectCriticalSuppression(bound: Int, candidate: Int) -> Bool {
        candidate > bound // true means reject
    }

    public func admitHandoff() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _live && handoffConsent && !handoffDestinationBinding.isEmpty
    }

    /// Verbosity never changes reasoning effort or already-generated text.
    public func applyVerbosity(toGenerated text: String, level: String) -> String {
        _ = level
        return text
    }

    public func visualForcesOriginal(isOCR: Bool, isUI: Bool, isDebug: Bool) -> Bool {
        isOCR || isUI || isDebug
    }
}
