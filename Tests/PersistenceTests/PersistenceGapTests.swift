import XCTest
@testable import Persistence
import CoreModel

/// Tests for persistence-layer gaps identified in the mac-persistence audit.
///
/// Coverage:
///   T015 — PromptHistoryStore hard cap + overflow trim
///   T016 — PromptHistoryStore workspace isolation + delete-on-workspace-remove
///   T019 — AgentCustomModelStore index operations (update/remove/bounds/dedup)
///   T022 — verify() touches last_seen_at; rejects revoked device even with valid hash
///   T023 — Pairing request TTL boundary: expiresAt == now is expired (isExpired uses <=)
///   T024 — audit_log rows written for every pairing action
///   T037 — NotificationRepository round-trip + dismissed-exclusion + limit cap
final class PersistenceGapTests: XCTestCase {

    // MARK: - Helpers

    private func makeDB() throws -> SQLiteDB {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return db
    }

    private func freshTrustRepo() throws -> DeviceTrustRepository {
        let tmp = NSTemporaryDirectory() + "trust-" + UUID().uuidString
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return DeviceTrustRepository(db: db)
    }

    // MARK: - T015: PromptHistoryStore hard cap and overflow trim

    /// WHY: the PromptHistoryStore.limit cap is the single piece of policy keeping the settings
    /// table from growing unboundedly. If save() or load() lets more than that many
    /// entries through, long-running apps accumulate unbounded JSON.
    func test_T015_promptHistory_cap_saveTrimsToBoundary() throws {
        let db = try makeDB()
        let store = PromptHistoryStore(db: db)
        let wid = WorkspaceID(UUID())

        // Save more than the cap; only the newest capped slice must survive.
        let entries = (0..<(PromptHistoryStore.limit + 5)).map { "prompt-\($0)" }
        store.save(entries, workspaceID: wid)

        let loaded = store.load(workspaceID: wid)
        XCTAssertEqual(loaded.count, PromptHistoryStore.limit,
            "save must cap history at PromptHistoryStore.limit so the settings row cannot grow unboundedly")
        XCTAssertEqual(loaded, Array(entries.suffix(PromptHistoryStore.limit)),
            "the retained entries must be the newest prompts, not the oldest prompts")
    }

    func test_T015_promptHistory_cap_loadTrimsLegacyOversizedBlob() throws {
        // A blob written by a buggy or future build over the cap must be
        // trimmed on load so the app never operates on an oversized buffer.
        let db = try makeDB()
        let store = PromptHistoryStore(db: db)
        let wid = WorkspaceID(UUID())

        let oversized = (0..<(PromptHistoryStore.limit + 10)).map { "p\($0)" }
        let json = (try? JSONEncoder().encode(oversized))
            .flatMap { String(data: $0, encoding: .utf8) }!
        try SettingsRepository(db: db).set("agent_prompt_history.\(wid.value.uuidString)", json)

        let loaded = store.load(workspaceID: wid)
        XCTAssertEqual(loaded.count, PromptHistoryStore.limit,
            "load must apply suffix(PromptHistoryStore.limit) so an oversized legacy blob is trimmed on first access")
        XCTAssertEqual(loaded, Array(oversized.suffix(PromptHistoryStore.limit)),
            "trimmed load must keep the newest entries, matching save semantics")
    }

    // MARK: - T016: PromptHistoryStore workspace isolation + delete-on-remove

    /// WHY: each workspace's history is stored under a distinct key. A bug in the
    /// key-derivation or a missing namespace separator can silently cross-pollute
    /// two workspaces' histories, which is both a privacy issue and a data-loss bug.
    func test_T016_promptHistory_workspaceIsolation() throws {
        let db = try makeDB()
        let store = PromptHistoryStore(db: db)
        let wA = WorkspaceID(UUID())
        let wB = WorkspaceID(UUID())

        store.save(["alpha", "beta"], workspaceID: wA)
        store.save(["gamma", "delta"], workspaceID: wB)

        XCTAssertEqual(store.load(workspaceID: wA), ["alpha", "beta"],
            "workspace A's history must be isolated from workspace B")
        XCTAssertEqual(store.load(workspaceID: wB), ["gamma", "delta"],
            "workspace B's history must be isolated from workspace A")
    }

    func test_T016_promptHistory_unicodeRoundTrip() throws {
        let db = try makeDB()
        let store = PromptHistoryStore(db: db)
        let wid = WorkspaceID(UUID())

        let emoji = "\u{1F600} hello\nworld"
        store.save([emoji], workspaceID: wid)

        let loaded = store.load(workspaceID: wid)
        XCTAssertEqual(loaded, [emoji],
            "multi-line and emoji prompts must round-trip through JSON encoding without corruption")
    }

