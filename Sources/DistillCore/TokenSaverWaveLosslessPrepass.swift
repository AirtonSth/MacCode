import Foundation
import CoreModel

/// Applies live Wave A / Wave B lossless transforms before the Distill sidecar call.
/// Fail-open: returns nil when no transform applies or when live rollout is off.
///
/// Early-return is reserved for transforms with a **byte-exact** round-trip proof.
/// `ManagedDistillCLI` skips the sidecar POST (and its recoverable store path) when
/// this prepass returns — so non-byte-exact or lossy transforms must return nil and
/// fall through (T-003 store-before-loss).
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

    // MARK: - Lossy Wave B opt-in (default OFF)

    /// Env flag for explicit opt-in to lossy Wave B crushers in this prepass.
    /// Value `"1"` / `"true"` / `"yes"` enables; anything else (or unset) is off.
    /// Distinct from `RC_TOKEN_SAVER_WAVE_LIVE` — does not alter `TokenSaverWaveLiveRollout`.
    public static let lossyCrushersOptInEnvKey = "RC_TOKEN_SAVER_PREPASS_LOSSY_CRUSHERS"

    private static let optInLock = NSLock()
    /// Test override; `nil` means read environment (production path).
    private static var _lossyCrushersOptInOverride: Bool?

    /// Explicit opt-in for lossy Wave B crushers. **Default false.**
    /// Required *in addition to* `TokenSaverWaveLiveRollout.isLive(.waveBCrushers)`.
    /// WHY: Wave B crushers are lossy and embed `[[rc:handle]]`; without opt-in + durable
    /// store those handles die with the CLI process and become unrecoverable (T-003).
    public static var lossyCrushersOptIn: Bool {
        optInLock.lock(); defer { optInLock.unlock() }
        if let override = _lossyCrushersOptInOverride { return override }
        let raw = ProcessInfo.processInfo.environment[lossyCrushersOptInEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if raw == "1" || raw == "true" || raw == "yes" { return true }
        // T-TO-01/02: when Token Saver distill is admitted, allow lossy prepass
        // with a durable store (still refused for process-local MemoryStore).
        let hint = ProcessInfo.processInfo.environment["RC_TOKEN_SAVER_DISTILL_HINT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return hint == "1"
    }

    /// Test hook: force opt-in on/off; pass `nil` to re-read the environment.
    public static func setLossyCrushersOptInForTesting(_ value: Bool?) {
        optInLock.lock()
        _lossyCrushersOptInOverride = value
        optInLock.unlock()
    }

    /// Try Wave A (byte-exact only) + optional Wave B crushers (opt-in + durable store).
    /// - Parameter durableStore: Optional durable `BlobStore` for lossy crushers. Process-local
    ///   `MemoryStore` is refused — blobs would not survive the CLI process for `/v1/retrieve` (T-003).
    public static func apply(
        input: String,
        toolHint: String? = nil,
        durableStore: TokenSaverTypedCrushers.BlobStore? = nil
    ) -> Result? {
        let originalBytes = input.utf8.count
        guard originalBytes > 0 else { return nil }

        if TokenSaverWaveLiveRollout.isLive(.waveA) {
            if let r = applyWaveA(input: input, originalBytes: originalBytes) {
                return r
            }
        }

        // Lossy Wave B: live rollout alone is insufficient — need explicit opt-in AND a
        // durable (non-process-local) store. Otherwise return nil so the sidecar handles
        // compression with recoverable store-before-loss (T-003).
        if TokenSaverWaveLiveRollout.isLive(.waveBCrushers),
           lossyCrushersOptIn,
           let store = durableStore,
           !TokenSaverTypedCrushers.isProcessLocalStore(store) {
            if let r = applyCrushers(
                input: input,
                toolHint: toolHint,
                originalBytes: originalBytes,
                store: store
            ) {
                return r
            }
            // T-TO-01: bash/build line budget when crushers miss but line count explodes.
            if let r = applyBashLineBudget(
                input: input,
                originalBytes: originalBytes,
                store: store
            ) {
                return r
            }
        }

        return nil
    }

    /// Apply only the byte-exact local prepass.
    ///
    /// The managed CLI runs in a short-lived process and cannot inject the sidecar's
    /// scoped durable store. Keeping its local fast path explicitly lossless prevents
    /// it from accidentally attempting a process-local Wave B store; recoverable lossy
    /// routes belong to the sidecar's scoped `/v1/distill` path.
    public static func applyLossless(input: String, toolHint: String? = nil) -> Result? {
        let originalBytes = input.utf8.count
        guard originalBytes > 0, TokenSaverWaveLiveRollout.isLive(.waveA) else { return nil }
        return applyWaveA(input: input, originalBytes: originalBytes)
    }

    /// Head/tail line budget with durable store-before-loss (T-TO-01).
    private static func applyBashLineBudget(
        input: String,
        originalBytes: Int,
        store: TokenSaverTypedCrushers.BlobStore
    ) -> Result? {
        let lineCount = input.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        guard lineCount > BashStdoutLineBudget.defaultMaxLines else { return nil }
        let data = Data(input.utf8)
        guard let handle = TokenSaverTypedCrushers.storeVerified(data, store: store) else { return nil }
        let budgeted = BashStdoutLineBudget.apply(input, handle: handle)
        guard budgeted.applied else { return nil }
        let compressedBytes = budgeted.text.utf8.count
        guard compressedBytes < originalBytes else { return nil }
        return Result(
            output: budgeted.text,
            waveID: TokenSaverWaveLiveRollout.WaveID.waveBCrushers.rawValue,
            trigger: "bash_line_budget",
            originalBytes: originalBytes,
            compressedBytes: compressedBytes
        )
    }

    // MARK: - Wave A

    /// Only transforms with a byte-exact round-trip proof may return a `Result`.
    /// - repeated-log: `expandStorelessLog(collapse(x)) == x` → may early-return
    /// - structured-JSON: sorted-key deep equality only (not byte-exact) → must not early-return
    private static func applyWaveA(input: String, originalBytes: Int) -> Result? {
        let modes = TokenSaverWaveALossless.defaults

        // Byte-exact: storeless RLE with proven expand(collapse(x)) == x.
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
        // Semantic-equality only: compact JSON reorders keys, drops whitespace/number
        // formatting/duplicate keys. NOT byte-exact — must NOT early-return or
        // ManagedDistillCLI would skip the sidecar recover path (T-003).
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
            // Deliberately no Result — fall through to sidecar.
        }

        return nil
    }

    // MARK: - Wave B crushers

    /// Lossy crushers: only called when opt-in is on and a durable store was injected.
    /// Never binds `sharedMemory` — process-local blobs cannot be retrieved by the sidecar (T-003).
    private static func applyCrushers(
        input: String,
        toolHint: String?,
        originalBytes: Int,
        store: TokenSaverTypedCrushers.BlobStore
    ) -> Result? {
        let reg = TokenSaverTypedCrushers.sharedRegistry

        if TokenSaverTypedCrushersBridge.containsFailedCountSummary(input)
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
