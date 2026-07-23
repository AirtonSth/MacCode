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

    /// Exact-replay state is atomic per BindingID+tool — never cross-binding.
    public static func observeExactReplay(
        bindingDigest: String,
        toolName: String,
        current: Data
    ) {
        guard !bindingDigest.isEmpty else { return } // no synthetic BindingID
        let key = ReplayKey(bindingDigest: bindingDigest, toolName: toolName)
        lock.lock()
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

    public static func observeToolOutput(
        toolName: String,
        output: String,
        bindingDigest: String?
    ) {
        // Score only when a real BindingID digest is provided (no tool-only synthetic IDs).
        guard let digest = bindingDigest, !digest.isEmpty else { return }

        let isLogLike = ["Bash", "bash", "Shell", "shell"].contains(toolName)
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

        observeExactReplay(
            bindingDigest: digest,
            toolName: toolName,
            current: Data(output.utf8)
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
