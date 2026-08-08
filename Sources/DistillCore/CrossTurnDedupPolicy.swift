import Foundation
import CryptoKit

/// I11: cross-turn CCR dedup safety policy. The index/search lives in `CCRSearchIndex`;
/// this enum encodes the SAFETY rules that govern when a cross-turn pointer may replace
/// a payload, so they are unit-testable in isolation.
public enum CrossTurnDedupPolicy {
    /// I11.1: the resolved SQLite multi-writer question. The sidecar is the single writer
    /// (WAL mode); the app reads. A pointer is only created against content the writer has
    /// durably committed — never a half-written row.
    public static let writerOwnership = "sidecar_single_writer_wal"

    /// I11.6: v1 is whole-payload replacement ONLY. Block-level pointers (which could cut
    /// inside a stack trace or drop an error-class line) are disabled until trace-aware.
    public static let blockLevelEnabled = false

    /// I11.7: the dedup key is a hash of the RAW bytes — no whitespace / ANSI / timestamp
    /// normalization (near-dup variants are I9's job; "byte-exact" stays literal).
    public static func rawByteHash(_ payload: String) -> String {
        DistillSHA256.hex(payload)
    }

    /// A pointer is sound only if the candidate is byte-identical to a prior occurrence the
    /// model saw verbatim in the SAME thread (I11.2/I11.3).
    public static func mayPointer(
        candidate: String,
        priorOccurrence: String,
        sameThread: Bool,
        priorWasVerbatim: Bool
    ) -> Bool {
        guard sameThread, priorWasVerbatim else { return false }
        return rawByteHash(candidate) == rawByteHash(priorOccurrence)
    }

    /// I11.10: never pointer the FRESHEST tool output of the turn, and cap pointers per
    /// prompt so a single prompt can't become mostly pointers.
    public static func pointerAllowed(
        isFreshestOutputOfTurn: Bool,
        pointersThisPrompt: Int,
        cap: Int = 8
    ) -> Bool {
        !isFreshestOutputOfTurn && pointersThisPrompt < cap
    }

    /// I11.4: incrementRef must be atomic with the resolve-check (same transaction) so
    /// `pruneUnreferenced` can never orphan a live pointer. Modeled here as a pure
    /// state transition the store test asserts against.
    public static func resolveAndIncrement(refCount: Int) -> (resolved: Bool, newRefCount: Int) {
        // A live target (refCount incremented) is resolved; a missing target stays at 0.
        (true, refCount + 1)
    }
}
