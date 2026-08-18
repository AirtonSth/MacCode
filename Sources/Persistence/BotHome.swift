import Foundation
import CoreModel

/// Exclusive on-disk home for one bot. Lives under Application Support,
/// never under the advertised workspace cwd.
public struct BotHome: Sendable {
    public let root: URL

    public static let identityName = "IDENTITY.md"
    public static let descriptionName = "DESCRIPTION.md"
    public static let soulName = "SOUL.md"
    public static let memoryName = "memory.md"
    public static let skillsDirectoryName = "skills"
    public static let filesDirectoryName = "files"

    public static let memoryProjectionHeader = """
    # Memory projection
    # Trusted facts from the store. Forget and Correct still go through Memory.
    """

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public init(appSupportDirectory: URL, bot: BotDefinition) {
        self.init(root: Self.url(appSupportDirectory: appSupportDirectory, bot: bot))
    }

    public static func url(appSupportDirectory: URL, bot: BotDefinition) -> URL {
        url(appSupportDirectory: appSupportDirectory, botID: bot.id, epoch: bot.directoryEpoch)
    }

    public static func url(appSupportDirectory: URL, botID: BotID, epoch: Int) -> URL {
        appSupportDirectory
            .appendingPathComponent("bots", isDirectory: true)
            .appendingPathComponent(botID.value.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("e\(epoch)", isDirectory: true)
    }

    public var identityURL: URL { root.appendingPathComponent(Self.identityName) }
    public var descriptionURL: URL { root.appendingPathComponent(Self.descriptionName) }
    public var soulURL: URL { root.appendingPathComponent(Self.soulName) }
    public var memoryURL: URL { root.appendingPathComponent(Self.memoryName) }
    public var skillsURL: URL { root.appendingPathComponent(Self.skillsDirectoryName, isDirectory: true) }
    public var filesURL: URL { root.appendingPathComponent(Self.filesDirectoryName, isDirectory: true) }

    public func ensure(
        name: String,
        handle: String,
        title: String,
        description: String,
        soul: String
    ) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)
        try writeIdentity(name: name, handle: handle, title: title)
        if !FileManager.default.fileExists(atPath: descriptionURL.path) {
            try writeDescription(description)
        }
        if !FileManager.default.fileExists(atPath: soulURL.path) {
            try writeSoul(soul)
        }
        if !FileManager.default.fileExists(atPath: memoryURL.path) {
            try writeMemoryProjection(facts: [])
        }
    }

    public func writeIdentity(name: String, handle: String, title: String) throws {
        let role = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = """
        # Identity
        Name: \(name)
        Role: \(role.isEmpty ? "—" : role)
        Handle: @\(handle)
        """
        try writeAtomic(text + "\n", to: identityURL)
    }

    public func writeDescription(_ description: String) throws {
        try writeAtomic(description, to: descriptionURL)
    }

    public func writeSoul(_ soul: String) throws {
        try writeAtomic(soul, to: soulURL)
    }

    public func writeMemoryProjection(facts: [String]) throws {
        var lines = [Self.memoryProjectionHeader]
        for fact in facts {
            let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append("- \(trimmed)")
        }
        try writeAtomic(lines.joined(separator: "\n") + "\n", to: memoryURL)
    }

    public func readSoul() throws -> String {
        try String(contentsOf: soulURL, encoding: .utf8)
    }

    public func readDescription() throws -> String {
        try String(contentsOf: descriptionURL, encoding: .utf8)
    }

    public func readIdentity() throws -> String {
        try String(contentsOf: identityURL, encoding: .utf8)
    }

    public func listRelativePaths() throws -> [String] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var paths: [String] = []
        let rootPath = root.path
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let path = url.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            paths.append(String(path.dropFirst(rootPath.count + 1)))
        }
        return paths.sorted()
    }

    public func readFile(relativePath: String) throws -> String {
        let url = try resolvedURL(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func writeFile(relativePath: String, contents: String) throws {
        let url = try resolvedURL(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeAtomic(contents, to: url)
    }

    public struct OwnedSkill: Sendable, Equatable {
        public var slug: String
        public var body: String
        public init(slug: String, body: String) {
            self.slug = slug
            self.body = body
        }
    }

    public func listOwnedSkills() throws -> [OwnedSkill] {
        guard FileManager.default.fileExists(atPath: skillsURL.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: skillsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var skills: [OwnedSkill] = []
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            guard isDir else { continue }
            let skillFile = url.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: skillFile.path) else { continue }
            let body = try String(contentsOf: skillFile, encoding: .utf8)
            skills.append(OwnedSkill(slug: url.lastPathComponent, body: body))
        }
        return skills
    }

    public func createOwnedSkill(slug: String) throws -> String {
        let normalized = Self.normalizeSkillSlug(slug)
        guard let normalized else {
            throw BotHomeError.invalid("Skill id must be a catalog-style slug, not a path.")
        }
        let dir = skillsURL.appendingPathComponent(normalized, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let skillFile = dir.appendingPathComponent("SKILL.md")
        if !FileManager.default.fileExists(atPath: skillFile.path) {
            let body = """
            ---
            name: \(normalized)
            description: Skill for this teammate.
            ---

            Do the job described by this skill.
            """
            try writeAtomic(body + "\n", to: skillFile)
        }
        return "\(Self.skillsDirectoryName)/\(normalized)/SKILL.md"
    }

    public static func normalizeSkillSlug(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, !value.contains("/"), !value.contains("..") else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }

    public func resolvedURL(_ relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("..") else {
            throw BotHomeError.invalid("Path must stay inside the bot home.")
        }
        let url = root.appendingPathComponent(trimmed).standardizedFileURL
        let rootPath = root.path
        guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else {
            throw BotHomeError.invalid("Path must stay inside the bot home.")
        }
        return url
    }

    private func writeAtomic(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

public enum BotHomeError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let message):
            return message
        }
    }
}
