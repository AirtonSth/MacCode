import XCTest
import AppKit
import SwiftUI
@testable import Surfaces

/// Perf CH-10: the composer's NSViewRepresentable used to force a full
/// layoutManager.ensureLayout of the prompt on EVERY SwiftUI update (and twice
/// per keystroke via textDidChange + the binding round-trip), so any parent
/// invalidation — a streamed token while typing — relaid out the whole prompt.
final class AgentComposerTextEditorHeightTests: XCTestCase {
    private func makeTextView() -> PromptComposerTextView {
        let contentSize = NSSize(width: 480, height: 44)
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            containerSize: NSSize(width: contentSize.width, height: .greatestFiniteMagnitude)
        )
        layoutManager.addTextContainer(container)
        let textView = PromptComposerTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: container)
        textView.font = .systemFont(ofSize: 13)
        return textView
    }

    private func makeCoordinator(text: String, height: CGFloat)
        -> (coordinator: AgentComposerTextEditor.Coordinator, textView: PromptComposerTextView, text: BindingBox<String>, height: BindingBox<CGFloat>) {
        let textBox = BindingBox(text)
        let heightBox = BindingBox(height)
        let coordinator = AgentComposerTextEditor.Coordinator(
            text: Binding(get: { textBox.value }, set: { textBox.value = $0 }),
            height: Binding(get: { heightBox.value }, set: { heightBox.value = $0 }),
            onTextEdited: {},
            onCursorMoved: { _ in },
            onCaretRectChanged: { _ in }
        )
        let textView = makeTextView()
        coordinator.textView = textView
        return (coordinator, textView, textBox, heightBox)
    }

    func test_keystrokeRunsExactlyOneLayout_andUnchangedExternalUpdatesRunNone() {
        let (coordinator, textView, textBox, _) = makeCoordinator(text: "", height: 44)

        // Simulate typing a character: textDidChange runs one layout pass.
        textView.string = "h"
        textBox.value = "h"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        XCTAssertEqual(coordinator.recalculateHeightCountForTesting, 1,
                       "one keystroke must cost exactly one height layout pass")

        // A SwiftUI update with unchanged text and width must NOT relayout —
        // this is the pass that used to fire on every parent invalidation.
        XCTAssertFalse(
            coordinator.needsHeightRecalculation(for: textView),
            "an external update with no text/width change must skip ensureLayout"
        )

        // More keystrokes: exactly one pass each.
        textView.string = "hi"
        textBox.value = "hi"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        XCTAssertEqual(coordinator.recalculateHeightCountForTesting, 2)

        // An external text apply (programmatic set) must schedule one pass.
        coordinator.applyExternalText("restored draft", to: textView)
        XCTAssertTrue(coordinator.needsHeightRecalculation(for: textView),
                      "an external text apply must relayout even at an unchanged width")
        coordinator.recalculateHeight()
        XCTAssertFalse(coordinator.needsHeightRecalculation(for: textView))
    }

    func test_widthChangeRequiresLayout() {
        let (coordinator, textView, _, _) = makeCoordinator(text: "", height: 44)
        textView.string = "hello"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        XCTAssertFalse(coordinator.needsHeightRecalculation(for: textView))

        // Window resize widens the container: layout must run again.
        textView.textContainer?.size.width += 120
        XCTAssertTrue(
            coordinator.needsHeightRecalculation(for: textView),
            "a container width change must relayout (wrapping changed)"
        )
    }

    func test_pureGateCoversApplyWidthAndFreshState() {
        XCTAssertTrue(AgentComposerTextEditor.Coordinator.shouldRecalculateHeight(
            appliedExternalText: true, currentWidth: 480, lastCalculatedWidth: 480
        ), "external applies always need layout")
        XCTAssertTrue(AgentComposerTextEditor.Coordinator.shouldRecalculateHeight(
            appliedExternalText: false, currentWidth: 600, lastCalculatedWidth: 480
        ), "width changes need layout")
        XCTAssertFalse(AgentComposerTextEditor.Coordinator.shouldRecalculateHeight(
            appliedExternalText: false, currentWidth: 480, lastCalculatedWidth: 480
        ), "unchanged text and width must skip layout")
        XCTAssertTrue(AgentComposerTextEditor.Coordinator.shouldRecalculateHeight(
            appliedExternalText: false, currentWidth: 480, lastCalculatedWidth: nil
        ), "the first pass after mount always runs")
    }
}

/// Tiny box so tests can hand the coordinator real two-way Bindings.
final class BindingBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
