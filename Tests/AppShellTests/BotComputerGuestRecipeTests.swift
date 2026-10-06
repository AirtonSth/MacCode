import XCTest
import CoreModel

final class BotComputerGuestRecipeTests: XCTestCase {
    func test_recipeIsFirstPartyLinuxDesktop_notAlpineSleep() throws {
        // WHY: alpine/sleep would let Studio show Docker desktop without a
        // screen. The guest must be Xvfb + Chromium + interactive noVNC.
        let root = sourceURL("Sources/AppShell/Resources/ComputerGuest")
        let dockerfile = try String(contentsOf: root.appendingPathComponent("Dockerfile"), encoding: .utf8)
        let start = try String(contentsOf: root.appendingPathComponent("start.sh"), encoding: .utf8)
        let browser = try String(contentsOf: root.appendingPathComponent("launch-browser.sh"), encoding: .utf8)
        let embed = try String(contentsOf: root.appendingPathComponent("embed.html"), encoding: .utf8)
        XCTAssertTrue(dockerfile.lowercased().contains("debian"))
        XCTAssertFalse(dockerfile.lowercased().contains("alpine"))
        XCTAssertFalse(dockerfile.contains("CMD sleep"))
        XCTAssertTrue(start.contains("Xvfb"))
        XCTAssertTrue(start.lowercased().contains("fluxbox"))
        XCTAssertFalse(start.contains("viewonly") || start.contains("-viewonly"))
        XCTAssertTrue(start.contains("websockify"))
        XCTAssertTrue(browser.lowercased().contains("chromium"))
        XCTAssertTrue(browser.contains("--no-sandbox"))
        XCTAssertTrue(embed.contains("token"))
        XCTAssertTrue(embed.contains("view_only=0"))
    }

    func test_xvfbGeometryMatchesTheActCoordinateBounds() throws {
        // WHY: bot_computer_act bounds clicks/drags by BotComputerGuestSpec's screen
        // size. If start.sh's Xvfb geometry drifts, valid on-screen points get
        // rejected or off-screen points get clamped onto the wrong control.
        let start = try String(
            contentsOf: sourceURL("Sources/AppShell/Resources/ComputerGuest/start.sh"),
            encoding: .utf8
        )
        let geometry = "\(BotComputerGuestSpec.screenWidth)x\(BotComputerGuestSpec.screenHeight)x24"
        XCTAssertTrue(start.contains("Xvfb :1 -screen 0 \(geometry) "), "start.sh must start Xvfb at \(geometry)")
    }

    private func sourceURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }
}
