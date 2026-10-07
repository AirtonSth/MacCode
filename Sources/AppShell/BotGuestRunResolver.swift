import Foundation
import os
import AgentRuntime
import CoreModel
import Persistence
import SocketServer

private let guestResolverLog = Logger(subsystem: "io.remotecode.agent", category: "bot.guest")

/// The bot container a guest run executes in, once it is current, running and
/// has the run's workspace mounted.
struct BotGuestVM: Equatable, Sendable {
    var container: String
    /// `docker info` Architecture (picks the guest Distill asset).
    var dockerArch: String
    /// Host paths bound at the same path inside the guest.
    var mountedWorkspaces: [String]
}

/// Brings a bot's container up for a guest run. Blocking (Docker CLI); the
/// resolver calls it on a dispatch queue, never on the cooperative pool.
protocol BotGuestVMPreparing: Sendable {
    /// `workspace` nil: a workspace-less (desk) thread, provision only.
    func prepare(
        botID: BotID,
        threadID: AgentThreadID,
        workspace: String?,
        registeredWorkspaces: Set<String>
    ) throws -> BotGuestVM
}

/// Decides and prepares, per Distill run, whether it runs inside its bot's
/// Linux guest (plan A).
///
/// Only threads carrying the durable guest marker (`BotGuestRuntime`) on a
/// `.vm` target go to the guest; legacy `.vm` threads keep their Mac sessions.
/// A guest thread never falls back to the Mac: every failure throws.
///
/// One guest run per bot: the registry claim (`tryBegin`) is taken here, at
/// the spawn point every send path goes through, and refuses another
/// conversation's run ("bot ocupado"); the coordinator's run-finished callback
/// frees it. The per-bot lease then makes the run wait until the previous
/// run's guest process is dead and its sign-in copies are gone.
///
/// Stop while a run is still preparing (an image build can take minutes)
/// invalidates the run's acceptance permit; preparation then stops at its
/// next step and undoes what it did, so nothing is provisioned, copied or
/// spawned for a run the user already stopped.
final class BotGuestRunResolver: DistillGuestLaunchResolving, @unchecked Sendable {
    struct Dependencies: @unchecked Sendable {
        var threadRepo: AgentThreadRepository
        var botStore: BotStore
        var appSupport: URL
        var registry: BotVMRunRegistry = .shared
        var leases = DistillGuestLeases()
        var barrier: DistillGuestLaunchBarrier
        var gateway: BotGuestMCPGateway
        var vm: any BotGuestVMPreparing
        /// In-guest path of the verified Distill binary for a Docker architecture.
        var binaryGuestPath: @Sendable (_ hostBinary: String?, _ dockerArch: String) async throws -> String
        /// Renews the Mac sign-in a run's model uses when it expires soon.
        var refresh: @Sendable (_ hostHome: URL, _ provider: DistillAccountProvider?) async throws -> Void
        var dockerExecutable: @Sendable () throws -> String
        /// Registered workspace roots by id (MainActor state in the app).
        var workspaces: @Sendable () async -> [WorkspaceID: String]
        /// The Mac distill binary, for its version (nil: not installed).
        var hostBinary: @Sendable (_ request: AgentRunRequest) -> String?
        var gitIdentity: @Sendable () -> GitIdentity?
        /// The app's own environment, under the run's (DISTILL_HOME, model keys).
        var processEnvironment: [String: String] = ProcessInfo.processInfo.environment
        var heartbeatInterval: TimeInterval = BotGuestLeaseHeartbeat.interval
        /// False in a process that does not own the app's bot guests (the
        /// scheduled-task agent): its guest threads fail instead of racing
        /// the app for the same bot.
        var hostsGuestRuns = true
    }

    private let deps: Dependencies
    private let lock = NSLock()
    private var mirrors: [String: DistillGuestCredentialMirror] = [:]
    /// Plans handed out and not yet torn down, by run id.
    private var livePlans: [String: DistillGuestLaunchPlan] = [:]

