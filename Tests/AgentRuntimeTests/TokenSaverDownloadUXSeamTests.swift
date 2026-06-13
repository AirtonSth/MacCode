import XCTest
@testable import AgentRuntime

/// Unit tests for the four pure aggregate-download-UX seams added to
/// TokenSaverModelInstaller: totalSizeFromBlobs, hasSufficientDiskSpace,
/// downloadSpeed, and eta.
///
/// WHY a separate file: the chunk-seam tests (TokenSaverDownloadChunkSeamTests)
/// already own the I/O-path invariants. These tests own the pure-arithmetic
/// seams that the UX layer (progress %, speed display, disk-space gate) depends
/// on. Keeping them separate makes failures easy to bisect.
final class TokenSaverDownloadUXSeamTests: XCTestCase {

    // MARK: - totalSizeFromBlobs

    func test_totalSizeFromBlobs_topLevelArray_sumsAllSizes() throws {
        // WHY: HF ?blobs=true returns a top-level JSON array; summing the `size`
        // fields gives the aggregate download size before any byte is fetched,
        // enabling an accurate progress bar from the very first callback.
        let json = """
        [{"rfilename":"weights.bin","size":900000},{"rfilename":"config.json","size":1024}]
        """.data(using: .utf8)!
        XCTAssertEqual(TokenSaverModelInstaller.totalSizeFromBlobs(json), 901_024)
    }

    func test_totalSizeFromBlobs_siblingsKey_sumsAllSizes() throws {
        // WHY: when ?blobs=true is appended to the full model URL, HF may return
        // the model object with a `siblings` array containing size fields; the
        // seam must handle both shapes so callers need not pre-parse the response.
        let json = """
        {"id":"samuelfaj/distill-1.7B-4bit-MLX","sha":"abc","siblings":[{"rfilename":"a.bin","size":500000},{"rfilename":"b.bin","size":250000}]}
        """.data(using: .utf8)!
        XCTAssertEqual(TokenSaverModelInstaller.totalSizeFromBlobs(json), 750_000)
    }

    func test_totalSizeFromBlobs_missingSizeFields_returnsNil() throws {
        // WHY: if the API response omits `size` on every entry (e.g. old API
        // version without ?blobs=true), returning nil lets callers fall back to
        // the static estimate rather than showing a bogus 0 B total.
        let json = """
        [{"rfilename":"weights.bin"},{"rfilename":"config.json"}]
        """.data(using: .utf8)!
        XCTAssertNil(TokenSaverModelInstaller.totalSizeFromBlobs(json))
    }

    func test_totalSizeFromBlobs_emptyArray_returnsNil() throws {
        // WHY: an empty file list means the model has no blobs; the caller must
        // not show "0 B total" as a progress denominator — nil signals fallback.
        let json = "[]".data(using: .utf8)!
        XCTAssertNil(TokenSaverModelInstaller.totalSizeFromBlobs(json))
    }

    func test_totalSizeFromBlobs_invalidJSON_returnsNil() throws {
        // WHY: a network error or truncated response must not crash the installer;
        // returning nil lets the download proceed with the static estimate.
        let json = "not json at all".data(using: .utf8)!
        XCTAssertNil(TokenSaverModelInstaller.totalSizeFromBlobs(json))
    }

    func test_totalSizeFromBlobs_partialSizeFields_sumsOnlyPresent() throws {
        // WHY: some entries may have a size (e.g. LFS blobs) while others do not
        // (e.g. text files inlined by the API). The seam must sum only the known
        // sizes and still return a useful total rather than nil.
        let json = """
        [{"rfilename":"weights.bin","size":1000000},{"rfilename":"README.md"}]
        """.data(using: .utf8)!
        XCTAssertEqual(TokenSaverModelInstaller.totalSizeFromBlobs(json), 1_000_000)
    }

    func test_totalSizeFromBlobs_singleFile_returnsItsSize() throws {
        // WHY: a model with a single shard must produce a non-nil total so that
        // the first-file progress bar shows a meaningful denominator.
        let json = """
        [{"rfilename":"model.safetensors","size":1100000000}]
        """.data(using: .utf8)!
        XCTAssertEqual(TokenSaverModelInstaller.totalSizeFromBlobs(json), 1_100_000_000)
    }

    // MARK: - hasSufficientDiskSpace

    func test_hasSufficientDiskSpace_exactlyEnough_returnsTrue() {
        // WHY: free == required + margin is the boundary; the download must be
        // allowed here. An off-by-one that blocks a valid download wastes the
        // user's time on a false-negative gate.
        let required: Int64 = 1_100_000_000
        let free = required + TokenSaverModelInstaller.diskSpaceMarginBytes
        XCTAssertTrue(TokenSaverModelInstaller.hasSufficientDiskSpace(required: required, free: free))
    }

