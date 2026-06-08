import Foundation

/// Serializes MLX GPU generation to a single in-flight job. The `DistillScheduler`
/// admits up to `maxConcurrentRequests` (default 8), but a single Metal device
/// should not run several decodes at once (memory pressure, contention with the
/// host renderer — see the documented Ghostty GPU co-tenancy history). This lane
/// is the GPU serialization gate underneath the admission gate: callers `acquire`
/// before generation and `release` after, so at most one generation runs at a time.
///
/// Correct under actor reentrancy: serialization is enforced by the `busy` flag +
/// `waiters` queue, not by actor isolation across `await`.
public actor MLXGenerationLane {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Test/inspection helper: number of callers currently waiting for the lane.
    public var waitingCount: Int { waiters.count }
}
