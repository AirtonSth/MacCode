import Foundation
import CoreModel

/// Host Graphify service: binary resolve, artifact roots, generation-based refresh.
///
/// Refresh model (Codex advisor E):
/// - Per-checkout scheduler: dirtyGeneration / builtGeneration / inFlight / rerunRequested
/// - FSEvents on active checkout → mark dirty + debounced update
/// - Every send: O(1) requestRefresh (stale/missing/dirty/max-age) never awaits CLI
/// - Trailing update if dirty during build; atomic publish of graph.json
/// - Fail-open; never blocks provider path
public final class GraphifyWorkspaceService: @unchecked Sendable {
    public static let shared = GraphifyWorkspaceService()

    /// Safety net when FSEvents misses an edit: re-check at most this often even if "fresh".
    /// Raised from 45s so multi-thread agents on large monorepos do not thrash
    /// `graphify update` (live sample: multi-GB / ~100% CPU rebuilds).
    public var maxAgeFresh: TimeInterval = 180
    /// Minimum gap between CLI update starts for the same checkout (anti-thrash).
    public var minRebuildInterval: TimeInterval = 45
    /// Trailing debounce after FSEvents dirty marks.
    public var fseventsDebounce: TimeInterval = 4.0

    private let lock = NSLock()
    // PERF: ensure/refresh probes load+save fingerprint JSON on the hot path
    // (every send + FSEvents debounce). JSONEncoder/Decoder are not thread-
    // safe — share one pair under a short lock (file I/O stays outside).
    private let fingerprintCodecLock = NSLock()
    private let fingerprintEncoder = JSONEncoder()
    private let fingerprintDecoder = JSONDecoder()
    private var stickyByWorkspace: [String: String] = [:]
    private var schedules: [String: RefreshSchedule] = [:]
    private var watchers: [String: GraphifyCheckoutWatcher] = [:]
    private var debounceWork: [String: DispatchWorkItem] = [:]
    private var binaryInstallAttempted = false
    /// Process-wide gate: at most one graphify CLI child at a time. Per-checkout
    /// `inFlight` already coalesces same-root work; this stops two large monorepos
    /// (or worktrees) from double-taxing CPU/RAM during multi-thread sessions.
    private var globalCLIInFlight = false
    private var globalCLIRerunIDs: Set<String> = []
    /// Live graphify/git child retained for cancel-before-watcher-stop (S9).
    private var activeRebuildProcess: Process?
    private var activeRebuildCancelled = false
    /// Monotonic rebuild ownership. Cancel and disable bump this so an in-flight
    /// build started under an older generation can never publish freshness.
    private var rebuildGeneration: UInt64 = 0
    /// S7: pressure governor may pause ensure + watch callbacks without killing
    /// active rebuilds. Resumed by `resumeOptionalWorkUnit` / clear.
    private var pressurePauseEnsureAndWatch = false
    /// Bumped on each unpause/resume schedule so stale async re-kicks abort.
    private var pressureUnpauseGeneration: UInt64 = 0

    public var appSupportDirectory: URL
    public var binaryPathOverride: String?
    /// Runtime authority. Default false until AppContext/settings reconcile
    /// `isGraphifyRuntimeActive` (Token Saver ∧ Graphify preference).
    public var enabled: Bool = false
    public var autoEnsure: Bool = false
    /// When false (default), graphs are written only under Application Support via
    /// `GRAPHIFY_OUT` and never create `graphify-out/` in the user's working tree.
    public var writeInRepo: Bool = false
    /// Optional pinned multi-repo roots (absolute paths), mirrored from AppSettings.
    public var pinnedRoots: [String] = []
    /// Hard timeout for graphify/git child processes (seconds).
    public var processTimeoutSeconds: TimeInterval = 180
    public var autoBootstrapMaxSourceFiles: Int = 2_500
    /// Injected process runner for tests.
    public var runProcess: (@Sendable ([String], String, [String: String]?) -> (exit: Int32, stdout: String, stderr: String))?
    /// Test seam: inject git HEAD probe.
    public var headProbe: (@Sendable (String) -> String?)?
    /// Test seam: resolve display-root → checkout without blocking Process I/O.
    public var checkoutIdentityProbe: (@Sendable (String) -> GraphifyCheckout?)?

    private struct RefreshSchedule {
        var dirtyGeneration: UInt64 = 0
        var builtGeneration: UInt64 = 0
        var inFlight: Bool = false
        var rebuildCancelled: Bool = false
        var rerunRequested: Bool = false
        var lastSuccessfulUpdate: Date?
        var lastEnsureStarted: Date?
        var status: GraphifyRootStatus = .missing
        var lastHead: String?
        var displayRoot: String = ""
    }

    private struct Fingerprint: Codable {
        var head: String?
        var displayRoot: String
        var builtAt: TimeInterval
    }

    public init(appSupportDirectory: URL? = nil) {
        if let appSupportDirectory {
            self.appSupportDirectory = appSupportDirectory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.appSupportDirectory = base
                .appendingPathComponent("RemoteCode", isDirectory: true)
                .appendingPathComponent("graphify-graphs", isDirectory: true)
        }
    }

    /// Identity string for S7 pressure mutation revalidation (rebuild generation).
    public var pressureChildIdentity: String {
        lock.lock(); defer { lock.unlock() }
        return "graphify-rebuild-\(rebuildGeneration)"
    }

    /// S7 non-destructive pressure action: pause ensure/watch scheduling.
    /// On true→false, re-kick dirty/deferred checkouts that may have missed
    /// debounce/ensure while paused. Git probes + ensure start off MainActor.
    public func setPressurePauseEnsureAndWatch(_ paused: Bool) {
        let rootsToKick: [String]
        let unpauseGeneration: UInt64
        lock.lock()
        let wasPaused = pressurePauseEnsureAndWatch
        pressurePauseEnsureAndWatch = paused
        if wasPaused && !paused {
            pressureUnpauseGeneration &+= 1
            unpauseGeneration = pressureUnpauseGeneration
            var roots: [String] = []
            for id in schedules.keys {
                guard var schedule = schedules[id], !schedule.displayRoot.isEmpty else { continue }
                if schedule.dirtyGeneration > schedule.builtGeneration
                    || schedule.rerunRequested {
                    schedule.rerunRequested = true
                    schedule.dirtyGeneration &+= 1
                    schedules[id] = schedule
                    roots.append(schedule.displayRoot)
                }
            }
            // Also drain process-wide deferred IDs so unpause is not a silent drop.
            roots.append(contentsOf: globalCLIRerunIDs.compactMap { id in
                schedules[id]?.displayRoot
            })
            rootsToKick = Array(Set(roots))
        } else {
            unpauseGeneration = pressureUnpauseGeneration
            rootsToKick = []
        }
        lock.unlock()
        scheduleAsyncRootReKicks(roots: rootsToKick, unpauseGeneration: unpauseGeneration)
    }

