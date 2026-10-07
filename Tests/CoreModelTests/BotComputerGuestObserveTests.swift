import XCTest
import CoreModel

final class BotComputerGuestObserveTests: XCTestCase {
    func test_observeRejectsNonPNGAndCapsActSteps() throws {
        // WHY: A JPEG placeholder would light the Studio radio without a
        // real guest screen. Act must stay a short brokered batch.
        XCTAssertThrowsError(try BotComputerGuestObserve.validatePNG(Data("not-png".utf8)))
        let png = BotComputerGuestObserve.pngSignature + Data(repeating: 0, count: 8)
        let hash = try BotComputerGuestObserve.validatePNG(png)
        XCTAssertEqual(hash.count, 64)
        XCTAssertThrowsError(try BotComputerGuestObserve.assertActStepCount(25))
        XCTAssertNoThrow(try BotComputerGuestObserve.assertActStepCount(3))
        XCTAssertThrowsError(try BotComputerGuestObserve.assertGuestRelativePath("../etc/passwd"))
    }

    func test_dragIsOneAtomicGuestCommand_becauseRemoteDragCannotBeThreeReplayableMutations() throws {
        let command = try BotComputerActStep(
            action: "drag",
            x: 10,
            y: 20,
            toX: 300,
            toY: 400
        ).execCommand()
        XCTAssertEqual(command, [
            "env", "DISPLAY=:1", "xdotool",
            "mousemove", "10", "20",
            "mousedown", "1",
            "mousemove", "--sync", "300", "400",
            "mouseup", "1",
        ])
        XCTAssertThrowsError(
            try BotComputerActStep(action: "drag", x: 10, y: 20, toX: 10, toY: 20).execCommand()
        )
    }

    func test_actBoundsFollowTheGuest1280x800Framebuffer() throws {
        // WHY: the guest Xvfb is 1280x800. The old 1600x1200 bound let off-screen
        // clicks through (xdotool clamps them to the edge, hitting the wrong spot).
        XCTAssertEqual(BotComputerGuestSpec.screenWidth, 1280)
        XCTAssertEqual(BotComputerGuestSpec.screenHeight, 800)
        XCTAssertNoThrow(try BotComputerActStep(action: "click", x: 0, y: 0).execCommand())
        XCTAssertNoThrow(try BotComputerActStep(action: "click", x: 1279, y: 799).execCommand())
        XCTAssertThrowsError(try BotComputerActStep(action: "click", x: 1280, y: 10).execCommand())
        XCTAssertThrowsError(try BotComputerActStep(action: "click", x: 10, y: 800).execCommand())
        XCTAssertThrowsError(try BotComputerActStep(action: "click", x: -1, y: 10).execCommand())
        XCTAssertThrowsError(try BotComputerActStep(action: "click", x: 1500, y: 1100).execCommand())

        XCTAssertNoThrow(
            try BotComputerActStep(action: "drag", x: 0, y: 0, toX: 1279, toY: 799).execCommand()
        )
        XCTAssertThrowsError(
            try BotComputerActStep(action: "drag", x: 10, y: 10, toX: 1280, toY: 10).execCommand(),
            "drag end is bounds-checked too"
        )
        XCTAssertThrowsError(
            try BotComputerActStep(action: "drag", x: 10, y: 800, toX: 20, toY: 20).execCommand(),
            "drag start is bounds-checked too"
        )
        XCTAssertThrowsError(
            try BotComputerActStep(action: "drag", x: 10, y: 10).execCommand(),
            "drag without an end point is rejected"
        )
    }
}
