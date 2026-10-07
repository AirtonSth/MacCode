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

    func test_execWaitCoversTheHostExecDeadline() {
        // WHY: the child must outwait the host's docker exec deadline, otherwise it
        // reports "Docker desktop is not available" while the command still runs.
        let service = BotComputerService(callerBotID: BotID(), store: BotComputerStore(appSupportDirectory: tempRoot()))
        XCTAssertGreaterThan(
            service.resultWaitSeconds(kind: BotComputerCatalog.exec),
            BotComputerGuestSpec.execHostDeadlineSeconds
                + TimeInterval(BotComputerGuestSpec.execResultMarginSeconds)
        )
    }

    func test_rebuildWaitCoversTheImageBuildAndTheRebuiltDesktop() {
        // WHY: bot_computer_rebuild runs `docker build` (up to the build deadline)
        // and then brings the rebuilt desktop up. Waiting only the exec window
        // told the agent the desktop was gone while the build kept going.
        let service = BotComputerService(callerBotID: BotID(), store: BotComputerStore(appSupportDirectory: tempRoot()))
        let rebuildWait = service.resultWaitSeconds(kind: BotComputerCatalog.rebuild)
        XCTAssertGreaterThanOrEqual(
            rebuildWait,
            BotComputerGuestSpec.imageBuildDeadlineSeconds + BotComputerGuestSpec.rebuildReadyBudgetSeconds
        )
        XCTAssertGreaterThan(rebuildWait, service.resultWaitSeconds(kind: BotComputerCatalog.exec))
        XCTAssertEqual(
            service.resultWaitSeconds(kind: BotComputerCatalog.observe),
            service.timeoutMS / 1000,
            "short actions keep the short caller wait"
        )
    }

    func test_pendingActionCarriesTheCallersDeadline() throws {
        // WHY: the host sizes the exec's guest limit and refuses stale actions by
        // this deadline; it must be the moment the caller stops waiting.
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BotComputerStore(appSupportDirectory: root)
        var service = BotComputerService(callerBotID: BotID(), store: store)
        service.timeoutMS = 300
        let before = Date()
        XCTAssertThrowsError(try service.call(name: BotComputerCatalog.observe, arguments: [:]))
        let pending = try XCTUnwrap(store.takePending().first)
        let deadline = try XCTUnwrap(pending.deadline)
        XCTAssertEqual(deadline.timeIntervalSince(before), 0.3, accuracy: 0.25)
    }

    func test_actionWhoseCallerStoppedWaitingIsAnsweredButNeverApplied() throws {
        // WHY: an act queued behind slow work used to run after the agent had been
        // told it failed, landing stale clicks and typing on the desktop.
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BotComputerStore(appSupportDirectory: root)
        let expired = BotComputerPendingAction(
            id: "expired",
            botID: "bot",
            kind: BotComputerCatalog.act,
            steps: [BotComputerActStep(action: "click", x: 1, y: 1)],
            deadline: Date().addingTimeInterval(-1)
        )
        let live = BotComputerPendingAction(
            id: "live",
            botID: "bot",
            kind: BotComputerCatalog.act,
            deadline: Date().addingTimeInterval(60)
        )
        try store.enqueue(expired)
        try store.enqueue(live)
        var applied: [String] = []
        _ = try BotComputerHost.applyPending(store: store) { action in
            applied.append(action.id)
            return ["ok": true]
        }
        XCTAssertEqual(applied, ["live"])
        XCTAssertEqual(try store.takeResult(id: "expired")?.error, BotComputerHost.expiredMessage)
        XCTAssertEqual(try store.takeResult(id: "live")?.error, "")
    }

    func test_longExecOnOneBotDoesNotDelayAnotherBotsObserve() throws {
        // WHY: one serial drain used to hold every bot's observe/act behind any
        // bot's exec (up to 175 s), so they failed after 20 s and then ran late.
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BotComputerStore(appSupportDirectory: root)
        let lanes = BotComputerActionLanes(label: "test.bot-computer-lanes")
        let execRelease = DispatchSemaphore(value: 0)
        let execStarted = DispatchSemaphore(value: 0)
        let apply: @Sendable (BotComputerPendingAction) throws -> [String: Any] = { action in
            if action.kind == BotComputerCatalog.exec {
                execStarted.signal()
                execRelease.wait() // stands in for a 175 s apt-get
                return ["ok": true, "output": ""]
            }
            return ["png_magic": "89504e47"]
        }
        let builder = BotComputerService(callerBotID: BotID(), store: store)
        let execDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? builder.call(name: BotComputerCatalog.exec, arguments: ["command": "apt-get install -y sl"])
            execDone.signal()
        }
        let drainStop = DispatchSemaphore(value: 0)
        let drain = Thread {
            while drainStop.wait(timeout: .now() + 0.01) == .timedOut {
                _ = try? BotComputerHost.dispatchPending(store: store, lanes: lanes, apply: apply)
            }
        }
        drain.start()
        defer {
            execRelease.signal()
            drainStop.signal()
            _ = execDone.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(execStarted.wait(timeout: .now() + 5), .success, "exec reached its lane")

        var watcher = BotComputerService(callerBotID: BotID(), store: store)
        watcher.timeoutMS = 2_000
        let started = Date()
        let result = try watcher.call(name: BotComputerCatalog.observe, arguments: [:])
        XCTAssertEqual(result["png_magic"] as? String, "89504e47")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "answered within its own wait while the exec runs")
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

    private func tempRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-bot-computer-\(UUID().uuidString)", isDirectory: true)
    }
}
