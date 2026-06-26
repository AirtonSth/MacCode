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

    /// Wrapper that defaults the F1 state-signature pair to equal values, so the
    /// pre-existing renderer/viewport tests below read unchanged and exercise only
    /// those two signals. The state-signature behaviour is covered separately.
    private func cacheValid(
        rendererVersion: UInt64,
        cachedVersion: UInt64,
        viewportText: String?,
        cachedViewportText: String?,
        stateSignature: String = "sig",
        cachedStateSignature: String = "sig"
    ) -> Bool {
        TerminalSurface.snapshotCacheValid(
            rendererVersion: rendererVersion,
            cachedVersion: cachedVersion,
            viewportText: viewportText,
            cachedViewportText: cachedViewportText,
            stateSignature: stateSignature,
            cachedStateSignature: cachedStateSignature
        )
    }

    // MARK: - snapshotCacheValid: identical inputs

    func test_cacheValid_whenBothKeysMatch() {
        // WHY: the common hot path — nothing changed since last build. The seam
        // must return true so readTextSnapshot() skips the expensive rebuild.
        XCTAssertTrue(
            cacheValid(
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
            cacheValid(
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
            cacheValid(
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
            cacheValid(
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
            cacheValid(
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
            cacheValid(
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
            cacheValid(
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
            cacheValid(
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
        let first  = cacheValid(rendererVersion: 1, cachedVersion: 1, viewportText: "x", cachedViewportText: "x")
        let second = cacheValid(rendererVersion: 1, cachedVersion: 1, viewportText: "x", cachedViewportText: "x")
        XCTAssertEqual(first, second,
                       "snapshotCacheValid must be pure — identical inputs must always produce the same result across calls")
    }

    func test_snapshotCacheValid_isPure_forInvalidCase() {
        // WHY: same purity requirement for the invalidation path; a stateful
        // seam might return false only once then flip to true, causing one stale
        // snapshot to be served on the second poll tick.
        let first  = cacheValid(rendererVersion: 2, cachedVersion: 1, viewportText: "a", cachedViewportText: "b")
        let second = cacheValid(rendererVersion: 2, cachedVersion: 1, viewportText: "a", cachedViewportText: "b")
        XCTAssertEqual(first, second,
                       "snapshotCacheValid must be pure for the invalidation path — same stale inputs must always return false")
    }

    // MARK: - snapshotCacheValid: state-signature drift (audit F1)
    //
    // The cache embeds render-diagnostics + pending/partial/history-failure flags in
    // the snapshot, but rendererVersion + viewportText do NOT capture those. A
    // diagnostics change (canRender flips, blockedReason changes, outputPendingBytes
    // moves) with the same renderer version and viewport text used to serve a snapshot
    // with STALE diagnostics. The state signature is now part of the key.

    func test_cacheInvalid_whenStateSignatureChanged_evenIfRendererAndViewportSame() {
        XCTAssertFalse(
            cacheValid(
                rendererVersion: 5, cachedVersion: 5,
                viewportText: "same", cachedViewportText: "same",
                stateSignature: "false|0|0|window_detached|false",
                cachedStateSignature: "false|0|0||true"
            ),
            "cache must be invalid when render-diagnostics/pending state changed even if renderer version and viewport text are identical — otherwise a snapshot with stale diagnostics is served")
    }

    func test_cacheValid_requiresAllThreeKeysToMatch() {
        XCTAssertTrue(
            cacheValid(
                rendererVersion: 5, cachedVersion: 5,
                viewportText: "same", cachedViewportText: "same",
                stateSignature: "x", cachedStateSignature: "x"
            ),
            "cache is valid only when renderer version, viewport text AND state signature all match")
    }

    // MARK: - snapshotStateSignature seam

    func test_stateSignature_differsWhenCanRenderFlips() {
        let blocked = TerminalSurface.snapshotStateSignature(
            outputPartial: false, outputPendingBytes: 0, historyWriteFailures: 0,
            renderBlockedReason: "window_detached", canRender: false)
        let live = TerminalSurface.snapshotStateSignature(
            outputPartial: false, outputPendingBytes: 0, historyWriteFailures: 0,
            renderBlockedReason: nil, canRender: true)
        XCTAssertNotEqual(blocked, live,
            "a render-gate transition (canRender / blockedReason) must change the signature so the snapshot is rebuilt with fresh diagnostics")
    }

    func test_stateSignature_differsWhenPendingBytesChange() {
        let a = TerminalSurface.snapshotStateSignature(
            outputPartial: false, outputPendingBytes: 0, historyWriteFailures: 0,
            renderBlockedReason: nil, canRender: true)
        let b = TerminalSurface.snapshotStateSignature(
            outputPartial: false, outputPendingBytes: 128, historyWriteFailures: 0,
            renderBlockedReason: nil, canRender: true)
        XCTAssertNotEqual(a, b, "a change in pending bytes must invalidate the cached snapshot")
    }

    func test_stateSignature_stableForIdenticalState() {
        let a = TerminalSurface.snapshotStateSignature(
            outputPartial: true, outputPendingBytes: 9, historyWriteFailures: 1,
            renderBlockedReason: "parking_window", canRender: false)
        let b = TerminalSurface.snapshotStateSignature(
            outputPartial: true, outputPendingBytes: 9, historyWriteFailures: 1,
            renderBlockedReason: "parking_window", canRender: false)
        XCTAssertEqual(a, b, "identical state must yield an identical signature so the hot path still hits the cache")
    }
}
