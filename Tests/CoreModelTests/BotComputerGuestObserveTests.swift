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
}
