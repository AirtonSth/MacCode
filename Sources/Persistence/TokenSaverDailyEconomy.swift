import Foundation

/// One calendar-day row of the **credible** vs-bare-agent economy.
/// Week totals are the **sum of these daily rows** (not a re-estimate on the week aggregate).
public struct TokenSaverDailyEconomyRecord: Sendable, Equatable {
    public let dayStartMs: Int64
    public let measuredTokens: Int
    public let dialectTokens: Int
    public let graphifyTokens: Int
    public let orchestrationTokens: Int
    public let totalCredible: Int
    public let windowUsageTokens: Int
    public let formulaVersion: String
    public let appliedOutputShare: Double
    public let graphifySignalCount: Int
    public let updatedAt: String
    /// Pre-cap dialect estimate (evidence; collapse detection).
    public let dialectRawTokens: Int
    /// Pre-cap graphify estimate (evidence).
    public let graphifyRawTokens: Int
    /// Which cap bound the attributed scale: none | no_proof_allowance |
    /// measured_multiple | usage_share.
    public let capBinding: String
    /// Billed window units used for usage-anchored legs; 0 when unknown/unavailable.
    public let windowUsageBilledUnits: Double

    public init(
        dayStartMs: Int64,
        measuredTokens: Int,
        dialectTokens: Int,
        graphifyTokens: Int,
        orchestrationTokens: Int = 0,
        totalCredible: Int,
        windowUsageTokens: Int,
        formulaVersion: String,
        appliedOutputShare: Double,
        graphifySignalCount: Int = 0,
        updatedAt: String,
        dialectRawTokens: Int = 0,
        graphifyRawTokens: Int = 0,
        capBinding: String = "none",
        windowUsageBilledUnits: Double = 0
    ) {
        self.dayStartMs = dayStartMs
        self.measuredTokens = max(0, measuredTokens)
        self.dialectTokens = max(0, dialectTokens)
        self.graphifyTokens = max(0, graphifyTokens)
        self.orchestrationTokens = max(0, orchestrationTokens)
        self.totalCredible = max(0, totalCredible)
        self.windowUsageTokens = max(0, windowUsageTokens)
        self.formulaVersion = formulaVersion
        self.appliedOutputShare = appliedOutputShare
        self.graphifySignalCount = max(0, graphifySignalCount)
        self.updatedAt = updatedAt
        self.dialectRawTokens = max(0, dialectRawTokens)
        self.graphifyRawTokens = max(0, graphifyRawTokens)
        self.capBinding = capBinding
        self.windowUsageBilledUnits = max(0, windowUsageBilledUnits)
    }
}

/// Persists per-day credible totals so Week = Σ(day.total_credible).
/// Does **not** backfill historical days; only upserts days that are recomputed going forward.
public final class TokenSaverDailyEconomyRepository: @unchecked Sendable {
    /// v4: monotone caps + billed denominator + displacement bound + raw/cap evidence columns.
    /// WHY: label mixed v3/v4 rows so they are never silently compared.
    public static let formulaVersion = "credible_v4"

    private let db: SQLiteDB
    private let calendar: Calendar
    private static let isoFormatter = ISO8601DateFormatter()

    public init(db: SQLiteDB, calendar: Calendar = .current) {
        self.db = db
        self.calendar = calendar
    }

    public func dayStartMs(for date: Date = Date()) -> Int64 {
        Int64(calendar.startOfDay(for: date).timeIntervalSince1970 * 1000)
    }

    public func dayEndMsExclusive(for date: Date = Date()) -> Int64 {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return Int64(end.timeIntervalSince1970 * 1000)
    }

    @discardableResult
    public func upsert(_ record: TokenSaverDailyEconomyRecord) throws -> TokenSaverDailyEconomyRecord {
        try write(record)
        return record
    }

    public func record(dayStartMs: Int64) throws -> TokenSaverDailyEconomyRecord? {
        try db.performSync { database in
            let stmt = try database.prepare("""
                SELECT day_start_ms, measured_tokens, dialect_tokens, graphify_tokens,
                       orchestration_tokens, total_credible, window_usage_tokens,
                       formula_version, applied_output_share, graphify_signal_count, updated_at,
                       dialect_raw_tokens, graphify_raw_tokens, cap_binding, window_usage_billed_units
                FROM token_saver_daily_economy
                WHERE day_start_ms = ?
                LIMIT 1;
            """)
            defer { stmt.reset() }
            try stmt.bind(1, dayStartMs)
            guard try stmt.step() else { return nil }
            return Self.decode(stmt)
        }
    }

