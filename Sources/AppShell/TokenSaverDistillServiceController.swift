import AgentRuntime
import CoreModel
import DistillCore
import Foundation
import Persistence

// MARK: - Notification names

public extension Notification.Name {
    /// Posted on the main actor whenever `TokenSaverDistillServiceController.status`
    /// changes. Observers (e.g. SidebarViewModel) can subscribe to refresh UI that
    /// shows the sidecar running / warming / blocked / failed state.
    /// The `object` of the notification is the controller instance.
    static let rc2TokenSaverDistillStatusChanged = Notification.Name("rc2TokenSaverDistillStatusChanged")
}

// MARK: - Status display helpers

/// Pure, nonisolated display helpers for `TokenSaverDistillServiceStatus`.
/// Used by UI layers (e.g. the Token Saver details popover) and by log output
/// to produce stable, ASCII-only human-readable labels without importing AppKit.
public extension TokenSaverDistillServiceStatus {
    /// Short, human-readable label suitable for a status row label or pill.
    /// ASCII-only; never contains smart quotes.
    var displayLabel: String {
        switch self {
        case .notStarted: return "not running"
        case .starting:   return "warming up"
        case .running:    return "running"
        case .blocked:    return "blocked"
        case .failed:     return "failed"
        }
    }

    /// Optional supplementary reason string shown beneath the label.
    /// Non-nil for `.blocked` and `.failed` states; nil for transient/healthy states.
    var displayReason: String? {
        switch self {
        case .blocked(let reason): return reason
        case .failed(let reason):  return reason
        default:                   return nil
        }
    }

    /// True when the sidecar is actively serving requests.
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// True when the sidecar is in a terminal non-operational state (blocked or
    /// failed) and compression requests will fall through to the local fallback.
    var isOperationallyBlocked: Bool {
        switch self {
        case .blocked, .failed: return true
        default:                return false
        }
    }
}

public enum TokenSaverDistillLaunchDecision: Sendable, Equatable {
    case start
    case skip(reason: String)
    case requireModel(reason: String?)
}

public struct TokenSaverDistillLaunchInput: Sendable, Equatable {
    public let hasPrivateAccount: Bool
    public let isSubscribed: Bool
    public let tokenSaverEnabled: Bool
    public let modelValidation: TokenSaverModelValidation
    public let allowsExternalGenerate: Bool

    public init(
        hasPrivateAccount: Bool,
        isSubscribed: Bool,
        tokenSaverEnabled: Bool,
        modelValidation: TokenSaverModelValidation,
        allowsExternalGenerate: Bool = false
    ) {
        self.hasPrivateAccount = hasPrivateAccount
        self.isSubscribed = isSubscribed
        self.tokenSaverEnabled = tokenSaverEnabled
        self.modelValidation = modelValidation
        self.allowsExternalGenerate = allowsExternalGenerate
    }
}

public enum TokenSaverDistillLaunchPlanner {
    public static func decide(_ input: TokenSaverDistillLaunchInput) -> TokenSaverDistillLaunchDecision {
        guard input.hasPrivateAccount else {
            return .skip(reason: "private account not signed in")
        }
        guard input.isSubscribed else {
            return .skip(reason: "subscription required")
        }
        guard input.tokenSaverEnabled else {
            return .skip(reason: "token saver disabled")
        }
        if !input.allowsExternalGenerate {
            guard input.modelValidation.state == .installed else {
                return .requireModel(reason: input.modelValidation.reason)
            }
        }
        return .start
    }
}

public enum TokenSaverDistillServiceStatus: Sendable, Equatable {
    case notStarted
    case blocked(String)
    case starting
    case running(DistillServiceReadyEvent)
    case failed(String)
}

/// Pure state-transition logic for the Token Saver sidecar supervisor.
///
/// Extracted so the health/restart/deadlock-recovery decisions are testable
/// without launching a real `Process` (Rule 8). The controller owns the side
/// effects (process launch, timers, status assignment); this struct owns the
/// "given current status + event, what is the next status / should we restart /
/// how long to back off" decision.
public enum TokenSaverDistillSupervisor {
    /// Lifecycle events the controller feeds to the supervisor.
    public enum Event: Sendable, Equatable {
        /// The sidecar process terminated. `wasUserStop` is true when `stop()`
        /// initiated the termination (so we must NOT auto-restart).
        case processExited(wasUserStop: Bool)
        /// The startup stdout stream hit EOF while the process is no longer
        /// running — the ready event will never arrive. Caps the startup wait.
        case startupEOFWhileDead
        /// An explicit user/eligibility stop. Resets to a clean idle status.
        case stopRequested
    }

    public struct Decision: Sendable, Equatable {
        public let nextStatus: TokenSaverDistillServiceStatus
        public let shouldRestart: Bool

        public init(nextStatus: TokenSaverDistillServiceStatus, shouldRestart: Bool) {
            self.nextStatus = nextStatus
            self.shouldRestart = shouldRestart
        }
    }

