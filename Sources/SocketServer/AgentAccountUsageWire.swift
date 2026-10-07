import AgentRuntime
import CoreModel
import Foundation

/// `agent.account.usage.get`: the host's stored provider account usage, read
/// from disk without probing any provider (contract in
/// AgentAccountUsageContracts.swift).
public enum AgentAccountUsageWire {
    /// Every managed provider, always in this order (part of the contract).
    static let providers: [AgentProvider] = [.claude, .codex, .grok]

    /// Reads the usage file; call off the main actor.
    public static func load(appSupportDirectory: URL, now: Date = Date()) -> JSONValue {
        let store = ProviderUsageStore(appSupportDirectory: appSupportDirectory, now: { now })
        let storedAt = (try? FileManager.default.attributesOfItem(atPath: store.storeURL.path))?[.modificationDate] as? Date
        return payload(snapshot: store.load(), storedAt: storedAt, now: now)
    }

    static func payload(snapshot: ProviderUsageSnapshot, storedAt: Date?, now: Date) -> JSONValue {
        let rows: [JSONValue] = providers.map { provider in
            let usage = snapshot.providers.first { $0.provider == provider }
                ?? ProviderTokenUsage(provider: provider)
            return .object([
                "provider": .string(provider.rawValue),
                "weekly_used_percent": number(usage.effectiveWeeklyUsedPercent(now: now)),
                "weekly_window_duration_minutes": number(usage.weeklyWindowDurationMinutes.map(Double.init)),
                "weekly_resets_at_ms": milliseconds(usage.weeklyResetsAt),
                "current_session_used_percent": number(usage.effectiveSessionUsedPercent(now: now)),
                "current_session_resets_at_ms": milliseconds(usage.currentSessionResetsAt),
            ])
        }
        return .object([
            "providers": .array(rows),
            "stored_at_ms": milliseconds(storedAt),
        ])
    }

    private static func number(_ value: Double?) -> JSONValue {
        value.map { .number($0) } ?? .null
    }

    private static func milliseconds(_ date: Date?) -> JSONValue {
        number(date.map { ($0.timeIntervalSince1970 * 1000).rounded() })
    }
}
