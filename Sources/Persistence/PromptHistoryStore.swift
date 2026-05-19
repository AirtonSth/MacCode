import Foundation
import CoreModel

public final class PromptHistoryStore {
    public static let limit = 20

    private let repo: SettingsRepository

    public init(db: SQLiteDB) {
        self.repo = SettingsRepository(db: db)
    }

    public func load(workspaceID: WorkspaceID) -> [String] {
        guard let json = try? repo.get(key(for: workspaceID)),
              let data = json.data(using: .utf8),
              let history = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Array(history.suffix(Self.limit))
    }

    public func save(_ history: [String], workspaceID: WorkspaceID) {
        let capped = Array(history.suffix(Self.limit))
        guard let data = try? JSONEncoder().encode(capped),
              let json = String(data: data, encoding: .utf8) else { return }
        try? repo.set(key(for: workspaceID), json)
    }

    private func key(for workspaceID: WorkspaceID) -> String {
        "agent_prompt_history.\(workspaceID.value.uuidString)"
    }
}
