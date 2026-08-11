import Foundation
import CoreModel

/// Deterministic semantic capacity harness (plan-optimize-swift S2 / T-003).
///
/// Virtual clock + seeded PRNG replace sleeps/random UUIDs so a repeated seed
/// yields the same DAG/event/fault schedule. Exercises depth/fan-out, rejoin,
/// cancellation, fairness, and terminal ownership without real providers.

public protocol CapacityVirtualClock: AnyObject, Sendable {
    var nowMs: Int64 { get }
    func advance(byMs delta: Int64)
}

public final class CapacityManualClock: CapacityVirtualClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _nowMs: Int64

    public init(startMs: Int64 = 0) {
        self._nowMs = startMs
    }

    public var nowMs: Int64 {
        lock.lock(); defer { lock.unlock() }
        return _nowMs
    }

    public func advance(byMs delta: Int64) {
        lock.lock(); defer { lock.unlock() }
        _nowMs &+= max(0, delta)
    }
}

/// Seeded xorshift64* — deterministic, no Foundation UUID dependency.
public struct CapacitySeededRNG: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    public mutating func nextUInt64() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state &* 0x2545F4914F6CDD1D
    }

    public mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(nextUInt64() % span)
    }

    public mutating func nextBool(probability: Double = 0.5) -> Bool {
        let threshold = UInt64(max(0.0, min(1.0, probability)) * Double(UInt64.max))
        return nextUInt64() <= threshold
    }

    public mutating func deterministicID(prefix: String) -> String {
        String(format: "%@-%016llx", prefix, nextUInt64())
    }
}

public enum CapacityHarnessNodeKind: String, Sendable, Equatable {
    case root
    case nested
}

public enum CapacityHarnessNodeStatus: String, Sendable, Equatable {
    case waiting
    case active
    case completed
    case failed
    case cancelled
}

public struct CapacityHarnessNode: Sendable, Equatable {
    public var id: String
    public var parentId: String?
    public var depth: Int
    public var kind: CapacityHarnessNodeKind
    public var provider: String
    public var status: CapacityHarnessNodeStatus
    public var resultRejoined: Bool
    public var startedAtMs: Int64?
    public var finishedAtMs: Int64?

    public init(
        id: String,
        parentId: String? = nil,
        depth: Int,
        kind: CapacityHarnessNodeKind,
        provider: String,
        status: CapacityHarnessNodeStatus = .waiting,
        resultRejoined: Bool = false,
        startedAtMs: Int64? = nil,
        finishedAtMs: Int64? = nil
    ) {
        self.id = id
        self.parentId = parentId
        self.depth = depth
        self.kind = kind
        self.provider = provider
        self.status = status
        self.resultRejoined = resultRejoined
        self.startedAtMs = startedAtMs
        self.finishedAtMs = finishedAtMs
    }
}

public struct CapacityHarnessFault: Sendable, Equatable {
    public var atMs: Int64
    public var nodeId: String
    public var kind: String

    public init(atMs: Int64, nodeId: String, kind: String) {
        self.atMs = atMs
        self.nodeId = nodeId
        self.kind = kind
    }
}

public struct CapacityHarnessSchedule: Sendable, Equatable {
    public var nodes: [CapacityHarnessNode]
    public var faults: [CapacityHarnessFault]
    public var seed: UInt64

    public init(nodes: [CapacityHarnessNode], faults: [CapacityHarnessFault], seed: UInt64) {
        self.nodes = nodes
        self.faults = faults
        self.seed = seed
    }
}

public struct CapacityHarnessRunResult: Sendable, Equatable {
    public var nodes: [CapacityHarnessNode]
    public var longestNoProgressMs: Int64
    public var completedCount: Int
    public var cancelledCount: Int
    public var failedCount: Int
    public var rejoinExactlyOnce: Bool
    public var queueDrained: Bool
    public var terminalOwnershipExact: Bool