    /// Restart backoff schedule. Exponential, capped, attempt-indexed.
    public static let baseBackoffSeconds: Double = 1
    public static let maxBackoffSeconds: Double = 30
    /// After this many consecutive failed restarts, stop auto-restarting and
    /// surface a terminal `.failed` so the popover/poll loop fail loud instead
    /// of looping forever (Rule 6).
    public static let maxRestartAttempts = 5

    /// Exponential backoff for the Nth (0-indexed) restart attempt, capped.
    public static func backoffSeconds(forAttempt attempt: Int) -> Double {
        guard attempt > 0 else { return baseBackoffSeconds }
        let raw = baseBackoffSeconds * pow(2, Double(attempt))
        return min(raw, maxBackoffSeconds)
    }

    /// Decide the next status and whether to schedule an auto-restart.
    ///
    /// - Parameters:
    ///   - status: current controller status.
    ///   - event: the lifecycle event.
    ///   - restartAttempts: how many consecutive auto-restarts have already
    ///     been scheduled (used to cap retries).
    public static func decide(
        status: TokenSaverDistillServiceStatus,
        event: Event,
        restartAttempts: Int
    ) -> Decision {
        switch event {
        case .stopRequested:
            // A stop is authoritative from ANY state: reset to idle so a stuck
            // `.starting`/`.failed`/`.running` never persists across restarts.
            return Decision(nextStatus: .notStarted, shouldRestart: false)

        case .processExited(let wasUserStop):
            // User-initiated termination is handled by `stop()` directly.
            if wasUserStop {
                return Decision(nextStatus: .notStarted, shouldRestart: false)
            }
            // Unexpected exit while blocked means eligibility already gated it
            // off — do not resurrect.
            if case .blocked = status {
                return Decision(nextStatus: status, shouldRestart: false)
            }
            if restartAttempts >= maxRestartAttempts {
                return Decision(
                    nextStatus: .failed("RemoteCodeDistillService exited; restart limit reached"),
                    shouldRestart: false
                )
            }
            // Downgrade out of `.running`/`.starting` and schedule a restart.
            return Decision(
                nextStatus: .failed("RemoteCodeDistillService exited; restarting"),
                shouldRestart: true
            )

        case .startupEOFWhileDead:
            // Caps the startup wait: a dead process that emitted no ready event
            // must transition out of `.starting`, otherwise the consumer polls
            // for the full 60s window.
            guard case .starting = status else {
                return Decision(nextStatus: status, shouldRestart: false)
            }
            if restartAttempts >= maxRestartAttempts {
                return Decision(
                    nextStatus: .failed("RemoteCodeDistillService exited during startup; restart limit reached"),
                    shouldRestart: false
                )
            }
            return Decision(
                nextStatus: .failed("RemoteCodeDistillService exited during startup; restarting"),
                shouldRestart: true
            )
        }
    }
}

public enum TokenSaverDistillFailureReasonFormatter {
    private static let serviceFailurePrefix = "RemoteCodeDistillService failed:"
    private static let maxDiagnosticCharacters = 220

    public static func appendDiagnostic(to reason: String, stderrLine: String?) -> String {
        guard let diagnostic = sanitizedDiagnostic(from: stderrLine) else { return reason }
        guard !reason.contains(diagnostic) else { return reason }
        return "\(reason): \(diagnostic)"
    }

