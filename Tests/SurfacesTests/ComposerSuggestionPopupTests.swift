import XCTest
import AppKit
@testable import Surfaces

// macos:32 -- pure-seam coverage for the caret-anchored suggestion popup.
// The geometry (caret rect) is not unit-testable; these tests pin the LOGIC
// that decides what each keystroke does and how navigation wraps/clamps, plus
// the critical guarantee that send/history behavior is unchanged when the popup
// is CLOSED.
final class ComposerSuggestionPopupTests: XCTestCase {

    // MARK: - Navigation: moveDown

    // WHY: from "nothing highlighted", the first Down must land on row 0 so the
    // user can apply the top suggestion with a single arrow + Return.
    func testMoveDownFromNilGoesToFirst() {
        XCTAssertEqual(ComposerSuggestionNavigation.moveDown(selected: nil, count: 3), 0)
    }

    // WHY: Down past the last row wraps to the top so the list is a loop, never
    // a dead end.
    func testMoveDownWrapsAtEnd() {
        XCTAssertEqual(ComposerSuggestionNavigation.moveDown(selected: 2, count: 3), 0)
    }

    // WHY: a normal Down advances by one.
    func testMoveDownAdvances() {
        XCTAssertEqual(ComposerSuggestionNavigation.moveDown(selected: 0, count: 3), 1)
    }

    // WHY: a stale selection larger than the new (shrunken) list must clamp into
    // range before advancing, so we never index out of bounds.
    func testMoveDownClampsStaleIndex() {
        // clamp 9 -> 2 (last), then advance with wrap -> 0
        XCTAssertEqual(ComposerSuggestionNavigation.moveDown(selected: 9, count: 3), 0)
    }

    // WHY: with no suggestions there is nothing to highlight.
    func testMoveDownCountZeroIsNil() {
        XCTAssertNil(ComposerSuggestionNavigation.moveDown(selected: 0, count: 0))
        XCTAssertNil(ComposerSuggestionNavigation.moveDown(selected: nil, count: 0))
    }

    // MARK: - Navigation: moveUp

    // WHY: from "nothing highlighted", the first Up must land on the LAST row so
    // the user can reach the bottom of the list quickly.
    func testMoveUpFromNilGoesToLast() {
        XCTAssertEqual(ComposerSuggestionNavigation.moveUp(selected: nil, count: 3), 2)
    }

    // WHY: Up from the top wraps to the bottom (loop symmetry with moveDown).
    func testMoveUpWrapsAtStart() {
        XCTAssertEqual(ComposerSuggestionNavigation.moveUp(selected: 0, count: 3), 2)
    }

    // WHY: a normal Up retreats by one.
    func testMoveUpRetreats() {
        XCTAssertEqual(ComposerSuggestionNavigation.moveUp(selected: 2, count: 3), 1)
    }

    // WHY: a stale over-range index must clamp before retreating.
    func testMoveUpClampsStaleIndex() {
        // clamp 9 -> 2 (last), then retreat -> 1
        XCTAssertEqual(ComposerSuggestionNavigation.moveUp(selected: 9, count: 3), 1)
    }

    // WHY: empty list -> nothing highlighted.
    func testMoveUpCountZeroIsNil() {
        XCTAssertNil(ComposerSuggestionNavigation.moveUp(selected: 1, count: 0))
        XCTAssertNil(ComposerSuggestionNavigation.moveUp(selected: nil, count: 0))
    }

    // MARK: - isOpen

    // WHY: the popup must show only when there are suggestions AND the user has
    // not dismissed it; this gates both the overlay and the keyDown interception.
    func testIsOpenOnlyWhenSuggestionsAndNotDismissed() {
        XCTAssertTrue(ComposerSuggestionNavigation.isOpen(count: 2, dismissed: false))
        XCTAssertFalse(ComposerSuggestionNavigation.isOpen(count: 0, dismissed: false))
        XCTAssertFalse(ComposerSuggestionNavigation.isOpen(count: 2, dismissed: true))
        XCTAssertFalse(ComposerSuggestionNavigation.isOpen(count: 0, dismissed: true))
    }

    // MARK: - Key resolution when popup is OPEN

