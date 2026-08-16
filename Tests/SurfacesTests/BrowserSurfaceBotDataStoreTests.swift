import XCTest
import CoreModel
@testable import Surfaces

final class BrowserSurfaceBotDataStoreTests: XCTestCase {
    func test_botStoreIdentifierIsNotWorkspaceIdentifier() {
        let raw = UUID(uuidString: "CAFEBABE-CAFE-BABE-CAFE-BABECAFEBABE")!
        let workspace = BrowserSurface.dataStoreIdentifier(for: WorkspaceID(raw))
        let bot = BrowserSurface.dataStoreIdentifier(forBot: BotID(raw))
        XCTAssertEqual(workspace, raw)
        XCTAssertEqual(bot, BotBrowserIdentity.dataStoreIdentifier(for: BotID(raw)))
        XCTAssertNotEqual(workspace, bot, "workspace browsers must not share a bot's WKWebsiteDataStore")
    }
}
