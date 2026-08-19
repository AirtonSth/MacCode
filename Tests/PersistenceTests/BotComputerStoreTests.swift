import XCTest
import CoreModel
import Persistence

final class BotComputerStoreTests: XCTestCase {
    func test_observeRoundTripReturnsPNGMagic() throws {
        // WHY: MCP cannot touch docker.sock. The host must apply the pending
        // observe and the child must see PNG 89 50 4E 47.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-bot-computer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BotComputerStore(appSupportDirectory: root)
        let bot = BotID()
        var service = BotComputerService(callerBotID: bot, store: store)
        service.timeoutMS = 2_000
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.02)
            try? BotComputerHost.applyPending(store: store) { action in
                XCTAssertEqual(action.kind, BotComputerCatalog.observe)
                return ["png_magic": "89504e47", "host": "127.0.0.1"]
            }
        }
        let result = try service.call(name: BotComputerCatalog.observe, arguments: [:])
        XCTAssertEqual(result["png_magic"] as? String, "89504e47")
        XCTAssertEqual(result["host"] as? String, "127.0.0.1")
    }

    func test_actRejectsTooManyStepsAndCrossBot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-bot-computer-act-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BotComputerStore(appSupportDirectory: root)
        let service = BotComputerService(callerBotID: BotID(), store: store)
        XCTAssertThrowsError(
            try service.call(name: BotComputerCatalog.act, arguments: [
                "steps": (0..<25).map { _ in ["action": "key", "key": "Return"] }
            ])
        )
        XCTAssertThrowsError(
            try service.call(name: BotComputerCatalog.act, arguments: [
                "bot_id": BotID().value.uuidString,
                "steps": [["action": "key", "key": "Return"]],
            ])
        ) { error in
            XCTAssertEqual(error as? BotComputerError, .crossBot)
        }
    }

    func test_actStepBuildsXdotoolWithoutShell() throws {
        let click = try BotComputerActStep(action: "click", x: 10, y: 20).execCommand()
        XCTAssertEqual(click, ["env", "DISPLAY=:1", "xdotool", "mousemove", "10", "20", "click", "1"])
        let typed = try BotComputerActStep(action: "type", text: "hi").execCommand()
        XCTAssertEqual(typed.last, "hi")
        XCTAssertFalse(typed.contains(where: { $0.contains(";") }))
        XCTAssertThrowsError(try BotComputerActStep(action: "key", key: "Return;rm").execCommand())
    }
}
