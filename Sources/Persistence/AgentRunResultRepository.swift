import CoreModel
import Foundation

public final class AgentRunResultRepository: @unchecked Sendable {
    private let db: SQLiteDB

    public init(db: SQLiteDB) { self.db = db }

    public func get(runId: AgentRunID) throws -> AgentRunResult? {
        try db.performSync { database in
            let statement = try database.prepare("""
                SELECT run_id, final_message_id, summary, viewed_at, attention_acknowledged_at
                FROM agent_run_results WHERE run_id = ? LIMIT 1;
                """)
            try statement.bind(1, runId.description)
            guard try statement.step() else { return nil }
            return Self.decode(statement)
        }
    }

    public func list(runIds: [AgentRunID]) throws -> [AgentRunResult] {
        guard !runIds.isEmpty else { return [] }
        let ids = Array(Set(runIds.map(\.description))).sorted().prefix(500)
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return try db.performSync { database in
            let statement = try database.prepare("""
                SELECT run_id, final_message_id, summary, viewed_at, attention_acknowledged_at
                FROM agent_run_results WHERE run_id IN (\(placeholders)) ORDER BY run_id;
                """)
            for (index, id) in ids.enumerated() { try statement.bind(Int32(index + 1), id) }
            var results: [AgentRunResult] = []
            while try statement.step() { results.append(Self.decode(statement)) }
            return results
        }
    }

    public func setViewed(runIds: [AgentRunID], viewedAt: Date?) throws -> [AgentRunID] {
        let ids = Array(Set(runIds.map(\.description))).sorted().prefix(500)
        guard !ids.isEmpty else { return [] }
        return try db.performSync { database in
            try database.transaction {
                var updated: [AgentRunID] = []
                let statement = try database.prepare("UPDATE agent_run_results SET viewed_at = ? WHERE run_id = ?;")
                for value in ids {
                    try statement.bind(1, viewedAt.map(isoFractional.string(from:)))
                    try statement.bind(2, value)
                    _ = try statement.step()
                    statement.reset()
                    let id = AgentRunID(UUID(uuidString: value)!)
                    if try Self.exists(database, id: value) { updated.append(id) }
                }
                return updated
            }
        }
    }

    /// Applies exact prior timestamps. Missing map key leaves row untouched; null clears viewed state.
    public func restoreViewed(_ viewedAtByRunId: [AgentRunID: Date?]) throws {
        try db.performSync { database in
            try database.transaction {
                let statement = try database.prepare("UPDATE agent_run_results SET viewed_at = ? WHERE run_id = ?;")
                for (id, date) in viewedAtByRunId {
                    try statement.bind(1, date.map(isoFractional.string(from:)))
                    try statement.bind(2, id.description)
                    _ = try statement.step()
                    statement.reset()
                }
            }
        }
    }

    /// Acknowledgment is valid only while canonical run status remains failed or interrupted.
    @discardableResult
    public func acknowledgeFailure(runId: AgentRunID, at date: Date = Date()) throws -> Bool {
        try db.performSync { database in
            try database.transaction {
                let eligible = try database.prepare("SELECT 1 FROM agent_runs WHERE id = ? AND (status IN ('failed', 'interrupted') OR (status = 'cancelled' AND COALESCE(terminal_reason, '') != 'userStop')); ")
                try eligible.bind(1, runId.description)
                guard try eligible.step() else { return false }
                let ensure = try database.prepare("INSERT OR IGNORE INTO agent_run_results(run_id) VALUES (?);")
                try ensure.bind(1, runId.description)
                _ = try ensure.step()
                let statement = try database.prepare("UPDATE agent_run_results SET attention_acknowledged_at = ? WHERE run_id = ?;")
                try statement.bind(1, isoFractional.string(from: date))
                try statement.bind(2, runId.description)
                _ = try statement.step()
                return true
            }
        }
    }

    func upsertTerminal(runId: AgentRunID, finalMessageId: AgentMessageID?, summary: String?) throws {
        let safeSummary = Self.safeSummary(summary)
        let statement = try db.prepare("""
            INSERT INTO agent_run_results(run_id, final_message_id, summary)
            VALUES (?, ?, ?)
            ON CONFLICT(run_id) DO UPDATE SET
                final_message_id = COALESCE(excluded.final_message_id, agent_run_results.final_message_id),
                summary = COALESCE(excluded.summary, agent_run_results.summary);
            """)
        try statement.bind(1, runId.description)
        try statement.bind(2, finalMessageId?.description)
        try statement.bind(3, safeSummary)
        _ = try statement.step()
    }

    private static func exists(_ db: SQLiteDB, id: String) throws -> Bool {
        let statement = try db.prepare("SELECT 1 FROM agent_run_results WHERE run_id = ?;")
        try statement.bind(1, id)
        return try statement.step()
    }

    private static func decode(_ statement: SQLiteStatement) -> AgentRunResult {
        let date: (Int32) -> Date? = { statement.columnText($0).flatMap(isoFractional.date(from:)) }
        return AgentRunResult(
            runId: AgentRunID(UUID(uuidString: statement.columnText(0)!)!),
            finalMessageId: statement.columnText(1).flatMap(UUID.init(uuidString:)).map(AgentMessageID.init),
            summary: statement.columnText(2),
            viewedAt: date(3),
            attentionAcknowledgedAt: date(4)
        )
    }

    public static func safeSummary(_ value: String?) -> String? {
        guard let value else { return nil }
        var text = AssistantToolMarkupSanitizer.strip(value)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        for pattern in [#"(?i)["'`]?(api[_-]?key|access[_-]?token|token|secret|password)["'`]?\s*[:=]\s*(?:"(?:\\.|[^"\\])*(?:"|$)|'(?:\\.|[^'\\])*(?:'|$)|`[^`]*(?:`|$)|[^\s,;]+)"#, #"(?i)bearer\s+[A-Za-z0-9._~+/-]+"#, #"\bsk-[A-Za-z0-9_-]{8,}\b"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[REDACTED]")
        }
        return String(text.prefix(500)).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
