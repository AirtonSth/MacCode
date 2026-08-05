import XCTest
import CoreModel
@testable import Persistence

final class TokenSaverT003PersistenceTests: XCTestCase {
    private func makeDB() throws -> SQLiteDB {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return db
    }

    private let disk = TokenSaverRecoveryDiskSnapshot(
        freeBytes: 20 * 1_024 * 1_024 * 1_024,
        totalBytes: 100 * 1_024 * 1_024 * 1_024
    )

    private func scope(
        project: String = "p",
        thread: String = "t",
        provider: String = "claude",
        attempt: String = "a"
    ) -> TokenSaverPersistentScope {
        TokenSaverPersistentScope(workspaceID: "w", projectID: project, threadID: thread, provider: provider, attemptID: attempt)
    }

    func test_schema45_quarantinesLegacyRowsAndCreatesProgramTables() throws {
        let steps = Schema.steps
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Array(steps.prefix(44)))
        try db.execute("""
            INSERT INTO rc_reversible_content
                (handle, original, sha256, byte_count, ref_count, created_at_ms, last_access_ms)
            VALUES ('legacy-hash', X'736563726574', 'legacy-hash', 6, 0, 1, 1);
        """)

        try Schema.migrate(db)

        XCTAssertGreaterThanOrEqual(Schema.currentVersion, Schema.checkpointListSchemaVersion)
        XCTAssertEqual(try scalar(db, sql: "SELECT MAX(version) FROM schema_meta;"), Schema.currentVersion)
        XCTAssertEqual(try count(db, table: "rc_reversible_content"), 1, "migration preserves legacy bytes for explicit user-approved reattachment")
        XCTAssertEqual(try count(db, table: "token_saver_recovery_objects"), 0, "legacy hashes never receive fabricated scope or capability")
        XCTAssertEqual(try count(db, table: "token_saver_attempts"), 0)
        XCTAssertEqual(try count(db, table: "token_saver_lane_state"), 0)
    }

    func test_scopedStore_requiresExactScopeAndCapability_notRawIntegrityHash() throws {
        let store = TokenSaverScopedRecoveryStore(db: try makeDB())
        let original = Data("scope-bound secret".utf8)
        let prepared = try store.prepare(
            original,
            scope: scope(),
            operationID: "scope-op",
            expiresAt: Date().addingTimeInterval(600),
            disk: disk
        )

        XCTAssertNotEqual(prepared.capability, prepared.integritySHA256)
        XCTAssertEqual(try store.retrieve(capability: prepared.capability, scope: scope()), original)
        XCTAssertNil(try store.retrieve(capability: prepared.integritySHA256, scope: scope()), "raw SHA proves integrity only")
        XCTAssertNil(try store.retrieve(capability: prepared.capability, scope: scope(project: "other")))
        XCTAssertNil(try store.retrieve(capability: prepared.capability, scope: scope(thread: "other")))
        XCTAssertNil(try store.retrieve(capability: prepared.capability, scope: scope(provider: "codex")))
        XCTAssertNil(try store.retrieve(capability: prepared.capability, scope: scope(attempt: "other")))
    }

    func test_scopedStore_performsDurableReadBackBeforeReturningPreparedCapability() throws {
        let store = TokenSaverScopedRecoveryStore(db: try makeDB())
        let original = Data(repeating: 0xAB, count: 8_192)
        let prepared = try store.prepare(original, scope: scope(), operationID: "readback-op", expiresAt: nil, disk: disk)

        XCTAssertEqual(prepared.state, .prepared)
        XCTAssertTrue(prepared.readBackVerified)
        XCTAssertEqual(try store.retrieve(capability: prepared.capability, scope: scope()), original)
    }

    func test_scopedStore_retryReusesObjectAndIdempotencyButRotatesCapability() throws {
        let db = try makeDB()
        let store = TokenSaverScopedRecoveryStore(db: db)
        let original = Data("stable retry".utf8)
        let first = try store.prepare(original, scope: scope(), operationID: "stable-operation", expiresAt: nil, disk: disk)
        let retry = try store.prepare(original, scope: scope(), operationID: "stable-operation", expiresAt: nil, disk: disk)

        XCTAssertEqual(retry.objectID, first.objectID)
        XCTAssertEqual(retry.idempotencyKey, first.idempotencyKey)
        XCTAssertNotEqual(retry.capability, first.capability, "a retry mints a fresh capability and revokes the prior bearer")
        XCTAssertNil(try store.retrieve(capability: first.capability, scope: scope()))
        XCTAssertEqual(try store.retrieve(capability: retry.capability, scope: scope()), original)
        XCTAssertEqual(try scalar(db, sql: "SELECT COUNT(*) FROM token_saver_recovery_objects;"), 1)
        XCTAssertEqual(try scalar(db, sql: "SELECT COUNT(*) FROM token_saver_recovery_capabilities WHERE capability_hash LIKE 'rcv1.%';"), 0,
                       "only a one-way capability hash may be persisted")
        XCTAssertThrowsError(
            try store.prepare(Data("different bytes".utf8), scope: scope(), operationID: "stable-operation", expiresAt: nil, disk: disk)
        ) { XCTAssertEqual($0 as? TokenSaverRecoveryStoreError, .idempotencyConflict) }
    }

    func test_scopedStore_terminalRetryPreservesEmittedCapabilityAndIndependentInvocationGetsNewMarker() throws {
        let db = try makeDB()
        let store = TokenSaverScopedRecoveryStore(db: db)
        let original = Data("same independent payload".utf8)
        let first = try store.prepare(
            original, scope: scope(), operationID: "same-retry",
            invocationID: "invocation-a", expiresAt: nil, disk: disk
        )
        XCTAssertTrue(try store.markDelivered(
            capability: first.capability, scope: scope(), idempotencyKey: first.idempotencyKey,
            outcome: .sentUnknown
        ))
        XCTAssertEqual(
            try store.invocationState(
                scope: scope(), invocationID: "invocation-a", operationID: "same-retry"
            ),
            .init(state: .delivered, transportOutcome: .sentUnknown)
        )
        XCTAssertThrowsError(try store.prepare(
            original, scope: scope(), operationID: "same-retry",
            invocationID: "invocation-a", expiresAt: nil, disk: disk
        )) { XCTAssertEqual($0 as? TokenSaverRecoveryStoreError, .operationUnavailable) }
        XCTAssertEqual(try store.retrieve(capability: first.capability, scope: scope()), original)

        let independent = try store.prepare(
            original, scope: scope(), operationID: "same-retry",
            invocationID: "invocation-b", expiresAt: nil, disk: disk
        )
        XCTAssertNotEqual(independent.objectID, first.objectID)
        XCTAssertNotEqual(independent.capability, first.capability)
        XCTAssertEqual(try store.retrieve(capability: first.capability, scope: scope()), original)
        XCTAssertEqual(try store.retrieve(capability: independent.capability, scope: scope()), original)
    }

    func test_scopedStore_detectsCorruptionAndDoesNotReturnTamperedBytes() throws {
        let db = try makeDB()
        let store = TokenSaverScopedRecoveryStore(db: db)
        try TokenSaverLaneStateRepository(db: db).upsert(.init(
            projectID: "p", lane: "semantic_prose", state: "promoted",
            reason: "scorecard_passed", evidenceLevel: "provider_usage",
            ownerRole: "owner", permissionBoundary: "project",
            retentionDays: 7, optedOut: false, killSwitchActive: false
        ))
        let prepared = try store.prepare(Data("original".utf8), scope: scope(), operationID: "corrupt-op", expiresAt: nil, disk: disk)
        try db.execute("UPDATE token_saver_recovery_objects SET original = X'74616D7065726564' WHERE id = '\(prepared.objectID)';")

        XCTAssertThrowsError(try store.retrieve(capability: prepared.capability, scope: scope())) { error in
            XCTAssertEqual(error as? TokenSaverRecoveryStoreError, .integrityMismatch)
        }
        let lane = try TokenSaverLaneStateRepository(db: db).get(projectID: "p", lane: "semantic_prose")
        XCTAssertEqual(lane?.state, "off")
        XCTAssertEqual(lane?.reason, "integrity_failure")
        XCTAssertEqual(lane?.killSwitchActive, true)
        XCTAssertEqual(try scalar(db, sql: "SELECT COUNT(*) FROM token_saver_audit_events WHERE event_kind = 'integrity_failure' AND project_id = 'p';"), 1)
    }

    func test_scopedStore_enforcesObjectThreadProjectGlobalAndDiskAdmission() throws {
        let db = try makeDB()
        let store = TokenSaverScopedRecoveryStore(db: db)
        XCTAssertThrowsError(
            try store.prepare(
                Data(count: Int(TokenSaverRecoveryLimits.maxObjectBytes + 1)),
                scope: scope(),
                operationID: "oversize-op",
                expiresAt: nil,
                disk: disk
            )
        ) { XCTAssertEqual($0 as? TokenSaverRecoveryStoreError, .objectQuotaExceeded) }

        let lowDisk = TokenSaverRecoveryDiskSnapshot(
            freeBytes: TokenSaverRecoveryLimits.minimumFreeDiskBytes - 1,
            totalBytes: 100 * 1_024 * 1_024 * 1_024
        )
        XCTAssertThrowsError(
            try store.prepare(Data("x".utf8), scope: scope(), operationID: "low-disk-op", expiresAt: nil, disk: lowDisk)
        ) { XCTAssertEqual($0 as? TokenSaverRecoveryStoreError, .diskFloorReached) }

        let exactFloor = TokenSaverRecoveryDiskSnapshot(
            freeBytes: TokenSaverRecoveryLimits.minimumFreeDiskBytes + 1,
            totalBytes: 10 * 1_024 * 1_024 * 1_024
        )
        _ = try store.prepare(Data("x".utf8), scope: scope(attempt: "floor-equal"), operationID: "floor-equal-op", expiresAt: nil, disk: exactFloor)
        XCTAssertThrowsError(
            try store.prepare(Data("xx".utf8), scope: scope(attempt: "floor-below"), operationID: "floor-below-op", expiresAt: nil, disk: exactFloor)
        ) { XCTAssertEqual($0 as? TokenSaverRecoveryStoreError, .diskFloorReached) }

        try db.execute("""
            INSERT INTO token_saver_recovery_objects
                (id, workspace_id, project_id, thread_id, provider, attempt_id,
                 integrity_sha256, original, byte_count, state, expires_at_ms,
                 tombstoned_at_ms, created_at_ms, last_access_ms)
            VALUES ('cross-workspace-project-usage', 'other-workspace', 'shared-project',
                    'other-thread', 'codex', 'other-attempt', '', X'',
                    \(TokenSaverRecoveryLimits.maxProjectBytes - 1), 'prepared', NULL, NULL, 1, 1);
        """)
        XCTAssertThrowsError(
            try store.prepare(
                Data("xx".utf8),
                scope: TokenSaverPersistentScope(
                    workspaceID: "second-workspace", projectID: "shared-project",
                    threadID: "new-thread", provider: "codex", attemptID: "new-attempt"
                ),
                operationID: "project-quota-op",
                expiresAt: nil,
                disk: disk
            )
        ) { XCTAssertEqual($0 as? TokenSaverRecoveryStoreError, .projectQuotaExceeded) }
    }

    func test_scopedStore_expiryBoundaryDeniesReadsMutationsReplayAndReferences() throws {
        let store = TokenSaverScopedRecoveryStore(db: try makeDB())
        let expires = Date(timeIntervalSince1970: 10)
        let prepared = try store.prepare(
            Data("expires exactly".utf8), scope: scope(), operationID: "expiry-boundary-op", expiresAt: expires,
            disk: disk, now: Date(timeIntervalSince1970: 1)
        )

        XCTAssertNil(try store.retrieve(capability: prepared.capability, scope: scope(), now: expires))
        XCTAssertNil(try store.outboxState(capability: prepared.capability, scope: scope(), idempotencyKey: prepared.idempotencyKey, now: expires))
        XCTAssertFalse(try store.mayReplayMutation(capability: prepared.capability, scope: scope(), idempotencyKey: prepared.idempotencyKey, now: expires))
        XCTAssertFalse(try store.markDelivered(capability: prepared.capability, scope: scope(), idempotencyKey: prepared.idempotencyKey, outcome: .sentUnknown, now: expires))
        XCTAssertFalse(try store.ack(capability: prepared.capability, scope: scope(), idempotencyKey: prepared.idempotencyKey, now: expires))
        XCTAssertNil(try store.attachReference(
            capability: prepared.capability, scope: scope(), ownerKind: "message",
            ownerID: "m", now: expires
        ))
    }

    func test_scopedStore_expiryAndDeletionDenyImmediatelyAndEraseContent() throws {
        let db = try makeDB()
        let store = TokenSaverScopedRecoveryStore(db: db)
        let expired = try store.prepare(
            Data("expired".utf8),
            scope: scope(attempt: "expired"),
            operationID: "expired-op",
            expiresAt: Date(timeIntervalSince1970: 10),
            disk: disk,
            now: Date(timeIntervalSince1970: 1)
        )
        XCTAssertNil(try store.retrieve(capability: expired.capability, scope: scope(attempt: "expired"), now: Date(timeIntervalSince1970: 11)))

        let live = try store.prepare(Data("delete me".utf8), scope: scope(), operationID: "delete-op", expiresAt: nil, disk: disk)
        XCTAssertEqual(try store.delete(scope: scope()), 1)
        XCTAssertNil(try store.retrieve(capability: live.capability, scope: scope()))

        let statement = try db.prepare("SELECT length(original), tombstoned_at_ms FROM token_saver_recovery_objects WHERE id = ?;")
        defer { statement.reset() }
        try statement.bind(1, live.objectID)
        XCTAssertTrue(try statement.step())
        XCTAssertEqual(statement.columnInt64(0), 0, "immediate tombstone must not retain deleted content")
        XCTAssertFalse(statement.columnIsNull(1))
    }

    func test_outboxTransitionsAreIdempotentAndAmbiguousMutationNeverReplays() throws {
        let store = TokenSaverScopedRecoveryStore(db: try makeDB())
        let prepared = try store.prepare(Data("payload".utf8), scope: scope(), operationID: "payload-op", expiresAt: nil, disk: disk)

        XCTAssertTrue(try store.markDelivered(capability: prepared.capability, scope: scope(), idempotencyKey: prepared.idempotencyKey, outcome: .acked))
        XCTAssertFalse(try store.markDelivered(capability: prepared.capability, scope: scope(), idempotencyKey: prepared.idempotencyKey, outcome: .acked), "duplicate delivery transition is a no-op")
        XCTAssertTrue(try store.ack(capability: prepared.capability, scope: scope(), idempotencyKey: prepared.idempotencyKey))
        XCTAssertEqual(try store.outboxState(capability: prepared.capability, scope: scope(), idempotencyKey: prepared.idempotencyKey), .acked)

        let ambiguous = try store.prepare(Data("mutation".utf8), scope: scope(attempt: "b"), operationID: "ambiguous-op", expiresAt: nil, disk: disk)
        XCTAssertTrue(try store.markDelivered(capability: ambiguous.capability, scope: scope(attempt: "b"), idempotencyKey: ambiguous.idempotencyKey, outcome: .sentUnknown))
        XCTAssertFalse(try store.mayReplayMutation(capability: ambiguous.capability, scope: scope(attempt: "b"), idempotencyKey: ambiguous.idempotencyKey))

        let safe = try store.prepare(Data("retry".utf8), scope: scope(attempt: "safe"), operationID: "safe-op", expiresAt: nil, disk: disk)
        XCTAssertTrue(try store.mayReplayMutation(capability: safe.capability, scope: scope(attempt: "safe"), idempotencyKey: safe.idempotencyKey))
        XCTAssertTrue(try store.markDelivered(capability: safe.capability, scope: scope(attempt: "safe"), idempotencyKey: safe.idempotencyKey, outcome: .notSent))
        XCTAssertEqual(try store.outboxState(capability: safe.capability, scope: scope(attempt: "safe"), idempotencyKey: safe.idempotencyKey), .prepared)
        XCTAssertTrue(try store.markDelivered(capability: safe.capability, scope: scope(attempt: "safe"), idempotencyKey: safe.idempotencyKey, outcome: .failed))
        XCTAssertTrue(try store.mayReplayMutation(capability: safe.capability, scope: scope(attempt: "safe"), idempotencyKey: safe.idempotencyKey))
        XCTAssertTrue(try store.markDelivered(capability: safe.capability, scope: scope(attempt: "safe"), idempotencyKey: safe.idempotencyKey, outcome: .sentUnknown))
        XCTAssertFalse(try store.mayReplayMutation(capability: safe.capability, scope: scope(attempt: "safe"), idempotencyKey: safe.idempotencyKey))
        XCTAssertFalse(try store.markDelivered(capability: safe.capability, scope: scope(attempt: "safe"), idempotencyKey: safe.idempotencyKey, outcome: .notSent))
    }

    func test_deleteScrubsIntegrityAndTerminalizesOutbox() throws {
        let db = try makeDB()
        let store = TokenSaverScopedRecoveryStore(db: db)
        let prepared = try store.prepare(Data("private".utf8), scope: scope(), operationID: "delete-terminal", expiresAt: nil, disk: disk)

        XCTAssertEqual(try store.delete(scope: scope()), 1)
        XCTAssertEqual(try scalar(db, sql: "SELECT COUNT(*) FROM token_saver_recovery_objects WHERE id = '\(prepared.objectID)' AND original = X'' AND integrity_sha256 = '' AND state = 'acked';"), 1)
        XCTAssertEqual(try scalar(db, sql: "SELECT COUNT(*) FROM token_saver_recovery_outbox WHERE object_id = '\(prepared.objectID)' AND state = 'acked' AND transport_outcome = 'acked';"), 1)
    }

    func test_discardAbandoned_isExactObjectIdempotentAndPreservesSiblingInSameScope() throws {
        let db = try makeDB()
        let store = TokenSaverScopedRecoveryStore(db: db)
        let abandoned = try store.prepare(
            Data("abandon me".utf8),
            scope: scope(),
            operationID: "abandon-op",
            expiresAt: nil,
            disk: disk
        )
        let sibling = try store.prepare(
            Data("keep me live".utf8),
            scope: scope(),
            operationID: "sibling-op",
            expiresAt: nil,
            disk: disk
        )
        XCTAssertTrue(try store.markDelivered(
            capability: abandoned.capability,
            scope: scope(),
            idempotencyKey: abandoned.idempotencyKey,
            outcome: .sentUnknown
        ))

        XCTAssertTrue(try store.discardAbandoned(
            capability: abandoned.capability,
            scope: scope(),
            idempotencyKey: abandoned.idempotencyKey
        ))
        XCTAssertTrue(
            try store.discardAbandoned(
                capability: abandoned.capability,
                scope: scope(),
                idempotencyKey: abandoned.idempotencyKey
            ),
            "discard must be idempotent for the same capability/scope/key"
        )
        XCTAssertFalse(
            try store.discardAbandoned(
                capability: abandoned.capability,
                scope: scope(project: "other"),
                idempotencyKey: abandoned.idempotencyKey
            ),
            "wrong five-field scope must not authorize discard"
        )
        XCTAssertFalse(
            try store.discardAbandoned(
                capability: abandoned.capability,
                scope: scope(),
                idempotencyKey: "wrong-key"
            ),
            "wrong idempotency key must not authorize discard"
        )

        XCTAssertNil(try store.retrieve(capability: abandoned.capability, scope: scope()))
        XCTAssertEqual(
            try store.retrieve(capability: sibling.capability, scope: scope()),
            Data("keep me live".utf8),
            "discard must never touch an unrelated live capability in the same scope"
        )
        XCTAssertEqual(
            try scalar(
                db,
                sql: """
                SELECT COUNT(*) FROM token_saver_recovery_objects
                WHERE id = '\(abandoned.objectID)'
                  AND original = X'' AND integrity_sha256 = '' AND byte_count = 0
                  AND state = 'acked' AND tombstoned_at_ms IS NOT NULL;
                """
            ),
            1
        )
        XCTAssertEqual(
            try scalar(
                db,
                sql: """
                SELECT COUNT(*) FROM token_saver_recovery_outbox
                WHERE object_id = '\(abandoned.objectID)'
                  AND state = 'acked' AND transport_outcome = 'acked';
                """
            ),
            1
        )
        XCTAssertEqual(
            try scalar(
                db,
                sql: """
                SELECT COUNT(*) FROM token_saver_recovery_capabilities
                WHERE object_id = '\(abandoned.objectID)' AND revoked_at_ms IS NULL;
                """
            ),
            0,
            "only the abandoned object's capability may remain revoked/live-cleared"
        )
        XCTAssertEqual(
            try scalar(
                db,
                sql: """
                SELECT COUNT(*) FROM token_saver_recovery_capabilities
                WHERE object_id = '\(sibling.objectID)' AND revoked_at_ms IS NULL;
                """
            ),
            1
        )
    }

    func test_discardAbandoned_rejectsNonTombstonedAlreadyAckedMarkerWithZeroMutation() throws {
        let db = try makeDB()
        let store = TokenSaverScopedRecoveryStore(db: db)
        let original = Data("live acked marker".utf8)
        let prepared = try store.prepare(
            original,
            scope: scope(),
            operationID: "acked-marker-op",
            expiresAt: nil,
            disk: disk
        )
        XCTAssertTrue(try store.markDelivered(
            capability: prepared.capability,
            scope: scope(),
            idempotencyKey: prepared.idempotencyKey,
            outcome: .sentUnknown
        ))
        XCTAssertTrue(try store.ack(
            capability: prepared.capability,
            scope: scope(),
            idempotencyKey: prepared.idempotencyKey
        ))
        XCTAssertEqual(
            try store.outboxState(
                capability: prepared.capability,
                scope: scope(),
                idempotencyKey: prepared.idempotencyKey
            ),
            .acked
        )

        XCTAssertFalse(
            try store.discardAbandoned(
                capability: prepared.capability,
                scope: scope(),
                idempotencyKey: prepared.idempotencyKey
            ),
            "discard must not scrub a non-tombstoned already-acked recovery marker"
        )

        XCTAssertEqual(
            try store.retrieve(capability: prepared.capability, scope: scope()),
            original,
            "original must remain retrievable after rejected discard"
        )
        XCTAssertEqual(
            try scalar(
                db,
                sql: """
                SELECT COUNT(*) FROM token_saver_recovery_capabilities
                WHERE object_id = '\(prepared.objectID)' AND revoked_at_ms IS NULL;
                """
            ),
            1,
            "capability must remain live when discard is rejected"
        )
        XCTAssertEqual(
            try scalar(
                db,
                sql: """
                SELECT COUNT(*) FROM token_saver_recovery_objects
                WHERE id = '\(prepared.objectID)'
                  AND tombstoned_at_ms IS NULL
                  AND byte_count = \(original.count)
                  AND original != X'';
                """
            ),
            1
        )
        XCTAssertEqual(
            try scalar(
                db,
                sql: """
                SELECT COUNT(*) FROM token_saver_recovery_outbox
                WHERE object_id = '\(prepared.objectID)'
                  AND state = 'acked' AND transport_outcome = 'acked';
                """
            ),
            1
        )
    }

    func test_finalizeSemanticRecoverySet_succeedsWithStageOnly() throws {
        let db = try makeDB()
        let store = TokenSaverScopedRecoveryStore(db: db)
        let stageBytes = Data("stage only body".utf8)
        let stage = try store.prepare(
            stageBytes, scope: scope(), operationID: "stage-only-op", expiresAt: nil, disk: disk
        )
        XCTAssertTrue(try store.markDelivered(
            capability: stage.capability,
            scope: scope(),
            idempotencyKey: stage.idempotencyKey,
            outcome: .sentUnknown
        ))

        XCTAssertTrue(try store.finalizeSemanticRecoverySet(
            stage: .init(capability: stage.capability, idempotencyKey: stage.idempotencyKey),
            fullOriginal: nil,
            scope: scope()
        ))
        XCTAssertEqual(try store.outboxState(
            capability: stage.capability, scope: scope(), idempotencyKey: stage.idempotencyKey
        ), .acked)
        XCTAssertEqual(
            try scalar(
                db,
                sql: """
                SELECT COUNT(*) FROM token_saver_recovery_outbox
                WHERE object_id = '\(stage.objectID)'
                  AND state = 'acked' AND transport_outcome = 'acked';
                """
            ),
            1
        )
        XCTAssertEqual(try store.retrieve(capability: stage.capability, scope: scope()), stageBytes)
    }

    func test_finalizeSemanticRecoverySet_succeedsWithStageAndFullOriginal() throws {
        let db = try makeDB()
        let store = TokenSaverScopedRecoveryStore(db: db)
        let stageBytes = Data("deterministic stage".utf8)
        let fullBytes = Data("full original prompt larger".utf8)
        let stage = try store.prepare(
            stageBytes, scope: scope(), operationID: "stage-dual-op", expiresAt: nil, disk: disk
        )
        let full = try store.prepare(
            fullBytes, scope: scope(), operationID: "full-dual-op", expiresAt: nil, disk: disk
        )
        XCTAssertTrue(try store.markDelivered(
            capability: stage.capability,
            scope: scope(),
            idempotencyKey: stage.idempotencyKey,
            outcome: .sentUnknown
        ))
        // Full-original remains prepared/not_sent until atomic finalization.

        XCTAssertTrue(try store.finalizeSemanticRecoverySet(
            stage: .init(capability: stage.capability, idempotencyKey: stage.idempotencyKey),
            fullOriginal: .init(capability: full.capability, idempotencyKey: full.idempotencyKey),
            scope: scope()
        ))
        XCTAssertEqual(try store.outboxState(
            capability: stage.capability, scope: scope(), idempotencyKey: stage.idempotencyKey
        ), .acked)
        XCTAssertEqual(try store.outboxState(
            capability: full.capability, scope: scope(), idempotencyKey: full.idempotencyKey
        ), .acked)
        XCTAssertEqual(
            try scalar(
                db,
                sql: """
                SELECT COUNT(*) FROM token_saver_recovery_outbox
                WHERE state = 'acked' AND transport_outcome = 'acked';
                """
            ),
            2
        )
        XCTAssertEqual(try store.retrieve(capability: stage.capability, scope: scope()), stageBytes)
        XCTAssertEqual(try store.retrieve(capability: full.capability, scope: scope()), fullBytes)
    }

    func test_finalizeSemanticRecoverySet_injectedFailureBetweenMembersRollsBackBoth() throws {
        let db = try makeDB()
        let store = TokenSaverScopedRecoveryStore(db: db)
        let stage = try store.prepare(
            Data("stage rollback".utf8),
            scope: scope(), operationID: "stage-inject-op", expiresAt: nil, disk: disk
        )
        let full = try store.prepare(
            Data("full rollback".utf8),
            scope: scope(), operationID: "full-inject-op", expiresAt: nil, disk: disk
        )
        XCTAssertTrue(try store.markDelivered(
            capability: stage.capability,
            scope: scope(),
            idempotencyKey: stage.idempotencyKey,
            outcome: .sentUnknown
        ))

        TokenSaverScopedRecoveryStore.testInjectFailureBetweenSemanticFinalizationMembers = true
        defer { TokenSaverScopedRecoveryStore.testInjectFailureBetweenSemanticFinalizationMembers = false }

        XCTAssertFalse(try store.finalizeSemanticRecoverySet(
            stage: .init(capability: stage.capability, idempotencyKey: stage.idempotencyKey),
            fullOriginal: .init(capability: full.capability, idempotencyKey: full.idempotencyKey),
            scope: scope()
        ), "injected mid-set failure must deny finalization")

        XCTAssertEqual(
            try store.outboxState(
                capability: stage.capability, scope: scope(), idempotencyKey: stage.idempotencyKey
            ),
            .delivered,
            "stage must remain delivered after rollback"
        )
        XCTAssertEqual(
            try scalar(
                db,
                sql: """
                SELECT COUNT(*) FROM token_saver_recovery_outbox
                WHERE object_id = '\(stage.objectID)'
                  AND state = 'delivered' AND transport_outcome = 'sent_unknown';
                """
            ),
            1
        )
        XCTAssertEqual(
            try store.outboxState(
                capability: full.capability, scope: scope(), idempotencyKey: full.idempotencyKey
            ),
            .prepared,
            "full-original must remain prepared after rollback"
        )
        XCTAssertEqual(
            try scalar(
                db,
                sql: """
                SELECT COUNT(*) FROM token_saver_recovery_outbox
                WHERE object_id = '\(full.objectID)'
                  AND state = 'prepared' AND transport_outcome = 'not_sent';
                """
            ),
            1
        )
        XCTAssertEqual(
            try scalar(
                db,
                sql: """
                SELECT COUNT(*) FROM token_saver_recovery_objects
                WHERE id = '\(stage.objectID)' AND state = 'delivered' AND tombstoned_at_ms IS NULL;
                """
            ),
            1
        )
        XCTAssertEqual(
            try scalar(
                db,
                sql: """
                SELECT COUNT(*) FROM token_saver_recovery_objects
                WHERE id = '\(full.objectID)' AND state = 'prepared' AND tombstoned_at_ms IS NULL;
                """
            ),
            1
        )
    }

    func test_finalizeSemanticRecoverySet_wrongKeyScopeOrStateCausesZeroMutation() throws {
        let db = try makeDB()
        let store = TokenSaverScopedRecoveryStore(db: db)
        let stage = try store.prepare(
            Data("stage auth".utf8),
            scope: scope(), operationID: "stage-auth-op", expiresAt: nil, disk: disk
        )
        let full = try store.prepare(
            Data("full auth".utf8),
            scope: scope(), operationID: "full-auth-op", expiresAt: nil, disk: disk
        )
        XCTAssertTrue(try store.markDelivered(
            capability: stage.capability,
            scope: scope(),
            idempotencyKey: stage.idempotencyKey,
            outcome: .sentUnknown
        ))

        func assertUnchanged(_ message: String) throws {
            XCTAssertEqual(
                try store.outboxState(
                    capability: stage.capability, scope: scope(), idempotencyKey: stage.idempotencyKey
                ),
                .delivered,
                message
            )
            XCTAssertEqual(
                try store.outboxState(
                    capability: full.capability, scope: scope(), idempotencyKey: full.idempotencyKey
                ),
                .prepared,
                message
            )
            XCTAssertEqual(
                try scalar(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM token_saver_recovery_outbox
                    WHERE object_id = '\(stage.objectID)'
                      AND state = 'delivered' AND transport_outcome = 'sent_unknown';
                    """
                ),
                1,
                message
            )
            XCTAssertEqual(
                try scalar(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM token_saver_recovery_outbox
                    WHERE object_id = '\(full.objectID)'
                      AND state = 'prepared' AND transport_outcome = 'not_sent';
                    """
                ),
                1,
                message
            )
        }

        XCTAssertFalse(try store.finalizeSemanticRecoverySet(
            stage: .init(capability: stage.capability, idempotencyKey: "wrong-stage-key"),
            fullOriginal: .init(capability: full.capability, idempotencyKey: full.idempotencyKey),
            scope: scope()
        ), "wrong stage idempotency key must deny")
        try assertUnchanged("wrong stage key must not mutate either member")

        XCTAssertFalse(try store.finalizeSemanticRecoverySet(
            stage: .init(capability: stage.capability, idempotencyKey: stage.idempotencyKey),
            fullOriginal: .init(capability: full.capability, idempotencyKey: full.idempotencyKey),
            scope: scope(project: "other")
        ), "wrong five-field scope must deny")
        try assertUnchanged("wrong scope must not mutate either member")

        XCTAssertFalse(try store.finalizeSemanticRecoverySet(
            stage: .init(capability: stage.capability, idempotencyKey: stage.idempotencyKey),
            fullOriginal: .init(capability: full.capability, idempotencyKey: "wrong-full-key"),
            scope: scope()
        ), "wrong full-original key must deny before any mutation")
        try assertUnchanged("wrong full key must not mutate either member")

        // Wrong member state: full-original already delivered instead of prepared/not_sent.
        XCTAssertTrue(try store.markDelivered(
            capability: full.capability,
            scope: scope(),
            idempotencyKey: full.idempotencyKey,
            outcome: .sentUnknown
        ))
        XCTAssertFalse(try store.finalizeSemanticRecoverySet(
            stage: .init(capability: stage.capability, idempotencyKey: stage.idempotencyKey),
            fullOriginal: .init(capability: full.capability, idempotencyKey: full.idempotencyKey),
            scope: scope()
        ), "full-original delivered pre-state must deny atomic finalization")
        XCTAssertEqual(
            try store.outboxState(
                capability: stage.capability, scope: scope(), idempotencyKey: stage.idempotencyKey
            ),
            .delivered
        )
        XCTAssertEqual(
            try store.outboxState(
                capability: full.capability, scope: scope(), idempotencyKey: full.idempotencyKey
            ),
            .delivered
        )
        XCTAssertEqual(
            try scalar(
                db,
                sql: """
                SELECT COUNT(*) FROM token_saver_recovery_outbox
                WHERE state = 'acked' OR transport_outcome = 'acked';
                """
            ),
            0,
            "wrong full pre-state must leave zero acked rows"
        )
    }

    func test_recoveryReferenceRegistryIsCapabilityScopedAndDurableUntilRelease() throws {
        let db = try makeDB()
        let store = TokenSaverScopedRecoveryStore(db: db)
        let prepared = try store.prepare(Data("referenced".utf8), scope: scope(), operationID: "reference-op", expiresAt: nil, disk: disk)

        let referenceID = try XCTUnwrap(store.attachReference(
            capability: prepared.capability, scope: scope(),
            ownerKind: "agent_message", ownerID: "message-1"
        ))
        XCTAssertEqual(try scalar(db, sql: "SELECT COUNT(*) FROM token_saver_recovery_references;"), 1)
        XCTAssertNil(try store.attachReference(
            capability: prepared.capability, scope: scope(project: "wrong"),
            ownerKind: "agent_message", ownerID: "message-2"
        ))
        XCTAssertTrue(try store.releaseReference(referenceID, capability: prepared.capability, scope: scope()))
        XCTAssertFalse(try store.releaseReference(referenceID, capability: prepared.capability, scope: scope()))
        XCTAssertEqual(try scalar(db, sql: "SELECT COUNT(*) FROM token_saver_recovery_references;"), 0)
    }

    func test_attemptLedgerIsAppendOnlyAndComputesProviderJoinCoverage() throws {
        let ledger = TokenSaverAttemptLedger(db: try makeDB())
        let a = TokenSaverAttemptRecord(
            id: "a",
            runID: "r",
            provider: "grok",
            adapterVersion: "1",
            providerVersion: "2",
            model: "grok-4.5",
            cacheState: "cold",
            language: "en",
            hardwareClass: "apple-silicon",
            workload: "coding",
            taskClass: "read_only",
            evidenceLevel: "provider_usage",
            unavailableFields: []
        )
        try ledger.begin(a)
        try ledger.appendEvent(attemptID: "a", kind: "provider_usage", payloadJSON: "{\"input\":10}")
        try ledger.appendInputComponent(attemptID: "a", category: "tool_output", tokens: 6, costMicros: 0)
        XCTAssertEqual(try ledger.attempt(id: "a"), a)
        XCTAssertNil(try ledger.attempt(id: "missing"))
        XCTAssertEqual(try ledger.events(attemptID: "a").map(\.kind), ["provider_usage"])
        XCTAssertEqual(try ledger.joinCoverage(expectedAttemptIDs: ["a"]), 1)
        XCTAssertEqual(try ledger.joinCoverage(expectedAttemptIDs: ["a", "missing"]), 0.5)
    }

    func test_attemptLedgerBuildsReproducibleProviderWorkloadPareto() throws {
        let ledger = TokenSaverAttemptLedger(db: try makeDB())
        func attempt(_ id: String, provider: String, workload: String) -> TokenSaverAttemptRecord {
            .init(
                id: id, runID: "run-\(id)", provider: provider,
                adapterVersion: "1", providerVersion: "1", model: "m",
                cacheState: "cold", language: "en", hardwareClass: "apple-silicon",
                workload: workload, taskClass: "local_resettable",
                evidenceLevel: "provider_usage", unavailableFields: []
            )
        }
        try ledger.begin(attempt("a1", provider: "codex", workload: "build"))
        try ledger.begin(attempt("a2", provider: "codex", workload: "build"))
        try ledger.begin(attempt("a3", provider: "claude", workload: "review"))
        try ledger.appendInputComponent(attemptID: "a1", category: "tool_output", tokens: 600, costMicros: 60)
        try ledger.appendInputComponent(attemptID: "a2", category: "tool_output", tokens: 200, costMicros: 20)
        try ledger.appendInputComponent(attemptID: "a2", category: "instructions", tokens: 200, costMicros: 40)
        try ledger.appendInputComponent(attemptID: "a3", category: "attachments", tokens: 9_000, costMicros: 900)

        let rows = try ledger.inputComponentPareto(provider: "codex", workload: "build")
        XCTAssertEqual(rows.map(\.category), ["tool_output", "instructions"])
        XCTAssertEqual(rows.map(\.tokens), [800, 200])
        XCTAssertEqual(rows.map(\.rank), [1, 2])
        XCTAssertEqual(rows[0].tokenShare, 0.8, accuracy: 0.0001)
        XCTAssertEqual(rows[1].cumulativeTokenShare, 1.0, accuracy: 0.0001)
        XCTAssertEqual(rows[0].costMicros, 80)
    }

    func test_laneStateIsPerProjectPersistentAndCarriesGovernanceFields() throws {
        let repo = TokenSaverLaneStateRepository(db: try makeDB())
        let state = TokenSaverLaneStateRecord(
            projectID: "p1",
            lane: "semantic_prose",
            state: "shadow_only",
            reason: "scorecard_underpowered",
            evidenceLevel: "diagnostic_heuristic",
            ownerRole: "Model Supply-Chain Owner",
            permissionBoundary: "project",
            retentionDays: 30,
            optedOut: true,
            killSwitchActive: true,
            attributionJoined: true,
            reconciliationPassed: true,
            usageSemanticsAvailable: true,
            scorecardID: "scorecard-2026-07-20"
        )
        try repo.upsert(state)

        XCTAssertEqual(try repo.get(projectID: "p1", lane: "semantic_prose"), state)
        XCTAssertEqual(state.typedEvidenceLevel, .diagnosticHeuristic)
        XCTAssertNil(try repo.get(projectID: "p2", lane: "semantic_prose"))
    }

    func test_defaultLaneStatesKeepMeasurementAndProviderNativeShadowOnly() throws {
        let repo = TokenSaverLaneStateRepository(db: try makeDB())
        try repo.ensureDefaults(projectID: "p1")
        let states = try repo.list(projectID: "p1")
        XCTAssertFalse(states.isEmpty)
        XCTAssertEqual(states.count, 10)
        XCTAssertEqual(states.first { $0.lane == "measurement" }?.state, "shadow_only")
        XCTAssertEqual(states.first { $0.lane == "measurement" }?.retentionDays, 0)
        XCTAssertEqual(states.first { $0.lane == "provider_native" }?.state, "shadow_only")
        XCTAssertEqual(states.first { $0.lane == "provider_native" }?.retentionDays, 0)
        // Core tool-output wrapper keeps a recovery window and is not kill-switched
        // by default so store-before-loss works before scorecard promotion.
        let wrapper = try XCTUnwrap(states.first { $0.lane == "deterministic_wrapper" })
        XCTAssertEqual(wrapper.state, "off")
        XCTAssertEqual(wrapper.retentionDays, 7)
        XCTAssertFalse(wrapper.killSwitchActive)
        XCTAssertTrue(states.filter {
            !["measurement", "provider_native", "deterministic_wrapper"].contains($0.lane)
        }.allSatisfy { $0.state == "off" && $0.killSwitchActive })
        XCTAssertTrue(states.allSatisfy { $0.ownerRole.hasPrefix("unassigned:") })
        XCTAssertTrue(states.allSatisfy {
            !$0.attributionJoined && !$0.reconciliationPassed
                && !$0.usageSemanticsAvailable && $0.scorecardID.isEmpty
        }, "default lane rows must not carry an authoritative promotion receipt")
        XCTAssertTrue(states.contains { $0.lane == "rollover_capsule" })
        XCTAssertTrue(states.contains { $0.lane == "semantic_prose" })
        XCTAssertTrue(states.contains { $0.lane == "visual_artifact" })

        try repo.setOptOut(projectID: "p1", optedOut: true)
        XCTAssertTrue(try repo.list(projectID: "p1").allSatisfy { $0.optedOut && $0.state == "off" })
        try repo.setRetentionDays(projectID: "p1", days: 7)
        XCTAssertTrue(try repo.list(projectID: "p1").allSatisfy { $0.retentionDays == 7 })
        try repo.forceVerbatim(projectID: "p1")
        XCTAssertTrue(try repo.list(projectID: "p1").allSatisfy { $0.killSwitchActive && $0.state == "off" })
    }

    func test_laneControlsCreateDefaultsBeforeApplyingDecisionToEmptyProject() throws {
        let repo = TokenSaverLaneStateRepository(db: try makeDB())

        try repo.setOptOut(projectID: "opt-out", optedOut: true)
        XCTAssertEqual(try repo.list(projectID: "opt-out").count, 10)
        XCTAssertTrue(try repo.list(projectID: "opt-out").allSatisfy(\.optedOut))

        try repo.setRetentionDays(projectID: "retention", days: 14)
        XCTAssertEqual(try repo.list(projectID: "retention").count, 10)
        XCTAssertTrue(try repo.list(projectID: "retention").allSatisfy { $0.retentionDays == 14 })

        try repo.forceVerbatim(projectID: "verbatim")
        XCTAssertEqual(try repo.list(projectID: "verbatim").count, 10)
        XCTAssertTrue(try repo.list(projectID: "verbatim").allSatisfy {
            $0.state == "off" && $0.reason == "verbatim_forced" && $0.killSwitchActive
        })
    }

    func test_rolloverCapsuleRepositoryPersistsSelfContainedChildArtifact() throws {
        let repo = TokenSaverRolloverCapsuleRepository(db: try makeDB())
        let record = TokenSaverRolloverCapsuleRecord(
            id: "capsule-1",
            parentThreadID: "parent",
            childThreadID: "child",
            scopeTransitionJSON: nil,
            capsuleSHA256: "sha",
            capsuleText: "ROLLOVER_CAPSULE_V1\nPARENT: parent\nstate"
        )
        try repo.save(record)
        XCTAssertEqual(try repo.get(childThreadID: "child"), record)
        XCTAssertNil(try repo.get(childThreadID: "parent"))
        XCTAssertTrue(try repo.delete(childThreadID: "child"))
        XCTAssertNil(try repo.get(childThreadID: "child"))
        XCTAssertFalse(try repo.delete(childThreadID: "child"))
    }

    /// WHY: with zero project lane scorecards, prepareOriginal used to throw
    /// retentionDisabled for every deterministic_wrapper call — store-before-loss
    /// then forced all tool-output compression to verbatim (0 savings). A default
    /// 7-day retention for that lane (unless explicitly denied) unblocks Token Saver.
    func test_runtimeRecovery_defaultDeterministicWrapperRetentionWithoutScorecard() throws {
        let db = try makeDB()
        let worker = TokenSaverRuntimeRecoveryWorker(db: db)
        let retentionStart = Date(timeIntervalSince1970: 2_000)
        let prepared = try worker.prepareOriginal(
            Data("wrapper-default".utf8),
            scope: scope(),
            operationID: "wrapper-default-op",
            lane: "deterministic_wrapper",
            expiresAt: nil,
            disk: disk,
            now: retentionStart
        )
        XCTAssertEqual(
            try scalar(db, sql: "SELECT COUNT(*) FROM token_saver_recovery_objects WHERE id = '\(prepared.objectID)';"),
            1
        )
        XCTAssertEqual(
            try scalar(db, sql: "SELECT expires_at_ms FROM token_saver_recovery_objects WHERE id = '\(prepared.objectID)';"),
            Int(retentionStart.addingTimeInterval(7 * 86_400).timeIntervalSince1970 * 1_000)
        )
        XCTAssertThrowsError(try worker.prepareOriginal(
            Data("semantic-default".utf8),
            scope: scope(),
            operationID: "semantic-default-op",
            lane: "semantic_prose",
            expiresAt: Date().addingTimeInterval(60),
            disk: disk,
            now: retentionStart
        )) { XCTAssertEqual($0 as? TokenSaverRecoveryStoreError, .retentionDisabled) }
    }

    /// WHY: ensureDefaults used to insert deterministic_wrapper with retention=0,
    /// which made store-before-loss prepare fail durable readback (retrieve SQL
    /// requires retention_days > 0). Factory defaults must keep a 7d recovery window.
    func test_runtimeRecovery_factoryDefaultsAllowWrapperPrepareAndReadback() throws {
        let db = try makeDB()
        try TokenSaverLaneStateRepository(db: db).ensureDefaults(projectID: "p")
        let worker = TokenSaverRuntimeRecoveryWorker(db: db)
        let original = Data("factory-default-wrapper".utf8)
        let prepared = try worker.prepareOriginal(
            original,
            scope: scope(),
            operationID: "factory-wrapper-op",
            lane: "deterministic_wrapper",
            expiresAt: nil,
            disk: disk,
            now: Date(timeIntervalSince1970: 3_000)
        )
        XCTAssertFalse(prepared.capability.isEmpty)
        XCTAssertEqual(
            try TokenSaverScopedRecoveryStore(db: db).retrieve(
                capability: prepared.capability,
                scope: scope(),
                now: Date(timeIntervalSince1970: 3_000)
            ),
            original
        )

        try TokenSaverLaneStateRepository(db: db).forceVerbatim(projectID: "p")
        XCTAssertThrowsError(try worker.prepareOriginal(
            Data("forced-verbatim".utf8),
            scope: scope(),
            operationID: "forced-op",
            lane: "deterministic_wrapper",
            expiresAt: nil,
            disk: disk
        )) { XCTAssertEqual($0 as? TokenSaverRecoveryStoreError, .retentionDisabled) }
    }

    /// WHY: installs that already ran ensureDefaults before the factory-default
    /// fix keep retention_days=0 rows (INSERT OR IGNORE). ensureDefaults + schema
    /// step 52 must repair those so store-before-loss works after upgrade.
    func test_ensureDefaults_repairsLegacyFactoryWrapperRetentionZero() throws {
        let db = try makeDB()
        // Simulate pre-fix factory seed.
        try db.execute("""
            INSERT INTO token_saver_lane_state
                (project_id, lane, state, reason, evidence_level, owner_role,
                 permission_boundary, retention_days, opted_out, kill_switch_active, updated_at_ms)
            VALUES ('p', 'deterministic_wrapper', 'off', 'owner_and_scorecard_required',
                    'unavailable', 'unassigned:Operations Owner', 'project', 0, 0, 1, 1);
        """)
        try TokenSaverLaneStateRepository(db: db).ensureDefaults(projectID: "p")
        let row = try XCTUnwrap(try TokenSaverLaneStateRepository(db: db).get(
            projectID: "p",
            lane: "deterministic_wrapper"
        ))
        XCTAssertEqual(row.retentionDays, 7)
        XCTAssertFalse(row.killSwitchActive)

        let original = Data("legacy-repair".utf8)
        let prepared = try TokenSaverRuntimeRecoveryWorker(db: db).prepareOriginal(
            original,
            scope: scope(),
            operationID: "legacy-repair-op",
            lane: "deterministic_wrapper",
            expiresAt: nil,
            disk: disk,
            now: Date(timeIntervalSince1970: 4_000)
        )
        XCTAssertEqual(
            try TokenSaverScopedRecoveryStore(db: db).retrieve(
                capability: prepared.capability,
                scope: scope(),
                now: Date(timeIntervalSince1970: 4_000)
            ),
            original
        )

        // Operator-chosen retention=0 after repair must NOT be re-opened by ensureDefaults.
        try TokenSaverLaneStateRepository(db: db).setRetentionDays(projectID: "p", days: 0)
        try TokenSaverLaneStateRepository(db: db).ensureDefaults(projectID: "p")
        let afterUserZero = try XCTUnwrap(try TokenSaverLaneStateRepository(db: db).get(
            projectID: "p",
            lane: "deterministic_wrapper"
        ))
        XCTAssertEqual(afterUserZero.retentionDays, 0)
        XCTAssertThrowsError(try TokenSaverRuntimeRecoveryWorker(db: db).prepareOriginal(
            Data("user-zero".utf8),
            scope: scope(),
            operationID: "user-zero-op",
            lane: "deterministic_wrapper",
            expiresAt: nil,
            disk: disk
        )) { XCTAssertEqual($0 as? TokenSaverRecoveryStoreError, .retentionDisabled) }
    }

    func test_runtimeRecoveryUsesExactLaneRetentionAndRetentionZeroPersistsNothing() throws {
        let db = try makeDB()
        let lanes = TokenSaverLaneStateRepository(db: db)
        try lanes.upsert(.init(
            projectID: "p", lane: "deterministic_wrapper", state: "promoted", reason: "passed",
            evidenceLevel: "provider_usage", ownerRole: "owner", permissionBoundary: "project",
            retentionDays: 7, optedOut: false, killSwitchActive: false,
            attributionJoined: true, reconciliationPassed: true,
            usageSemanticsAvailable: true, scorecardID: "scorecard-wrapper"
        ))
        try lanes.upsert(.init(
            projectID: "p", lane: "semantic_prose", state: "promoted", reason: "passed",
            evidenceLevel: "provider_usage", ownerRole: "owner", permissionBoundary: "project",
            retentionDays: 0, optedOut: false, killSwitchActive: false,
            attributionJoined: true, reconciliationPassed: true,
            usageSemanticsAvailable: true, scorecardID: "scorecard-semantic-off"
        ))
        let worker = TokenSaverRuntimeRecoveryWorker(db: db)

        XCTAssertThrowsError(try worker.prepareOriginal(
            Data("semantic".utf8), scope: scope(), operationID: "semantic-op", lane: "semantic_prose",
            expiresAt: Date().addingTimeInterval(60), disk: disk
        )) { XCTAssertEqual($0 as? TokenSaverRecoveryStoreError, .retentionDisabled) }
        XCTAssertEqual(try scalar(db, sql: "SELECT COUNT(*) FROM token_saver_recovery_objects;"), 0)

        let retentionStart = Date(timeIntervalSince1970: 1_000)
        let prepared = try worker.prepareOriginal(
            Data("wrapper".utf8), scope: scope(), operationID: "wrapper-op", lane: "deterministic_wrapper",
            expiresAt: nil, disk: disk, now: retentionStart
        )
        XCTAssertEqual(try scalar(db, sql: "SELECT COUNT(*) FROM token_saver_recovery_objects WHERE id = '\(prepared.objectID)' AND lane = 'deterministic_wrapper';"), 1)
        XCTAssertEqual(
            try scalar(db, sql: "SELECT expires_at_ms FROM token_saver_recovery_objects WHERE id = '\(prepared.objectID)';"),
            Int(retentionStart.addingTimeInterval(7 * 86_400).timeIntervalSince1970 * 1_000),
            "expiry must come from the exact lane's authoritative retention window"
        )

        try lanes.upsert(.init(
            projectID: "p", lane: "semantic_prose", state: "promoted", reason: "passed",
            evidenceLevel: "provider_usage", ownerRole: "owner", permissionBoundary: "project",
            retentionDays: 3, optedOut: false, killSwitchActive: false,
            attributionJoined: true, reconciliationPassed: true,
            usageSemanticsAvailable: true, scorecardID: "scorecard-semantic"
        ))
        let semantic = try worker.prepareOriginal(
            Data("semantic retained".utf8), scope: scope(attempt: "semantic-retained"),
            operationID: "semantic-retained-op", lane: "semantic_prose",
            expiresAt: nil, disk: disk, now: retentionStart
        )
        XCTAssertEqual(
            try scalar(db, sql: "SELECT expires_at_ms FROM token_saver_recovery_objects WHERE id = '\(semantic.objectID)';"),
            Int(retentionStart.addingTimeInterval(3 * 86_400).timeIntervalSince1970 * 1_000)
        )
    }

    func test_lifecycleKeepsLiveReferencesThenScrubsAfterReleaseUnderRetentionZero() throws {
        let db = try makeDB()
        let store = TokenSaverScopedRecoveryStore(db: db)
        let prepared = try store.prepare(Data("referenced private".utf8), scope: scope(), operationID: "live-ref", expiresAt: nil, disk: disk)
        let reference = try XCTUnwrap(store.attachReference(
            capability: prepared.capability, scope: scope(), ownerKind: "provider_operation", ownerID: "live-ref"
        ))
        let lifecycle = TokenSaverProjectDataRepository(db: db)

        XCTAssertEqual(try lifecycle.performLifecycleSweep().recoveryObjects, 0)
        XCTAssertEqual(try store.retrieve(capability: prepared.capability, scope: scope()), Data("referenced private".utf8))
        XCTAssertTrue(try store.releaseReference(reference, capability: prepared.capability, scope: scope()))
        XCTAssertEqual(try lifecycle.performLifecycleSweep().recoveryObjects, 1)
        XCTAssertNil(try store.retrieve(capability: prepared.capability, scope: scope()))
    }

    func test_atomicRetentionReductionClampsExistingRecoveryAndSessionLearnAndZeroDeletesImmediately() throws {
        let db = try makeDB()
        let projectID = "retention-project"
        let lanes = TokenSaverLaneStateRepository(db: db)
        try lanes.ensureDefaults(projectID: projectID)
        try lanes.setRetentionDays(projectID: projectID, days: 30)
        let created = Date(timeIntervalSince1970: 1_000_000)
        let scope = TokenSaverPersistentScope(
            workspaceID: "w", projectID: projectID, threadID: "t",
            provider: "codex", attemptID: "a"
        )
        let recovery = TokenSaverScopedRecoveryStore(db: db)
        let prepared = try recovery.prepare(
            Data("private recovery".utf8), scope: scope, operationID: "retention",
            expiresAt: created.addingTimeInterval(30 * 86_400), disk: disk, now: created
        )
        let learn = TokenSaverSessionLearnRepository(db: db)
        let learnScope = TokenSaverSessionLearnScope(
            workspaceID: "w", projectID: projectID, threadID: "t", provider: "codex"
        )
        try learn.save(
            text: "private learning", scope: learnScope, attemptID: "a",
            now: created, expiresAt: created.addingTimeInterval(30 * 86_400)
        )
        let repository = TokenSaverProjectDataRepository(db: db)
        let afterEightDays = created.addingTimeInterval(8 * 86_400)

        let reduced = try repository.setProjectRetentionDays(
            projectID: projectID, days: 7, now: afterEightDays
        )

        XCTAssertEqual(reduced.recoveryObjects, 1)
        XCTAssertEqual(reduced.sessionLearnRecords, 1)
        XCTAssertNil(try recovery.retrieve(capability: prepared.capability, scope: scope, now: afterEightDays))
        XCTAssertTrue(try learn.topK(scope: learnScope, byteBudget: 1_024, limit: 5, now: afterEightDays).isEmpty)
        XCTAssertTrue(try lanes.list(projectID: projectID).allSatisfy { $0.retentionDays == 7 })

        let live = try recovery.prepare(
            Data("new private recovery".utf8), scope: scope,
            operationID: "retention-zero", invocationID: "retention-zero",
            expiresAt: afterEightDays.addingTimeInterval(7 * 86_400), disk: disk,
            now: afterEightDays
        )
        try learn.save(
            text: "new private learning", scope: learnScope, attemptID: "b",
            now: afterEightDays, expiresAt: afterEightDays.addingTimeInterval(7 * 86_400)
        )
        let zeroed = try repository.setProjectRetentionDays(
            projectID: projectID, days: 0, now: afterEightDays
        )
        XCTAssertEqual(zeroed.recoveryObjects, 1)
        XCTAssertEqual(zeroed.sessionLearnRecords, 1)
        XCTAssertNil(try recovery.retrieve(capability: live.capability, scope: scope, now: afterEightDays))
        XCTAssertTrue(try lanes.list(projectID: projectID).allSatisfy { $0.retentionDays == 0 })
    }

    func test_atomicRetentionFailureRollsBackPolicyAndPrivateData() throws {
        enum Injected: Error { case cleanup }
        let db = try makeDB()
        let projectID = "rollback-project"
        let lanes = TokenSaverLaneStateRepository(db: db)
        try lanes.ensureDefaults(projectID: projectID)
        try lanes.setRetentionDays(projectID: projectID, days: 30)
        let created = Date(timeIntervalSince1970: 2_000_000)
        let scope = TokenSaverPersistentScope(
            workspaceID: "w", projectID: projectID, threadID: "t",
            provider: "codex", attemptID: "a"
        )
        let recovery = TokenSaverScopedRecoveryStore(db: db)
        let prepared = try recovery.prepare(
            Data("must survive rollback".utf8), scope: scope, operationID: "rollback",
            expiresAt: created.addingTimeInterval(30 * 86_400), disk: disk, now: created
        )
        let repository = TokenSaverProjectDataRepository(db: db)
        repository.beforeAtomicRetentionCleanupForTesting = { throw Injected.cleanup }

        XCTAssertThrowsError(try repository.setProjectRetentionDays(
            projectID: projectID, days: 7, now: created.addingTimeInterval(8 * 86_400)
        ))

        XCTAssertTrue(try lanes.list(projectID: projectID).allSatisfy { $0.retentionDays == 30 })
        XCTAssertEqual(
            try recovery.retrieve(
                capability: prepared.capability,
                scope: scope,
                now: created.addingTimeInterval(8 * 86_400)
            ),
            Data("must survive rollback".utf8)
        )
    }

    func test_projectDataDeletionTombstonesRecoveryAndSessionLearnContent() throws {
        let db = try makeDB()
        let recovery = TokenSaverScopedRecoveryStore(db: db)
        let scope = TokenSaverPersistentScope(workspaceID: "w", projectID: "p1", threadID: "t", provider: "codex", attemptID: "a")
        let prepared = try recovery.prepare(Data("private original".utf8), scope: scope, operationID: "private-op", expiresAt: nil, disk: disk)
        let learn = TokenSaverSessionLearnRepository(db: db)
        try learn.save(
            text: "private rule",
            scope: .init(workspaceID: "w", projectID: "p1", threadID: "t", provider: "codex"),
            attemptID: "a"
        )

        let result = try TokenSaverProjectDataRepository(db: db).deleteProjectData(projectID: "p1")
        XCTAssertEqual(result.recoveryObjects, 1)
        XCTAssertEqual(result.sessionLearnRecords, 1)
        XCTAssertNil(try recovery.retrieve(capability: prepared.capability, scope: scope))
        XCTAssertTrue(try learn.topK(
            scope: .init(workspaceID: "w", projectID: "p1", threadID: "t", provider: "codex"),
            byteBudget: 100,
            limit: 5
        ).isEmpty)
    }

    func test_projectDataDeletionScrubsChildCapsuleMessageAndIsIdempotent() throws {
        let db = try makeDB()
        let now = Date(timeIntervalSince1970: 500)
        let project = ProjectRepository.Project(
            id: ProjectID(), name: "Delete", path: "/tmp/delete", favorite: false,
            createdAt: now, updatedAt: now
        )
        try ProjectRepository(db: db).upsert(project)
        let parent = AgentThread(
            projectId: project.id, workspaceId: WorkspaceID(),
            title: "parent", provider: .codex, model: "m"
        )
        let child = AgentThread(
            projectId: project.id, workspaceId: parent.workspaceId,
            title: "child", provider: .codex, model: "m"
        )
        let threads = AgentThreadRepository(db: db)
        try threads.upsert(parent)
        try threads.upsert(child)
        let privateCapsule = "ROLLOVER_CAPSULE_V1\nprivate state"
        try TokenSaverRolloverCapsuleRepository(db: db).save(.init(
            id: "delete-capsule", parentThreadID: parent.id.value.uuidString,
            childThreadID: child.id.value.uuidString, scopeTransitionJSON: "{\"private\":true}",
            capsuleSHA256: "sha", capsuleText: privateCapsule
        ), now: now)
        try AgentMessageRepository(db: db).append(.init(
            threadId: child.id, role: .system, content: privateCapsule, createdAt: now
        ))

        let repository = TokenSaverProjectDataRepository(db: db)
        let first = try repository.deleteProjectData(projectID: project.id.value.uuidString, now: now)
        XCTAssertEqual(first.rolloverCapsules, 1)
        XCTAssertEqual(try AgentMessageRepository(db: db).list(threadId: child.id).first?.content, "TOKEN_SAVER_CAPSULE_REMOVED")
        XCTAssertEqual(try TokenSaverRolloverCapsuleRepository(db: db).get(childThreadID: child.id.value.uuidString)?.capsuleText, "")

        let second = try repository.deleteProjectData(projectID: project.id.value.uuidString, now: now.addingTimeInterval(1))
        XCTAssertEqual(second.rolloverCapsules, 0)
    }

    func test_lifecycleSweepExpiresAllScopedContentAndIsIdempotent() throws {
        let db = try makeDB()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let project = ProjectRepository.Project(
            id: ProjectID(), name: "Scoped", path: "/tmp/scoped", favorite: false,
            createdAt: now, updatedAt: now
        )
        try ProjectRepository(db: db).upsert(project)
        let parent = AgentThread(
            projectId: project.id, workspaceId: WorkspaceID(),
            title: "parent", provider: .codex, model: "m"
        )
        let child = AgentThread(
            projectId: project.id, workspaceId: parent.workspaceId,
            title: "child", provider: .codex, model: "m"
        )
        let threads = AgentThreadRepository(db: db)
        try threads.upsert(parent)
        try threads.upsert(child)

        let lanes = TokenSaverLaneStateRepository(db: db)
        try lanes.ensureDefaults(projectID: project.id.value.uuidString)
        try lanes.setRetentionDays(projectID: project.id.value.uuidString, days: 7, now: now)

        let recovery = TokenSaverScopedRecoveryStore(db: db)
        let recoveryScope = TokenSaverPersistentScope(
            workspaceID: parent.workspaceId!.value.uuidString,
            projectID: project.id.value.uuidString,
            threadID: parent.id.value.uuidString,
            provider: "codex",
            attemptID: "expired"
        )
        let prepared = try recovery.prepare(
            Data("expired original".utf8), scope: recoveryScope,
            operationID: "lifecycle-expired-op",
            expiresAt: now.addingTimeInterval(-1), disk: disk,
            now: now.addingTimeInterval(-100)
        )
        let learn = TokenSaverSessionLearnRepository(db: db)
        let learnScope = TokenSaverSessionLearnScope(
            workspaceID: recoveryScope.workspaceID,
            projectID: recoveryScope.projectID,
            threadID: recoveryScope.threadID,
            provider: recoveryScope.provider
        )
        try learn.save(
            text: "expired rule", scope: learnScope, attemptID: recoveryScope.attemptID,
            now: now.addingTimeInterval(-100), expiresAt: now.addingTimeInterval(-1)
        )
        let capsules = TokenSaverRolloverCapsuleRepository(db: db)
        try capsules.save(.init(
            id: "old", parentThreadID: parent.id.value.uuidString,
            childThreadID: child.id.value.uuidString, scopeTransitionJSON: nil,
            capsuleSHA256: "sha", capsuleText: "private capsule"
        ), now: now.addingTimeInterval(-8 * 86_400))
        try AgentMessageRepository(db: db).append(.init(
            threadId: child.id, role: .system, content: "private capsule",
            createdAt: now.addingTimeInterval(-8 * 86_400)
        ))

        let repository = TokenSaverProjectDataRepository(db: db)
        let first = try repository.performLifecycleSweep(now: now)
        XCTAssertEqual(first, .init(recoveryObjects: 1, sessionLearnRecords: 1, rolloverCapsules: 1))
        XCTAssertNil(try recovery.retrieve(capability: prepared.capability, scope: recoveryScope, now: now))
        XCTAssertTrue(try learn.topK(scope: learnScope, byteBudget: 1_024, limit: 5, now: now).isEmpty)
        XCTAssertEqual(try capsules.get(childThreadID: child.id.value.uuidString)?.capsuleText, "")
        XCTAssertEqual(try AgentMessageRepository(db: db).list(threadId: child.id).first?.content, "TOKEN_SAVER_CAPSULE_REMOVED")

        let second = try repository.performLifecycleSweep(now: now.addingTimeInterval(1))
        XCTAssertEqual(second.total, 0, "a repeated sweep must not re-count tombstoned content")
        let audit = try db.prepare("SELECT COUNT(*) FROM token_saver_audit_events WHERE event_kind = 'lifecycle_sweep';")
        defer { audit.reset() }
        XCTAssertTrue(try audit.step())
        XCTAssertEqual(audit.columnInt64(0), 1, "audit remains content-free and idempotent")
    }

    func test_lifecycleSweepFailsClosedWhenCapsuleLaneStateIsMissing() throws {
        let db = try makeDB()
        let now = Date(timeIntervalSince1970: 3_000_000)
        let project = ProjectRepository.Project(
            id: ProjectID(), name: "No lane", path: "/tmp/no-lane", favorite: false,
            createdAt: now, updatedAt: now
        )
        try ProjectRepository(db: db).upsert(project)
        let parent = AgentThread(
            projectId: project.id, workspaceId: WorkspaceID(),
            title: "parent", provider: .codex, model: "m"
        )
        let child = AgentThread(
            projectId: project.id, workspaceId: parent.workspaceId,
            title: "child", provider: .codex, model: "m"
        )
        let threads = AgentThreadRepository(db: db)
        try threads.upsert(parent)
        try threads.upsert(child)
        try TokenSaverRolloverCapsuleRepository(db: db).save(.init(
            id: "missing-lane", parentThreadID: parent.id.value.uuidString,
            childThreadID: child.id.value.uuidString, scopeTransitionJSON: nil,
            capsuleSHA256: "sha", capsuleText: "private without policy"
        ), now: now)
        try AgentMessageRepository(db: db).append(.init(
            threadId: child.id, role: .system, content: "private without policy", createdAt: now
        ))

        let result = try TokenSaverProjectDataRepository(db: db).performLifecycleSweep(now: now)
        XCTAssertEqual(result.rolloverCapsules, 1)
        XCTAssertEqual(try AgentMessageRepository(db: db).list(threadId: child.id).first?.content, "TOKEN_SAVER_CAPSULE_REMOVED")
    }

    func test_sessionLearnRecordsAreExactScopeAndByteBudgetBounded() throws {
        let repo = TokenSaverSessionLearnRepository(db: try makeDB())
        let scope = TokenSaverSessionLearnScope(
            workspaceID: "w1",
            projectID: "p1",
            threadID: "t1",
            provider: "codex"
        )
        try repo.save(text: "short rule", scope: scope, attemptID: "a1", now: Date(timeIntervalSince1970: 1))
        try repo.save(text: "newer and more useful rule", scope: scope, attemptID: "a2", now: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(try repo.topK(scope: scope, byteBudget: 64, limit: 5).count, 2)
        XCTAssertEqual(try repo.topK(scope: scope, byteBudget: 32, limit: 5).map(\.attemptID), ["a2"])
        XCTAssertTrue(try repo.topK(
            scope: TokenSaverSessionLearnScope(workspaceID: "w1", projectID: "p1", threadID: "t2", provider: "codex"),
            byteBudget: 64,
            limit: 5
        ).isEmpty)
    }

    private func count(_ db: SQLiteDB, table: String) throws -> Int {
        let statement = try db.prepare("SELECT COUNT(*) FROM \(table);")
        defer { statement.reset() }
        return try statement.step() ? Int(statement.columnInt64(0)) : 0
    }

    private func scalar(_ db: SQLiteDB, sql: String) throws -> Int {
        let statement = try db.prepare(sql)
        defer { statement.reset() }
        return try statement.step() ? Int(statement.columnInt64(0)) : 0
    }
}