    public static func sanitizedDiagnostic(from stderrLine: String?) -> String? {
        guard let stderrLine else { return nil }
        let candidates = stderrLine
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !$0.contains("MLX memory bounded") }
        guard var diagnostic = candidates.last else { return nil }
        if diagnostic.hasPrefix(serviceFailurePrefix) {
            diagnostic = String(diagnostic.dropFirst(serviceFailurePrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !diagnostic.isEmpty else { return nil }
        if diagnostic.count > maxDiagnosticCharacters {
            let cutoff = diagnostic.index(diagnostic.startIndex, offsetBy: maxDiagnosticCharacters)
            diagnostic = String(diagnostic[..<cutoff]) + "..."
        }
        return diagnostic
    }
}

/// Cached sha256 result keyed on (size, mtime) for a single model file.
///
/// The entry is considered valid only when both the file size and modification
/// timestamp match what was recorded at hash time. Any drift in either field
/// means the file may have changed and a full re-hash is required.
public struct ModelChecksumCacheEntry: Sendable, Equatable {
    public let sizeBytes: Int64
    public let mtime: Date
    public let sha256Hex: String

    public init(sizeBytes: Int64, mtime: Date, sha256Hex: String) {
        self.sizeBytes = sizeBytes
        self.mtime = mtime
        self.sha256Hex = sha256Hex
    }
}

/// Pure cache-decision helper: given a file's current attributes and an optional
/// cached entry, returns `true` when a full SHA-256 re-hash is needed.
///
/// Rules (all three must hold to skip rehash):
///   - a cached entry exists, AND
///   - cached.sizeBytes == size, AND
///   - cached.mtime    == mtime
///
/// This function has no side effects and requires no MainActor isolation, so it
/// is safely testable from any context.
public enum ModelChecksumPolicy {
    public static func needsRehash(size: Int64, mtime: Date, cached: ModelChecksumCacheEntry?) -> Bool {
        guard let cached else { return true }
        return cached.sizeBytes != size || cached.mtime != mtime
    }
}

/// Thread-safe cache that maps a file URL to its last-known checksum entry.
///
/// The cache stores (size, mtime) -> sha256 so that repeated calls to
/// `validateInstalledModel` skip the O(file-size) SHA-256 loop when the file
/// has not changed. Only `needsRehash` decides whether the cached entry is
/// still valid; the cache itself performs no I/O.
public final class ModelChecksumCache: @unchecked Sendable {
    /// Peak distinct model file URLs retained. Path churn under Models/ would
    /// otherwise pin unbounded (size, mtime, sha256) rows process-wide; 32
    /// matches discovery / probe cache order of magnitude.
    public static let countLimit = 32

    private var entries: [URL: ModelChecksumCacheEntry] = [:]
    private let lock = NSLock()
    private let limit: Int

    public init(countLimit: Int = ModelChecksumCache.countLimit) {
        self.limit = max(1, countLimit)
    }

    public func entry(for url: URL) -> ModelChecksumCacheEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[url]
    }

    public func store(_ entry: ModelChecksumCacheEntry, for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        Self.noteEntry(&entries, url: url, entry: entry, countLimit: limit)
    }

    /// Test-only: retained URL count under the lock.
    public var countForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// Pure insert/evict for unit tests. Keeps `url`; drops arbitrary other
    /// keys when over `countLimit`.
    public static func noteEntry(
        _ entries: inout [URL: ModelChecksumCacheEntry],
        url: URL,
        entry: ModelChecksumCacheEntry,
        countLimit: Int = ModelChecksumCache.countLimit
    ) {
        entries[url] = entry
        let cap = max(1, countLimit)
        while entries.count > cap {
            if let victim = entries.keys.first(where: { $0 != url }) ?? entries.keys.first {
                entries.removeValue(forKey: victim)
            } else {
                break
            }
        }
    }
}

// MARK: - Distill --status diagnostics formatter

/// Snapshot of inputs needed to produce a distill --status summary line set.
/// All fields are plain value types so the formatter remains MainActor-free.
public struct TokenSaverDistillStatusInput: Sendable, Equatable {
    public let status: TokenSaverDistillServiceStatus
    /// Live metrics fetched from /metrics, or nil when the service is not running.
    public let metrics: DistillServiceMetrics?
    /// Total bytes in the CCR reversible-content store, or nil when unavailable.
    public let storeSizeBytes: Int64?
    /// Result of a /readyz probe: true = 200, false = non-200, nil = not probed.
    public let readyzOK: Bool?

    public init(
        status: TokenSaverDistillServiceStatus,
        metrics: DistillServiceMetrics? = nil,
        storeSizeBytes: Int64? = nil,
        readyzOK: Bool? = nil
    ) {
        self.status = status
        self.metrics = metrics
        self.storeSizeBytes = storeSizeBytes
        self.readyzOK = readyzOK
    }
}

/// Pure, side-effect-free formatter that converts a `TokenSaverDistillStatusInput`
/// into an ordered list of ASCII diagnostic lines suitable for `distill --status`
/// output or a diagnostics UI panel.
///
/// Extracted as a standalone enum so every output rule is testable without
/// MainActor isolation or a live sidecar process (Rule 8).
public enum TokenSaverDistillStatusFormatter {
    /// Returns an ordered list of ASCII diagnostic lines.
    /// Each line is `key: value`. Keys never contain smart quotes or non-ASCII.
    public static func lines(for input: TokenSaverDistillStatusInput) -> [String] {
        var result: [String] = []

        // Early-return for terminal/non-connectable states to avoid emitting
        // url / metrics lines that would mislead diagnostics readers.
        switch input.status {
        case .blocked(let reason):
            result.append("status: blocked")
            result.append("reason: \(reason)")
            appendStoreSize(&result, input.storeSizeBytes)
            return result
        case .failed(let reason):
            result.append("status: failed")
            result.append("reason: \(reason)")
            appendStoreSize(&result, input.storeSizeBytes)
            return result
        default:
            break
        }

        // --- state label for non-terminal cases ---
        let stateLabel: String
        switch input.status {
        case .notStarted: stateLabel = "not-running"
        case .starting:   stateLabel = "starting"
        default:          stateLabel = "running"
        }

        result.append("status: \(stateLabel)")

        // --- url / service details (only when running) ---
        if case .running(let ready) = input.status {
            result.append("url: \(ready.baseURL)")
            result.append("pid: \(ready.pid)")
            result.append("runtime: \(ready.runtime)")
            result.append("model: \(ready.modelID)")
        }

        // --- readyz probe result ---
        if let ok = input.readyzOK {
            let readyLabel = ok ? "yes" : "no"
            result.append("ready: \(readyLabel)")
        }

        // --- live metrics ---
        if let m = input.metrics {
            result.append(
                "metrics: total=\(m.totalRequests) active=\(m.activeRequests) success=\(m.successfulRequests) failed=\(m.failedRequests) max=\(m.maxConcurrentRequests)"
            )
        }

        // --- store size ---
        appendStoreSize(&result, input.storeSizeBytes)

        return result
    }

