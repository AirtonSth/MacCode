import Foundation

/// Host-side live rollout for Token Saver waves (T-012 series).
///
/// Token economy remains gated by the global Token Saver toggle / distill hint.
/// Individual waves default OFF in code; this façade is the single place that
/// flips them live for production / E2E after admission.
///
/// Env override (for hermetic E2E without UI):
///   `RC_TOKEN_SAVER_WAVE_LIVE=all` or comma list:
///   `wave_a,wave_b_crushers,wave_b_cache,wave_b_recovery,wave_c_queue,wave_c_rollover,wave_d,prefetch,canary`
public enum TokenSaverWaveLiveRollout: Sendable {
    public enum WaveID: String, CaseIterable, Sendable {
        case waveA = "wave_a"
        case waveBCrushers = "wave_b_crushers"
        case waveBCache = "wave_b_cache"
        case waveBRecovery = "wave_b_recovery"
        case waveCQueue = "wave_c_queue"
        case waveCRollover = "wave_c_rollover"
        case waveD = "wave_d"
        case prefetch = "prefetch"
        case canary = "canary"
    }

    /// Process-wide live set. Empty until `activate` / env apply.
    private static let lock = NSLock()
    private static var _live: Set<WaveID> = []
    /// Permanently disabled for this process (unfixable after E2E).
    private static var _disabled: Set<WaveID> = []
    private static var _appliedEnv = false

    /// Waves currently live in this process.
    public static var liveWaves: Set<WaveID> {
        lock.lock(); defer { lock.unlock() }
        applyEnvIfNeededLocked()
        return _live
    }

    public static func isLive(_ wave: WaveID) -> Bool {
        liveWaves.contains(wave)
    }

    /// Enable one wave (idempotent). No-op if permanently disabled.
    public static func activate(_ wave: WaveID) {
        lock.lock()
        applyEnvIfNeededLocked()
        if _disabled.contains(wave) {
            lock.unlock()
            return
        }
        _live.insert(wave)
        lock.unlock()
        applySideEffects(for: wave, enabled: true)
    }

    /// Disable one wave (idempotent). Not permanent — `activate` can re-enable.
    public static func deactivate(_ wave: WaveID) {
        lock.lock()
        applyEnvIfNeededLocked()
        _live.remove(wave)
        lock.unlock()
        applySideEffects(for: wave, enabled: false)
    }

    /// Mark wave unfixable: stays off until process restart + explicit clear.
    public static func permanentlyDisable(_ wave: WaveID, reason: String) {
        lock.lock()
        _disabled.insert(wave)
        _live.remove(wave)
        lock.unlock()
        applySideEffects(for: wave, enabled: false)
        FileHandle.standardError.write(Data(
            "TokenSaverWaveLiveRollout permanently disabled \(wave.rawValue): \(reason)\n".utf8
        ))
    }

    public static var permanentlyDisabled: Set<WaveID> {
        lock.lock(); defer { lock.unlock() }
        return _disabled
    }

    /// Activate every wave that is not permanently disabled.
    public static func activateAll() {
        for w in WaveID.allCases where !permanentlyDisabled.contains(w) {
            activate(w)
        }
    }

    /// Clear process live set (tests).
    public static func resetForTesting() {
        lock.lock()
        _live.removeAll()
        _disabled.removeAll()
        _appliedEnv = false
        lock.unlock()
        TokenSaverWaveALossless.defaults = Dictionary(
            uniqueKeysWithValues: TokenSaverWaveALossless.Trigger.allCases.map { ($0, .shadow) }
        )
        TokenSaverTypedCrushers.sharedRegistry.deactivate()
    }

    // MARK: - Env

    private static func applyEnvIfNeededLocked() {
        guard !_appliedEnv else { return }
        _appliedEnv = true
        guard let raw = ProcessInfo.processInfo.environment["RC_TOKEN_SAVER_WAVE_LIVE"],
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let tokens = raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        if tokens.contains("all") {
            _live = Set(WaveID.allCases)
        } else {
            for t in tokens {
                if let w = WaveID(rawValue: t) { _live.insert(w) }
            }
        }
        for w in _live { applySideEffects(for: w, enabled: true) }
    }

    // MARK: - Side effects (defaults / registries)

    private static func applySideEffects(for wave: WaveID, enabled: Bool) {
        switch wave {
        case .waveA:
            let mode: TokenSaverWaveALossless.Mode = enabled ? .active : .shadow
            TokenSaverWaveALossless.defaults = Dictionary(
                uniqueKeysWithValues: TokenSaverWaveALossless.Trigger.allCases.map { ($0, mode) }
            )
        case .waveBCrushers:
            if enabled {
                // Master + all kinds on for exact-lossless crushers (store-before-loss still required).
                TokenSaverTypedCrushers.sharedRegistry.enableAllForTesting()
            } else {
                TokenSaverTypedCrushers.sharedRegistry.deactivate()
            }
        case .waveBCache, .waveBRecovery, .waveCQueue, .waveCRollover, .waveD, .prefetch, .canary:
            // Policy façades read `isLive` / `defaultEnabled` via this gate.
            break
        }
    }
}

// MARK: - Policy façade bridges (defaultEnabled reads live gate)

extension TokenSaverCacheGuard {
    /// Live when wave rollout enabled (overrides static defaultEnabled=false).
    public static var isLive: Bool {
        TokenSaverWaveLiveRollout.isLive(.waveBCache)
    }
}

extension TokenSaverRecoveryProjections {
    public static var isLive: Bool {
        TokenSaverWaveLiveRollout.isLive(.waveBRecovery)
    }
}

extension TokenSaverQueueCoalesce {
    public static var isLive: Bool {
        TokenSaverWaveLiveRollout.isLive(.waveCQueue)
    }
}

extension TokenSaverRolloverHandoff {
    public static var isLive: Bool {
        TokenSaverWaveLiveRollout.isLive(.waveCRollover)
    }
}

extension TokenSaverWaveDFamilies {
    public static var isLive: Bool {
        TokenSaverWaveLiveRollout.isLive(.waveD)
    }
}

extension TokenSaverTurnBatchPrefetch {
    public static var isLive: Bool {
        TokenSaverWaveLiveRollout.isLive(.prefetch)
    }
}

extension TokenSaverPromotionCanary {
    public static var isLive: Bool {
        TokenSaverWaveLiveRollout.isLive(.canary)
    }
}
