import Foundation
import CoreModel

public final class PromptHistoryStore {
    public static let limit = 200

    private let repo: any SettingsKeyValueRepository
    public var onWriteError: ((Error) -> Void)?
    // PERF: load/save allocated JSONDecoder/JSONEncoder per call. Concurrent
    // agent surfaces share stores — serialize under a short lock and reuse one
    // pair (wire JSON formatting unchanged).
    private let codecLock = NSLock()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(db: SQLiteDB) {
        self.repo = SettingsRepository(db: db)
    }

    init(repo: any SettingsKeyValueRepository) {
        self.repo = repo
    }

    public func load(workspaceID: WorkspaceID) -> [String] {
        guard let json = try? repo.get(key(for: workspaceID)),
              let data = json.data(using: .utf8) else {
            return []
        }
        codecLock.lock()
        let history = try? decoder.decode([String].self, from: data)
        codecLock.unlock()
        guard let history else { return [] }
        return Array(history.suffix(Self.limit))
    }

    public func save(_ history: [String], workspaceID: WorkspaceID) {
        let capped = Array(history.suffix(Self.limit))
        codecLock.lock()
        let data = try? encoder.encode(capped)
        codecLock.unlock()
        guard let data,
              let json = String(data: data, encoding: .utf8) else { return }
        do {
            try repo.set(key(for: workspaceID), json)
        } catch {
            onWriteError?(error)
        }
    }

    /// Return up to `limit` history entries for `workspaceID` whose text
    /// contains `query` (case-insensitive substring match), most-recent-first,
    /// deduplicated (first occurrence wins when scanning newest-to-oldest).
    /// Pass an empty `query` to list all entries most-recent-first.
    public func search(workspaceID: WorkspaceID, query: String, limit: Int = PromptHistoryStore.limit) -> [String] {
        let all = load(workspaceID: workspaceID)
        let needle = query.lowercased()
        var seen = Set<String>()
        var result: [String] = []
        for entry in all.reversed() {
            guard seen.insert(entry).inserted else { continue }
            if needle.isEmpty || entry.lowercased().contains(needle) {
                result.append(entry)
                if result.count == limit { break }
            }
        }
        return result
    }

    /// Remove the prompt-history row for `workspaceID`. Called when a workspace
    /// is deleted so user-typed prompts do not persist on disk indefinitely
    /// (privacy + unbounded settings-table growth).
    public func delete(workspaceID: WorkspaceID) throws {
        try repo.delete(key: key(for: workspaceID))
    }

    private func key(for workspaceID: WorkspaceID) -> String {
        "agent_prompt_history.\(workspaceID.value.uuidString)"
    }
}
