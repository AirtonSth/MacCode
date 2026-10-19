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
        let size = NSHostingController(rootView: bar).sizeThatFits(in: CGSize(width: 360, height: 400))
        XCTAssertLessThanOrEqual(size.width, 361,
            "a long control row must scroll inside the composer, not widen it past its pane")
    }
}
