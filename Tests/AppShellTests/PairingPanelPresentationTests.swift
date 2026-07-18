import AppKit
import XCTest
@testable import AppShell

@MainActor
final class PairingPanelPresentationTests: XCTestCase {
    private func prompt(id: String) -> PairingPrompt {
        let createdAt = Date()
        return PairingPrompt(
            requestId: id,
            code: "123456",
            deviceName: "Test iPhone",
            clientDeviceID: "test-client",
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(300)
        )
    }

    func test_pairingPanelUsesActivatingStyleSoApprovalControlsCanReceiveFocus() {
        let style = AppDelegate.pairingPanelStyleMask

        XCTAssertTrue(
            style.contains(.titled),
            "The pairing request needs normal titled-window behavior so it remains visible and actionable."
        )
        XCTAssertFalse(
            style.contains(.nonactivatingPanel),
            "A security approval prompt must activate with RemoteCode instead of remaining a non-activating floating panel."
        )
    }

    func test_pairingPanelCentersInsideAnchorScreenWithNegativeDisplayOrigin() {
        let visibleFrame = NSRect(x: -1_920, y: 24, width: 1_920, height: 1_056)
        let panelSize = NSSize(width: 400, height: 290)

        let frame = AppDelegate.pairingPanelFrame(
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame.midX, visibleFrame.midX, accuracy: 0.001)
        XCTAssertEqual(frame.midY, visibleFrame.midY, accuracy: 0.001)
        XCTAssertTrue(
            visibleFrame.contains(frame),
            "The pairing request must stay on the same visible display as the active RemoteCode window, including left-side external displays."
        )
    }

    func test_pairingPanelRemainsVisibleAcrossDeactivationAndCanPresentAgainAfterClose() {
        // WHY: repeated iOS reconnects must always get a fresh approval panel;
        // a hidden or merely ordered-out prior panel blocks terminal mirroring.
        let delegate = AppDelegate()
        delegate.presentPairingPrompt(prompt(id: "first"))
        guard let first = delegate.pairingSheet else {
            return XCTFail("the first valid pairing request must create a panel")
        }
        XCTAssertFalse(
            first.hidesOnDeactivate,
            "security approval must remain visible when activation moves between Mac and Simulator"
        )

        delegate.dismissPairingSheet()
        XCTAssertNil(delegate.pairingSheet, "closing a decision must clear the owned panel")
        XCTAssertFalse(first.isVisible, "the closed first panel must not remain on screen")

        delegate.presentPairingPrompt(prompt(id: "second"))
        guard let second = delegate.pairingSheet else {
            return XCTFail("a second valid request must create a fresh approval panel")
        }
        XCTAssertFalse(first === second, "a new request must never reuse the closed panel")
        XCTAssertFalse(second.hidesOnDeactivate, "the fresh panel must keep the durable visibility policy")
        XCTAssertTrue(second.isVisible, "the second panel must be ordered on screen")
        delegate.dismissPairingSheet()
    }
}
