import Foundation
import CryptoKit

// MARK: - Scoped recovery

public struct TokenSaverPersistentScope: Sendable, Hashable, Equatable {
    public let workspaceID: String
    public let projectID: String
    public let threadID: String
    public let provider: String
    public let attemptID: String

    public init(workspaceID: String, projectID: String, threadID: String, provider: String, attemptID: String) {
        self.workspaceID = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.projectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.threadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.attemptID = attemptID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isComplete: Bool {
        !workspaceID.isEmpty && !projectID.isEmpty && !threadID.isEmpty
            && !provider.isEmpty && !attemptID.isEmpty
    }
}

public struct TokenSaverRecoveryDiskSnapshot: Sendable, Equatable {
    public let freeBytes: Int64
    public let totalBytes: Int64

    public init(freeBytes: Int64, totalBytes: Int64) {
        self.freeBytes = max(0, freeBytes)
        self.totalBytes = max(0, totalBytes)
    }
}

public enum TokenSaverRecoveryLimits {
    public static let maxObjectBytes: Int64 = 32 * 1_024 * 1_024
    public static let maxThreadBytes: Int64 = 512 * 1_024 * 1_024
    public static let maxProjectBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    public static let maxGlobalBytes: Int64 = 5 * 1_024 * 1_024 * 1_024
    public static let minimumFreeDiskBytes: Int64 = 5 * 1_024 * 1_024 * 1_024
}

public enum TokenSaverRecoveryStoreError: Error, Sendable, Equatable {
    case incompleteScope
    case invalidOperationID
    case idempotencyConflict
    case operationUnavailable
    case retentionDisabled
    case objectQuotaExceeded
    case threadQuotaExceeded
    case projectQuotaExceeded
    case globalQuotaExceeded
    case diskFloorReached
    case durableReadBackFailed
    case integrityMismatch
}

public enum TokenSaverRecoveryObjectState: String, Sendable, Equatable {
    case prepared
    case delivered
    case acked
}

public enum TokenSaverRecoveryTransportOutcome: String, Sendable, Equatable {
    case notSent = "not_sent"
    case sentUnknown = "sent_unknown"
    case acked
    case failed
}

public struct TokenSaverPreparedRecovery: Sendable, Equatable {
    public let objectID: String
    public let capability: String
    public let integritySHA256: String
    public let idempotencyKey: String
    public let state: TokenSaverRecoveryObjectState
    public let readBackVerified: Bool
}

public struct TokenSaverRecoveryInvocationState: Sendable, Equatable {
    public let state: TokenSaverRecoveryObjectState
    public let transportOutcome: TokenSaverRecoveryTransportOutcome
}

/// One authorized member of a semantic recovery finalization set.
public struct TokenSaverSemanticRecoveryMember: Sendable, Equatable {
    public let capability: String
    public let idempotencyKey: String

    public init(capability: String, idempotencyKey: String) {
        self.capability = capability
        self.idempotencyKey = idempotencyKey
    }
}

public final class TokenSaverScopedRecoveryStore: @unchecked Sendable {
    private let db: SQLiteDB

    /// Test seam only: when true, `finalizeSemanticRecoverySet` fails after the first
    /// member mutates and before the second, forcing a full SQLite rollback.
    public static var testInjectFailureBetweenSemanticFinalizationMembers: Bool = false

    public init(db: SQLiteDB) {
        self.db = db
    }

