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

    func test_dragRoundTripCarriesEndPointAndIsAdvertised() throws {
        // WHY: parseSteps used to drop toX/toY, so every drag failed validation and
        // the schema never told the agent drag existed.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-bot-computer-drag-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BotComputerStore(appSupportDirectory: root)
        var service = BotComputerService(callerBotID: BotID(), store: store)
        service.timeoutMS = 2_000
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.02)
            try? BotComputerHost.applyPending(store: store) { action in
                XCTAssertEqual(action.steps, [
                    BotComputerActStep(action: "drag", x: 100, y: 120, toX: 1279, toY: 799),
                ])
                return ["ok": true, "steps": action.steps.count]
            }
        }
        // Arguments arrive as decoded MCP JSON, not Swift literals.
        let json = #"{"steps":[{"action":"drag","x":100,"y":120,"toX":1279,"toY":799}]}"#
        let arguments = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let result = try service.call(name: BotComputerCatalog.act, arguments: arguments)
        XCTAssertEqual(result["ok"] as? Bool, true)

        XCTAssertThrowsError(
            try service.call(name: BotComputerCatalog.act, arguments: [
                "steps": [["action": "drag", "x": 100, "y": 120, "toX": 1280, "toY": 10]],
            ]),
            "an off-screen drag end is rejected before reaching the host"
        )

        let schema = BotComputerCatalog.schema(for: BotComputerCatalog.act)
        let steps = try XCTUnwrap((schema["properties"] as? [String: Any])?["steps"] as? [String: Any])
        let item = try XCTUnwrap((steps["items"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertNotNil(item["toX"])
        XCTAssertNotNil(item["toY"])
        let actions = try XCTUnwrap((item["action"] as? [String: Any])?["enum"] as? [String])
        XCTAssertTrue(actions.contains("drag"))
        XCTAssertTrue(BotComputerCatalog.description(for: BotComputerCatalog.act).contains("drag"))
        XCTAssertTrue(BotComputerCatalog.description(for: BotComputerCatalog.act).contains("1280x800"))
    }

    func test_execAndRebuildWaitCoversTheHostExecDeadline() {
        // WHY: the child must outwait the host's docker exec deadline, otherwise it
        // reports "Docker desktop is not available" while the command still runs.
        XCTAssertGreaterThan(
            BotComputerGuestSpec.execResultWaitSeconds,
            BotComputerGuestSpec.execHostDeadlineSeconds
        )
    }

    func test_execRoundTripCarriesCommand() throws {
        // WHY: the bot installs packages through host-brokered exec, not host docker.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-bot-computer-exec-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BotComputerStore(appSupportDirectory: root)
        var service = BotComputerService(callerBotID: BotID(), store: store)
        service.timeoutMS = 2_000
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.02)
            try? BotComputerHost.applyPending(store: store) { action in
                XCTAssertEqual(action.kind, BotComputerCatalog.exec)
                XCTAssertEqual(action.command, "apt-get install -y sl")
                return ["ok": true, "output": "done"]
            }
        }
        let result = try service.call(
            name: BotComputerCatalog.exec,
            arguments: ["command": "apt-get install -y sl"]
        )
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["output"] as? String, "done")
    }

    func test_resultRetentionIsBoundedToNewestResponses() throws {
        // WHY: a timed-out caller can leave a screenshot result behind; the
        // result channel must not grow without bound across repeated actions.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-bot-computer-results-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BotComputerStore(appSupportDirectory: root)

        for index in 0..<40 {
            try store.writeResult(
                BotComputerActionResult(
                    id: "result-" + String(index),
                    botID: "bot",
                    payload: String(repeating: "x", count: 16),
                    error: ""
                )
            )
        }

        let data = try Data(contentsOf: store.rootDirectory.appendingPathComponent("results.json"))
        let results = try JSONDecoder().decode([BotComputerActionResult].self, from: data)
        XCTAssertEqual(results.count, 32)
        XCTAssertEqual(results.map(\.id), (8..<40).map { "result-\($0)" })
    }
}
