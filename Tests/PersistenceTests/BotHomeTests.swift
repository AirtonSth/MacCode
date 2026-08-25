import XCTest
import CoreModel
@testable import Persistence

final class BotHomeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rc-bot-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    func test_homeLivesUnderAppSupportNotAdvertisedWorkspace() {
        let bot = BotDefinition(
            handle: "piper",
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            directoryEpoch: 2
        )
        let home = BotHome(appSupportDirectory: directory, bot: bot)
        XCTAssertTrue(home.root.path.contains("/bots/"))
        XCTAssertTrue(home.root.path.hasSuffix("/e2"))
        XCTAssertTrue(home.root.path.contains(bot.id.value.uuidString.lowercased()))
        XCTAssertFalse(home.root.path.contains("/star"))
        XCTAssertEqual(
            home.root.path.hasPrefix(directory.path),
            true,
            "home must stay under the Application Support override"
        )
    }

    func test_ensureSeedsFileMemoryNotProjection() throws {
        // WHY: Memory is the markdown the bot writes. A projection header
        // would tell the model the store still owns Forget/Correct.
        let bot = BotDefinition(
            handle: "piper",
            name: "Piper",
            title: "Scout",
            description: "Looks around"
        )
        let home = BotHome(appSupportDirectory: directory, bot: bot)
        try home.ensure(
            name: bot.name,
            handle: bot.handle,
            title: bot.title,
            description: bot.description,
            soul: "Be brief."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.memoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.memoryDirectoryURL.path))
        XCTAssertEqual(home.memoryURL.lastPathComponent, "MEMORY.md")
        let body = try String(contentsOf: home.memoryURL, encoding: .utf8)
        XCTAssertTrue(body.contains("Durable facts"))
        XCTAssertFalse(body.contains("Memory projection"))
        XCTAssertFalse(body.contains("Forget and Correct still go through Memory"))
        XCTAssertTrue(BotHome.isWritableMemoryPath("MEMORY.md"))
        XCTAssertTrue(BotHome.isWritableMemoryPath("memory/2026-08-18.md"))
        XCTAssertTrue(BotHome.isWritableMemoryPath("USER.md"))
        XCTAssertFalse(BotHome.isWritableMemoryPath("IDENTITY.md"))
        XCTAssertFalse(BotHome.isWritableMemoryPath("memory/not-a-date.md"))
    }

    func test_ensureSeedsIdentitySoulMemorySkillsAndFiles() throws {
        let bot = BotDefinition(
            handle: "piper",
            name: "Piper",
            title: "Scout",
            description: "Looks around"
        )
        let home = BotHome(appSupportDirectory: directory, bot: bot)
        try home.ensure(
            name: bot.name,
            handle: bot.handle,
            title: bot.title,
            description: bot.description,
            soul: "Be brief."
        )
        try home.ensure(
            name: bot.name,
            handle: bot.handle,
            title: bot.title,
            description: "ignored on second ensure",
            soul: "must not clobber"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.identityURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.descriptionURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.soulURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.memoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.skillsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.filesURL.path))
        XCTAssertEqual(try home.readSoul(), "Be brief.")
        XCTAssertEqual(try home.readDescription(), "Looks around")
        XCTAssertTrue(try home.readIdentity().contains("@piper"))
        XCTAssertTrue(try home.readIdentity().contains("Name: Piper"))
        XCTAssertTrue(try String(contentsOf: home.memoryURL, encoding: .utf8).contains("Durable facts"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.memoryDirectoryURL.path))
    }

    func test_identityFileIsGeneratedAndHandleStaysCreateOnly() throws {
        let bot = BotDefinition(
            handle: "piper",
            name: "Piper",
            title: "Scout",
            description: ""
        )
        let home = BotHome(appSupportDirectory: directory, bot: bot)
        try home.ensure(name: bot.name, handle: bot.handle, title: bot.title, description: "", soul: "Be brief.")
        try home.writeFile(relativePath: BotHome.identityName, contents: "Handle: @stolen\n")
        try home.writeIdentity(name: "Piper", handle: "piper", title: "Scout")
        let identity = try home.readIdentity()
        XCTAssertTrue(identity.contains("Handle: @piper"))
        XCTAssertFalse(identity.contains("@stolen"))
    }

    func test_identityPathIsNotWritableHomePath() {
        XCTAssertFalse(BotHome.isWritableHomePath("IDENTITY.md"))
        XCTAssertFalse(BotHome.isWritableHomePath("DESCRIPTION.md"))
        XCTAssertTrue(BotHome.isWritableHomePath("SOUL.md"))
        XCTAssertTrue(BotHome.isWritableHomePath("MEMORY.md"))
    }

    func test_thisBotSkillIsASkillMarkdownFile() throws {
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let home = BotHome(appSupportDirectory: directory, bot: bot)
        try home.ensure(name: bot.name, handle: bot.handle, title: bot.title, description: "", soul: "")
        let relative = try home.createOwnedSkill(slug: "weekly-invoice")
        XCTAssertEqual(relative, "skills/weekly-invoice/SKILL.md")
        XCTAssertEqual(try home.listOwnedSkills().map(\.slug), ["weekly-invoice"])
        XCTAssertTrue(try home.listOwnedSkills()[0].body.contains("name: weekly-invoice"))
        XCTAssertNil(BotHome.normalizeSkillSlug("a/b"))
        XCTAssertNil(BotHome.normalizeSkillSlug("../x"))
    }

    func test_legacyMemoryProjectionMigratesOnceIntoMEMORY() throws {
        // WHY: Existing homes wrote memory.md from the store. Opening them
        // must lift that text into MEMORY.md once and never overwrite a
        // bot-edited MEMORY.md with leftover store bullets.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let home = BotHome(appSupportDirectory: directory, bot: bot)
        try FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
        let legacy = """
        # Memory projection
        # Trusted facts from the store. Forget and Correct still go through Memory.
        - Prefers dark mode
        """
        try legacy.write(
            to: home.root.appendingPathComponent(BotHome.legacyMemoryName),
            atomically: true,
            encoding: .utf8
        )
        try home.migrateLegacyMemoryIfNeeded(legacyFacts: ["Store leftover"])
        let migrated = try String(contentsOf: home.memoryURL, encoding: .utf8)
        XCTAssertTrue(migrated.contains("Prefers dark mode"))
        XCTAssertFalse(migrated.contains("Memory projection"))
        XCTAssertFalse(migrated.contains("Store leftover"))
        let entriesAfter = try FileManager.default.contentsOfDirectory(atPath: home.root.path)
        XCTAssertTrue(entriesAfter.contains(BotHome.memoryName))
        XCTAssertFalse(entriesAfter.contains(BotHome.legacyMemoryName))
        let editedMemory = migrated + "\nUser-edited canonical memory\n"
        try editedMemory.write(to: home.memoryURL, atomically: true, encoding: .utf8)
        try home.migrateLegacyMemoryIfNeeded(legacyFacts: ["Must not clobber"])
        XCTAssertEqual(try String(contentsOf: home.memoryURL, encoding: .utf8), editedMemory)
    }

    func test_legacyAndMemoryAliasOnlyWhenDirectoryHasOneCaseVariant() {
        // WHY: Lowercasing the two paths always compares equal, even on a
        // case-sensitive volume where both files can coexist. Treating those
        // distinct entries as aliases would overwrite the bot-edited MEMORY.md.
        XCTAssertTrue(BotHome.legacyAndMemoryShareDirectoryEntry(
            legacyExists: true,
            memoryExists: true,
            directoryEntries: [BotHome.legacyMemoryName]
        ))
        XCTAssertTrue(BotHome.legacyAndMemoryShareDirectoryEntry(
            legacyExists: true,
            memoryExists: true,
            directoryEntries: [BotHome.memoryName]
        ))
        XCTAssertFalse(BotHome.legacyAndMemoryShareDirectoryEntry(
            legacyExists: true,
            memoryExists: true,
            directoryEntries: [BotHome.legacyMemoryName, BotHome.memoryName]
        ))
    }

    func test_removeOwnedSkillDeletesSkillDirectory() throws {
        // WHY: Remove must delete the markdown the bot owns. A leftover
        // store unbind would leave SKILL.md compiled.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let home = BotHome(appSupportDirectory: directory, bot: bot)
        try home.ensure(name: bot.name, handle: bot.handle, title: bot.title, description: "", soul: "")
        let relative = try home.createOwnedSkill(slug: "weekly-invoice")
        XCTAssertEqual(relative, "skills/weekly-invoice/SKILL.md")
        XCTAssertTrue(BotHome.isWritableSkillPath(relative))
        XCTAssertTrue(BotHome.isWritableHomePath(relative))
        XCTAssertFalse(BotHome.isWritableSkillPath("skills/weekly-invoice/NOTES.md"))
        try home.removeOwnedSkill(slug: "weekly-invoice")
        XCTAssertTrue(try home.listOwnedSkills().isEmpty)
        XCTAssertThrowsError(try home.removeOwnedSkill(slug: "weekly-invoice"))
    }

    func test_writeFileRejectsPathEscape() throws {
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let home = BotHome(appSupportDirectory: directory, bot: bot)
        try home.ensure(name: bot.name, handle: bot.handle, title: bot.title, description: "", soul: "")
        XCTAssertThrowsError(try home.writeFile(relativePath: "../outside.md", contents: "x"))
        XCTAssertThrowsError(try home.readFile(relativePath: "/etc/passwd"))
    }
}