    init(_ dependencies: Dependencies) {
        self.deps = dependencies
    }

    // MARK: - DistillGuestLaunchResolving

    func isGuestThread(_ threadId: AgentThreadID) -> Bool {
        (try? deps.threadRepo.guestPlacement(of: threadId))??.runsInGuest == true
    }

    func prepare(
        _ request: AgentRunRequest,
        progress: @escaping @Sendable (DistillGuestStage) -> Void
    ) async throws -> DistillGuestLaunchPlan? {
        guard let placement = try deps.threadRepo.guestPlacement(of: request.threadId),
              placement.runsInGuest else { return nil }
        let work = Task { try await self.prepareGuestRun(request, placement: placement, progress: progress) }
        request.acceptancePermit?.onInvalidate { work.cancel() }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func prepareGuestRun(
        _ request: AgentRunRequest,
        placement: AgentThreadGuestPlacement,
        progress: @escaping @Sendable (DistillGuestStage) -> Void
    ) async throws -> DistillGuestLaunchPlan {
        guard placement.guestRuntime == BotGuestRuntime.distillV1 else {
            throw DistillGuestLaunchError.unavailable(
                "this conversation was set up by a newer RemoteCode; update RemoteCode to run it."
            )
        }
        guard deps.hostsGuestRuns else {
            throw DistillGuestLaunchError.unavailable("bot Linux VM runs only start from the RemoteCode app.")
        }
        // The guest gets the app user's own sign-ins; a run meant for another
        // macOS user must not run with them.
        if let runAsUser = request.runAsUser, runAsUser.uid != getuid() {
            throw DistillGuestLaunchError.unavailable(
                "this conversation runs as the macOS user \(runAsUser.shortName); bot Linux VM runs use only your own accounts."
            )
        }
        guard let thread = try deps.threadRepo.get(id: request.threadId) else {
            throw DistillGuestLaunchError.unavailable("the conversation no longer exists.")
        }
        let botID = try dockerBot(of: thread)
        try await deps.barrier.wait()

        let claim = BotVMRunRegistry.Entry(
            threadID: request.threadId, runID: request.runId, title: thread.title, workspace: request.cwd
        )
        if let holder = deps.registry.tryBegin(botID: botID, entry: claim) {
            throw DistillGuestLaunchError.busy("bot ocupado em \(holder.title)")
        }
        // From here the claim is the coordinator's to free (run finished,
        // which also fires for a failed start): freeing it here would skip
        // the queued send that run-finished hands to the next thread.
        let leaseKey = botID.value.uuidString.lowercased()
        if await deps.leases.isHeld(leaseKey) { progress(.waitingForBot) }
        let lease = try await deps.leases.acquire(leaseKey)
        let runID = request.runId.value.uuidString.lowercased()
        var undo: [() -> Void] = []
        do {
            // A lease handed over just before a Stop is this run's to free.
            try Task.checkCancellation()
            progress(.startingVM)
            let workspace = try await workspaceRoot(of: thread)
            let registered = Set(await deps.workspaces().values)
            let vmPreparer = deps.vm
            let vm = try await Self.blocking {
                try vmPreparer.prepare(
                    botID: botID, threadID: request.threadId,
                    workspace: workspace, registeredWorkspaces: registered
                )
            }
            try Task.checkCancellation()
            let guestCwd = try Self.guestCwd(
                requestCwd: request.cwd, workspace: workspace, mounted: vm.mountedWorkspaces
            )

            progress(.preparingAgent)
            let binaryPath = try await deps.binaryGuestPath(deps.hostBinary(request), vm.dockerArch)
            let dockerExecutable = try deps.dockerExecutable()
            try Task.checkCancellation()

            progress(.signingIn)
            let hostEnvironment = deps.processEnvironment.merging(request.environment) { _, run in run }
            let hostHome = DistillProvisioner.homeURL(environment: hostEnvironment)
            let hostConfig = (try? String(
                contentsOf: hostHome.appendingPathComponent("config.toml"), encoding: .utf8
            )) ?? ""
            let provider = DistillGuestCredentials.accountProvider(model: request.model, hostConfig: hostConfig)
            try await deps.refresh(hostHome, provider)
            try Task.checkCancellation()
            let guestHome = BotComputerGuestSpec.guestHomeURL(appSupport: deps.appSupport, botID: botID)
            let guestDistillHome = DistillGuestCredentials.distillHome(guestHome: guestHome)
            let mirror = mirror(hostHome: hostHome)
            try mirror.begin(runID: runID, guestDistillHome: guestDistillHome, provider: provider)
            undo.append { mirror.end(runID: runID) }

            let gateway = deps.gateway
            let issued = try gateway.issue(BotGuestMCPGateway.Binding(
                runID: runID,
                hostEnvironment: BotGuestMCPGateway.Binding.hostEnvironment(fromRunEnvironment: request.environment)
            ))
            undo.append { gateway.revoke(runID: runID) }
            let rendered = DistillGuestConfig.render(
                hostConfig: hostConfig, gatewayPort: issued.port, hostEnvironment: hostEnvironment
            )
            if let reason = rendered.droppedModels[request.model] {
                throw DistillGuestLaunchError.unavailable(
                    "the model \(request.model) cannot run in the bot's Linux VM: \(reason)"
                )
            }
            // Relative to a no-follow descriptor: the guest can swap its
            // `.distill` for a symlink to any Mac folder at any moment.
            let distillDirectory = try PrivateDirectory(guestDistillHome, create: true)
            defer { distillDirectory.close() }
            try distillDirectory.writeAtomically(Data(rendered.toml.utf8), to: "config.toml")
            let environment = DistillGuestEnvironment.build(
                providerEnvironment: request.environment,
                runID: runID,
                gatewayToken: issued.token,
                modelSecrets: rendered.secretEnvironment,
                gitIdentity: deps.gitIdentity()
            )
            let envFile = try DistillGuestEnvironment.writeEnvFile(
                environment, runID: runID,
                directory: DistillGuestEnvironment.runsDirectory(appSupport: deps.appSupport)
            )
            undo.append { unlink(envFile.path) }
            // Before the agent starts: its reaper ends a run with no lease.
            let heartbeat = try BotGuestLeaseHeartbeat(
                guestHome: guestHome, runID: runID, interval: deps.heartbeatInterval
            )
            undo.append { heartbeat.stop() }
            let guestCommand = try DistillGuestLaunchPlan.guestCommand(binaryPath: binaryPath, for: request)
            try Task.checkCancellation()

            progress(.launching)
            guestResolverLog.info(
                "bot.guest.prepared run=\(runID, privacy: .public) bot=\(leaseKey, privacy: .public) binary=\(binaryPath, privacy: .public)"
            )
            let plan = DistillGuestLaunchPlan(
                runID: runID,
                dockerExecutable: dockerExecutable,
                container: vm.container,
                guestCwd: guestCwd,
                guestCommand: guestCommand,
                envFileURL: envFile,
                lease: lease,
                teardown: { [weak self] _ in
                    heartbeat.stop()
                    mirror.end(runID: runID)
                    gateway.revoke(runID: runID)
                    self?.forgetPlan(runID: runID)
                }
            )
            lock.withLock { livePlans[runID] = plan }
            return plan
        } catch {
            undo.reversed().forEach { $0() }
            await lease.release()
            if error is CancellationError {
                guestResolverLog.info(
                    "bot.guest.prepare_stopped run=\(runID, privacy: .public) bot=\(leaseKey, privacy: .public)"
                )
            } else {
                guestResolverLog.error(
                    "bot.guest.prepare_failed run=\(runID, privacy: .public) bot=\(leaseKey, privacy: .public)"
                )
            }
            throw Self.launchError(error)
        }
    }

    // MARK: - App termination

    /// App quit, synchronous: ends every guest run this app still owns
    /// (including one whose turn is still ending, which the adapter no longer
    /// tracks) with a fire-and-forget `kill-agent`, stops renewing their
    /// sign-in copies, and deletes every copy, env file and lease, as the
    /// next launch would. A run whose kill does not land is ended by its
    /// guest reaper once its lease stops changing. A process that does not
    /// host guest runs (the scheduled-task agent) leaves the app's alone.
    func endRunsForAppTermination() {
        guard deps.hostsGuestRuns else { return }
        let (plans, mirrors) = lock.withLock { (Array(livePlans.values), Array(self.mirrors.values)) }
        plans.forEach { $0.killGuestDetached() }
        mirrors.forEach { $0.endAll() }
        BotGuestLaunchSweep.removeLeftovers(appSupport: deps.appSupport)
        guestResolverLog.info("bot.guest.app_termination runs=\(plans.count, privacy: .public)")
    }

    private func forgetPlan(runID: String) {
        lock.withLock { _ = livePlans.removeValue(forKey: runID) }
    }

    // MARK: - Rules

    /// The bot whose Docker desktop runs this thread.
    private func dockerBot(of thread: AgentThread) throws -> BotID {
        let linked = thread.actor.botID ?? (try? deps.botStore.conversationLinked(to: thread.id))??.botID
        guard let botID = linked,
              let bot = try deps.botStore.get(id: botID), bot.deletedAt == nil else {
            throw DistillGuestLaunchError.unavailable("the bot of this conversation no longer exists.")
        }
        let revision = try bot.currentRevisionID.flatMap { try deps.botStore.getRevision(id: $0) }
        guard revision?.desktopKind == .dockerDesktop else {
            throw DistillGuestLaunchError.unavailable("this bot no longer has a Docker desktop.")
        }
        return botID
    }

    /// The registered workspace root a workspace thread mounts; nil for a
    /// workspace-less (desk) thread.
    private func workspaceRoot(of thread: AgentThread) async throws -> String? {
        guard let workspaceID = thread.workspaceId else { return nil }
        guard let root = await deps.workspaces()[workspaceID] else {
            throw DistillGuestLaunchError.unavailable("this conversation's workspace is no longer open in RemoteCode.")
        }
        return root
    }

    /// Where the agent runs inside the guest. A desk thread runs in the guest
    /// user's home. A workspace thread runs at its own path, which must be
    /// the mounted workspace or inside it; anything else fails rather than
    /// silently running somewhere else. A linked git worktree also needs the
    /// repository its `.git` file points at to be mounted, or git fails inside.
    static func guestCwd(requestCwd: String, workspace: String?, mounted: [String]) throws -> String {
        guard workspace != nil else { return BotComputerGuestSpec.guestUserHome }
        let cwd = URL(fileURLWithPath: requestCwd).resolvingSymlinksInPath().standardizedFileURL.path
        guard let mount = mountContaining(cwd, mounted) else {
            throw DistillGuestLaunchError.unavailable(
                "this conversation's folder \(cwd) is not inside a folder mounted in the bot's Linux VM."
            )
        }
        if let gitDir = linkedGitDir(from: cwd, upTo: mount), mountContaining(gitDir, mounted) == nil {
            throw DistillGuestLaunchError.unavailable(
                "this conversation's git worktree belongs to a repository at \(gitDir), which is not mounted in the bot's Linux VM."
            )
        }
        return cwd
    }

    private static func mountContaining(_ path: String, _ mounted: [String]) -> String? {
        mounted.first { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// The git directory a `.git` file (`gitdir: <path>`) between `path` and
    /// `root` points at; nil when the nearest `.git` is a directory or absent.
    static func linkedGitDir(from path: String, upTo root: String) -> String? {
        var directory = URL(fileURLWithPath: path, isDirectory: true)
        while true {
            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                guard !isDirectory.boolValue,
                      let text = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = text.split(whereSeparator: \.isNewline).first,
                      line.hasPrefix("gitdir:") else { return nil }
                let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let url = target.hasPrefix("/")
                    ? URL(fileURLWithPath: target)
                    : directory.appendingPathComponent(target)
                return url.resolvingSymlinksInPath().standardizedFileURL.path
            }
            if directory.path == root || directory.path == "/" { return nil }
            directory.deleteLastPathComponent()
        }
    }

    // MARK: - Helpers

    private func mirror(hostHome: URL) -> DistillGuestCredentialMirror {
        lock.withLock {
            if let mirror = mirrors[hostHome.path] { return mirror }
            let refresh = deps.refresh
            let mirror = DistillGuestCredentialMirror(
                hostHome: hostHome,
                refresh: { provider in try await refresh(hostHome, provider) },
                onRefreshFailure: { runIDs, _ in
                    guestResolverLog.error("bot.guest.credentials.refresh_failed runs=\(runIDs.count, privacy: .public)")
                }
            )
            mirrors[hostHome.path] = mirror
            return mirror
        }
    }

    static func launchError(_ error: Error) -> Error {
        if error is DistillGuestLaunchError || error is CancellationError { return error }
        let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return DistillGuestLaunchError.unavailable(reason)
    }

    /// Runs Docker and file work on a dispatch queue: it blocks for seconds,
    /// which would starve Swift's cooperative pool.
    static func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}

/// Renews `<guest home>/.rc-runs/<runId>.lease` while the Mac owns a guest
/// run. The guest's reaper (run-agent) ends a run whose lease has not changed
/// for 45 s, which is what stops it after the app crashes or is killed. Each
/// renewal re-creates the file (temp + rename): the agent can delete it.
/// The agent owns `.rc-runs` too and can swap it for a symlink to a Mac
/// folder, so every write and delete goes through a no-follow descriptor
/// reopened each time; a swapped `.rc-runs` makes renewals fail (and the
/// reaper end the run), never write into the Mac folder.
final class BotGuestLeaseHeartbeat: @unchecked Sendable {
    static let interval: TimeInterval = 10

    let fileURL: URL
    private let directoryURL: URL
    private let queue = DispatchQueue(label: "io.remotecode.bot-guest.lease", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var renewals = 0

    /// Writes the lease once before returning; throws when it cannot.
    init(guestHome: URL, runID: String, interval: TimeInterval = BotGuestLeaseHeartbeat.interval) throws {
        directoryURL = guestHome.appendingPathComponent(".rc-runs", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("\(runID).lease")
        try queue.sync { try renew() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            do {
                try self.renew()
            } catch {
                guestResolverLog.error("bot.guest.lease.renew_failed file=\(self.fileURL.lastPathComponent, privacy: .public)")
            }
        }
        self.timer = timer
        timer.resume()
    }

    deinit { timer?.cancel() }

    /// Idempotent. Removes the lease so a leftover agent is reaped.
    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            timer?.cancel()
            timer = nil
            guard let directory = try? PrivateDirectory(directoryURL, create: false) else { return }
            directory.remove(fileURL.lastPathComponent)
            directory.close()
        }
    }

    private func renew() throws {
        renewals += 1
        let directory = try PrivateDirectory(directoryURL, create: true)
        defer { directory.close() }
        try directory.writeAtomically(Data("\(renewals)\n".utf8), to: fileURL.lastPathComponent)
    }
}

/// The production `BotGuestVMPreparing`: Docker up, container current and
/// running (an outdated one is replaced: this run is the bot's only one),
/// workspace mounted, and the agent's tools present.
final class BotGuestDockerVM: BotGuestVMPreparing, @unchecked Sendable {
    /// What the in-guest agent and its MCP servers execute (run-agent's
    /// reaper needs setsid; linux-use needs the X11 tools and ImageMagick).
    static let requiredTools = ["setsid", "git", "python3", "xdotool", "wmctrl", "xwd", "playwright-mcp"]

    private let appSupport: URL
    private let docker: any BotComputerDockerClienting
    private let service: BotComputerGuestService
    private let lock = NSLock()
    /// Container name → image whose tools passed the probe. Tools come from
    /// the image, so a container keeps its result until it is recreated.
    private var probedImages: [String: String] = [:]

    init(appSupport: URL, docker: any BotComputerDockerClienting, service: BotComputerGuestService) {
        self.appSupport = appSupport
        self.docker = docker
        self.service = service
    }

    func prepare(
        botID: BotID,
        threadID: AgentThreadID,
        workspace: String?,
        registeredWorkspaces: Set<String>
    ) throws -> BotGuestVM {
        let info = try docker.info()
        guard let arch = DistillGuestBinaryProvisioner.dockerArchitecture(fromInfo: info) else {
            throw DistillGuestLaunchError.unavailable("Docker did not report its CPU architecture.")
        }
        if let workspace {
            try service.ensureWorkspaceMounted(
                botID: botID, workspace: workspace,
                registered: registeredWorkspaces, requestingThreadID: threadID
            )
        }
        let ready = try service.provision(botID: botID, requestingThreadID: threadID)
        try checkTools(container: ready.containerID, image: ready.imageReference, recreated: !ready.resumed)
        let manifest = BotComputerGuestSpec.workspacesURL(appSupport: appSupport, botID: botID)
        let mounted = (try? Data(contentsOf: manifest))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return BotGuestVM(container: ready.containerID, dockerArch: arch, mountedWorkspaces: mounted)
    }

    static let toolsProbeScript =
        "for t in " + requiredTools.joined(separator: " ")
        + "; do command -v \"$t\" >/dev/null 2>&1 || printf '%s ' \"$t\"; done; "
        + "command -v convert >/dev/null 2>&1 || command -v magick >/dev/null 2>&1 || printf 'convert '"

    private func checkTools(container: String, image: String, recreated: Bool) throws {
        let cached = lock.withLock { () -> Bool in
            if recreated { probedImages[container] = nil }
            return probedImages[container] == image
        }
        if cached { return }
        let output = try docker.exec(
            name: container,
            command: ["sh", "-c", Self.toolsProbeScript],
            user: BotComputerGuestSpec.agentUser,
            detach: false
        )
        let missing = (String(data: output, encoding: .utf8) ?? "")
            .split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard missing.isEmpty else {
            throw DistillGuestLaunchError.unavailable(
                "the bot's Linux image lacks \(missing.joined(separator: ", ")). "
                    + "Add them to the bot's Dockerfile, or restore the default one, and rebuild."
            )
        }
        lock.withLock { probedImages[container] = image }
    }
}

extension AppContext {
    /// The app's guest resolver. In the app (`hostsGuestRuns`), launch
    /// cleanup runs off the main thread and then opens the barrier guest runs
    /// wait on; elsewhere guest threads fail.
    func makeBotGuestRunResolver(hostsGuestRuns: Bool) -> BotGuestRunResolver {
        let appSupport = appSupportDirectory
        let docker = BotComputerDockerCLI()
        let binaries = distillGuestBinaries
        let distillOverride = (try? settingsRepo.get("cli.distill.path")) ?? nil
        let barrier = botGuestLaunchBarrier
        if hostsGuestRuns {
            // Unit tests never reach the user's Docker daemon.
            let sweepDocker: (any BotComputerDockerClienting)? = AppContext.isRunningUnitTests ? nil : docker
            let store = botStore
            DispatchQueue.global(qos: .utility).async {
                var botIDs: [BotID] = []
                if sweepDocker != nil {
                    do {
                        botIDs = try store.list(includeHidden: true, includeDeleted: true).map(\.id)
                    } catch {
                        // Fail open: the barrier still opens; a leftover
                        // agent then ends only by its lease reaper (~50 s).
                        guestResolverLog.error(
                            "bot.guest.launch_sweep skipped=bot_list_failed error=\(String(describing: error), privacy: .public)"
                        )
                    }
                }
                BotGuestLaunchSweep.run(
                    docker: sweepDocker, appSupport: appSupport, botIDs: botIDs, barrier: barrier
                )
            }
        }
        return BotGuestRunResolver(BotGuestRunResolver.Dependencies(
            threadRepo: threadRepo,
            botStore: botStore,
            appSupport: appSupport,
            barrier: barrier,
            gateway: botGuestMCPGateway,
            vm: BotGuestDockerVM(
                appSupport: appSupport,
                docker: docker,
                service: BotComputerGuestService(
                    appSupport: appSupport,
                    docker: docker,
                    recipeContext: AppShellResourceBundle.computerGuestRecipeURL()
                )
            ),
            binaryGuestPath: { hostBinary, arch in
                try await binaries.resolve(hostBinary: hostBinary, dockerArch: arch).guestPath
            },
            refresh: { hostHome, provider in
                try await DistillHostCredentialRefresher(hostHome: hostHome).prepare(provider: provider)
            },
            dockerExecutable: { try BotComputerDockerResolver.shared.resolveHealthyExecutable() },
            workspaces: { [weak self] in
                await MainActor.run {
                    self?.state.workspaces.mapValues(\.cwd) ?? [:]
                }
            },
            hostBinary: { request in
                DistillProvisioner.resolveInstalledBinary(override: request.providerBinary ?? distillOverride)
            },
            gitIdentity: { BotComputerGuestService.gitIdentity() },
            hostsGuestRuns: hostsGuestRuns
        ))
    }
}

/// App launch: no guest run survives a quit, so nothing a previous run left
/// is live. Quit runs `removeLeftovers` too.
enum BotGuestLaunchSweep {
    /// The launch cleanup, blocking: ends leftover in-guest agents and stray
    /// `bash -lc` shells, then deletes the Mac-side leftovers (sign-in
    /// copies, env files, leases), then opens `barrier`, so no guest run
    /// starts before its bot's leftovers are gone and the cleanup never
    /// touches a new run (whose tools run under `bash -lc` too).
    /// `docker` nil skips the in-guest step.
    static func run(
        docker: (any BotComputerDockerClienting)?,
        appSupport: URL,
        botIDs: [BotID],
        barrier: DistillGuestLaunchBarrier
    ) {
        if let docker { endLeftoverRuns(docker: docker, appSupport: appSupport, botIDs: botIDs) }
        removeLeftovers(appSupport: appSupport)
        Task { await barrier.open() }
    }

    /// Ends what a previous session of this app left running in the
    /// containers of this database's bots, whatever their desktop kind is
    /// now: in-guest agents (`kill-agent --all` as the guest user, only where
    /// a run's lease survived, i.e. the app crashed or was killed; quit and
    /// the previous launch delete them), then `bash -lc` shells whose
    /// `docker exec` client died with the app (`BotVMOrphanScan`, as root).
    /// Another app sharing the Docker daemon (the installed app beside a
    /// debug sandbox) has its own bots and its own Application Support, so a
    /// container counts only when this app has a guest home for its bot, its
    /// name and bot label match one of `botIDs`, and its home is bound from
    /// that guest home. Docker down: no container runs, so there is nothing
    /// to end. Blocking; returns the containers whose agents were ended.
    @discardableResult
    static func endLeftoverRuns(
        docker: any BotComputerDockerClienting,
        appSupport: URL,
        botIDs: [BotID]
    ) -> [String] {
        // No guest home here: no container of this app is bound from it, so
        // bots that never had a Docker desktop cost no Docker call.
        let candidates = botIDs.filter {
            FileManager.default.fileExists(atPath: BotComputerGuestSpec.guestHomeURL(appSupport: appSupport, botID: $0).path)
        }
        guard !candidates.isEmpty else { return [] }
        guard (try? docker.info()) != nil else {
            guestResolverLog.info("bot.guest.launch_sweep skipped=docker_unavailable")
            return []
        }
        var swept: [String] = []
        var reaped = 0
        var inspectFailures = 0
        for botID in candidates {
            let name = BotComputerGuestSpec.containerName(botID: botID)
            let container: BotComputerContainerInspect
            do {
                container = try docker.inspect(name: name)
            } catch {
                // Usually a removed container; counted so a failing Docker shows.
                inspectFailures += 1
                continue
            }
            guard container.running,
                  container.labels[BotComputerGuestSpec.botIDLabelKey] == botID.value.uuidString.lowercased(),
                  let source = container.homeSource,
                  samePath(source, BotComputerGuestSpec.guestHomeURL(appSupport: appSupport, botID: botID).path)
            else { continue }
            if mayHaveLeftoverRuns(appSupport: appSupport, botID: botID) {
                do {
                    _ = try docker.exec(
                        name: name,
                        command: [BotComputerGuestSpec.killAgentPath, "--all"],
                        user: BotComputerGuestSpec.agentUser,
                        detach: false
                    )
                    swept.append(name)
                } catch {
                    // A run that survived KILL is left to its reaper, which
                    // ends it once its lease stops changing.
                    guestResolverLog.error("bot.guest.launch_sweep.kill_failed container=\(name, privacy: .public)")
                }
            }
            reaped += BotVMOrphanScan.reap(docker: docker, names: [name]).count
        }
        guestResolverLog.info(
            "bot.guest.launch_sweep containers=\(swept.count, privacy: .public) orphan_shells=\(reaped, privacy: .public) inspect_failed=\(inspectFailures, privacy: .public)"
        )
        return swept
    }

    /// Whether an agent a previous session started may still run in
    /// `botID`'s guest: a lease outlives its run only when the app did not
    /// end it. A `.rc-runs` that is not a plain folder (the guest owns it and
    /// may swap it for a symlink) cannot be read safely, so it counts.
    static func mayHaveLeftoverRuns(appSupport: URL, botID: BotID) -> Bool {
        let leases = BotComputerGuestSpec.guestHomeURL(appSupport: appSupport, botID: botID)
            .appendingPathComponent(".rc-runs", isDirectory: true)
        do {
            let directory = try PrivateDirectory(leases, create: false)
            defer { directory.close() }
            return directory.entries().contains { $0.hasSuffix(".lease") }
        } catch DistillGuestCredentialError.writeFailed(_, let code) where code == ENOENT {
            return false
        } catch {
            return true
        }
    }

    private static func samePath(_ a: String, _ b: String) -> Bool {
        func canonical(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        return canonical(a) == canonical(b)
    }

    static func removeLeftovers(appSupport: URL, fileManager: FileManager = .default) {
        let guestHomes = BotComputerGuestSpec.guestHomeRoot(appSupport: appSupport)
        DistillGuestCredentials.removeAllCopies(guestHomeRoot: guestHomes)
        let runs = DistillGuestEnvironment.runsDirectory(appSupport: appSupport)
        for name in (try? fileManager.contentsOfDirectory(atPath: runs.path)) ?? [] where name.hasSuffix(".env") {
            unlink(runs.appendingPathComponent(name).path)
        }
        // A lease nobody renews makes the guest reaper end a leftover agent
        // `endLeftoverRuns` could not reach (up to ~50 s later). The guest
        // owns `.rc-runs`: a symlinked one is skipped, never followed.
        for bot in (try? fileManager.contentsOfDirectory(atPath: guestHomes.path)) ?? [] {
            let leases = guestHomes.appendingPathComponent(bot, isDirectory: true)
                .appendingPathComponent("home/.rc-runs", isDirectory: true)
            guard let directory = try? PrivateDirectory(leases, create: false) else { continue }
            for name in directory.entries() where name.hasSuffix(".lease") {
                directory.remove(name)
            }
            directory.close()
        }
    }
}
