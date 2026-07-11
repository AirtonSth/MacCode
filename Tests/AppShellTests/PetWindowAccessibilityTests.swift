import AppKit
import CoreGraphics
import Persistence
import SwiftUI
import XCTest
@testable import AppShell

@MainActor
final class PetWindowAccessibilityTests: XCTestCase {
    private func database() throws -> SQLiteDB {
        let directory = NSTemporaryDirectory() + "RC2PetWindowAccessibility-\(UUID().uuidString)"
        return try Bootstrap(channel: .debug, appSupportOverride: directory).run().1
    }

    private func controller(
        model: PetViewModel? = nil
    ) throws -> PetWindowController {
        let model = model ?? PetViewModel(settings: AppSettings(petEnabled: true))
        return PetWindowController(
            model: model,
            placementStore: PetPlacementStore(repository: SettingsRepository(db: try database()))
        )
    }

    func test_dragThresholdUsesFourPointsAndFinishResetsTheDecision() {
        var interaction = PetDragInteraction()
        interaction.begin(mouseLocation: .zero, windowOrigin: CGPoint(x: 40, y: 60))

        XCTAssertNil(interaction.draggedWindowOrigin(to: CGPoint(x: 3.9, y: 0)))
        XCTAssertFalse(interaction.didDrag)
        XCTAssertEqual(
            interaction.draggedWindowOrigin(to: CGPoint(x: 4, y: 0)),
            CGPoint(x: 44, y: 60)
        )
        XCTAssertTrue(interaction.didDrag)
        XCTAssertTrue(interaction.finish(), "mouse-up must retain the drag decision for routing")
        XCTAssertFalse(interaction.didDrag, "mouse-up must reset click-through state after routing")
        XCTAssertFalse(interaction.finish(), "a consumed drag must not leak into the next interaction")
    }

    func test_alphaMaskBuildsOncePerFrameInsteadOfCopyingProviderDataPerHover() throws {
        let firstImage = try image(alpha: [0, 255, 255, 0])
        let secondImage = try image(alpha: [255, 255, 255, 255])
        var currentImage = firstImage
        let view = PetSpriteHostingView(rootView: EmptyView())
        view.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        view.imageProvider = { currentImage }

        XCTAssertFalse(view.isOpaque(at: CGPoint(x: 5, y: 5)))
        XCTAssertTrue(view.isOpaque(at: CGPoint(x: 15, y: 5)))
        XCTAssertFalse(view.isOpaque(at: CGPoint(x: 5, y: 5)))
        XCTAssertEqual(view.alphaMaskBuildCountForTests, 1)

        currentImage = secondImage
        XCTAssertTrue(view.isOpaque(at: CGPoint(x: 5, y: 5)))
        XCTAssertEqual(view.alphaMaskBuildCountForTests, 2)
    }

    func test_rowAccessibilityIdentifierIsStableSHA256AndNeverContainsRawRequestID() {
        let raw = "request/secret:abc-123"
        let identifier = PetAccessibilityIdentifier.row(raw)

        XCTAssertEqual(
            identifier,
            "19a0f89a68c1442253108834f090995551fe30e96cbd05f3a315b95db9805c85"
        )
        XCTAssertFalse(identifier.contains("request"))
        XCTAssertFalse(identifier.contains("secret"))
        XCTAssertEqual(identifier, PetAccessibilityIdentifier.row(raw))
        XCTAssertNotEqual(identifier, PetAccessibilityIdentifier.row(raw + "-other"))
    }

    func test_spriteExposesButtonRoleAndDefaultPressAction() throws {
        let controller = try controller()
        defer { controller.stop() }
        controller.show()
        let sprite = try XCTUnwrap(controller.spriteAccessibilityViewForTests)

        XCTAssertEqual(sprite.accessibilityRole(), .button)
        XCTAssertEqual(sprite.accessibilityLabel(), "Remote Code pet")
        XCTAssertTrue(sprite.accessibilityPerformPress())
        XCTAssertTrue(controller.isPopoverVisible)
    }

    func test_contextMenuContainsCareSubmenuAndRoutesEveryCareAction() throws {
        let controller = try controller()
        var received: [PetCareAction] = []
        controller.onCareAction = { received.append($0) }

        let menu = controller.contextMenuForTests()
        let care = try XCTUnwrap(menu.items.first(where: { $0.title == "Care" })?.submenu)
        XCTAssertEqual(care.items.map(\.title), PetCareAction.allCases.map(\.title))

        for item in care.items {
            XCTAssertNotNil(item.action)
            XCTAssertTrue(item.target === controller)
            controller.invokeCareMenuItemForTests(item)
        }
        XCTAssertEqual(received, PetCareAction.allCases,
            "every right-click care command must reach the authored reaction router")
    }