    public init(
        nodes: [CapacityHarnessNode],
        longestNoProgressMs: Int64,
        completedCount: Int,
        cancelledCount: Int,
        failedCount: Int,
        rejoinExactlyOnce: Bool,
        queueDrained: Bool,
        terminalOwnershipExact: Bool
    ) {
        self.nodes = nodes
        self.longestNoProgressMs = longestNoProgressMs
        self.completedCount = completedCount
        self.cancelledCount = cancelledCount
        self.failedCount = failedCount
        self.rejoinExactlyOnce = rejoinExactlyOnce
        self.queueDrained = queueDrained
        self.terminalOwnershipExact = terminalOwnershipExact
    }
}

public enum CapacitySemanticHarness {
    public static let defaultProviders = ["claude", "codex", "grok", "fake"]

    /// Build a reproducible DAG: `roots` top-level threads, up to `nestedNodes`
    /// children placed at the given depths with mixed fan-out.
    public static func buildSchedule(
        roots: Int = 32,
        nestedNodes: Int = 64,
        depths: [Int] = [1, 2, 4],
        fanOut: [Int] = [1, 2, 4],
        providers: [String] = defaultProviders,
        faultKinds: [String] = ["malformed_frame", "reorder", "pipe_pressure", "stop_race", "resume"],
        seed: UInt64
    ) -> CapacityHarnessSchedule {
        var rng = CapacitySeededRNG(seed: seed)
        var nodes: [CapacityHarnessNode] = []
        var rootIDs: [String] = []

        for i in 0..<roots {
            let id = rng.deterministicID(prefix: "root")
            let provider = providers[i % providers.count]
            nodes.append(CapacityHarnessNode(id: id, depth: 0, kind: .root, provider: provider))
            rootIDs.append(id)
        }

        // Place nested nodes at sequential depths 1..depths.count so ancestry length
        // matches the depth label (root→d1→d2→d3).
        var remaining = nestedNodes
        var parentsByDepth: [Int: [String]] = [0: rootIDs]
        let maxDepth = max(1, depths.filter { $0 > 0 }.max() ?? 1)
        // Continuous levels 1...maxDepth so depth labels match ancestry length and
        // include configured peaks such as 4 (with intermediate 3 parents).
        var perLevel = Array(repeating: nestedNodes / maxDepth, count: maxDepth)
        for i in 0..<(nestedNodes % maxDepth) { perLevel[i] += 1 }

        for level in 1...maxDepth {
            guard remaining > 0 else { break }
            let budget = min(remaining, perLevel[level - 1])
            var parentFrontier = parentsByDepth[level - 1] ?? rootIDs
            if parentFrontier.isEmpty { parentFrontier = rootIDs }
            var nextFrontier: [String] = []
            var placed = 0
            var parentCursor = 0
            while placed < budget {
                let parent = parentFrontier[parentCursor % parentFrontier.count]
                parentCursor += 1
                let fan = fanOut[rng.nextInt(in: 0...(fanOut.count - 1))]
                let childCount = min(max(1, fan), budget - placed)
                for _ in 0..<childCount {
                    let id = rng.deterministicID(prefix: "node")
                    let provider = providers[rng.nextInt(in: 0...(providers.count - 1))]
                    nodes.append(CapacityHarnessNode(
                        id: id,
                        parentId: parent,
                        depth: level,
                        kind: .nested,
                        provider: provider
                    ))
                    nextFrontier.append(id)
                    placed += 1
                    remaining -= 1
                }
            }
            parentsByDepth[level] = nextFrontier
        }

        // Seeded fault plan against a deterministic subset of nodes.
        var faults: [CapacityHarnessFault] = []
        let faultBudget = min(8, nodes.count)
        for i in 0..<faultBudget {
            let node = nodes[i * max(1, nodes.count / faultBudget) % nodes.count]
            let kind = faultKinds[i % faultKinds.count]
            let atMs = Int64((i + 1) * 100)
            faults.append(CapacityHarnessFault(atMs: atMs, nodeId: node.id, kind: kind))
        }

        return CapacityHarnessSchedule(nodes: nodes, faults: faults, seed: seed)
    }