    private let noMods: NSEvent.ModifierFlags = []

    // WHY: Up arrow with the popup open navigates the list, not prompt history.
    func testOpenUpArrowNavigates() {
        XCTAssertEqual(
            PromptComposerKeyAction.resolve(keyCode: 126, modifiers: noMods, popupOpen: true),
            .navUp
        )
    }

    // WHY: Down arrow with the popup open navigates the list, not prompt history.
    func testOpenDownArrowNavigates() {
        XCTAssertEqual(
            PromptComposerKeyAction.resolve(keyCode: 125, modifiers: noMods, popupOpen: true),
            .navDown
        )
    }

    // WHY: plain Return with the popup open APPLIES the highlighted suggestion
    // (it must NOT send the message while the user is picking a command).
    func testOpenReturnApplies() {
        XCTAssertEqual(
            PromptComposerKeyAction.resolve(keyCode: 36, modifiers: noMods, popupOpen: true),
            .applySelected
        )
        // Numeric-keypad Enter (76) behaves identically.
        XCTAssertEqual(
            PromptComposerKeyAction.resolve(keyCode: 76, modifiers: noMods, popupOpen: true),
            .applySelected
        )
    }

    // WHY: Esc with the popup open dismisses it (and only it), leaving the prompt
    // text intact.
    func testOpenEscDismisses() {
        XCTAssertEqual(
            PromptComposerKeyAction.resolve(keyCode: 53, modifiers: noMods, popupOpen: true),
            .dismissPopup
        )
    }

    // WHY: even with the popup open, Shift+Return must still insert a newline so
    // the user can compose a multiline prompt while the list is visible.
    func testOpenShiftReturnPassesThroughToNewline() {
        XCTAssertEqual(
            PromptComposerKeyAction.resolve(keyCode: 36, modifiers: .shift, popupOpen: true),
            .passthrough(.insertNewline)
        )
    }

    // WHY: a normal letter key with the popup open is not a navigation key, so it
    // passes through to the editor (which maps it to .ignore == default typing).
    func testOpenLetterPassesThrough() {
        // keyCode 0 == 'a'
        XCTAssertEqual(
            PromptComposerKeyAction.resolve(keyCode: 0, modifiers: noMods, popupOpen: true),
            .passthrough(.ignore)
        )
    }

    // MARK: - Key resolution when popup is CLOSED (the critical guarantees)

    // WHY: THIS IS THE GUARD. With the popup closed, plain Return must SEND the
    // message exactly as before -- the popup feature must never break send.
    func testClosedReturnStillSends() {
        XCTAssertEqual(
            PromptComposerKeyAction.resolve(keyCode: 36, modifiers: noMods, popupOpen: false),
            .passthrough(.send)
        )
    }

    // WHY: with the popup closed, Up arrow must still recall the PREVIOUS prompt
    // from history (unchanged behavior).
    func testClosedUpArrowIsHistory() {
        XCTAssertEqual(
            PromptComposerKeyAction.resolve(keyCode: 126, modifiers: noMods, popupOpen: false),
            .passthrough(.previousHistory)
        )
    }

    // WHY: with the popup closed, Down arrow must still recall the NEXT prompt
    // from history (unchanged behavior).
    func testClosedDownArrowIsHistory() {
        XCTAssertEqual(
            PromptComposerKeyAction.resolve(keyCode: 125, modifiers: noMods, popupOpen: false),
            .passthrough(.nextHistory)
        )
    }

    // MARK: - The existing 2-arg seam must remain byte-for-byte unchanged

    // WHY: the original pure mapping is still used by the passthrough path and by
    // any other caller; plain Return there must still mean .send.
    func testExistingTwoArgActionUnchangedForReturn() {
        XCTAssertEqual(PromptComposerKeyAction.action(keyCode: 36, modifiers: noMods), .send)
        XCTAssertEqual(PromptComposerKeyAction.action(keyCode: 126, modifiers: noMods), .previousHistory)
        XCTAssertEqual(PromptComposerKeyAction.action(keyCode: 125, modifiers: noMods), .nextHistory)
        XCTAssertEqual(PromptComposerKeyAction.action(keyCode: 36, modifiers: .shift), .insertNewline)
    }
}