    private static func appendStoreSize(_ result: inout [String], _ bytes: Int64?) {
        if let bytes {
            result.append("store: \(bytes) bytes")
        }
    }
}

private struct TokenSaverDistillCLIState: Codable {
    let baseURL: String
    let authToken: String
    let pid: Int32
    let runtime: String
    let modelID: String

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case authToken = "auth_token"
        case pid
        case runtime
        case modelID = "model_id"
    }
}

private struct TokenSaverDistillProcessEvent: Codable {
    let event: String
    let provider: String?
    let mode: String?
    let savedTokens: Int?

    enum CodingKeys: String, CodingKey {
        case event
        case provider
        case mode
        case savedTokens = "saved_tokens"
    }
}

// MARK: - Process spawner seam

/// Result of spawning the sidecar process.
/// Carries the live `Process` handle plus the read ends of stdout and stderr,
/// so the controller can wire readability handlers without knowing how the pipes
/// were created (real `Pipe()` vs. test-injected `FileHandle`).
public struct DistillSpawnResult: @unchecked Sendable {
    public let process: Process
    public let stdoutHandle: FileHandle
    public let stderrHandle: FileHandle
    public let ownershipTag: SpawnedProcessTag?

    public init(
        process: Process,
        stdoutHandle: FileHandle,
        stderrHandle: FileHandle,
        ownershipTag: SpawnedProcessTag? = nil
    ) {
        self.process = process
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle
        self.ownershipTag = ownershipTag
    }
}

/// Abstracts `Process()` creation so crash/EOF/stderr scenarios are exercisable
/// in unit tests without launching the real `RemoteCodeDistillService` binary.
/// WHY: the start() method hard-codes `Process()`, making it impossible to
/// simulate a crash (process exits immediately), an EOF on stdout (ready event
/// never arrives), or stderr flooding without a real binary on-disk (Rule 8).
/// The default implementation creates real `Pipe`-backed processes; tests inject
/// a factory that returns a pre-wired fast-exit process or a controlled pipe.
public protocol DistillProcessSpawning: Sendable {
    /// Create and run a process.  Must call `process.run()` before returning.
    /// Throws if the process cannot be launched.
    func spawn(executableURL: URL, arguments: [String]) throws -> DistillSpawnResult
}

/// Real (production) spawner: creates a `Process` with two `Pipe` instances and
/// calls `run()`.  This is identical to the code that was previously inlined in
/// `start()`, with no behaviour change in production.
public struct RealDistillProcessSpawner: DistillProcessSpawning, Sendable {
    public init() {}

    public func spawn(executableURL: URL, arguments: [String]) throws -> DistillSpawnResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.standardOutput = stdout
        process.standardError = stderr
        process.arguments = arguments
        try process.run()
        let ownershipTag = try ProcessSpawnTagger.tagProcess(process, managedKind: .sidecar)
        return DistillSpawnResult(
            process: process,
            stdoutHandle: stdout.fileHandleForReading,
            stderrHandle: stderr.fileHandleForReading,
            ownershipTag: ownershipTag
        )
    }
}

@MainActor
public final class TokenSaverDistillServiceController {
    public typealias ExecutableURLResolver = @MainActor () -> URL?
    /// Reconcile exact persisted ownership before a sidecar launch. Injectable so
    /// unit tests never signal a developer's real sidecar.
    public typealias ForeignServerTerminator = @Sendable (Int32?) -> ProviderProcessSweepResult

    public private(set) var status: TokenSaverDistillServiceStatus = .notStarted {
        didSet {
            guard status != oldValue else { return }
            NotificationCenter.default.post(
                name: .rc2TokenSaverDistillStatusChanged,
                object: self
            )
        }
    }
    public private(set) var bearerToken: String?

    private let appSupportDirectory: URL
    private let executableURLResolver: ExecutableURLResolver
    private let processSpawner: any DistillProcessSpawning
    private let terminateForeignServers: ForeignServerTerminator
    private let memoryProfileProvider: @Sendable () -> ManagedProcessMemoryProfile
    private let ownedProcessTerminationTimeout: TimeInterval
    // PERF: every sidecar stdout line (ready event + savings_recorded) and CLI
    // state write allocated JSONDecoder/JSONEncoder. Controller is MainActor-
    // isolated so one pair is safe and avoids per-line codec construction.
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()
    private var process: Process?
    private var lastStartSettings: AppSettings?
    private var processOwnershipTag: SpawnedProcessTag?
    private var terminatingProcess: Process?
    private var terminationTask: Task<Void, Never>?
    private var pendingStartAfterTermination = false
    // Desired lifecycle state (a start request wants the sidecar running) plus a
    // latch for the in-flight off-main foreign-server sweep. The sweep completes
    // on the MainActor and re-checks `shouldRun` before spawning, so an
    // overlapping stop()/termination cannot leave a stale sidecar running.
    private var shouldRun = false
    private var foreignSweepInFlight = false
    private var readyOutputHandle: FileHandle?
    private var stderrOutputHandle: FileHandle?
    private var readyOutputBuffer = Data()
    private var stderrOutputBuffer = Data()
    private var lastStderrLine: String?
    private static let maxCapturedStderrBytes = 8192
    /// Set while `stop()` is tearing down so the termination handler does not
    /// misinterpret an intentional terminate() as a crash and auto-restart.
    private var isStopping = false
    /// Consecutive auto-restart attempts; reset to 0 once the sidecar reports
    /// ready. Caps retries (TokenSaverDistillSupervisor.maxRestartAttempts).
    private var restartAttempts = 0
    private var restartTask: Task<Void, Never>?