    public func prepare(
        _ data: Data,
        scope: TokenSaverPersistentScope,
        operationID: String,
        invocationID: String? = nil,
        lane: String = "semantic_prose",
        expiresAt: Date?,
        disk: TokenSaverRecoveryDiskSnapshot,
        now: Date = Date()
    ) throws -> TokenSaverPreparedRecovery {
        guard scope.isComplete else { throw TokenSaverRecoveryStoreError.incompleteScope }
        let normalizedOperationID = operationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedOperationID.isEmpty else { throw TokenSaverRecoveryStoreError.invalidOperationID }
        let normalizedInvocationID = (invocationID ?? normalizedOperationID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInvocationID.isEmpty else { throw TokenSaverRecoveryStoreError.invalidOperationID }
        let normalizedLane = lane.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLane.isEmpty else { throw TokenSaverRecoveryStoreError.retentionDisabled }
        let objectBytes = Int64(data.count)
        guard objectBytes <= TokenSaverRecoveryLimits.maxObjectBytes else {
            throw TokenSaverRecoveryStoreError.objectQuotaExceeded
        }
        let diskFloor = max(TokenSaverRecoveryLimits.minimumFreeDiskBytes, disk.totalBytes / 10)
        guard disk.freeBytes >= diskFloor,
              objectBytes <= disk.freeBytes - diskFloor else {
            throw TokenSaverRecoveryStoreError.diskFloorReached
        }

        let integrity = Self.sha256(data)
        let idempotencyKey = Self.idempotencyKey(
            scope: scope,
            invocationID: normalizedInvocationID,
            operationID: normalizedOperationID
        )
        let nowMS = Self.milliseconds(now)
        let expiresMS = expiresAt.map(Self.milliseconds)

        return try db.performSync { database in
            try database.transaction {
                if let existing = try self.existingOperation(
                    database: database,
                    idempotencyKey: idempotencyKey,
                    scope: scope,
                    invocationID: normalizedInvocationID,
                    operationID: normalizedOperationID,
                    lane: normalizedLane,
                    integrity: integrity,
                    data: data,
                    nowMS: nowMS
                ) {
                    guard existing.state == .prepared,
                          existing.transportOutcome == .notSent || existing.transportOutcome == .failed else {
                        throw TokenSaverRecoveryStoreError.operationUnavailable
                    }
                    let capability = try self.mintCapability(
                        database: database,
                        objectID: existing.objectID,
                        nowMS: nowMS,
                        revokeExisting: true
                    )
                    return TokenSaverPreparedRecovery(
                        objectID: existing.objectID,
                        capability: capability,
                        integritySHA256: integrity,
                        idempotencyKey: idempotencyKey,
                        state: existing.state,
                        readBackVerified: true
                    )
                }
                let usage = try self.usage(database: database, scope: scope)
                guard usage.thread + objectBytes <= TokenSaverRecoveryLimits.maxThreadBytes else {
                    throw TokenSaverRecoveryStoreError.threadQuotaExceeded
                }
                guard usage.project + objectBytes <= TokenSaverRecoveryLimits.maxProjectBytes else {
                    throw TokenSaverRecoveryStoreError.projectQuotaExceeded
                }
                guard usage.global + objectBytes <= TokenSaverRecoveryLimits.maxGlobalBytes else {
                    throw TokenSaverRecoveryStoreError.globalQuotaExceeded
                }

                let objectID = UUID().uuidString.lowercased()
                let object = try database.prepare("""
                    INSERT INTO token_saver_recovery_objects
                        (id, workspace_id, project_id, thread_id, provider, attempt_id,
                         integrity_sha256, original, byte_count, state, expires_at_ms,
                         tombstoned_at_ms, created_at_ms, last_access_ms, operation_id,
                         invocation_id, lane)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'prepared', ?, NULL, ?, ?, ?, ?, ?);
                """)
                defer { object.reset() }
                try object.bind(1, objectID)
                try object.bind(2, scope.workspaceID)
                try object.bind(3, scope.projectID)
                try object.bind(4, scope.threadID)
                try object.bind(5, scope.provider)
                try object.bind(6, scope.attemptID)
                try object.bind(7, integrity)
                try object.bind(8, data)
                try object.bind(9, objectBytes)
                try object.bind(10, expiresMS)
                try object.bind(11, nowMS)
                try object.bind(12, nowMS)
                try object.bind(13, normalizedOperationID)
                try object.bind(14, normalizedInvocationID)
                try object.bind(15, normalizedLane)
                _ = try object.step()

                let capability = try self.mintCapability(
                    database: database,
                    objectID: objectID,
                    nowMS: nowMS,
                    revokeExisting: false
                )

                let outbox = try database.prepare("""
                    INSERT INTO token_saver_recovery_outbox
                        (object_id, state, transport_outcome, idempotency_key, updated_at_ms)
                    VALUES (?, 'prepared', 'not_sent', ?, ?);
                """)
                defer { outbox.reset() }
                try outbox.bind(1, objectID)
                try outbox.bind(2, idempotencyKey)
                try outbox.bind(3, nowMS)
                _ = try outbox.step()

                let readBack = try database.prepare("""
                    SELECT original, integrity_sha256
                    FROM token_saver_recovery_objects WHERE id = ? LIMIT 1;
                """)
                defer { readBack.reset() }
                try readBack.bind(1, objectID)
                guard try readBack.step(),
                      let stored = readBack.columnBlob(0),
                      stored == data,
                      readBack.columnText(1) == integrity,
                      Self.sha256(stored) == integrity else {
                    throw TokenSaverRecoveryStoreError.durableReadBackFailed
                }

                return TokenSaverPreparedRecovery(
                    objectID: objectID,
                    capability: capability,
                    integritySHA256: integrity,
                    idempotencyKey: idempotencyKey,
                    state: .prepared,
                    readBackVerified: true
                )
            }
        }
    }

    public func invocationState(
        scope: TokenSaverPersistentScope,
        invocationID: String,
        operationID: String,
        now: Date = Date()
    ) throws -> TokenSaverRecoveryInvocationState? {
        let normalizedInvocationID = invocationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOperationID = operationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard scope.isComplete, !normalizedInvocationID.isEmpty, !normalizedOperationID.isEmpty else {
            throw TokenSaverRecoveryStoreError.invalidOperationID
        }
        return try db.performSync { database in
            let statement = try database.prepare("""
                SELECT o.state, x.transport_outcome
                FROM token_saver_recovery_objects o
                JOIN token_saver_recovery_outbox x ON x.object_id = o.id
                WHERE o.workspace_id = ? AND o.project_id = ? AND o.thread_id = ?
                  AND o.provider = ? AND o.attempt_id = ? AND o.invocation_id = ?
                  AND o.operation_id = ? AND o.tombstoned_at_ms IS NULL
                  AND (o.expires_at_ms IS NULL OR o.expires_at_ms > ?)
                LIMIT 1;
            """)
            defer { statement.reset() }
            try statement.bind(1, scope.workspaceID)
            try statement.bind(2, scope.projectID)
            try statement.bind(3, scope.threadID)
            try statement.bind(4, scope.provider)
            try statement.bind(5, scope.attemptID)
            try statement.bind(6, normalizedInvocationID)
            try statement.bind(7, normalizedOperationID)
            try statement.bind(8, Self.milliseconds(now))
            guard try statement.step(),
                  let state = TokenSaverRecoveryObjectState(rawValue: statement.columnText(0) ?? ""),
                  let outcome = TokenSaverRecoveryTransportOutcome(rawValue: statement.columnText(1) ?? "") else {
                return nil
            }
            return .init(state: state, transportOutcome: outcome)
        }
    }

    public func retrieve(
        capability: String,
        scope: TokenSaverPersistentScope,
        now: Date = Date()
    ) throws -> Data? {
        guard capability.hasPrefix("rcv1.") else { return nil }
        let capabilityHash = Self.sha256(Data(capability.utf8))
        let nowMS = Self.milliseconds(now)
        return try db.performSync { database in
            let statement = try database.prepare("""
                SELECT o.id, o.original, o.integrity_sha256, o.lane
                FROM token_saver_recovery_capabilities c
                JOIN token_saver_recovery_objects o ON o.id = c.object_id
                WHERE c.capability_hash = ?
                  AND c.revoked_at_ms IS NULL
                  AND o.workspace_id = ?
                  AND o.project_id = ?
                  AND o.thread_id = ?
                  AND o.provider = ?
                  AND o.attempt_id = ?
                  AND o.tombstoned_at_ms IS NULL
                  AND (o.expires_at_ms IS NULL OR o.expires_at_ms > ?)
                  AND (NOT EXISTS (
                      SELECT 1 FROM token_saver_lane_state l
                      WHERE l.project_id = o.project_id AND l.lane = o.lane
                  ) OR EXISTS (
                      SELECT 1 FROM token_saver_lane_state l
                      WHERE l.project_id = o.project_id AND l.lane = o.lane
                        AND l.retention_days > 0 AND l.opted_out = 0
                        AND o.created_at_ms > ? - (l.retention_days * 86400000)
                  ))
                LIMIT 1;
            """)
            defer { statement.reset() }
            try statement.bind(1, capabilityHash)
            try statement.bind(2, scope.workspaceID)
            try statement.bind(3, scope.projectID)
            try statement.bind(4, scope.threadID)
            try statement.bind(5, scope.provider)
            try statement.bind(6, scope.attemptID)
            try statement.bind(7, nowMS)
            try statement.bind(8, nowMS)
            guard try statement.step() else { return nil }
            let objectID = statement.columnText(0) ?? ""
            let original = statement.columnBlob(1) ?? Data()
            let integrity = statement.columnText(2) ?? ""
            let lane = statement.columnText(3) ?? ""
            guard Self.sha256(original) == integrity else {
                try self.disablePromotedLanesAfterIntegrityFailure(
                    database: database,
                    projectID: scope.projectID,
                    lane: lane,
                    objectID: objectID,
                    nowMS: nowMS
                )
                throw TokenSaverRecoveryStoreError.integrityMismatch
            }

            let touch = try database.prepare("UPDATE token_saver_recovery_objects SET last_access_ms = ? WHERE id = ?;")
            defer { touch.reset() }
            try touch.bind(1, nowMS)
            try touch.bind(2, objectID)
            _ = try touch.step()
            return original
        }
    }

    public func markDelivered(
        capability: String,
        scope: TokenSaverPersistentScope,
        idempotencyKey: String,
        outcome: TokenSaverRecoveryTransportOutcome,
        now: Date = Date()
    ) throws -> Bool {
        if outcome == .notSent || outcome == .failed {
            return try recordSafeDeliveryFailure(
                capability: capability,
                scope: scope,
                idempotencyKey: idempotencyKey,
                outcome: outcome,
                now: now
            )
        }
        return try transition(
            capability: capability,
            scope: scope,
            idempotencyKey: idempotencyKey,
            expected: .prepared,
            next: .delivered,
            outcome: outcome,
            now: now
        )
    }

    public func ack(
        capability: String,
        scope: TokenSaverPersistentScope,
        idempotencyKey: String,
        now: Date = Date()
    ) throws -> Bool {
        try transition(
            capability: capability,
            scope: scope,
            idempotencyKey: idempotencyKey,
            expected: .delivered,
            next: .acked,
            outcome: .acked,
            now: now
        )
    }

    /// Atomically finalize a semantic recovery set after the final marker-inclusive gate.
    ///
    /// - Stage (required): pre-state `delivered` / `sent_unknown` → `acked` / `acked`.
    /// - Full-original (optional): pre-state `prepared` / `not_sent` → through
    ///   `delivered` / `sent_unknown` → `acked` / `acked`.
    ///
    /// Every member is authorized with capability + exact five-field scope + exact
    /// idempotency key, and every required pre-state is checked, before any mutation.
    /// Missing members, wrong scope/key/state, update-count mismatches, or the
    /// deterministic between-member injection hook roll back the whole set.
    @discardableResult
    public func finalizeSemanticRecoverySet(
        stage: TokenSaverSemanticRecoveryMember,
        fullOriginal: TokenSaverSemanticRecoveryMember? = nil,
        scope: TokenSaverPersistentScope,
        now: Date = Date()
    ) throws -> Bool {
        guard scope.isComplete else { throw TokenSaverRecoveryStoreError.incompleteScope }
        let stageKey = stage.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullKey = fullOriginal.map { $0.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !stageKey.isEmpty, stage.capability.hasPrefix("rcv1.") else { return false }
        if let fullOriginal {
            guard let fullKey, !fullKey.isEmpty, fullOriginal.capability.hasPrefix("rcv1.") else {
                return false
            }
        }
        let nowMS = Self.milliseconds(now)

        enum FinalizeAbort: Error {
            case deny
            case updateMismatch
            case injectedFailure
        }

        do {
            return try db.performSync { database in
                try database.transaction {
                    // Authorize + validate every member before any write.
                    guard let stageObjectID = try self.authorizedObjectID(
                        database: database,
                        capability: stage.capability,
                        scope: scope,
                        nowMS: nowMS
                    ),
                    try self.outboxMatches(
                        database: database,
                        objectID: stageObjectID,
                        idempotencyKey: stageKey,
                        state: .delivered,
                        transportOutcome: .sentUnknown
                    ) else {
                        throw FinalizeAbort.deny
                    }

                    var fullObjectID: String?
                    if let fullOriginal, let fullKey {
                        guard let objectID = try self.authorizedObjectID(
                            database: database,
                            capability: fullOriginal.capability,
                            scope: scope,
                            nowMS: nowMS
                        ),
                        try self.outboxMatches(
                            database: database,
                            objectID: objectID,
                            idempotencyKey: fullKey,
                            state: .prepared,
                            transportOutcome: .notSent
                        ) else {
                            throw FinalizeAbort.deny
                        }
                        fullObjectID = objectID
                    }

                    // Mutate first member (full-original when present), then stage.
                    if let fullObjectID, let fullKey {
                        guard try self.applyOutboxAndObjectTransition(
                            database: database,
                            objectID: fullObjectID,
                            idempotencyKey: fullKey,
                            expectedState: .prepared,
                            expectedOutcome: .notSent,
                            nextState: .delivered,
                            nextOutcome: .sentUnknown,
                            nowMS: nowMS
                        ),
                        try self.applyOutboxAndObjectTransition(
                            database: database,
                            objectID: fullObjectID,
                            idempotencyKey: fullKey,
                            expectedState: .delivered,
                            expectedOutcome: .sentUnknown,
                            nextState: .acked,
                            nextOutcome: .acked,
                            nowMS: nowMS
                        ) else {
                            throw FinalizeAbort.updateMismatch
                        }
                        if Self.testInjectFailureBetweenSemanticFinalizationMembers {
                            throw FinalizeAbort.injectedFailure
                        }
                    }

                    guard try self.applyOutboxAndObjectTransition(
                        database: database,
                        objectID: stageObjectID,
                        idempotencyKey: stageKey,
                        expectedState: .delivered,
                        expectedOutcome: .sentUnknown,
                        nextState: .acked,
                        nextOutcome: .acked,
                        nowMS: nowMS
                    ) else {
                        throw FinalizeAbort.updateMismatch
                    }
                    return true
                }
            }
        } catch FinalizeAbort.deny, FinalizeAbort.updateMismatch, FinalizeAbort.injectedFailure {
            return false
        }
    }

    public func outboxState(
        capability: String,
        scope: TokenSaverPersistentScope,
        idempotencyKey: String,
        now: Date = Date()
    ) throws -> TokenSaverRecoveryObjectState? {
        try db.performSync { database in
            guard let objectID = try self.authorizedObjectID(
                database: database,
                capability: capability,
                scope: scope,
                nowMS: Self.milliseconds(now)
            ) else {
                return nil
            }
            let statement = try database.prepare("SELECT state FROM token_saver_recovery_outbox WHERE object_id = ? AND idempotency_key = ? LIMIT 1;")
            defer { statement.reset() }
            try statement.bind(1, objectID)
            try statement.bind(2, idempotencyKey)
            guard try statement.step() else { return nil }
            return TokenSaverRecoveryObjectState(rawValue: statement.columnText(0) ?? "")
        }
    }

    public func mayReplayMutation(
        capability: String,
        scope: TokenSaverPersistentScope,
        idempotencyKey: String,
        now: Date = Date()
    ) throws -> Bool {
        try db.performSync { database in
            guard let objectID = try self.authorizedObjectID(
                database: database,
                capability: capability,
                scope: scope,
                nowMS: Self.milliseconds(now)
            ) else {
                return false
            }
            let statement = try database.prepare("SELECT state, transport_outcome FROM token_saver_recovery_outbox WHERE object_id = ? AND idempotency_key = ? LIMIT 1;")
            defer { statement.reset() }
            try statement.bind(1, objectID)
            try statement.bind(2, idempotencyKey)
            guard try statement.step() else { return false }
            guard statement.columnText(0) == TokenSaverRecoveryObjectState.prepared.rawValue else { return false }
            let outcome = TokenSaverRecoveryTransportOutcome(rawValue: statement.columnText(1) ?? "")
            return outcome == .notSent || outcome == .failed
        }
    }

    @discardableResult
    public func attachReference(
        capability: String,
        scope: TokenSaverPersistentScope,
        ownerKind: String,
        ownerID: String,
        expiresAt: Date? = nil,
        now: Date = Date()
    ) throws -> String? {
        try db.performSync { database in
            try database.transaction {
                guard let objectID = try self.authorizedObjectID(
                    database: database,
                    capability: capability,
                    scope: scope,
                    nowMS: Self.milliseconds(now)
                ) else { return nil }
                let referenceID = UUID().uuidString.lowercased()
                let statement = try database.prepare("""
                    INSERT INTO token_saver_recovery_references
                        (id, object_id, owner_kind, owner_id, expires_at_ms, created_at_ms)
                    VALUES (?, ?, ?, ?, ?, ?);
                """)
                defer { statement.reset() }
                try statement.bind(1, referenceID)
                try statement.bind(2, objectID)
                try statement.bind(3, ownerKind)
                try statement.bind(4, ownerID)
                try statement.bind(5, expiresAt.map(Self.milliseconds))
                try statement.bind(6, Self.milliseconds(now))
                _ = try statement.step()
                return referenceID
            }
        }
    }

    public func releaseReference(
        _ referenceID: String,
        capability: String,
        scope: TokenSaverPersistentScope,
        now: Date = Date()
    ) throws -> Bool {
        try db.performSync { database in
            try database.transaction {
                guard let objectID = try self.authorizedObjectID(
                    database: database,
                    capability: capability,
                    scope: scope,
                    nowMS: Self.milliseconds(now)
                ) else { return false }
                let statement = try database.prepare("""
                    DELETE FROM token_saver_recovery_references
                    WHERE id = ? AND object_id = ?;
                """)
                defer { statement.reset() }
                try statement.bind(1, referenceID)
                try statement.bind(2, objectID)
                _ = try statement.step()
                return try self.lastStatementChanged(database)
            }
        }
    }

    /// Client-abandoned recovery: scrub one exact object after capability + five-field
    /// scope + outbox idempotency authorization. Never mutates another live object.
    ///
    /// A non-tombstoned object may be scrubbed only while its transport outcome is
    /// still provisional (`not_sent`, `sent_unknown`, or `failed`). An already-acked
    /// live marker is rejected with no mutation; prior discard remains idempotent.
    @discardableResult
    public func discardAbandoned(
        capability: String,
        scope: TokenSaverPersistentScope,
        idempotencyKey: String,
        now: Date = Date()
    ) throws -> Bool {
        guard scope.isComplete else { throw TokenSaverRecoveryStoreError.incompleteScope }
        let normalizedKey = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty, capability.hasPrefix("rcv1.") else { return false }
        let nowMS = Self.milliseconds(now)
        let capabilityHash = Self.sha256(Data(capability.utf8))
        return try db.performSync { database in
            try database.transaction {
                let lookup = try database.prepare("""
                    SELECT o.id, o.tombstoned_at_ms, x.transport_outcome
                    FROM token_saver_recovery_capabilities c
                    JOIN token_saver_recovery_objects o ON o.id = c.object_id
                    JOIN token_saver_recovery_outbox x
                      ON x.object_id = o.id AND x.idempotency_key = ?
                    WHERE c.capability_hash = ?
                      AND o.workspace_id = ?
                      AND o.project_id = ?
                      AND o.thread_id = ?
                      AND o.provider = ?
                      AND o.attempt_id = ?
                    LIMIT 1;
                """)
                defer { lookup.reset() }
                try lookup.bind(1, normalizedKey)
                try lookup.bind(2, capabilityHash)
                try lookup.bind(3, scope.workspaceID)
                try lookup.bind(4, scope.projectID)
                try lookup.bind(5, scope.threadID)
                try lookup.bind(6, scope.provider)
                try lookup.bind(7, scope.attemptID)
                guard try lookup.step() else { return false }
                let objectID = lookup.columnText(0) ?? ""
                guard !objectID.isEmpty else { return false }

                if lookup.columnIsNull(1) {
                    // Live marker already emitted and acknowledged must not be revoked.
                    let outcome = TokenSaverRecoveryTransportOutcome(
                        rawValue: lookup.columnText(2) ?? ""
                    )
                    guard outcome == .notSent
                            || outcome == .sentUnknown
                            || outcome == .failed else {
                        return false
                    }

                    let tombstone = try database.prepare("""
                        UPDATE token_saver_recovery_objects
                        SET original = X'', integrity_sha256 = '', byte_count = 0,
                            tombstoned_at_ms = ?, state = 'acked'
                        WHERE id = ? AND tombstoned_at_ms IS NULL;
                    """)
                    defer { tombstone.reset() }
                    try tombstone.bind(1, nowMS)
                    try tombstone.bind(2, objectID)
                    _ = try tombstone.step()

                    let outbox = try database.prepare("""
                        UPDATE token_saver_recovery_outbox
                        SET state = 'acked', transport_outcome = 'acked', updated_at_ms = ?
                        WHERE object_id = ?;
                    """)
                    defer { outbox.reset() }
                    try outbox.bind(1, nowMS)
                    try outbox.bind(2, objectID)
                    _ = try outbox.step()

                    let references = try database.prepare(
                        "DELETE FROM token_saver_recovery_references WHERE object_id = ?;"
                    )
                    defer { references.reset() }
                    try references.bind(1, objectID)
                    _ = try references.step()
                }

                // Revoke only the authorized capability bearer for this object.
                let revoke = try database.prepare("""
                    UPDATE token_saver_recovery_capabilities
                    SET revoked_at_ms = ?
                    WHERE capability_hash = ? AND object_id = ? AND revoked_at_ms IS NULL;
                """)
                defer { revoke.reset() }
                try revoke.bind(1, nowMS)
                try revoke.bind(2, capabilityHash)
                try revoke.bind(3, objectID)
                _ = try revoke.step()
                return true
            }
        }
    }

    @discardableResult
    public func delete(scope: TokenSaverPersistentScope, now: Date = Date()) throws -> Int {
        let nowMS = Self.milliseconds(now)
        return try db.performSync { database in
            try database.transaction {
                let objectIDs = try self.objectIDs(database: database, scope: scope)
                guard !objectIDs.isEmpty else { return 0 }
                for objectID in objectIDs {
                    let tombstone = try database.prepare("""
                        UPDATE token_saver_recovery_objects
                        SET original = X'', integrity_sha256 = '', byte_count = 0,
                            tombstoned_at_ms = ?, state = 'acked'
                        WHERE id = ? AND tombstoned_at_ms IS NULL;
                    """)
                    defer { tombstone.reset() }
                    try tombstone.bind(1, nowMS)
                    try tombstone.bind(2, objectID)
                    _ = try tombstone.step()

                    let outbox = try database.prepare("""
                        UPDATE token_saver_recovery_outbox
                        SET state = 'acked', transport_outcome = 'acked', updated_at_ms = ?
                        WHERE object_id = ?;
                    """)
                    defer { outbox.reset() }
                    try outbox.bind(1, nowMS)
                    try outbox.bind(2, objectID)
                    _ = try outbox.step()

                    let revoke = try database.prepare("UPDATE token_saver_recovery_capabilities SET revoked_at_ms = ? WHERE object_id = ? AND revoked_at_ms IS NULL;")
                    defer { revoke.reset() }
                    try revoke.bind(1, nowMS)
                    try revoke.bind(2, objectID)
                    _ = try revoke.step()

                    let references = try database.prepare("DELETE FROM token_saver_recovery_references WHERE object_id = ?;")
                    defer { references.reset() }
                    try references.bind(1, objectID)
                    _ = try references.step()
                }
                return objectIDs.count
            }
        }
    }

    private func transition(
        capability: String,
        scope: TokenSaverPersistentScope,
        idempotencyKey: String,
        expected: TokenSaverRecoveryObjectState,
        next: TokenSaverRecoveryObjectState,
        outcome: TokenSaverRecoveryTransportOutcome,
        now: Date
    ) throws -> Bool {
        try db.performSync { database in
            try database.transaction {
                guard let objectID = try self.authorizedObjectID(
                    database: database,
                    capability: capability,
                    scope: scope,
                    nowMS: Self.milliseconds(now)
                ) else {
                    return false
                }
                let current = try database.prepare("SELECT state FROM token_saver_recovery_outbox WHERE object_id = ? AND idempotency_key = ? LIMIT 1;")
                defer { current.reset() }
                try current.bind(1, objectID)
                try current.bind(2, idempotencyKey)
                guard try current.step(), current.columnText(0) == expected.rawValue else { return false }

                let updateOutbox = try database.prepare("""
                    UPDATE token_saver_recovery_outbox
                    SET state = ?, transport_outcome = ?, updated_at_ms = ?
                    WHERE object_id = ? AND state = ?;
                """)
                defer { updateOutbox.reset() }
                try updateOutbox.bind(1, next.rawValue)
                try updateOutbox.bind(2, outcome.rawValue)
                try updateOutbox.bind(3, Self.milliseconds(now))
                try updateOutbox.bind(4, objectID)
                try updateOutbox.bind(5, expected.rawValue)
                _ = try updateOutbox.step()

                let updateObject = try database.prepare("UPDATE token_saver_recovery_objects SET state = ? WHERE id = ?;")
                defer { updateObject.reset() }
                try updateObject.bind(1, next.rawValue)
                try updateObject.bind(2, objectID)
                _ = try updateObject.step()
                return true
            }
        }
    }

    private func outboxMatches(
        database: SQLiteDB,
        objectID: String,
        idempotencyKey: String,
        state: TokenSaverRecoveryObjectState,
        transportOutcome: TokenSaverRecoveryTransportOutcome
    ) throws -> Bool {
        let statement = try database.prepare("""
            SELECT state, transport_outcome
            FROM token_saver_recovery_outbox
            WHERE object_id = ? AND idempotency_key = ?
            LIMIT 1;
        """)
        defer { statement.reset() }
        try statement.bind(1, objectID)
        try statement.bind(2, idempotencyKey)
        guard try statement.step() else { return false }
        return statement.columnText(0) == state.rawValue
            && statement.columnText(1) == transportOutcome.rawValue
    }

    /// Applies a guarded outbox + object state transition. Returns false on
    /// update-count mismatch so the caller can abort and roll back the set.
    private func applyOutboxAndObjectTransition(
        database: SQLiteDB,
        objectID: String,
        idempotencyKey: String,
        expectedState: TokenSaverRecoveryObjectState,
        expectedOutcome: TokenSaverRecoveryTransportOutcome,
        nextState: TokenSaverRecoveryObjectState,
        nextOutcome: TokenSaverRecoveryTransportOutcome,
        nowMS: Int64
    ) throws -> Bool {
        let updateOutbox = try database.prepare("""
            UPDATE token_saver_recovery_outbox
            SET state = ?, transport_outcome = ?, updated_at_ms = ?
            WHERE object_id = ? AND idempotency_key = ?
              AND state = ? AND transport_outcome = ?;
        """)
        defer { updateOutbox.reset() }
        try updateOutbox.bind(1, nextState.rawValue)
        try updateOutbox.bind(2, nextOutcome.rawValue)
        try updateOutbox.bind(3, nowMS)
        try updateOutbox.bind(4, objectID)
        try updateOutbox.bind(5, idempotencyKey)
        try updateOutbox.bind(6, expectedState.rawValue)
        try updateOutbox.bind(7, expectedOutcome.rawValue)
        _ = try updateOutbox.step()
        guard try lastStatementChanged(database) else { return false }

        let updateObject = try database.prepare("""
            UPDATE token_saver_recovery_objects
            SET state = ?
            WHERE id = ? AND state = ?;
        """)
        defer { updateObject.reset() }
        try updateObject.bind(1, nextState.rawValue)
        try updateObject.bind(2, objectID)
        try updateObject.bind(3, expectedState.rawValue)
        _ = try updateObject.step()
        return try lastStatementChanged(database)
    }

    private func recordSafeDeliveryFailure(
        capability: String,
        scope: TokenSaverPersistentScope,
        idempotencyKey: String,
        outcome: TokenSaverRecoveryTransportOutcome,
        now: Date
    ) throws -> Bool {
        try db.performSync { database in
            try database.transaction {
                guard let objectID = try self.authorizedObjectID(
                    database: database,
                    capability: capability,
                    scope: scope,
                    nowMS: Self.milliseconds(now)
                ) else { return false }
                let statement = try database.prepare("""
                    UPDATE token_saver_recovery_outbox
                    SET transport_outcome = ?, updated_at_ms = ?
                    WHERE object_id = ? AND idempotency_key = ? AND state = 'prepared';
                """)
                defer { statement.reset() }
                try statement.bind(1, outcome.rawValue)
                try statement.bind(2, Self.milliseconds(now))
                try statement.bind(3, objectID)
                try statement.bind(4, idempotencyKey)
                _ = try statement.step()
                return try self.lastStatementChanged(database)
            }
        }
    }

    private struct ExistingOperation {
        let objectID: String
        let state: TokenSaverRecoveryObjectState
        let transportOutcome: TokenSaverRecoveryTransportOutcome
    }

    private func existingOperation(
        database: SQLiteDB,
        idempotencyKey: String,
        scope: TokenSaverPersistentScope,
        invocationID: String,
        operationID: String,
        lane: String,
        integrity: String,
        data: Data,
        nowMS: Int64
    ) throws -> ExistingOperation? {
        let statement = try database.prepare("""
            SELECT o.id, o.workspace_id, o.project_id, o.thread_id, o.provider,
                   o.attempt_id, o.invocation_id, o.operation_id, o.lane,
                   o.integrity_sha256, o.original, o.state, o.expires_at_ms,
                   o.tombstoned_at_ms, x.transport_outcome
            FROM token_saver_recovery_outbox x
            JOIN token_saver_recovery_objects o ON o.id = x.object_id
            WHERE x.idempotency_key = ? LIMIT 1;
        """)
        defer { statement.reset() }
        try statement.bind(1, idempotencyKey)
        guard try statement.step() else { return nil }
        guard statement.columnText(1) == scope.workspaceID,
              statement.columnText(2) == scope.projectID,
              statement.columnText(3) == scope.threadID,
              statement.columnText(4) == scope.provider,
              statement.columnText(5) == scope.attemptID,
              statement.columnText(6) == invocationID,
              statement.columnText(7) == operationID,
              statement.columnText(8) == lane,
              statement.columnText(9) == integrity,
              statement.columnBlob(10) == data else {
            throw TokenSaverRecoveryStoreError.idempotencyConflict
        }
        guard statement.columnIsNull(13),
              statement.columnIsNull(12) || statement.columnInt64(12) > nowMS,
              let state = TokenSaverRecoveryObjectState(rawValue: statement.columnText(11) ?? ""),
              let outcome = TokenSaverRecoveryTransportOutcome(rawValue: statement.columnText(14) ?? "") else {
            throw TokenSaverRecoveryStoreError.operationUnavailable
        }
        return ExistingOperation(
            objectID: statement.columnText(0) ?? "",
            state: state,
            transportOutcome: outcome
        )
    }

    private func mintCapability(
        database: SQLiteDB,
        objectID: String,
        nowMS: Int64,
        revokeExisting: Bool
    ) throws -> String {
        if revokeExisting {
            let revoke = try database.prepare("""
                UPDATE token_saver_recovery_capabilities
                SET revoked_at_ms = ? WHERE object_id = ? AND revoked_at_ms IS NULL;
            """)
            defer { revoke.reset() }
            try revoke.bind(1, nowMS)
            try revoke.bind(2, objectID)
            _ = try revoke.step()
        }
        let secret = UUID().uuidString.lowercased() + UUID().uuidString.lowercased()
        let capability = "rcv1.\(objectID).\(secret)"
        let statement = try database.prepare("""
            INSERT INTO token_saver_recovery_capabilities
                (capability_hash, object_id, revoked_at_ms, created_at_ms)
            VALUES (?, ?, NULL, ?);
        """)
        defer { statement.reset() }
        try statement.bind(1, Self.sha256(Data(capability.utf8)))
        try statement.bind(2, objectID)
        try statement.bind(3, nowMS)
        _ = try statement.step()
        return capability
    }

    private func authorizedObjectID(
        database: SQLiteDB,
        capability: String,
        scope: TokenSaverPersistentScope,
        nowMS: Int64
    ) throws -> String? {
        guard capability.hasPrefix("rcv1.") else { return nil }
        let statement = try database.prepare("""
            SELECT o.id
            FROM token_saver_recovery_capabilities c
            JOIN token_saver_recovery_objects o ON o.id = c.object_id
            WHERE c.capability_hash = ? AND c.revoked_at_ms IS NULL
              AND o.workspace_id = ? AND o.project_id = ? AND o.thread_id = ?
              AND o.provider = ? AND o.attempt_id = ? AND o.tombstoned_at_ms IS NULL
              AND (o.expires_at_ms IS NULL OR o.expires_at_ms > ?)
              AND (NOT EXISTS (
                  SELECT 1 FROM token_saver_lane_state l
                  WHERE l.project_id = o.project_id AND l.lane = o.lane
              ) OR EXISTS (
                  SELECT 1 FROM token_saver_lane_state l
                  WHERE l.project_id = o.project_id AND l.lane = o.lane
                    AND l.retention_days > 0 AND l.opted_out = 0
                    AND o.created_at_ms > ? - (l.retention_days * 86400000)
              ))
            LIMIT 1;
        """)
        defer { statement.reset() }
        try statement.bind(1, Self.sha256(Data(capability.utf8)))
        try statement.bind(2, scope.workspaceID)
        try statement.bind(3, scope.projectID)
        try statement.bind(4, scope.threadID)
        try statement.bind(5, scope.provider)
        try statement.bind(6, scope.attemptID)
        try statement.bind(7, nowMS)
        try statement.bind(8, nowMS)
        return try statement.step() ? statement.columnText(0) : nil
    }

    private func disablePromotedLanesAfterIntegrityFailure(
        database: SQLiteDB,
        projectID: String,
        lane: String,
        objectID: String,
        nowMS: Int64
    ) throws {
        let lanes = try database.prepare("""
            UPDATE token_saver_lane_state
            SET state = 'off', reason = 'integrity_failure', kill_switch_active = 1,
                updated_at_ms = ?
            WHERE project_id = ? AND lane = ? AND state = 'promoted';
        """)
        defer { lanes.reset() }
        try lanes.bind(1, nowMS)
        try lanes.bind(2, projectID)
        try lanes.bind(3, lane)
        _ = try lanes.step()

        let audit = try database.prepare("""
            INSERT INTO token_saver_audit_events
                (event_kind, project_id, object_id, reason, created_at_ms)
            VALUES ('integrity_failure', ?, ?, 'promoted_lanes_disabled', ?);
        """)
        defer { audit.reset() }
        try audit.bind(1, projectID)
        try audit.bind(2, objectID)
        try audit.bind(3, nowMS)
        _ = try audit.step()
    }

    private func lastStatementChanged(_ database: SQLiteDB) throws -> Bool {
        let statement = try database.prepare("SELECT changes();")
        defer { statement.reset() }
        return try statement.step() && statement.columnInt64(0) > 0
    }

    private func objectIDs(database: SQLiteDB, scope: TokenSaverPersistentScope) throws -> [String] {
        let statement = try database.prepare("""
            SELECT id FROM token_saver_recovery_objects
            WHERE workspace_id = ? AND project_id = ? AND thread_id = ?
              AND provider = ? AND attempt_id = ? AND tombstoned_at_ms IS NULL;
        """)
        defer { statement.reset() }
        try statement.bind(1, scope.workspaceID)
        try statement.bind(2, scope.projectID)
        try statement.bind(3, scope.threadID)
        try statement.bind(4, scope.provider)
        try statement.bind(5, scope.attemptID)
        var ids: [String] = []
        while try statement.step() { ids.append(statement.columnText(0) ?? "") }
        return ids
    }

    private func usage(database: SQLiteDB, scope: TokenSaverPersistentScope) throws -> (thread: Int64, project: Int64, global: Int64) {
        func sum(_ sql: String, bindings: [String]) throws -> Int64 {
            let statement = try database.prepare(sql)
            defer { statement.reset() }
            for (index, value) in bindings.enumerated() { try statement.bind(Int32(index + 1), value) }
            guard try statement.step() else { return 0 }
            return statement.columnInt64(0)
        }
        let thread = try sum(
            "SELECT COALESCE(SUM(byte_count), 0) FROM token_saver_recovery_objects WHERE workspace_id = ? AND project_id = ? AND thread_id = ? AND tombstoned_at_ms IS NULL;",
            bindings: [scope.workspaceID, scope.projectID, scope.threadID]
        )
        let project = try sum(
            "SELECT COALESCE(SUM(byte_count), 0) FROM token_saver_recovery_objects WHERE project_id = ? AND tombstoned_at_ms IS NULL;",
            bindings: [scope.projectID]
        )
        let global = try sum(
            "SELECT COALESCE(SUM(byte_count), 0) FROM token_saver_recovery_objects WHERE tombstoned_at_ms IS NULL;",
            bindings: []
        )
        return (thread, project, global)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func idempotencyKey(
        scope: TokenSaverPersistentScope,
        invocationID: String,
        operationID: String
    ) -> String {
        let fields = [
            scope.workspaceID, scope.projectID, scope.threadID, scope.provider,
            scope.attemptID, invocationID, operationID,
        ]
        let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return "tsop1." + sha256(Data(canonical.utf8))
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }
}

public struct TokenSaverProtectedCandidate: Sendable, Equatable {
    public let output: String
    public let recoveryMarker: String
    public let preparation: TokenSaverPreparedRecovery
}

/// Shipping store-before-loss seam. Unlike the lower-level repository, this
/// denies persistence unless the project has an explicitly promoted lane with
/// positive retention, then verifies byte-exact retrieval before exposing a
/// candidate or marker to a provider runtime.
public final class TokenSaverRuntimeRecoveryWorker: @unchecked Sendable {
    private let db: SQLiteDB
    private let store: TokenSaverScopedRecoveryStore

    public init(db: SQLiteDB) {
        self.db = db
        self.store = TokenSaverScopedRecoveryStore(db: db)
    }

    public func prepareOriginal(
        _ original: Data,
        scope: TokenSaverPersistentScope,
        operationID: String,
        invocationID: String? = nil,
        lane: String = "semantic_prose",
        expiresAt requestedExpiresAt: Date? = nil,
        disk: TokenSaverRecoveryDiskSnapshot,
        now: Date = Date()
    ) throws -> TokenSaverPreparedRecovery {
        guard let retentionDays = try authoritativeRetentionDays(projectID: scope.projectID, lane: lane) else {
            throw TokenSaverRecoveryStoreError.retentionDisabled
        }
        let policyExpiresAt = now.addingTimeInterval(TimeInterval(retentionDays) * 86_400)
        let expiresAt = requestedExpiresAt.map { min($0, policyExpiresAt) } ?? policyExpiresAt
        let prepared = try store.prepare(
            original,
            scope: scope,
            operationID: operationID,
            invocationID: invocationID,
            lane: lane,
            expiresAt: expiresAt,
            disk: disk,
            now: now
        )
        guard try store.retrieve(capability: prepared.capability, scope: scope, now: now) == original else {
            _ = try? store.discardAbandoned(
                capability: prepared.capability,
                scope: scope,
                idempotencyKey: prepared.idempotencyKey,
                now: now
            )
            throw TokenSaverRecoveryStoreError.durableReadBackFailed
        }
        _ = try store.attachReference(
            capability: prepared.capability,
            scope: scope,
            ownerKind: "provider_operation",
            ownerID: operationID,
            expiresAt: expiresAt,
            now: now
        )
        return prepared
    }

    @discardableResult
    public func discardAbandoned(
        capability: String,
        scope: TokenSaverPersistentScope,
        idempotencyKey: String,
        now: Date = Date()
    ) throws -> Bool {
        try store.discardAbandoned(
            capability: capability,
            scope: scope,
            idempotencyKey: idempotencyKey,
            now: now
        )
    }

    public func invocationState(
        scope: TokenSaverPersistentScope,
        invocationID: String,
        operationID: String,
        now: Date = Date()
    ) throws -> TokenSaverRecoveryInvocationState? {
        try store.invocationState(
            scope: scope,
            invocationID: invocationID,
            operationID: operationID,
            now: now
        )
    }

    public func protect(
        original: String,
        candidate: String,
        scope: TokenSaverPersistentScope,
        operationID: String,
        invocationID: String? = nil,
        lane: String = "semantic_prose",
        expiresAt: Date,
        disk: TokenSaverRecoveryDiskSnapshot,
        now: Date = Date()
    ) throws -> TokenSaverProtectedCandidate {
        guard candidate != original else {
            throw TokenSaverRecoveryStoreError.operationUnavailable
        }
        let prepared = try prepareOriginal(
            Data(original.utf8),
            scope: scope,
            operationID: operationID,
            invocationID: invocationID,
            lane: lane,
            expiresAt: expiresAt,
            disk: disk,
            now: now
        )
        return .init(
            output: candidate,
            recoveryMarker: "[[rc:\(prepared.capability)]]",
            preparation: prepared
        )
    }

    private func authoritativeRetentionDays(projectID: String, lane: String) throws -> Int? {
        try db.performSync { database in
            // Fully promoted + scorecarded lane: authoritative product retention.
            let statement = try database.prepare("""
                SELECT retention_days FROM token_saver_lane_state
                WHERE project_id = ? AND state = 'promoted'
                  AND lane = ?
                  AND retention_days > 0 AND opted_out = 0 AND kill_switch_active = 0
                  AND evidence_level = 'provider_usage'
                  AND attribution_joined = 1 AND reconciliation_passed = 1
                  AND usage_semantics_available = 1 AND scorecard_id != ''
                LIMIT 1;
            """)
            defer { statement.reset() }
            try statement.bind(1, projectID)
            try statement.bind(2, lane)
            if try statement.step() {
                return Int(statement.columnInt64(0))
            }

            // Explicit governance row can still deny retention (opt-out / kill /
            // retention=0) even when scorecard promotion is incomplete.
            let explicit = try database.prepare("""
                SELECT retention_days, opted_out, kill_switch_active
                FROM token_saver_lane_state
                WHERE project_id = ? AND lane = ?
                LIMIT 1;
            """)
            defer { explicit.reset() }
            try explicit.bind(1, projectID)
            try explicit.bind(2, lane)
            if try explicit.step() {
                let retentionDays = Int(explicit.columnInt64(0))
                let optedOut = explicit.columnInt64(1) != 0
                let killSwitch = explicit.columnInt64(2) != 0
                if optedOut || killSwitch || retentionDays <= 0 {
                    return nil
                }
            }

            // Default for the tool-output wrapper lane: Token Saver ON without a
            // project scorecard must still be able to store-before-loss so
            // command-output compression is not forced to permanent verbatim.
            // Semantic prose stays fail-closed until promoted.
            if lane == "deterministic_wrapper" {
                return 7
            }
            return nil
        }
    }
}

// MARK: - Attempt ledger

public struct TokenSaverAttemptRecord: Sendable, Equatable {
    public let id: String
    public let runID: String
    public let provider: String
    public let adapterVersion: String
    public let providerVersion: String
    public let model: String
    public let cacheState: String
    public let language: String
    public let hardwareClass: String
    public let workload: String
    public let taskClass: String
    public let evidenceLevel: String
    public let unavailableFields: [String]

    public init(
        id: String,
        runID: String,
        provider: String,
        adapterVersion: String,
        providerVersion: String,
        model: String,
        cacheState: String,
        language: String,
        hardwareClass: String,
        workload: String,
        taskClass: String,
        evidenceLevel: String,
        unavailableFields: [String]
    ) {
        self.id = id
        self.runID = runID
        self.provider = provider
        self.adapterVersion = adapterVersion
        self.providerVersion = providerVersion
        self.model = model
        self.cacheState = cacheState
        self.language = language
        self.hardwareClass = hardwareClass
        self.workload = workload
        self.taskClass = taskClass
        self.evidenceLevel = evidenceLevel
        self.unavailableFields = unavailableFields
    }
}

public struct TokenSaverAttemptEvent: Sendable, Equatable {
    public let id: Int64
    public let attemptID: String
    public let kind: String
    public let payloadJSON: String
}

public struct TokenSaverInputComponentParetoRow: Sendable, Equatable {
    public let rank: Int
    public let category: String
    public let tokens: Int
    public let costMicros: Int64
    public let tokenShare: Double
    public let cumulativeTokenShare: Double
}

public final class TokenSaverAttemptLedger: @unchecked Sendable {
    private let db: SQLiteDB

    public init(db: SQLiteDB) { self.db = db }

    public func begin(_ attempt: TokenSaverAttemptRecord, now: Date = Date()) throws {
        let unavailableData = try JSONEncoder().encode(attempt.unavailableFields)
        let unavailableJSON = String(data: unavailableData, encoding: .utf8) ?? "[]"
        try db.performSync { database in
            let statement = try database.prepare("""
                INSERT INTO token_saver_attempts
                    (id, run_id, provider, adapter_version, provider_version, model,
                     cache_state, language, hardware_class, workload, task_class,
                     evidence_level, unavailable_fields_json, created_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
            defer { statement.reset() }
            let values = [attempt.id, attempt.runID, attempt.provider, attempt.adapterVersion,
                          attempt.providerVersion, attempt.model, attempt.cacheState,
                          attempt.language, attempt.hardwareClass, attempt.workload,
                          attempt.taskClass, attempt.evidenceLevel, unavailableJSON]
            for (index, value) in values.enumerated() { try statement.bind(Int32(index + 1), value) }
            try statement.bind(14, Int64(now.timeIntervalSince1970 * 1_000))
            _ = try statement.step()
        }
    }

    public func attempt(id: String) throws -> TokenSaverAttemptRecord? {
        try db.performSync { database in
            let statement = try database.prepare("""
                SELECT id, run_id, provider, adapter_version, provider_version, model,
                       cache_state, language, hardware_class, workload, task_class,
                       evidence_level, unavailable_fields_json
                FROM token_saver_attempts WHERE id = ? LIMIT 1;
            """)
            defer { statement.reset() }
            try statement.bind(1, id)
            guard try statement.step() else { return nil }
            let unavailableData = Data((statement.columnText(12) ?? "[]").utf8)
            let unavailableFields = (try? JSONDecoder().decode([String].self, from: unavailableData)) ?? []
            return TokenSaverAttemptRecord(
                id: statement.columnText(0) ?? "",
                runID: statement.columnText(1) ?? "",
                provider: statement.columnText(2) ?? "",
                adapterVersion: statement.columnText(3) ?? "",
                providerVersion: statement.columnText(4) ?? "",
                model: statement.columnText(5) ?? "",
                cacheState: statement.columnText(6) ?? "",
                language: statement.columnText(7) ?? "",
                hardwareClass: statement.columnText(8) ?? "",
                workload: statement.columnText(9) ?? "",
                taskClass: statement.columnText(10) ?? "",
                evidenceLevel: statement.columnText(11) ?? "",
                unavailableFields: unavailableFields
            )
        }
    }

    public func appendEvent(attemptID: String, kind: String, payloadJSON: String, now: Date = Date()) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                INSERT INTO token_saver_attempt_events (attempt_id, kind, payload_json, created_at_ms)
                VALUES (?, ?, ?, ?);
            """)
            defer { statement.reset() }
            try statement.bind(1, attemptID)
            try statement.bind(2, kind)
            try statement.bind(3, payloadJSON)
            try statement.bind(4, Int64(now.timeIntervalSince1970 * 1_000))
            _ = try statement.step()
        }
    }

    public func appendInputComponent(
        attemptID: String,
        category: String,
        tokens: Int,
        costMicros: Int64,
        now: Date = Date()
    ) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                INSERT INTO token_saver_input_components
                    (attempt_id, category, tokens, cost_micros, created_at_ms)
                VALUES (?, ?, ?, ?, ?);
            """)
            defer { statement.reset() }
            try statement.bind(1, attemptID)
            try statement.bind(2, category)
            try statement.bind(3, Int64(max(0, tokens)))
            try statement.bind(4, max(0, costMicros))
            try statement.bind(5, Int64(now.timeIntervalSince1970 * 1_000))
            _ = try statement.step()
        }
    }

    public func events(attemptID: String) throws -> [TokenSaverAttemptEvent] {
        try db.performSync { database in
            let statement = try database.prepare("""
                SELECT id, attempt_id, kind, payload_json
                FROM token_saver_attempt_events WHERE attempt_id = ? ORDER BY id;
            """)
            defer { statement.reset() }
            try statement.bind(1, attemptID)
            var result: [TokenSaverAttemptEvent] = []
            while try statement.step() {
                result.append(TokenSaverAttemptEvent(
                    id: statement.columnInt64(0),
                    attemptID: statement.columnText(1) ?? "",
                    kind: statement.columnText(2) ?? "",
                    payloadJSON: statement.columnText(3) ?? "{}"
                ))
            }
            return result
        }
    }

    public func joinCoverage(expectedAttemptIDs: [String]) throws -> Double {
        let expected = Set(expectedAttemptIDs)
        guard !expected.isEmpty else { return 0 }
        let joined: Set<String> = try db.performSync { database in
            let statement = try database.prepare("SELECT DISTINCT attempt_id FROM token_saver_attempt_events WHERE kind = 'provider_usage';")
            defer { statement.reset() }
            var ids = Set<String>()
            while try statement.step() { ids.insert(statement.columnText(0) ?? "") }
            return ids
        }
        return Double(expected.intersection(joined).count) / Double(expected.count)
    }

    public func inputComponentPareto(provider: String? = nil, workload: String? = nil) throws -> [TokenSaverInputComponentParetoRow] {
        try db.performSync { database in
            var predicates: [String] = []
            var bindings: [String] = []
            if let provider {
                predicates.append("a.provider = ?")
                bindings.append(provider)
            }
            if let workload {
                predicates.append("a.workload = ?")
                bindings.append(workload)
            }
            let whereClause = predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND ")
            let statement = try database.prepare("""
                SELECT c.category, SUM(c.tokens), SUM(c.cost_micros)
                FROM token_saver_input_components c
                JOIN token_saver_attempts a ON a.id = c.attempt_id
                \(whereClause)
                GROUP BY c.category
                ORDER BY SUM(c.tokens) DESC, c.category ASC;
            """)
            defer { statement.reset() }
            for (index, value) in bindings.enumerated() {
                try statement.bind(Int32(index + 1), value)
            }
            var aggregates: [(category: String, tokens: Int, costMicros: Int64)] = []
            while try statement.step() {
                aggregates.append((
                    category: statement.columnText(0) ?? "unknown",
                    tokens: Int(statement.columnInt64(1)),
                    costMicros: statement.columnInt64(2)
                ))
            }
            let totalTokens = aggregates.reduce(0) { $0 + $1.tokens }
            var cumulative = 0
            return aggregates.enumerated().map { index, aggregate in
                cumulative += aggregate.tokens
                let share = totalTokens > 0 ? Double(aggregate.tokens) / Double(totalTokens) : 0
                let cumulativeShare = totalTokens > 0 ? Double(cumulative) / Double(totalTokens) : 0
                return TokenSaverInputComponentParetoRow(
                    rank: index + 1,
                    category: aggregate.category,
                    tokens: aggregate.tokens,
                    costMicros: aggregate.costMicros,
                    tokenShare: share,
                    cumulativeTokenShare: cumulativeShare
                )
            }
        }
    }
}

// MARK: - Scoped SessionLearn

public struct TokenSaverSessionLearnScope: Sendable, Equatable {
    public let workspaceID: String
    public let projectID: String
    public let threadID: String
    public let provider: String

    public init(workspaceID: String, projectID: String, threadID: String, provider: String) {
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.threadID = threadID
        self.provider = provider
    }
}

public struct TokenSaverSessionLearnRecord: Sendable, Equatable {
    public let id: String
    public let scope: TokenSaverSessionLearnScope
    public let attemptID: String
    public let text: String
    public let createdAt: Date
}

public final class TokenSaverSessionLearnRepository: @unchecked Sendable {
    private let db: SQLiteDB

    public init(db: SQLiteDB) { self.db = db }

    public func save(
        text: String,
        scope: TokenSaverSessionLearnScope,
        attemptID: String,
        lane: String = "session_learn",
        now: Date = Date(),
        expiresAt: Date? = nil
    ) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                INSERT INTO token_saver_session_learn_records
                    (id, workspace_id, project_id, thread_id, provider, attempt_id,
                     text, created_at_ms, expires_at_ms, tombstoned_at_ms, lane)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?);
            """)
            defer { statement.reset() }
            try statement.bind(1, UUID().uuidString)
            try statement.bind(2, scope.workspaceID)
            try statement.bind(3, scope.projectID)
            try statement.bind(4, scope.threadID)
            try statement.bind(5, scope.provider)
            try statement.bind(6, attemptID)
            try statement.bind(7, text)
            try statement.bind(8, Int64(now.timeIntervalSince1970 * 1_000))
            if let expiresAt {
                try statement.bind(9, Int64(expiresAt.timeIntervalSince1970 * 1_000))
            } else {
                try statement.bind(9, Optional<Int64>.none)
            }
            try statement.bind(10, lane)
            _ = try statement.step()
        }
    }

