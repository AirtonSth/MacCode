import Foundation
import Persistence

public struct PetStoredPlacement: Codable, Sendable, Equatable {
    public let displayID: String
    public let position: PetNormalizedPosition

    public init(displayID: String, position: PetNormalizedPosition) {
        self.displayID = displayID
        self.position = position
    }
}

@MainActor
public final class PetPlacementStore {
    private let repository: SettingsRepository
    private let key = "pet.placement.v1"

    public init(repository: SettingsRepository) {
        self.repository = repository
    }

    public func load() -> PetStoredPlacement? {
        guard let raw = try? repository.get(key),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PetStoredPlacement.self, from: data)
    }

    public func save(_ placement: PetStoredPlacement) {
        guard let data = try? JSONEncoder().encode(placement),
              let raw = String(data: data, encoding: .utf8) else { return }
        try? repository.set(key, raw)
    }

    public func reset() {
        try? repository.delete(key: key)
    }
}