    /// Idle window (ms) forwarded to the sidecar so the SERVER reclaims the
    /// model's GPU memory when its request queue drains. The controller itself
    /// keeps the sidecar resident while Token Saver is enabled: terminal
    /// `cmd | distill` talks straight to the sidecar socket and cannot autostart
    /// it, so killing the process on idle silently broke `| distill` (it failed
    /// open with zero recorded savings — the "saved stuck at 36k" symptom). The
    /// heavy MLX memory is already returned per request-drain, so staying
    /// resident only holds the ~1.1 GB process baseline.
    public let idleTimeoutMS: Int

    public init(
        appSupportDirectory: URL,
        executableURLResolver: @escaping ExecutableURLResolver = TokenSaverDistillServiceController.defaultExecutableURL,
        idleTimeoutMS: Int = 300_000,
        processSpawner: any DistillProcessSpawning = RealDistillProcessSpawner(),
        terminateForeignServers: @escaping ForeignServerTerminator = { TokenSaverDistillServiceController.defaultTerminateForeignServers(keeping: $0) },
        ownedProcessTerminationTimeout: TimeInterval = 2.5,
        memoryProfileProvider: @escaping @Sendable () -> ManagedProcessMemoryProfile = {
            ManagedProcessMemoryProfile.resolve(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        }
    ) {
        self.appSupportDirectory = appSupportDirectory
        self.executableURLResolver = executableURLResolver
        self.idleTimeoutMS = idleTimeoutMS
        self.processSpawner = processSpawner
        self.terminateForeignServers = terminateForeignServers
        self.ownedProcessTerminationTimeout = max(0.1, ownedProcessTerminationTimeout)
        self.memoryProfileProvider = memoryProfileProvider
    }

    /// Production ownership reconciliation. No-ops under XCTest so suite
    /// start/stop never signals a developer's real sidecar; tests inject a spy.
    ///
    /// Also reaps live HTTP/MLX Distill servers found via process table that are
    /// not the keepPID. Worktree/manual sidecars are often absent from the
    /// ownership ledger, and leaving them alive breaks the multi-GB singleton
    /// gate (second spawn fails or competes for unified memory).
    /// Never signals `mcp` helpers (multi-instance CLI path).
    nonisolated public static func defaultTerminateForeignServers(
        keeping keepPID: Int32?
    ) -> ProviderProcessSweepResult {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return ProviderProcessSweepResult(orphanRootPIDs: [], terminatedPIDs: [], failedPIDs: [])
        }
        var orphanRootPIDs: [Int32] = []
        var terminatedPIDs: [Int32] = []
        var failedPIDs: [Int32] = []
        do {
            let ledger = try ProviderProcessSweeper.terminatePersistedOrphanedProviderRuntimes(minAge: 0)
            orphanRootPIDs.append(contentsOf: ledger.orphanRootPIDs)
            terminatedPIDs.append(contentsOf: ledger.terminatedPIDs)
            failedPIDs.append(contentsOf: ledger.failedPIDs)
        } catch {
            // Fall through to process-table reaping; ledger absence must not
            // leave a multi-GB foreign Distill HTTP server alive.
        }
        let table = reapForeignHTTPDistillServers(keeping: keepPID)
        orphanRootPIDs.append(contentsOf: table.orphanRootPIDs)
        terminatedPIDs.append(contentsOf: table.terminatedPIDs)
        failedPIDs.append(contentsOf: table.failedPIDs)
        return ProviderProcessSweepResult(
            orphanRootPIDs: orphanRootPIDs,
            terminatedPIDs: terminatedPIDs,
            failedPIDs: failedPIDs
        )
    }

    /// TERM then brief wait then KILL for HTTP Distill servers only (`mcp` excluded).
    nonisolated private static func reapForeignHTTPDistillServers(
        keeping keepPID: Int32?
    ) -> ProviderProcessSweepResult {
        guard let rows = try? ProviderProcessSweeper.psRowsThrowing() else {
            return ProviderProcessSweepResult(orphanRootPIDs: [], terminatedPIDs: [], failedPIDs: [])
        }
        var orphans: [Int32] = []
        var terminated: [Int32] = []
        var failed: [Int32] = []
        for row in rows {
            guard ProviderProcessSweeper.isRemoteCodeDistillServerCommand(row.command) else { continue }
            if let keepPID, row.pid == keepPID { continue }
            orphans.append(row.pid)
            let pid = row.pid
            guard pid > 1 else { continue }
            _ = Darwin.kill(pid, SIGTERM)
            Thread.sleep(forTimeInterval: 0.25)
            if processIsAlive(pid) {
                _ = Darwin.kill(pid, SIGKILL)
                Thread.sleep(forTimeInterval: 0.05)
            }
            if processIsAlive(pid) {
                failed.append(pid)
            } else {
                terminated.append(pid)
            }
        }
        return ProviderProcessSweepResult(
            orphanRootPIDs: orphans,
            terminatedPIDs: terminated,
            failedPIDs: failed
        )
    }

