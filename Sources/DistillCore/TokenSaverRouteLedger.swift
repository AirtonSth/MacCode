import Foundation

/// C5 telemetry: aggregates per-lane routing outcomes so the team can see the
/// BERT-first payoff — what share of requests are resolved WITHOUT touching the
/// MLX LLM, and the average wall-clock of the encoder stage vs the LLM stage,
/// per traffic class. Pure value type; the service recorder owns one instance.
public struct TokenSaverRouteLedger: Sendable, Equatable {
    public struct StageStat: Sendable, Equatable {
        public var count: Int = 0
        public var totalMillis: Int = 0
        public var averageMillis: Double { count == 0 ? 0 : Double(totalMillis) / Double(count) }
    }

    public struct LaneStat: Sendable, Equatable {
        public var total: Int = 0
        public var resolvedWithoutLLM: Int = 0
        public var byStage: [TokenSaverRouteStage: StageStat] = [:]
        public var resolvedWithoutLLMRate: Double {
            total == 0 ? 0 : Double(resolvedWithoutLLM) / Double(total)
        }
    }

    private(set) public var perLane: [TokenSaverLane: LaneStat] = [:]
    private(set) public var total = 0
    private(set) public var resolvedWithoutLLM = 0

    public init() {}

    public mutating func record(_ event: TokenSaverRouteTelemetryEvent) {
        total += 1
        if event.resolvedWithoutLLM { resolvedWithoutLLM += 1 }
        var lane = perLane[event.lane] ?? LaneStat()
        lane.total += 1
        if event.resolvedWithoutLLM { lane.resolvedWithoutLLM += 1 }
        var stage = lane.byStage[event.stage] ?? StageStat()
        stage.count += 1
        stage.totalMillis += event.wallClockMilliseconds
        lane.byStage[event.stage] = stage
        perLane[event.lane] = lane
    }

    /// Headline: fraction of all routed requests answered without the LLM (target 0.30–0.60).
    public var resolvedWithoutLLMRate: Double {
        total == 0 ? 0 : Double(resolvedWithoutLLM) / Double(total)
    }

    /// C5: average latency of a stage across all lanes (encoder vs LLM comparison).
    public func averageLatencyMillis(stage: TokenSaverRouteStage) -> Double {
        var count = 0
        var millis = 0
        for lane in perLane.values {
            if let s = lane.byStage[stage] { count += s.count; millis += s.totalMillis }
        }
        return count == 0 ? 0 : Double(millis) / Double(count)
    }

    public func resolvedWithoutLLMRate(lane: TokenSaverLane) -> Double {
        perLane[lane]?.resolvedWithoutLLMRate ?? 0
    }
}