    public func topK(
        scope: TokenSaverSessionLearnScope,
        byteBudget: Int,
        limit: Int,
        now: Date = Date()
    ) throws -> [TokenSaverSessionLearnRecord] {
        guard byteBudget > 0, limit > 0 else { return [] }
        return try db.performSync { database in
            let statement = try database.prepare("""
                SELECT id, attempt_id, text, created_at_ms
                FROM token_saver_session_learn_records
                WHERE workspace_id = ? AND project_id = ? AND thread_id = ? AND provider = ?
                  AND tombstoned_at_ms IS NULL
                  AND (expires_at_ms IS NULL OR expires_at_ms > ?)
                  AND (NOT EXISTS (
                      SELECT 1 FROM token_saver_lane_state l
                      WHERE l.project_id = token_saver_session_learn_records.project_id
                        AND l.lane = token_saver_session_learn_records.lane
                  ) OR EXISTS (
                      SELECT 1 FROM token_saver_lane_state l
                      WHERE l.project_id = token_saver_session_learn_records.project_id
                        AND l.lane = token_saver_session_learn_records.lane
                        AND l.retention_days > 0 AND l.opted_out = 0
                        AND token_saver_session_learn_records.created_at_ms > ? - (l.retention_days * 86400000)
                  ))
                ORDER BY created_at_ms DESC, id DESC;
            """)
            defer { statement.reset() }
            try statement.bind(1, scope.workspaceID)
            try statement.bind(2, scope.projectID)
            try statement.bind(3, scope.threadID)
            try statement.bind(4, scope.provider)
            try statement.bind(5, Int64(now.timeIntervalSince1970 * 1_000))
            try statement.bind(6, Int64(now.timeIntervalSince1970 * 1_000))
            var records: [TokenSaverSessionLearnRecord] = []
            var remainingBytes = byteBudget
            while records.count < limit, try statement.step() {
                let text = statement.columnText(2) ?? ""
                let bytes = text.lengthOfBytes(using: .utf8)
                guard bytes <= remainingBytes else { continue }
                records.append(TokenSaverSessionLearnRecord(
                    id: statement.columnText(0) ?? "",
                    scope: scope,
                    attemptID: statement.columnText(1) ?? "",
                    text: text,
                    createdAt: Date(timeIntervalSince1970: Double(statement.columnInt64(3)) / 1_000)
                ))
                remainingBytes -= bytes
            }
            return records
        }
    }
}

// MARK: - Rollover capsules

public struct TokenSaverRolloverCapsuleRecord: Sendable, Equatable {
    public let id: String
    public let parentThreadID: String
    public let childThreadID: String
    public let scopeTransitionJSON: String?
    public let capsuleSHA256: String
    public let capsuleText: String

