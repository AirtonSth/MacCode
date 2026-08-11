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
    /// Indices into schedule.faults that were applied during the run.
    public var appliedFaultIndices: [Int]
    /// True when every scheduled fault was applied exactly once and no unknown kinds remain.
    public var allFaultsApplied: Bool
    public var unknownFaultKinds: [String]

    public init(
        nodes: [CapacityHarnessNode],
        longestNoProgressMs: Int64,
        completedCount: Int,
        cancelledCount: Int,
        failedCount: Int,
        rejoinExactlyOnce: Bool,
        queueDrained: Bool,
        terminalOwnershipExact: Bool,
        appliedFaultIndices: [Int] = [],
        allFaultsApplied: Bool = true,
        unknownFaultKinds: [String] = []
    ) {
        self.nodes = nodes
        self.longestNoProgressMs = longestNoProgressMs
        self.completedCount = completedCount
        self.cancelledCount = cancelledCount
        self.failedCount = failedCount
        self.rejoinExactlyOnce = rejoinExactlyOnce
        self.queueDrained = queueDrained
        self.terminalOwnershipExact = terminalOwnershipExact
        self.appliedFaultIndices = appliedFaultIndices
        self.allFaultsApplied = allFaultsApplied
        self.unknownFaultKinds = unknownFaultKinds
    }
}

public enum CapacityHarnessKnownFaultKind: String, Sendable, CaseIterable {
    case malformed_frame
    case reorder
    case pipe_pressure
    case stop_race
    case resume
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

        // Seeded fault plan: place every declared kind on live roots so
        // qualification cannot skip kinds that land on never-activated children.
        // stop_race+resume pair on the first root; remaining kinds on other roots.
        var faults: [CapacityHarnessFault] = []
        if let pairNode = rootIDs.first {
            faults.append(CapacityHarnessFault(atMs: 50, nodeId: pairNode, kind: "stop_race"))
            faults.append(CapacityHarnessFault(atMs: 150, nodeId: pairNode, kind: "resume"))
        }
        let remainingKinds = faultKinds.filter { $0 != "stop_race" && $0 != "resume" }
        // One deterministic root-targeted fault per remaining kind (reachable).
        for (i, kind) in remainingKinds.enumerated() {
            guard rootIDs.count > 1 else { break }
            let node = rootIDs[(i + 1) % rootIDs.count]
            faults.append(CapacityHarnessFault(atMs: Int64((i + 1) * 40), nodeId: node, kind: kind))
        }
        // Optional extras for stress, still root-only so they stay reachable.
        let extraBudget = min(3, max(0, rootIDs.count - 1 - remainingKinds.count))
        for i in 0..<extraBudget {
            let node = rootIDs[(i + 1 + remainingKinds.count) % rootIDs.count]
            let kind = remainingKinds.isEmpty
                ? faultKinds[i % max(1, faultKinds.count)]
                : remainingKinds[i % remainingKinds.count]
            faults.append(CapacityHarnessFault(atMs: Int64((i + 4) * 80), nodeId: node, kind: kind))
        }

