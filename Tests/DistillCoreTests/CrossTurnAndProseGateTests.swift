import XCTest
@testable import DistillCore

/// I11 cross-turn dedup safety + I12.7 prose-lane gate stack.
final class CrossTurnAndProseGateTests: XCTestCase {
    // I11.7: raw-byte hash, no normalization → volatile differences are different keys.
    func test_rawByteHashIsLiteral() {
        let a = "deploy 2026-06-14T01:00:00Z ok"
        let b = "deploy 2026-06-14T09:30:00Z ok"
        XCTAssertNotEqual(CrossTurnDedupPolicy.rawByteHash(a), CrossTurnDedupPolicy.rawByteHash(b))
        XCTAssertEqual(CrossTurnDedupPolicy.rawByteHash(a), CrossTurnDedupPolicy.rawByteHash(a))
    }

    // I11.2/3: pointer only when byte-identical, same-thread, and prior was verbatim.
    func test_mayPointerRequiresByteIdenticalSameThreadVerbatim() {
        XCTAssertTrue(CrossTurnDedupPolicy.mayPointer(candidate: "X", priorOccurrence: "X", sameThread: true, priorWasVerbatim: true))
        XCTAssertFalse(CrossTurnDedupPolicy.mayPointer(candidate: "X", priorOccurrence: "Y", sameThread: true, priorWasVerbatim: true))
        XCTAssertFalse(CrossTurnDedupPolicy.mayPointer(candidate: "X", priorOccurrence: "X", sameThread: false, priorWasVerbatim: true))
        XCTAssertFalse(CrossTurnDedupPolicy.mayPointer(candidate: "X", priorOccurrence: "X", sameThread: true, priorWasVerbatim: false))
    }

    // I11.10: never pointer the freshest output; cap per prompt.
    func test_pointerCapsAndFreshestGuard() {
        XCTAssertFalse(CrossTurnDedupPolicy.pointerAllowed(isFreshestOutputOfTurn: true, pointersThisPrompt: 0, cap: 8))
        XCTAssertTrue(CrossTurnDedupPolicy.pointerAllowed(isFreshestOutputOfTurn: false, pointersThisPrompt: 7, cap: 8))
        XCTAssertFalse(CrossTurnDedupPolicy.pointerAllowed(isFreshestOutputOfTurn: false, pointersThisPrompt: 8, cap: 8))
    }

    // I11.6: block-level disabled (whole-payload only in v1).
    func test_blockLevelDisabled() {
        XCTAssertFalse(CrossTurnDedupPolicy.blockLevelEnabled)
        XCTAssertEqual(CrossTurnDedupPolicy.writerOwnership, "sidecar_single_writer_wal")
    }

    // I12.7: gate stack refuses without a handle and rejects toward original on any gate fail.
    func test_proseGateStackRefusesWithoutHandle() {
        let v = ProseLaneGateStack.evaluate(original: "a long original line here", compressed: "short", handle: nil)
        XCTAssertFalse(v.accepted)
        XCTAssertEqual(v.reason, "no_reversible_handle")
        XCTAssertEqual(v.output, "a long original line here")
    }

    func test_proseGateStackRejectsLiteralDrop() {
        let original = "build error at /var/log/app.log code 4321 in module"
        let compressed = "build ok in module"  // drops the error/path/number
        let v = ProseLaneGateStack.evaluate(original: original, compressed: compressed, handle: "deadbeef")
        XCTAssertFalse(v.accepted)
        XCTAssertEqual(v.output, original)
    }

    func test_proseGateStackAcceptsFaithfulCompression() {
        let original = "The deployment pipeline ran for a while and then it eventually completed without anything notable to report at all today."
        let compressed = "The deployment pipeline ran and completed without anything notable to report."
        let v = ProseLaneGateStack.evaluate(original: original, compressed: compressed, handle: "deadbeef", minGainRatio: 0.10)
        XCTAssertTrue(v.accepted, "faithful, gainful, handle-backed compression passes all 4 gates")
        XCTAssertEqual(v.output, compressed)
    }

    func test_proseGateStackRejectsBelowMinGain() {
        let original = "The pipeline ran and completed without notable issues."
        let compressed = "The pipeline ran and completed without notable issue."  // ~no gain
        let v = ProseLaneGateStack.evaluate(original: original, compressed: compressed, handle: "deadbeef", minGainRatio: 0.10)
        XCTAssertFalse(v.accepted)
    }
}
