import AppKit
import PDFKit
import XCTest
import CoreModel
@testable import Surfaces

final class FilePreviewMemoryLifecycleTests: XCTestCase {
    @MainActor
    func test_hidePurgesHeavyCaches_withoutEvictingAnotherActiveSurface() {
        // WHY: two tabs can preview the same path. Hiding one must release only that
        // surface's heavy ownership; a still-visible sibling must remain intact.
        let path = "/tmp/remote-code-shared-preview.fixture"
        let hidden = FilePreviewSurface(workspaceID: WorkspaceID(), filePath: path)
        let active = FilePreviewSurface(workspaceID: WorkspaceID(), filePath: path)
        let hiddenDocument = PDFDocument()
        let activeDocument = PDFDocument()
        hidden.textCache.store(path: path, text: String(repeating: "hidden\n", count: 1_000))
        active.textCache.store(path: path, text: String(repeating: "active\n", count: 1_000))
        hidden.pdfCache.store(path: path, document: hiddenDocument)
        active.pdfCache.store(path: path, document: activeDocument)

        hidden.didBecomeHidden()

        XCTAssertTrue(hidden.view.subviews.isEmpty)
        XCTAssertEqual(hidden.textCache.entryCountForTesting, 0)
        XCTAssertEqual(hidden.textCache.retainedPayloadBytesForTesting, 0)
        XCTAssertEqual(hidden.pdfCache.entryCountForTesting, 0)
        XCTAssertEqual(active.textCache.text(for: path), String(repeating: "active\n", count: 1_000),
            "per-surface purge must not evict a sibling that is still visible")
        XCTAssertTrue(active.pdfCache.document(for: path) === activeDocument,
            "per-surface PDF ownership must remain isolated")
    }

    @MainActor
    func test_closePurgesLateHeavyContent_butPreservesPathAndScrollState() {
        // WHY: the router can close a surface after it was hidden. A late callback
        // must not survive that second lifecycle boundary, while reopen metadata and
        // lightweight scroll/page state stay available to the owning object.
        let path = "/tmp/remote-code-closed-preview.fixture"
        let surface = FilePreviewSurface(workspaceID: WorkspaceID(), filePath: path)
        surface.didBecomeHidden()
        let saved = FilePreviewScrollCache.Entry(scrollOffsetY: 321, pdfPageIndex: 7)
        surface.scrollCache.store(path: path, entry: saved)
        surface.textCache.store(path: path, text: String(repeating: "late\n", count: 1_000))
        surface.pdfCache.store(path: path, document: PDFDocument())

        surface.close()

        XCTAssertEqual(surface.filePath, path)
        XCTAssertEqual(surface.scrollCache.entry(for: path), saved,
            "close must preserve only lightweight reopen/scroll state")
        XCTAssertEqual(surface.textCache.entryCountForTesting, 0)
        XCTAssertEqual(surface.pdfCache.entryCountForTesting, 0)
    }

    @MainActor
    func test_loadingDifferentPathBoundsActiveSurfaceToCurrentHeavyEntry() {
        // WHY: a visible preview can be reused for many paths without ever hiding.
        // Changing path must not grow an unbounded history of Strings/PDFDocuments;
        // only lightweight per-path scroll state is allowed to survive navigation.
        let firstPath = "/tmp/remote-code-first-preview.fixture"
        let secondPath = "/tmp/remote-code-second-preview.fixture"
        let surface = FilePreviewSurface(workspaceID: WorkspaceID(), filePath: firstPath)
        let saved = FilePreviewScrollCache.Entry(scrollOffsetY: 88, pdfPageIndex: 2)
        surface.scrollCache.store(path: firstPath, entry: saved)
        surface.textCache.store(path: firstPath, text: String(repeating: "old\n", count: 1_000))
        surface.pdfCache.store(path: firstPath, document: PDFDocument())

        surface.load(filePath: secondPath)

        XCTAssertEqual(surface.filePath, secondPath)
        XCTAssertEqual(surface.textCache.entryCountForTesting, 0)
        XCTAssertEqual(surface.pdfCache.entryCountForTesting, 0)
        XCTAssertEqual(surface.scrollCache.entry(for: firstPath), saved,
            "navigation may preserve lightweight scroll history but not heavy content")
    }