        return CapacityHarnessSchedule(nodes: nodes, faults: faults, seed: seed)
    }

    /// Execute the schedule on a virtual clock. Pure in-process simulation.
    ///
    /// Every declared fault kind is modeled. Faults due at or before `now` apply
    /// when their node is active; future-dated faults are not lost — they apply
    /// on the first quantum once `atMs` is reached while the node is still live,
    /// or at terminalization if the node finishes earlier (forced application).
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
        var appliedFaultIndices = Set<Int>()
        var skippedFaultIndices = Set<Int>()
        var unknownFaultKinds: [String] = []
        // Nodes that still need an extra quantum after pipe_pressure.
        var pipePressurePending = Set<String>()

        func markProgress() {
            let gap = clock.nowMs - lastProgressMs
            if gap > longestGap { longestGap = gap }
            lastProgressMs = clock.nowMs
        }

        func markFaultApplied(_ faultIndex: Int) {
            appliedFaultIndices.insert(faultIndex)
        }

        /// Fault outcome: terminal ends the node; requeue only reorders work.
        enum FaultEffect {
            case none
            case requeue
            case terminal
        }

        /// Unreachable faults on a terminalized node are explicitly skipped
        /// (not counted as executed).
        func skipRemainingFaultsForNode(_ nodeId: String) {
            for (faultIndex, fault) in schedule.faults.enumerated()
            where !appliedFaultIndices.contains(faultIndex)
                && !skippedFaultIndices.contains(faultIndex)
                && fault.nodeId == nodeId {
                if CapacityHarnessKnownFaultKind(rawValue: fault.kind) == nil,
                   !unknownFaultKinds.contains(fault.kind) {
                    unknownFaultKinds.append(fault.kind)
                }
                skippedFaultIndices.insert(faultIndex)
            }
        }

        /// Apply one scheduled fault. Returns effect for the caller's queue handling.
        func applyFault(faultIndex: Int, nodeIdx: Int) -> FaultEffect {
            guard !appliedFaultIndices.contains(faultIndex) else { return .none }
            let fault = schedule.faults[faultIndex]
            guard let kind = CapacityHarnessKnownFaultKind(rawValue: fault.kind) else {
                if !unknownFaultKinds.contains(fault.kind) {
                    unknownFaultKinds.append(fault.kind)
                }
                markFaultApplied(faultIndex)
                return .none
            }
            switch kind {
            case .stop_race:
                nodes[nodeIdx].status = .cancelled
                nodes[nodeIdx].finishedAtMs = clock.nowMs
                markFaultApplied(faultIndex)
                // Do not skip remaining: a later resume may re-admit the node.
                markProgress()
                return .terminal
            case .malformed_frame:
                nodes[nodeIdx].status = .failed
                nodes[nodeIdx].finishedAtMs = clock.nowMs
                markFaultApplied(faultIndex)
                markProgress()
                return .terminal
            case .reorder:
                // Move to tail even if already queued (true reorder).
                let id = nodes[nodeIdx].id
                activeQueue.removeAll { $0 == id }
                activeQueue.append(id)
                markFaultApplied(faultIndex)
                markProgress()
                return .requeue
            case .pipe_pressure:
                pipePressurePending.insert(nodes[nodeIdx].id)
                markFaultApplied(faultIndex)
                markProgress()
                return .none
            case .resume:
                // Resume may re-admit a cancelled node (time-ordered after stop_race).
                if nodes[nodeIdx].status == .cancelled || nodes[nodeIdx].status == .failed {
                    nodes[nodeIdx].status = .waiting
                    nodes[nodeIdx].finishedAtMs = nil
                    nodes[nodeIdx].startedAtMs = nil
                }
                markFaultApplied(faultIndex)
                markProgress()
                return .none
            }
        }

        // Activate roots.
        for id in activeQueue {
            guard let idx = byId[id] else { continue }
            nodes[idx].status = .active
            nodes[idx].startedAtMs = clock.nowMs
        }

        // Cancel requested nodes immediately (they never become active work).
        for i in nodes.indices where cancelNodeIds.contains(nodes[i].id) {
            nodes[i].status = .cancelled
            nodes[i].finishedAtMs = clock.nowMs
            nodes[i].resultRejoined = nodes[i].kind == .root
            markProgress()
        }
        activeQueue = activeQueue.filter { !cancelNodeIds.contains($0) }

        func hasPendingResumableFaults() -> Bool {
            for (fi, fault) in schedule.faults.enumerated()
            where !appliedFaultIndices.contains(fi) && !skippedFaultIndices.contains(fi) {
                guard fault.kind == CapacityHarnessKnownFaultKind.resume.rawValue,
                      let idx = byId[fault.nodeId] else { continue }
                if nodes[idx].status == .cancelled || nodes[idx].status == .failed {
                    return true
                }
            }
            return false
        }

        var safety = 0
        while nodes.contains(where: { $0.status == .waiting || $0.status == .active })
            || hasPendingResumableFaults() {
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

            // Due faults: active nodes; resume also on cancelled/failed terminals.
            for (faultIndex, fault) in schedule.faults.enumerated()
            where !appliedFaultIndices.contains(faultIndex)
                && !skippedFaultIndices.contains(faultIndex)
                && fault.atMs <= clock.nowMs {
                guard let idx = byId[fault.nodeId] else { continue }
                let status = nodes[idx].status
                let isResume = fault.kind == CapacityHarnessKnownFaultKind.resume.rawValue
                if isResume {
                    guard status == .cancelled || status == .failed || status == .active else { continue }
                } else {
                    guard status == .active else { continue }
                }
                switch applyFault(faultIndex: faultIndex, nodeIdx: idx) {
                case .terminal:
                    activeQueue.removeAll { $0 == fault.nodeId }
                case .requeue:
                    break
                case .none:
                    // Resume may re-admit as waiting — ensure it can start.
                    if isResume, nodes[idx].status == .waiting {
                        // parent completed or root: activate next loop
                    }
                    break
                }
            }

            guard let currentId = activeQueue.first else {
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

            // Apply first unapplied due fault for this node.
            var skipCompletion = false
            for (faultIndex, fault) in schedule.faults.enumerated()
            where !appliedFaultIndices.contains(faultIndex)
                && fault.nodeId == currentId
                && fault.atMs <= clock.nowMs {
                switch applyFault(faultIndex: faultIndex, nodeIdx: idx) {
                case .terminal:
                    skipCompletion = true
                case .requeue:
                    skipCompletion = true
                case .none:
                    break
                }
                if skipCompletion { break }
            }
            if skipCompletion {
                clock.advance(byMs: workQuantumMs)
                continue
            }

            // Future-dated faults: advance clock and apply earliest pending.
            if let (faultIndex, _) = schedule.faults.enumerated()
                .filter({ !appliedFaultIndices.contains($0.offset) && $0.element.nodeId == currentId })
                .min(by: { $0.element.atMs < $1.element.atMs }) {
                let due = schedule.faults[faultIndex].atMs
                if due > clock.nowMs {
                    clock.advance(byMs: due - clock.nowMs)
                }
                switch applyFault(faultIndex: faultIndex, nodeIdx: idx) {
                case .terminal, .requeue:
                    clock.advance(byMs: workQuantumMs)
                    continue
                case .none:
                    break
                }
            }

            // Pipe pressure: burn one extra quantum before allowing completion.
            if pipePressurePending.contains(currentId) {
                pipePressurePending.remove(currentId)
                clock.advance(byMs: workQuantumMs)
                if !activeQueue.contains(currentId) {
                    activeQueue.append(currentId)
                }
                markProgress()
                continue
            }

            // Complete work quantum.
            clock.advance(byMs: workQuantumMs)
            nodes[idx].status = .completed
            nodes[idx].finishedAtMs = clock.nowMs
            let childId = nodes[idx].id
            rejoinCounts[childId, default: 0] += 1
            nodes[idx].resultRejoined = rejoinCounts[childId] == 1
            skipRemainingFaultsForNode(childId)
            markProgress()
        }

        // Account remaining: unapplied faults on terminal nodes are skipped.
        for (faultIndex, fault) in schedule.faults.enumerated()
        where !appliedFaultIndices.contains(faultIndex) && !skippedFaultIndices.contains(faultIndex) {
            if let idx = byId[fault.nodeId] {
                switch nodes[idx].status {
                case .completed, .failed, .cancelled:
                    skipRemainingFaultsForNode(fault.nodeId)
                case .waiting, .active:
                    break
                }
            } else {
                skippedFaultIndices.insert(faultIndex)
            }
            if CapacityHarnessKnownFaultKind(rawValue: fault.kind) == nil,
               !unknownFaultKinds.contains(fault.kind) {
                unknownFaultKinds.append(fault.kind)
            }
        }

        let completed = nodes.filter { $0.status == .completed }.count
        let cancelled = nodes.filter { $0.status == .cancelled }.count
        let failed = nodes.filter { $0.status == .failed }.count
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
        // Qualification requires true application (not skip accounting).
        let allFaultsApplied = appliedFaultIndices.count == schedule.faults.count
            && unknownFaultKinds.isEmpty
            && skippedFaultIndices.isEmpty

        return CapacityHarnessRunResult(
            nodes: nodes,
            longestNoProgressMs: longestGap,
            completedCount: completed,
            cancelledCount: cancelled,
            failedCount: failed,
            rejoinExactlyOnce: rejoinOK,
            queueDrained: queueDrained,
            terminalOwnershipExact: terminalExact,
            appliedFaultIndices: appliedFaultIndices.sorted(),
            allFaultsApplied: allFaultsApplied,
            unknownFaultKinds: unknownFaultKinds
        )
    }
}

