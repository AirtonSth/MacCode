import Foundation
import CoreModel
import os

private let guestLaunchLog = Logger(subsystem: "io.remotecode.agent", category: "distill.guest")

/// Decides, per run, whether a Distill turn runs inside its bot's Linux guest.
///
/// Implemented in AppShell (it reads the thread's durable guest marker and the
/// bot's computer). A thread it routes to the guest never falls back to the Mac.
public protocol DistillGuestLaunchResolving: Sendable {
    /// True when the thread runs inside a guest. Reads durable state only and
    /// has no side effects: recovery and transcript reads call it on open.
    func isGuestThread(_ threadId: AgentThreadID) -> Bool
    /// A launch plan for a guest thread, nil for a Mac thread. Throws when the
    /// thread belongs in a guest that cannot run it now; the run fails rather
    /// than run on the Mac.
    func prepare(_ request: AgentRunRequest) async throws -> DistillGuestLaunchPlan?
}

/// One in-guest Distill run: `docker exec -i --env-file … run-agent <runId> -- <guestCommand>`.
///
/// The guest process outlives its `docker exec` client, so ending a run means
/// running `kill-agent` in the guest. `finish` does that (after letting a
/// finished turn exit on its own), then the resolver's cleanup, then frees the
/// bot's lease, exactly once per run whichever path (turn end, Stop, transport
/// loss, failed open) gets there first.
public final class DistillGuestLaunchPlan: @unchecked Sendable {
    public let runID: String
    public let dockerExecutable: String
    public let container: String
    public let guestCwd: String
    /// In-guest argv: the guest Distill binary and its arguments.
    public let guestCommand: [String]
    /// 0600 `KEY=value` file holding the run's whole environment; the adapter
    /// deletes it once `initialize` proves the docker CLI has read it.
    public let envFileURL: URL
    public let lease: DistillGuestLease?
    private let teardown: @Sendable (AgentRunStatus) async -> Void
    private let teardownTimeout: TimeInterval
    private let killGuestBody: @Sendable () async -> Void
    private let killGuestDetachedBody: @Sendable () -> Void
    private let lock = NSLock()
    private var finishTask: Task<Void, Never>?

    /// Bound on one `kill-agent` (TERM, 1 s, KILL inside the guest).
    public static let killTimeout: TimeInterval = 5
    /// Bound on a finished turn's own exit after stdin closes. Distill's
    /// shutdown drains workflows (up to 7 s) and flushes the session (2 s);
    /// a plain turn took about 2.2 s in the guest.
    public static let gracefulExitTimeout: TimeInterval = 10
    /// Bound on the resolver's teardown. Past it the lease is freed anyway: a
    /// hung cleanup must not block every later run of the bot, and the guest's
    /// lease reaper and the launch sweep still end anything left behind.
    public static let teardownTimeout: TimeInterval = 30

    /// - Parameters:
    ///   - teardown: the resolver's cleanup after the guest process is gone
    ///     (credentials, gateway token, lease heartbeat).
    ///   - killGuest / killGuestDetached: tests only; default to `kill-agent`
    ///     over `docker exec` as the guest user.
    ///   - teardownTimeout: tests only.
    public init(
        runID: String,
        dockerExecutable: String,
        container: String,
        guestCwd: String,
        guestCommand: [String],
        envFileURL: URL,
        lease: DistillGuestLease?,
        teardown: @escaping @Sendable (AgentRunStatus) async -> Void,
        killGuest: (@Sendable () async -> Void)? = nil,
        killGuestDetached: (@Sendable () -> Void)? = nil,
        teardownTimeout: TimeInterval = DistillGuestLaunchPlan.teardownTimeout
    ) {
        self.runID = runID
        self.dockerExecutable = dockerExecutable
        self.container = container
        self.guestCwd = guestCwd
        self.guestCommand = guestCommand
        self.envFileURL = envFileURL
        self.lease = lease
        self.teardown = teardown
        self.teardownTimeout = teardownTimeout
        let killArguments = Self.killArguments(container: container, runID: runID, detached: false)
        let detachedArguments = Self.killArguments(container: container, runID: runID, detached: true)
        self.killGuestBody = killGuest ?? {
            await Self.runDocker(dockerExecutable, killArguments, runID: runID, timeout: Self.killTimeout)
        }
        self.killGuestDetachedBody = killGuestDetached ?? {
            Self.startDocker(dockerExecutable, detachedArguments, runID: runID)
        }
    }

    /// No `-e`: every value rides in the env file, so none shows in `ps`.
    public var dockerArguments: [String] {
        [
            "exec", "-i",
            "--env-file", envFileURL.path,
            "-u", BotComputerGuestSpec.agentUser,
            "-w", guestCwd,
            container,
            BotComputerGuestSpec.runAgentPath, runID, "--",
        ] + guestCommand
    }

    /// `kill-agent` must run as the guest user: root is refused (it cannot read
    /// the run tag in another user's /proc environ).
    static func killArguments(container: String, runID: String, detached: Bool) -> [String] {
        ["exec"] + (detached ? ["-d"] : []) + [
            "-u", BotComputerGuestSpec.agentUser,
            container,
            BotComputerGuestSpec.killAgentPath, runID,
        ]
    }