    public func records(fromDayStartMs: Int64, toDayStartMs: Int64) throws -> [TokenSaverDailyEconomyRecord] {
        try db.performSync { database in
            let stmt = try database.prepare("""
                SELECT day_start_ms, measured_tokens, dialect_tokens, graphify_tokens,
                       orchestration_tokens, total_credible, window_usage_tokens,
                       formula_version, applied_output_share, graphify_signal_count, updated_at,
                       dialect_raw_tokens, graphify_raw_tokens, cap_binding, window_usage_billed_units
                FROM token_saver_daily_economy
                WHERE day_start_ms >= ? AND day_start_ms <= ?
                ORDER BY day_start_ms ASC;
            """)
            defer { stmt.reset() }
            try stmt.bind(1, fromDayStartMs)
            try stmt.bind(2, toDayStartMs)
            var rows: [TokenSaverDailyEconomyRecord] = []
            while try stmt.step() {
                rows.append(Self.decode(stmt))
            }
            return rows
        }
    }

    /// Week/window total from stored daily rows only.
    public func sumTotalCredible(fromDayStartMs: Int64, toDayStartMs: Int64) throws -> Int {
        try db.performSync { database in
            let stmt = try database.prepare("""
                SELECT COALESCE(SUM(total_credible), 0)
                FROM token_saver_daily_economy
                WHERE day_start_ms >= ? AND day_start_ms <= ?;
            """)
            defer { stmt.reset() }
            try stmt.bind(1, fromDayStartMs)
            try stmt.bind(2, toDayStartMs)
            _ = try stmt.step()
            return Int(stmt.columnInt64(0))
        }
    }

    /// Measured pipes for one calendar day from the event ledger.
    public func measuredPipes(dayStartMs: Int64, dayEndMsExclusive: Int64) throws -> Int {
        try db.performSync { database in
            let stmt = try database.prepare("""
                SELECT COALESCE(SUM(saved_tokens), 0)
                FROM token_saver_savings
                WHERE created_at_ms >= ? AND created_at_ms < ?;
            """)
            defer { stmt.reset() }
            try stmt.bind(1, dayStartMs)
            try stmt.bind(2, dayEndMsExclusive)
            _ = try stmt.step()
            return Int(stmt.columnInt64(0))
        }
    }

    /// Measured pipes grouped by calendar day start ms for a window (for hybrid week totals).
    public func measuredPipesByDay(fromDayStartMs: Int64, toDayEndMsExclusive: Int64, calendar: Calendar = .current) throws -> [Int64: Int] {
        try db.performSync { database in
            let stmt = try database.prepare("""
                SELECT created_at_ms, COALESCE(saved_tokens, 0)
                FROM token_saver_savings
                WHERE created_at_ms >= ? AND created_at_ms < ?;
            """)
            defer { stmt.reset() }
            try stmt.bind(1, fromDayStartMs)
            try stmt.bind(2, toDayEndMsExclusive)
            var byDay: [Int64: Int] = [:]
            while try stmt.step() {
                let created = stmt.columnInt64(0)
                let saved = Int(stmt.columnInt64(1))
                let dayStart = Int64(
                    calendar.startOfDay(for: Date(timeIntervalSince1970: Double(created) / 1000.0))
                        .timeIntervalSince1970 * 1000
                )
                byDay[dayStart, default: 0] += max(0, saved)
            }
            return byDay
        }
    }