    public init(
        id: String,
        parentThreadID: String,
        childThreadID: String,
        scopeTransitionJSON: String?,
        capsuleSHA256: String,
        capsuleText: String
    ) {
        self.id = id
        self.parentThreadID = parentThreadID
        self.childThreadID = childThreadID
        self.scopeTransitionJSON = scopeTransitionJSON
        self.capsuleSHA256 = capsuleSHA256
        self.capsuleText = capsuleText
    }
}

public final class TokenSaverRolloverCapsuleRepository: @unchecked Sendable {
    private let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

    public func save(_ record: TokenSaverRolloverCapsuleRecord, now: Date = Date()) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                INSERT INTO token_saver_rollover_capsules
                    (id, parent_thread_id, child_thread_id, scope_transition_json,
                     capsule_sha256, capsule_text, created_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?);
            """)
            defer { statement.reset() }
            try statement.bind(1, record.id)
            try statement.bind(2, record.parentThreadID)
            try statement.bind(3, record.childThreadID)
            try statement.bind(4, record.scopeTransitionJSON)
            try statement.bind(5, record.capsuleSHA256)
            try statement.bind(6, record.capsuleText)
            try statement.bind(7, Int64(now.timeIntervalSince1970 * 1_000))
            _ = try statement.step()
        }
    }

    public func get(childThreadID: String) throws -> TokenSaverRolloverCapsuleRecord? {
        try db.performSync { database in
            let statement = try database.prepare("""
                SELECT id, parent_thread_id, child_thread_id, scope_transition_json,
                       capsule_sha256, capsule_text
                FROM token_saver_rollover_capsules
                WHERE child_thread_id = ? ORDER BY created_at_ms DESC LIMIT 1;
            """)
            defer { statement.reset() }
            try statement.bind(1, childThreadID)
            guard try statement.step() else { return nil }
            return .init(
                id: statement.columnText(0) ?? "",
                parentThreadID: statement.columnText(1) ?? "",
                childThreadID: statement.columnText(2) ?? "",
                scopeTransitionJSON: statement.columnText(3),
                capsuleSHA256: statement.columnText(4) ?? "",
                capsuleText: statement.columnText(5) ?? ""
            )
        }
    }

    @discardableResult
    public func delete(childThreadID: String) throws -> Bool {
        try db.performSync { database in
            let statement = try database.prepare("""
                DELETE FROM token_saver_rollover_capsules WHERE child_thread_id = ?;
            """)
            defer { statement.reset() }
            try statement.bind(1, childThreadID)
            _ = try statement.step()
            let changed = try database.prepare("SELECT changes();")
            defer { changed.reset() }
            return try changed.step() && changed.columnInt64(0) > 0
        }
    }
}

public struct TokenSaverProjectDataDeletionResult: Sendable, Equatable {
    public let recoveryObjects: Int
    public let sessionLearnRecords: Int
    public let rolloverCapsules: Int
}

public struct TokenSaverLifecycleSweepResult: Sendable, Equatable {
    public let recoveryObjects: Int
    public let sessionLearnRecords: Int
    public let rolloverCapsules: Int

    public var total: Int { recoveryObjects + sessionLearnRecords + rolloverCapsules }
}

public final class TokenSaverProjectDataRepository: @unchecked Sendable {
    private let db: SQLiteDB
    var beforeAtomicRetentionCleanupForTesting: (() throws -> Void)?
    public init(db: SQLiteDB) { self.db = db }

    @discardableResult
    public func setProjectRetentionDays(
        projectID: String,
        days: Int,
        now: Date = Date()
    ) throws -> TokenSaverLifecycleSweepResult {
        let retentionDays = max(0, days)
        let nowMS = Int64(now.timeIntervalSince1970 * 1_000)
        return try db.performSync { database in
            try database.transaction {
                try TokenSaverLaneStateRepository(db: self.db).insertDefaults(
                    database: database,
                    projectID: projectID,
                    now: now
                )
                let lanes = try database.prepare("""
                    UPDATE token_saver_lane_state
                    SET retention_days = ?, updated_at_ms = ? WHERE project_id = ?;
                """)
                defer { lanes.reset() }
                try lanes.bind(1, Int64(retentionDays))
                try lanes.bind(2, nowMS)
                try lanes.bind(3, projectID)
                _ = try lanes.step()

                try self.beforeAtomicRetentionCleanupForTesting?()

                let retentionMS = Int64(retentionDays) * 86_400_000
                let clampRecovery = try database.prepare("""
                    UPDATE token_saver_recovery_objects
                    SET expires_at_ms = CASE
                        WHEN expires_at_ms IS NULL OR expires_at_ms > created_at_ms + ?
                        THEN created_at_ms + ? ELSE expires_at_ms END
                    WHERE project_id = ? AND tombstoned_at_ms IS NULL;
                """)
                defer { clampRecovery.reset() }
                try clampRecovery.bind(1, retentionMS)
                try clampRecovery.bind(2, retentionMS)
                try clampRecovery.bind(3, projectID)
                _ = try clampRecovery.step()

                let clampLearn = try database.prepare("""
                    UPDATE token_saver_session_learn_records
                    SET expires_at_ms = CASE
                        WHEN expires_at_ms IS NULL OR expires_at_ms > created_at_ms + ?
                        THEN created_at_ms + ? ELSE expires_at_ms END
                    WHERE project_id = ? AND tombstoned_at_ms IS NULL;
                """)
                defer { clampLearn.reset() }
                try clampLearn.bind(1, retentionMS)
                try clampLearn.bind(2, retentionMS)
                try clampLearn.bind(3, projectID)
                _ = try clampLearn.step()

                let recoveryCount = try self.count(
                    database,
                    sql: "SELECT COUNT(*) FROM token_saver_recovery_objects WHERE project_id = ? AND tombstoned_at_ms IS NULL AND expires_at_ms <= \(nowMS);",
                    projectID: projectID
                )
                let learnCount = try self.count(
                    database,
                    sql: "SELECT COUNT(*) FROM token_saver_session_learn_records WHERE project_id = ? AND tombstoned_at_ms IS NULL AND expires_at_ms <= \(nowMS);",
                    projectID: projectID
                )
                let capsuleCount = try self.count(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM token_saver_rollover_capsules
                        WHERE capsule_text != '' AND parent_thread_id IN (
                            SELECT id FROM agent_threads
                            WHERE project_id = ? AND created_at <= datetime(\(Double(nowMS - retentionMS)) / 1000, 'unixepoch')
                        );
                    """,
                    projectID: projectID
                )

