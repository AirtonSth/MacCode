import Foundation

/// Wave D command families / code structure / evidence graph / validation recipes (task-20). Default OFF.
public enum TokenSaverWaveDFamilies {
    public static let taskID = "task-20"
    public static let defaultEnabled = false
}

/// Host-owned Wave D runtime. Bound user + binding digest required for admission.
public final class TokenSaverWaveDRuntime: @unchecked Sendable {
    public static let taskID = "task-20"

    public enum Admit: String, Sendable, Error {
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
        case userMismatch
        case bindingMismatch
        case missingStructureOriginal
        case missingProvenance
    }

    /// Closed command family — not free-form argv strings from callers.
    public enum FamilyCommand: String, Sendable, CaseIterable {
        case test
        case build
        case lint
        case typecheck
        case formatCheck = "format-check"

        /// Side-effect class derived from the closed family (not caller-asserted).
        public var isMutating: Bool { false }

        /// Broad package-manager wrap families are intentionally absent.
        public static let packageManagerWrapCommands: Set<String> = [
            "npm", "yarn", "pnpm", "pip", "cargo", "brew", "apt", "pod"
        ]
    }

    public struct StructureView: Sendable, Equatable {
        public let handle: String
        public let marker: String
        public let language: String
        public let lineMapDigest: String
    }

    public struct GraphProvenance: Sendable, Equatable {
        public let sourceDigest: String
        public let coverageDigest: String
        public let lspGeneration: UInt64
    }

    public let boundUserID: String
    public let bindingDigest: String
    private let lock = NSLock()
    private var _live = TokenSaverWaveDFamilies.defaultEnabled
    private var validationFailed = false
    private var structureOriginals: [String: Data] = [:]

    public init(boundUserID: String, bindingDigest: String) {
        self.boundUserID = boundUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bindingDigest = bindingDigest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var live: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _live }
        set { lock.lock(); _live = newValue; lock.unlock() }
    }

    private func authorize(requestingUserID: String, bindingDigest: String) -> Admit? {
        let u = requestingUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = bindingDigest.trimmingCharacters(in: .whitespacesAndNewlines)
        if boundUserID.isEmpty || u != boundUserID { return .userMismatch }
        if self.bindingDigest.isEmpty || b != self.bindingDigest { return .bindingMismatch }
        return nil
    }

    public func admitCommand(
        _ command: FamilyCommand,
        requestingUserID: String,
        bindingDigest: String
    ) -> Admit {
        lock.lock(); let isLive = _live; lock.unlock()
        guard isLive else { return .notLive }
        if let deny = authorize(requestingUserID: requestingUserID, bindingDigest: bindingDigest) {
            return deny
        }
        // Closed family never mutates; package-manager wrap strings are not representable.
        if FamilyCommand.packageManagerWrapCommands.contains(command.rawValue) {
            return .packageManagerAutoWrapAbsent
        }
        if command.isMutating { return .mutant }
        return .admitted
    }

    /// Reject free-form subcommand strings that look like package-manager wrap.
    public func admitRawSubcommand(
        _ subcommand: String,
        requestingUserID: String,
        bindingDigest: String
    ) -> Admit {
        let s = subcommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if FamilyCommand.packageManagerWrapCommands.contains(s) {
            return .packageManagerAutoWrapAbsent
        }
        guard let cmd = FamilyCommand(rawValue: s) else { return .unknownSubcommand }
        return admitCommand(cmd, requestingUserID: requestingUserID, bindingDigest: bindingDigest)
    }

    /// Live terminal never buffers for compression (AC-02).
    public func mayBufferLiveTerminal() -> Bool { false }

    /// Structure view requires store-before-loss of original bytes + language + line map digest.
    public func codeStructureView(
        original: Data,
        language: String,
        lineMapDigest: String,
        isLatestRead: Bool,
        isPatchTarget: Bool,
        requestingUserID: String,
        bindingDigest: String
    ) -> Result<StructureView, Admit> {
        lock.lock(); defer { lock.unlock() }
        guard _live else { return .failure(.notLive) }
        if let deny = authorize(requestingUserID: requestingUserID, bindingDigest: bindingDigest) {
            return .failure(deny)
        }
        if isLatestRead || isPatchTarget { return .failure(.latestReadOrPatchForcesRaw) }
        let lang = language.trimmingCharacters(in: .whitespacesAndNewlines)
        let map = lineMapDigest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, !lang.isEmpty, !map.isEmpty else {
            return .failure(.missingStructureOriginal)
        }
        let handle = "struct-\(map.prefix(12))"
        structureOriginals[handle] = original
        // Verify store
        guard structureOriginals[handle] == original else {
            return .failure(.missingStructureOriginal)
        }
        return .success(StructureView(
            handle: handle,
            marker: "[[rc:\(handle)]]",
            language: lang,
            lineMapDigest: map
        ))
    }

    public func retrieveStructureOriginal(handle: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return structureOriginals[handle]
    }

    public func evidenceGraph(
        provenance: GraphProvenance?,
        lspStale: Bool,
        requestingUserID: String,
        bindingDigest: String
    ) -> Admit {
        lock.lock(); let isLive = _live; lock.unlock()
        guard isLive else { return .notLive }
        if let deny = authorize(requestingUserID: requestingUserID, bindingDigest: bindingDigest) {
            return deny
        }
        guard let provenance,
              !provenance.sourceDigest.isEmpty,
              !provenance.coverageDigest.isEmpty else {
            return .missingProvenance
        }
        if lspStale { return .graphDegraded }
        return .admitted
    }

    public func validationRecipe(
        networked: Bool,
        mappingAmbiguous: Bool,
        requestingUserID: String,
        bindingDigest: String
    ) -> Admit {
        lock.lock(); let isLive = _live; lock.unlock()
        guard isLive else { return .notLive }
        if let deny = authorize(requestingUserID: requestingUserID, bindingDigest: bindingDigest) {
            return deny
        }
        if networked { return .networkedRecipe }
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