    /// Execute the schedule on a virtual clock. Pure in-process simulation.
    public static func run(
        schedule: CapacityHarnessSchedule,
        clock: CapacityVirtualClock,
        workQuantumMs: Int64 = 10,
        cancelNodeIds: Set<String> = []
    ) -> CapacityHarnessRunResult {
        var nodes = schedule.nodes
        var byId = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        var rejoinCounts: [String: Int] = [:]
        var lastProgressMs = clock.nowMs
        var longestGap: Int64 = 0
        var activeQueue: [String] = nodes.filter { $0.kind == .root }.map(\.id)

        func markProgress() {
            let gap = clock.nowMs - lastProgressMs
            if gap > longestGap { longestGap = gap }
            lastProgressMs = clock.nowMs
        }

        // Activate roots.
        for id in activeQueue {
            guard let idx = byId[id] else { continue }
            nodes[idx].status = .active
            nodes[idx].startedAtMs = clock.nowMs
        }

        let faultByNode = Dictionary(grouping: schedule.faults, by: \.nodeId)
        // Cancel requested nodes immediately (they never become active work).
        for i in nodes.indices where cancelNodeIds.contains(nodes[i].id) {
            nodes[i].status = .cancelled
            nodes[i].finishedAtMs = clock.nowMs
            nodes[i].resultRejoined = nodes[i].kind == .root
            markProgress()
        }
        activeQueue = activeQueue.filter { !cancelNodeIds.contains($0) }

        var safety = 0
        while nodes.contains(where: { $0.status == .waiting || $0.status == .active }) {
            safety += 1
            if safety > 100_000 { break }

            // Start waiting children whose parent has completed (or root).
            for i in nodes.indices where nodes[i].status == .waiting {
                if cancelNodeIds.contains(nodes[i].id) {
                    nodes[i].status = .cancelled
                    nodes[i].finishedAtMs = clock.nowMs
                    markProgress()
                    continue
                }
                if let parentId = nodes[i].parentId {
                    guard let pidx = byId[parentId] else { continue }
                    if nodes[pidx].status == .cancelled || nodes[pidx].status == .failed {
                        nodes[i].status = .cancelled
                        nodes[i].finishedAtMs = clock.nowMs
                        markProgress()
                        continue
                    }
                    guard nodes[pidx].status == .completed else { continue }
                }
                nodes[i].status = .active
                nodes[i].startedAtMs = clock.nowMs
                activeQueue.append(nodes[i].id)
                markProgress()
            }

            guard let currentId = activeQueue.first else {
                // If only cancelled/failed/completed remain as terminals of waiting graph,
                // force-cancel remaining waiting that can never start (dead parent failed).
                var progressed = false
                for i in nodes.indices where nodes[i].status == .waiting {
                    if let parentId = nodes[i].parentId,
                       let pidx = byId[parentId],
                       nodes[pidx].status == .failed || nodes[pidx].status == .cancelled {
                        nodes[i].status = .cancelled
                        nodes[i].finishedAtMs = clock.nowMs
                        markProgress()
                        progressed = true
                    }
                }
                if !progressed {
                    clock.advance(byMs: workQuantumMs)
                }
                continue
            }
            activeQueue.removeFirst()
            guard let idx = byId[currentId], nodes[idx].status == .active else { continue }

            if cancelNodeIds.contains(currentId) {
                nodes[idx].status = .cancelled
                nodes[idx].finishedAtMs = clock.nowMs
                markProgress()
                clock.advance(byMs: workQuantumMs)
                continue
            }

            // Apply first matching fault if any.
            if let faults = faultByNode[currentId],
               let fault = faults.first(where: { $0.atMs <= clock.nowMs }),
               fault.kind == "stop_race" || fault.kind == "malformed_frame" {
                nodes[idx].status = fault.kind == "stop_race" ? .cancelled : .failed
                nodes[idx].finishedAtMs = clock.nowMs
                markProgress()
                clock.advance(byMs: workQuantumMs)
                continue
            }

            // Complete work quantum.
            clock.advance(byMs: workQuantumMs)
            nodes[idx].status = .completed
            nodes[idx].finishedAtMs = clock.nowMs
            // Exactly-once rejoin into parent accounting (count per child id).
            let childId = nodes[idx].id
            rejoinCounts[childId, default: 0] += 1
            nodes[idx].resultRejoined = rejoinCounts[childId] == 1
            markProgress()
        }

        let completed = nodes.filter { $0.status == .completed }.count
        let cancelled = nodes.filter { $0.status == .cancelled }.count
        let failed = nodes.filter { $0.status == .failed }.count
        // Each completed nested node rejoins exactly once (per-child count == 1).
        let rejoinOK = nodes.filter { $0.kind == .nested }.allSatisfy { node in
            switch node.status {
            case .completed:
                return node.resultRejoined && rejoinCounts[node.id] == 1
            case .cancelled, .failed, .waiting, .active:
                return rejoinCounts[node.id, default: 0] == 0 || rejoinCounts[node.id] == 1
            }
        }
        let queueDrained = !nodes.contains(where: { $0.status == .waiting || $0.status == .active })
        let terminalExact = nodes.allSatisfy { node in
            switch node.status {
            case .completed, .failed, .cancelled:
                return node.finishedAtMs != nil
            case .waiting, .active:
                return false
            }
        }

        return CapacityHarnessRunResult(
            nodes: nodes,
            longestNoProgressMs: longestGap,
            completedCount: completed,
            cancelledCount: cancelled,
            failedCount: failed,
            rejoinExactlyOnce: rejoinOK,
            queueDrained: queueDrained,
            terminalOwnershipExact: terminalExact
        )
    }
}

