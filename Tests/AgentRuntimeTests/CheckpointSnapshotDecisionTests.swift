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

    func test_checkpointSnapshotByteCap_isOneMebibyte() {
        XCTAssertEqual(
            AgentRunCoordinator.checkpointSnapshotByteCap, 1 << 20,
            "checkpoint snapshots stay at 1 MiB; raising it reintroduces large Data rows"
        )
    }

    // CKPT-READ: FileHandle.read(upToCount: cap+1) so a 20 MiB file never
    // becomes full-file Data. The skip marker hashes the prefix, not the rest.
    func test_readCheckpointSnapshotPrefix_oversizedFile_readsCapPlusOneAndHashesPrefix() throws {
        let cap = 32
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-ckpt-prefix-\(UUID().uuidString).txt")
        let payload = Data(repeating: 0x41, count: 256)
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let prefix = try XCTUnwrap(
            AgentRunCoordinator.readCheckpointSnapshotPrefix(from: url, cap: cap)
        )
        XCTAssertEqual(
            prefix.count, cap + 1,
            "must stop at cap+1 so the rest of the file never becomes Data"
        )
        XCTAssertEqual(prefix, payload.prefix(cap + 1))

        let decision = AgentRunCoordinator.checkpointSnapshotDecision(
            byteCount: prefix.count,
            isBinary: AgentRunCoordinator.dataLooksBinary(prefix),
            cap: cap,
            hash: { AgentRunCoordinator.sha256Hex(prefix) }
        )
        XCTAssertEqual(decision, .skipMarker(hash: hex(prefix)))
        XCTAssertNotEqual(
            hex(prefix), hex(payload),
            "skip hash must be the FileHandle prefix, not SHA-256 of the full file"
        )
    }

    func test_readCheckpointSnapshotPrefix_atCap_returnsWholeFileForSnapshot() throws {
        let cap = 48
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-ckpt-atcap-\(UUID().uuidString).txt")
        let payload = Data(repeating: 0x42, count: cap)
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let prefix = try XCTUnwrap(
            AgentRunCoordinator.readCheckpointSnapshotPrefix(from: url, cap: cap)
        )
        XCTAssertEqual(prefix, payload, "a file at the cap must still snapshot in full")
        let decision = AgentRunCoordinator.checkpointSnapshotDecision(
            byteCount: prefix.count,
            isBinary: false,
            cap: cap,
            hash: { XCTFail("hash must not run when snapshotting"); return "" }
        )
        XCTAssertEqual(decision, .snapshot)
    }

    func test_captureFileSnapshots_usesPrefixReadNotWholeFileData() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let marker = try XCTUnwrap(source.range(of: "private func captureFileSnapshots"))
        let rest = source[marker.lowerBound...]
        let end = rest.range(of: "\n    enum CheckpointSnapshotDecision")?.lowerBound ?? rest.endIndex
        let chunk = String(source[marker.lowerBound..<end])
        XCTAssertFalse(
            chunk.contains("Data(contentsOf: URL") || chunk.contains("Data(contentsOf: url"),
            "captureFileSnapshots must not load the whole file into Data"
        )
        XCTAssertTrue(
            chunk.contains("readCheckpointSnapshotPrefix"),
            "captureFileSnapshots must FileHandle-prefix at cap+1"
        )
    }

    // MARK: - CKPT-BUDGET: per-checkpoint total snapshot budget

    /// Replays the capture loop's exact fold: per-file decision + running
    /// budget decremented only by snapshotted bytes.
    private func replay(
        _ entries: [(bytes: Int, binary: Bool)],
        cap: Int = AgentRunCoordinator.checkpointSnapshotByteCap,
        total: Int = AgentRunCoordinator.checkpointSnapshotTotalByteCap
    ) -> (decisions: [AgentRunCoordinator.CheckpointSnapshotDecision], storedBytes: Int, remaining: Int) {
        var remaining = total
        var stored = 0
        var decisions: [AgentRunCoordinator.CheckpointSnapshotDecision] = []
        for entry in entries {
            let decision = AgentRunCoordinator.checkpointSnapshotBudgetDecision(
                byteCount: entry.bytes,
                isBinary: entry.binary,
                remainingBudget: remaining,
                cap: cap,
                hash: { "hash-\(entry.bytes)" }
            )
            if decision == .snapshot { remaining -= entry.bytes; stored += entry.bytes }
            decisions.append(decision)
        }
        return (decisions, stored, remaining)
    }

    // WHY: the per-file cap alone bounded each file, not the turn. A turn that
    // rewrites many at-cap text files wrote a multi-MiB row every time; the
    // checkpoint table is the largest in the owner's live store (176 MB of
    // file_snapshots_json) and 66 rows over 500 KB held 66% of it.
    func test_manyAtCapFiles_stayWithinCheckpointTotalBudget() {
        let cap = 1 << 20
        let total = 1 << 20
        let entries = Array(repeating: (bytes: cap, binary: false), count: 12)
        let result = replay(entries, cap: cap, total: total)
        XCTAssertEqual(result.storedBytes, total, "12 at-cap files must not store 12 MiB")
        XCTAssertLessThanOrEqual(result.remaining, 0, "budget must be spent, not overrun")
        XCTAssertEqual(result.decisions.first, .snapshot, "the first file still snapshots exactly")
        XCTAssertEqual(
            result.decisions.filter { if case .skipMarker = $0 { return true } else { return false } }.count,
            11,
            "the remaining 11 files take the nil-content marker path"
        )
    }

    // WHY: a rejected large file must not end the turn's snapshots -- smaller
    // files after it still fit the leftover budget and keep exact restore.
    func test_laterSmallFileStillSnapshotsAfterLargeFileIsRejected() {
        let result = replay(
            [(bytes: 800, binary: false), (bytes: 300, binary: false), (bytes: 100, binary: false)],
            cap: 1 << 20,
            total: 1_000
        )
        XCTAssertEqual(result.decisions[0], .snapshot)
        XCTAssertEqual(result.decisions[1], .skipMarker(hash: "hash-300"))
        XCTAssertEqual(result.decisions[2], .snapshot, "100 bytes still fit the 200 left")
        XCTAssertEqual(result.storedBytes, 900)
        XCTAssertEqual(result.remaining, 100)
    }

    // Boundary is inclusive, matching the per-file cap: a file that needs
    // exactly the remaining budget is snapshotted, and the next byte is not.
    func test_fileExactlyAtRemainingBudget_snapshotsThenExhausts() {
        let cap = 1 << 20
        let result = replay([(bytes: 500, binary: false), (bytes: 1, binary: false)], cap: cap, total: 500)
        XCTAssertEqual(result.decisions[0], .snapshot)
        XCTAssertEqual(result.remaining, 0)
        XCTAssertEqual(result.decisions[1], .skipMarker(hash: "hash-1"))
    }

    // WHY: the budget must only remove bytes, never re-admit what the P2 rule
    // already refuses -- binary and oversized files skip for their own reason.
    func test_budgetNeverReAdmitsBinaryOrOversizedFiles() {
        let cap = 64
        let result = replay(
            [(bytes: 16, binary: true), (bytes: cap + 1, binary: false), (bytes: 16, binary: false)],
            cap: cap,
            total: 1 << 20
        )
        XCTAssertEqual(result.decisions[0], .skipMarker(hash: "hash-16"))
        XCTAssertEqual(result.decisions[1], .skipMarker(hash: "hash-\(cap + 1)"))
        XCTAssertEqual(result.decisions[2], .snapshot)
        XCTAssertEqual(result.storedBytes, 16)
    }

    // WHY: normal turns (median checkpoint is <10 KB of changed text) must be
    // untouched; the budget exists for the tail, not to shrink ordinary turns.
    func test_smallCheckpointWithManyFiles_isUnaffectedByBudget() {
        let result = replay(Array(repeating: (bytes: 4_096, binary: false), count: 40))
        XCTAssertEqual(result.decisions.filter { $0 == .snapshot }.count, 40)
        XCTAssertEqual(result.remaining, (1 << 20) - 40 * 4_096)
    }

    func test_checkpointSnapshotTotalByteCap_isOneMebibyte() {
        XCTAssertEqual(
            AgentRunCoordinator.checkpointSnapshotTotalByteCap, 1 << 20,
            "one checkpoint stores at most 1 MiB of snapshot bytes; raising it reintroduces multi-MiB rows"
        )
    }

    // The capture loop must run the budgeted decision and charge the budget, or
    // the cap above is a constant nothing enforces.
    func test_captureFileSnapshots_chargesTheCheckpointBudget() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let marker = try XCTUnwrap(source.range(of: "private func captureFileSnapshots"))
        let rest = source[marker.lowerBound...]
        let end = rest.range(of: "\n    /// P2: per-file checkpoint snapshot decision")?.lowerBound ?? rest.endIndex
        let chunk = String(source[marker.lowerBound..<end])
        XCTAssertTrue(
            chunk.contains("var remainingBudget = Self.checkpointSnapshotTotalByteCap"),
            "captureFileSnapshots must start each checkpoint from the total budget"
        )
        XCTAssertTrue(
            chunk.contains("remainingBudget -= data.count"),
            "snapshotted bytes must be charged against the checkpoint budget"
        )
        XCTAssertTrue(
            chunk.contains("checkpointSnapshotBudgetDecision"),
            "captureFileSnapshots must use the budgeted decision"
        )
    }
}
