import XCTest
import CoreGraphics
import ImageIO
import CoreModel
import Persistence
@testable import AppShell

private final class RecordingDocker: BotComputerDockerClienting, @unchecked Sendable {
    var containers: [String: BotComputerContainerInspect] = [:]
    var png: Data
    var execCalls: [[String]] = []
    init(png: Data) { self.png = png }

    func info() throws -> String { "ok" }
    func imageExists(tag: String) throws -> Bool { true }
    func imageLabel(tag: String, key: String) throws -> String {
        key == BotComputerGuestSpec.recipeLabelKey ? BotComputerGuestSpec.recipeRevision : ""
    }
    func imageID(tag: String) throws -> String { "img" }
    func build(context: URL, tag: String) throws {}
    func create(options: BotComputerContainerCreateOptions) throws -> String {
        containers[options.name] = BotComputerContainerInspect(running: false, imageID: "img", hostPort: 49152)
        return options.name
    }
    func start(name: String) throws {
        containers[name] = BotComputerContainerInspect(running: true, imageID: "img", hostPort: 49152)
    }
    func stop(name: String) throws {}
    func inspect(name: String) throws -> BotComputerContainerInspect {
        guard let value = containers[name] else { throw BotComputerGuestError.notReady }
        return value
    }
    func exec(name: String, command: [String], user: String?, detach: Bool, workdir: String?, environment: [String: String]) throws -> Data {
        // The PNG probe (`import ... png:-`) is observation, not an act/exec call.
        if command.contains("import") { return png }
        execCalls.append(command)
        return Data()
    }
    func rename(from: String, to: String) throws {}
    func ensureNetwork(name: String) throws {}
    func remove(name: String) throws { containers[name] = nil }
    func removeMatching(namePrefix: String) throws {}
}

final class BotComputerControlHostTests: XCTestCase {
    private func makeService(
        control: BotComputerControl,
        limiter: BotScreenshotRateLimiter = BotScreenshotRateLimiter(),
        center: NotificationCenter = NotificationCenter()
    ) throws -> (BotComputerGuestService, RecordingDocker, URL) {
        let support = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-manual-action-\(UUID().uuidString)", isDirectory: true)
        let docker = RecordingDocker(png: try Self.makePNG(width: 2000, height: 1000))
        let service = BotComputerGuestService(
            appSupport: support,
            docker: docker,
            recipeContext: AppShellResourceBundle.computerGuestRecipeURL(),
            observeAttempts: 1,
            observeDelay: 0,
            control: control,
            screenshotLimiter: limiter,
            notificationCenter: center
        )
        return (service, docker, support)
    }

    private func action(_ kind: String, bot: BotID, command: String = "", reason: String = "", subkind: String = "")
        -> BotComputerPendingAction {
        BotComputerPendingAction(
            id: UUID().uuidString.lowercased(),
            botID: bot.value.uuidString.lowercased(),
            kind: kind,
            steps: kind == BotComputerCatalog.act ? [BotComputerActStep(action: "key", key: "Return")] : [],
            command: command,
            reason: reason,
            subkind: subkind
        )
    }

    func test_manualAction_3_actAndExecRefusedWhileUserControlsThenRunAfterRelease() throws {
        // WHY: while the user drives the VM the bot must not touch it; nothing is queued or replayed (spec test 3).
        let control = BotComputerControl()
        let (service, docker, support) = try makeService(control: control)
        defer { try? FileManager.default.removeItem(at: support) }
        let bot = BotID()
        control.take(bot)

        let act = try service.apply(action(BotComputerCatalog.act, bot: bot))
        let exec = try service.apply(action(BotComputerCatalog.exec, bot: bot, command: "ls"))
        XCTAssertEqual(act["refusal"] as? String, ManualActionRequest.refusalPhrase)
        XCTAssertEqual(exec["refusal"] as? String, ManualActionRequest.refusalPhrase)
        XCTAssertTrue(docker.execCalls.isEmpty, "refused calls must not reach docker exec")

        control.release(bot)
        XCTAssertEqual(try service.apply(action(BotComputerCatalog.act, bot: bot))["ok"] as? Bool, true)
        XCTAssertEqual(docker.execCalls.count, 1)
        XCTAssertEqual(try service.apply(action(BotComputerCatalog.exec, bot: bot, command: "ls"))["ok"] as? Bool, true)
        XCTAssertEqual(docker.execCalls.count, 2)
    }

    func test_observeStillWorksWhileUserControls() throws {
        let control = BotComputerControl()
        let (service, _, support) = try makeService(control: control)
        defer { try? FileManager.default.removeItem(at: support) }
        let bot = BotID()
        control.take(bot)
        let result = try service.apply(action(BotComputerCatalog.observe, bot: bot))
        XCTAssertNotNil(result["png_base64"])
    }

