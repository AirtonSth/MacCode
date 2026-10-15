import Foundation

/// Directive appended to a free-text Titio desk run in the Notices inbox (§7).
/// The provider session never sees the rows the host wrote, so this tells the
/// model which notices were posted since the user's last message.
public enum TitioNoticeDirective {
    public static let maxRows = 12
    public static let maxTextCharacters = 200
    public static let closingRule = "You cannot approve or answer requests yourself; tell the user to tap the card or open the thread."

    /// Up to `maxRows` notices (the newest ones), oldest first, one line each:
    /// kind, state, the posted text (no choices block, max 200 chars) and ids.
    /// Nil when there is nothing to list.
    public static func text(rows: [TitioNoticeRecord], language: TitioNoticeLanguage = .en, timeZone: TimeZone = .current) -> String? {
        guard !rows.isEmpty else { return nil }
        let ordered = rows.sorted {
            $0.occurredAt == $1.occurredAt ? $0.key < $1.key : $0.occurredAt < $1.occurredAt
        }.suffix(maxRows)
        var lines = ["Notices RemoteCode posted in this Titio inbox since the user's last message (oldest first):"]
        for row in ordered {
            let body = TitioNoticeCopy.body(for: TitioNoticeRenderItem(record: row), language: language, timeZone: timeZone)
            let text = TitioNoticeCopy.clean(body, max: maxTextCharacters) ?? ""
            lines.append("- [\(row.kind.rawValue) · \(row.state.rawValue)] \(text) (\(ids(row)))")
        }
        lines.append(closingRule)
        return lines.joined(separator: "\n")
    }

    private static func ids(_ row: TitioNoticeRecord) -> String {
        var parts = ["key: \(row.key)"]
        let source = row.source
        let pairs: [(String, String?)] = [
            ("message", row.messageID),
            ("thread", source.threadId),
            ("run", source.runId),
            ("request", source.requestId),
            ("bot", source.botId),
            ("conversation", source.conversationId),
            ("scheduled_task", source.scheduledTaskId),
        ]
        for (name, value) in pairs {
            if let value, !value.isEmpty { parts.append("\(name): \(value)") }
        }
        return parts.joined(separator: ", ")
    }
}
