import Foundation

/// Decides whether to compress the SINGLE outbound new-turn argv (the prompt path).
///
/// Verified fact: on resume both providers send the full wrapped prompt as argv and
/// the cached prefix lives entirely server-side — there is NO app-side prefix to
/// segment. So this is a NUMERIC predicate, not a positional segmenter (G3): compress
/// only when it is worth the MLX latency and not a quick warm follow-up.
///
/// Rules (in order):
///  1. Below `floorCharacters` → SKIP (too small to be worth a model round-trip).
///  2. Warm resume (a turn happened within `warmResumeTTLSeconds`) → SKIP (don't add
///     MLX latency to a rapid follow-up in an active session).
///  3. Otherwise → COMPRESS.
///
/// `secondsSinceLastTurn == nil` means UNKNOWN, which maps to COLD (never warm), so a
/// genuinely cold prompt is never wrongly skipped (N5). Cache-state is derived from
/// `provider_session_runtime.updated_at` staleness only — a heuristic, not a billed
/// cache hit — because that table has no TTL/cache columns (verified).
public struct NetPositiveGate: Sendable, Equatable {
    public let floorCharacters: Int
    public let warmResumeTTLSeconds: Double

    public init(floorCharacters: Int = 2_000, warmResumeTTLSeconds: Double = 300) {
        self.floorCharacters = max(1, floorCharacters)
        self.warmResumeTTLSeconds = max(0, warmResumeTTLSeconds)
    }

    public enum Decision: String, Sendable, Equatable {
        case compress
        case skipBelowFloor
        case skipWarmResume
    }

    public func decide(inputCharacters: Int, secondsSinceLastTurn: Double?) -> Decision {
        if inputCharacters < floorCharacters {
            return .skipBelowFloor
        }
        if let elapsed = secondsSinceLastTurn, elapsed >= 0, elapsed < warmResumeTTLSeconds {
            return .skipWarmResume
        }
        return .compress
    }

    public func shouldCompress(inputCharacters: Int, secondsSinceLastTurn: Double?) -> Bool {
        decide(inputCharacters: inputCharacters, secondsSinceLastTurn: secondsSinceLastTurn) == .compress
    }

    public func acceptsBilledSavings(
        originalBilledTokenUnits: Double,
        compressedBilledTokenUnits: Double,
        retrieveDebitUnits: Double = 0,
        localOverheadUnits: Double = 0
    ) -> Bool {
        let net = originalBilledTokenUnits
            - compressedBilledTokenUnits
            - max(0, retrieveDebitUnits)
            - max(0, localOverheadUnits)
        return net > 0
    }
}