// MARK: - Production-path subprocess fixture scaffolding (S2)

/// Result of spawning a controlled local child that emits fixture frames.
public struct CapacitySubprocessRunResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdoutLines: [String]
    public var stderrLines: [String]
    public var pid: pid_t
    public var stoppedByCaller: Bool

    public init(
        exitCode: Int32,
        stdoutLines: [String],
        stderrLines: [String],
        pid: pid_t,
        stoppedByCaller: Bool
    ) {
        self.exitCode = exitCode
        self.stdoutLines = stdoutLines
        self.stderrLines = stderrLines
        self.pid = pid
        self.stoppedByCaller = stoppedByCaller
    }
}

/// Spawns a real local shell child that prints fixture frames (S2).
/// This is not a paid provider CLI; it exercises process/pipe/Stop/reap ownership
/// on the production spawn/tag seams with deterministic content.
public enum CapacitySubprocessFixtureRunner {
    /// Spawn `/bin/sh` that echoes each frame on stdout, optional stderr lines,
    /// then exits with the fixture code. When `stopAfterMs` is set, the caller
    /// terminates the child mid-run (Stop race).
    public static func run(
        spec: CapacitySubprocessFixtureSpec,
        seed: UInt64 = 1,
        stopAfterMs: Int? = nil,
        requireOwnershipTag: Bool = false
    ) throws -> CapacitySubprocessRunResult {
        let frames = spec.materializedFrames(seed: seed).filter { !$0.contains("stop_race") }
        var scriptParts: [String] = ["set -e"]
        for frame in frames {
            let escaped = frame
                .replacingOccurrences(of: "'", with: "'\\''")
            scriptParts.append("printf '%s\\n' '\(escaped)'")
            scriptParts.append("sleep 0.01")
        }
        for line in spec.stderrLines {
            let escaped = line.replacingOccurrences(of: "'", with: "'\\''")
            scriptParts.append("printf '%s\\n' '\(escaped)' 1>&2")
        }
        // Keep the child alive briefly so stopAfterMs can race.
        if stopAfterMs != nil {
            scriptParts.append("sleep 2")
        }
        scriptParts.append("exit \(spec.exitCode)")
        let script = scriptParts.joined(separator: "; ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let pid = process.processIdentifier
        var ownershipTag: SpawnedProcessTag?
        if requireOwnershipTag {
            guard ProviderProcessOwnership.shared.store() != nil else {
                process.terminate()
                throw ProviderProcessOwnershipError.storeNotConfigured
            }
            ownershipTag = try ProcessSpawnTagger.tagProcess(process, managedKind: .sidecar)
        } else if ProviderProcessOwnership.shared.store() != nil {
            ownershipTag = try ProcessSpawnTagger.tagProcess(process, managedKind: .sidecar)
        }
        // Concurrent drain while the process runs (pipe-pressure safe).
        let outBox = CapacitySubprocessDrainBox()
        let errBox = CapacitySubprocessDrainBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.set(out.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.set(err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        var stoppedByCaller = false
        if let stopAfterMs, stopAfterMs >= 0 {
            Thread.sleep(forTimeInterval: Double(stopAfterMs) / 1000.0)
            if process.isRunning {
                process.terminate()
                stoppedByCaller = true
            }
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 2)
        if let ownershipTag {
            try ProviderProcessOwnership.shared.store()?.removeExact(ownershipTag)
        }
        let outLines = String(data: outBox.get(), encoding: .utf8)?
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty } ?? []
        let errLines = String(data: errBox.get(), encoding: .utf8)?
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty } ?? []
        return CapacitySubprocessRunResult(
            exitCode: process.terminationStatus,
            stdoutLines: outLines,
            stderrLines: errLines,
            pid: pid,
            stoppedByCaller: stoppedByCaller
        )
    }
}

private final class CapacitySubprocessDrainBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ data: Data) { lock.lock(); self.data = data; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// Describes a controlled stdout/stderr fixture for one real adapter seam.
/// Frames are also runnable via `CapacitySubprocessFixtureRunner` (real local child).
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
