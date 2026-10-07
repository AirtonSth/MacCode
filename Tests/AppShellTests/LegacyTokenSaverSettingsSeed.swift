import Foundation
import Persistence

/// Writes `tokenSaverEnabled: true` into the stored settings blob, the way a
/// build that still had Token Saver persisted it. Other stored keys are kept.
/// Tests use it to prove a leftover preference turns nothing back on.
func seedLegacyTokenSaverOn(_ repo: SettingsRepository) throws {
    var object: [String: Any] = [:]
    if let json = try repo.get("app_settings"),
       let existing = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
        object = existing
    }
    object["tokenSaverEnabled"] = true
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try repo.set("app_settings", String(decoding: data, as: UTF8.self))
}