    func test_popoverSizingUsesFittingHeightAndCapsToScreenSafeMaximum() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 800, height: 700)

        XCTAssertEqual(
            PetPopoverSizing.resolve(
                fittingSize: CGSize(width: 360, height: 314),
                visibleFrame: visibleFrame
            ),
            CGSize(width: 360, height: 314)
        )
        XCTAssertEqual(
            PetPopoverSizing.resolve(
                fittingSize: CGSize(width: 360, height: 900),
                visibleFrame: visibleFrame
            ),
            CGSize(width: 360, height: 520)
        )

        let shortScreen = CGRect(x: 0, y: 0, width: 800, height: 400)
        XCTAssertEqual(
            PetPopoverSizing.resolve(
                fittingSize: CGSize(width: 360, height: 900),
                visibleFrame: shortScreen
            ).height,
            376
        )
    }

    func test_singleItemPopoverUsesMeasuredContentInsteadOfLegacy180PointFormula() throws {
        let model = PetViewModel(settings: AppSettings(petEnabled: true))
        model.apply(snapshot: PetAttentionSnapshot(items: [attentionItem(kind: .agentOutcome(.completed))]))
        let controller = try controller(model: model)
        defer { controller.stop() }

        controller.show()
        controller.openPopoverForTests()

        let panel = try XCTUnwrap(controller.popoverPanelForTests)
        XCTAssertGreaterThan(panel.frame.height, 180)
        XCTAssertLessThanOrEqual(panel.frame.height, 520)
        if let screen = panel.screen ?? NSScreen.main {
            XCTAssertLessThanOrEqual(panel.frame.height, screen.visibleFrame.height - 24 + 0.5)
        }
    }

    func test_failedAndInterruptedRowsUseSemanticNonSuccessStatus() {
        XCTAssertEqual(PetAttentionVisualStatus.resolve(.agentOutcome(.failed)), .failed)
        XCTAssertEqual(PetAttentionVisualStatus.resolve(.agentOutcome(.interrupted)), .interrupted)
        XCTAssertEqual(PetAttentionVisualStatus.resolve(.agentOutcome(.completed)), .completed)
        XCTAssertEqual(PetAttentionVisualStatus.resolve(.notification(.gitFailed)), .failed)
        XCTAssertEqual(PetAttentionVisualStatus.resolve(.notification(.fileConflict)), .needsAttention)
        XCTAssertNotEqual(PetAttentionVisualStatus.failed.systemImage, "checkmark.circle.fill")
        XCTAssertEqual(PetAttentionVisualStatus.failed.accessibilityLabel, "Failed")
    }

    func test_closingPopoverRestoresPreviousKeyWindow() throws {
        let previous = RecordingKeyWindow(
            contentRect: CGRect(x: 100, y: 100, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        let controller = try controller()
        defer { controller.stop() }
        controller.show()
        controller.keyWindowProviderForTests = { previous }
        controller.openPopoverForTests()
        let popover = try XCTUnwrap(controller.popoverPanelForTests)
        XCTAssertTrue(popover.canBecomeKey)
        XCTAssertTrue(popover.isVisible,
            "The broad XCTest host may deny global key status, but opening must still show a key-capable panel.")

        controller.closePopover()

        XCTAssertEqual(previous.restoreCount, 1)
    }

    func test_routeDismissalDoesNotRestorePreviousKeyWindow() throws {
        let previous = RecordingKeyWindow(
            contentRect: CGRect(x: 100, y: 100, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let controller = try controller()
        defer { controller.stop() }
        controller.show()
        controller.keyWindowProviderForTests = { previous }
        controller.openPopoverForTests()

        controller.closePopover(restoringPreviousKeyWindow: false)

        XCTAssertEqual(previous.restoreCount, 0,
            "A verified route must keep its destination key instead of restoring the pre-popover window.")
    }

    func test_screenSelectionRequiresPositiveIntersection() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1_000, height: 800),
            CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
        ]

        XCTAssertNil(PetScreenGeometry.largestPositiveIntersectionIndex(
            frame: CGRect(x: -500, y: -500, width: 100, height: 100),
            screenFrames: screens
        ))
        XCTAssertEqual(PetScreenGeometry.largestPositiveIntersectionIndex(
            frame: CGRect(x: 950, y: 100, width: 200, height: 200),
            screenFrames: screens
        ), 1)
    }

    func test_globalMouseMovesCoalesceToLatestSynchronouslyCapturedPoint() async throws {
        let controller = try controller()
        defer { controller.stop() }

        controller.enqueueGlobalMouseMoveForTests(CGPoint(x: 10, y: 20))
        controller.enqueueGlobalMouseMoveForTests(CGPoint(x: 30, y: 40))
        controller.enqueueGlobalMouseMoveForTests(CGPoint(x: 50, y: 60))
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(controller.lastProcessedGlobalMousePointForTests, CGPoint(x: 50, y: 60))
        XCTAssertEqual(controller.globalMouseMoveProcessCountForTests, 1)
    }

    private func attentionItem(kind: PetAttentionItemKind) -> PetAttentionItem {
        PetAttentionItem(
            id: "request/secret:abc-123",
            kind: kind,
            title: "Safe status",
            detail: "Workspace",
            createdAt: Date(timeIntervalSince1970: 1),
            route: .settings(.general),
            source: .notification(id: "notification-1")
        )
    }

    private func image(alpha: [UInt8]) throws -> CGImage {
        XCTAssertEqual(alpha.count, 4)
        var rgba: [UInt8] = []
        for value in alpha {
            rgba.append(contentsOf: [20, 30, 40, value])
        }
        let data = Data(rgba) as CFData
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        return try XCTUnwrap(CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }
}

@MainActor
private final class RecordingKeyWindow: NSWindow {
    private(set) var restoreCount = 0

    override var isVisible: Bool { true }
    override var canBecomeKey: Bool { true }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        restoreCount += 1
    }
}