    func test_hasSufficientDiskSpace_oneByteShort_returnsFalse() {
        // WHY: a disk with one byte less than required+margin must be blocked;
        // proceeding would risk a failed partial write and a corrupt model.
        let required: Int64 = 1_100_000_000
        let free = required + TokenSaverModelInstaller.diskSpaceMarginBytes - 1
        XCTAssertFalse(TokenSaverModelInstaller.hasSufficientDiskSpace(required: required, free: free))
    }

    func test_hasSufficientDiskSpace_plentyOfSpace_returnsTrue() {
        // WHY: typical Mac with 50 GB free must pass the gate for a 1.1 GB model;
        // the margin must not be so large that it blocks users with adequate space.
        XCTAssertTrue(TokenSaverModelInstaller.hasSufficientDiskSpace(
            required: 1_100_000_000, free: 50_000_000_000))
    }

    func test_hasSufficientDiskSpace_zeroDiskSpace_returnsFalse() {
        // WHY: zero free bytes is always insufficient; the guard must not
        // produce unexpected results when FileManager returns 0.
        XCTAssertFalse(TokenSaverModelInstaller.hasSufficientDiskSpace(
            required: 1_000_000, free: 0))
    }

    func test_hasSufficientDiskSpace_zeroRequired_marginStillApplies() {
        // WHY: even a zero-byte model must leave the margin free to absorb the
        // manifest write; a disk with 0 free bytes must still fail.
        XCTAssertFalse(TokenSaverModelInstaller.hasSufficientDiskSpace(required: 0, free: 0))
        XCTAssertTrue(TokenSaverModelInstaller.hasSufficientDiskSpace(
            required: 0, free: TokenSaverModelInstaller.diskSpaceMarginBytes))
    }

    func test_diskSpaceMarginBytes_isAtLeast100MB() {
        // WHY: the margin must be large enough to absorb the partial-download file
        // and post-download manifest+cache write. 100 MB is the absolute minimum.
        XCTAssertGreaterThanOrEqual(
            TokenSaverModelInstaller.diskSpaceMarginBytes, 100_000_000,
            "margin must be >= 100 MB to absorb partial files and manifest writes")
    }

    // MARK: - downloadSpeed

    func test_downloadSpeed_normalSample_returnsCorrectRate() {
        // WHY: 10 MB transferred in 2 s should report 5 MB/s; any deviation means
        // the speed display misleads the user about remaining time.
        let speed = TokenSaverModelInstaller.downloadSpeed(
            bytesDelta: 10_000_000, secondsDelta: 2.0)
        XCTAssertEqual(speed, 5_000_000.0, accuracy: 1.0)
    }

    func test_downloadSpeed_zeroElapsed_returnsZero() {
        // WHY: if the two speed samples are taken at the same instant (clock
        // granularity or frozen monotonic clock), division by zero must be
        // suppressed; the caller shows "-- MB/s" instead of NaN/inf.
        let speed = TokenSaverModelInstaller.downloadSpeed(bytesDelta: 1_000_000, secondsDelta: 0)
        XCTAssertEqual(speed, 0)
    }

    func test_downloadSpeed_negativeElapsed_returnsZero() {
        // WHY: monotonic clock skew or a VM migration can produce a negative
        // elapsed interval; a negative speed is physically meaningless and must
        // not propagate to the ETA calculation.
        let speed = TokenSaverModelInstaller.downloadSpeed(bytesDelta: 1_000_000, secondsDelta: -1.0)
        XCTAssertEqual(speed, 0)
    }

    func test_downloadSpeed_negativeDelta_returnsZero() {
        // WHY: a bytesDelta < 0 would indicate the download went backward (e.g.
        // a file restart was misaccounted); negative speed must not propagate.
        let speed = TokenSaverModelInstaller.downloadSpeed(bytesDelta: -500, secondsDelta: 1.0)
        XCTAssertEqual(speed, 0)
    }

    func test_downloadSpeed_zeroBytesPositiveElapsed_returnsZero() {
        // WHY: a progress callback fired but no bytes moved (e.g. a stall before
        // the server begins sending data); speed must be 0, not NaN.
        let speed = TokenSaverModelInstaller.downloadSpeed(bytesDelta: 0, secondsDelta: 5.0)
        XCTAssertEqual(speed, 0)
    }

