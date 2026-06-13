import XCTest
@testable import Surfaces

/// Tests for the `readTextSnapshot()` two-signal cache on `TerminalSurface`.
///
/// WHY these tests exist:
///
/// Problem — Hundreds of ms of main-thread work per mirror snapshot while output
/// flows: `readTextSnapshot()` called `renderer.snapshot().string` and
/// `renderer.ansiSnapshot(includeScrollback: true)` on EVERY invocation, even
/// when neither the renderer content nor the ghostty viewport text had changed.
/// At 10 000-row scrollback that is one `NSAttributedString` allocation per cell
/// per poll tick, burning the main thread during high-rate terminal output.
///
/// Fix — A two-key cache gated on:
///   1. `rendererMutationCount` — a local counter bumped after every
///      `renderer.feed()` / `renderer.resize()` call inside `TerminalSurface`.
///      This reflects all ANSIRenderer content changes without touching
///      ANSIRenderer's private `contentVersion`.
///   2. `viewportText` — the full `String?` returned by
///      `ghosttyView.readViewportText()` on the last build. The ghostty viewport
///      can change (scroll, repaint) independently of the ANSIRenderer; a
///      renderer-version-only key would return stale viewport text, which means
///      the user's iOS mirror would show the wrong terminal content. Storing the
///      full string and checking equality is O(n) in text length but is only
///      paid on `readTextSnapshot()` calls — not on every byte of output.
///
/// The pure seam `snapshotCacheValid(rendererVersion:cachedVersion:viewportText:cachedViewportText:)`
/// is the single decision point and is tested here in isolation.
final class TerminalSnapshotCacheTests: XCTestCase {

    // MARK: - snapshotCacheValid: identical inputs

    func test_cacheValid_whenBothKeysMatch() {
        // WHY: the common hot path — nothing changed since last build. The seam
        // must return true so readTextSnapshot() skips the expensive rebuild.
        XCTAssertTrue(
            TerminalSurface.snapshotCacheValid(
                rendererVersion: 7,
                cachedVersion: 7,
                viewportText: "hello\nworld",
                cachedViewportText: "hello\nworld"
            ),
            "cache must be valid when both renderer version and viewport text are identical — expensive snapshot rebuild must be skipped"
        )
    }

    func test_cacheValid_whenBothKeysMatchAndViewportTextIsNil() {
        // WHY: when ghostty has no live surface, readViewportText() returns nil.
        // The cache must stay valid across repeated nil-viewport calls so the
        // ansi_fallback path is not rebuilt on every poll tick.
        XCTAssertTrue(
            TerminalSurface.snapshotCacheValid(
                rendererVersion: 3,
                cachedVersion: 3,
                viewportText: nil,
                cachedViewportText: nil
            ),
            "cache must be valid when ghostty viewport is nil on both current and cached read — nil-ghostty path must not rebuild every poll tick"
        )
    }

    // MARK: - snapshotCacheValid: renderer changed

    func test_cacheInvalid_whenRendererVersionAdvanced() {
        // WHY: a byte arrived and renderer.feed() was called, bumping the
        // mutation count. The cached snapshot is stale — it does not reflect the
        // new output. Must return false so the caller rebuilds.
        XCTAssertFalse(
            TerminalSurface.snapshotCacheValid(
                rendererVersion: 8,
                cachedVersion: 7,
                viewportText: "hello",
                cachedViewportText: "hello"
            ),
            "cache must be invalid when the renderer mutation count advanced — cached snapshot does not include the new output bytes"
        )
    }

    func test_cacheInvalid_whenRendererVersionAdvanced_andViewportAlsoNil() {
        // WHY: even in the nil-viewport (ansi_fallback) path, new bytes fed to
        // the renderer must invalidate the cache.
        XCTAssertFalse(
            TerminalSurface.snapshotCacheValid(
                rendererVersion: 2,
                cachedVersion: 1,
                viewportText: nil,
                cachedViewportText: nil
            ),
            "nil-viewport cache must still be invalidated when the renderer received new bytes — ansi_fallback text would be stale otherwise"
        )
    }

    // MARK: - snapshotCacheValid: viewport text changed (staleness trap)