                let revoke = try database.prepare("""
                    UPDATE token_saver_recovery_capabilities SET revoked_at_ms = ?
                    WHERE revoked_at_ms IS NULL AND object_id IN (
                        SELECT id FROM token_saver_recovery_objects
                        WHERE project_id = ? AND tombstoned_at_ms IS NULL AND expires_at_ms <= ?
                    );
                """)
                defer { revoke.reset() }
                try revoke.bind(1, nowMS)
                try revoke.bind(2, projectID)
                try revoke.bind(3, nowMS)
                _ = try revoke.step()

                let references = try database.prepare("""
                    DELETE FROM token_saver_recovery_references WHERE object_id IN (
                        SELECT id FROM token_saver_recovery_objects
                        WHERE project_id = ? AND tombstoned_at_ms IS NULL AND expires_at_ms <= ?
                    );
                """)
                defer { references.reset() }
                try references.bind(1, projectID)
                try references.bind(2, nowMS)
                _ = try references.step()

                let recovery = try database.prepare("""
                    UPDATE token_saver_recovery_objects
                    SET original = X'', integrity_sha256 = '', byte_count = 0,
                        tombstoned_at_ms = ?, state = 'acked'
                    WHERE project_id = ? AND tombstoned_at_ms IS NULL AND expires_at_ms <= ?;
                """)
                defer { recovery.reset() }
                try recovery.bind(1, nowMS)
                try recovery.bind(2, projectID)
                try recovery.bind(3, nowMS)
                _ = try recovery.step()