    /// WHY (GAP 8): when a workspace is deleted its prompt-history key must also
    /// be deleted. Without delete(), user-typed prompts persist on disk
    /// indefinitely (privacy) and the settings table grows monotonically.
    func test_T016_promptHistory_delete_removesKeyForWorkspace() throws {
        let db = try makeDB()
        let store = PromptHistoryStore(db: db)
        let wid = WorkspaceID(UUID())

        store.save(["saved prompt"], workspaceID: wid)
        XCTAssertFalse(store.load(workspaceID: wid).isEmpty, "pre-condition: history is present")

        try store.delete(workspaceID: wid)

        XCTAssertTrue(store.load(workspaceID: wid).isEmpty,
            "delete(workspaceID:) must remove the history row so deleted workspaces leave no residue")
    }

    func test_T016_promptHistory_delete_doesNotAffectOtherWorkspaces() throws {
        let db = try makeDB()
        let store = PromptHistoryStore(db: db)
        let wA = WorkspaceID(UUID())
        let wB = WorkspaceID(UUID())

        store.save(["keep me"], workspaceID: wA)
        store.save(["delete me"], workspaceID: wB)

        try store.delete(workspaceID: wB)

        XCTAssertEqual(store.load(workspaceID: wA), ["keep me"],
            "delete(workspaceID:) must not affect other workspaces' history rows")
        XCTAssertTrue(store.load(workspaceID: wB).isEmpty,
            "the deleted workspace's history must be gone")
    }

    // MARK: - T019: AgentCustomModelStore index operations

    private func freshCustomModelStore() throws -> (AgentCustomModelStore, SQLiteDB) {
        let db = try makeDB()
        return (AgentCustomModelStore(db: db), db)
    }

    /// WHY: update/remove with an out-of-bounds index must be silent no-ops so
    /// a stale UI index (e.g. after a concurrent save from another surface) does
    /// not crash or corrupt the list.
    func test_T019_customModelStore_updateOutOfBounds_isNoOp() throws {
        let (store, _) = try freshCustomModelStore()
        store.add("gpt-4o", provider: .codex)

        store.update(provider: .codex, index: 99, value: "new-model")

        XCTAssertEqual(store.list(provider: .codex), ["gpt-4o"],
            "update with an out-of-bounds index must be a silent no-op")
    }

    func test_T019_customModelStore_removeOutOfBounds_isNoOp() throws {
        let (store, _) = try freshCustomModelStore()
        store.add("claude-3", provider: .codex)

        store.remove(provider: .codex, index: 99)

        XCTAssertEqual(store.list(provider: .codex), ["claude-3"],
            "remove with an out-of-bounds index must be a silent no-op")
    }

    func test_T019_customModelStore_updateToEmpty_removesRow() throws {
        let (store, _) = try freshCustomModelStore()
        store.add("model-x", provider: .codex)
        XCTAssertEqual(store.list(provider: .codex).count, 1)

        store.update(provider: .codex, index: 0, value: "   ")

        XCTAssertTrue(store.list(provider: .codex).isEmpty,
            "updating to empty/whitespace must remove the entry so the list never holds blank models")
    }

    func test_T019_customModelStore_deduplicates() throws {
        let (store, _) = try freshCustomModelStore()
        store.add("model-a", provider: .codex)
        store.add("model-a", provider: .codex)
        store.add("  model-a  ", provider: .codex)

        XCTAssertEqual(store.list(provider: .codex), ["model-a"],
            "add must deduplicate so the same model is never listed twice after whitespace normalization")
    }

    func test_T019_customModelStore_providerIsolation() throws {
        let (store, _) = try freshCustomModelStore()
        store.add("model-codex", provider: .codex)
        store.add("model-claude", provider: .claude)

        XCTAssertEqual(store.list(provider: .codex), ["model-codex"])
        XCTAssertEqual(store.list(provider: .claude), ["model-claude"],
            "custom models are stored per-provider and must not bleed across providers")
    }

    // MARK: - T022: verify() touches last_seen_at; rejects revoked device

    /// WHY: last_seen_at is the source of truth for "device last active" in the
    /// Settings panel. A verify() that does not update it makes the display stale.
    func test_T022_verify_touchesLastSeenAt() throws {
        let repo = try freshTrustRepo()
        let code = try repo.createPairingCode(ttlSeconds: 60)
        let (_, token) = try XCTUnwrap(try repo.redeemPairingCode(code.code, deviceName: "dev"))

        // First verify seeds last_seen_at.
        let v1 = try XCTUnwrap(try repo.verify(token: token))
        let seenAfterFirst = v1.lastSeenAt

        // Wait a tiny bit (sub-second granularity via Date), then verify again.
        // We cannot sleep without the test harness complaining, so we reopen and
        // verify twice in sequence — the second call happens after the first.
        let v2 = try XCTUnwrap(try repo.verify(token: token))
        let seenAfterSecond = try XCTUnwrap(v2.lastSeenAt,
            "verify() must set last_seen_at so the devices panel shows when the phone was last active")

        // The second verify must record a timestamp >= the first.
        if let first = seenAfterFirst {
            XCTAssertGreaterThanOrEqual(seenAfterSecond, first,
                "last_seen_at must be monotonically non-decreasing across consecutive verify() calls")
        }
    }

