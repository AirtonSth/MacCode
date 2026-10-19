import XCTest
import SwiftUI
import AppKit
@testable import Surfaces

/// WHY: panes are resized and split; the composer controls must not push the card wider
/// than its pane (they used to overflow past the right edge).
@MainActor
final class AgentComposerResponsiveTests: XCTestCase {
    func test_wideControlRowFitsANarrowPane() {
        let chips = AnyView(HStack(spacing: 8) {
            ForEach(0..<8, id: \.self) { i in Text("very long control chip \(i)").fixedSize() }
        })
        let bar = AgentChatComposerBar(
            text: .constant(""), attachments: [], placeholder: "Ask", sendEnabled: true,
            runActive: false, isStopping: false, attachEnabled: true,
            onSend: {}, onStop: {}, onAttach: { _ in }, onRemoveAttachment: { _ in },
            composerIdentifier: "c", sendIdentifier: "s", leadingControls: chips
        )
        // Same bar hosts the Bots Desk footer (run-as, models, fixed-size Ultracode, permission).
        let controller = NSHostingController(rootView: bar)
        for width in [320.0, 360.0, 500.0, 900.0] {
            let size = controller.sizeThatFits(in: CGSize(width: width, height: 400))
            XCTAssertLessThanOrEqual(size.width, width + 1,
                "a long control row must scroll inside the composer, not widen a \(Int(width)) pt pane")
        }
    }
}
