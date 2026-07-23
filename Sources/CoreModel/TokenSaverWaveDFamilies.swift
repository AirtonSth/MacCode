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
        case handleCollision
        case durableRequired
    }

    public enum FamilyCommand: String, Sendable, CaseIterable {
        case test
        case build
        case lint
        case typecheck
        case formatCheck = "format-check"

        public var isMutating: Bool { false }

        public static let packageManagerWrapCommands: Set<String> = [
            "npm", "yarn", "pnpm", "pip", "cargo", "brew", "apt", "pod"
        ]
    }

    public struct StructureView: Sendable, Equatable {
        public let handle: String
        public let marker: String
        public let language: String
        public let lineMapDigest: String

        public init(handle: String, marker: String, language: String, lineMapDigest: String) {
            self.handle = handle
            self.marker = marker
            self.language = language
            self.lineMapDigest = lineMapDigest
        }
    }

    public struct GraphProvenance: Sendable, Equatable {
        public let sourceDigest: String
        public let coverageDigest: String
        public let path: String
        public let startLine: Int
        public let endLine: Int
        public let lspGeneration: UInt64

        public init(
            sourceDigest: String,
            coverageDigest: String,
            path: String,
            startLine: Int,
            endLine: Int,
            lspGeneration: UInt64
        ) {
            self.sourceDigest = sourceDigest
            self.coverageDigest = coverageDigest
            self.path = path
            self.startLine = startLine
            self.endLine = endLine
            self.lspGeneration = lspGeneration
        }

        public var isValid: Bool {
            let s = sourceDigest.trimmingCharacters(in: .whitespacesAndNewlines)
            let c = coverageDigest.trimmingCharacters(in: .whitespacesAndNewlines)
            let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
            return !s.isEmpty && !c.isEmpty && !p.isEmpty
                && startLine > 0 && endLine >= startLine
                && lspGeneration > 0
        }
    }

    public let boundUserID: String
    public let bindingDigest: String
    private let durableRoot: URL?
    private let lock = NSLock()
    private var _live = TokenSaverWaveDFamilies.defaultEnabled
    private var validationFailed = false
    private var structureOriginals: [String: Data] = [:]

    public init(boundUserID: String, bindingDigest: String, durableDirectory: URL? = nil) {
        self.boundUserID = boundUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bindingDigest = bindingDigest.trimmingCharacters(in: .whitespacesAndNewlines)
        self.durableRoot = durableDirectory
        if let dir = durableDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
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
        if FamilyCommand.packageManagerWrapCommands.contains(command.rawValue) {
            return .packageManagerAutoWrapAbsent
        }
        if command.isMutating { return .mutant }
        return .admitted
    }

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

    public func mayBufferLiveTerminal() -> Bool { false }

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
        // Unique handle: UUID (no collision / no overwrite of prior originals).
        let handle = UUID().uuidString
        // Durable store required for store-before-loss across relaunch.
        guard let root = durableRoot else { return .failure(.durableRequired) }
        let url = self.fileURL(root: root, handle: handle)
        if FileManager.default.fileExists(atPath: url.path) { return .failure(.handleCollision) }
        do {
            try original.write(to: url, options: [.withoutOverwriting])
        } catch {
            return .failure(.missingStructureOriginal)
        }
        guard let readback = try? Data(contentsOf: url), readback == original else {
            try? FileManager.default.removeItem(at: url)
            return .failure(.missingStructureOriginal)
        }
        structureOriginals[handle] = original
        return .success(StructureView(
            handle: handle,
            marker: "[[rc:\(handle)]]",
            language: lang,
            lineMapDigest: map
        ))
    }

    public func retrieveStructureOriginal(
        handle: String,
        requestingUserID: String,
        bindingDigest: String
    ) -> Data? {
        lock.lock(); defer { lock.unlock() }
        if authorize(requestingUserID: requestingUserID, bindingDigest: bindingDigest) != nil {
            return nil
        }
        let h = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let mem = structureOriginals[h] { return mem }
        guard let root = durableRoot else { return nil }
        return try? Data(contentsOf: fileURL(root: root, handle: h))
    }

    private func fileURL(root: URL, handle: String) -> URL {
        // Scope durable key by user + binding so another runtime cannot read across identity.
        let key = "\(boundUserID)|\(bindingDigest)|\(handle)"
        let safe = Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return root.appendingPathComponent(safe)
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
        guard let provenance, provenance.isValid else { return .missingProvenance }
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
        if !_live { return true }
        return !validationFailed
    }

    public static let packageManagerAutoWrapEnabled = false
}