    func test_requestUserActionPostsOnceAndReturnsPauseReplyWithScreenshot() throws {
        let control = BotComputerControl()
        let center = NotificationCenter()
        let (service, _, support) = try makeService(control: control, center: center)
        defer { try? FileManager.default.removeItem(at: support) }
        let bot = BotID()
        var posted: [ManualActionRequest] = []
        var shots = 0
        let token = center.addObserver(forName: .botManualActionRequested, object: nil, queue: nil) { note in
            if let request = note.userInfo?[BotHostNotificationKey.request] as? ManualActionRequest {
                posted.append(request)
            }
            if note.userInfo?[BotHostNotificationKey.screenshotPNG] is Data { shots += 1 }
        }
        defer { center.removeObserver(token) }

        let first = try service.apply(action(BotComputerCatalog.requestUserAction, bot: bot, reason: "login", subkind: "login"))
        let second = try service.apply(action(BotComputerCatalog.requestUserAction, bot: bot, reason: "outro", subkind: "captcha"))
        XCTAssertEqual(first["message"] as? String, ManualActionRequest.pauseReply)
        XCTAssertEqual(first["request_id"] as? String, second["request_id"] as? String)
        XCTAssertFalse((first["png_base64"] as? String ?? "").isEmpty)
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted.first?.reason, "login")
        XCTAssertEqual(posted.first?.kind, .login)
        XCTAssertEqual(shots, 1)
    }

    func test_postScreenshotRateLimitsNormalAndPostsJPEG() throws {
        let center = NotificationCenter()
        let (service, _, support) = try makeService(control: BotComputerControl(), center: center)
        defer { try? FileManager.default.removeItem(at: support) }
        let bot = BotID()
        var jpegs: [Data] = []
        let token = center.addObserver(forName: .botScreenshotPosted, object: nil, queue: nil) { note in
            if let data = note.userInfo?[BotHostNotificationKey.jpeg] as? Data { jpegs.append(data) }
        }
        defer { center.removeObserver(token) }

        let ok = try service.apply(action(BotComputerCatalog.postScreenshot, bot: bot, reason: "fim", subkind: "normal"))
        XCTAssertEqual(ok["width"] as? Int, 1280)
        XCTAssertThrowsError(
            try service.apply(action(BotComputerCatalog.postScreenshot, bot: bot, reason: "de novo", subkind: "normal"))
        ) { error in
            XCTAssertTrue(String(describing: error).hasPrefix("rate limited, try again in "))
        }
        _ = try service.apply(action(BotComputerCatalog.postScreenshot, bot: bot, reason: "erro", subkind: "error"))
        XCTAssertEqual(jpegs.count, 2)
    }

    func test_requestMacExecutionPostsNotification() throws {
        let center = NotificationCenter()
        let (service, _, support) = try makeService(control: BotComputerControl(), center: center)
        defer { try? FileManager.default.removeItem(at: support) }
        let bot = BotID()
        var reasons: [String] = []
        let token = center.addObserver(forName: .botMacExecutionRequested, object: nil, queue: nil) { note in
            reasons.append(note.userInfo?[BotHostNotificationKey.reason] as? String ?? "")
        }
        defer { center.removeObserver(token) }
        let result = try service.apply(action(BotComputerCatalog.requestMacExecution, bot: bot, reason: "swift build"))
        XCTAssertEqual(result["message"] as? String, "Request sent to the user; wait for approval. End your turn.")
        XCTAssertEqual(reasons, ["swift build"])
    }

    func test_pendingActionDecodesLegacyJSONWithoutThread() throws {
        let legacy = Data(#"{"id":"1","botID":"b","kind":"bot_computer_act","steps":[],"command":""}"#.utf8)
        let decoded = try JSONDecoder().decode(BotComputerPendingAction.self, from: legacy)
        XCTAssertNil(decoded.threadID)
        let withThread = BotComputerPendingAction(id: "1", botID: "b", kind: "k", threadID: "t")
        let round = try JSONDecoder().decode(BotComputerPendingAction.self, from: JSONEncoder().encode(withThread))
        XCTAssertEqual(round.threadID, "t")
    }

    func test_catalogListsNewToolsWithSchemas() {
        let names = BotComputerCatalog.toolCatalog().compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("bot_request_user_action"))
        XCTAssertTrue(names.contains("bot_post_screenshot"))
        XCTAssertTrue(names.contains("request_mac_execution"))
        let schema = BotComputerCatalog.schema(for: BotComputerCatalog.requestUserAction)
        let kind = ((schema["properties"] as? [String: Any])?["kind"] as? [String: Any])?["enum"] as? [String]
        XCTAssertEqual(kind, ["login", "captcha", "2fa", "payment", "confirm", "other"])
    }

    func test_managedMCPReturnsRefusalAsNormalToolResult() async throws {
        // WHY: a refusal is guidance for the model, not a tool failure; isError stays false so it is not retried blindly.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-manual-mcp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BotComputerStore(appSupportDirectory: root)
        let bot = BotID()
        let mcp = ManagedBotComputerMCP(
            environment: [
                BotComputerCatalog.callerEnvironmentKey: bot.value.uuidString,
                "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY": root.path,
            ],
            storeFactory: { _ in store }
        )
        let responder = Task.detached {
            for _ in 0..<500 {
                if let item = try? store.takePending().first {
                    let payload = try? JSONSerialization.data(withJSONObject: ["refusal": ManualActionRequest.refusalPhrase])
                    try? store.writeResult(BotComputerActionResult(
                        id: item.id, botID: item.botID, payload: String(data: payload ?? Data(), encoding: .utf8) ?? "", error: ""
                    ))
                    return
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"bot_computer_exec","arguments":{"command":"ls"}}}"#
        let maybeReply = await mcp.handle(line)
        let reply = try XCTUnwrap(maybeReply)
        await responder.value
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"]) as? String
        XCTAssertEqual(text, ManualActionRequest.refusalPhrase)
    }

    static func makePNG(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
