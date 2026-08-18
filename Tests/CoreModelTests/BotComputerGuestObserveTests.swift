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
}
