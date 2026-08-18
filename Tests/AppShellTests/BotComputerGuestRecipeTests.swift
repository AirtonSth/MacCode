import XCTest

final class BotComputerGuestRecipeTests: XCTestCase {
    func test_recipeIsFirstPartyLinuxDesktop_notAlpineSleep() throws {
        // WHY: alpine/sleep would let Studio show Docker desktop without a
        // screen. The guest must be Xvfb + Chromium + view-only noVNC.
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
        XCTAssertTrue(start.contains("viewonly") || start.contains("-viewonly"))
        XCTAssertTrue(start.contains("websockify"))
        XCTAssertTrue(browser.lowercased().contains("chromium"))
        XCTAssertTrue(browser.contains("--no-sandbox"))
        XCTAssertTrue(embed.contains("token"))
        XCTAssertTrue(embed.contains("view_only"))
    }

    private func sourceURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }
}