    /// Shared async re-kick path for pressure unpause / resume-after-disable.
    /// Never blocks the caller with git Process I/O; revalidates Token Saver /
    /// Graphify enabled + pressure pause + unpause generation before probe and ensure.
    private func scheduleAsyncRootReKicks(roots: [String], unpauseGeneration: UInt64) {
        guard !roots.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for root in roots {
                guard self.shouldContinuePressureReKick(unpauseGeneration: unpauseGeneration) else {
                    return
                }
                let checkout: GraphifyCheckout
                if let probe = self.checkoutIdentityProbe, let resolved = probe(root) {
                    checkout = resolved
                } else if let identity = GraphifyGitProbe.identity(at: root) {
                    checkout = identity.checkout
                } else {
                    checkout = GraphifyCheckout(
                        key: GraphifyRepoKey(commonDir: root),
                        displayRoot: root
                    )
                }
                guard self.shouldContinuePressureReKick(unpauseGeneration: unpauseGeneration) else {
                    return
                }
                self.startEnsureIfNeeded(checkout: checkout)
            }
        }
    }

    private func shouldContinuePressureReKick(unpauseGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // Fail-open when Graphify/Token Saver is off: never probe or ensure.
        return enabled
            && autoEnsure
            && !pressurePauseEnsureAndWatch
            && pressureUnpauseGeneration == unpauseGeneration
    }

    public var isPressurePauseEnsureAndWatch: Bool {
        lock.lock(); defer { lock.unlock() }
        return pressurePauseEnsureAndWatch
    }

    // MARK: Artifact root (worktree-aware)

    public func artifactRoot(for checkout: GraphifyCheckout) -> URL {
        appSupportDirectory.appendingPathComponent(checkout.artifactDirectoryName, isDirectory: true)
    }

    public func graphJSONPath(for checkout: GraphifyCheckout) -> URL {
        artifactRoot(for: checkout).appendingPathComponent("graph.json")
    }

    private func fingerprintPath(for checkout: GraphifyCheckout) -> URL {
        artifactRoot(for: checkout).appendingPathComponent("fingerprint.json")
    }

    // MARK: Binary

    public func resolveBinary() -> String? {
        if let override = binaryPathOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        for path in binarySearchPaths() {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        let which = run(["/usr/bin/env", "which", "graphify"], cwd: NSHomeDirectory(), env: processEnvironment())
        if which.exit == 0 {
            let path = which.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    @discardableResult
    public func ensureBinaryInstalledIfNeeded() -> String? {
        // S9: refuse floating install when pin is incomplete; operators must pin first.
        let pin = GraphifyRuntimeHardening.defaultPin
        if !GraphifyRuntimeHardening.isPinComplete(pin) {
            // Still allow a pre-installed binary if present (dev machines), but
            // never perform an unpinned network install.
            return resolveBinary()
        }
        if let existing = resolveBinary() { return existing }
        lock.lock()
        let already = binaryInstallAttempted
        if !already { binaryInstallAttempted = true }
        lock.unlock()
        guard !already else { return resolveBinary() }
        LoginShellEnvironment.prewarm()
        let env = processEnvironment()
        // Pinned install only — no floating --upgrade of an unpinned package.
        let attempts: [[String]] = [
            ["/usr/bin/env", "uv", "tool", "install", "graphifyy==\(pin.approvedVersion)", "-q"],
            ["/usr/bin/env", "pipx", "install", "graphifyy==\(pin.approvedVersion)"],
        ]
        for args in attempts {
            let which = run(["/usr/bin/env", "which", args[1]], cwd: NSHomeDirectory(), env: env)
            guard which.exit == 0 else { continue }
            _ = run(args, cwd: NSHomeDirectory(), env: env)
            if let bin = resolveBinary() { return bin }
        }
        return resolveBinary()
    }

    private func binarySearchPaths() -> [String] {
        var paths: [String] = []
        let home = NSHomeDirectory()
        paths.append("\(home)/.local/bin/graphify")
        paths.append("\(home)/.cargo/bin/graphify")
        let uvTools = "\(home)/.local/share/uv/tools"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: uvTools) {
            for name in entries where name.contains("graphify") {
                paths.append("\(uvTools)/\(name)/bin/graphify")
            }
        }
        if let login = LoginShellEnvironment.current() {
            for dir in (login["PATH"] ?? "").split(separator: ":") {
                paths.append("\(dir)/graphify")
            }
        }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            paths.append("\(dir)/graphify")
        }
        return paths
    }

    private func processEnvironment() -> [String: String] {
        var env = ChildProcessEnvironmentPolicy.scrubHostOnlyKeys(
            from: ProcessInfo.processInfo.environment
        )
        if let login = LoginShellEnvironment.current() {
            for (k, v) in login where env[k] == nil { env[k] = v }
            if let p = login["PATH"] {
                let g = env["PATH"] ?? ""
                env["PATH"] = g.contains(p) ? g : (p + ":" + g)
            }
        }
        let localBin = NSHomeDirectory() + "/.local/bin"
        let path = env["PATH"] ?? ""
        if !path.contains(localBin) { env["PATH"] = localBin + ":" + path }
        return ChildProcessEnvironmentPolicy.scrubHostOnlyKeys(from: env)
    }

    // MARK: Status / verify (staleness-aware)

    public func verify(_ checkout: GraphifyCheckout) -> GraphifyRootStatus {
        if resolveBinary() == nil { return .unavailable }
        let graph = graphJSONPath(for: checkout)
        guard FileManager.default.fileExists(atPath: graph.path) else { return .missing }

        lock.lock()
        let schedule = schedules[checkout.scheduleID]
        let dirty = (schedule.map { $0.dirtyGeneration > $0.builtGeneration } ?? false)
            || (schedule?.rerunRequested == true)
        let building = schedule?.inFlight == true
        let lastOK = schedule?.lastSuccessfulUpdate
        lock.unlock()

        if building { return .building }
        if dirty { return .stale }

        // Max-age safety net for missed FSEvents (schedule warm or fingerprint).
        if let lastOK, Date().timeIntervalSince(lastOK) > maxAgeFresh {
            return .stale
        }
        if lastOK == nil, let fp = loadFingerprint(checkout),
           Date().timeIntervalSince1970 - fp.builtAt > maxAgeFresh {
            return .stale
        }
        // Fingerprint HEAD mismatch (cheap single git rev-parse).
        if isHeadStale(checkout: checkout) { return .stale }
        // Warm in-memory schedule from on-disk fingerprint so cold starts don't
        // look "never built" to the scheduler.
        if schedule == nil, let fp = loadFingerprint(checkout) {
            lock.lock()
            var s = schedules[checkout.scheduleID] ?? RefreshSchedule()
            s.displayRoot = checkout.displayRoot
            s.lastSuccessfulUpdate = Date(timeIntervalSince1970: fp.builtAt)
            s.lastHead = fp.head
            if s.builtGeneration == 0 {
                s.builtGeneration = 1
                s.dirtyGeneration = 1
            }
            s.status = .fresh
            schedules[checkout.scheduleID] = s
            lock.unlock()
        }
        return .fresh
    }

    /// O(1)-ish hot path used on every send: mark dirty when needed and kick async update.
    public func requestRefresh(checkout: GraphifyCheckout, force: Bool = false) {
        guard enabled, autoEnsure else { return }
        // Pressure pause: record dirty only — no watch install, verify probes, or ensure.
        lock.lock()
        let pressurePaused = pressurePauseEnsureAndWatch
        if pressurePaused {
            var schedule = schedules[checkout.scheduleID] ?? RefreshSchedule()
            schedule.displayRoot = checkout.displayRoot
            schedule.dirtyGeneration &+= 1
            schedule.rerunRequested = true
            schedules[checkout.scheduleID] = schedule
            lock.unlock()
            return
        }
        lock.unlock()

        watchCheckout(checkout)

        let status = verify(checkout)
        let needs: Bool
        switch status {
        case .missing, .stale, .error, .unavailable:
            needs = status != .unavailable // still try when missing/stale/error
        case .fresh:
            needs = force
        case .building, .ambiguous:
            needs = force
        }
        // Even when "fresh", max-age already folded into verify → stale.

        lock.lock()
        var schedule = schedules[checkout.scheduleID] ?? RefreshSchedule()
        schedule.displayRoot = checkout.displayRoot
        if needs || force {
            schedule.dirtyGeneration &+= 1
        }
        schedules[checkout.scheduleID] = schedule
        let shouldStart = needs || force || schedule.dirtyGeneration > schedule.builtGeneration
        lock.unlock()

        if shouldStart {
            startEnsureIfNeeded(checkout: checkout)
        }
    }

    public func markDirtyFromFilesystem(checkout: GraphifyCheckout) {
        guard enabled, autoEnsure else { return }
        lock.lock()
        var schedule = schedules[checkout.scheduleID] ?? RefreshSchedule()
        schedule.displayRoot = checkout.displayRoot
        schedule.dirtyGeneration &+= 1
        // Under pressure pause: keep dirty for unpause re-kick, but do not
        // schedule debounce/ensure work (pauseGraphifyEnsureAndWatchCallbacks).
        if pressurePauseEnsureAndWatch {
            schedule.rerunRequested = true
            schedules[checkout.scheduleID] = schedule
            lock.unlock()
            return
        }
        schedules[checkout.scheduleID] = schedule
        lock.unlock()

        // Trailing debounce: storms collapse into one delayed start.
        let id = checkout.scheduleID
        lock.lock()
        debounceWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.startEnsureIfNeeded(checkout: checkout)
        }
        debounceWork[id] = work
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + fseventsDebounce, execute: work)
    }

    private func isHeadStale(checkout: GraphifyCheckout) -> Bool {
        let head = currentHead(checkout.displayRoot)
        guard let head, !head.isEmpty else { return false }
        if let fp = loadFingerprint(checkout), let built = fp.head, !built.isEmpty {
            return built != head
        }
        // No fingerprint yet but graph exists → treat as stale once so we write fingerprint.
        return FileManager.default.fileExists(atPath: graphJSONPath(for: checkout).path)
            && loadFingerprint(checkout) == nil
    }

    private func currentHead(_ displayRoot: String) -> String? {
        if let headProbe { return headProbe(displayRoot) }
        let r = run(["/usr/bin/env", "git", "rev-parse", "HEAD"], cwd: displayRoot, env: processEnvironment())
        guard r.exit == 0 else { return nil }
        let h = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return h.isEmpty ? nil : h
    }

    private func loadFingerprint(_ checkout: GraphifyCheckout) -> Fingerprint? {
        let url = fingerprintPath(for: checkout)
        guard let data = try? Data(contentsOf: url) else { return nil }
        fingerprintCodecLock.lock()
        let decoded = try? fingerprintDecoder.decode(Fingerprint.self, from: data)
        fingerprintCodecLock.unlock()
        return decoded
    }

    private func saveFingerprint(_ checkout: GraphifyCheckout, head: String?) {
        let fp = Fingerprint(head: head, displayRoot: checkout.displayRoot, builtAt: Date().timeIntervalSince1970)
        let url = fingerprintPath(for: checkout)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fingerprintCodecLock.lock()
        let data = try? fingerprintEncoder.encode(fp)
        fingerprintCodecLock.unlock()
        if let data {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Ensure scheduler

    private func startEnsureIfNeeded(checkout: GraphifyCheckout) {
        guard enabled, autoEnsure else { return }
        // S7: pressure may pause ensure without disabling the feature gate.
        lock.lock()
        let pressurePaused = pressurePauseEnsureAndWatch
        lock.unlock()
        if pressurePaused { return }

        // Cheap disk/git probes OUTSIDE the lock (avoid holding NSLock across Process I/O).
        let graphExists = FileManager.default.fileExists(atPath: graphJSONPath(for: checkout).path)
        let headStale = isHeadStale(checkout: checkout)
        let fp = loadFingerprint(checkout)

        lock.lock()
        // Revalidate gates under the same lock as inFlight claim. Token Saver /
        // Graphify may be disabled during unlocked probes above — fail open.
        if !enabled || !autoEnsure {
            lock.unlock()
            return
        }
        // Re-check pressure under the same lock as inFlight claim (S7): pause
        // may land during unlocked probes above; preserve dirty for unpause.
        if pressurePauseEnsureAndWatch {
            var schedule = schedules[checkout.scheduleID] ?? RefreshSchedule()
            schedule.displayRoot = checkout.displayRoot
            schedule.rerunRequested = true
            if schedule.dirtyGeneration == schedule.builtGeneration {
                schedule.dirtyGeneration &+= 1
            }
            schedules[checkout.scheduleID] = schedule
            lock.unlock()
            return
        }
        var schedule = schedules[checkout.scheduleID] ?? RefreshSchedule()
        schedule.displayRoot = checkout.displayRoot

        if schedule.inFlight {
            schedule.rerunRequested = true
            schedules[checkout.scheduleID] = schedule
            lock.unlock()
            return
        }

        // Global single-flight: another checkout is already running graphify CLI.
        if globalCLIInFlight {
            schedule.rerunRequested = true
            schedules[checkout.scheduleID] = schedule
            globalCLIRerunIDs.insert(checkout.scheduleID)
            lock.unlock()
            return
        }

        if let last = schedule.lastEnsureStarted,
           Date().timeIntervalSince(last) < minRebuildInterval,
           schedule.dirtyGeneration <= schedule.builtGeneration {
            schedules[checkout.scheduleID] = schedule
            lock.unlock()
            return
        }

        // Dirty generation, missing graph, HEAD/fingerprint mismatch, or max-age.
        // Do NOT treat builtGeneration==0 alone as needs — cold start with a good
        // on-disk fingerprint must not force a rebuild every process launch.
        let ageStale: Bool = {
            if let ok = schedule.lastSuccessfulUpdate {
                return Date().timeIntervalSince(ok) > maxAgeFresh
            }
            if let fp {
                return Date().timeIntervalSince1970 - fp.builtAt > maxAgeFresh
            }
            return !graphExists
        }()
        let needs = schedule.dirtyGeneration > schedule.builtGeneration
            || !graphExists
            || headStale
            || ageStale

        guard needs else {
            schedules[checkout.scheduleID] = schedule
            lock.unlock()
            return
        }

        if schedule.dirtyGeneration == schedule.builtGeneration {
            schedule.dirtyGeneration &+= 1
        }
        schedule.inFlight = true
        schedule.rebuildCancelled = false
        globalCLIInFlight = true
        // Capture ownership generation for this launch; cancel bumps rebuildGeneration.
        let launchRebuildGeneration = rebuildGeneration
        schedule.lastEnsureStarted = Date()
        schedule.status = .building
        let targetGen = schedule.dirtyGeneration
        schedules[checkout.scheduleID] = schedule
        lock.unlock()

        let service = self
        DispatchQueue.global(qos: .utility).async {
            let status = service.ensureSync(
                checkout: checkout,
                mode: .update,
                launchRebuildGeneration: launchRebuildGeneration
            )
            // HEAD probe outside the service lock — run() also takes the lock.
            let head: String? = {
                if status == .fresh {
                    return service.currentHead(checkout.displayRoot)
                }
                return nil
            }()
            service.lock.lock()
            var s = service.schedules[checkout.scheduleID] ?? RefreshSchedule()
            s.inFlight = false
            // Ownership: old launch is cancelled if rebuildGeneration advanced.
            let generationCancelled = launchRebuildGeneration != service.rebuildGeneration
            let cancelled = generationCancelled
                || s.rebuildCancelled
                || service.activeRebuildCancelled
            // Never publish fresh after cancel / Token Saver disable / superseded gen.
            if cancelled {
                s.status = .missing
                s.rebuildCancelled = false
                // Unconditionally leave built below dirty so a cancelled build
                // never verifies fresh (even if dirtyGeneration advanced mid-build).
                if s.dirtyGeneration <= s.builtGeneration {
                    s.dirtyGeneration = s.builtGeneration &+ 1
                }
                if s.builtGeneration >= s.dirtyGeneration {
                    s.builtGeneration = s.dirtyGeneration &- 1
                }
            } else {
                s.status = status
                if status == .fresh {
                    s.builtGeneration = targetGen
                    s.lastSuccessfulUpdate = Date()
                    s.lastHead = head
                }
            }
            // After a cancelled generation drains, still re-kick if enabled and dirty
            // so resumeAfterDisable's replacement request is not lost.
            let dirtyNow = s.rerunRequested || s.dirtyGeneration > s.builtGeneration
            let needRerun = service.enabled && dirtyNow
            s.rerunRequested = false
            service.schedules[checkout.scheduleID] = s
            service.globalCLIInFlight = false
            service.activeRebuildProcess = nil
            // Clear sticky cancel only when no generation-owned work remains.
            if !service.schedules.values.contains(where: \.inFlight) {
                service.activeRebuildCancelled = false
            }
            // On cancel drain, also re-kick any other deferred/dirty schedules while enabled.
            let deferredIDs: Set<String>
            if cancelled && service.enabled {
                deferredIDs = service.globalCLIRerunIDs.union(
                    Set(service.schedules.compactMap { id, sch in
                        (sch.dirtyGeneration > sch.builtGeneration || sch.rerunRequested) ? id : nil
                    })
                )
            } else if cancelled {
                deferredIDs = []
            } else {
                deferredIDs = service.globalCLIRerunIDs
            }
            service.globalCLIRerunIDs.removeAll(keepingCapacity: true)
            let deferredRoots = deferredIDs.compactMap { id -> String? in
                guard id != checkout.scheduleID,
                      let deferred = service.schedules[id],
                      !deferred.displayRoot.isEmpty else { return nil }
                return deferred.displayRoot
            }
            service.lock.unlock()

            // If cancel landed after ensureSync saved a fingerprint, remove it so
            // restart cannot warm the cancelled generation as fresh.
            if cancelled {
                try? FileManager.default.removeItem(at: service.fingerprintPath(for: checkout))
            }
            // Kick deferred checkouts that waited on the global gate (at most one
            // trailing ensure per id via startEnsureIfNeeded coalescing).
            // Under pressure pause: preserve dirty/rerun only — do not spawn git
            // identity probes before startEnsure would no-op.
            service.lock.lock()
            let deferUnderPressure = service.pressurePauseEnsureAndWatch
            if deferUnderPressure {
                for id in deferredIDs where id != checkout.scheduleID {
                    guard var sch = service.schedules[id] else { continue }
                    sch.rerunRequested = true
                    if sch.dirtyGeneration == sch.builtGeneration {
                        sch.dirtyGeneration &+= 1
                    }
                    service.schedules[id] = sch
                }
            }
            service.lock.unlock()
            if !deferUnderPressure {
                for displayRoot in deferredRoots {
                    if let deferredCheckout = GraphifyGitProbe.identity(at: displayRoot)?.checkout {
                        service.startEnsureIfNeeded(checkout: deferredCheckout)
                    }
                }
            }
            if needRerun {
                // Replacement after cancel or trailing dirty during build.
                // startEnsureIfNeeded itself no-ops under pressure pause.
                service.startEnsureIfNeeded(checkout: checkout)
            }
        }
    }

    /// Fire-and-forget ensure (compat). Prefer `requestRefresh`.
    public func ensureAsync(checkout: GraphifyCheckout, mode: GraphifyEnsureMode = .update) {
        _ = mode
        requestRefresh(checkout: checkout, force: true)
    }

    @discardableResult
    public func ensureSync(checkout: GraphifyCheckout, mode: GraphifyEnsureMode = .update) -> GraphifyRootStatus {
        ensureSync(checkout: checkout, mode: mode, launchRebuildGeneration: nil)
    }

    @discardableResult
    public func ensureSync(
        checkout: GraphifyCheckout,
        mode: GraphifyEnsureMode = .update,
        launchRebuildGeneration: UInt64?
    ) -> GraphifyRootStatus {
        guard let binary = resolveBinary() else { return .unavailable }
        let artifact = artifactRoot(for: checkout)
        do {
            try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        } catch {
            return .error
        }

        let scanRoot = checkout.displayRoot
        if mode == .verify { return verify(checkout) }

        // Build into a generation-owned staging directory; promote graph.json only
        // after the final ownership check so a cancelled build cannot replace the
        // canonical artifact consumed by agents.
        let stagingName = "staging-\(launchRebuildGeneration ?? rebuildGeneration)"
        let staging = artifact.appendingPathComponent(stagingName, isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        var env = processEnvironment()
        let repoOut = URL(fileURLWithPath: scanRoot).appendingPathComponent("graphify-out")
        if writeInRepo {
            env.removeValue(forKey: "GRAPHIFY_OUT")
        } else {
            env["GRAPHIFY_OUT"] = staging.path
        }

        let result = run([binary, "update", scanRoot], cwd: scanRoot, env: env)

        func discardStaging() {
            try? FileManager.default.removeItem(at: staging)
            if writeInRepo {
                // Do not delete user repoOut wholesale; only skip promote.
            }
        }
        func isCancelledNow() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let generationStale = launchRebuildGeneration.map { $0 != rebuildGeneration } ?? false
            return generationStale
                || activeRebuildCancelled
                || (schedules[checkout.scheduleID]?.rebuildCancelled == true)
        }

        if isCancelledNow() {
            discardStaging()
            lock.lock()
            var s = schedules[checkout.scheduleID] ?? RefreshSchedule()
            s.displayRoot = checkout.displayRoot
            s.status = .missing
            s.rebuildCancelled = false
            schedules[checkout.scheduleID] = s
            lock.unlock()
            return .missing
        }
        let dest = graphJSONPath(for: checkout)

        // Locate produced graph under staging (or repoOut when writeInRepo).
        let producedCandidates: [URL] = {
            if writeInRepo {
                return [
                    repoOut.appendingPathComponent("graph.json"),
                    staging.appendingPathComponent("graph.json"),
                    staging.appendingPathComponent("graphify-out/graph.json"),
                ]
            }
            return [
                staging.appendingPathComponent("graph.json"),
                staging.appendingPathComponent("graphify-out/graph.json"),
            ]
        }()
        let produced = producedCandidates.first { FileManager.default.fileExists(atPath: $0.path) }

        if result.exit != 0 {
            discardStaging()
            if FileManager.default.fileExists(atPath: dest.path) {
                lock.lock()
                var s = schedules[checkout.scheduleID] ?? RefreshSchedule()
                s.displayRoot = checkout.displayRoot
                s.status = .stale
                schedules[checkout.scheduleID] = s
                lock.unlock()
                return .stale
            }
            return .error
        }

        guard let produced else {
            discardStaging()
            if FileManager.default.fileExists(atPath: dest.path) { return .stale }
            return .missing
        }

        // Enforce artifact size bound before promotion; keep previous valid graph.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: produced.path),
           let size = attrs[.size] as? NSNumber,
           size.intValue > GraphifyRuntimeHardening.maxArtifactBytes {
            discardStaging()
            if FileManager.default.fileExists(atPath: dest.path) { return .stale }
            return .error
        }

        // Prepare a generation-specific publish file outside the scheduler lock.
        let publishStaging = artifact.appendingPathComponent(
            "graph.json.promote-\(launchRebuildGeneration ?? rebuildGeneration)"
        )
        try? FileManager.default.removeItem(at: publishStaging)
        do {
            try FileManager.default.copyItem(at: produced, to: publishStaging)
        } catch {
            discardStaging()
            try? FileManager.default.removeItem(at: publishStaging)
            if FileManager.default.fileExists(atPath: dest.path) { return .stale }
            return .error
        }
        discardStaging()

        // Hold the cancellation lock across final ownership check + atomic rename
        // so a concurrent cancel cannot replace canonical graph.json with a
        // superseded generation's bytes.
        lock.lock()
        let generationStaleAtPromote = launchRebuildGeneration.map { $0 != rebuildGeneration } ?? false
        let cancelledAtPromote = generationStaleAtPromote
            || activeRebuildCancelled
            || (schedules[checkout.scheduleID]?.rebuildCancelled == true)
        if cancelledAtPromote {
            var s = schedules[checkout.scheduleID] ?? RefreshSchedule()
            s.displayRoot = checkout.displayRoot
            s.status = .missing
            s.rebuildCancelled = false
            schedules[checkout.scheduleID] = s
            lock.unlock()
            try? FileManager.default.removeItem(at: publishStaging)
            return .missing
        }
        // Backup previous canonical bytes so cancel-before-commit can restore.
        let previousBackup = artifact.appendingPathComponent(
            "graph.json.prev-\(launchRebuildGeneration ?? rebuildGeneration)"
        )
        try? FileManager.default.removeItem(at: previousBackup)
        let hadPreviousCanonical = FileManager.default.fileExists(atPath: dest.path)
        if hadPreviousCanonical {
            try? FileManager.default.copyItem(at: dest, to: previousBackup)
        }
        let promoted: Bool = {
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    _ = try FileManager.default.replaceItemAt(dest, withItemAt: publishStaging)
                } else {
                    try FileManager.default.moveItem(at: publishStaging, to: dest)
                }
                return true
            } catch {
                try? FileManager.default.removeItem(at: publishStaging)
                return false
            }
        }()
        if !promoted {
            try? FileManager.default.removeItem(at: previousBackup)
            lock.unlock()
            if FileManager.default.fileExists(atPath: dest.path) { return .stale }
            return .error
        }
        lock.unlock()

        if FileManager.default.fileExists(atPath: dest.path) {
            // Probe HEAD outside the scheduler lock (run() also takes the lock).
            let head = currentHead(checkout.displayRoot)
            // Single cancellation-owned commit boundary: schedule state + fingerprint
            // decision under lock; if cancelled before/while writing, roll back.
            lock.lock()
            let generationStaleBeforeCommit = launchRebuildGeneration.map { $0 != rebuildGeneration } ?? false
            let cancelledBeforeCommit = generationStaleBeforeCommit
                || activeRebuildCancelled
                || (schedules[checkout.scheduleID]?.rebuildCancelled == true)
            if cancelledBeforeCommit {
                var s = schedules[checkout.scheduleID] ?? RefreshSchedule()
                s.displayRoot = checkout.displayRoot
                s.status = .missing
                s.rebuildCancelled = false
                schedules[checkout.scheduleID] = s
                lock.unlock()
                // Restore previous canonical or remove cancelled promote.
                if hadPreviousCanonical, FileManager.default.fileExists(atPath: previousBackup.path) {
                    _ = try? FileManager.default.replaceItemAt(dest, withItemAt: previousBackup)
                } else {
                    try? FileManager.default.removeItem(at: dest)
                }
                try? FileManager.default.removeItem(at: previousBackup)
                return .missing
            }
            var s = schedules[checkout.scheduleID] ?? RefreshSchedule()
            let previousBuilt = s.builtGeneration
            let previousStatus = s.status
            let previousHead = s.lastHead
            let previousSuccess = s.lastSuccessfulUpdate
            s.displayRoot = checkout.displayRoot
            s.lastSuccessfulUpdate = Date()
            s.lastHead = head
            s.status = .fresh
            if s.dirtyGeneration == 0 { s.dirtyGeneration = 1 }
            s.builtGeneration = s.dirtyGeneration
            let committedBuilt = s.builtGeneration
            schedules[checkout.scheduleID] = s
            lock.unlock()

            saveFingerprint(checkout, head: head)

            // If cancel landed after schedule update, roll back freshness so a
            // cancelled build cannot survive restart as fresh.
            lock.lock()
            let generationStaleAfter = launchRebuildGeneration.map { $0 != rebuildGeneration } ?? false
            let cancelledAfterFingerprint = generationStaleAfter
                || activeRebuildCancelled
                || (schedules[checkout.scheduleID]?.rebuildCancelled == true)
            if cancelledAfterFingerprint {
                var rolled = schedules[checkout.scheduleID] ?? RefreshSchedule()
                rolled.builtGeneration = previousBuilt
                rolled.status = previousStatus == .fresh ? .stale : previousStatus
                rolled.lastHead = previousHead
                rolled.lastSuccessfulUpdate = previousSuccess
                rolled.rebuildCancelled = false
                schedules[checkout.scheduleID] = rolled
                lock.unlock()
                // Best-effort: remove fingerprint so restart does not warm cancelled gen.
                try? FileManager.default.removeItem(at: fingerprintPath(for: checkout))
                // Restore previous graph.json or delete cancelled promote (backup kept until here).
                if hadPreviousCanonical, FileManager.default.fileExists(atPath: previousBackup.path) {
                    _ = try? FileManager.default.replaceItemAt(dest, withItemAt: previousBackup)
                } else {
                    try? FileManager.default.removeItem(at: dest)
                }
                try? FileManager.default.removeItem(at: previousBackup)
                return .missing
            }
            // Confirm generation still matches our commit (no intervening ensure).
            if schedules[checkout.scheduleID]?.builtGeneration != committedBuilt {
                lock.unlock()
                try? FileManager.default.removeItem(at: previousBackup)
                return .missing
            }
            lock.unlock()
            try? FileManager.default.removeItem(at: previousBackup)
            return .fresh
        }
        return .missing
    }

    /// Merge Graphify env + kick refresh for an agent run. Used by AppCommandRouter
    /// and AgentAppSurface so the macOS UI path cannot bypass Graphify.
    @discardableResult
    public func applyToAgentEnvironment(
        base: [String: String],
        threadId: UUID?,
        threadCwd: String,
        worktreePath: String?,
        workspaceCwd: String,
        attachmentPaths: [String]
    ) -> (environment: [String: String], workingSet: GraphifyThreadWorkingSet) {
        var env = base
        // Fail-open when inactive: never leave stale/user-supplied RC_GRAPHIFY_* that
        // would re-enable query-first prompts without Token Saver.
        env = Self.stripGraphifyKeys(from: env)
        guard enabled else {
            return (env, GraphifyThreadWorkingSet(threadId: threadId, workspaceKind: "disabled", roots: [], ambiguous: false))
        }
        let set = authoritativeResolve(
            threadId: threadId,
            threadCwd: threadCwd,
            worktreePath: worktreePath,
            workspaceCwd: workspaceCwd,
            attachmentPaths: attachmentPaths,
            pinnedRoots: pinnedRoots
        )
        env["RC_GRAPHIFY_ENABLED"] = "1"
        env["RC_GRAPHIFY_INSTRUCTIONS"] = GraphifyStableSkillText.instructions
        if !set.roots.isEmpty {
            env["RC_GRAPHIFY_ROOTS"] = set.roots.map(\.checkout.displayRoot).joined(separator: "\n")
            if let first = set.roots.first {
                let artifact = first.artifactRoot ?? artifactRoot(for: first.checkout).path
                env["RC_GRAPHIFY_ARTIFACT_ROOT"] = artifact
                // Always expose on-disk graph when present — even for missing/error/ambiguous
                // status — so agents cannot false-negative by checking only repo graphify-out/.
                let graphJSON = graphJSONPath(for: first.checkout).path
                if FileManager.default.fileExists(atPath: graphJSON) {
                    env["RC_GRAPHIFY_GRAPH_JSON"] = graphJSON
                }
                switch first.status {
                case .fresh:
                    break
                case .stale, .building:
                    env["RC_GRAPHIFY_STALE"] = "1"
                case .missing, .error, .unavailable, .ambiguous:
                    break
                }
            }
        }
        if set.ambiguous {
            env["RC_GRAPHIFY_AMBIGUOUS"] = "1"
        }
        return (env, set)
    }

    /// Remove host-owned Graphify env keys (reserved namespace).
    public static func stripGraphifyKeys(from environment: [String: String]) -> [String: String] {
        var env = environment
        for key in environment.keys where key.hasPrefix("RC_GRAPHIFY_") {
            env.removeValue(forKey: key)
        }
        return env
    }

    /// Publish graph.json without a missing-file window. Returns false on failure.
    private func atomicallyPublish(from produced: URL, to dest: URL, stagingDir: URL) -> Bool {
        let staging = stagingDir.appendingPathComponent("graph.json.staging")
        try? FileManager.default.removeItem(at: staging)
        do {
            try FileManager.default.copyItem(at: produced, to: staging)
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: dest)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return false
        }
    }

    // MARK: FSEvents

    public func watchCheckout(_ checkout: GraphifyCheckout) {
        let id = checkout.scheduleID
        lock.lock()
        if watchers[id] != nil {
            lock.unlock()
            return
        }
        // Ignore ArtifactRoot (and nested paths) so host graph writes never loop FSEvents.
        // Also ignore in-repo graphify-out via noise filter in the watcher.
        let ignored = [artifactRoot(for: checkout).path]
        let watcher = GraphifyCheckoutWatcher(
            path: checkout.displayRoot,
            ignoredPathPrefixes: ignored
        ) { [weak self] in
            self?.markDirtyFromFilesystem(checkout: checkout)
        }
        watchers[id] = watcher
        lock.unlock()
        watcher.start()
    }

    public func stopWatchingAll() {
        // S9: cancel any in-flight rebuild before tearing down watchers so a
        // late Process completion cannot mark the graph fresh after Token Saver off.
        cancelInFlightRebuildIfNeeded()
        lock.lock()
        let all = watchers
        watchers.removeAll()
        // Mark every in-flight schedule cancelled so completion cannot publish fresh.
        for id in Array(schedules.keys) {
            guard var s = schedules[id] else { continue }
            s.rebuildCancelled = true
            s.rerunRequested = false
            schedules[id] = s
        }
        lock.unlock()
        for w in all.values { w.stop() }
    }

    /// Cancel the active graphify child and mark rebuilds cancelled (S9).
    /// Only sticky while a rebuild is actually in flight; idle cancel is a no-op
    /// so Token Saver off/on does not poison PATH/HEAD probes forever.
    /// Process terminate/kill wait runs off the calling thread so MainActor
    /// settings/lifecycle paths are not blocked for up to 1s.
    public func cancelInFlightRebuildIfNeeded() {
        lock.lock()
        let anyInFlight = globalCLIInFlight
            || schedules.values.contains(where: \.inFlight)
            || activeRebuildProcess != nil
        if !anyInFlight {
            activeRebuildCancelled = false
            lock.unlock()
            return
        }
        // Bump ownership generation so old launches cannot publish after this point.
        rebuildGeneration &+= 1
        activeRebuildCancelled = true
        let process = activeRebuildProcess
        for id in Array(schedules.keys) {
            guard var s = schedules[id], s.inFlight else { continue }
            s.rebuildCancelled = true
            s.rerunRequested = false
            if s.dirtyGeneration <= s.builtGeneration {
                s.dirtyGeneration = s.builtGeneration &+ 1
            }
            schedules[id] = s
        }
        lock.unlock()
        guard let process, process.isRunning else { return }
        DispatchQueue.global(qos: .utility).async {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    /// Inactive→active transition only. Dirties known schedules so edits made
    /// while watchers were down force a rebuild. Does **not** uncancel an
    /// in-flight old generation — rebuildGeneration ownership handles that.
    public func resumeAfterDisable() {
        let roots: [String]
        let unpauseGeneration: UInt64
        lock.lock()
        // Do not clear cancellation while an old process may still complete;
        // only clear when nothing is in flight.
        let anyInFlight = globalCLIInFlight
            || schedules.values.contains(where: \.inFlight)
            || activeRebuildProcess != nil
        if !anyInFlight {
            activeRebuildCancelled = false
        }
        for id in Array(schedules.keys) {
            guard var s = schedules[id] else { continue }
            // Keep rebuildCancelled on in-flight rows until they drain.
            if !s.inFlight {
                s.rebuildCancelled = false
            }
            s.dirtyGeneration = max(s.dirtyGeneration &+ 1, s.builtGeneration &+ 1)
            s.rerunRequested = true
            schedules[id] = s
        }
        roots = schedules.values.map(\.displayRoot).filter { !$0.isEmpty }
        // Treat as a new re-kick generation so stale async work aborts.
        pressureUnpauseGeneration &+= 1
        unpauseGeneration = pressureUnpauseGeneration
        lock.unlock()
        scheduleAsyncRootReKicks(roots: roots, unpauseGeneration: unpauseGeneration)
    }

    // MARK: Sticky

    public func stickyRoot(forWorkspace cwd: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return stickyByWorkspace[URL(fileURLWithPath: cwd).standardizedFileURL.path]
    }

    public func rememberSticky(workspaceCwd: String, displayRoot: String) {
        let ws = URL(fileURLWithPath: workspaceCwd).standardizedFileURL.path
        let root = URL(fileURLWithPath: displayRoot).standardizedFileURL.path
        lock.lock()
        stickyByWorkspace[ws] = root
        lock.unlock()
    }

    // MARK: Working set

    public func enrich(_ set: GraphifyThreadWorkingSet) -> GraphifyThreadWorkingSet {
        let roots = set.roots.map { binding -> GraphifyRootBinding in
            let st = verify(binding.checkout)
            return GraphifyRootBinding(
                checkout: binding.checkout,
                status: st,
                reason: binding.reason,
                artifactRoot: artifactRoot(for: binding.checkout).path
            )
        }
        return GraphifyThreadWorkingSet(
            threadId: set.threadId,
            workspaceKind: set.workspaceKind,
            roots: roots,
            ambiguous: set.ambiguous
        )
    }

    public func softPreflight(
        workspaceCwd: String,
        pinnedRoots: [String] = [],
        sticky: String? = nil
    ) -> GraphifyThreadWorkingSet {
        guard enabled else {
            return GraphifyThreadWorkingSet(threadId: nil, workspaceKind: "disabled", roots: [], ambiguous: false)
        }
        _ = ensureBinaryInstalledIfNeeded()
        let stickyResolved = sticky ?? stickyRoot(forWorkspace: workspaceCwd)
        let resolver = GraphifyRootResolver(
            pinnedRoots: pinnedRoots,
            stickyLastTouchedRoot: stickyResolved
        )
        let kind = resolver.classify(workspaceCwd: workspaceCwd)
        switch kind {
        case .singleRepo(let checkout):
            requestRefresh(checkout: checkout)
            rememberSticky(workspaceCwd: workspaceCwd, displayRoot: checkout.displayRoot)
            return GraphifyThreadWorkingSet(
                threadId: nil,
                workspaceKind: "singleRepo",
                roots: [GraphifyRootBinding(
                    checkout: checkout,
                    status: verify(checkout),
                    reason: "single_repo",
                    artifactRoot: artifactRoot(for: checkout).path
                )],
                ambiguous: false
            )
        case .multiRepoContainer:
            let bootstrapped = resolver.resolve(
                threadCwd: nil,
                worktreePath: nil,
                workspaceCwd: workspaceCwd,
                attachmentPaths: []
            )
            if !bootstrapped.roots.isEmpty {
                let enriched = enrich(bootstrapped)
                for root in enriched.roots { requestRefresh(checkout: root.checkout) }
                if let first = enriched.roots.first {
                    rememberSticky(workspaceCwd: workspaceCwd, displayRoot: first.checkout.displayRoot)
                }
                return enriched
            }
            if let pick = autoPickProductCheckout(containerCwd: workspaceCwd) {
                requestRefresh(checkout: pick)
                rememberSticky(workspaceCwd: workspaceCwd, displayRoot: pick.displayRoot)
                return GraphifyThreadWorkingSet(
                    threadId: nil,
                    workspaceKind: "multiRepoContainer",
                    roots: [GraphifyRootBinding(
                        checkout: pick,
                        status: verify(pick),
                        reason: "auto_bootstrap",
                        artifactRoot: artifactRoot(for: pick).path
                    )],
                    ambiguous: false
                )
            }
            return GraphifyThreadWorkingSet(
                threadId: nil,
                workspaceKind: "multiRepoContainer",
                roots: [],
                ambiguous: true
            )
        case .plainFolder:
            return GraphifyThreadWorkingSet(
                threadId: nil,
                workspaceKind: "plainFolder",
                roots: [],
                ambiguous: false
            )
        }
    }

    public func authoritativeResolve(
        threadId: UUID?,
        threadCwd: String?,
        worktreePath: String?,
        workspaceCwd: String,
        attachmentPaths: [String],
        pinnedRoots: [String] = []
    ) -> GraphifyThreadWorkingSet {
        guard enabled else {
            return GraphifyThreadWorkingSet(threadId: threadId, workspaceKind: "disabled", roots: [], ambiguous: false)
        }
        _ = ensureBinaryInstalledIfNeeded()
        let resolver = GraphifyRootResolver(
            pinnedRoots: pinnedRoots,
            stickyLastTouchedRoot: stickyRoot(forWorkspace: workspaceCwd)
        )
        var raw = resolver.resolve(
            threadId: threadId,
            threadCwd: threadCwd,
            worktreePath: worktreePath,
            workspaceCwd: workspaceCwd,
            attachmentPaths: attachmentPaths
        )
        if raw.roots.isEmpty, raw.workspaceKind == "multiRepoContainer",
           let pick = autoPickProductCheckout(containerCwd: workspaceCwd) {
            raw = GraphifyThreadWorkingSet(
                threadId: threadId,
                workspaceKind: "multiRepoContainer",
                roots: [GraphifyRootBinding(
                    checkout: pick,
                    status: .missing,
                    reason: "auto_bootstrap",
                    artifactRoot: artifactRoot(for: pick).path
                )],
                ambiguous: false
            )
        }
        // Every send: refresh all resolved roots (stale/missing/max-age/dirty).
        for root in raw.roots {
            requestRefresh(checkout: root.checkout)
        }
        let enriched = enrich(raw)
        if let first = enriched.roots.first {
            rememberSticky(workspaceCwd: workspaceCwd, displayRoot: first.checkout.displayRoot)
        }
        return enriched
    }

    public func autoPickProductCheckout(containerCwd: String) -> GraphifyCheckout? {
        let children = GraphifyGitProbe.discoverChildRepos(containerCwd: containerCwd)
        guard !children.isEmpty else { return nil }
        if children.count == 1 { return children[0] }

        struct Scored {
            let checkout: GraphifyCheckout
            let mtime: Date
        }
        var scored: [Scored] = []
        for child in children {
            let srcCount = approximateSourceFileCount(at: child.displayRoot, limit: autoBootstrapMaxSourceFiles + 1)
            if srcCount > autoBootstrapMaxSourceFiles { continue }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: child.displayRoot)[.modificationDate] as? Date) ?? .distantPast
            scored.append(Scored(checkout: child, mtime: mtime))
        }
        if scored.isEmpty {
            return children.min(by: {
                approximateSourceFileCount(at: $0.displayRoot, limit: 50_000)
                    < approximateSourceFileCount(at: $1.displayRoot, limit: 50_000)
            })
        }
        return scored.max(by: { $0.mtime < $1.mtime })?.checkout
    }

    private func approximateSourceFileCount(at root: String, limit: Int) -> Int {
        let rootURL = URL(fileURLWithPath: root)
        let skip: Set<String> = ["node_modules", ".git", "dist", ".next", "build", "vendor", "graphify-out"]
        let exts: Set<String> = ["ts", "tsx", "js", "jsx", "swift", "py", "go", "rs", "md", "vue", "php", "css", "html"]
        var count = 0
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        while let item = enumerator.nextObject() as? URL {
            if skip.contains(item.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard exts.contains(item.pathExtension.lowercased()) else { continue }
            count += 1
            if count > limit { return count }
        }
        return count
    }

    // MARK: Process

    /// True only for a direct graphify binary or `env graphify …` launch.
    /// False for `which graphify`, package pins containing "graphify", git, etc.
    static func isGraphifyCLIInvocation(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        let firstBase = URL(fileURLWithPath: first).lastPathComponent
        if firstBase == "graphify" { return true }
        // `/usr/bin/env graphify …`
        if firstBase == "env", args.count >= 2 {
            let secondBase = URL(fileURLWithPath: args[1]).lastPathComponent
            return secondBase == "graphify"
        }
        return false
    }

    private func run(_ args: [String], cwd: String, env: [String: String]?) -> (exit: Int32, stdout: String, stderr: String) {
        if let runProcess { return runProcess(args, cwd, env) }
        // Only the graphify CLI child is generation-owned for cancel. Helper
        // probes (`which graphify`, pip install args) must not match.
        let isGraphifyCLI = Self.isGraphifyCLIInvocation(args)
        lock.lock()
        // Generation-owned cancel: any bump after launch also aborts mid-run via
        // ensureSync checks; pre-spawn still honors sticky cancel flag.
        if isGraphifyCLI, activeRebuildCancelled {
            lock.unlock()
            return (-15, "", "graphify rebuild cancelled before spawn")
        }
        lock.unlock()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        if let env { p.environment = env }
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            return (-1, "", String(describing: error))
        }
        // S9: durable ownership tag before acceptance (tagProcess also records).
        // Fail-open when ownership store is unconfigured (tests / early boot).
        var ownershipTag: SpawnedProcessTag?
        if isGraphifyCLI, ProviderProcessOwnership.shared.store() != nil {
            do {
                ownershipTag = try ProcessSpawnTagger.tagProcess(p, managedKind: .graphify)
            } catch {
                // Bounded terminate/kill/reap so an untagged child cannot leak.
                ProcessTerminator.terminateTreeImmediately(p)
                let killDeadline = Date().addingTimeInterval(1)
                while p.isRunning && Date() < killDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                if !p.isRunning { p.waitUntilExit() }
                return (-1, "", "graphify ownership tag failed: \(error)")
            }
        }
        let trackedPID = p.processIdentifier
        if isGraphifyCLI {
            lock.lock()
            activeRebuildProcess = p
            let alreadyCancelled = activeRebuildCancelled
            lock.unlock()
            if alreadyCancelled {
                p.terminate()
            }
        }
        // Concurrent capped drain while the process runs so a verbose child cannot
        // fill pipes and hang until the full process timeout (S9).
        let timeout = processTimeoutSeconds > 0 ? processTimeoutSeconds : 180
        let deadline = Date().addingTimeInterval(timeout)
        let maxOut = GraphifyRuntimeHardening.maxStdoutCaptureBytes
        let maxErr = GraphifyRuntimeHardening.maxStderrCaptureBytes
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var storage = Data()
            private var finished = false
            func set(_ data: Data) {
                lock.lock(); storage = data; finished = true; lock.unlock()
            }
            func get() -> Data {
                lock.lock(); defer { lock.unlock() }
                return storage
            }
            var isFinished: Bool {
                lock.lock(); defer { lock.unlock() }
                return finished
            }
        }
        let outBox = Box()
        let errBox = Box()
        let q = DispatchQueue(label: "io.remotecode.graphify.pipe.drain", attributes: .concurrent)
        let outHandle = out.fileHandleForReading
        let errHandle = err.fileHandleForReading
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        q.async {
            outBox.set(BoundedPipeDrain.readRemaining(
                from: outHandle,
                timeout: timeout + 0.5,
                maxBytes: maxOut
            ))
            drainGroup.leave()
        }
        drainGroup.enter()
        q.async {
            errBox.set(BoundedPipeDrain.readRemaining(
                from: errHandle,
                timeout: timeout + 0.5,
                maxBytes: maxErr
            ))
            drainGroup.leave()
        }
        while p.isRunning && Date() < deadline {
            lock.lock()
            let cancelled = activeRebuildCancelled
            lock.unlock()
            if cancelled {
                // Signal whole process group so descendants cannot outlive the root.
                ProcessTerminator.terminateTreeImmediately(p)
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        var timedOut = false
        if p.isRunning {
            timedOut = true
            ProcessTerminator.terminateTreeImmediately(p)
            let killDeadline = Date().addingTimeInterval(1)
            while p.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if p.isRunning {
                kill(p.processIdentifier, SIGKILL)
                // Negative PID = process group (when isolated).
                kill(-p.processIdentifier, SIGKILL)
            }
        }
        // Always reap; SIGKILL path still needs waitUntilExit when possible.
        if p.isRunning {
            // Last chance reap under short bound.
            let reapDeadline = Date().addingTimeInterval(0.5)
            while p.isRunning && Date() < reapDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        if !p.isRunning {
            p.waitUntilExit()
        }
        // Extra group drain: any surviving same-pgid descendants are signalled.
        if let group = ownershipTag?.isolatedProcessGroup ?? (isGraphifyCLI ? p.processIdentifier : nil) {
            let members = ProcessTerminator.processGroupPIDs(group)
            for member in members where member != p.processIdentifier && member > 0 {
                kill(member, SIGTERM)
            }
            Thread.sleep(forTimeInterval: 0.05)
            for member in members where member != p.processIdentifier && member > 0 {
                if kill(member, 0) == 0 {
                    kill(member, SIGKILL)
                }
            }
        }
        // Unblock drains: close write ends so EOF can arrive.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        // Join drains under absolute remaining budget; do not read boxes until finished
        // or the hard deadline expires (then still lock-safe snapshot).
        let hardJoinDeadline = Date().addingTimeInterval(max(0.1, deadline.timeIntervalSinceNow + 0.6))
        while true {
            let waitMs = max(10, Int(hardJoinDeadline.timeIntervalSinceNow * 1000))
            if drainGroup.wait(timeout: .now() + .milliseconds(min(waitMs, 100))) == .success {
                break
            }
            if Date() >= hardJoinDeadline { break }
            if outBox.isFinished && errBox.isFinished { break }
        }
        if isGraphifyCLI {
            // Clear by exact PID so a concurrent helper cannot clobber a newer CLI child.
            lock.lock()
            if activeRebuildProcess?.processIdentifier == trackedPID {
                activeRebuildProcess = nil
            }
            lock.unlock()
        }
        // S9: remove ownership only when the certified group/tree is fully dead.
        // Surviving descendants keep the row so relaunch sweep can reap them.
        if let ownershipTag {
            let group = ownershipTag.isolatedProcessGroup ?? ownershipTag.pgid
            let survivors = ProcessTerminator.processGroupPIDs(group).filter { pid in
                pid > 0 && kill(pid, 0) == 0
            }
            if survivors.isEmpty {
                try? ProviderProcessOwnership.shared.store()?.removeExact(ownershipTag)
            }
            // else: retain tag for ProviderProcessSweeper on relaunch
        }
        let oData = outBox.get()
        let eData = errBox.get()
        if timedOut {
            return (-9, String(data: oData, encoding: .utf8) ?? "", "graphify process timed out after \(Int(timeout))s")
        }
        return (
            p.terminationStatus,
            String(data: oData, encoding: .utf8) ?? "",
            String(data: eData, encoding: .utf8) ?? ""
        )
    }
}
