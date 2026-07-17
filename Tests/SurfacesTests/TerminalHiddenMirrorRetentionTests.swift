import Persistence
import XCTest
@testable import CoreModel
@testable import Surfaces

/// Proves the pre-gate memory mechanism without claiming live RSS soak PASS:
/// continuous hidden producers must not pin a permanent raw copy of all
/// accepted mirror bytes (up to 4 MiB per terminal) for the whole hidden
/// lifetime. The mirror path force-flushes into the capped ANSI ring, while
/// history + outputBus remain the authoritative full-byte paths.
@MainActor
final class TerminalHiddenMirrorRetentionTests: XCTestCase {
    func test_continuousHiddenOutputDoesNotPinRawBytesLinearlyWithAcceptedVolume() throws {
        // WHY: pre-gate RSS slope failed with 12 terminals (most hidden) while
        // max pending stayed flat at the flood watermark. Each hidden stream was
        // growing `hiddenRendererBuffer` toward 4 MiB for ~55 minutes — dual
        // retention beside Ghostty — so the 15-minute gate never saw a plateau.
        // This test only proves the local retention bound; it is not an RSS soak.
        let bus = SurfaceOutputBus(flushDelay: 0)
        let busLock = NSLock()
        var busBytes = 0
        bus.sink = { frame in
            busLock.lock()
            busBytes += frame.data.count
            busLock.unlock()
        }
        try waitUntilSinkInstalled(bus)

        let database = try SQLiteDB(path: ":memory:")
        try Schema.migrate(database)
        let repository = TerminalOutputRepository(db: database)
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "hidden mirror retention",
            launch: .sshPlaceholder(cwd: NSTemporaryDirectory()),
            historyRepo: repository,
            outputBus: bus
        )
        defer { surface.close() }

        try waitForHistoryPreparationReady(surface)
        surface.didBecomeHidden()
        XCTAssertFalse(surface.readerAllowsRenderForTesting)

        // Drop any constructor/bus/history baseline before measuring inject volume.
        bus.flushNow(surface.descriptor.id)
        busLock.lock()
        busBytes = 0
        busLock.unlock()
        surface.flushPersistedHistory()
        try waitForHistoryDrain(surface)
        let historyBaselineBytes = try repository.readWindow(
            surfaceID: surface.descriptor.id.value.uuidString,
            maxBytes: 1024 * 1024
        ).chunks.reduce(0) { $0 + $1.data.count }