    @MainActor
    func test_staleTextCallbackCannotRepopulateAfterHideAndReopen() async throws {
        // WHY: a detached disk read can finish after hide. If the same path reopens,
        // visibility alone is insufficient: the old callback could overwrite the new
        // content and recreate heavy retention. A render generation must reject it.
        let path = "/tmp/remote-code-stale-preview.txt"
        let probe = ControlledTextLoader()
        let surface = FilePreviewSurface(workspaceID: WorkspaceID(), filePath: nil)
        surface.previewTextLoaderForTesting = { path in probe.load(path: path) }
        surface.previewTextPublicationProbeForTesting = { text, shouldPublish in
            probe.recordPublication(text: text, shouldPublish: shouldPublish)
        }

        surface.load(filePath: path)
        let firstStarted = await Task.detached { probe.waitForFirstStart() }.value
        XCTAssertTrue(firstStarted, "the first detached read must be held in flight")
        let staleScroll = try XCTUnwrap(surface.view.subviews.first as? NSScrollView)
        let staleTextView = try XCTUnwrap(staleScroll.documentView as? NSTextView)
        let staleRuler = try XCTUnwrap(staleScroll.verticalRulerView)

        surface.didBecomeHidden()
        XCTAssertEqual(surface.textCache.retainedPayloadBytesForTesting, 0)
        XCTAssertTrue(surface.view.subviews.isEmpty)

        surface.didBecomeVisible()
        let reopened = await eventually { surface.textCache.text(for: path) == "fresh generation" }
        XCTAssertTrue(reopened,
            "reopen must perform a fresh off-main load after the hidden cache was purged")

        probe.releaseFirst()
        let staleCallbackEvaluated = await Task.detached { probe.waitForStalePublication() }.value
        XCTAssertTrue(staleCallbackEvaluated,
            "the stale callback must reach MainActor and evaluate publication before assertions")

        XCTAssertEqual(probe.stalePublicationAllowed, false,
            "the pre-hide generation must be explicitly rejected even while its old views remain alive")
        XCTAssertEqual(surface.textCache.text(for: path), "fresh generation",
            "late pre-hide content must not replace the reopened generation")
        XCTAssertEqual(surface.textCache.entryCountForTesting, 1,
            "the active surface remains bounded to its current path")
        withExtendedLifetime((staleScroll, staleTextView, staleRuler)) {}
    }

    @MainActor
    private func eventually(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }
}

private final class ControlledTextLoader: @unchecked Sendable {
    private let lock = NSLock()
    private let firstStarted = DispatchSemaphore(value: 0)
    private let releaseFirstLoad = DispatchSemaphore(value: 0)
    private let stalePublicationEvaluated = DispatchSemaphore(value: 0)
    private var calls = 0
    private var staleAllowed: Bool?

    var callCount: Int { lock.withLock { calls } }
    var stalePublicationAllowed: Bool? { lock.withLock { staleAllowed } }

    func load(path: String) -> String {
        let call = lock.withLock {
            calls += 1
            return calls
        }
        if call == 1 {
            firstStarted.signal()
            _ = releaseFirstLoad.wait(timeout: .now() + 5)
            return "stale generation"
        }
        return "fresh generation"
    }

    func waitForFirstStart() -> Bool {
        firstStarted.wait(timeout: .now() + 5) == .success
    }

    func releaseFirst() {
        releaseFirstLoad.signal()
    }

    func recordPublication(text: String, shouldPublish: Bool) {
        guard text == "stale generation" else { return }
        lock.withLock { staleAllowed = shouldPublish }
        stalePublicationEvaluated.signal()
    }

    func waitForStalePublication() -> Bool {
        stalePublicationEvaluated.wait(timeout: .now() + 5) == .success
    }
}
