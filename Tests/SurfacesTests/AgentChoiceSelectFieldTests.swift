import XCTest
@testable import Surfaces

final class AgentChoiceSelectFieldTests: XCTestCase {
    /// A matched value must show its option title, otherwise the user sees a value they did not pick.
    func testSelectedValueShowsItsOptionTitle() {
        let display = AgentChoiceSelectPresentation.display(matchedTitle: "GPT-5", rawValue: "gpt-5", placeholder: "Choose model")
        XCTAssertEqual(display, .init(text: "GPT-5", isUnavailable: false, isPlaceholder: false))
    }

    /// A saved model no longer offered must stay visible as unavailable, not be silently replaced.
    func testUnavailableValueShowsWarningText() {
        let display = AgentChoiceSelectPresentation.display(matchedTitle: nil, rawValue: "old-model", placeholder: "Choose model")
        XCTAssertEqual(display, .init(text: "Unavailable: old-model", isUnavailable: true, isPlaceholder: false))
    }

    /// An empty value means nothing chosen yet, so the placeholder is shown instead of a blank field.
    func testEmptyValueShowsPlaceholder() {
        let display = AgentChoiceSelectPresentation.display(matchedTitle: nil, rawValue: "", placeholder: "Same as Main")
        XCTAssertEqual(display, .init(text: "Same as Main", isUnavailable: false, isPlaceholder: true))
    }

    /// VoiceOver must read the field caption with its current value, so the caption is not lost.
    func testAccessibilityLabelCombinesCaptionAndValue() {
        XCTAssertEqual(AgentChoiceSelectPresentation.accessibilityLabel(caption: "MAIN MODEL", text: "GPT-5"), "MAIN MODEL, GPT-5")
    }
}