// MARK: - Production-path subprocess fixture scaffolding (S2)

/// Describes a controlled stdout/stderr fixture for one real adapter seam.
/// Does not spawn providers; tests inject frames through the adapter parser path.
public struct CapacitySubprocessFixtureSpec: Sendable, Equatable {
    public var provider: String
    public var frames: [String]
    public var stderrLines: [String]
    public var exitCode: Int32
    public var reorder: Bool
    public var stopRace: Bool

    public init(
        provider: String,
        frames: [String],
        stderrLines: [String] = [],
        exitCode: Int32 = 0,
        reorder: Bool = false,
        stopRace: Bool = false
    ) {
        self.provider = provider
        self.frames = frames
        self.stderrLines = stderrLines
        self.exitCode = exitCode
        self.reorder = reorder
        self.stopRace = stopRace
    }

    public static func catalog() -> [CapacitySubprocessFixtureSpec] {
        [
            CapacitySubprocessFixtureSpec(
                provider: "claude",
                frames: [
                    #"{"type":"message_start","message":{"id":"m1","role":"assistant","content":[]}}"#,
                    #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                    #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}"#,
                    #"{"type":"content_block_stop","index":0}"#,
                    #"{"type":"message_stop"}"#,
                ],
                exitCode: 0
            ),
            CapacitySubprocessFixtureSpec(
                provider: "codex",
                frames: [
                    #"{"type":"thread.started","thread_id":"t1"}"#,
                    #"{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"ok"}}"#,
                    #"{"type":"turn.completed"}"#,
                ],
                stderrLines: ["noise"],
                exitCode: 0,
                reorder: true
            ),
            CapacitySubprocessFixtureSpec(
                provider: "grok",
                frames: [
                    #"{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"g"}}}}"#,
                ],
                exitCode: 1,
                stopRace: true
            ),
        ]
    }

    /// Apply reorder/stop-race transforms deterministically for a given seed.
    public func materializedFrames(seed: UInt64) -> [String] {
        var frames = self.frames
        if reorder && frames.count > 1 {
            // Stable seed mix — never use process-randomized hashValue.
            var mix: UInt64 = seed
            for b in provider.utf8 { mix = mix &* 131 + UInt64(b) }
            var rng = CapacitySeededRNG(seed: mix == 0 ? 1 : mix)
            let i = rng.nextInt(in: 0...(frames.count - 1))
            let j = rng.nextInt(in: 0...(frames.count - 1))
            frames.swapAt(i, j)
        }
        if stopRace {
            frames.append("[[rc:stop_race]]")
        }
        return frames
    }
}