    nonisolated private static func processIsAlive(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    deinit {
        process?.terminate()
        terminatingProcess?.terminate()
    }

    public func startIfEligible(
        session: PrivateAccountSession?,
        settings: AppSettings,
        modelValidation: TokenSaverModelValidation
    ) {
        lastStartSettings = settings
        let allowsExternal: Bool
        if case .openaiCompatible = settings.tokenSaverGenerateTarget { allowsExternal = true } else { allowsExternal = false }
        let decision = TokenSaverDistillLaunchPlanner.decide(TokenSaverDistillLaunchInput(
            hasPrivateAccount: session != nil,
            isSubscribed: session?.user.subscribed == true,
            tokenSaverEnabled: settings.tokenSaverEnabled,
            modelValidation: modelValidation,
            allowsExternalGenerate: allowsExternal
        ))

        switch decision {
        case .start:
            start()
        case .skip(let reason):
            stop()
            status = .blocked(reason)
        case .requireModel(let reason):
            stop()
            status = .blocked(reason ?? "model download required")
        }
    }

    public func stop() {
        isStopping = true
        shouldRun = false
        restartTask?.cancel()
        restartTask = nil
        restartAttempts = 0
        readyOutputHandle?.readabilityHandler = nil
        readyOutputHandle = nil
        stderrOutputHandle?.readabilityHandler = nil
        stderrOutputHandle = nil
        readyOutputBuffer.removeAll(keepingCapacity: false)
        stderrOutputBuffer.removeAll(keepingCapacity: false)
        lastStderrLine = nil
        removeCLIState()
        pendingStartAfterTermination = false
        if let process {
            process.terminationHandler = nil
            beginBoundedTermination(of: process, ownershipTag: processOwnershipTag)
        }
        process = nil
        processOwnershipTag = nil
        bearerToken = nil
        // Reset from EVERY state (.starting/.failed/.running) so a stuck status
        // never survives a stop()/eligibility change.
        let decision = TokenSaverDistillSupervisor.decide(
            status: status,
            event: .stopRequested,
            restartAttempts: 0
        )
        status = decision.nextStatus
        isStopping = false
    }

    private func beginBoundedTermination(
        of process: Process,
        ownershipTag: SpawnedProcessTag?
    ) {
        guard process.isRunning else {
            if let ownershipTag {
                try? ProviderProcessOwnership.shared.store()?.removeExact(ownershipTag)
            }
            return
        }
        let expectedIdentity = ownershipTag?.startIdentity
            ?? ProviderProcessStartIdentity.read(pid: process.processIdentifier)
        terminatingProcess = process
        let timeout = ownedProcessTerminationTimeout
        terminationTask = Task.detached(priority: .userInitiated) { [weak self, weak process] in
            guard let process else { return }
            let stopped = ProcessSpawnTagger.terminateExactOwnedProcessAndWait(
                process,
                expectedStartIdentity: expectedIdentity,
                timeout: timeout
            )
            if stopped, let ownershipTag {
                try? ProviderProcessOwnership.shared.store()?.removeExact(ownershipTag)
            }
            await MainActor.run { [weak self, weak process] in
                guard let self, let process, self.terminatingProcess === process else { return }
                self.terminatingProcess = nil
                self.terminationTask = nil
                let shouldRestart = self.pendingStartAfterTermination
                self.pendingStartAfterTermination = false
                guard stopped else {
                    self.status = .failed("Previous RemoteCodeDistillService did not stop within the bounded handoff window")
                    return
                }
                if shouldRestart {
                    self.start()
                }
            }
        }
    }

    /// Called from the process termination handler on the MainActor.
    private func handleProcessExit() {
        // Tear down the dead process' I/O handles so a relaunch starts clean.
        readyOutputHandle?.readabilityHandler = nil
        readyOutputHandle = nil
        stderrOutputHandle?.readabilityHandler = nil
        if let data = stderrOutputHandle?.readDataToEndOfFile(), !data.isEmpty {
            captureStderrData(data)
        }
        stderrOutputHandle = nil
        readyOutputBuffer.removeAll(keepingCapacity: false)
        removeCLIState()
        process = nil
        bearerToken = nil
        applySupervisorEvent(.processExited(wasUserStop: isStopping))
    }

    /// Feeds a lifecycle event through the pure supervisor, applies the next
    /// status, and schedules a backed-off restart when the supervisor asks for
    /// one. Idempotent for terminal/duplicate events (e.g. EOF then exit).
    private func applySupervisorEvent(_ event: TokenSaverDistillSupervisor.Event) {
        let decision = TokenSaverDistillSupervisor.decide(
            status: status,
            event: event,
            restartAttempts: restartAttempts
        )
        status = statusWithLastStderr(decision.nextStatus)
        if decision.shouldRestart {
            scheduleRestart()
        }
    }

    private func statusWithLastStderr(_ nextStatus: TokenSaverDistillServiceStatus) -> TokenSaverDistillServiceStatus {
        guard case .failed(let reason) = nextStatus else { return nextStatus }
        return .failed(TokenSaverDistillFailureReasonFormatter.appendDiagnostic(to: reason, stderrLine: lastStderrLine))
    }

    private func scheduleRestart() {
        // Coalesce: if a restart is already pending, keep it.
        guard restartTask == nil else { return }
        let delay = TokenSaverDistillSupervisor.backoffSeconds(forAttempt: restartAttempts)
        restartAttempts += 1
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.restartTask = nil
            // Only relaunch if we are still in a failed/restart-pending state;
            // a stop() or eligibility change may have intervened.
            if case .failed = self.status {
                self.start()
            }
        }
    }

