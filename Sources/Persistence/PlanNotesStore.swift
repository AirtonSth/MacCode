import Foundation
import CoreModel

/// Persists per-thread plan notes keyed by thread ID.
/// Mirrors PromptHistoryStore: thin wrapper over SettingsWriteRepository so
/// the storage layer is injectable for tests without a live SQLite DB.
public final class PlanNotesStore {

    private let repo: any SettingsWriteRepository

    public init(db: SQLiteDB) {
        self.repo = SettingsRepository(db: db)
    }

    /// Seam for testing: inject any SettingsWriteRepository.
    public init(repo: any SettingsWriteRepository) {
        self.repo = repo
    }

    /// Returns the full plan notes for the thread, or "" when absent.
    public func load(threadId: AgentThreadID) throws -> String {
        try repo.get(Self.storageKey(for: threadId)) ?? ""
    }

    /// Persists the plan notes for the thread. Passing "" overwrites prior content.
    public func save(_ notes: String, threadId: AgentThreadID) throws {
        try repo.set(Self.storageKey(for: threadId), notes)
    }

    /// Stable, deterministic key for a thread. Public for test assertions.
    public static func storageKey(for threadId: AgentThreadID) -> String {
        "agent.plan_notes.\(threadId.value.uuidString)"
    }
}