    /// UI window total:
    /// - days **with** economy rows → `total_credible` (full formula, going forward)
    /// - days **without** rows (pre-feature) → measured pipes only (no retroactive rewrite)
    public func windowTotalCredible(
        fromDayStartMs: Int64,
        toDayStartMs: Int64,
        toDayEndMsExclusive: Int64
    ) throws -> (total: Int, economyDays: Int, measuredOnlyDays: Int) {
        let economy = try records(fromDayStartMs: fromDayStartMs, toDayStartMs: toDayStartMs)
        let economyDays = Set(economy.map(\.dayStartMs))
        var total = economy.reduce(0) { $0 + $1.totalCredible }
        let measuredByDay = try measuredPipesByDay(
            fromDayStartMs: fromDayStartMs,
            toDayEndMsExclusive: toDayEndMsExclusive
        )
        var measuredOnly = 0
        for (day, measured) in measuredByDay {
            if !economyDays.contains(day) {
                total += measured
                measuredOnly += 1
            }
        }
        return (total, economy.count, measuredOnly)
    }

    private func write(_ record: TokenSaverDailyEconomyRecord) throws {
        try db.performSync { database in
            let stmt = try database.prepare("""
                INSERT INTO token_saver_daily_economy (
                    day_start_ms, measured_tokens, dialect_tokens, graphify_tokens,
                    orchestration_tokens, total_credible, window_usage_tokens,
                    formula_version, applied_output_share, graphify_signal_count, updated_at,
                    dialect_raw_tokens, graphify_raw_tokens, cap_binding, window_usage_billed_units
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(day_start_ms) DO UPDATE SET
                    measured_tokens = excluded.measured_tokens,
                    dialect_tokens = excluded.dialect_tokens,
                    graphify_tokens = excluded.graphify_tokens,
                    orchestration_tokens = excluded.orchestration_tokens,
                    total_credible = excluded.total_credible,
                    window_usage_tokens = excluded.window_usage_tokens,
                    formula_version = excluded.formula_version,
                    applied_output_share = excluded.applied_output_share,
                    graphify_signal_count = excluded.graphify_signal_count,
                    updated_at = excluded.updated_at,
                    dialect_raw_tokens = excluded.dialect_raw_tokens,
                    graphify_raw_tokens = excluded.graphify_raw_tokens,
                    cap_binding = excluded.cap_binding,
                    window_usage_billed_units = excluded.window_usage_billed_units;
            """)
            defer { stmt.reset() }
            try stmt.bind(1, record.dayStartMs)
            try stmt.bind(2, Int64(record.measuredTokens))
            try stmt.bind(3, Int64(record.dialectTokens))
            try stmt.bind(4, Int64(record.graphifyTokens))
            try stmt.bind(5, Int64(record.orchestrationTokens))
            try stmt.bind(6, Int64(record.totalCredible))
            try stmt.bind(7, Int64(record.windowUsageTokens))
            try stmt.bind(8, record.formulaVersion)
            try stmt.bind(9, record.appliedOutputShare)
            try stmt.bind(10, Int64(record.graphifySignalCount))
            try stmt.bind(11, record.updatedAt)
            try stmt.bind(12, Int64(record.dialectRawTokens))
            try stmt.bind(13, Int64(record.graphifyRawTokens))
            try stmt.bind(14, record.capBinding)
            try stmt.bind(15, record.windowUsageBilledUnits)
            _ = try stmt.step()
        }
    }

    private static func decode(_ stmt: SQLiteStatement) -> TokenSaverDailyEconomyRecord {
        TokenSaverDailyEconomyRecord(
            dayStartMs: stmt.columnInt64(0),
            measuredTokens: Int(stmt.columnInt64(1)),
            dialectTokens: Int(stmt.columnInt64(2)),
            graphifyTokens: Int(stmt.columnInt64(3)),
            orchestrationTokens: Int(stmt.columnInt64(4)),
            totalCredible: Int(stmt.columnInt64(5)),
            windowUsageTokens: Int(stmt.columnInt64(6)),
            formulaVersion: stmt.columnText(7) ?? TokenSaverDailyEconomyRepository.formulaVersion,
            appliedOutputShare: stmt.columnDouble(8),
            graphifySignalCount: Int(stmt.columnInt64(9)),
            updatedAt: stmt.columnText(10) ?? "",
            dialectRawTokens: Int(stmt.columnInt64(11)),
            graphifyRawTokens: Int(stmt.columnInt64(12)),
            capBinding: stmt.columnText(13) ?? "none",
            windowUsageBilledUnits: stmt.columnDouble(14)
        )
    }
}