    func test_T022_verify_rejectsRevokedDeviceEvenWithValidHash() throws {
        // WHY: verify() must check revoked_at. A revoked device must not be able
        // to authenticate even with its original valid token — that would defeat
        // the entire revocation mechanism.
        let repo = try freshTrustRepo()
        let code = try repo.createPairingCode(ttlSeconds: 60)
        let (trust, token) = try XCTUnwrap(try repo.redeemPairingCode(code.code, deviceName: "phone"))

        try repo.revoke(id: trust.id)

        XCTAssertNil(try repo.verify(token: token),
            "verify() must return nil for a revoked device even when the token hash matches, so revocation actually removes access")
    }

    // MARK: - T023: Pairing request TTL boundary

    /// WHY: isExpired uses `expiresAt <= Date()`, meaning a request at EXACTLY
    /// the expiry moment is already expired. approvePairingRequest must respect
    /// this boundary or an attacker can exploit a narrow race window after TTL.
    func test_T023_pairingRequest_exactExpiry_isExpired() throws {
        let repo = try freshTrustRepo()
        // TTL=-0 means expiresAt = now, so <= now is true immediately.
        let req = try repo.createPairingRequest(deviceName: "dev", ttlSeconds: 0)

        let fetched = try XCTUnwrap(try repo.pairingRequest(id: req.id))
        XCTAssertEqual(fetched.effectiveStatus, "expired",
            "a request with TTL=0 must report effectiveStatus=expired at creation time (boundary: expiresAt <= now)")
        XCTAssertNil(try repo.approvePairingRequest(id: req.id),
            "approvePairingRequest must reject a request whose expiresAt == now, not just expiresAt < now")
    }

    // MARK: - T024: audit_log written for every pairing action

    /// WHY: audit_log is the only trace of pairing events for security auditing.
    /// The try? wrappers in LocalAuthAdapter mean a regression is invisible at
    /// runtime. This test drives the repo-level audit method directly and asserts
    /// rows are present and distinguishable.
    func test_T024_auditLog_recordsAllPairingActions() throws {
        let repo = try freshTrustRepo()

        // Drive every pairing action in sequence.
        try repo.audit(actor: "server", action: "pairing.request", detail: "device=PhoneA")
        try repo.audit(actor: "user",   action: "pairing.approve", detail: "device=PhoneA")
        try repo.audit(actor: "server", action: "pairing.create",  detail: nil)
        try repo.audit(actor: "user",   action: "device.revoke",   detail: "id=abc")
        try repo.audit(actor: nil,      action: "pairing.deny",    detail: "id=xyz")

        let entries = try repo.listAuditLog(limit: 50)
        XCTAssertEqual(entries.count, 5,
            "every audit() call must produce a row — a missing row means a pairing event is invisible to security review")

        // Entries are newest-first; reverse to check insertion order.
        let actions = entries.reversed().map(\.action)
        XCTAssertEqual(actions, [
            "pairing.request", "pairing.approve", "pairing.create", "device.revoke", "pairing.deny"
        ], "audit rows must be returned newest-first and must preserve action labels exactly")
    }

    func test_T024_auditLog_limit_cappsResults() throws {
        let repo = try freshTrustRepo()
        for i in 0..<10 {
            try repo.audit(actor: nil, action: "test.\(i)", detail: nil)
        }

        let capped = try repo.listAuditLog(limit: 3)
        XCTAssertEqual(capped.count, 3,
            "listAuditLog(limit:) must cap results at the given limit so callers never pull unbounded rows")
    }

    /// WHY: the Subagents rail refreshes on every send and every 2s poll. It only
    /// needs `detail`, but reading through `listAuditLog` parsed an ISO8601 `ts`
    /// for every row in the table and filtered actions in Swift — ~1.3s of blocked
    /// MainActor, growing with the whole audit log. This asserts the details query
    /// selects ONLY the requested actions, so an unrelated action can never be
    /// loaded and decoded just to be thrown away again.
    func test_auditLogDetails_returnsOnlyRequestedActions_newestFirst() throws {
        let repo = try freshTrustRepo()
        try repo.audit(actor: nil, action: "agent.orchestration.admitted", detail: "admit-1")
        try repo.audit(actor: nil, action: "pairing.request", detail: "unrelated")
        try repo.audit(actor: nil, action: "agent.orchestration.ledger", detail: "ledger-1")
        try repo.audit(actor: nil, action: "agent.orchestration.admitted", detail: "admit-2")

        let details = try repo.listAuditLogDetails(
            actions: ["agent.orchestration.admitted", "agent.orchestration.ledger"],
            limit: 50
        )
        XCTAssertEqual(details, ["admit-2", "ledger-1", "admit-1"],
            "details must be newest-first and exclude non-requested actions entirely — filtering in Swift after the read is what made the Subagents refresh scale with the whole audit log")
    }

