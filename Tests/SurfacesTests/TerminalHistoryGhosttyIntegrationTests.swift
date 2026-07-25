import AppKit
import XCTest

@testable import CoreModel
@testable import Persistence
@testable import Surfaces

/// Opt-in C13 gate: persisted replay races actual PTY output while a real
/// Ghostty surface is attached to a runtime-visible AppKit window.
@MainActor
final class TerminalHistoryGhosttyIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["RC2_ENABLE_GHOSTTY_IN_TESTS"] == "1" else {
            return
        }
        var activeDisplayCount: UInt32 = 0
        let displayStatus = CGGetActiveDisplayList(0, nil, &activeDisplayCount)
        guard displayStatus == .success, activeDisplayCount > 0 else {
            throw XCTSkip(
                "real Ghostty needs a WindowServer session with an active Quartz display; "
                    + "CGGetActiveDisplayList reported status=\(displayStatus.rawValue) count=\(activeDisplayCount)"
            )
        }
    }

    func testMountedResetRecreatesGhosttyImmediatelyAndShowsCanonicalBytes() throws {
        guard ProcessInfo.processInfo.environment["RC2_ENABLE_GHOSTTY_IN_TESTS"] == "1" else {
            throw XCTSkip("run with RC2_ENABLE_GHOSTTY_IN_TESTS=1 for the mounted reset gate")
        }

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let canonicalMarker = "RC2_GHOSTTY_MOUNTED_RESET_\(token)"
        let view = GhosttyTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view.ownerIsClosing = { false }
        let window = makeWindow(containing: view)
        defer {
            view.ownerIsClosing = { true }
            view.closeSurface(silent: true)
            window.orderOut(nil)
        }
        view.setOcclusion(visible: true)
        view.forceRefresh()
        view.processOutput(Data("seed\r\n".utf8))
        try waitUntil("the mounted fixture must create its initial real Ghostty surface") {
            view.hasLiveSurfaceForTesting
        }

        view.resetSurfaceOutput(Data("\(canonicalMarker)\r\n".utf8))

        XCTAssertTrue(
            view.hasLiveSurfaceForTesting,
            "mounted reset must recreate the C surface synchronously before any read or explicit refresh can mask the bug"
        )
        try waitUntil("canonical reset bytes must become visible without forceRefresh") {
            view.readViewportText()?.contains(canonicalMarker) == true
        }
    }

    func testLegacyReplayYieldsBetweenBoundedGhosttyChunks() throws {
        guard ProcessInfo.processInfo.environment["RC2_ENABLE_GHOSTTY_IN_TESTS"] == "1" else {
            throw XCTSkip("run with RC2_ENABLE_GHOSTTY_IN_TESTS=1 for the mounted reset gate")
        }

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let marker = "RC2_GHOSTTY_BOUNDED_REPLAY_\(token)"
        var legacyHistory = Data(repeating: UInt8(ascii: "x"), count: 256 * 1024)
        legacyHistory.append(Data("\r\n\(marker)\r\n".utf8))
        let view = GhosttyTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view.ownerIsClosing = { false }
        let window = makeWindow(containing: view)
        defer {
            view.ownerIsClosing = { true }
            view.closeSurface(silent: true)
            window.orderOut(nil)
        }
        view.setOcclusion(visible: true)
        view.forceRefresh()
        view.processOutput(Data("seed\r\n".utf8))
        try waitUntil("the mounted fixture must create its initial real Ghostty surface") {
            view.hasLiveSurfaceForTesting
        }

        view.resetSurfaceOutput(legacyHistory)
        XCTAssertTrue(view.historyReplayDrainInProgressForTesting)
        var mainRunLoopYielded = false
        var replayWasInProgressWhenMainRunLoopYielded = false
        DispatchQueue.main.async {
            replayWasInProgressWhenMainRunLoopYielded = view.historyReplayDrainInProgressForTesting
            mainRunLoopYielded = true
        }
        try waitUntil("legacy replay must yield MainActor before consuming the whole window") {
            mainRunLoopYielded
        }
        XCTAssertTrue(
            replayWasInProgressWhenMainRunLoopYielded,
            "a 256 KiB legacy window must take multiple bounded main-run-loop turns"
        )
        try waitUntil("bounded replay must eventually drain", timeout: 10) {
            !view.historyReplayDrainInProgressForTesting
        }
        try waitUntil("the newest useful scrollback must survive bounded replay") {
            view.readScrollbackText()?.contains(marker) == true
        }
    }

    func testReplayKeepsOneParserForActiveSGRAlternateScreenAndPrivateModes() throws {
        guard ProcessInfo.processInfo.environment["RC2_ENABLE_GHOSTTY_IN_TESTS"] == "1" else {
            throw XCTSkip("run with RC2_ENABLE_GHOSTTY_IN_TESTS=1 for the parser continuity gate")
        }

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let normalMarker = "RC2_NORMAL_\(token)"
        let altMarker = "RC2_ALT_\(token)"
        let continuation = "Z_CONTINUATION_\(token)"
        let view = GhosttyTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view.ownerIsClosing = { false }
        let window = makeWindow(containing: view)
        defer {
            view.ownerIsClosing = { true }
            view.closeSurface(silent: true)
            window.orderOut(nil)
        }
        view.setOcclusion(visible: true)
        view.forceRefresh()
        view.processOutput(Data("seed\r\n".utf8))
        try waitUntil("the mounted fixture must create its initial real Ghostty surface") {
            view.hasLiveSurfaceForTesting
        }

        var replay = Data(repeating: UInt8(ascii: "h"), count: 256 * 1024)
        replay.append(Data("\u{001B}[2J\u{001B}[H\(normalMarker)".utf8))
        // Set representative parser/session modes before entering the TUI. They
        // are not synthesized later: mouse, bracketed paste, focus, active SGR,
        // and DEC alternate-screen state all remain in this same C surface.
        replay.append(Data("\u{001B}[?1000h\u{001B}[?2004h\u{001B}[?1004h".utf8))
        replay.append(Data("\u{001B}[?1049h\u{001B}[H\u{001B}[31m\(altMarker)".utf8))
        let mirror = ANSIRenderer(rows: 30, cols: 120)
        mirror.showCursor = false
        mirror.feed(replay)

        XCTAssertTrue(view.resetSurfaceOutput(replay))
        XCTAssertTrue(view.historyReplayDrainInProgressForTesting)
        let creationCountAfterReset = view.surfaceCreationCountForTesting

        // No SGR is repeated here. A recreated/synthesized parser would render
        // this with defaults; the original parser must retain red as it drains.
        XCTAssertTrue(view.processOutput(Data(continuation.utf8)))
        mirror.feed(Data(continuation.utf8))
        let continuationCell = mirror.grid
            .flatMap { $0 }
            .first { $0.ch == "Z" }
        XCTAssertNotNil(continuationCell)
        XCTAssertNotEqual(continuationCell?.fg, ANSIRenderer.Cell.defaultFG)

        let exit = Data("\u{001B}[?1049l-AFTER".utf8)
        XCTAssertTrue(view.processOutput(exit))
        mirror.feed(exit)
        XCTAssertFalse(mirror.usesAlternateScreen)
        XCTAssertTrue(mirror.snapshot().string.contains("\(normalMarker)-AFTER"))

        try waitUntil("the byte-identical replay and continuation must drain", timeout: 10) {
            !view.historyReplayDrainInProgressForTesting
        }
        try waitUntil("real Ghostty must restore the saved normal screen on TUI exit", timeout: 10) {
            view.readScrollbackText()?.contains("\(normalMarker)-AFTER") == true
        }
        let ghostty = try XCTUnwrap(view.readScrollbackText())
        XCTAssertEqual(ghostty.ranges(of: normalMarker).count, 1)
        XCTAssertFalse(ghostty.contains(altMarker))
        XCTAssertFalse(ghostty.contains(continuation))
        XCTAssertEqual(
            view.surfaceCreationCountForTesting,
            creationCountAfterReset,
            "overflow handling must never recreate the parser and erase modes"
        )
        XCTAssertEqual(view.droppedOutputBytes, 0)
    }

    func testPTYProducerIsBackpressuredWhileReplayDrainsThenResumesWithoutStarvation() throws {
        guard ProcessInfo.processInfo.environment["RC2_ENABLE_GHOSTTY_IN_TESTS"] == "1" else {
            throw XCTSkip("run with RC2_ENABLE_GHOSTTY_IN_TESTS=1 for the PTY backpressure gate")
        }

        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ReplayPressure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let environment = ShellEnvironmentLease(zdotdir: testRoot.path)
        defer { environment.restore() }

        let armed = testRoot.appendingPathComponent("armed")
        let go = testRoot.appendingPathComponent("go")
        let started = testRoot.appendingPathComponent("started")
        let marker = "RC2_REPLAY_PRESSURE_DONE_\(UUID().uuidString)"
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "Ghostty replay pressure",
            launch: .shell(cwd: testRoot.path),
            outputBus: SurfaceOutputBus(flushDelay: 0)
        )
        let window = makeWindow(containing: surface.view)
        SurfaceRegistry.shared.register(surface)
        SurfaceRegistry.shared.setVisibleSurfaceIDs([surface.descriptor.id])
        defer {
            SurfaceRegistry.shared.setVisibleSurfaceIDs([])
            surface.close()
            SurfaceRegistry.shared.unregister(surface.descriptor.id)
            window.orderOut(nil)
        }

        try waitUntil("the pressure fixture must be renderable and reading its PTY") {
            surface.runtimeHealth().renderDiagnostics?.canRender == true
                && surface.readerConfiguredForTesting
                && surface.ghosttySurfaceCreationCountForTesting > 0
        }

        let command = "printf armed > '\(armed.path)'; while [ ! -f '\(go.path)' ]; do sleep 0.01; done; printf started > '\(started.path)'; /usr/bin/yes RC2_PRESSURE | /usr/bin/head -c 2097152; printf '\\n\(marker)\\n'\n"
        XCTAssertEqual(surface.sendTextStatus(command), .accepted)
        try waitUntil("the shell producer must arm before replay starts") {
            FileManager.default.fileExists(atPath: armed.path)
        }

        let creationCountBeforeReplay = surface.ghosttySurfaceCreationCountForTesting
        let replay = Data(repeating: UInt8(ascii: "h"), count: 3 * 1024 * 1024)
        surface.replayResetSurfaceOutputForTesting(replay)
        XCTAssertTrue(surface.ghosttyReplayInProgressForTesting)
        XCTAssertTrue(surface.readerPausedForHistoryReplayForTesting)
        try Data("go".utf8).write(to: go)
        try waitUntil("the faster producer must begin while the PTY reader is paused") {
            FileManager.default.fileExists(atPath: started.path)
        }
        XCTAssertTrue(
            surface.ghosttyReplayInProgressForTesting,
            "a 3 MiB replay must still be yielding when the producer starts"
        )
        XCTAssertTrue(surface.readerPausedForHistoryReplayForTesting)
        XCTAssertLessThanOrEqual(
            surface.ghosttyMaximumPendingOutputBytesForTesting,
            GhosttyTerminalView.maxPendingOutputBytes
        )

        try waitUntil("bounded replay must drain and release PTY backpressure", timeout: 20) {
            !surface.ghosttyReplayInProgressForTesting
                && !surface.readerPausedForHistoryReplayForTesting
        }
        try waitUntil("the previously blocked producer must reach its final marker", timeout: 20) {
            surface.ghosttyScrollbackTextForTesting?.contains(marker) == true
        }
        XCTAssertLessThanOrEqual(
            surface.ghosttyMaximumPendingOutputBytesForTesting,
            GhosttyTerminalView.maxPendingOutputBytes
        )
        XCTAssertEqual(
            surface.ghosttySurfaceCreationCountForTesting,
            creationCountBeforeReplay + 1,
            "sustained producer pressure must not reset the Ghostty parser"
        )
    }

    func testHiddenReparentReschedulesCurrentGenerationReplayWithoutFurtherStimulus() throws {
        guard ProcessInfo.processInfo.environment["RC2_ENABLE_GHOSTTY_IN_TESTS"] == "1" else {
            throw XCTSkip("run with RC2_ENABLE_GHOSTTY_IN_TESTS=1 for the hidden replay lifecycle gate")
        }

        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ReplayReparent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let environment = ShellEnvironmentLease(zdotdir: testRoot.path)
        defer { environment.restore() }
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "Ghostty hidden replay reparent",
            launch: .shell(cwd: testRoot.path),
            outputBus: SurfaceOutputBus(flushDelay: 0)
        )
        let window = makeWindow(containing: surface.view)
        SurfaceRegistry.shared.register(surface)
        SurfaceRegistry.shared.setVisibleSurfaceIDs([surface.descriptor.id])
        defer {
            SurfaceRegistry.shared.setVisibleSurfaceIDs([])
            surface.close()
            SurfaceRegistry.shared.unregister(surface.descriptor.id)
            window.orderOut(nil)
        }
        try waitUntil("the reparent fixture must have a live Ghostty parser") {
            surface.ghosttyHasLiveSurfaceForTesting
        }

        let startMarker = "RC2_REPARENT_START_\(UUID().uuidString)"
        let endMarker = "RC2_REPARENT_END_\(UUID().uuidString)"
        var replay = Data("\r\n\(startMarker)\r\n".utf8)
        replay.append(Data(repeating: 0, count: 3 * 1024 * 1024))
        replay.append(Data("\r\n\(endMarker)\r\n".utf8))
        surface.replayResetSurfaceOutputForTesting(replay)
        XCTAssertTrue(surface.ghosttyReplayInProgressForTesting)
        XCTAssertTrue(surface.readerPausedForHistoryReplayForTesting)
        let creationCountAfterReset = surface.ghosttySurfaceCreationCountForTesting

        var pendingBytesAtHide: Int?
        var didHideAndDetach = false
        DispatchQueue.main.async {
            // The first queued 8 KiB replay slice runs before this block.
            pendingBytesAtHide = surface.ghosttyPendingOutputBytesForTesting
            surface.didBecomeHidden()
            surface.view.removeFromSuperview()
            didHideAndDetach = true
        }
        try waitUntil("the surface must hide and detach after a replay slice") {
            didHideAndDetach
        }
        let pendingAfterSlice = try XCTUnwrap(pendingBytesAtHide)
        XCTAssertGreaterThan(pendingAfterSlice, 0)
        XCTAssertLessThan(pendingAfterSlice, replay.count)
        try waitUntil("the hidden surface must attach to its parking host") {
            surface.runtimeHealth().renderDiagnostics?.parked == true
        }

        // Deliberately do not reselect the tab, read the view, or inject output.
        // Reparent lifecycle alone must install a current-generation replay turn.
        try waitUntil("hidden replay must drain and resume its PTY reader", timeout: 20) {
            !surface.ghosttyReplayInProgressForTesting
                && !surface.readerPausedForHistoryReplayForTesting
        }
        XCTAssertEqual(
            surface.ghosttySurfaceCreationCountForTesting,
            creationCountAfterReset,
            "parking must retain the same parser instead of replaying twice"
        )

        let ghostty = try XCTUnwrap(surface.ghosttyScrollbackTextForTesting)
        assertOrderedOnce([startMarker, endMarker], in: ghostty, label: "hidden Ghostty scrollback")
        XCTAssertEqual(surface.runtimeHealth().droppedOutputBytes, 0)
    }

    func testRejectedHandoffGatesDelayedOutputAndEOFExitBannerInExactFIFOOrder() throws {
        guard ProcessInfo.processInfo.environment["RC2_ENABLE_GHOSTTY_IN_TESTS"] == "1" else {
            throw XCTSkip("run with RC2_ENABLE_GHOSTTY_IN_TESTS=1 for the replay ownership gate")
        }

        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ReplayOwnership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let environment = ShellEnvironmentLease(zdotdir: testRoot.path)
        defer { environment.restore() }
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "Ghostty replay ownership",
            launch: .shell(cwd: testRoot.path),
            outputBus: SurfaceOutputBus(flushDelay: 0)
        )
        let window = makeWindow(containing: surface.view)
        SurfaceRegistry.shared.register(surface)
        SurfaceRegistry.shared.setVisibleSurfaceIDs([surface.descriptor.id])
        defer {
            SurfaceRegistry.shared.setVisibleSurfaceIDs([])
            surface.close()
            SurfaceRegistry.shared.unregister(surface.descriptor.id)
            window.orderOut(nil)
        }
        try waitUntil("the ownership fixture must have a live Ghostty parser") {
            surface.ghosttyHasLiveSurfaceForTesting
        }

        let noticeMarker = "RC2_NOTICE_\(UUID().uuidString)"
        let ptyMarker = "RC2_PTY_HANDOFF_\(UUID().uuidString)"
        let delayedMarker = "RC2_DELAYED_AFTER_HANDOFF_\(UUID().uuidString)"
        let exitMarker = "[process exited (code 0)]"
        let replay = Data(
            repeating: UInt8(ascii: "h"),
            count: TerminalHistoryCoordinator.maxCanonicalReplayBytes
        )
        surface.replayResetSurfaceOutputForTesting(replay)
        XCTAssertTrue(surface.readerPausedForHistoryReplayForTesting)

        var notice = Data(
            repeating: 0,
            count: 64 * 1024 - noticeMarker.utf8.count - 4
        )
        notice.append(Data("\r\n\(noticeMarker)\r\n".utf8))
        surface.appendSystemText(String(decoding: notice, as: UTF8.self))
        var ptyHandoff = Data(
            repeating: 0,
            count: 256 * 1024 - ptyMarker.utf8.count - 4
        )
        ptyHandoff.append(Data("\r\n\(ptyMarker)\r\n".utf8))
        surface.injectReaderOutputForTesting(ptyHandoff)

        XCTAssertEqual(
            surface.ownedGhosttyReplayOutputBytesForTesting,
            ptyHandoff.count,
            "the rejected max-size reader handoff must remain explicitly owned"
        )
        let delayedOutput = "\r\n\(delayedMarker)\r\n"
        var ownedBytesAfterDelayedOutput: Int?
        DispatchQueue.main.async {
            // The replay pump's already-queued turn runs first and frees 8 KiB.
            // B would now fit in Ghostty, but A is still owner-held and must gate
            // B plus the EOF banner behind it instead of allowing an overtake.
            surface.appendSystemText(delayedOutput)
            surface.simulateReaderEOFAndExitBannerForTesting()
            ownedBytesAfterDelayedOutput = surface.ownedGhosttyReplayOutputBytesForTesting
        }
        try waitUntil("delayed output and EOF banner must join the owner FIFO") {
            ownedBytesAfterDelayedOutput != nil
        }
        let exitBannerBytes = Data("\r\n\(exitMarker)\r\n".utf8).count
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(ownedBytesAfterDelayedOutput),
            ptyHandoff.count + Data(delayedOutput.utf8).count + exitBannerBytes
        )
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(ownedBytesAfterDelayedOutput),
            GhosttyTerminalView.maxPendingOutputBytes
        )
        XCTAssertFalse(surface.readerConfiguredForTesting)
        try waitUntil("owned replay continuation must drain before reader resume", timeout: 20) {
            !surface.ghosttyReplayInProgressForTesting
                && !surface.readerPausedForHistoryReplayForTesting
                && surface.ownedGhosttyReplayOutputBytesForTesting == 0
        }
        try waitUntil("Ghostty must receive the FIFO plus EOF banner", timeout: 20) {
            let text = surface.ghosttyScrollbackTextForTesting ?? ""
            return text.contains(noticeMarker)
                && text.contains(ptyMarker)
                && text.contains(delayedMarker)
                && text.contains(exitMarker)
        }

        let ghostty = try XCTUnwrap(surface.ghosttyScrollbackTextForTesting)
        let mirror = surface.readTextSnapshot().text
        let expectedOrder = [noticeMarker, ptyMarker, delayedMarker, exitMarker]
        assertOrderedOnce(expectedOrder, in: ghostty, label: "Ghostty scrollback")
        assertOrderedOnce(expectedOrder, in: mirror, label: "ANSI mirror")
    }

    func testPersistedReplayRacingLivePTYKeepsExactOrderInGhosttyAndMirrorSnapshot() throws {
        guard ProcessInfo.processInfo.environment["RC2_ENABLE_GHOSTTY_IN_TESTS"] == "1" else {
            throw XCTSkip("run with RC2_ENABLE_GHOSTTY_IN_TESTS=1 for the real Ghostty replay gate")
        }

        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2HistoryGhostty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let environment = ShellEnvironmentLease(zdotdir: testRoot.path)
        defer { environment.restore() }

        let database = try SQLiteDB(path: testRoot.appendingPathComponent("history.sqlite").path)
        try Schema.migrate(database)
        let repository = TerminalOutputRepository(db: database)
        let surfaceID = SurfaceID()
        let workspaceID = WorkspaceID()
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let persistedMarker = "RC2_HISTORY_PERSISTED_\(token)"
        let firstLiveMarker = "RC2_HISTORY_LIVE_FIRST_\(token)"
        let secondLiveMarker = "RC2_HISTORY_LIVE_SECOND_\(token)"
        try repository.append(
            surfaceID: surfaceID.value.uuidString,
            workspaceID: workspaceID.value.uuidString,
            chunkIndex: 1,
            data: Data("\(persistedMarker)\r\n".utf8)
        )

        let readStarted = DispatchSemaphore(value: 0)
        let allowRead = DispatchSemaphore(value: 0)
        let hookLock = NSLock()
        var didBlockRead = false
        database.beforeStatementStepForTesting = { sql in
            guard sql.contains("FROM terminal_output_chunks"),
                  sql.contains("ORDER BY id DESC") else { return }
            hookLock.lock()
            let shouldBlock = !didBlockRead
            didBlockRead = true
            hookLock.unlock()
            guard shouldBlock else { return }
            readStarted.signal()
            _ = allowRead.wait(timeout: .now() + 10)
        }

        SurfaceRegistry.shared.setVisibleSurfaceIDs([])
        let surface = try TerminalSurface(
            workspaceID: workspaceID,
            title: "Ghostty history race",
            launch: .shell(cwd: testRoot.path),
            restoredSurfaceID: surfaceID,
            historyRepo: repository,
            outputBus: SurfaceOutputBus(flushDelay: 0)
        )
        let window = makeWindow(containing: surface.view)
        SurfaceRegistry.shared.register(surface)
        SurfaceRegistry.shared.setVisibleSurfaceIDs([surfaceID])
        defer {
            allowRead.signal()
            database.beforeStatementStepForTesting = nil
            SurfaceRegistry.shared.setVisibleSurfaceIDs([])
            surface.close()
            SurfaceRegistry.shared.unregister(surfaceID)
            window.orderOut(nil)
        }

        var readDidStart = false
        try waitUntil("the fixture must hold the real persisted-history read while the PTY remains live") {
            if readDidStart { return true }
            readDidStart = readStarted.wait(timeout: .now()) == .success
            return readDidStart
        }
        var lastRenderDiagnostics: TerminalRenderDiagnostics?
        do {
            try waitUntil("the restored terminal must own a runtime-visible Ghostty view") {
                lastRenderDiagnostics = surface.runtimeHealth().renderDiagnostics
                return lastRenderDiagnostics?.canRender == true
            }
        } catch {
            XCTFail("final render diagnostics: \(String(describing: lastRenderDiagnostics))")
            throw error
        }

        let command = shellPrintfCommand(lines: [firstLiveMarker, secondLiveMarker])
        XCTAssertEqual(surface.sendTextStatus(command), .accepted)
        try waitUntil("actual PTY output must reach both renderers before history completes") {
            let mirror = surface.readTextSnapshot().text
            let ghostty = surface.ghosttyScrollbackTextForTesting ?? ""
            return mirror.contains(firstLiveMarker)
                && mirror.contains(secondLiveMarker)
                && ghostty.contains(firstLiveMarker)
                && ghostty.contains(secondLiveMarker)
        }

        allowRead.signal()
        try waitUntil("persisted history replay must complete") {
            !surface.historyReplayInFlightForTesting
        }
        try waitUntil("Ghostty and mirror must converge on the complete ordered replay", timeout: 10) {
            let snapshot = surface.readTextSnapshot()
            let ghostty = surface.ghosttyScrollbackTextForTesting ?? ""
            return snapshot.complete
                && snapshot.text.contains(persistedMarker)
                && snapshot.text.contains(firstLiveMarker)
                && snapshot.text.contains(secondLiveMarker)
                && ghostty.contains(persistedMarker)
                && ghostty.contains(firstLiveMarker)
                && ghostty.contains(secondLiveMarker)
        }

        let ghostty = try XCTUnwrap(surface.ghosttyScrollbackTextForTesting)
        let snapshot = surface.readTextSnapshot()
        assertOrderedOnce(
            [persistedMarker, firstLiveMarker, secondLiveMarker],
            in: ghostty,
            label: "Ghostty scrollback"
        )
        assertOrderedOnce(
            [persistedMarker, firstLiveMarker, secondLiveMarker],
            in: snapshot.text,
            label: "surface.read_text"
        )
        XCTAssertTrue(snapshot.complete, "final read_text must be complete: \(snapshot.partialReason ?? "none")")
    }

    private func shellPrintfCommand(lines: [String]) -> String {
        let bytes = lines.joined(separator: "\n") + "\n"
        let escaped = bytes.utf8.map { String(format: "\\%03o", $0) }.joined()
        return "printf '\(escaped)'\n"
    }

    private func assertOrderedOnce(_ markers: [String], in text: String, label: String) {
        var previousEnd = text.startIndex
        for marker in markers {
            let ranges = text.ranges(of: marker)
            XCTAssertEqual(ranges.count, 1, "\(label) must contain \(marker) exactly once")
            guard let range = ranges.first else { continue }
            XCTAssertGreaterThanOrEqual(
                range.lowerBound,
                previousEnd,
                "\(label) must preserve persisted -> live-first -> live-second order"
            )
            previousEnd = range.upperBound
        }
    }

    private func makeWindow(containing view: NSView) -> NSWindow {
        let window = RuntimeVisibleTestWindow(
            contentRect: NSRect(x: 120, y: 120, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: window.contentLayoutRect)
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = window.contentView?.bounds ?? .zero
        view.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(view)
        window.alphaValue = 1
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.orderFrontRegardless()
        window.makeKey()
        return window
    }

    private func waitUntil(
        _ message: String,
        timeout: TimeInterval = 6,
        predicate: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail(message)
        throw WaitTimeout()
    }

    private struct WaitTimeout: Error {}

    private final class RuntimeVisibleTestWindow: NSWindow {
        override var occlusionState: NSWindow.OcclusionState { [.visible] }
    }

    private final class ShellEnvironmentLease {
        private let oldZDOTDIR = ProcessInfo.processInfo.environment["ZDOTDIR"]
        private let oldHISTFILE = ProcessInfo.processInfo.environment["HISTFILE"]

        init(zdotdir: String) {
            setenv("ZDOTDIR", zdotdir, 1)
            setenv("HISTFILE", "/dev/null", 1)
        }

        func restore() {
            restore("ZDOTDIR", value: oldZDOTDIR)
            restore("HISTFILE", value: oldHISTFILE)
        }

        private func restore(_ name: String, value: String?) {
            if let value {
                setenv(name, value, 1)
            } else {
                unsetenv(name)
            }
        }
    }
}

private extension String {
    func ranges(of needle: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var start = startIndex
        while start < endIndex,
              let range = range(of: needle, range: start..<endIndex) {
            result.append(range)
            start = range.upperBound
        }
        return result
    }
}
