import XCTest
@testable import Surfaces

/// Tests the seam between persisted terminal history chunks and the
/// replay payload that is fed into the Ghostty terminal emulator on restore.
///
/// The pure `assembleReplayPayload(from:)` helper is tested here because it
/// is the only logic path that can be exercised without a live Ghostty surface,
/// AppKit window, or PTY. The full wiring (historyRepo.readWindow → payload →
/// resetSurfaceOutput) requires a real window server and is verified manually
/// (see manual verification plan below).
final class TerminalHistoryRestoreTests: XCTestCase {

    // MARK: - assembleReplayPayload

    func test_assembleReplayPayload_joinsChunksInOrder() {
        // Chunks must arrive in original write order so the terminal emulator
        // replays the ANSI byte stream intact; wrong order produces garbled output.
        let chunks: [Data] = [
            Data("first ".utf8),
            Data("second ".utf8),
            Data("third".utf8),
        ]

        let payload = TerminalSurface.assembleReplayPayload(from: chunks)

        XCTAssertEqual(payload, Data("first second third".utf8),
                       "restored history must replay bytes in the exact write order so the terminal emulator sees the same stream the user originally produced")
    }

    func test_assembleReplayPayload_singleChunkPassesThrough() {
        let chunks: [Data] = [Data("hello\r\n".utf8)]

        let payload = TerminalSurface.assembleReplayPayload(from: chunks)

        XCTAssertEqual(payload, Data("hello\r\n".utf8),
                       "a single persisted chunk must be passed through unchanged to the terminal emulator")
    }

    func test_assembleReplayPayload_emptyChunkListProducesEmptyPayload() {
        let payload = TerminalSurface.assembleReplayPayload(from: [])

        XCTAssertTrue(payload.isEmpty,
                      "an empty history must produce an empty payload so the caller can skip calling resetSurfaceOutput and avoid needlessly resetting a live surface")
    }

    func test_assembleReplayPayload_preservesRawBinaryBytes() {
        // Terminal history includes raw ANSI escape sequences and binary PTY output
        // that must not be altered during reassembly.
        let ansiClear = Data([0x1B, 0x5B, 0x48,  // ESC[H  (cursor home)
                              0x1B, 0x5B, 0x32, 0x4A]) // ESC[2J (clear screen)
        let prompt    = Data("$ ".utf8)
        let chunks    = [ansiClear, prompt]

        let payload = TerminalSurface.assembleReplayPayload(from: chunks)

        XCTAssertEqual(payload, ansiClear + prompt,
                       "ANSI escape bytes must survive chunk reassembly unmodified so the Ghostty renderer produces an identical screen state to the original session")
    }

    func test_assembleReplayPayload_largeChunkCountProducesCorrectByteCount() {
        // Guard against off-by-one errors when concatenating many small chunks
        // (common during high-throughput terminal sessions that flush every 64 KB).
        let chunkCount = 200
        let chunkSize  = 100
        let singleChunk = Data(repeating: 0x41 /* 'A' */, count: chunkSize)
        let chunks = Array(repeating: singleChunk, count: chunkCount)

        let payload = TerminalSurface.assembleReplayPayload(from: chunks)

        XCTAssertEqual(payload.count, chunkCount * chunkSize,
                       "all \(chunkCount) chunks × \(chunkSize) bytes must be present in the reassembled payload; any byte drop makes the restored terminal show a truncated session")
    }
}

// MARK: - Manual Verification Plan
//
// The end-to-end wiring (historyRepo.readWindow → assembleReplayPayload →
// ghosttyView.resetSurfaceOutput) is tested manually because it requires a
// live Ghostty surface, AppKit window server, and SQLite-backed persistence:
//
// 1. Launch the macOS app with a workspace that has at least one terminal pane.
// 2. Run a command that produces visible output, e.g. `echo "session-marker-XYZ"`.
// 3. Quit the app (Cmd+Q) — this flushes history via flushPersistedHistory().
// 4. Relaunch the app — reinstantiateRestoredSurfaces() recreates the terminal
//    with restoredSurfaceID + historyRepo, setting needsHistoryReplay = true.
// 5. When the pane's container view receives its window (handleContainerWindowChanged),
//    replayPersistedHistoryIfNeeded() fires, reads chunks from historyRepo on
//    historyQueue, and calls ghosttyView.resetSurfaceOutput(payload) on main.
// 6. Expected: the restored terminal pane shows "session-marker-XYZ" in the
//    viewport immediately on reveal, without any user input.
// 7. Negative case: close the pane before quitting — the restored terminal should
//    start blank because historyRepo has no chunks for the new surface ID.
