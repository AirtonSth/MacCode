import Foundation
import CoreModel

public final class BotDesktopVMStore: @unchecked Sendable {
    private let root: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func identity(botID: BotID) throws -> BotDesktopVMIdentity? {
        let url = identityURL(botID: botID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(BotDesktopVMIdentity.self, from: data)
    }

    @discardableResult
    public func ensure(botID: BotID, now: Date = Date()) throws -> BotDesktopVMIdentity {
        if let existing = try identity(botID: botID) { return existing }
        let bundle = bundleURL(botID: botID)
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        let created = BotDesktopVMIdentity(
            botID: botID,
            generation: 1,
            bundlePath: bundle.path,
            state: .stopped,
            updatedAt: now
        )
        try save(created)
        return created
    }

    public func save(_ identity: BotDesktopVMIdentity) throws {
        let bundle = URL(fileURLWithPath: identity.bundlePath, isDirectory: true)
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        let data = try encoder.encode(identity)
        let url = identityURL(botID: identity.botID)
        try data.write(to: url, options: .atomic)
    }

    public func bundleURL(botID: BotID) -> URL {
        root.appendingPathComponent(botID.value.uuidString.lowercased(), isDirectory: true)
    }

    private func identityURL(botID: BotID) -> URL {
        bundleURL(botID: botID).appendingPathComponent("identity.json")
    }
}
