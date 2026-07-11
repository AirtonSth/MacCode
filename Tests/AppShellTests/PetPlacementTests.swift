import XCTest
@testable import AppShell

final class PetPlacementTests: XCTestCase {
    private let visibleFrame = CGRect(x: 100, y: 100, width: 1_000, height: 700)

    func test_petScreenFrameUsesPhysicalSideAndBottomEdgesButKeepsMenuBarClear() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let dockAndMenuVisibleFrame = CGRect(x: 80, y: 60, width: 840, height: 710)

        XCTAssertEqual(
            PetScreenGeometry.petPlacementFrame(
                screenFrame: screenFrame,
                visibleFrame: dockAndMenuVisibleFrame
            ),
            CGRect(x: 0, y: 0, width: 1_000, height: 770),
            "the pet may occupy Dock-reserved side/bottom space, but must remain below the menu bar"
        )
    }

    func test_petScreenFramePreservesOffsetDisplayCoordinates() {
        XCTAssertEqual(
            PetScreenGeometry.petPlacementFrame(
                screenFrame: CGRect(x: 3_337, y: 158, width: 1_728, height: 1_117),
                visibleFrame: CGRect(x: 3_400, y: 218, width: 1_600, height: 1_025)
            ),
            CGRect(x: 3_337, y: 158, width: 1_728, height: 1_085),
            "secondary-display offsets must not become artificial margins"
        )
    }

    func test_normalizedPositionAlwaysClampsToUnitRange() {
        XCTAssertEqual(PetNormalizedPosition(x: -2, y: 5), PetNormalizedPosition(x: 0, y: 1))
    }

    func test_decodedNormalizedPositionCannotBypassUnitRangeInvariant() throws {
        let decoded = try JSONDecoder().decode(
            PetNormalizedPosition.self,
            from: Data(#"{"x":-2,"y":5}"#.utf8)
        )

        XCTAssertEqual(
            decoded,
            PetNormalizedPosition(x: 0, y: 1),
            "Corrupt persisted coordinates must not restore the pet off-screen."
        )
    }

    func test_defaultPlacementAllowsPetToTouchEveryVisibleEdge() {
        let size = CGSize(width: 100, height: 100)
        let bottomLeft = PetPlacement.frame(
            size: size,
            normalizedPosition: PetNormalizedPosition(x: 0, y: 0),
            in: visibleFrame
        )
        let topRight = PetPlacement.frame(
            size: size,
            normalizedPosition: PetNormalizedPosition(x: 1, y: 1),
            in: visibleFrame
        )

        XCTAssertEqual(bottomLeft.minX, visibleFrame.minX, accuracy: 0.001)
        XCTAssertEqual(bottomLeft.minY, visibleFrame.minY, accuracy: 0.001)
        XCTAssertEqual(topRight.maxX, visibleFrame.maxX, accuracy: 0.001)
        XCTAssertEqual(topRight.maxY, visibleFrame.maxY, accuracy: 0.001)
        XCTAssertEqual(
            PetPlacement.normalizedPosition(for: bottomLeft, in: visibleFrame),
            PetNormalizedPosition(x: 0, y: 0)
        )
        XCTAssertEqual(
            PetPlacement.normalizedPosition(for: topRight, in: visibleFrame),
            PetNormalizedPosition(x: 1, y: 1)
        )
    }

    func test_clampKeepsEveryPetEdgeInsideVisibleFrameMargin() {
        let margin: CGFloat = 16
        let size = CGSize(width: 100, height: 100)
        let expectedOrigins: [(CGPoint, CGPoint)] = [
            (CGPoint(x: -500, y: 300), CGPoint(x: 116, y: 300)),
            (CGPoint(x: 2_000, y: 300), CGPoint(x: 984, y: 300)),
            (CGPoint(x: 300, y: -500), CGPoint(x: 300, y: 116)),
            (CGPoint(x: 300, y: 2_000), CGPoint(x: 300, y: 684))
        ]

        for (input, expected) in expectedOrigins {
            let clamped = PetPlacement.clamped(
                frame: CGRect(origin: input, size: size),
                to: visibleFrame,
                margin: margin
            )
            XCTAssertEqual(clamped.origin.x, expected.x, accuracy: 0.001)
            XCTAssertEqual(clamped.origin.y, expected.y, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(clamped.minX, visibleFrame.minX + margin)
            XCTAssertLessThanOrEqual(clamped.maxX, visibleFrame.maxX - margin)
            XCTAssertGreaterThanOrEqual(clamped.minY, visibleFrame.minY + margin)
            XCTAssertLessThanOrEqual(clamped.maxY, visibleFrame.maxY - margin)
        }
    }

    func test_oversizedFrameShrinksToScreenSafeAreaInsteadOfClipping() {
        let clamped = PetPlacement.clamped(
            frame: CGRect(x: -100, y: -100, width: 2_000, height: 1_000),
            to: visibleFrame,
            margin: 16
        )

        XCTAssertEqual(clamped, CGRect(x: 116, y: 116, width: 968, height: 668))
    }

    func test_marginLargerThanTinyDisplayStillKeepsFrameInsideDisplay() {
        let tinyDisplay = CGRect(x: 40, y: 80, width: 20, height: 12)
        let clamped = PetPlacement.clamped(
            frame: CGRect(x: -100, y: -100, width: 96, height: 96),
            to: tinyDisplay,
            margin: 16
        )

        XCTAssertGreaterThanOrEqual(clamped.minX, tinyDisplay.minX)
        XCTAssertLessThanOrEqual(clamped.maxX, tinyDisplay.maxX)
        XCTAssertGreaterThanOrEqual(clamped.minY, tinyDisplay.minY)
        XCTAssertLessThanOrEqual(clamped.maxY, tinyDisplay.maxY)
    }

    func test_normalizedPositionRoundTripsAcrossCurrentDisplay() {
        let original = CGRect(x: 742, y: 417, width: 96, height: 96)
        let normalized = PetPlacement.normalizedPosition(
            for: original,
            in: visibleFrame,
            margin: 16
        )
        let restored = PetPlacement.frame(
            size: original.size,
            normalizedPosition: normalized,
            in: visibleFrame,
            margin: 16
        )

        XCTAssertEqual(restored.origin.x, original.origin.x, accuracy: 0.001)
        XCTAssertEqual(restored.origin.y, original.origin.y, accuracy: 0.001)
    }

    func test_normalizedPositionRestoresProportionallyOnReplacementDisplay() {
        let replacementDisplay = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
        let frame = PetPlacement.frame(
            size: CGSize(width: 96, height: 96),
            normalizedPosition: PetNormalizedPosition(x: 1, y: 0),
            in: replacementDisplay,
            margin: 16
        )

        XCTAssertEqual(frame.maxX, replacementDisplay.maxX - 16, accuracy: 0.001)
        XCTAssertEqual(frame.minY, replacementDisplay.minY + 16, accuracy: 0.001)
    }

    func test_bottomRightAnchorPlacesPopoverAboveAndTrailing() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let result = PetPopoverPlacement.resolve(
            anchorFrame: CGRect(x: 1_320, y: 20, width: 96, height: 96),
            requestedSize: CGSize(width: 360, height: 520),
            visibleFrame: screen
        )

        XCTAssertEqual(result.orientation.vertical, .above)
        XCTAssertEqual(result.orientation.horizontal, .trailing)
        XCTAssertGreaterThanOrEqual(result.frame.minX, 12)
        XCTAssertLessThanOrEqual(result.frame.maxX, 1_428)
        XCTAssertGreaterThanOrEqual(result.frame.minY, 12)
        XCTAssertLessThanOrEqual(result.frame.maxY, 888)
    }

    func test_topLeftAnchorPlacesPopoverBelowAndLeading() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let result = PetPopoverPlacement.resolve(
            anchorFrame: CGRect(x: 20, y: 780, width: 96, height: 96),
            requestedSize: CGSize(width: 360, height: 520),
            visibleFrame: screen
        )

        XCTAssertEqual(result.orientation.vertical, .below)
        XCTAssertEqual(result.orientation.horizontal, .leading)
        XCTAssertEqual(result.frame.minX, 20, accuracy: 0.001)
        XCTAssertLessThan(result.frame.maxY, 780)
    }

    func test_popoverShrinksAndClampsWhenRequestedSizeExceedsDisplay() {
        let screen = CGRect(x: 500, y: 200, width: 600, height: 400)
        let result = PetPopoverPlacement.resolve(
            anchorFrame: CGRect(x: 760, y: 350, width: 96, height: 96),
            requestedSize: CGSize(width: 2_000, height: 2_000),
            visibleFrame: screen,
            margin: 12,
            spacing: 8
        )

        XCTAssertEqual(result.frame, CGRect(x: 512, y: 212, width: 576, height: 376))
    }
}