    /// The guest binary's argv: the same Distill arguments as a Mac launch, plus
    /// `--no-auto-update` (the binary sits on a read-only mount the host keeps
    /// at the right version).
    public static func guestCommand(binaryPath: String, for request: AgentRunRequest) throws -> [String] {
        let arguments = try DistillACPClient.launchArguments(for: request)
        let noAutoUpdate = "--no-auto-update"
        return [binaryPath] + (arguments.contains(noAutoUpdate) ? arguments : [noAutoUpdate] + arguments)
    }

    /// Ends the guest process. Idempotent: `kill-agent` exits 0 for a run that
    /// already ended, so Stop and the run's own finish may both call it.
    public func killGuest() async {
        await killGuestBody()
    }

    /// Fire-and-forget kill for app termination, which cannot wait.
    public func killGuestDetached() {
        killGuestDetachedBody()
    }

    /// Kill the guest, run the resolver's teardown, delete the env file, then
    /// free the lease, in that order and once. The lease is what makes the next
    /// run of this bot wait, so it is freed only after the guest is gone and
    /// its credentials are cleaned up (or teardown ran out of time). Later
    /// calls return the first call's task.
    ///
    /// `exitGracefully` runs before the kill. A finished turn passes one that
    /// closes the client's stdin and waits (bounded) for Distill to exit on
    /// its own: a TERM skips its session shutdown, which flushes the turn's
    /// last durable records that the next turn's `session/load` replays.
    @discardableResult
    public func finish(
        _ status: AgentRunStatus,
        exitGracefully: (@Sendable () async -> Void)? = nil
    ) -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let finishTask { return finishTask }
        let task = Task.detached { [self] in
            await exitGracefully?()
            await killGuest()
            let finished = await Self.completes(within: teardownTimeout) { [teardown] in
                await teardown(status)
            }
            if !finished {
                guestLaunchLog.error(
                    "distill.guest.teardown.timeout run=\(self.runID, privacy: .public) seconds=\(self.teardownTimeout, privacy: .public)"
                )
            }
            unlink(envFileURL.path)
            await lease?.release()
            guestLaunchLog.info(
                "distill.guest.finished run=\(self.runID, privacy: .public) status=\(status.rawValue, privacy: .public)"
            )
        }
        finishTask = task
        return task
    }

    /// Runs `body` unstructured and returns whether it finished in time. A
    /// body that never returns is left behind rather than awaited.
    static func completes(
        within timeout: TimeInterval,
        _ body: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let resume: @Sendable (Bool) -> Void = { value in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            Task.detached {
                await body()
                resume(true)
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                resume(false)
            }
        }
    }

    private static func runDocker(
        _ executable: String,
        _ arguments: [String],
        runID: String,
        timeout: TimeInterval
    ) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32? = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let resume: @Sendable (Int32?) -> Void = { value in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            process.terminationHandler = { resume($0.terminationStatus) }
            do {
                try process.run()
            } catch {
                resume(nil)
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
                resume(nil)
            }
        }
        if status != 0 {
            guestLaunchLog.error(
                "distill.guest.kill.failed run=\(runID, privacy: .public) status=\(status.map(String.init) ?? "timeout_or_spawn", privacy: .public)"
            )
        }
    }

    private static func startDocker(_ executable: String, _ arguments: [String], runID: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            guestLaunchLog.error("distill.guest.kill_detached.spawn_failed run=\(runID, privacy: .public)")
        }
    }
}

/// One guest run per bot at a time, including its teardown: the next run of a
/// bot waits until the previous run's guest process is dead and its
/// credentials are cleaned up. Waiters are served in arrival order.
public actor DistillGuestLeases {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private var held: Set<String> = []
    private var waiters: [String: [Waiter]] = [:]
    private var nextWaiterID: UInt64 = 0

    public init() {}

    /// Throws `CancellationError` when the waiting task is cancelled (Stop
    /// while the run waits for the bot): the waiter leaves the queue and never
    /// takes the lease. A lease handed over before the cancellation is
    /// returned and must be released by the caller.
    public func acquire(_ key: String) async throws -> DistillGuestLease {
        try Task.checkCancellation()
        if held.contains(key) {
            nextWaiterID += 1
            let id = nextWaiterID
            // `release` hands the lease over without freeing it in between.
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters[key, default: []].append(Waiter(id: id, continuation: continuation))
                }
            } onCancel: {
                // Runs after the append: this actor is busy until the
                // continuation above suspends.
                Task { await self.cancelWaiter(key, id: id) }
            }
        } else {
            held.insert(key)
        }
        return DistillGuestLease(key: key, owner: self)
    }

    public func isHeld(_ key: String) -> Bool {
        held.contains(key)
    }

    private func cancelWaiter(_ key: String, id: UInt64) {
        guard var queue = waiters[key], let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = queue.remove(at: index)
        waiters[key] = queue.isEmpty ? nil : queue
        waiter.continuation.resume(throwing: CancellationError())
    }

    fileprivate func release(_ key: String) {
        guard var queue = waiters[key], !queue.isEmpty else {
            held.remove(key)
            return
        }
        let next = queue.removeFirst()
        waiters[key] = queue.isEmpty ? nil : queue
        next.continuation.resume()
    }
}

public final class DistillGuestLease: @unchecked Sendable {
    public let key: String
    private let owner: DistillGuestLeases
    private let lock = NSLock()
    private var released = false

    fileprivate init(key: String, owner: DistillGuestLeases) {
        self.key = key
        self.owner = owner
    }

    /// Idempotent.
    public func release() async {
        let first = lock.withLock { () -> Bool in
            defer { released = true }
            return !released
        }
        guard first else { return }
        await owner.release(key)
    }
}
