import Foundation

/// One recorded Graphify CLI use (or exploration sample for Phase-2 baseline).
public struct GraphifyUsageEvent: Sendable, Equatable {
    public let createdAtMs: Int64
    public let provider: String
    public let runId: String
    public let itemId: String
    public let subcommand: String
    public let answerTokens: Int
    public let source: String
    /// 1 only after a non-failed tool result (or successful empty output).
    public let ok: Bool

    public init(
        createdAtMs: Int64,
        provider: String,
        runId: String,
        itemId: String,
        subcommand: String,
        answerTokens: Int = 0,
        source: String = "event_stream",
        ok: Bool = false
    ) {
        self.createdAtMs = createdAtMs
        self.provider = provider
        self.runId = runId
        self.itemId = itemId
        self.subcommand = subcommand
        self.answerTokens = max(0, answerTokens)
        self.source = source
        self.ok = ok
    }
}

/// Day-scoped Graphify activity for the bare-user estimator.
public final class GraphifyUsageRepository: @unchecked Sendable {
    private let db: SQLiteDB
    private let calendar: Calendar

    /// Retention window matches Token Saver savings (7 days).
    public static let retentionDays: Int = 7

    public init(db: SQLiteDB, calendar: Calendar = .current) {
        self.db = db
        self.calendar = calendar
    }

    /// Insert a Graphify signal (pending until marked ok). Idempotent on (run,item,sub).
    @discardableResult
    public func insert(_ event: GraphifyUsageEvent) throws -> Bool {
        try db.performSync { database in
            let stmt = try database.prepare("""
                INSERT OR IGNORE INTO graphify_usage_events (
                    created_at_ms, provider, run_id, item_id, subcommand, answer_tokens, source, ok
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """)
            defer { stmt.reset() }
            try stmt.bind(1, event.createdAtMs)
            try stmt.bind(2, event.provider)
            try stmt.bind(3, event.runId)
            try stmt.bind(4, event.itemId)
            try stmt.bind(5, event.subcommand)
            try stmt.bind(6, Int64(event.answerTokens))
            try stmt.bind(7, event.source)
            try stmt.bind(8, event.ok ? 1 : 0)
            _ = try stmt.step()
            return true
        }
    }

    /// Mark tool result success: set answer size and ok=1.
    public func markSucceeded(runId: String, itemId: String, answerTokens: Int) throws {
        try db.performSync { database in
            let stmt = try database.prepare("""
                UPDATE graphify_usage_events
                SET answer_tokens = ?, ok = 1
                WHERE run_id = ? AND item_id = ?;
            """)
            defer { stmt.reset() }
            try stmt.bind(1, Int64(max(0, answerTokens)))
            try stmt.bind(2, runId)
            try stmt.bind(3, itemId)
            _ = try stmt.step()
        }
    }

    /// Drop pending/failed rows for an item (command not found, cancelled, failed state).
    public func deleteItem(runId: String, itemId: String) throws {
        try db.performSync { database in
            let stmt = try database.prepare("""
                DELETE FROM graphify_usage_events
                WHERE run_id = ? AND item_id = ?;
            """)
            defer { stmt.reset() }
            try stmt.bind(1, runId)
            try stmt.bind(2, itemId)
            _ = try stmt.step()
        }
    }

    /// Record a bare-agent exploration sample (Read/Grep/Glob output size).
    @discardableResult
    public func insertExplorationSample(
        createdAtMs: Int64,
        provider: String,
        runId: String,
        itemId: String,
        answerTokens: Int,
        toolName: String,
        ok: Bool = false
    ) throws -> Bool {
        let event = GraphifyUsageEvent(
            createdAtMs: createdAtMs,
            provider: provider,
            runId: runId,
            itemId: itemId,
            subcommand: "exploration:\(toolName.lowercased())",
            answerTokens: answerTokens,
            source: "exploration_sample",
            ok: ok
        )
        return try insert(event)
    }

    /// Count of **successful** Graphify query|path|explain signals in [start, end).
    public func signalCount(fromMs: Int64, toMsExclusive: Int64) throws -> Int {
        try db.performSync { database in
            let stmt = try database.prepare("""
                SELECT COUNT(*)
                FROM graphify_usage_events
                WHERE created_at_ms >= ? AND created_at_ms < ?
                  AND ok = 1
                  AND subcommand IN ('query', 'path', 'explain');
            """)
            defer { stmt.reset() }
            try stmt.bind(1, fromMs)
            try stmt.bind(2, toMsExclusive)
            _ = try stmt.step()
            return Int(stmt.columnInt64(0))
        }
    }

    /// Sum of answer tokens for successful Graphify signals in the window.
    public func answerTokensSum(fromMs: Int64, toMsExclusive: Int64) throws -> Int {
        try db.performSync { database in
            let stmt = try database.prepare("""
                SELECT COALESCE(SUM(answer_tokens), 0)
                FROM graphify_usage_events
                WHERE created_at_ms >= ? AND created_at_ms < ?
                  AND ok = 1
                  AND subcommand IN ('query', 'path', 'explain');
            """)
            defer { stmt.reset() }
            try stmt.bind(1, fromMs)
            try stmt.bind(2, toMsExclusive)
            _ = try stmt.step()
            return Int(stmt.columnInt64(0))
        }
    }

    /// Median answer_tokens of successful exploration samples in the last N days.
    /// Returns nil when fewer than `minSamples` rows exist.
    public func medianExplorationTokens(
        nowMs: Int64,
        lookbackDays: Int = 7,
        minSamples: Int = 8
    ) throws -> Int? {
        let fromMs = nowMs - Int64(lookbackDays) * 86_400_000
        let samples: [Int] = try db.performSync { database in
            let stmt = try database.prepare("""
                SELECT answer_tokens
                FROM graphify_usage_events
                WHERE created_at_ms >= ? AND created_at_ms <= ?
                  AND source = 'exploration_sample'
                  AND ok = 1
                  AND answer_tokens > 0
                ORDER BY answer_tokens ASC;
            """)
            defer { stmt.reset() }
            try stmt.bind(1, fromMs)
            try stmt.bind(2, nowMs)
            var rows: [Int] = []
            while try stmt.step() {
                rows.append(Int(stmt.columnInt64(0)))
            }
            return rows
        }
        guard samples.count >= minSamples else { return nil }
        let mid = samples.count / 2
        if samples.count % 2 == 0 {
            return (samples[mid - 1] + samples[mid]) / 2
        }
        return samples[mid]
    }

    /// Drop rows older than retention window.
    public func prune(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws {
        let cutoff = nowMs - Int64(Self.retentionDays) * 86_400_000
        try db.performSync { database in
            let stmt = try database.prepare("""
                DELETE FROM graphify_usage_events WHERE created_at_ms < ?;
            """)
            defer { stmt.reset() }
            try stmt.bind(1, cutoff)
            _ = try stmt.step()
        }
    }
}
