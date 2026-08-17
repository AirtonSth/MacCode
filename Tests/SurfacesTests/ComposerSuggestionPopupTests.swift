import XCTest
import AppKit
import CoreModel
@testable import Surfaces

// macos:32 -- pure-seam coverage for the caret-anchored suggestion popup.
// The geometry (caret rect) is not unit-testable; these tests pin the LOGIC
// that decides what each keystroke does and how navigation wraps/clamps, plus
// the critical guarantee that send/history behavior is unchanged when the popup
// is CLOSED.
final class ComposerSuggestionPopupTests: XCTestCase {

    // MARK: - Extra commands + discovered skills surface in the menu

    // WHY: `/mcp` (a built-in Claude command the app doesn't own) and on-disk
    // project/user skills were invisible in the `/` menu. They must appear as
    // suggestions so the agent surface matches interactive claude's `/`.
    func testSuggestionsSurfaceExtraCommandsAndDiscoveredSkills() {
        let out = AgentComposerSuggestions.suggestions(
            for: "/",
            snapshot: nil,
            localSlashCommands: ["/clear"],
            extraCommands: ["/mcp"],
            extraSkillNames: ["task", "build-admin"],
            limit: 20
        )
        // insertText carries a trailing space (ready to type args): "/mcp ".
        let inserts = Set(out.map { $0.insertText.trimmingCharacters(in: .whitespaces) })
        XCTAssertTrue(inserts.contains("/mcp"), "built-in /mcp must be offered")
        XCTAssertTrue(inserts.contains("/task"), "a discovered project skill must be offered")
        XCTAssertTrue(inserts.contains("/build-admin"))
    }

    // WHY (regression, caught by grok review): when commands already fill the
    // limit (Claude's built-ins + /mcp + local modes), the old
    // `skillCap = max(limit, commandCount)` gave skills ZERO rows on a bare `/`,
    // hiding every project/user skill. Skills must still appear.
    func testBareSlashStillShowsSkillsWhenCommandsFillLimit() {
        // 10 commands (> default limit of 8) + discovered skills.
        let manyCommands = (0..<10).map { "/cmd\($0)" }
        let out = AgentComposerSuggestions.suggestions(
            for: "/",
            snapshot: nil,
            localSlashCommands: manyCommands,
            extraSkillNames: ["task", "deploy", "review"]
            // default limit = 8
        )
        let inserts = Set(out.map { $0.insertText.trimmingCharacters(in: .whitespaces) })
        XCTAssertTrue(inserts.contains("/task"),
                      "a project skill must still surface on bare `/` even when commands exceed the limit")
        let skillCount = out.filter { $0.kind == .skill }.count
        XCTAssertGreaterThan(skillCount, 0, "skills must never be starved to zero by a large command pool")
    }

    // WHY: typing `/ta` must filter down to the matching discovered skill.
    // WHY: Agent App `@` must list mentionable bots so a teammate can be
    // addressed from the same composer as slash commands.
    func test_atTokenSuggestsMentionableBots() {
        let quinn = BotDefinition(
            handle: "quinn",
            name: "Quinn",
            title: "CRM Controller",
            description: ""
        )
        let piper = BotDefinition(
            handle: "piper",
            name: "Piper",
            title: "Seller",
            description: ""
        )
        let out = AgentComposerSuggestions.suggestions(
            for: "@q",
            snapshot: nil,
            localSlashCommands: ["/clear"],
            mentionableBots: [quinn, piper],
            limit: 20
        )
        XCTAssertEqual(out.map(\.kind), [.bot])
        XCTAssertEqual(out.map(\.insertText), ["@quinn "])
        XCTAssertEqual(out.first?.title, "Quinn")
        XCTAssertTrue(out.first?.subtitle.contains("@quinn") == true)
        let empty = AgentComposerSuggestions.suggestions(
            for: "@",
            snapshot: nil,
            localSlashCommands: [],
            mentionableBots: [quinn, piper]
        )
        XCTAssertEqual(Set(empty.map(\.insertText)), ["@quinn ", "@piper "])
        let slashStillWins = AgentComposerSuggestions.suggestions(
            for: "/",
            snapshot: nil,
            localSlashCommands: ["/clear"],
            mentionableBots: [quinn]
        )
        XCTAssertFalse(slashStillWins.contains(where: { $0.kind == .bot }))
    }

