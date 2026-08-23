import Foundation

/// Wraps any `DistillRuntime` with a per-call wall-clock deadline and fail-open
/// semantics (N2). `promptCompressor` is awaited synchronously on the agent's
/// startRun path, so an MLX generation that stalls — or a cold model that takes
/// seconds — must never block the agent loop unbounded. On deadline-exceeded OR
/// any thrown error, this returns a deterministic fallback instead of propagating,
/// so the caller always gets a usable result and the turn proceeds.
public struct DeadlineDistillRuntime: DistillRuntime {
    private let wrapped: any DistillRuntime
    private let deadline: Duration
    private let fallback: @Sendable (DistillRequest) -> String
    /// Called when the deadline fires or the runtime throws and the deterministic
    /// fallback is returned.  Wire this to `DistillServiceMetricsRecorder.recordFallback()`
    /// so operators can detect a permanently-cold model via /metrics.
    /// WHY: without this hook every deadline-exceeded response goes through the
    /// success path, making `fallbackRequests` permanently zero even when the MLX
    /// model never warms up (silent fail-open that metrics cannot detect).
    private let onFallback: (@Sendable () async -> Void)?

    private struct DeadlineExceeded: Error {}

    final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private var registeredTasks: [Task<Void, Never>] = []

        func register(_ task: Task<Void, Never>) {
            lock.lock()
            guard !fired else {
                lock.unlock()
                task.cancel()
                return
            }
            registeredTasks.append(task)
            lock.unlock()
        }

        func fire(_ body: () -> Void) {
            lock.lock()
            guard !fired else {
                lock.unlock()
                return
            }
            fired = true
            let tasks = registeredTasks
            registeredTasks.removeAll(keepingCapacity: false)
            lock.unlock()
            for task in tasks { task.cancel() }
            body()
        }
    }

    public init(
        wrapping wrapped: any DistillRuntime,
        deadlineMilliseconds: Int,
        fallback: @escaping @Sendable (DistillRequest) -> String = { MLXDistillRuntime.fallbackOutput(for: $0) },
        onFallback: (@Sendable () async -> Void)? = nil
    ) {
        self.wrapped = wrapped
        self.deadline = .milliseconds(max(1, deadlineMilliseconds))
        self.fallback = fallback
        self.onFallback = onFallback
    }

    public func distill(_ request: DistillRequest) async throws -> String {
        try await distillStaged(request).output
    }

    public func distillStaged(_ request: DistillRequest) async throws -> DistillStageResult {
        let wrapped = self.wrapped
        let deadline = self.deadline
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let oneShot = OneShot()
                let runtimeTask = Task {
                    do {
                        let staged = try await wrapped.distillStaged(request)
                        oneShot.fire { continuation.resume(returning: staged) }
                    } catch {
                        oneShot.fire { continuation.resume(throwing: error) }
                    }
                }
                oneShot.register(runtimeTask)
                let deadlineTask = Task {
                    try? await Task.sleep(for: deadline)
                    guard !Task.isCancelled else { return }
                    oneShot.fire {
                        continuation.resume(throwing: DeadlineExceeded())
                    }
                }
                oneShot.register(deadlineTask)
            }
        } catch {
            // Deadline exceeded or the runtime threw: fail open to the deterministic
            // fallback. Never propagate — the agent turn must proceed.
            if let onFallback {
                await onFallback()
            }
            return DistillStageResult(output: fallback(request), stage: .deterministic)
        }
    }

    public func rawGenerate(system: String, user: String, maxTokens: Int) async -> String? {
        let wrapped = self.wrapped
        let deadline = self.deadline
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let oneShot = OneShot()
                let runtimeTask = Task {
                    let out = await wrapped.rawGenerate(system: system, user: user, maxTokens: maxTokens)
                    oneShot.fire { continuation.resume(returning: out) }
                }
                oneShot.register(runtimeTask)
                let deadlineTask = Task {
                    try? await Task.sleep(for: deadline)
                    guard !Task.isCancelled else { return }
                    oneShot.fire {
                        continuation.resume(throwing: DeadlineExceeded())
                    }
                }
                oneShot.register(deadlineTask)
            }
        } catch {
            if let onFallback {
                await onFallback()
            }
            return nil
        }
    }

    public func warmup() async throws {
        try await wrapped.warmup()
    }

    public func reclaimIdleMemory() {
        wrapped.reclaimIdleMemory()
    }
}
