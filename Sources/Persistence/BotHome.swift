import Foundation
import CoreModel

/// Exclusive on-disk home for one bot. Lives under Application Support,
/// never under the advertised workspace cwd.
public struct BotHome: Sendable {
    public let root: URL

    public static let identityName = "IDENTITY.md"
    public static let descriptionName = "DESCRIPTION.md"
    public static let soulName = "SOUL.md"
    public static let memoryName = "MEMORY.md"
    public static let userMemoryName = "USER.md"
    public static let legacyMemoryName = "memory.md"
    public static let memoryDirectoryName = "memory"
    public static let skillsDirectoryName = "skills"
    public static let filesDirectoryName = "files"

    public static let memoryStarter = """
    # Memory

    Durable facts and standing decisions. Edit this file to remember or correct.
    Daily notes go in memory/YYYY-MM-DD.md.
    """

    public struct MemoryFile: Sendable, Equatable {
        public var path: String
        public var body: String

        public init(path: String, body: String) {
            self.path = path
            self.body = body
        }
    }

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
    public var userMemoryURL: URL { root.appendingPathComponent(Self.userMemoryName) }
    public var memoryDirectoryURL: URL {
        root.appendingPathComponent(Self.memoryDirectoryName, isDirectory: true)
    }
    public var skillsURL: URL { root.appendingPathComponent(Self.skillsDirectoryName, isDirectory: true) }
    public var filesURL: URL { root.appendingPathComponent(Self.filesDirectoryName, isDirectory: true) }

    public func ensure(
        name: String,
        handle: String,
        title: String,
        description: String,
        soul: String,
        legacyFacts: [String] = []
    ) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: memoryDirectoryURL, withIntermediateDirectories: true)
        try writeIdentity(name: name, handle: handle, title: title)
        if !FileManager.default.fileExists(atPath: descriptionURL.path) {
            try writeDescription(description)
        }
        if !FileManager.default.fileExists(atPath: soulURL.path) {
            try writeSoul(soul)
        }
        try migrateLegacyMemoryIfNeeded(legacyFacts: legacyFacts)
        if !FileManager.default.fileExists(atPath: memoryURL.path) {
            try writeAtomic(Self.memoryStarter + "\n", to: memoryURL)
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

    /// One-time lift of leftover `memory.md` or store bullets into `MEMORY.md`.
    /// Never overwrites an existing `MEMORY.md`.
    public func migrateLegacyMemoryIfNeeded(legacyFacts: [String] = []) throws {
        if FileManager.default.fileExists(atPath: memoryURL.path) { return }
        let legacyURL = root.appendingPathComponent(Self.legacyMemoryName)
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            let raw = try mappedString(at: legacyURL)
            let body = Self.stripProjectionHeader(raw)
            try writeAtomic(
                body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? Self.memoryStarter + "\n"
                    : body,
                to: memoryURL
            )
            try FileManager.default.removeItem(at: legacyURL)
            return
        }
        let facts = legacyFacts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !facts.isEmpty else { return }
        var lines = ["# Memory", ""]
        lines.append(contentsOf: facts.map { "- \($0)" })
        try writeAtomic(lines.joined(separator: "\n") + "\n", to: memoryURL)
    }

    public func readBootstrapMemory(
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> [MemoryFile] {
        var files: [MemoryFile] = []
        for name in [Self.userMemoryName, Self.memoryName] {
            if let file = try readMemoryFile(relativePath: name) {
                files.append(file)
            }
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        let yesterdayDate = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let yesterday = formatter.string(from: yesterdayDate)
        for day in [today, yesterday] {
            files.append(contentsOf: try dailyNotes(dayPrefix: day))
        }
        return files
    }

    public static func isWritableMemoryPath(_ relativePath: String) -> Bool {
        let path = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path == memoryName || path == userMemoryName { return true }
        let pattern = #"^memory/[0-9]{4}-[0-9]{2}-[0-9]{2}(?:-[A-Za-z0-9][A-Za-z0-9-]*)?\.md$"#
        return path.range(of: pattern, options: .regularExpression) != nil
    }

    public static func isWritableSkillPath(_ relativePath: String) -> Bool {
        let path = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              parts[0] == skillsDirectoryName,
              parts[2] == "SKILL.md",
              normalizeSkillSlug(parts[1]) == parts[1] else { return false }
        return true
    }

    public static func isWritableHomePath(_ relativePath: String) -> Bool {
        let path = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path == soulName || isWritableMemoryPath(relativePath) || isWritableSkillPath(relativePath)
    }

    public static func stripProjectionHeader(_ raw: String) -> String {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let kept = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("# Memory projection")
                && trimmed != "# Trusted facts from the store. Forget and Correct still go through Memory."
        }
        var body = kept.joined(separator: "\n")
        while body.hasPrefix("\n") { body.removeFirst() }
        return body
    }

    // PERF: map file via Data to avoid heap copy for read-heavy memory/soul paths.
    private func mappedString(at url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let str = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSFilePathErrorKey: url.path])
        }
        return str
    }
    private func mappedStringIfPresent(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    private func readMemoryFile(relativePath: String) throws -> MemoryFile? {
        let url = try resolvedURL(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let body = try mappedString(at: url)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return MemoryFile(path: relativePath, body: body)
    }

    private func dailyNotes(dayPrefix: String) throws -> [MemoryFile] {
        guard FileManager.default.fileExists(atPath: memoryDirectoryURL.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: memoryDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return entries
            .filter {
                $0.pathExtension == "md"
                    && ($0.deletingPathExtension().lastPathComponent == dayPrefix
                        || $0.deletingPathExtension().lastPathComponent.hasPrefix(dayPrefix + "-"))
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let body = mappedStringIfPresent(at: url),
                      !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return MemoryFile(
                    path: "\(Self.memoryDirectoryName)/\(url.lastPathComponent)",
                    body: body
                )
            }
    }

    public func readSoul() throws -> String {
        try mappedString(at: soulURL)
    }

    public func readDescription() throws -> String {
        try mappedString(at: descriptionURL)
    }

    public func readIdentity() throws -> String {
        try mappedString(at: identityURL)
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
        return try mappedString(at: url)
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
            let body = try mappedString(at: skillFile)
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

    public func removeOwnedSkill(slug: String) throws {
        let normalized = Self.normalizeSkillSlug(slug)
        guard let normalized else {
            throw BotHomeError.invalid("Skill id must be a catalog-style slug, not a path.")
        }
        let dir = skillsURL.appendingPathComponent(normalized, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw BotHomeError.invalid("Skill not found.")
        }
        try FileManager.default.removeItem(at: dir)
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
