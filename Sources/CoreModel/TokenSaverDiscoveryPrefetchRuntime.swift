import Foundation

/// Host-owned local_discovery_prefetch runtime (task-17). Default OFF.
/// MLX may only classify allowlisted recipes; host validates resolved workspace paths.
public final class TokenSaverDiscoveryPrefetchRuntime: @unchecked Sendable {
    public static let taskID = "task-17"
    public static let defaultDeadlineMs: Int = 250

    public enum Recipe: String, Sendable, CaseIterable {
        case gitStatus = "git_status"
        case rgWorkspace = "rg_workspace"
        case listPanes = "list_panes"
        case fsStat = "fs_stat"

        public var isReadOnly: Bool { true }
        public var allowsNetwork: Bool { false }

        public func argv(relativePath: String?) -> [String]? {
            // Reject option-like paths that could be interpreted as flags (e.g. --pre=CMD).
            if let relativePath, relativePath.hasPrefix("-") {
                return nil
            }
            switch self {
            case .gitStatus:
                return ["git", "status", "--porcelain"]
            case .rgWorkspace:
                let path = relativePath ?? "."
                // `--` ends option parsing so path cannot inject rg flags.
                return ["rg", "--no-heading", "--line-number", "--color", "never", "--", ".", path]
            case .listPanes:
                return ["rc2", "panes", "list"]
            case .fsStat:
                let path = relativePath ?? "."
                return ["stat", "-f", "%N %z", "--", path]
            }
        }
    }

    public static let allowlistedRecipes: Set<String> = Set(Recipe.allCases.map(\.rawValue))

    public struct RecipeRequest: Sendable, Equatable {
        public let name: String
        public let pathArgument: String?
        public let mlxProposedMutation: Bool

        public init(name: String, pathArgument: String? = nil, mlxProposedMutation: Bool = false) {
            self.name = name
            self.pathArgument = pathArgument
            self.mlxProposedMutation = mlxProposedMutation
        }
    }

    public enum Admit: String, Sendable, Equatable {
        case admitted
        case notLive
        case notAllowlisted
        case networkDenied
        case outOfWorkspace
        case mlxMutationRejected
        case recipeNotReadOnly
        case deadlineExceeded
    }

    public struct ExecutionReceipt: Sendable, Equatable {
        public let recipe: String
        public let path: String
        public let line: Int?
        public let digest: String
        public let exitCode: Int
        public let argv: [String]
        public let selected: Bool
        /// Only set true via `markUsed` when host proves consumption (digest match).
        public let used: Bool
        /// Ledger operation bound at markUsed — usefulness only credits this op.
        public let boundOperationDigest: String
    }

    public protocol HostRunner: AnyObject {
        func run(argv: [String], cwd: String) -> (exitCode: Int, stdoutDigest: String)
    }

    public final class RecordingRunner: HostRunner, @unchecked Sendable {
        public private(set) var lastArgv: [String] = []
        public private(set) var lastCwd: String = ""
        public var exitCode: Int = 0
        public var digest: String = "d0"
        public init() {}
        public func run(argv: [String], cwd: String) -> (exitCode: Int, stdoutDigest: String) {
            lastArgv = argv
            lastCwd = cwd
            return (exitCode, digest)
        }
    }

