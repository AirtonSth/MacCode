import Foundation

/// M6: bounded p50/p95 latency tracker for hooks/gates (incl. GPU contention with the
/// MLX LLM). Keeps a fixed-size ring of recent samples so steady-state memory is flat
/// and percentiles reflect recent behaviour. Pure value type, O(n log n) on read.
public struct LatencyPercentileTracker: Sendable, Equatable {
    private var samples: [Int]
    private var nextIndex = 0
    private var filled = false
    private let capacity: Int

    public init(capacity: Int = 512) {
        self.capacity = max(1, capacity)
        self.samples = []
        self.samples.reserveCapacity(self.capacity)
    }

    public mutating func record(milliseconds: Int) {
        let value = max(0, milliseconds)
        if samples.count < capacity {
            samples.append(value)
        } else {
            samples[nextIndex] = value
            nextIndex = (nextIndex + 1) % capacity
            filled = true
        }
    }

    public var count: Int { samples.count }

    /// Nearest-rank percentile. `p` in [0, 1]. Returns 0 when empty.
    public func percentile(_ p: Double) -> Int {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let clamped = min(1, max(0, p))
        let rank = Int((clamped * Double(sorted.count - 1)).rounded())
        return sorted[rank]
    }

    public var p50: Int { percentile(0.50) }
    public var p95: Int { percentile(0.95) }
}