    func testExtraSkillsAreFilteredByQuery() {
        let out = AgentComposerSuggestions.suggestions(
            for: "/ta",
            snapshot: nil,
            localSlashCommands: [],
            extraSkillNames: ["task", "unrelated"],
            limit: 20
        )
        let inserts = Set(out.map { $0.insertText.trimmingCharacters(in: .whitespaces) })
        XCTAssertTrue(inserts.contains("/task"))
        XCTAssertFalse(inserts.contains("/unrelated"), "non-matching skill must be filtered out")
    }

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

    // MARK: - Placement (inline panel between editor and toolbar)

    // WHY: the panel height must cap at 6 rows so a long slash/skill list cannot
    // shove the toolbar off-screen or reintroduce the caret-overlay collision.
    func testPlacementCapsVisibleRowsAtSix() {
        let layout = ComposerSuggestionPlacement.layout(suggestionCount: 20)
        XCTAssertEqual(layout.height, 6 * ComposerSuggestionPlacement.defaultRowHeight)
        XCTAssertEqual(layout.maxVisibleRows, 6)
    }

    // WHY: empty suggestion sets must produce a zero-height panel so the composer
    // does not reserve dead space when the popup is closed.
    func testPlacementZeroWhenEmpty() {
        let layout = ComposerSuggestionPlacement.layout(suggestionCount: 0)
        XCTAssertEqual(layout.height, 0)
    }

    // WHY: short lists size exactly to their row count (no empty scroll chrome).
    func testPlacementExactHeightForShortList() {
        let layout = ComposerSuggestionPlacement.layout(suggestionCount: 2)
        XCTAssertEqual(layout.height, 2 * ComposerSuggestionPlacement.defaultRowHeight)
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

    // WHY: macOS Option/dead-key input is how users type characters such as ç,
    // á, and é on common keyboard layouts (ABNT, US-International). The composer
    // must send these events through AppKit text input so composition commits
    // into the prompt instead of being swallowed by command/history routing.
    func testOptionAndDeadKeyTextInputBypassesCommandRouting() {
        XCTAssertTrue(
            PromptComposerKeyAction.shouldInterpretTextInput(
                keyCode: 8,
                modifiers: .option,
                characters: "ç"
            ),
            "Option+C must use AppKit text input so ç is inserted into the Agent composer"
        )
        XCTAssertTrue(
            PromptComposerKeyAction.shouldInterpretTextInput(
                keyCode: 14,
                modifiers: .option,
                characters: ""
            ),
            "Option dead-key composition must use AppKit text input even with empty characters"
        )
        // ABNT / many layouts: acute/tilde dead keys arrive WITHOUT Option and
        // with empty characters on the first press. They must still compose.
        XCTAssertTrue(
            PromptComposerKeyAction.shouldInterpretTextInput(
                keyCode: 24,
                modifiers: [],
                characters: ""
            ),
            "plain dead-key (empty characters, no Option) must use AppKit text input for accents"
        )
        XCTAssertTrue(
            PromptComposerKeyAction.shouldInterpretTextInput(
                keyCode: 0,
                modifiers: [],
                characters: "a"
            ),
            "plain letter keys must use AppKit text input"
        )
        XCTAssertFalse(
            PromptComposerKeyAction.shouldInterpretTextInput(
                keyCode: 36,
                modifiers: [],
                characters: "\r"
            ),
            "Return must stay on the composer send/newline route, not the generic text-input route"
        )
        XCTAssertFalse(
            PromptComposerKeyAction.shouldInterpretTextInput(
                keyCode: 0,
                modifiers: .command,
                characters: "a"
            ),
            "Command shortcuts must not be treated as text input"
        )
        // Brazilian-Pro acute dead key is physical keyCode 39 (empty characters).
        XCTAssertTrue(
            PromptComposerKeyAction.shouldInterpretTextInput(
                keyCode: 39,
                modifiers: [],
                characters: ""
            ),
            "Brazilian-Pro acute key (keycode 39) must use AppKit text input"
        )
    }

    // WHY: syncing the SwiftUI binding (or cursor observers) while marked text is
    // active re-enters updateNSView and can replace NSTextView.string, aborting
    // dead-key composition so á/é/í never land in the Agent composer.
    func testComposerBindingDoesNotSyncDuringMarkedText() {
        XCTAssertFalse(
            PromptComposerKeyAction.shouldSyncComposerBinding(hasMarkedText: true),
            "marked-text preedit must not publish into the SwiftUI prompt binding"
        )
        XCTAssertTrue(
            PromptComposerKeyAction.shouldSyncComposerBinding(hasMarkedText: false),
            "committed text must sync into the SwiftUI prompt binding"
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
