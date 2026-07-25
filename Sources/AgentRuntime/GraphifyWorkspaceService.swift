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
    public var maxAgeFresh: TimeInterval = 45
    /// Minimum gap between CLI update starts for the same checkout (anti-thrash).
    public var minRebuildInterval: TimeInterval = 15
    /// Trailing debounce after FSEvents dirty marks.
    public var fseventsDebounce: TimeInterval = 2.5

    private let lock = NSLock()
    private var stickyByWorkspace: [String: String] = [:]
    private var schedules: [String: RefreshSchedule] = [:]
    private var watchers: [String: GraphifyCheckoutWatcher] = [:]
    private var debounceWork: [String: DispatchWorkItem] = [:]
    private var binaryInstallAttempted = false

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

    private struct RefreshSchedule {
        var dirtyGeneration: UInt64 = 0
        var builtGeneration: UInt64 = 0
        var inFlight: Bool = false
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
        if let existing = resolveBinary() { return existing }
        lock.lock()
        let already = binaryInstallAttempted
        if !already { binaryInstallAttempted = true }
        lock.unlock()
        guard !already else { return resolveBinary() }
        LoginShellEnvironment.prewarm()
        let env = processEnvironment()
        let attempts: [[String]] = [
            ["/usr/bin/env", "uv", "tool", "install", "--upgrade", "graphifyy", "-q"],
            ["/usr/bin/env", "pipx", "install", "graphifyy"],
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
        var env = ProcessInfo.processInfo.environment
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
        return env
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
        return try? JSONDecoder().decode(Fingerprint.self, from: data)
    }

    private func saveFingerprint(_ checkout: GraphifyCheckout, head: String?) {
        let fp = Fingerprint(head: head, displayRoot: checkout.displayRoot, builtAt: Date().timeIntervalSince1970)
        let url = fingerprintPath(for: checkout)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(fp) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Ensure scheduler

    private func startEnsureIfNeeded(checkout: GraphifyCheckout) {
        guard enabled, autoEnsure else { return }

        // Cheap disk/git probes OUTSIDE the lock (avoid holding NSLock across Process I/O).
        let graphExists = FileManager.default.fileExists(atPath: graphJSONPath(for: checkout).path)
        let headStale = isHeadStale(checkout: checkout)
        let fp = loadFingerprint(checkout)

        lock.lock()
        var schedule = schedules[checkout.scheduleID] ?? RefreshSchedule()
        schedule.displayRoot = checkout.displayRoot

        if schedule.inFlight {
            schedule.rerunRequested = true
            schedules[checkout.scheduleID] = schedule
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
        schedule.lastEnsureStarted = Date()
        schedule.status = .building
        let targetGen = schedule.dirtyGeneration
        schedules[checkout.scheduleID] = schedule
        lock.unlock()

        let service = self
        DispatchQueue.global(qos: .utility).async {
            let status = service.ensureSync(checkout: checkout, mode: .update)
            service.lock.lock()
            var s = service.schedules[checkout.scheduleID] ?? RefreshSchedule()
            s.inFlight = false
            s.status = status
            if status == .fresh {
                s.builtGeneration = targetGen
                s.lastSuccessfulUpdate = Date()
                s.lastHead = service.currentHead(checkout.displayRoot)
            }
            let needRerun = s.rerunRequested || s.dirtyGeneration > s.builtGeneration
            s.rerunRequested = false
            service.schedules[checkout.scheduleID] = s
            service.lock.unlock()

            if status == .fresh {
                service.saveFingerprint(checkout, head: service.currentHead(checkout.displayRoot))
            }
            if needRerun {
                // Exactly one trailing update for changes during the build.
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
        guard let binary = resolveBinary() else { return .unavailable }
        let artifact = artifactRoot(for: checkout)
        do {
            try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        } catch {
            return .error
        }

        let scanRoot = checkout.displayRoot
        if mode == .verify { return verify(checkout) }

        // Output location:
        // - default writeInRepo=false → GRAPHIFY_OUT=<ArtifactRoot> (absolute). Graphify writes
        //   graph.json/cache/report there and does NOT create repo/graphify-out/.
        // - writeInRepo=true → default relative graphify-out under the checkout (team-commit layout).
        var env = processEnvironment()
        let repoOut = URL(fileURLWithPath: scanRoot).appendingPathComponent("graphify-out")
        if writeInRepo {
            env.removeValue(forKey: "GRAPHIFY_OUT")
        } else {
            env["GRAPHIFY_OUT"] = artifact.path
        }

        let result = run([binary, "update", scanRoot], cwd: scanRoot, env: env)
        let dest = graphJSONPath(for: checkout)

        if writeInRepo {
            // CLI wrote to checkout/graphify-out/; mirror into ArtifactRoot for stable agent paths.
            let produced = repoOut.appendingPathComponent("graph.json")
            if FileManager.default.fileExists(atPath: produced.path) {
                if !atomicallyPublish(from: produced, to: dest, stagingDir: artifact) {
                    if FileManager.default.fileExists(atPath: dest.path) { return .stale }
                    return .error
                }
            }
        } else {
            // GRAPHIFY_OUT absolute: graph.json already lives at ArtifactRoot/graph.json.
            // Never leave a stray graphify-out in the user tree from this host path.
            // (Do not delete user-created graphify-out; only avoid creating one.)
            if !FileManager.default.fileExists(atPath: dest.path) {
                // Some CLI versions may still nest under GRAPHIFY_OUT/graphify-out/
                let nested = artifact.appendingPathComponent("graphify-out/graph.json")
                if FileManager.default.fileExists(atPath: nested.path) {
                    _ = atomicallyPublish(from: nested, to: dest, stagingDir: artifact)
                }
            }
        }

        // Only advance fingerprint/generations on a successful CLI update that
        // left a usable graph. Non-zero exit with a previous graph stays .stale
        // so the agent gets RC_GRAPHIFY_STALE (never silently "fresh" on failure).
        if result.exit != 0 {
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

        if FileManager.default.fileExists(atPath: dest.path) {
            let head = currentHead(checkout.displayRoot)
            saveFingerprint(checkout, head: head)
            lock.lock()
            var s = schedules[checkout.scheduleID] ?? RefreshSchedule()
            s.displayRoot = checkout.displayRoot
            s.lastSuccessfulUpdate = Date()
            s.lastHead = head
            s.status = .fresh
            if s.dirtyGeneration == 0 { s.dirtyGeneration = 1 }
            s.builtGeneration = s.dirtyGeneration
            schedules[checkout.scheduleID] = s
            lock.unlock()
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
        lock.lock()
        let all = watchers
        watchers.removeAll()
        lock.unlock()
        for w in all.values { w.stop() }
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

    private func run(_ args: [String], cwd: String, env: [String: String]?) -> (exit: Int32, stdout: String, stderr: String) {
        if let runProcess { return runProcess(args, cwd, env) }
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
        // Parallel drain avoids classic Process deadlock when stderr fills the pipe.
        final class Box: @unchecked Sendable { var data = Data() }
        let errBox = Box()
        let q = DispatchQueue(label: "io.remotecode.graphify.pipe.drain")
        let errHandle = err.fileHandleForReading
        q.async { errBox.data = errHandle.readDataToEndOfFile() }
        let oData = out.fileHandleForReading.readDataToEndOfFile()
        q.sync {}
        // Bounded wait: wedged graphify/git must not leave schedule inFlight forever.
        let timeout = processTimeoutSeconds > 0 ? processTimeoutSeconds : 180
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            p.terminate()
            // brief grace then kill
            let killDeadline = Date().addingTimeInterval(1)
            while p.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            return (-9, String(data: oData, encoding: .utf8) ?? "", "graphify process timed out after \(Int(timeout))s")
        }
        p.waitUntilExit()
        return (
            p.terminationStatus,
            String(data: oData, encoding: .utf8) ?? "",
            String(data: errBox.data, encoding: .utf8) ?? ""
        )
    }
}