                let outbox = try database.prepare("""
                    UPDATE token_saver_recovery_outbox
                    SET state = 'acked', transport_outcome = 'acked', updated_at_ms = ?
                    WHERE object_id IN (
                        SELECT id FROM token_saver_recovery_objects
                        WHERE project_id = ? AND tombstoned_at_ms = ?
                    );
                """)
                defer { outbox.reset() }
                try outbox.bind(1, nowMS)
                try outbox.bind(2, projectID)
                try outbox.bind(3, nowMS)
                _ = try outbox.step()

                let learn = try database.prepare("""
                    UPDATE token_saver_session_learn_records
                    SET text = '', tombstoned_at_ms = ?
                    WHERE project_id = ? AND tombstoned_at_ms IS NULL AND expires_at_ms <= ?;
                """)
                defer { learn.reset() }
                try learn.bind(1, nowMS)
                try learn.bind(2, projectID)
                try learn.bind(3, nowMS)
                _ = try learn.step()

                if retentionDays == 0 {
                    let capsuleMessages = try database.prepare("""
                        UPDATE agent_messages SET content = 'TOKEN_SAVER_CAPSULE_REMOVED'
                        WHERE role = 'system' AND EXISTS (
                            SELECT 1 FROM token_saver_rollover_capsules c
                            JOIN agent_threads p ON p.id = c.parent_thread_id
                            WHERE p.project_id = ? AND c.child_thread_id = agent_messages.thread_id
                              AND c.capsule_text = agent_messages.content AND c.capsule_text != ''
                        );
                    """)
                    defer { capsuleMessages.reset() }
                    try capsuleMessages.bind(1, projectID)
                    _ = try capsuleMessages.step()

                    let capsules = try database.prepare("""
                        UPDATE token_saver_rollover_capsules
                        SET capsule_text = '', capsule_sha256 = '', scope_transition_json = NULL
                        WHERE capsule_text != '' AND parent_thread_id IN (
                            SELECT id FROM agent_threads WHERE project_id = ?
                        );
                    """)
                    defer { capsules.reset() }
                    try capsules.bind(1, projectID)
                    _ = try capsules.step()
                }

