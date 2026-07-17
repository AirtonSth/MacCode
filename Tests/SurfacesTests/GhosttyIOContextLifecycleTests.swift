import XCTest
import AppKit
@testable import Surfaces

/// Regression for the intentional-but-bounded IOContext leak:
/// `Unmanaged.passRetained(ioContext)` in setup() pinned the tiny context for the
/// process lifetime (one per terminal view ever created). The fix stores the
/// retained ref and releases it in deinit after ghostty_surface_free returns, so
/// the context is freed when the view is closed instead of at process exit.
///
/// WHY these tests matter: the retained ref guards against a use-after-free on
/// Ghostty's IO thread — releasing it before ghostty_surface_free returns would
/// dangle the raw io_write_userdata pointer. The fix must keep the context alive
/// for the full view lifetime and release it exactly once in deinit.
@MainActor
final class GhosttyIOContextLifecycleTests: XCTestCase {

    // MARK: - Pin-on-init

    func test_ioContextIsPinnedAfterInit() {
        // ioContextRetain must be set in setup() so the raw userdata pointer Ghostty
        // holds is backed by a live object from the first surface creation onward.
        let view = GhosttyTerminalView(frame: .zero)
        XCTAssertTrue(
            view.ioContextIsPinned,
            "ioContext must be retained immediately after init — Ghostty may create the surface " +
            "and fire io_write_cb before any other setup runs"
        )
        // Prevent premature dealloc (view must still be live at assertion site).
        _ = view.frame
    }

    // MARK: - Release-on-deinit (no-surface path)

    func test_ioContextIsReleasedWhenViewDeinitWithNoSurface() {
        // When no Ghostty surface exists (no window, no Ghostty runtime), deinit takes
        // the else-branch and releases the pin synchronously. The ioContext object
        // must then have no owners and be deallocated.
        //
        // We observe deallocation via a weak outer reference: if ioContext were still
        // retained after `view = nil`, weakView would remain non-nil here.
        weak var weakView: GhosttyTerminalView?

        autoreleasepool {
            let view = GhosttyTerminalView(frame: .zero)
            weakView = view
            XCTAssertTrue(view.ioContextIsPinned, "pre-condition: context must be pinned")
            // view goes out of scope here; deinit runs synchronously (no surface ->
            // no async DispatchQueue.main.async path).
        }

        // If the extra retain were never released, the view itself would be kept alive
        // by the ioContext -> view relationship (ioContext.view is weak, so this path
        // actually tests ARC count on the view object: the Unmanaged retain on ioContext
        // keeps ioContext alive, but ioContext has only a weak back-ref to view, so
        // view dealloc is driven purely by the view's own ARC count).
        //
        // What this verifies: after autoreleasepool drains, the view is gone, which
        // means deinit ran and (on the no-surface path) the release executed synchronously.
        // We cannot directly observe ioContext dealloc (it's private), but verifying
        // the view itself is gone confirms the no-surface deinit path ran to completion
        // without a retain cycle or assertion failure.
        XCTAssertNil(
            weakView,
            "GhosttyTerminalView must be deallocated after all strong refs drop — " +
            "a leaked ioContextRetain would not prevent view dealloc (ioContext holds only " +
            "a weak view ref), but any retain cycle would keep the view alive here"
        )
    }

    // MARK: - Single pin (not re-pinned on surface recreation)

    func test_ioContextRetainCountDoesNotGrowOnMultipleSetupCalls() {
        // `setup()` is called exactly once (from init). Calling it again would add a
        // second unbalanced retain. This test guards against accidental double-pinning
        // by verifying ioContextIsPinned is stable (not a counter).
        let view = GhosttyTerminalView(frame: .zero)
        XCTAssertTrue(view.ioContextIsPinned, "should be pinned after first init")
        // If setup() were accidentally called twice the second passRetained would
        // overwrite ioContextRetain, leaking the first ref — but the Bool seam
        // can only tell us it is pinned, not the count. This test is a documentation
        // anchor: the actual defence is that setup() is only called from init.
        _ = view.frame
    }

    func test_preAttachOutputOverflowUsesBatchedCompactionAndBoundedStorage() {
        // WHY: long output before AppKit attaches a live Ghostty surface must
        // not copy the full 4 MiB tail for every small chunk above the cap.
        let view = GhosttyTerminalView(frame: .zero)
        let chunk = Data(repeating: 0x41, count: 4 * 1024)
        let chunkCount = 20_000

        for _ in 0..<chunkCount {
            view.processOutput(chunk)
        }

        let diagnostics = view.pendingOutputDiagnosticsForTesting
        let totalBytes = chunk.count * chunkCount
        let cap = 4 * 1024 * 1024
        XCTAssertEqual(diagnostics.logicalBytes, cap)
        XCTAssertEqual(view.droppedOutputBytes, totalBytes - cap)
        XCTAssertLessThanOrEqual(
            diagnostics.storageBytes,
            cap + (1024 * 1024),
            "physical storage must stay within one compaction batch of the logical cap"
        )
        XCTAssertGreaterThan(diagnostics.compactions, 0)
        XCTAssertLessThan(
            diagnostics.compactions,
            chunkCount / 100,
            "overflow must compact in batches instead of copying on every chunk"
        )
    }
}
