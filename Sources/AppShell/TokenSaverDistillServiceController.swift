import AgentRuntime
import DistillCore
import Foundation
import Persistence

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

    public init(
        hasPrivateAccount: Bool,
        isSubscribed: Bool,
        tokenSaverEnabled: Bool,
        modelValidation: TokenSaverModelValidation
    ) {
        self.hasPrivateAccount = hasPrivateAccount
        self.isSubscribed = isSubscribed
        self.tokenSaverEnabled = tokenSaverEnabled
        self.modelValidation = modelValidation
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
        guard input.modelValidation.state == .installed else {
            return .requireModel(reason: input.modelValidation.reason)
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

/// Pure idle-unload decision helper. No side effects; fully testable without MainActor.
///
/// - Parameters:
///   - lastRequestAt: timestamp of the most recent request, or nil if no request has occurred.
///   - idleTimeoutMS: idle window in milliseconds. <= 0 disables the feature (always returns false).
///   - now: current time (injected for deterministic tests).
/// - Returns: true when the model should be unloaded due to idleness.
public enum TokenSaverIdlePolicy {
    public static func shouldUnload(lastRequestAt: Date?, idleTimeoutMS: Int, now: Date) -> Bool {
        guard idleTimeoutMS > 0 else { return false }
        guard let last = lastRequestAt else { return false }
        let elapsed = now.timeIntervalSince(last) * 1000
        return elapsed >= Double(idleTimeoutMS)
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
    private var entries: [URL: ModelChecksumCacheEntry] = [:]
    private let lock = NSLock()

    public init() {}

    public func entry(for url: URL) -> ModelChecksumCacheEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[url]
    }

    public func store(_ entry: ModelChecksumCacheEntry, for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        entries[url] = entry
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

@MainActor
public final class TokenSaverDistillServiceController {
    public typealias ExecutableURLResolver = @MainActor () -> URL?

    public private(set) var status: TokenSaverDistillServiceStatus = .notStarted
    public private(set) var bearerToken: String?

    private let appSupportDirectory: URL
    private let executableURLResolver: ExecutableURLResolver
    private var process: Process?
    private var readyOutputHandle: FileHandle?
    private var readyOutputBuffer = Data()
    /// Set while `stop()` is tearing down so the termination handler does not
    /// misinterpret an intentional terminate() as a crash and auto-restart.
    private var isStopping = false
    /// Consecutive auto-restart attempts; reset to 0 once the sidecar reports
    /// ready. Caps retries (TokenSaverDistillSupervisor.maxRestartAttempts).
    private var restartAttempts = 0
    private var restartTask: Task<Void, Never>?

    /// Milliseconds of inactivity after which the sidecar is unloaded to free
    /// ~1.1 GB RAM. 0 or negative disables the feature. Defaults to 5 minutes.
    public let idleTimeoutMS: Int
    /// Timestamp of the most recent request routed through the sidecar.
    public private(set) var lastRequestAt: Date?
    private var idleCheckTask: Task<Void, Never>?

    public init(
        appSupportDirectory: URL,
        executableURLResolver: @escaping ExecutableURLResolver = TokenSaverDistillServiceController.defaultExecutableURL,
        idleTimeoutMS: Int = 300_000
    ) {
        self.appSupportDirectory = appSupportDirectory
        self.executableURLResolver = executableURLResolver
        self.idleTimeoutMS = idleTimeoutMS
    }

    deinit {
        process?.terminate()
    }

    public func startIfEligible(
        session: PrivateAccountSession?,
        settings: AppSettings,
        modelValidation: TokenSaverModelValidation
    ) {
        let decision = TokenSaverDistillLaunchPlanner.decide(TokenSaverDistillLaunchInput(
            hasPrivateAccount: session != nil,
            isSubscribed: session?.user.subscribed == true,
            tokenSaverEnabled: settings.tokenSaverEnabled,
            modelValidation: modelValidation
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
        idleCheckTask?.cancel()
        idleCheckTask = nil
        lastRequestAt = nil
        restartTask?.cancel()
        restartTask = nil
        restartAttempts = 0
        readyOutputHandle?.readabilityHandler = nil
        readyOutputHandle = nil
        readyOutputBuffer.removeAll(keepingCapacity: false)
        removeCLIState()
        if let process {
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
            }
        }
        process = nil
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

    /// Called from the process termination handler on the MainActor.
    private func handleProcessExit() {
        // Tear down the dead process' I/O handles so a relaunch starts clean.
        readyOutputHandle?.readabilityHandler = nil
        readyOutputHandle = nil
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
        status = decision.nextStatus
        if decision.shouldRestart {
            scheduleRestart()
        }
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

    /// Call when a request is dispatched through the sidecar so the idle timer resets.
    public func recordRequest() {
        lastRequestAt = Date()
    }

    /// Schedules a periodic check that unloads the sidecar when idle.
    /// Coalesces: only one check task runs at a time.
    private func scheduleIdleCheck() {
        guard idleTimeoutMS > 0, idleCheckTask == nil else { return }
        let intervalNS = UInt64(max(idleTimeoutMS, 10_000)) * 1_000_000
        idleCheckTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNS)
                guard !Task.isCancelled, let self else { return }
                if TokenSaverIdlePolicy.shouldUnload(
                    lastRequestAt: self.lastRequestAt,
                    idleTimeoutMS: self.idleTimeoutMS,
                    now: Date()
                ) {
                    self.idleCheckTask = nil
                    self.stop()
                    return
                }
            }
        }
    }

    private func start() {
        if let process, process.isRunning {
            return
        }
        // A live launch supersedes any pending backoff retry.
        restartTask?.cancel()
        restartTask = nil
        guard let executableURL = executableURLResolver() else {
            status = .failed("RemoteCodeDistillService executable missing")
            return
        }

        let token = UUID().uuidString
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.standardOutput = stdout
        process.standardError = stderr
        process.arguments = [
            "--auth-token", token,
            "--app-support-dir", appSupportDirectory.path,
            "--host", "127.0.0.1",
            "--port", "0",
            "--runtime", DistillApprovedModel.runtime,
            "--model-id", DistillApprovedModel.id,
            "--model-url", DistillApprovedModel.url,
            "--max-concurrent-requests", "8",
            "--max-queue-depth", "64",
            "--idle-timeout-ms", "300000"
        ]

        do {
            try process.run()
            self.process = process
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
            stderr.fileHandleForReading.readabilityHandler = { handle in
                _ = handle.availableData   // discard; keeps the buffer empty
            }
            readReadyEvent(from: stdout.fileHandleForReading, process: process)
        } catch {
            self.status = .failed("RemoteCodeDistillService launch failed")
            self.bearerToken = nil
            self.process = nil
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
            let ready = try? JSONDecoder().decode(DistillServiceReadyEvent.self, from: lineData)
            if let ready {
                writeCLIState(ready: ready)
                // Healthy startup clears the restart-attempt counter so the next
                // crash gets a fresh backoff budget.
                restartAttempts = 0
                lastRequestAt = Date()
                status = .running(ready)
                scheduleIdleCheck()
            } else {
                status = .failed("RemoteCodeDistillService ready event invalid")
            }
            return
        }

        guard let event = try? JSONDecoder().decode(TokenSaverDistillProcessEvent.self, from: lineData),
              event.event == "savings_recorded" else {
            return
        }
        NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)
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
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
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
