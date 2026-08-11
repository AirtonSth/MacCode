import Foundation
import CoreModel

/// Production bridge for Wave A lossless triggers (task-12).
/// Shadow/scorecard only by default; never mutates provider turns.
public enum TokenSaverWaveAShadowBridge {
    public static let taskID = "task-12"

    private struct ReplayKey: Hashable {
        let bindingDigest: String
        let toolName: String
    }

    private static let lock = NSLock()
    private static var priorByKey: [ReplayKey: Data] = [:]
    private static var pointerCounts: [ReplayKey: Int] = [:]
    private static var replayInsertionOrder: [ReplayKey] = []
    /// Peak distinct BindingID+tool exact-replay priors retained process-wide.
    /// Each value holds prior tool-output `Data` (can be multi-KB/MB). 128 matches
    /// other agent/Token Saver count windows — was 256 (and 2_048 before that).
    public static let maxReplayKeys = 128
    // PERF: observeToolOutput runs on every Token Saver tool observation.
    // Array-literal membership reallocated per call; share process-wide Set.
    private static let shellLikeToolNames: Set<String> = [
        "Bash", "bash", "Shell", "shell",
    ]

    /// Exact-replay state is atomic per BindingID+tool — never cross-binding.
    public static func observeExactReplay(
        bindingDigest: String,
        toolName: String,
        current: Data
    ) {
        guard !bindingDigest.isEmpty else { return } // no synthetic BindingID
        let key = ReplayKey(bindingDigest: bindingDigest, toolName: toolName)
        lock.lock()
        if priorByKey[key] == nil {
            if replayInsertionOrder.count >= maxReplayKeys {
                let evicted = replayInsertionOrder.removeFirst()
                priorByKey.removeValue(forKey: evicted)
                pointerCounts.removeValue(forKey: evicted)
            }
            replayInsertionOrder.append(key)
        }
        let prior = priorByKey[key]
        let count = pointerCounts[key] ?? 0
        let isMostRecent = prior == nil || prior != current
        if prior == current {
            pointerCounts[key] = count + 1
        } else {
            pointerCounts[key] = 1
            priorByKey[key] = current
        }
        let pointerCount = pointerCounts[key] ?? 1
        lock.unlock()

        let allows = TokenSaverWaveALossless.exactReplayAllows(
            first: prior ?? current,
            second: current,
            isMostRecent: isMostRecent,
            pointerCount: pointerCount
        )
        TokenSaverWaveALossless.observeShadow(
            trigger: .exactToolReplay,
            eligible: prior == current,
            wouldAccept: allows,
            bindingDigest: bindingDigest
        )
    }

    internal static func replayStateCountForTesting() -> Int {
        lock.lock(); defer { lock.unlock() }
        return priorByKey.count
    }

    internal static func resetReplayStateForTesting() {
        lock.lock()
        priorByKey.removeAll()
        pointerCounts.removeAll()
        replayInsertionOrder.removeAll()
        lock.unlock()
    }

    public static func observeToolOutput(
        toolName: String,
        output: String,
        bindingDigest: String?
    ) {
        // Score only when a real BindingID digest is provided (no tool-only synthetic IDs).
        guard let digest = bindingDigest, !digest.isEmpty else { return }

        let isLogLike = shellLikeToolNames.contains(toolName)
            || LogCollapser.looksLikeLog(output)
            || output.contains("exit")
        if isLogLike {
            // Prefer storeless LogCollapser round-trip when available; fall back to Wave A RLE.
            let allows: Bool
            if let collapsed = LogCollapser.collapse(output) {
                allows = LogCollapser.expand(collapsed) == output
                    && TokenSaverWaveALossless.preservesExitMarkers(original: output, collapsed: collapsed)
            } else {
                allows = TokenSaverWaveALossless.repeatedLogAllows(original: output)
            }
            TokenSaverWaveALossless.observeShadow(
                trigger: .repeatedLog,
                eligible: true,
                wouldAccept: allows,
                bindingDigest: digest
            )
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "{" || trimmed.first == "[" {
            let compact = compactJSON(trimmed) ?? trimmed
            let allows = TokenSaverWaveALossless.structuredJSONAllows(original: trimmed, collapsed: compact)
            TokenSaverWaveALossless.observeShadow(
                trigger: .structuredJSON,
                eligible: TokenSaverWaveALossless.isHomogeneousJSON(trimmed),
                wouldAccept: allows,
                bindingDigest: digest
            )
        }

        // PERF: one UTF-8 materialization shared by exact-replay store and
        // shadow metrics (tool outputs can be multi-KB/MB).
        let outputBytes = Data(output.utf8)
        observeExactReplay(
            bindingDigest: digest,
            toolName: toolName,
            current: outputBytes
        )
        _ = observeShadowMetrics(
            bindingDigest: digest,
            providerVisible: outputBytes,
            cacheVolatileTokens: 0,
            queueCohortSize: 0,
            pair: nil
        )
    }

    public static func failOpenObserve(_ body: () throws -> Void) {
        do { try body() } catch { /* fail-open */ }
    }

    private static func compactJSON(_ s: String) -> String? {
        guard let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: []) else {
            return nil
        }
        return String(data: out, encoding: .utf8)
    }
}

extension TokenSaverWaveAShadowBridge {
    /// task-13: emit shadow metrics without mutating provider payload.
    @discardableResult
    public static func observeShadowMetrics(
        bindingDigest: String,
        providerVisible: Data,
        cacheVolatileTokens: Int,
        queueCohortSize: Int,
        pair: TokenSaverWaveAShadowMetrics.PairedControlEvidence?
    ) -> Data {
        let unchanged = TokenSaverWaveAShadowMetrics.observeWithoutMutation(providerVisible)
        _ = TokenSaverWaveAShadowMetrics.emit(
            bindingDigest: bindingDigest,
            cacheVolatileTokens: cacheVolatileTokens,
            queueCohortSize: queueCohortSize,
            pair: pair
        )
        return unchanged
    }
}