    private let lock = NSLock()
    private var _live: Bool = TokenSaverTurnBatchPrefetch.defaultEnabled
    private var receipts: [String: ExecutionReceipt] = [:]
    private let runner: HostRunner
    private let workspaceRoot: String
    private let bindingDigest: String
    public var deadlineMs: Int = TokenSaverDiscoveryPrefetchRuntime.defaultDeadlineMs
    /// Clock for deadline tests (ms since epoch).
    public var nowMs: () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }

    public init(
        workspaceRoot: String,
        bindingDigest: String = "",
        runner: HostRunner = RecordingRunner()
    ) {
        self.workspaceRoot = Self.resolve(workspaceRoot)
        self.bindingDigest = bindingDigest.trimmingCharacters(in: .whitespacesAndNewlines)
        self.runner = runner
    }

    public var live: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _live }
        set { lock.lock(); _live = newValue; lock.unlock() }
    }

    /// Resolve symlinks then standardize — prevents in-workspace symlink escape.
    public static func resolve(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    public static func pathIsInsideWorkspace(path: String, workspaceRoot: String) -> Bool {
        let root = resolve(workspaceRoot)
        guard !root.isEmpty else { return false }
        let candidate = resolve(path)
        if candidate == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return candidate.hasPrefix(prefix)
    }

    public static func standardize(_ path: String) -> String { resolve(path) }

    public func admit(_ request: RecipeRequest, startedAtMs: Int? = nil) -> Admit {
        lock.lock()
        let isLive = _live
        let root = workspaceRoot
        let deadline = deadlineMs
        let now = nowMs()
        lock.unlock()
        guard isLive else { return .notLive }
        if let start = startedAtMs, now - start > deadline {
            return .deadlineExceeded
        }
        if request.mlxProposedMutation { return .mlxMutationRejected }
        guard let recipe = Recipe(rawValue: request.name) else { return .notAllowlisted }
        guard recipe.isReadOnly else { return .recipeNotReadOnly }
        guard !recipe.allowsNetwork else { return .networkDenied }
        if let rel = request.pathArgument {
            if rel.hasPrefix("-") { return .outOfWorkspace }
            let abs = rel.hasPrefix("/") ? rel : (root as NSString).appendingPathComponent(rel)
            guard Self.pathIsInsideWorkspace(path: abs, workspaceRoot: root) else {
                return .outOfWorkspace
            }
        }
        return .admitted
    }

    /// Host execute after admit. `used` starts false; host must call `markUsed` with digest proof.
    @discardableResult
    public func execute(
        _ request: RecipeRequest,
        selected: Bool,
        startedAtMs: Int? = nil
    ) -> ExecutionReceipt? {
        guard admit(request, startedAtMs: startedAtMs) == .admitted,
              let recipe = Recipe(rawValue: request.name) else {
            return nil
        }
        let root = workspaceRoot
        let pathArg = request.pathArgument
        var resolvedPathArg: String? = pathArg
        if let rel = pathArg {
            if rel.hasPrefix("-") { return nil }
            let abs = rel.hasPrefix("/") ? rel : (root as NSString).appendingPathComponent(rel)
            let resolved = Self.resolve(abs)
            guard Self.pathIsInsideWorkspace(path: resolved, workspaceRoot: root) else { return nil }
            // Pass resolved path to runner to avoid symlink-swap TOCTOU on the relative form.
            resolvedPathArg = resolved
        }
        guard let argv = recipe.argv(relativePath: resolvedPathArg.map {
            // Prefer workspace-relative when possible; absolute resolved path is safe after `--`.
            $0
        }) else { return nil }
        if argv.contains(where: { $0.contains("http://") || $0.contains("https://") || $0 == "--network" }) {
            return nil
        }
        let start = startedAtMs ?? nowMs()
        let (code, digest) = runner.run(argv: argv, cwd: root)
        // Deadline must hold through execution, not only admit.
        if nowMs() - start > deadlineMs {
            return nil
        }
        let receipt = ExecutionReceipt(
            recipe: recipe.rawValue,
            path: resolvedPathArg ?? root,
            line: nil,
            digest: digest,
            exitCode: code,
            argv: argv,
            selected: selected,
            used: false,
            boundOperationDigest: ""
        )
        lock.lock()
        receipts[recipe.rawValue] = receipt
        lock.unlock()
        return receipt
    }

    /// Prove provider-turn consumption: digest must match stored receipt and
    /// must match the ledger measurement's evidenceDigest for operationDigest.
    @discardableResult
    public func markUsed(
        recipe: String,
        consumedDigest: String,
        ledger: TokenSaverAccountingV2.Ledger,
        operationDigest: String
    ) -> Bool {
        lock.lock()
        guard let rec = receipts[recipe],
              rec.digest == consumedDigest,
              !consumedDigest.isEmpty,
              !operationDigest.isEmpty else {
            lock.unlock()
            return false
        }
        lock.unlock()
        guard let snap = ledger.measuredSnapshot(for: operationDigest),
              snap.evidenceDigest == consumedDigest,
              !bindingDigest.isEmpty,
              snap.bindingDigest == bindingDigest,
              !snap.evidenceDigest.isEmpty else {
            return false
        }
        lock.lock()
        receipts[recipe] = ExecutionReceipt(
            recipe: rec.recipe,
            path: rec.path,
            line: rec.line,
            digest: rec.digest,
            exitCode: rec.exitCode,
            argv: rec.argv,
            selected: rec.selected,
            used: true,
            boundOperationDigest: operationDigest
        )
        lock.unlock()
        return true
    }

    public func lastReceipt(for recipe: String) -> ExecutionReceipt? {
        lock.lock(); defer { lock.unlock() }
        return receipts[recipe]
    }

    public func mlxMayClassify(_ recipeName: String, proposesMutation: Bool) -> Bool {
        !proposesMutation && Recipe(rawValue: recipeName) != nil
    }

    public func mlxMayMutate() -> Bool { false }

    /// Credit only when runtime is live, markUsed bound this recipe to a ledger op whose
    /// evidenceDigest matches the prefetch digest. Caller cannot supply a free operationDigest.
    public func usefulnessCredit(
        recipe: String,
        ledger: TokenSaverAccountingV2.Ledger
    ) -> Int64 {
        lock.lock()
        let isLive = _live
        let receipt = receipts[recipe]
        lock.unlock()
        guard isLive else { return 0 }
        guard let receipt, receipt.used, !receipt.boundOperationDigest.isEmpty else { return 0 }
        guard let snap = ledger.measuredSnapshot(for: receipt.boundOperationDigest),
              snap.evidenceDigest == receipt.digest,
              !bindingDigest.isEmpty,
              snap.bindingDigest == bindingDigest else { return 0 }
        guard let measured = TokenSaverRecoveryProjections.ReceiptFactory.fromLocalLedger(
            ledger: ledger,
            operationDigest: receipt.boundOperationDigest
        ) else { return 0 }
        return TokenSaverRecoveryProjections.admitPrefetchSavings(
            used: true,
            receipt: measured,
            creditBindingDigest: bindingDigest,
            live: true
        )
    }
}
