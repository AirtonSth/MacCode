import XCTest
import CoreGraphics
import ImageIO
import CoreModel
import Persistence
@testable import AppShell

/// WHY: the screenshot tool is the only way a bot pushes images into the user's chat; the guest
/// service must throttle routine shots, never block error evidence, and bound the posted size.
final class BotScreenshotToolTests: XCTestCase {
    private let botID = BotID()

    private static func widePNG(width: Int = 2000, height: Int = 1000) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func makeService(center: NotificationCenter) -> BotComputerGuestService {
        let png = Self.widePNG()
        let docker = BotComputerDockerCLI(run: { args in
            switch args.first {
            case "inspect":
                if args.contains(where: { $0.contains("Config.Labels\"") }) {
                    return Data(BotComputerGuestSpec.recipeRevision.utf8)
                }
                if args.contains("{{.Id}}") { return Data("img".utf8) }
                return Data("true img 49152  {}".utf8)
            case "create": return Data("cid".utf8)
            case "exec": return png
            default: return Data()
            }
        })
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-shot-\(UUID().uuidString)", isDirectory: true)
        let fixedNow = Date()
        return BotComputerGuestService(
            appSupport: support,
            docker: docker,
            observeAttempts: 1,
            observeDelay: 0,
            screenshotLimiter: BotScreenshotRateLimiter(interval: 30, now: { fixedNow }),
            notificationCenter: center
        )
    }

    private func action(_ subkind: String) -> BotComputerPendingAction {
        BotComputerPendingAction(
            id: UUID().uuidString,
            botID: botID.value.uuidString,
            kind: BotComputerCatalog.postScreenshot,
            reason: "progress",
            subkind: subkind
        )
    }

    func test_secondNormalShotWithinWindowIsRateLimitedButErrorShotPasses() throws {
        let center = NotificationCenter()
        var posted: [[AnyHashable: Any]] = []
        let token = center.addObserver(forName: .botScreenshotPosted, object: nil, queue: nil) {
            posted.append($0.userInfo ?? [:])
        }
        defer { center.removeObserver(token) }
        let service = makeService(center: center)

        let first = try service.apply(action("normal"))
        XCTAssertEqual(first["ok"] as? Bool, true)
        XCTAssertLessThanOrEqual(first["width"] as? Int ?? .max, 1280, "posted shot is downscaled")

        XCTAssertThrowsError(try service.apply(action("normal"))) { error in
            XCTAssertTrue("\(error)".contains("rate limited"), "got \(error)")
        }
        XCTAssertEqual(posted.count, 1, "blocked shot posts nothing")

        let errorShot = try service.apply(action("error"))
        XCTAssertEqual(errorShot["ok"] as? Bool, true, "error evidence is never throttled")
        XCTAssertEqual(posted.count, 2)

        let jpeg = try XCTUnwrap(posted[0][BotHostNotificationKey.jpeg] as? Data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(image.width, 1280)
        XCTAssertEqual(image.width, 1280, "2000px source is capped, not kept")
        XCTAssertEqual(posted[1][BotHostNotificationKey.kind] as? String, "error")
    }
}
