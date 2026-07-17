import AppKit
import XCTest

@testable import CoreModel
@testable import Persistence
@testable import Surfaces

/// Opt-in C13 gate: persisted replay races actual PTY output while a real
/// Ghostty surface is attached to a runtime-visible AppKit window.
@MainActor
final class TerminalHistoryGhosttyIntegrationTests: XCTestCase {
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

        XCTAssertEqual(
            readStarted.wait(timeout: .now() + 3),
            .success,
            "the fixture must hold the real persisted-history read while the PTY remains live"
        )
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
