import Foundation

/// Wave D command families / code structure / evidence graph / validation recipes (task-20). Default OFF.
public enum TokenSaverWaveDFamilies {
    public static let taskID = "task-20"
    public static let defaultEnabled = false
}

public final class TokenSaverWaveDRuntime: @unchecked Sendable {
    public static let taskID = "task-20"

    public enum Admit: String, Sendable {
        case admitted
        case notLive
        case unknownSubcommand
        case mutant
        case liveTerminalNoBuffer
        case latestReadOrPatchForcesRaw
        case graphDegraded
        case networkedRecipe
        case ambiguousMapping
        case mlxInventedShell
        case validationFailed
        case packageManagerAutoWrapAbsent
    }

    private let lock = NSLock()
    private var _live = TokenSaverWaveDFamilies.defaultEnabled
    private var validationFailed = false
    private let allowlistedSubcommands: Set<String> = [
        "test", "build", "lint", "typecheck", "format-check"
    ]

    public init() {}

    public var live: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _live }
        set { lock.lock(); _live = newValue; lock.unlock() }
    }

    public func admitCommand(subcommand: String, isMutating: Bool) -> Admit {
        lock.lock(); let isLive = _live; lock.unlock()
        guard isLive else { return .notLive }
        if isMutating { return .mutant }
        if !allowlistedSubcommands.contains(subcommand) { return .unknownSubcommand }
        return .admitted
    }

    /// Live terminal never buffers for compression (AC-02).
    public func mayBufferLiveTerminal() -> Bool { false }

    public func codeStructureView(isLatestRead: Bool, isPatchTarget: Bool) -> Admit {
        lock.lock(); let isLive = _live; lock.unlock()
        guard isLive else { return .notLive }
        if isLatestRead || isPatchTarget { return .latestReadOrPatchForcesRaw }
        return .admitted
    }

    public func evidenceGraph(lspStale: Bool, coverageOK: Bool) -> Admit {
        lock.lock(); let isLive = _live; lock.unlock()
        guard isLive else { return .notLive }
        if lspStale || !coverageOK { return .graphDegraded }
        return .admitted
    }

    public func validationRecipe(networked: Bool, mutating: Bool, mappingAmbiguous: Bool) -> Admit {
        lock.lock(); let isLive = _live; lock.unlock()
        guard isLive else { return .notLive }
        if networked { return .networkedRecipe }
        if mutating { return .mutant }
        if mappingAmbiguous { return .ambiguousMapping }
        return .admitted
    }

    public func mlxMayInventShell() -> Bool { false }

    public func recordValidationFailure() {
        lock.lock(); validationFailed = true; lock.unlock()
    }

    public func taskDoneAllowed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !_live { return true } // fail-open
        return !validationFailed
    }

    /// Guard: broad package-manager auto-wrap is intentionally absent (AC-08).
    public static let packageManagerAutoWrapEnabled = false
}