    /// WHY: the limit is the only bound on how much the MainActor refresh decodes.
    /// It must cap rows AFTER the action filter, so unrelated rows cannot consume
    /// the budget and silently starve the caller of real receipts.
    func test_auditLogDetails_limitCountsOnlyMatchingActions() throws {
        let repo = try freshTrustRepo()
        for index in 0..<5 {
            try repo.audit(actor: nil, action: "noise.\(index)", detail: "noise-\(index)")
            try repo.audit(actor: nil, action: "agent.orchestration.ledger", detail: "ledger-\(index)")
        }

        let details = try repo.listAuditLogDetails(actions: ["agent.orchestration.ledger"], limit: 3)
        XCTAssertEqual(details, ["ledger-4", "ledger-3", "ledger-2"],
            "limit must apply to matching rows only; counting interleaved unrelated rows would drop real receipts the rail needs")
    }

    /// WHY: an empty action list must not build `IN ()` (invalid SQL) nor degrade
    /// into an unfiltered whole-table read.
    func test_auditLogDetails_emptyActionsReturnsEmptyWithoutReadingTable() throws {
        let repo = try freshTrustRepo()
        try repo.audit(actor: nil, action: "agent.orchestration.ledger", detail: "ledger-1")

        XCTAssertEqual(try repo.listAuditLogDetails(actions: [], limit: 50), [],
            "no requested actions must mean no rows — never a fallback to an unfiltered scan")
    }

    // MARK: - T037: NotificationRepository round-trip + dismissed-exclusion + limit

    /// WHY: dismissed rows are excluded by the WHERE clause; if the exclusion
    /// breaks, dismissed notifications resurface in the notification center and
    /// the unreadOnly filter produces false positives. Zero tests previously
    /// covered NotificationRepository.
    func test_T037_notifications_insertAndList_excludesDismissed() throws {
        let db = try makeDB()
        let repo = NotificationRepository(db: db)

        let n1 = AppNotification(title: "Active notification")
        let n2 = AppNotification(title: "To be dismissed")
        try repo.insert(n1)
        try repo.insert(n2)

        try repo.dismiss(id: n2.id)

        let listed = try repo.list()
        XCTAssertEqual(listed.count, 1,
            "list() must exclude dismissed notifications so the notification center shows only active items")
        XCTAssertEqual(listed.first?.id, n1.id)
    }

    func test_T037_notifications_unreadOnly_filtersRead() throws {
        let db = try makeDB()
        let repo = NotificationRepository(db: db)

        let unread = AppNotification(title: "Unread")
        let read   = AppNotification(title: "Already read")
        try repo.insert(unread)
        try repo.insert(read)
        try repo.markRead(id: read.id)

        let result = try repo.list(unreadOnly: true)
        XCTAssertEqual(result.count, 1, "unreadOnly filter must exclude read notifications")
        XCTAssertEqual(result.first?.id, unread.id)
    }

    func test_T037_notifications_list_limit_preventsUnboundedGrowth() throws {
        // WHY (GAP 10): list() had no LIMIT. On a long-lived install with thousands
        // of historical undismissed notifications the query loads them all into memory.
        // The limit parameter caps this. This test inserts more than the cap and verifies
        // only `limit` rows are returned.
        let db = try makeDB()
        let repo = NotificationRepository(db: db)

        for i in 0..<10 {
            try repo.insert(AppNotification(title: "n\(i)"))
        }

        let capped = try repo.list(limit: 5)
        XCTAssertEqual(capped.count, 5,
            "list(limit:) must cap returned rows so callers cannot inadvertently pull unbounded notifications")
    }

    func test_T037_notifications_workspaceFilter_isolates() throws {
        let db = try makeDB()
        let repo = NotificationRepository(db: db)
        let wA = WorkspaceID(UUID())
        let wB = WorkspaceID(UUID())

        try repo.insert(AppNotification(workspaceId: wA, title: "for A"))
        try repo.insert(AppNotification(workspaceId: wB, title: "for B"))
        try repo.insert(AppNotification(title: "global"))

        let forA = try repo.list(workspaceId: wA)
        XCTAssertEqual(forA.count, 1)
        XCTAssertEqual(forA.first?.title, "for A",
            "workspace filter must isolate notifications to the requested workspace")
    }
}
