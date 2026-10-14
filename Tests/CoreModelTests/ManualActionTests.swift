import XCTest
import CoreGraphics
import ImageIO
import CoreModel

final class ManualActionTests: XCTestCase {
    func test_normalizedReason_trimsCapsAndDefaults() {
        // WHY: the reason is shown verbatim on the card; it must be bounded and never empty.
        XCTAssertEqual(ManualActionRequest.normalizedReason("  entre na conta \n"), "entre na conta")
        XCTAssertEqual(ManualActionRequest.normalizedReason(String(repeating: "a", count: 500)).count, 280)
        XCTAssertEqual(ManualActionRequest.normalizedReason("   \n"), "The bot asked you to take over")
    }

    func test_twoFactorRawValueAndCodableRoundTrip() throws {
        XCTAssertEqual(ManualActionKind.twoFactor.rawValue, "2fa")
        let request = ManualActionRequest(
            botID: BotID(),
            threadID: AgentThreadID(),
            kind: .twoFactor,
            reason: "codigo",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ManualActionRequest.self, from: data), request)
    }

    func test_requestHelpTwiceReturnsSameIdAndKeepsReason() {
        // WHY: one open request per bot; a repeated call must not overwrite what the user sees.
        let control = BotComputerControl()
        let bot = BotID()
        let first = ManualActionRequest(botID: bot, kind: .login, reason: "primeiro")
        let second = ManualActionRequest(botID: bot, kind: .captcha, reason: "segundo")
        XCTAssertEqual(control.requestHelp(first), first.id)
        XCTAssertEqual(control.requestHelp(second), first.id)
        XCTAssertEqual(control.openRequest(bot)?.reason, "primeiro")
        XCTAssertEqual(control.openRequest(bot)?.kind, .login)
    }

    func test_manualAction_6_expireWithStaleIdDoesNotCloseNewerRequest() {
        // WHY: an old timer must never close a request the bot opened later (spec test 6).
        let control = BotComputerControl()
        let bot = BotID()
        let old = ManualActionRequest(botID: bot, kind: .login, reason: "old")
        control.requestHelp(old)
        XCTAssertNotNil(control.dismiss(old.id, as: .declined))
        let newer = ManualActionRequest(botID: bot, kind: .payment, reason: "new")
        control.requestHelp(newer)

        XCTAssertNil(control.expire(old.id))
        XCTAssertEqual(control.openRequest(bot)?.id, newer.id)
        XCTAssertEqual(control.expire(newer.id)?.state, .expired)
        XCTAssertNil(control.openRequest(bot))
    }

    func test_takeReleaseAndRestartSemantics() {
        // WHY: control is memory only; a restarted app must hand the computer back to the bot (spec test 5).
        let control = BotComputerControl()
        let bot = BotID()
        let request = ManualActionRequest(botID: bot, kind: .login, reason: "r")
        control.requestHelp(request)
        control.take(bot)
        XCTAssertTrue(control.isControlledByUser(bot))
        XCTAssertEqual(control.openRequest(bot)?.state, .taken)
        XCTAssertFalse(BotComputerControl().isControlledByUser(bot))
        control.release(bot)
        XCTAssertFalse(control.isControlledByUser(bot))
        control.take(bot)
        control.forget(bot)
        XCTAssertFalse(control.isControlledByUser(bot))
        XCTAssertNil(control.openRequest(bot))
    }

    func test_followUpTextsAreExact() {
        XCTAssertEqual(
            ManualActionRequest.continueFollowUp(kind: .twoFactor, note: " done "),
            "The user finished the manual action (2fa). Note: done. Take a fresh screenshot before acting."
        )
        XCTAssertEqual(
            ManualActionRequest.continueFollowUp(kind: .login, note: nil),
            "The user finished the manual action (login). Note: none. Take a fresh screenshot before acting."
        )
        XCTAssertEqual(
            ManualActionRequest.declineFollowUp,
            "The user declined the manual action. Continue without it, or stop and explain."
        )
        XCTAssertEqual(
            ManualActionRequest.pauseReply,
            "Paused: waiting for the user. End your turn now. Their answer arrives as a new message."
        )
        XCTAssertEqual(
            ManualActionRequest.refusalPhrase,
            "The user has taken control of this computer, so this call was NOT executed. Do not retry: the screen is changing. Pause the task, say you are waiting for the user to hand control back, and take a fresh screenshot before the next action."
        )
    }

    func test_hostRequestPostsOnlyForNewRequest() {
        let control = BotComputerControl()
        let center = NotificationCenter()
        let bot = BotID()
        var posted: [ManualActionRequest] = []
        let token = center.addObserver(forName: .botManualActionRequested, object: nil, queue: nil) { note in
            if let request = note.userInfo?[BotHostNotificationKey.request] as? ManualActionRequest {
                posted.append(request)
            }
        }
        defer { center.removeObserver(token) }
        let first = ManualActionHost.request(
            control: control, botID: bot, threadID: nil, kind: .confirm, reason: "a", screenshotPNG: nil, center: center
        )
        let second = ManualActionHost.request(
            control: control, botID: bot, threadID: nil, kind: .other, reason: "b", screenshotPNG: nil, center: center
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted.first?.id, first)
    }
}

final class BotScreenshotTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000)
    }

    func test_limiterBlocksSecondNormalWithin30sButNotErrorOrAction() {
        // WHY: normal screenshots flood the chat; errors and action requests must always get through.
        let clock = Clock()
        let limiter = BotScreenshotRateLimiter(now: { clock.now })
        let bot = BotID()
        XCTAssertEqual(limiter.acquire(botID: bot, kind: .normal), .allowed)
        clock.now.addTimeInterval(10)
        XCTAssertEqual(limiter.acquire(botID: bot, kind: .normal), .blocked(retryAfterSeconds: 20))
        XCTAssertEqual(limiter.acquire(botID: bot, kind: .normal).message, "rate limited, try again in 20s")
        XCTAssertEqual(limiter.acquire(botID: bot, kind: .error), .allowed)
        XCTAssertEqual(limiter.acquire(botID: bot, kind: .action), .allowed)
        XCTAssertEqual(limiter.acquire(botID: BotID(), kind: .normal), .allowed)
        clock.now.addTimeInterval(20)
        XCTAssertEqual(limiter.acquire(botID: bot, kind: .normal), .allowed)
    }

    func test_jpegEncoderDownscalesWideImage() throws {
        let png = try Self.makePNG(width: 2000, height: 1000)
        let result = try BotScreenshotEncoder.jpeg(fromPNG: png, maxWidth: 1280)
        XCTAssertEqual(result.width, 1280)
        XCTAssertEqual(result.height, 640)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(image.width, 1280)
        XCTAssertEqual(Array(result.data.prefix(2)), [0xFF, 0xD8])
    }

    func test_jpegEncoderKeepsSmallImageSizeAndRejectsGarbage() throws {
        let result = try BotScreenshotEncoder.jpeg(fromPNG: try Self.makePNG(width: 400, height: 300))
        XCTAssertEqual(result.width, 400)
        XCTAssertThrowsError(try BotScreenshotEncoder.jpeg(fromPNG: Data([1, 2, 3])))
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
