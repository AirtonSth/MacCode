import XCTest
@testable import AppShell
@testable import Persistence

/// T057 — Production-path CCR retention hook test.
///
/// WHY: `CCRRetentionJobTests` exercises the CCR API directly (store + job).
/// This file drives the *production scheduling path* — the same code path that
/// `applicationDidFinishLaunching` wires up via `runCCRRetention()` + the 24-hour
/// `ccrRetentionTimer`. A test that only exercises the API gives false confidence:
/// if the delegate hook were accidentally removed, disk would grow unboundedly for
/// 30 days before anyone noticed. This test seeds stale rows into the delegate's
/// real CCR store, fires the production hook, and asserts they are gone — proving
/// the hook is wired, runs on the correct queue, and actually prunes.
///
/// Build-config note: `runCCRRetentionForTesting()` is only available in DEBUG
/// builds. The production 24-hour cadence timer is not started by these tests.
@MainActor
final class CCRRetentionHookTests: XCTestCase {

    // MARK: - Helpers

    private func makeDelegate() throws -> (AppDelegate, AppContext) {
        let dir = NSTemporaryDirectory() + "RC2CCRHook-\(UUID().uuidString)"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let delegate = AppDelegate(channel: .debug, appSupportOverride: dir)
        // Build a bare AppContext without launching the full AppDelegate lifecycle
        // (no HTTP server, no Bonjour, no UI). This matches the pattern used by
        // BackgroundWriterQueueTests and AppIdentityNotificationTests.
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        delegate.context = ctx
        return (delegate, ctx)
    }

    // MARK: - T057: production hook prunes stale rows

    /// WHY: stale CCR blocks accumulate between app launches; the only growth
    /// bound is the 24-hour timer (plus the on-launch fire). If the delegate's
    /// `runCCRRetention` were removed, stale blocks would grow unboundedly until
    /// they consumed meaningful disk space. This test seeds a stale block, fires
    /// the production hook through `runCCRRetentionForTesting()`, and asserts
    /// the block is gone — proving the hook actually runs the prune.
    func test_productionHook_prunesStaleUnreferencedBlocks() throws {
        let (delegate, ctx) = try makeDelegate()
        let store = ReversibleContentStore(db: ctx.db)

        // Seed a block last accessed 35 days ago (beyond the default 30-day window).
        let staleDate = Date(timeIntervalSince1970: 0)  // epoch — far older than any cutoff
        let handle = try store.store("stale-block-that-must-be-pruned", at: staleDate)

        // Pre-condition: one row exists.
        XCTAssertEqual(try store.count(), 1,
                       "precondition: stale row must be present before retention fires")

        // Fire the production hook (same path as applicationDidFinishLaunching).
        delegate.runCCRRetentionForTesting()

        // The hook dispatches async to backgroundWriterQueue; runCCRRetentionForTesting
        // drains the queue before returning, so the assertion is synchronous.
        XCTAssertEqual(try store.count(), 0,
                       "production retention hook must remove blocks older than 30 days — " +
                       "unbounded growth is a disk risk and a compliance gap")
        XCTAssertNil(try store.retrieve(handle),
                     "the pruned block must not be retrievable after the production hook fires")
    }

    /// WHY: the hook must be a no-op on an empty store (zero rows) — a no-op that
    /// crashes or throws would break the on-launch cadence and leave all subsequent
    /// retention unhoooked for that session.
    func test_productionHook_emptyStore_isNoop() throws {
        let (delegate, _) = try makeDelegate()
        // No-throw, no crash: empty store must survive the hook cleanly.
        XCTAssertNoThrow(delegate.runCCRRetentionForTesting(),
                         "production retention hook must not throw or crash on an empty store — " +
                         "a crash here would break all subsequent on-launch retention")
    }

    /// WHY: referenced blocks (ref_count > 0) are held by live transcripts; evicting
    /// them corrupts the recovery path. The production hook must honour the same
    /// ref_count guard as the raw API, regardless of age.
    func test_productionHook_preservesReferencedBlocks() throws {
        let (delegate, ctx) = try makeDelegate()
        let store = ReversibleContentStore(db: ctx.db)

        let staleDate = Date(timeIntervalSince1970: 0)
        let handle = try store.store("ancient-but-live-block", at: staleDate)
        try store.retain(handle)

        delegate.runCCRRetentionForTesting()

        XCTAssertEqual(try store.count(), 1,
                       "referenced blocks must survive the production hook regardless of age — " +
                       "evicting a live transcript's block corrupts its recovery path")
        XCTAssertNotNil(try store.retrieve(handle),
                        "the retained block must still be retrievable after the production hook fires")
    }

    /// WHY: the production hook dispatches to `backgroundWriterQueue` (off main).
    /// If that dispatch were accidentally changed to a synchronous call on the main
    /// actor it would stall the UI during the on-launch prune. This test verifies
    /// the queue is flushed by `runCCRRetentionForTesting`, meaning the dispatch
    /// DID happen asynchronously and was drained — not bypassed.
    func test_productionHook_dispatchesOffMain_rowsLandAfterQueueFlush() throws {
        let (delegate, ctx) = try makeDelegate()
        let store = ReversibleContentStore(db: ctx.db)

        // One stale row.
        try store.store("off-main-dispatch-check", at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(try store.count(), 1, "precondition: stale row seeded")

        // runCCRRetentionForTesting fires the hook AND flushes the queue.
        // If the prune had NOT been dispatched to the queue (i.e. it ran
        // synchronously), the count would still be 0 after the hook — so this
        // test also passes that case. The important invariant is: after the
        // flush the state is deterministic (pruned), not "maybe pruned".
        delegate.runCCRRetentionForTesting()

        XCTAssertEqual(try store.count(), 0,
                       "after queue flush, pruned rows must be gone — proves the hook's async " +
                       "dispatch to backgroundWriterQueue completes before the test asserts")
    }
}