                return .init(
                    recoveryObjects: recoveryCount,
                    sessionLearnRecords: learnCount,
                    rolloverCapsules: retentionDays == 0 ? capsuleCount : 0
                )
            }
        }
    }

    public func deleteProjectData(projectID: String, now: Date = Date()) throws -> TokenSaverProjectDataDeletionResult {
        try db.performSync { database in
            try database.transaction {
                let recoveryCount = try count(
                    database,
                    sql: "SELECT COUNT(*) FROM token_saver_recovery_objects WHERE project_id = ? AND tombstoned_at_ms IS NULL;",
                    projectID: projectID
                )
                let learnCount = try count(
                    database,
                    sql: "SELECT COUNT(*) FROM token_saver_session_learn_records WHERE project_id = ? AND tombstoned_at_ms IS NULL;",
                    projectID: projectID
                )
                let capsuleCount = try count(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM token_saver_rollover_capsules
                        WHERE capsule_text != '' AND (
                            parent_thread_id IN (SELECT id FROM agent_threads WHERE project_id = ?)
                            OR child_thread_id IN (SELECT id FROM agent_threads WHERE project_id = ?)
                        );
                    """,
                    projectID: projectID,
                    bindTwice: true
                )
                let nowMS = Int64(now.timeIntervalSince1970 * 1_000)
                try execute(
                    database,
                    sql: "UPDATE token_saver_recovery_capabilities SET revoked_at_ms = ? WHERE object_id IN (SELECT id FROM token_saver_recovery_objects WHERE project_id = ?) AND revoked_at_ms IS NULL;",
                    projectID: projectID,
                    nowMS: nowMS
                )
                try execute(
                    database,
                    sql: "DELETE FROM token_saver_recovery_references WHERE object_id IN (SELECT id FROM token_saver_recovery_objects WHERE project_id = ?);",
                    projectID: projectID
                )
                try execute(
                    database,
                    sql: "UPDATE token_saver_recovery_outbox SET state = 'acked', transport_outcome = 'acked', updated_at_ms = ? WHERE object_id IN (SELECT id FROM token_saver_recovery_objects WHERE project_id = ?);",
                    projectID: projectID,
                    nowMS: nowMS
                )
                try execute(
                    database,
                    sql: "UPDATE token_saver_recovery_objects SET original = X'', integrity_sha256 = '', byte_count = 0, tombstoned_at_ms = ?, state = 'acked' WHERE project_id = ? AND tombstoned_at_ms IS NULL;",
                    projectID: projectID,
                    nowMS: nowMS
                )
                try execute(
                    database,
                    sql: "UPDATE token_saver_session_learn_records SET text = '', tombstoned_at_ms = ? WHERE project_id = ? AND tombstoned_at_ms IS NULL;",
                    projectID: projectID,
                    nowMS: nowMS
                )
                let capsuleMessages = try database.prepare("""
                    UPDATE agent_messages
                    SET content = 'TOKEN_SAVER_CAPSULE_REMOVED'
                    WHERE role = 'system' AND EXISTS (
                        SELECT 1 FROM token_saver_rollover_capsules c
                        WHERE c.capsule_text != ''
                          AND c.child_thread_id = agent_messages.thread_id
                          AND c.capsule_text = agent_messages.content
                          AND (
                              c.parent_thread_id IN (SELECT id FROM agent_threads WHERE project_id = ?)
                              OR c.child_thread_id IN (SELECT id FROM agent_threads WHERE project_id = ?)
                          )
                    );
                """)
                defer { capsuleMessages.reset() }
                try capsuleMessages.bind(1, projectID)
                try capsuleMessages.bind(2, projectID)
                _ = try capsuleMessages.step()
                let capsule = try database.prepare("""
                    UPDATE token_saver_rollover_capsules
                    SET capsule_text = '', capsule_sha256 = '', scope_transition_json = NULL
                    WHERE capsule_text != '' AND (
                        parent_thread_id IN (SELECT id FROM agent_threads WHERE project_id = ?)
                        OR child_thread_id IN (SELECT id FROM agent_threads WHERE project_id = ?)
                    );
                """)
                defer { capsule.reset() }
                try capsule.bind(1, projectID)
                try capsule.bind(2, projectID)
                _ = try capsule.step()
                let audit = try database.prepare("""
                    INSERT INTO token_saver_audit_events
                        (event_kind, project_id, count_value, reason, created_at_ms)
                    VALUES ('project_data_deleted', ?, ?, 'user_requested', ?);
                """)
                defer { audit.reset() }
                try audit.bind(1, projectID)
                try audit.bind(2, Int64(recoveryCount + learnCount + capsuleCount))
                try audit.bind(3, nowMS)
                _ = try audit.step()
                return .init(
                    recoveryObjects: recoveryCount,
                    sessionLearnRecords: learnCount,
                    rolloverCapsules: capsuleCount
                )
            }
        }
    }

    public func performLifecycleSweep(now: Date = Date()) throws -> TokenSaverLifecycleSweepResult {
        let nowMS = Int64(now.timeIntervalSince1970 * 1_000)
        return try db.performSync { database in
            try database.transaction {
                let expiredReferences = try database.prepare("""
                    DELETE FROM token_saver_recovery_references
                    WHERE expires_at_ms IS NOT NULL AND expires_at_ms <= ?;
                """)
                defer { expiredReferences.reset() }
                try expiredReferences.bind(1, nowMS)
                _ = try expiredReferences.step()

                let recoveryPredicate = """
                    tombstoned_at_ms IS NULL AND (
                        (expires_at_ms IS NOT NULL AND expires_at_ms <= ?)
                        OR NOT EXISTS (SELECT 1 FROM projects p WHERE p.id = token_saver_recovery_objects.project_id)
                        OR NOT EXISTS (SELECT 1 FROM agent_threads t WHERE t.id = token_saver_recovery_objects.thread_id)
                        OR NOT EXISTS (
                            SELECT 1 FROM token_saver_lane_state l
                            WHERE l.project_id = token_saver_recovery_objects.project_id
                              AND l.lane = token_saver_recovery_objects.lane
                              AND l.retention_days > 0 AND l.opted_out = 0
                              AND token_saver_recovery_objects.created_at_ms > \(nowMS) - (l.retention_days * 86400000)
                        )
                    )
                    AND NOT EXISTS (
                        SELECT 1 FROM token_saver_recovery_references r
                        WHERE r.object_id = token_saver_recovery_objects.id
                    )
                """
                let recoveryCountStatement = try database.prepare(
                    "SELECT COUNT(*) FROM token_saver_recovery_objects WHERE \(recoveryPredicate);"
                )
                defer { recoveryCountStatement.reset() }
                try recoveryCountStatement.bind(1, nowMS)
                let recoveryCount = try recoveryCountStatement.step() ? Int(recoveryCountStatement.columnInt64(0)) : 0

                let revoke = try database.prepare("""
                    UPDATE token_saver_recovery_capabilities SET revoked_at_ms = ?
                    WHERE revoked_at_ms IS NULL AND object_id IN (
                        SELECT id FROM token_saver_recovery_objects WHERE \(recoveryPredicate)
                    );
                """)
                defer { revoke.reset() }
                try revoke.bind(1, nowMS)
                try revoke.bind(2, nowMS)
                _ = try revoke.step()

                let references = try database.prepare("""
                    DELETE FROM token_saver_recovery_references WHERE object_id IN (
                        SELECT id FROM token_saver_recovery_objects WHERE \(recoveryPredicate)
                    );
                """)
                defer { references.reset() }
                try references.bind(1, nowMS)
                _ = try references.step()

                let recovery = try database.prepare("""
                    UPDATE token_saver_recovery_objects
                    SET original = X'', integrity_sha256 = '', byte_count = 0,
                        tombstoned_at_ms = ?, state = 'acked'
                    WHERE \(recoveryPredicate);
                """)
                defer { recovery.reset() }
                try recovery.bind(1, nowMS)
                try recovery.bind(2, nowMS)
                _ = try recovery.step()

                let outbox = try database.prepare("""
                    UPDATE token_saver_recovery_outbox
                    SET state = 'acked', transport_outcome = 'acked', updated_at_ms = ?
                    WHERE object_id IN (
                        SELECT id FROM token_saver_recovery_objects WHERE tombstoned_at_ms = ?
                    );
                """)
                defer { outbox.reset() }
                try outbox.bind(1, nowMS)
                try outbox.bind(2, nowMS)
                _ = try outbox.step()

                let learnPredicate = """
                    tombstoned_at_ms IS NULL AND (
                        (expires_at_ms IS NOT NULL AND expires_at_ms <= ?)
                        OR NOT EXISTS (SELECT 1 FROM projects p WHERE p.id = token_saver_session_learn_records.project_id)
                        OR NOT EXISTS (SELECT 1 FROM agent_threads t WHERE t.id = token_saver_session_learn_records.thread_id)
                        OR NOT EXISTS (
                            SELECT 1 FROM token_saver_lane_state l
                            WHERE l.project_id = token_saver_session_learn_records.project_id
                              AND l.lane = token_saver_session_learn_records.lane
                              AND l.retention_days > 0 AND l.opted_out = 0
                              AND token_saver_session_learn_records.created_at_ms > \(nowMS) - (l.retention_days * 86400000)
                        )
                    )
                """
                let learnCountStatement = try database.prepare(
                    "SELECT COUNT(*) FROM token_saver_session_learn_records WHERE \(learnPredicate);"
                )
                defer { learnCountStatement.reset() }
                try learnCountStatement.bind(1, nowMS)
                let learnCount = try learnCountStatement.step() ? Int(learnCountStatement.columnInt64(0)) : 0

                let learn = try database.prepare("""
                    UPDATE token_saver_session_learn_records
                    SET text = '', tombstoned_at_ms = ? WHERE \(learnPredicate);
                """)
                defer { learn.reset() }
                try learn.bind(1, nowMS)
                try learn.bind(2, nowMS)
                _ = try learn.step()

                let capsulePredicate = """
                    capsule_text != '' AND (
                        NOT EXISTS (SELECT 1 FROM agent_threads p WHERE p.id = token_saver_rollover_capsules.parent_thread_id)
                        OR NOT EXISTS (SELECT 1 FROM agent_threads c WHERE c.id = token_saver_rollover_capsules.child_thread_id)
                        OR NOT EXISTS (
                            SELECT 1
                            FROM agent_threads p
                            JOIN token_saver_lane_state l ON l.project_id = p.project_id AND l.lane = 'rollover_capsule'
                            WHERE p.id = token_saver_rollover_capsules.parent_thread_id
                        )
                        OR EXISTS (
                            SELECT 1
                            FROM agent_threads p
                            JOIN token_saver_lane_state l ON l.project_id = p.project_id AND l.lane = 'rollover_capsule'
                            WHERE p.id = token_saver_rollover_capsules.parent_thread_id
                              AND (
                                  l.opted_out = 1
                                  OR l.retention_days = 0
                                  OR token_saver_rollover_capsules.created_at_ms <= ? - (l.retention_days * 86400000)
                              )
                        )
                    )
                """
                let capsuleCountStatement = try database.prepare(
                    "SELECT COUNT(*) FROM token_saver_rollover_capsules WHERE \(capsulePredicate);"
                )
                defer { capsuleCountStatement.reset() }
                try capsuleCountStatement.bind(1, nowMS)
                let capsuleCount = try capsuleCountStatement.step() ? Int(capsuleCountStatement.columnInt64(0)) : 0

                let capsuleMessages = try database.prepare("""
                    UPDATE agent_messages
                    SET content = 'TOKEN_SAVER_CAPSULE_REMOVED'
                    WHERE role = 'system' AND EXISTS (
                        SELECT 1 FROM token_saver_rollover_capsules
                        WHERE child_thread_id = agent_messages.thread_id
                          AND capsule_text = agent_messages.content
                          AND \(capsulePredicate)
                    );
                """)
                defer { capsuleMessages.reset() }
                try capsuleMessages.bind(1, nowMS)
                _ = try capsuleMessages.step()

                let capsule = try database.prepare("""
                    UPDATE token_saver_rollover_capsules
                    SET capsule_text = '', capsule_sha256 = '', scope_transition_json = NULL
                    WHERE \(capsulePredicate);
                """)
                defer { capsule.reset() }
                try capsule.bind(1, nowMS)
                _ = try capsule.step()

                let total = recoveryCount + learnCount + capsuleCount
                if total > 0 {
                    let audit = try database.prepare("""
                        INSERT INTO token_saver_audit_events
                            (event_kind, count_value, reason, created_at_ms)
                        VALUES ('lifecycle_sweep', ?, 'expiry_or_orphan', ?);
                    """)
                    defer { audit.reset() }
                    try audit.bind(1, Int64(total))
                    try audit.bind(2, nowMS)
                    _ = try audit.step()
                }
                return TokenSaverLifecycleSweepResult(
                    recoveryObjects: recoveryCount,
                    sessionLearnRecords: learnCount,
                    rolloverCapsules: capsuleCount
                )
            }
        }
    }

    private func count(
        _ database: SQLiteDB,
        sql: String,
        projectID: String,
        bindTwice: Bool = false
    ) throws -> Int {
        let statement = try database.prepare(sql)
        defer { statement.reset() }
        try statement.bind(1, projectID)
        if bindTwice { try statement.bind(2, projectID) }
        return try statement.step() ? Int(statement.columnInt64(0)) : 0
    }

    private func execute(
        _ database: SQLiteDB,
        sql: String,
        projectID: String,
        nowMS: Int64? = nil
    ) throws {
        let statement = try database.prepare(sql)
        defer { statement.reset() }
        if let nowMS {
            try statement.bind(1, nowMS)
            try statement.bind(2, projectID)
        } else {
            try statement.bind(1, projectID)
        }
        _ = try statement.step()
    }
}

// MARK: - Per-project lane governance

public enum TokenSaverPromotionEvidenceLevel: String, Sendable, Codable, CaseIterable {
    case providerUsage = "provider_usage"
    case providerTokenizedPayload = "provider_tokenized_payload"
    case diagnosticHeuristic = "diagnostic_heuristic"
    case hypothesis
    case unavailable
}

public struct TokenSaverLaneStateRecord: Sendable, Equatable {
    public let projectID: String
    public let lane: String
    public let state: String
    public let reason: String
    public let evidenceLevel: String
    public let typedEvidenceLevel: TokenSaverPromotionEvidenceLevel
    public let attributionJoined: Bool
    public let reconciliationPassed: Bool
    public let usageSemanticsAvailable: Bool
    public let scorecardID: String
    public let ownerRole: String
    public let permissionBoundary: String
    public let retentionDays: Int
    public let optedOut: Bool
    public let killSwitchActive: Bool

    public init(
        projectID: String,
        lane: String,
        state: String,
        reason: String,
        evidenceLevel: String,
        ownerRole: String,
        permissionBoundary: String,
        retentionDays: Int,
        optedOut: Bool,
        killSwitchActive: Bool,
        attributionJoined: Bool = false,
        reconciliationPassed: Bool = false,
        usageSemanticsAvailable: Bool = false,
        scorecardID: String = ""
    ) {
        self.projectID = projectID
        self.lane = lane
        self.state = state
        self.reason = reason
        let typedEvidence = TokenSaverPromotionEvidenceLevel(rawValue: evidenceLevel) ?? .unavailable
        self.evidenceLevel = typedEvidence.rawValue
        self.typedEvidenceLevel = typedEvidence
        self.attributionJoined = attributionJoined
        self.reconciliationPassed = reconciliationPassed
        self.usageSemanticsAvailable = usageSemanticsAvailable
        self.scorecardID = scorecardID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ownerRole = ownerRole
        self.permissionBoundary = permissionBoundary
        self.retentionDays = max(0, retentionDays)
        self.optedOut = optedOut
        self.killSwitchActive = killSwitchActive
    }
}

public final class TokenSaverLaneStateRepository: @unchecked Sendable {
    private let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

    public func upsert(_ record: TokenSaverLaneStateRecord, now: Date = Date()) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                INSERT INTO token_saver_lane_state
                    (project_id, lane, state, reason, evidence_level, owner_role,
                     permission_boundary, retention_days, opted_out,
                     kill_switch_active, attribution_joined, reconciliation_passed,
                     usage_semantics_available, scorecard_id, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(project_id, lane) DO UPDATE SET
                    state = excluded.state,
                    reason = excluded.reason,
                    evidence_level = excluded.evidence_level,
                    owner_role = excluded.owner_role,
                    permission_boundary = excluded.permission_boundary,
                    retention_days = excluded.retention_days,
                    opted_out = excluded.opted_out,
                    kill_switch_active = excluded.kill_switch_active,
                    attribution_joined = excluded.attribution_joined,
                    reconciliation_passed = excluded.reconciliation_passed,
                    usage_semantics_available = excluded.usage_semantics_available,
                    scorecard_id = excluded.scorecard_id,
                    updated_at_ms = excluded.updated_at_ms;
            """)
            defer { statement.reset() }
            try statement.bind(1, record.projectID)
            try statement.bind(2, record.lane)
            try statement.bind(3, record.state)
            try statement.bind(4, record.reason)
            try statement.bind(5, record.evidenceLevel)
            try statement.bind(6, record.ownerRole)
            try statement.bind(7, record.permissionBoundary)
            try statement.bind(8, Int64(record.retentionDays))
            try statement.bind(9, record.optedOut)
            try statement.bind(10, record.killSwitchActive)
            try statement.bind(11, record.attributionJoined)
            try statement.bind(12, record.reconciliationPassed)
            try statement.bind(13, record.usageSemanticsAvailable)
            try statement.bind(14, record.scorecardID)
            try statement.bind(15, Int64(now.timeIntervalSince1970 * 1_000))
            _ = try statement.step()
        }
    }

    public func get(projectID: String, lane: String) throws -> TokenSaverLaneStateRecord? {
        try db.performSync { database in
            let statement = try database.prepare("""
                SELECT project_id, lane, state, reason, evidence_level, owner_role,
                       permission_boundary, retention_days, opted_out, kill_switch_active,
                       attribution_joined, reconciliation_passed,
                       usage_semantics_available, scorecard_id
                FROM token_saver_lane_state
                WHERE project_id = ? AND lane = ? LIMIT 1;
            """)
            defer { statement.reset() }
            try statement.bind(1, projectID)
            try statement.bind(2, lane)
            guard try statement.step() else { return nil }
            return TokenSaverLaneStateRecord(
                projectID: statement.columnText(0) ?? "",
                lane: statement.columnText(1) ?? "",
                state: statement.columnText(2) ?? "off",
                reason: statement.columnText(3) ?? "",
                evidenceLevel: statement.columnText(4) ?? "unavailable",
                ownerRole: statement.columnText(5) ?? "",
                permissionBoundary: statement.columnText(6) ?? "project",
                retentionDays: Int(statement.columnInt64(7)),
                optedOut: statement.columnInt64(8) != 0,
                killSwitchActive: statement.columnInt64(9) != 0,
                attributionJoined: statement.columnInt64(10) != 0,
                reconciliationPassed: statement.columnInt64(11) != 0,
                usageSemanticsAvailable: statement.columnInt64(12) != 0,
                scorecardID: statement.columnText(13) ?? ""
            )
        }
    }

    public func list(projectID: String) throws -> [TokenSaverLaneStateRecord] {
        try db.performSync { database in
            let statement = try database.prepare("""
                SELECT project_id, lane, state, reason, evidence_level, owner_role,
                       permission_boundary, retention_days, opted_out, kill_switch_active,
                       attribution_joined, reconciliation_passed,
                       usage_semantics_available, scorecard_id
                FROM token_saver_lane_state WHERE project_id = ? ORDER BY lane;
            """)
            defer { statement.reset() }
            try statement.bind(1, projectID)
            var result: [TokenSaverLaneStateRecord] = []
            while try statement.step() {
                result.append(.init(
                    projectID: statement.columnText(0) ?? "",
                    lane: statement.columnText(1) ?? "",
                    state: statement.columnText(2) ?? "off",
                    reason: statement.columnText(3) ?? "",
                    evidenceLevel: statement.columnText(4) ?? "unavailable",
                    ownerRole: statement.columnText(5) ?? "",
                    permissionBoundary: statement.columnText(6) ?? "project",
                    retentionDays: Int(statement.columnInt64(7)),
                    optedOut: statement.columnInt64(8) != 0,
                    killSwitchActive: statement.columnInt64(9) != 0,
                    attributionJoined: statement.columnInt64(10) != 0,
                    reconciliationPassed: statement.columnInt64(11) != 0,
                    usageSemanticsAvailable: statement.columnInt64(12) != 0,
                    scorecardID: statement.columnText(13) ?? ""
                ))
            }
            return result
        }
    }

    public func ensureDefaults(projectID: String) throws {
        try db.performSync { database in
            try database.transaction {
                try self.insertDefaults(database: database, projectID: projectID)
            }
        }
    }

    public func setOptOut(projectID: String, optedOut: Bool, now: Date = Date()) throws {
        try db.performSync { database in
            try database.transaction {
                try self.insertDefaults(database: database, projectID: projectID, now: now)
                let statement = try database.prepare("""
                    UPDATE token_saver_lane_state
                    SET opted_out = ?,
                        state = CASE WHEN ? = 1 THEN 'off' ELSE state END,
                        kill_switch_active = CASE WHEN ? = 1 THEN 1 ELSE kill_switch_active END,
                        reason = CASE WHEN ? = 1 THEN 'project_opted_out' ELSE reason END,
                        updated_at_ms = ?
                    WHERE project_id = ?;
                """)
                defer { statement.reset() }
                try statement.bind(1, optedOut)
                try statement.bind(2, optedOut)
                try statement.bind(3, optedOut)
                try statement.bind(4, optedOut)
                try statement.bind(5, Int64(now.timeIntervalSince1970 * 1_000))
                try statement.bind(6, projectID)
                _ = try statement.step()
            }
        }
    }

    public func setRetentionDays(projectID: String, days: Int, now: Date = Date()) throws {
        try db.performSync { database in
            try database.transaction {
                try self.insertDefaults(database: database, projectID: projectID, now: now)
                let statement = try database.prepare("""
                    UPDATE token_saver_lane_state SET retention_days = ?, updated_at_ms = ? WHERE project_id = ?;
                """)
                defer { statement.reset() }
                try statement.bind(1, Int64(max(0, days)))
                try statement.bind(2, Int64(now.timeIntervalSince1970 * 1_000))
                try statement.bind(3, projectID)
                _ = try statement.step()
            }
        }
    }

    public func forceVerbatim(projectID: String, now: Date = Date()) throws {
        try db.performSync { database in
            try database.transaction {
                try self.insertDefaults(database: database, projectID: projectID, now: now)
                let statement = try database.prepare("""
                    UPDATE token_saver_lane_state
                    SET state = 'off', reason = 'verbatim_forced', kill_switch_active = 1, updated_at_ms = ?
                    WHERE project_id = ?;
                """)
                defer { statement.reset() }
                try statement.bind(1, Int64(now.timeIntervalSince1970 * 1_000))
                try statement.bind(2, projectID)
                _ = try statement.step()
            }
        }
    }

    fileprivate func insertDefaults(database: SQLiteDB, projectID: String, now: Date = Date()) throws {
        let defaults: [(lane: String, state: String, reason: String, evidence: String, owner: String, retention: Int, killSwitch: Bool)] = [
            ("measurement", "shadow_only", "content_free_exact_scope_observation_only", "diagnostic_heuristic", "Measurement Owner", 0, false),
            ("provider_native", "shadow_only", "shadow_observation_no_provider_behavior_change", "unavailable", "Provider Compatibility Owner", 0, true),
            ("deterministic_wrapper", "off", "owner_and_scorecard_required", "unavailable", "Operations Owner", 0, true),
            ("exact_repetition", "off", "owner_and_scorecard_required", "unavailable", "Security Owner", 0, true),
            ("lexical_retrieval", "off", "owner_and_scorecard_required", "unavailable", "Product Owner", 0, true),
            ("rollover_capsule", "off", "owner_and_scorecard_required", "unavailable", "Provider Compatibility Owner", 0, true),
            ("session_learn", "off", "owner_and_scorecard_required", "unavailable", "Security Owner", 0, true),
            ("semantic_prose", "off", "owner_and_scorecard_required", "unavailable", "Model Supply-Chain Owner", 0, true),
            ("adaptive_effort", "off", "owner_and_scorecard_required", "unavailable", "Product Owner", 0, true),
            ("visual_artifact", "off", "owner_and_scorecard_required", "unavailable", "Model Supply-Chain Owner", 0, true),
        ]
        let statement = try database.prepare("""
            INSERT OR IGNORE INTO token_saver_lane_state
                (project_id, lane, state, reason, evidence_level, owner_role,
                 permission_boundary, retention_days, opted_out,
                 kill_switch_active, updated_at_ms)
            VALUES (?, ?, ?, ?, ?, ?, 'project', ?, 0, ?, ?);
        """)
        defer { statement.reset() }
        for item in defaults {
            statement.reset()
            try statement.bind(1, projectID)
            try statement.bind(2, item.lane)
            try statement.bind(3, item.state)
            try statement.bind(4, item.reason)
            try statement.bind(5, item.evidence)
            try statement.bind(6, "unassigned:\(item.owner)")
            try statement.bind(7, Int64(item.retention))
            try statement.bind(8, item.killSwitch)
            try statement.bind(9, Int64(now.timeIntervalSince1970 * 1_000))
            _ = try statement.step()
        }
    }
}