    private func start() {
        // A start request wants the sidecar running; the off-main sweep below can
        // overlap with stop()/termination, so its completion re-checks this latch.
        shouldRun = true
        if let process, process.isRunning {
            return
        }
        if terminatingProcess != nil {
            pendingStartAfterTermination = true
            return
        }
        // A sweep is already running; its MainActor completion spawns exactly once.
        if foreignSweepInFlight {
            return
        }
        // A live launch supersedes any pending backoff retry.
        restartTask?.cancel()
        restartTask = nil
        guard let executableURL = executableURLResolver() else {
            status = .failed("RemoteCodeDistillService executable missing")
            return
        }

        // Single-instance gate: never spawn a second multi-GB MLX server while any
        // other Distill server still holds the model (orphans / prior runs). The
        // sweep does blocking `ps` execs + SIGTERM grace sleeps, so it must run OFF
        // the main actor — running it inline here froze the UI (F3). It still
        // completes BEFORE the spawn, so two model-holding servers never overlap.
        foreignSweepInFlight = true
        let terminate = terminateForeignServers
        Task.detached(priority: .userInitiated) {
            _ = terminate(nil)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.foreignSweepInFlight = false
                // stop()/termination/an existing process may have intervened
                // during the sweep; never spawn against the current intent.
                guard self.shouldRun,
                      !(self.process?.isRunning ?? false),
                      self.terminatingProcess == nil else { return }
                self.performSpawn(executableURL: executableURL)
            }
        }
    }

    private func performSpawn(executableURL: URL) {
        let token = UUID().uuidString
        stderrOutputHandle?.readabilityHandler = nil
        stderrOutputHandle = nil
        stderrOutputBuffer.removeAll(keepingCapacity: false)
        lastStderrLine = nil
        let settings = lastStartSettings ?? AppSettings()
        let localModel = settings.tokenSaverLocalModel
        let model: TokenSaverApprovedModel
        if case .openaiCompatible = settings.tokenSaverGenerateTarget {
            model = localModel
        } else {
            model = localModel
        }
        let memoryProfile = memoryProfileProvider()
        var arguments = [
            "--auth-token", token,
            "--app-support-dir", appSupportDirectory.path,
            "--host", "127.0.0.1",
            "--port", "0",
            "--runtime", model.runtime,
            "--model-id", model.id,
            "--model-url", model.url,
            "--max-concurrent-requests", String(memoryProfile.sidecarMaxConcurrentRequests),
            "--max-queue-depth", String(memoryProfile.sidecarMaxQueueDepth),
            "--max-queue-wait-ms", String(memoryProfile.sidecarMaxQueueWaitMilliseconds),
            "--idle-timeout-ms", String(idleTimeoutMS)
        ]
        if case let .openaiCompatible(url, apiModel, apiToken) = settings.tokenSaverGenerateTarget {
            arguments += ["--generate-base-url", url.absoluteString, "--generate-model", apiModel]
            if !apiToken.isEmpty {
                arguments += ["--generate-token", apiToken]
            }
        }
        if settings.tokenSaverSaveTrainingPrompts {
            arguments += ["--save-training-prompts", "true"]
        }

        do {
            let spawned = try processSpawner.spawn(executableURL: executableURL, arguments: arguments)
            let process = spawned.process
            self.process = process
            self.processOwnershipTag = spawned.ownershipTag
            self.bearerToken = token
            self.status = .starting
            // Supervise: when the sidecar exits unexpectedly, downgrade status
            // and schedule a backed-off auto-restart so a crashed sidecar does
            // not silently fail-open (Rule 6).
            process.terminationHandler = { [weak self, weak process] _ in
                Task { @MainActor [weak self, weak process] in
                    guard let self, let process, self.process === process else { return }
                    self.handleProcessExit()
                }
            }
            // Drain stderr continuously so the pipe buffer never fills.
            // Without this handler the sidecar blocks on any stderr write once
            // the 64 KB kernel pipe buffer is full, producing a deadlock.
            self.stderrOutputHandle = spawned.stderrHandle
            spawned.stderrHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData   // drains; keeps the buffer empty
                guard !data.isEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.captureStderrData(data)
                }
            }
            readReadyEvent(from: spawned.stdoutHandle, process: process)
        } catch {
            self.status = .failed("RemoteCodeDistillService launch failed")
            self.bearerToken = nil
            self.process = nil
            self.processOwnershipTag = nil
        }
    }

    private func readReadyEvent(from handle: FileHandle, process: Process) {
        readyOutputHandle?.readabilityHandler = nil
        readyOutputHandle = handle
        readyOutputBuffer.removeAll(keepingCapacity: false)
        handle.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                Task { @MainActor [weak self, weak process] in
                    guard let self, let process, self.process === process else { return }
                    handle.readabilityHandler = nil
                    self.readyOutputHandle = nil
                    guard case .starting = self.status else { return }
                    if process.isRunning {
                        // Stream closed but process alive: ready event will never
                        // arrive on this handle.
                        self.status = .failed("RemoteCodeDistillService ready event missing")
                    } else {
                        // Dead process + EOF: cap the startup wait so the consumer
                        // poll loop does not spin for the full 60s window. The
                        // terminationHandler also fires, but EOF can arrive first;
                        // whichever runs first downgrades + schedules the restart.
                        self.applySupervisorEvent(.startupEOFWhileDead)
                    }
                }
                return
            }

            Task { @MainActor [weak self, weak process] in
                guard let self, let process, self.process === process else { return }
                self.readyOutputBuffer.append(data)
                while let newline = self.readyOutputBuffer.firstIndex(of: 10) {
                    let lineData = Data(self.readyOutputBuffer[..<newline])
                    self.readyOutputBuffer.removeSubrange(...newline)
                    self.handleOutputLine(lineData)
                }
            }
        }
    }

    private func handleOutputLine(_ lineData: Data) {
        if case .starting = status {
            let ready = try? jsonDecoder.decode(DistillServiceReadyEvent.self, from: lineData)
            if let ready {
                writeCLIState(ready: ready)
                // Healthy startup clears the restart-attempt counter so the next
                // crash gets a fresh backoff budget.
                restartAttempts = 0
                status = .running(ready)
            } else {
                status = .failed("RemoteCodeDistillService ready event invalid")
            }
            return
        }

        handleRunningOutputLine(lineData)
    }

    /// Handles a sidecar stdout line once the service is running. Split out from
    /// `handleOutputLine` (which also handles the `.starting` ready event) so the
    /// savings-event → UI-refresh wiring is unit-testable without spawning a real
    /// process. A `savings_recorded` event means real distill traffic happened
    /// (CLI or app), so the Token Saver card must re-read the ledger.
    func handleRunningOutputLine(_ lineData: Data) {
        guard let event = try? jsonDecoder.decode(TokenSaverDistillProcessEvent.self, from: lineData),
              event.event == "savings_recorded" else {
            return
        }
        NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)
    }

    private func captureStderrData(_ data: Data) {
        guard !data.isEmpty else { return }
        stderrOutputBuffer.append(data)
        if stderrOutputBuffer.count > Self.maxCapturedStderrBytes {
            stderrOutputBuffer = stderrOutputBuffer.suffix(Self.maxCapturedStderrBytes)
        }
        guard let text = String(data: stderrOutputBuffer, encoding: .utf8) else { return }
        lastStderrLine = TokenSaverDistillFailureReasonFormatter.sanitizedDiagnostic(from: text)
    }

    private var cliStateURL: URL {
        appSupportDirectory
            .appendingPathComponent("Distill", isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
    }

    private func writeCLIState(ready: DistillServiceReadyEvent) {
        guard let bearerToken else { return }
        let state = TokenSaverDistillCLIState(
            baseURL: ready.baseURL,
            authToken: bearerToken,
            pid: ready.pid,
            runtime: ready.runtime,
            modelID: ready.modelID
        )
        do {
            let url = cliStateURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jsonEncoder.encode(state).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("RemoteCode Token Saver distill CLI state write failed: \(error)")
        }
    }

    private func removeCLIState() {
        let url = cliStateURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            NSLog("RemoteCode Token Saver distill CLI state remove failed: \(error)")
        }
    }

    public static func defaultExecutableURL() -> URL? {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            Bundle.main.bundlePath.hasSuffix(".xctest") ||
            Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) ||
            NSClassFromString("XCTest.XCTestCase") != nil ||
            NSClassFromString("XCTestCase") != nil {
            return nil
        }
        let fileManager = FileManager.default
        let bundled = Bundle.main.url(forAuxiliaryExecutable: "RemoteCodeDistillService")
        if let bundled, fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        let currentExecutable = URL(fileURLWithPath: CommandLine.arguments[0])
        let sibling = currentExecutable
            .deletingLastPathComponent()
            .appendingPathComponent("RemoteCodeDistillService")
        if fileManager.isExecutableFile(atPath: sibling.path) {
            return sibling
        }

        let debugBuild = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/RemoteCodeDistillService")
        if fileManager.isExecutableFile(atPath: debugBuild.path) {
            return debugBuild
        }
        return nil
    }
}
