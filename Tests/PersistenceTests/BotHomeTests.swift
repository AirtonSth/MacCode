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
        XCTAssertTrue(try String(contentsOf: home.memoryURL, encoding: .utf8).contains(BotHome.memoryProjectionHeader))
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

    func test_memoryMarkdownIsProjectionNotSourceOfTruth() throws {
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let home = BotHome(appSupportDirectory: directory, bot: bot)
        try home.ensure(name: bot.name, handle: bot.handle, title: bot.title, description: "", soul: "")
        try home.writeMemoryProjection(facts: ["Prefers dark mode"])
        XCTAssertTrue(try String(contentsOf: home.memoryURL, encoding: .utf8).contains("Prefers dark mode"))
        try home.writeMemoryProjection(facts: [])
        let wiped = try String(contentsOf: home.memoryURL, encoding: .utf8)
        XCTAssertFalse(wiped.contains("Prefers dark mode"))
        XCTAssertTrue(wiped.contains(BotHome.memoryProjectionHeader))
    }

    func test_writeFileRejectsPathEscape() throws {
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let home = BotHome(appSupportDirectory: directory, bot: bot)
        try home.ensure(name: bot.name, handle: bot.handle, title: bot.title, description: "", soul: "")
        XCTAssertThrowsError(try home.writeFile(relativePath: "../outside.md", contents: "x"))
        XCTAssertThrowsError(try home.readFile(relativePath: "/etc/passwd"))
    }
}