    func test_cacheInvalid_whenViewportTextChanged() {
        // WHY: this is the exact staleness trap flagged in the audit comment.
        // Ghostty can scroll or repaint its viewport independently of the
        // ANSIRenderer. A renderer-version-only key would return the old cached
        // snapshot even though the visible terminal content has changed, causing
        // the user's iOS mirror to show wrong text.
        XCTAssertFalse(
            TerminalSurface.snapshotCacheValid(
                rendererVersion: 5,
                cachedVersion: 5,
                viewportText: "samuel@mac ~ % ls",
                cachedViewportText: "samuel@mac ~ % "
            ),
            "cache must be invalid when the ghostty viewport text changed even if the ANSIRenderer mutation count is the same — a renderer-version-only key returns stale viewport content to the iOS mirror"
        )
    }

    func test_cacheInvalid_whenViewportTransitionsFromNilToString() {
        // WHY: ghostty surface became available between the last and current
        // readTextSnapshot() call. The nil cached key must not match the new
        // non-nil viewport text so the fresh ghostty_viewport snapshot is built.
        XCTAssertFalse(
            TerminalSurface.snapshotCacheValid(
                rendererVersion: 4,
                cachedVersion: 4,
                viewportText: "new text",
                cachedViewportText: nil
            ),
            "cache must be invalid when ghostty viewport transitions from nil to a real string — the stale ansi_fallback snapshot must not be served after ghostty becomes available"
        )
    }

    func test_cacheInvalid_whenViewportTransitionsFromStringToNil() {
        // WHY: ghostty surface was torn down between reads. The non-nil cached
        // key must not match the nil current viewport so the fallback snapshot
        // is rebuilt from the current ANSIRenderer state.
        XCTAssertFalse(
            TerminalSurface.snapshotCacheValid(
                rendererVersion: 4,
                cachedVersion: 4,
                viewportText: nil,
                cachedViewportText: "old text"
            ),
            "cache must be invalid when ghostty viewport becomes nil — previously cached ghostty_viewport snapshot must not be served after the surface is gone"
        )
    }

    // MARK: - snapshotCacheValid: both keys changed

    func test_cacheInvalid_whenBothKeysChanged() {
        // WHY: normal case during active output — renderer received new bytes
        // AND ghostty repainted its frame. Both invalidation signals fire
        // simultaneously; either alone is sufficient to force a rebuild.
        XCTAssertFalse(
            TerminalSurface.snapshotCacheValid(
                rendererVersion: 10,
                cachedVersion: 9,
                viewportText: "new frame",
                cachedViewportText: "old frame"
            ),
            "cache must be invalid when both renderer version and viewport text changed — both signals independently demand a rebuild"
        )
    }

    // MARK: - snapshotCacheValid: purity

    func test_snapshotCacheValid_isPure_forValidCase() {
        // WHY: the seam must be side-effect-free. Repeated calls with identical
        // arguments must always return the same value; a stateful implementation
        // would silently break the skip-or-rebuild decision across poll ticks.
        let first  = TerminalSurface.snapshotCacheValid(rendererVersion: 1, cachedVersion: 1, viewportText: "x", cachedViewportText: "x")
        let second = TerminalSurface.snapshotCacheValid(rendererVersion: 1, cachedVersion: 1, viewportText: "x", cachedViewportText: "x")
        XCTAssertEqual(first, second,
                       "snapshotCacheValid must be pure — identical inputs must always produce the same result across calls")
    }

    func test_snapshotCacheValid_isPure_forInvalidCase() {
        // WHY: same purity requirement for the invalidation path; a stateful
        // seam might return false only once then flip to true, causing one stale
        // snapshot to be served on the second poll tick.
        let first  = TerminalSurface.snapshotCacheValid(rendererVersion: 2, cachedVersion: 1, viewportText: "a", cachedViewportText: "b")
        let second = TerminalSurface.snapshotCacheValid(rendererVersion: 2, cachedVersion: 1, viewportText: "a", cachedViewportText: "b")
        XCTAssertEqual(first, second,
                       "snapshotCacheValid must be pure for the invalidation path — same stale inputs must always return false")
    }
}