    func test_downloadSpeed_resultIsFinite() {
        // WHY: the ETA seam passes speed through Double arithmetic; a NaN or inf
        // speed propagates to the UI label and produces "nan s remaining".
        let speed = TokenSaverModelInstaller.downloadSpeed(bytesDelta: 9_999_999, secondsDelta: 3.7)
        XCTAssertTrue(speed.isFinite, "downloadSpeed must never return NaN or inf")
        XCTAssertGreaterThan(speed, 0)
    }

    // MARK: - eta

    func test_eta_normalCase_returnsCorrectSeconds() {
        // WHY: 50 MB remaining at 10 MB/s -> 5 s; if eta returns a wrong value
        // the user's displayed "time remaining" is wrong and erodes trust.
        let result = TokenSaverModelInstaller.eta(remaining: 50_000_000, speed: 10_000_000)
        XCTAssertEqual(result, 5)
    }

    func test_eta_zeroSpeed_returnsNil() {
        // WHY: speed == 0 means we cannot estimate; returning nil lets callers
        // hide the ETA label rather than showing "inf s remaining".
        let result = TokenSaverModelInstaller.eta(remaining: 1_000_000, speed: 0)
        XCTAssertNil(result, "ETA must be nil when speed is zero to avoid divide-by-zero")
    }

    func test_eta_negativeSpeed_returnsNil() {
        // WHY: a negative speed (clock skew) is physically meaningless; nil
        // prevents a negative countdown from being shown to the user.
        let result = TokenSaverModelInstaller.eta(remaining: 1_000_000, speed: -1_000)
        XCTAssertNil(result)
    }

    func test_eta_zeroRemaining_returnsZero() {
        // WHY: download complete — the ETA is 0 s, not nil. Callers display "0s"
        // or hide the label; returning nil here would cause a flicker where the
        // ETA disappears one callback before the "Done" state arrives.
        let result = TokenSaverModelInstaller.eta(remaining: 0, speed: 5_000_000)
        XCTAssertEqual(result, 0)
    }

    func test_eta_negativeRemaining_returnsZero() {
        // WHY: remaining < 0 can happen when the pre-fetch size estimate was low
        // and more bytes were actually downloaded; treat as complete (0) not error.
        let result = TokenSaverModelInstaller.eta(remaining: -100, speed: 5_000_000)
        XCTAssertEqual(result, 0)
    }

    func test_eta_smallRemainder_roundsToZero() {
        // WHY: 0.4 s rounds to 0 — the user sees "0s" which is correct at human
        // perception granularity. A negative rounding (-1) would be confusing.
        let result = TokenSaverModelInstaller.eta(remaining: 2, speed: 5)  // 0.4 s
        XCTAssertEqual(result, 0)
    }

    func test_eta_largeRemainder_doesNotOverflow() {
        // WHY: a slow connection (1 B/s) with a 1 GB remaining must not overflow
        // Int. The result (~1e9 seconds) is unrealistic but must be finite.
        let result = TokenSaverModelInstaller.eta(remaining: 1_000_000_000, speed: 1)
        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result!, 0)
    }

    func test_eta_resultIsNonNegativeWhenNonNil() {
        // WHY: a negative ETA displayed as "-3s remaining" is a confusing
        // regression; every non-nil return value must be >= 0.
        let cases: [(Int64, Double)] = [
            (100, 7.3), (1, 0.001), (999_999, 123.4), (1, 1_000_000)
        ]
        for (remaining, speed) in cases {
            if let result = TokenSaverModelInstaller.eta(remaining: remaining, speed: speed) {
                XCTAssertGreaterThanOrEqual(result, 0,
                    "eta must be >= 0 for remaining=\(remaining) speed=\(speed)")
            }
        }
    }

    // MARK: - approvedModelBlobsURL

    func test_approvedModelBlobsURL_containsBlobsQueryParam() {
        // WHY: the URL must have ?blobs=true so HF embeds size in each sibling;
        // without it the API omits sizes and totalSizeFromBlobs returns nil.
        let url = TokenSaverModelInstaller.approvedModelBlobsURL
        XCTAssertTrue(
            url.absoluteString.contains("blobs=true"),
            "blobsURL must contain ?blobs=true so HF returns per-file sizes")
    }

    func test_approvedModelBlobsURL_containsApprovedModelID() {
        // WHY: the URL must reference the approved model ID; a wrong model ID
        // would fetch blob sizes for a different model and produce a bogus total.
        let url = TokenSaverModelInstaller.approvedModelBlobsURL
        XCTAssertTrue(
            url.absoluteString.contains(TokenSaverModelManifest.approvedModelID),
            "blobsURL must contain the approved model ID")
    }
}
