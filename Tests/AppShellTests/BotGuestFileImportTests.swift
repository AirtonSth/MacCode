import XCTest
import CoreModel
import Persistence
@testable import AppShell

final class BotGuestFileImportTests: XCTestCase {
    func test_importCopiesIntoGuestDownloadsWithoutOverwriting() throws {
        // WHY: files dropped or pasted on the Linux desktop, or sent for a bot's file
        // request, must land where the guest sees them and never replace an earlier file.
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("RC2Import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("report.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: source)
        let bot = BotID()
        let first = try BotGuestHome.importFiles([source], appSupport: root, botID: bot)
        let second = try BotGuestHome.importFiles([source], appSupport: root, botID: bot)
        XCTAssertEqual(first, ["/home/remotecode/Downloads/report.pdf"])
        XCTAssertEqual(second, ["/home/remotecode/Downloads/report 2.pdf"])
        let host = BotGuestHome.url(appSupport: root, botID: bot).appendingPathComponent("Downloads/report 2.pdf")
        XCTAssertEqual(try Data(contentsOf: host), Data("a".utf8))
    }

    func test_pasteScriptEscapesTextAndSendsCtrlV() {
        // WHY: Cmd+V must paste the Mac text verbatim, even with quotes or newlines.
        let script = BotComputerGuestWebView.pasteScript("a\"b\n</script>")
        XCTAssertTrue(script.contains(#"field.value = "a\"b\n<\/script>";"#) || script.contains(#"field.value = "a\"b\n</script>";"#))
        XCTAssertTrue(script.contains("'KeyV'"))
    }
}
