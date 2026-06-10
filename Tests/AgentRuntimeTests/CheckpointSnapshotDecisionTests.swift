import XCTest
import CryptoKit
@testable import AgentRuntime

// P2: verifies the checkpoint snapshot size/binary cap. WHY: without a cap the
// coordinator base64s every changed file into a DB row + a transient in-memory
// allocation, so a single large or binary file can balloon to 500MB+ per turn.
// These tests pin the decision that protects allocation/row size and prove the
// skip marker carries a content hash so the skipped bytes stay diagnosable.
final class CheckpointSnapshotDecisionTests: XCTestCase {

    private func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // Small text file at/under cap -> snapshot the bytes inline. WHY: normal
    // edits must keep their restorable content; capping must not regress them.
    func test_smallTextFileUnderCap_isSnapshotted() {
        let cap = 1024
        let decision = AgentRunCoordinator.checkpointSnapshotDecision(
            byteCount: 512,
            isBinary: false,
            cap: cap,
            hash: { XCTFail("hash must not be computed when snapshotting"); return "" }
        )
        XCTAssertEqual(decision, .snapshot)
    }

    // Exactly at the cap is still snapshotted (boundary is inclusive). WHY:
    // off-by-one on the boundary would silently drop a legitimately-small file.
    func test_textFileExactlyAtCap_isSnapshotted() {
        let cap = 1024
        let decision = AgentRunCoordinator.checkpointSnapshotDecision(
            byteCount: cap,
            isBinary: false,
            cap: cap,
            hash: { "unused" }
        )
        XCTAssertEqual(decision, .snapshot)
    }

    // Over the cap -> skip the bytes, emit a marker carrying the content hash.
    // WHY: this is the whole point of the cap -- never base64 oversized content.
    func test_textFileOverCap_skipsWithHashMarker() {
        let cap = 1024
        let payload = Data(repeating: 0x41, count: cap + 1) // "A" * (cap+1), text
        let expectedHash = hex(payload)
        let decision = AgentRunCoordinator.checkpointSnapshotDecision(
            byteCount: payload.count,
            isBinary: AgentRunCoordinator.dataLooksBinary(payload),
            cap: cap,
            hash: { AgentRunCoordinator.sha256Hex(payload) }
        )
        XCTAssertEqual(decision, .skipMarker(hash: expectedHash))
    }

    // Binary file under the cap -> still skipped. WHY: base64'ing binary blobs
    // (e.g. a small image) bloats rows and they are not text-restorable anyway;
    // size alone must not be the only guard.
    func test_smallBinaryFile_skipsWithHashMarker() {
        let cap = 1024
        var payload = Data(repeating: 0x42, count: 16)
        payload.append(0x00) // NUL byte => binary per repo convention
        let expectedHash = hex(payload)
        XCTAssertTrue(AgentRunCoordinator.dataLooksBinary(payload), "NUL byte must mark data binary")
        let decision = AgentRunCoordinator.checkpointSnapshotDecision(
            byteCount: payload.count,
            isBinary: AgentRunCoordinator.dataLooksBinary(payload),
            cap: cap,
            hash: { AgentRunCoordinator.sha256Hex(payload) }
        )
        XCTAssertEqual(decision, .skipMarker(hash: expectedHash))
    }

    // The hash in the marker is the SHA256 of the exact bytes -- distinct content
    // yields a distinct marker. WHY: a hardcoded/constant marker would pass the
    // shape checks above but be useless for diagnosing which bytes were skipped.
    func test_skipMarkerHash_tracksContent() {
        let cap = 8
        let a = Data(repeating: 0x41, count: cap + 1)
        let b = Data(repeating: 0x5A, count: cap + 1)
        let da = AgentRunCoordinator.checkpointSnapshotDecision(
            byteCount: a.count, isBinary: false, cap: cap, hash: { AgentRunCoordinator.sha256Hex(a) }
        )
        let db = AgentRunCoordinator.checkpointSnapshotDecision(
            byteCount: b.count, isBinary: false, cap: cap, hash: { AgentRunCoordinator.sha256Hex(b) }
        )
        XCTAssertEqual(da, .skipMarker(hash: hex(a)))
        XCTAssertEqual(db, .skipMarker(hash: hex(b)))
        XCTAssertNotEqual(da, db, "different content must produce different skip markers")
    }
}