        // 8 MiB of 1 MiB chunks: few events, so the byte cap (not event cap)
        // triggers force-flush under the fixed path. Old path pinned 4 MiB raw.
        // Flush history after each chunk so the 4 MiB history outstanding cap
        // does not discard bytes — history remains the durable full-byte path.
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 1024 * 1024)
        let chunkCount = 8
        let expectedTotal = chunk.count * chunkCount
        for _ in 0..<chunkCount {
            surface.injectReaderOutputForTesting(chunk)
            surface.flushPersistedHistory()
            try waitForHistoryDrain(surface)
        }
        let accepted = surface.hiddenMirrorAcceptedBytesForTesting
        let retainedRaw = surface.hiddenMirrorRetainedRawBytesForTesting

        XCTAssertEqual(
            accepted,
            expectedTotal,
            "accepted-byte accounting must track every hidden chunk for the 4 MiB recoverability budget"
        )
        XCTAssertTrue(
            surface.hiddenRendererBufferOverflowedForTesting,
            "crossing the 4 MiB recoverability budget must latch overflow for partial truth"
        )
        XCTAssertTrue(
            surface.runtimeHealth().outputPartial,
            "health must report output_partial once the hidden recoverability budget is exceeded"
        )
        // Ghostty / history / mirror may latch different first reasons under dense
        // inject; all are honest partial — never a silent complete snapshot.
        let partialReason = surface.runtimeHealth().outputPartialReason
        XCTAssertNotNil(partialReason, "overflowed hidden output must publish a partial reason")
        XCTAssertNotEqual(partialReason, "", "partial reason must be non-empty")

        // After inclusive force-flush at 4 MiB boundaries, raw pending/heal
        // retention must not scale with accepted volume (old code kept ~4 MiB).
        XCTAssertLessThan(
            retainedRaw,
            512 * 1024,
            "continuous hidden output must force-flush into the capped ANSI ring instead of pinning up to 4 MiB raw for the whole hidden session; retainedRaw=\(retainedRaw) accepted=\(accepted)"
        )
        XCTAssertLessThan(
            retainedRaw,
            accepted / 8,
            "retained raw mirror bytes must not scale with total accepted volume after the pending flush threshold"
        )
        // 1 MiB-aligned total that is a multiple of the 4 MiB force-flush
        // threshold must leave the pending queue empty after the last flush.
        XCTAssertEqual(
            retainedRaw,
            0,
            "after 1 MiB-aligned force-flush at a 4 MiB boundary, pending/heal raw retention must be empty; retainedRaw=\(retainedRaw)"
        )

        bus.flushNow(surface.descriptor.id)
        busLock.lock()
        let observedBusBytes = busBytes
        busLock.unlock()
        XCTAssertEqual(
            observedBusBytes,
            expectedTotal,
            "outputBus must receive every injected PTY byte even when the ANSI mirror force-flushes and marks partial"
        )

        let persisted = try repository.readWindow(
            surfaceID: surface.descriptor.id.value.uuidString,
            maxBytes: expectedTotal + historyBaselineBytes + 64 * 1024
        )
        let persistedBytes = persisted.chunks.reduce(0) { $0 + $1.data.count }
        XCTAssertEqual(
            persistedBytes - historyBaselineBytes,
            expectedTotal,
            "history persistence is the authoritative full-byte path; every injected byte must be enqueued/flushed (baseline=\(historyBaselineBytes) total=\(persistedBytes))"
        )

        // Transcript remains readable while still hidden (soak aux READY path).
        let snap = surface.readTextSnapshot()
        XCTAssertEqual(snap.source, "ansi_fallback")
        XCTAssertFalse(snap.text.isEmpty, "force-flushed ANSI mirror must remain readable while hidden")
        XCTAssertFalse(snap.complete, "overflowed hidden snapshot must stay incomplete")
        // ANSI ring may drop early lines under dense output; partial must stay true
        // so callers do not treat the truncated renderer view as full truth.
        XCTAssertTrue(
            surface.runtimeHealth().outputPartial,
            "if the capped ANSI ring drops older lines, partial truth must remain latched"
        )
    }

    func test_hiddenOverflowStillPartialAfterRevealWithoutDoubleFeed() throws {
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "hidden overflow reveal",
            launch: .sshPlaceholder(cwd: NSTemporaryDirectory())
        )
        defer { surface.close() }

        surface.didBecomeHidden()
        let marker = "RC2_HIDDEN_TAIL_MARKER"
        let prefix = Data(repeating: UInt8(ascii: "y"), count: 4 * 1024 * 1024 + 64 * 1024)
        surface.injectReaderOutputForTesting(prefix)
        surface.injectReaderOutputForTesting(Data("\(marker)\n".utf8))

        XCTAssertTrue(surface.hiddenRendererBufferOverflowedForTesting)
        surface.didBecomeVisible()
        XCTAssertTrue(
            surface.runtimeHealth().outputPartial,
            "reveal must preserve hidden_output_cap partial after recoverability overflow"
        )
        XCTAssertEqual(
            surface.hiddenMirrorAcceptedBytesForTesting,
            0,
            "accepted-byte budget must reset on reveal so a later hide session cannot inherit a false partial"
        )
        let after = surface.readTextSnapshot()
        XCTAssertTrue(
            after.text.contains(marker),
            "newest hidden bytes must survive force-flush into the ANSI ring (not only the first 4 MiB prefix)"
        )
        let occurrences = after.text.components(separatedBy: marker).count - 1
        XCTAssertEqual(occurrences, 1, "reveal must not double-feed already-flushed hidden mirror bytes")
    }

    func test_hiddenMirrorAcceptedBytesResetsAcrossHideSessionsWithoutFalsePartial() throws {
        // WHY: cumulative accepted-byte accounting must be per hidden period.
        // Carrying it across hide/show would latch hidden_output_cap on a fresh
        // session that never exceeded the recoverability budget.
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "hidden accepted reset",
            launch: .sshPlaceholder(cwd: NSTemporaryDirectory())
        )
        defer { surface.close() }

        surface.didBecomeHidden()
        let underBudget = Data(repeating: UInt8(ascii: "a"), count: 1024 * 1024)
        surface.injectReaderOutputForTesting(underBudget)
        XCTAssertEqual(surface.hiddenMirrorAcceptedBytesForTesting, underBudget.count)
        XCTAssertFalse(surface.hiddenRendererBufferOverflowedForTesting)

        surface.didBecomeVisible()
        XCTAssertEqual(surface.hiddenMirrorAcceptedBytesForTesting, 0)

        surface.didBecomeHidden()
        XCTAssertEqual(
            surface.hiddenMirrorAcceptedBytesForTesting,
            0,
            "a new hidden period must start the recoverability budget at zero"
        )
        XCTAssertFalse(surface.hiddenRendererBufferOverflowedForTesting)
        surface.injectReaderOutputForTesting(underBudget)
        XCTAssertEqual(surface.hiddenMirrorAcceptedBytesForTesting, underBudget.count)
        XCTAssertFalse(
            surface.hiddenRendererBufferOverflowedForTesting,
            "a second under-budget hide session must not inherit overflow from prior accepted totals"
        )
        // Exact 4 MiB fills the budget without overflow (matches old inclusive fill).
        let restToExactCap = Data(
            repeating: UInt8(ascii: "b"),
            count: 3 * 1024 * 1024
        )
        surface.injectReaderOutputForTesting(restToExactCap)
        XCTAssertEqual(surface.hiddenMirrorAcceptedBytesForTesting, 4 * 1024 * 1024)
        XCTAssertFalse(
            surface.hiddenRendererBufferOverflowedForTesting,
            "exactly 4 MiB must remain recoverable without latching hidden_output_cap"
        )
        surface.injectReaderOutputForTesting(Data("x".utf8))
        XCTAssertTrue(
            surface.hiddenRendererBufferOverflowedForTesting,
            "the first byte past 4 MiB must latch honest partial"
        )
        XCTAssertTrue(
            surface.runtimeHealth().outputPartial,
            "crossing the recoverability budget must keep health partial"
        )
        // Ghostty may have already latched ghostty_buffer_cap under dense fill;
        // the overflow latch is the mirror recoverability signal under test.
        let reason = surface.runtimeHealth().outputPartialReason
        XCTAssertNotNil(reason)
    }

    func test_inclusivePendingCapForceFlushLeavesNoRawDualRetention() throws {
        // WHY: exclusive `>` left a permanent 4 MiB-1 (or post-chunk remainder)
        // raw pin under continuous producers. Inclusive flush must drain to zero
        // for aligned 1 MiB chunks at the recoverability budget.
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "inclusive force flush",
            launch: .sshPlaceholder(cwd: NSTemporaryDirectory())
        )
        defer { surface.close() }

        surface.didBecomeHidden()
        let chunk = Data(repeating: UInt8(ascii: "z"), count: 1024 * 1024)
        for _ in 0..<4 {
            surface.injectReaderOutputForTesting(chunk)
        }
        XCTAssertEqual(surface.hiddenMirrorAcceptedBytesForTesting, 4 * 1024 * 1024)
        XCTAssertEqual(
            surface.hiddenMirrorRetainedRawBytesForTesting,
            0,
            "inclusive 4 MiB force-flush must empty pending/heal raw retention"
        )
        XCTAssertFalse(surface.hiddenRendererBufferOverflowedForTesting)

        // Next under-threshold chunk may sit in pending until the next flush
        // boundary — that is bounded working memory, not dual 4 MiB retention.
        surface.injectReaderOutputForTesting(chunk)
        XCTAssertEqual(
            surface.hiddenMirrorRetainedRawBytesForTesting,
            chunk.count,
            "one under-threshold pending chunk is expected between force-flush boundaries"
        )
        XCTAssertTrue(surface.hiddenRendererBufferOverflowedForTesting)

        // Fill back to the next 4 MiB pending boundary and prove drain again.
        for _ in 0..<3 {
            surface.injectReaderOutputForTesting(chunk)
        }
        XCTAssertEqual(
            surface.hiddenMirrorRetainedRawBytesForTesting,
            0,
            "second inclusive 4 MiB force-flush must drain pending again"
        )
        XCTAssertLessThan(
            surface.hiddenMirrorRetainedRawBytesForTesting,
            512 * 1024,
            "pending must not re-accumulate a permanent raw dual buffer after repeated force-flushes"
        )
    }

    // MARK: - helpers

    private func waitUntilSinkInstalled(
        _ bus: SurfaceOutputBus,
        timeout: TimeInterval = 1
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while bus.sink == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        XCTAssertNotNil(bus.sink, "outputBus sink must be installed before inject")
        if bus.sink == nil {
            struct SinkTimeout: Error {}
            throw SinkTimeout()
        }
    }

    private func waitForHistoryPreparationReady(
        _ surface: TerminalSurface,
        timeout: TimeInterval = 2
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .ready = surface.historyPreparationStateForTesting {
                return
            }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        XCTFail("history preparation not ready: \(surface.historyPreparationStateForTesting)")
        struct PrepTimeout: Error {}
        throw PrepTimeout()
    }

    private func waitForHistoryDrain(
        _ surface: TerminalSurface,
        timeout: TimeInterval = 2
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if surface.historyOutstandingBytesForTesting == 0 {
                return
            }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        XCTFail(
            "history outstanding did not drain; remaining=\(surface.historyOutstandingBytesForTesting)"
        )
        struct DrainTimeout: Error {}
        throw DrainTimeout()
    }
}
