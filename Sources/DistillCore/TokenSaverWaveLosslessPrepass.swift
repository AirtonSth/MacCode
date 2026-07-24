import Foundation
import CoreModel

/// Applies live Wave A / Wave B lossless transforms before the Distill sidecar call.
/// Fail-open: returns nil when no transform applies or when live rollout is off.
public enum TokenSaverWaveLosslessPrepass {
    public struct Result: Sendable, Equatable {
        public let output: String
        public let waveID: String
        public let trigger: String
        public let originalBytes: Int
        public let compressedBytes: Int

        public var savedBytes: Int { max(0, originalBytes - compressedBytes) }
        public var savedFraction: Double {
            guard originalBytes > 0 else { return 0 }
            return Double(savedBytes) / Double(originalBytes)
        }
    }

    /// Try Wave A + Wave B crushers. First accepted transform wins.
    public static func apply(input: String, toolHint: String? = nil) -> Result? {
        let originalBytes = input.utf8.count
        guard originalBytes > 0 else { return nil }

        if TokenSaverWaveLiveRollout.isLive(.waveA) {
            if let r = applyWaveA(input: input, originalBytes: originalBytes) {
                return r
            }
        }

        if TokenSaverWaveLiveRollout.isLive(.waveBCrushers) {
            if let r = applyCrushers(input: input, toolHint: toolHint, originalBytes: originalBytes) {
                return r
            }
        }

        return nil
    }

    // MARK: - Wave A

    private static func applyWaveA(input: String, originalBytes: Int) -> Result? {
        let modes = TokenSaverWaveALossless.defaults

        if modes[.repeatedLog] == .active,
           TokenSaverWaveALossless.repeatedLogAllows(original: input),
           let collapsed = TokenSaverWaveALossless.collapseStorelessLog(input),
           collapsed.utf8.count < originalBytes {
            TokenSaverWaveALossless.observeShadow(
                trigger: .repeatedLog,
                eligible: true,
                wouldAccept: true
            )
            return Result(
                output: collapsed,
                waveID: TokenSaverWaveLiveRollout.WaveID.waveA.rawValue,
                trigger: TokenSaverWaveALossless.Trigger.repeatedLog.rawValue,
                originalBytes: originalBytes,
                compressedBytes: collapsed.utf8.count
            )
        }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if modes[.structuredJSON] == .active,
           TokenSaverWaveALossless.isHomogeneousJSON(trimmed),
           let compact = compactJSON(trimmed),
           TokenSaverWaveALossless.structuredJSONAllows(original: trimmed, collapsed: compact),
           compact.utf8.count < originalBytes {
            TokenSaverWaveALossless.observeShadow(
                trigger: .structuredJSON,
                eligible: true,
                wouldAccept: true
            )
            return Result(
                output: compact,
                waveID: TokenSaverWaveLiveRollout.WaveID.waveA.rawValue,
                trigger: TokenSaverWaveALossless.Trigger.structuredJSON.rawValue,
                originalBytes: originalBytes,
                compressedBytes: compact.utf8.count
            )
        }

        return nil
    }

    // MARK: - Wave B crushers

    private static func applyCrushers(input: String, toolHint: String?, originalBytes: Int) -> Result? {
        let store = TokenSaverTypedCrushers.sharedMemory
        let reg = TokenSaverTypedCrushers.sharedRegistry

        if input.range(of: #"\d+\s+failed"#, options: .regularExpression) != nil
            || input.lowercased().contains("pytest") {
            let failureLines = TokenSaverTypedCrushersBridge.pytestFailureLines(from: input)
            let r = TokenSaverTypedCrushers.crushPytest(
                original: input,
                failureLines: failureLines,
                store: store,
                registry: reg,
                masterEnabled: true
            )
            if r.accepted, let collapsed = r.collapsed, collapsed.utf8.count < originalBytes {
                return Result(
                    output: collapsed,
                    waveID: TokenSaverWaveLiveRollout.WaveID.waveBCrushers.rawValue,
                    trigger: TokenSaverTypedCrushers.CrusherKind.pytest.rawValue,
                    originalBytes: originalBytes,
                    compressedBytes: collapsed.utf8.count
                )
            }
        }

        if input.contains("Traceback")
            || input.split(separator: "\n").contains(where: { TokenSaverTypedCrushers.isStackFrameLine(String($0)) }) {
            let r = TokenSaverTypedCrushers.crushStacktrace(
                original: input,
                store: store,
                registry: reg,
                masterEnabled: true
            )
            if r.accepted, let collapsed = r.collapsed, collapsed.utf8.count < originalBytes {
                return Result(
                    output: collapsed,
                    waveID: TokenSaverWaveLiveRollout.WaveID.waveBCrushers.rawValue,
                    trigger: TokenSaverTypedCrushers.CrusherKind.stacktrace.rawValue,
                    originalBytes: originalBytes,
                    compressedBytes: collapsed.utf8.count
                )
            }
        }

        if TokenSaverTypedCrushers.isUnifiedDiff(input) {
            let r = TokenSaverTypedCrushers.crushDiff(
                original: input,
                isBinary: false,
                store: store,
                registry: reg,
                masterEnabled: true
            )
            if r.accepted, let collapsed = r.collapsed, collapsed.utf8.count < originalBytes {
                return Result(
                    output: collapsed,
                    waveID: TokenSaverWaveLiveRollout.WaveID.waveBCrushers.rawValue,
                    trigger: TokenSaverTypedCrushers.CrusherKind.diff.rawValue,
                    originalBytes: originalBytes,
                    compressedBytes: collapsed.utf8.count
                )
            }
        }

        let tool = (toolHint ?? "").lowercased()
        if tool == "grep" || tool == "glob" || tool.contains("search") {
            let lines = input.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            let r = TokenSaverTypedCrushers.crushSearch(
                original: input,
                matchLines: lines,
                store: store,
                registry: reg,
                masterEnabled: true
            )
            if r.accepted, let collapsed = r.collapsed, collapsed.utf8.count < originalBytes {
                return Result(
                    output: collapsed,
                    waveID: TokenSaverWaveLiveRollout.WaveID.waveBCrushers.rawValue,
                    trigger: TokenSaverTypedCrushers.CrusherKind.search.rawValue,
                    originalBytes: originalBytes,
                    compressedBytes: collapsed.utf8.count
                )
            }
        }

        if trimmedIsJSON(input) {
            let r = TokenSaverTypedCrushers.crushAdaptiveJSON(
                original: input.trimmingCharacters(in: .whitespacesAndNewlines),
                store: store,
                registry: reg,
                masterEnabled: true
            )
            if r.accepted, let collapsed = r.collapsed, collapsed.utf8.count < originalBytes {
                return Result(
                    output: collapsed,
                    waveID: TokenSaverWaveLiveRollout.WaveID.waveBCrushers.rawValue,
                    trigger: TokenSaverTypedCrushers.CrusherKind.adaptiveJSON.rawValue,
                    originalBytes: originalBytes,
                    compressedBytes: collapsed.utf8.count
                )
            }
        }

        return nil
    }

    private static func compactJSON(_ s: String) -> String? {
        guard let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: []) else {
            return nil
        }
        return String(data: out, encoding: .utf8)
    }

    private static func trimmedIsJSON(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.first == "{" || t.first == "["
    }
}
