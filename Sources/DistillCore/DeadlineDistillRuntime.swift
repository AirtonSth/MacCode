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

    private struct DeadlineExceeded: Error {}

    public init(
        wrapping wrapped: any DistillRuntime,
        deadlineMilliseconds: Int,
        fallback: @escaping @Sendable (DistillRequest) -> String = { MLXDistillRuntime.fallbackOutput(for: $0) }
    ) {
        self.wrapped = wrapped
        self.deadline = .milliseconds(max(1, deadlineMilliseconds))
        self.fallback = fallback
    }

    public func distill(_ request: DistillRequest) async throws -> String {
        let wrapped = self.wrapped
        let deadline = self.deadline
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await wrapped.distill(request) }
                group.addTask {
                    try await Task.sleep(for: deadline)
                    throw DeadlineExceeded()
                }
                // First child to finish wins; cancel the loser (the sleep, or the
                // in-flight generation if the deadline fired first).
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            // Deadline exceeded or the runtime threw: fail open to the deterministic
            // fallback. Never propagate — the agent turn must proceed.
            return fallback(request)
        }
    }

    public func warmup() async throws {
        try await wrapped.warmup()
    }

    public func reclaimIdleMemory() {
        wrapped.reclaimIdleMemory()
    }
}
