import XCTest
import GhosttyKit
@testable import Surfaces

/// Tests for the pure GhosttyActionMapper and cursor mapper.
///
/// WHY these tests matter:
/// - The action_cb previously returned `true` for every action without doing
///   anything (silent drop). Introducing handling means future regressions
///   would silently revert. These tests pin that SET_TITLE produces a `.setTitle`
///   effect, MOUSE_SHAPE produces `.mouseShape`, and unknown actions produce nil
///   so we never crash on unrecognized future action tags.
/// - The cursor mapper is tested separately so a wrong enum branch (e.g. pointer
///   mapped to iBeam) gets caught here rather than at the GPU-driver level.
///
/// @MainActor required: the file imports Surfaces which contains @MainActor view
/// types; the annotation satisfies the actor-isolation checker even though the
/// tested symbols are nonisolated statics.
@MainActor
final class GhosttyActionMapperTests: XCTestCase {

    // MARK: - GhosttyActionMapper.map

    func test_setTitle_producesSetTitleEffect() {
        // OSC 2 causes Ghostty to fire GHOSTTY_ACTION_SET_TITLE. The host must
        // update the tab label; dropping it means the tab title never updates.
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_SET_TITLE
        // Build a C string and point the struct at it for the duration of the call.
        "hello world".withCString { ptr in
            action.action = ghostty_action_u()
            action.action.set_title = ghostty_action_set_title_s(title: ptr)
            guard case .setTitle(let title) = GhosttyActionMapper.map(action) else {
                XCTFail("GHOSTTY_ACTION_SET_TITLE must produce a .setTitle effect")
                return
            }
            XCTAssertEqual(title, "hello world",
                "SET_TITLE effect must carry the exact title string from the C struct")
        }
    }

    func test_setTabTitle_producesSetTitleEffect() {
        // GHOSTTY_ACTION_SET_TAB_TITLE is the per-tab variant; it uses the same
        // struct layout and should map identically.
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_SET_TAB_TITLE
        "tab label".withCString { ptr in
            action.action = ghostty_action_u()
            action.action.set_tab_title = ghostty_action_set_title_s(title: ptr)
            guard case .setTitle(let title) = GhosttyActionMapper.map(action) else {
                XCTFail("GHOSTTY_ACTION_SET_TAB_TITLE must produce a .setTitle effect")
                return
            }
            XCTAssertEqual(title, "tab label")
        }
    }

    func test_setTitle_nilCString_producesEmptyString() {
        // Ghostty may send a nil title pointer when clearing the title; the host
        // must not crash and must treat it as an empty string reset.
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_SET_TITLE
        action.action = ghostty_action_u()
        action.action.set_title = ghostty_action_set_title_s(title: nil)
        guard case .setTitle(let title) = GhosttyActionMapper.map(action) else {
            XCTFail("GHOSTTY_ACTION_SET_TITLE with nil pointer must still produce a .setTitle effect")
            return
        }
        XCTAssertEqual(title, "",
            "a nil title C-string must map to an empty Swift string, not crash")
    }

    func test_mouseShape_producesMouseShapeEffect() {
        // TUI programs (vim, htop) set the cursor shape via escape sequences.
        // Dropping GHOSTTY_ACTION_MOUSE_SHAPE means the cursor never changes,
        // breaking e.g. the I-beam in insert mode.
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_MOUSE_SHAPE
        action.action = ghostty_action_u()
        action.action.mouse_shape = GHOSTTY_MOUSE_SHAPE_POINTER
        guard case .mouseShape(let shape) = GhosttyActionMapper.map(action) else {
            XCTFail("GHOSTTY_ACTION_MOUSE_SHAPE must produce a .mouseShape effect")
            return
        }
        XCTAssertEqual(shape, GHOSTTY_MOUSE_SHAPE_POINTER,
            "mouseShape effect must carry the exact shape value from the C enum")
    }

    func test_unknownAction_producesNil() {
        // An action we don't handle (e.g. GHOSTTY_ACTION_QUIT from a future
        // Ghostty build) must produce nil so the dispatcher simply returns `true`
        // without crashing or dispatching garbage to the view.
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_QUIT
        XCTAssertNil(GhosttyActionMapper.map(action),
            "unhandled action tags must produce nil — never crash or produce a garbage effect")
    }

    // MARK: - GhosttyTerminalView.cursor(for:)

    func test_defaultShape_returnsNil() {
        // DEFAULT means the host cursor (arrow) should be restored. The caller
        // pops the cursor stack and must NOT push a new one — nil signals that.
        XCTAssertNil(GhosttyTerminalView.cursor(for: GHOSTTY_MOUSE_SHAPE_DEFAULT),
            "MOUSE_SHAPE_DEFAULT must return nil so the caller only pops, restoring the system cursor")
    }

    func test_pointerShape_returnsPointingHand() {
        // Web links in the terminal use the pointer shape; pointingHand is the
        // macOS convention that matches Safari/other apps.
        XCTAssertEqual(GhosttyTerminalView.cursor(for: GHOSTTY_MOUSE_SHAPE_POINTER), .pointingHand,
            "POINTER shape must map to NSCursor.pointingHand to match macOS link-hover convention")
    }

    func test_textShape_returnsIBeam() {
        // Text selection inside TUIs expects the I-beam; a wrong mapping (e.g.
        // arrow) makes text selection feel broken.
        XCTAssertEqual(GhosttyTerminalView.cursor(for: GHOSTTY_MOUSE_SHAPE_TEXT), .iBeam,
            "TEXT shape must map to NSCursor.iBeam for in-terminal text selection")
    }

    func test_crosshairShape_returnsCrosshair() {
        XCTAssertEqual(GhosttyTerminalView.cursor(for: GHOSTTY_MOUSE_SHAPE_CROSSHAIR), .crosshair,
            "CROSSHAIR shape must map to NSCursor.crosshair")
    }

    func test_notAllowedShape_returnsOperationNotAllowed() {
        XCTAssertEqual(GhosttyTerminalView.cursor(for: GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED), .operationNotAllowed,
            "NOT_ALLOWED shape must map to NSCursor.operationNotAllowed")
    }

    func test_copyShape_returnsDragCopy() {
        XCTAssertEqual(GhosttyTerminalView.cursor(for: GHOSTTY_MOUSE_SHAPE_COPY), .dragCopy,
            "COPY shape must map to NSCursor.dragCopy")
    }

    func test_ewResizeShape_returnsResizeLeftRight() {
        // EW resize is the horizontal resize handle; left-right cursor is correct.
        XCTAssertEqual(GhosttyTerminalView.cursor(for: GHOSTTY_MOUSE_SHAPE_EW_RESIZE), .resizeLeftRight,
            "EW_RESIZE shape must map to NSCursor.resizeLeftRight")
    }

    func test_nsResizeShape_returnsResizeUpDown() {
        XCTAssertEqual(GhosttyTerminalView.cursor(for: GHOSTTY_MOUSE_SHAPE_NS_RESIZE), .resizeUpDown,
            "NS_RESIZE shape must map to NSCursor.resizeUpDown")
    }
}
