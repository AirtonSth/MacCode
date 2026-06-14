import CoreModel
import Foundation

public typealias TokenSaverEncoderManifest = CoreModel.TokenSaverEncoderManifest
public typealias TokenSaverApprovedEncoderManifests = CoreModel.TokenSaverApprovedEncoderManifests

public struct EncoderLaneMetricsSnapshot: Sendable, Equatable {
    public let invocations: Int
    public let accepts: Int
    public let fallbacks: Int
    public let failures: Int
    /// I3.10/M5: calls that blew the per-call deadline (counted INSIDE p95, not hidden).
    public let deadlineTimeouts: Int
    /// I3.10/K3: lane has latched itself off after N consecutive deadline-outs (anti-thrash).
    public let disabled: Bool

    public init(
        invocations: Int,
        accepts: Int,
        fallbacks: Int,
        failures: Int,
        deadlineTimeouts: Int = 0,
        disabled: Bool = false
    ) {
        self.invocations = invocations
        self.accepts = accepts
        self.fallbacks = fallbacks
        self.failures = failures
        self.deadlineTimeouts = deadlineTimeouts
        self.disabled = disabled
    }
}

public actor EncoderLane {
    public typealias ScoreFn = @Sendable (_ query: String, _ text: String) async throws -> Double?

    private let manifest: TokenSaverEncoderManifest
    private let scorer: ScoreFn?
    private let ranker: QueryAwareChunkRanker
    private let warmupFn: (@Sendable () async throws -> Void)?
    private let reclaimFn: (@Sendable () async -> Void)?
    /// Per-call budget (I3.3): encoder ranking must answer fast or fall open. Default 500ms.
    private let deadlineMillis: Int
    /// I3.10/K3: latch lane-disabled after this many consecutive deadline-outs so a slow
    /// host does not burn the budget re-trying every request (evict-to-next-call thrash).
    private let maxConsecutiveDeadlineTimeouts: Int

    private var invocations = 0
    private var accepts = 0
    private var fallbacks = 0
    private var failures = 0
    private var deadlineTimeouts = 0
    private var consecutiveDeadlineTimeouts = 0
    private var disabled = false

    public init(
        manifest: TokenSaverEncoderManifest,
        scorer: ScoreFn?,
        ranker: QueryAwareChunkRanker = QueryAwareChunkRanker(),
        deadlineMillis: Int = 500,
        maxConsecutiveDeadlineTimeouts: Int = 3,
        warmup: (@Sendable () async throws -> Void)? = nil,
        reclaimIdleMemory: (@Sendable () async -> Void)? = nil
    ) {
        self.manifest = manifest
        self.scorer = scorer
        self.ranker = ranker
        self.deadlineMillis = max(1, deadlineMillis)
        self.maxConsecutiveDeadlineTimeouts = max(1, maxConsecutiveDeadlineTimeouts)
        self.warmupFn = warmup
        self.reclaimFn = reclaimIdleMemory
    }

    /// I3.3: pay cold start before /readyz so no live turn awaits a cold model.
    /// Fail-open: a warmup error leaves the lane usable (it will fall back at rank()).
    public func warmup() async {
        guard manifest.isApprovedForTokenSaver, let warmupFn else { return }
        do { try await warmupFn() } catch { /* fail-open: stay available, rank() falls back */ }
    }

    /// I3.3: return idle encoder memory to the OS on drain.
    public func reclaimIdleMemory() async {
        await reclaimFn?()
    }

    /// I3.10 telemetry: has the lane latched itself off for this host?
    public var isDisabled: Bool { disabled }

    public func rank(
        chunks: [QueryAwareChunk],
        query: String,
        toolArguments: String? = nil,
        topK: Int = 8
    ) async -> [QueryAwareRankedChunk]? {
        invocations += 1
        // I3.10/K3: once latched off, never re-enter the model path (no per-request thrash).
        guard !disabled, manifest.isApprovedForTokenSaver, let scorer else {
            fallbacks += 1
            return nil
        }
        do {
            // I3.3: bound the whole scoring pass by the per-call deadline. A timeout is a
            // first-class outcome (counted), not a hidden tail latency.
            let immutableScores = try await withDeadline(milliseconds: deadlineMillis) {
                var scoreByText: [String: Double] = [:]
                for chunk in chunks {
                    if let score = try await scorer(query, chunk.text) {
                        scoreByText[chunk.text] = score
                    }
                }
                return scoreByText
            }
            consecutiveDeadlineTimeouts = 0
            let ranked = ranker.rank(
                chunks: chunks,
                query: query,
                toolArguments: toolArguments,
                embeddingScore: { _, text in
                    immutableScores[text]
                }
            )
            let result = Array(ranked.prefix(max(1, topK)))
            if result.isEmpty {
                fallbacks += 1
                return nil
            }
            accepts += 1
            return result
        } catch is EncoderDeadlineError {
            deadlineTimeouts += 1
            consecutiveDeadlineTimeouts += 1
            if consecutiveDeadlineTimeouts >= maxConsecutiveDeadlineTimeouts {
                disabled = true
            }
            fallbacks += 1
            return nil
        } catch {
            failures += 1
            fallbacks += 1
            return nil
        }
    }

    public func metricsSnapshot() -> EncoderLaneMetricsSnapshot {
        EncoderLaneMetricsSnapshot(
            invocations: invocations,
            accepts: accepts,
            fallbacks: fallbacks,
            failures: failures,
            deadlineTimeouts: deadlineTimeouts,
            disabled: disabled
        )
    }
}

struct EncoderDeadlineError: Error {}

/// Race `operation` against a wall-clock deadline. If the deadline wins, the
/// operation Task is cancelled and `EncoderDeadlineError` is thrown. Used to keep
/// the encoder lane fail-open under load (I3.3).
func withDeadline<T: Sendable>(
    milliseconds: Int,
    _ operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(1, milliseconds)) * 1_000_000)
            throw EncoderDeadlineError()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw EncoderDeadlineError() }
        return first
    }
}
