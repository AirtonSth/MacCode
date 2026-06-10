import XCTest
@testable import AppShell
@testable import CoreModel

/// Tests for the pure undo-stack helpers and the selection-highlight resolver
/// introduced for P3 (Remove-Workspace undo + color-aware selection highlight).
///
/// All helpers under test are nonisolated/pure — no @MainActor annotation needed.
final class WorkspaceUndoStackTests: XCTestCase {

    // MARK: WorkspaceUndoStack.push

    func test_push_appendsEntryToStack() {
        // WHY: remove must push a restorable entry; a subsequent pop must return it.
        let entry = WorkspaceUndoEntry(name: "MyWS", cwd: "/home/user", metadata: ["color": "blue"])
        let stack = WorkspaceUndoStack.push(entry, onto: [])
        XCTAssertEqual(stack.count, 1, "push onto empty stack must produce a 1-element stack")
        XCTAssertEqual(stack.last, entry, "pushed entry must be the last element")
    }

    func test_push_preservesOrder_newestAtEnd() {
        // WHY: pop must return entries in LIFO order; newest-at-end encodes that contract.
        let e1 = WorkspaceUndoEntry(name: "A", cwd: "/a", metadata: [:])
        let e2 = WorkspaceUndoEntry(name: "B", cwd: "/b", metadata: [:])
        let s1 = WorkspaceUndoStack.push(e1, onto: [])
        let s2 = WorkspaceUndoStack.push(e2, onto: s1)
        XCTAssertEqual(s2.last?.name, "B", "second push must be at end (newest)")
        XCTAssertEqual(s2.first?.name, "A", "first push must be at front (oldest)")
    }

    func test_push_dropsOldestWhenExceedingMaxDepth() {
        // WHY: cap prevents unbounded memory growth during a long session.
        var stack: [WorkspaceUndoEntry] = []
        for i in 0..<12 {
            let e = WorkspaceUndoEntry(name: "ws\(i)", cwd: "/", metadata: [:])
            stack = WorkspaceUndoStack.push(e, onto: stack, maxDepth: 10)
        }
        XCTAssertEqual(stack.count, 10, "stack must be capped at maxDepth=10 entries")
        XCTAssertEqual(stack.first?.name, "ws2", "oldest entries (ws0, ws1) must be evicted first")
        XCTAssertEqual(stack.last?.name, "ws11", "newest entry must remain at end")
    }

    // MARK: WorkspaceUndoStack.pop

    func test_pop_returnsLastEntryAndShrinkStack() {
        // WHY: undo must pop the most-recently-removed workspace (LIFO).
        let e1 = WorkspaceUndoEntry(name: "A", cwd: "/a", metadata: [:])
        let e2 = WorkspaceUndoEntry(name: "B", cwd: "/b", metadata: [:])
        let stack = [e1, e2]
        let result = WorkspaceUndoStack.pop(from: stack)
        XCTAssertNotNil(result, "pop on non-empty stack must return a result")
        XCTAssertEqual(result!.entry, e2, "pop must return the last (most recent) entry")
        XCTAssertEqual(result!.remaining.count, 1, "remaining stack must have one fewer entry")
        XCTAssertEqual(result!.remaining.first, e1, "older entry must remain in stack")
    }

    func test_pop_returnsNilForEmptyStack() {
        // WHY: canUndoRemoveWorkspace guard relies on pop returning nil when there is nothing to undo.
        let result = WorkspaceUndoStack.pop(from: [])
        XCTAssertNil(result, "pop on empty stack must return nil (nothing to undo)")
    }

    func test_pushThenPop_roundtrip() {
        // WHY: the full remove->undo cycle must reproduce the exact workspace snapshot.
        let original = WorkspaceUndoEntry(
            name: "Production",
            cwd: "/srv/app",
            metadata: ["color": "red", "pinned": "true", "description": "live env"]
        )
        let pushed = WorkspaceUndoStack.push(original, onto: [])
        let popped = WorkspaceUndoStack.pop(from: pushed)
        XCTAssertNotNil(popped)
        XCTAssertEqual(popped!.entry.name, original.name, "name must survive round-trip")
        XCTAssertEqual(popped!.entry.cwd, original.cwd, "cwd must survive round-trip")
        XCTAssertEqual(popped!.entry.metadata, original.metadata, "metadata must survive round-trip")
        XCTAssertTrue(popped!.remaining.isEmpty, "stack must be empty after popping the only entry")
    }

    // MARK: SidebarSelectionHighlightResolver

    func test_resolver_noSelection_returnsNone() {
        // WHY: unselected rows must not show any highlight tint.
        let tone = SidebarSelectionHighlightResolver().resolve(colorKey: nil, isSelected: false, isChecked: false)
        XCTAssertEqual(tone, .none, "unselected, unchecked row must resolve to .none")
    }

    func test_resolver_selectedWithNoColor_returnsSelection() {
        // WHY: selected row with no workspace color must fall back to the generic selection tone.
        let tone = SidebarSelectionHighlightResolver().resolve(colorKey: nil, isSelected: true, isChecked: false)
        XCTAssertEqual(tone, .selection, "selected row without color must resolve to .selection")
    }

    func test_resolver_selectedWithColor_returnsWorkspaceColor() {
        // WHY: when the workspace has a color, the selection highlight must adopt it
        //      so the left-edge bar and row tint reflect the workspace identity.
        let tone = SidebarSelectionHighlightResolver().resolve(colorKey: "blue", isSelected: true, isChecked: false)
        XCTAssertEqual(tone, .workspaceColor(TabColor.blue.hex),
                       "selected row with color=blue must resolve to .workspaceColor with the blue hex swatch")
    }

    func test_resolver_selectedWithUnknownColor_fallsBackToSelection() {
        // WHY: an unknown/empty color key must not crash and must behave like no-color.
        let tone = SidebarSelectionHighlightResolver().resolve(colorKey: "neon", isSelected: true, isChecked: false)
        XCTAssertEqual(tone, .selection,
                       "selected row with an unrecognised color key must fall back to .selection, not crash")
    }

    func test_resolver_checkedTakesPriorityOverColor() {
        // WHY: multi-select (checked) uses accent tint regardless of workspace color
        //      to signal batch-selection visually distinct from single-select.
        let tone = SidebarSelectionHighlightResolver().resolve(colorKey: "green", isSelected: true, isChecked: true)
        XCTAssertEqual(tone, .accent,
                       "checked (multi-select) row must resolve to .accent even when a workspace color is set")
    }

    func test_resolver_allKnownColorsReturnWorkspaceColor() {
        // WHY: every TabColor swatch must round-trip through the resolver without falling to .selection.
        for color in TabColor.allCases {
            let tone = SidebarSelectionHighlightResolver().resolve(colorKey: color.rawValue, isSelected: true, isChecked: false)
            XCTAssertEqual(tone, .workspaceColor(color.hex),
                           "TabColor.\(color.rawValue) must resolve to .workspaceColor(\(color.hex))")
        }
    }

    func test_resolver_emptyColorKey_fallsBackToSelection() {
        // WHY: metadata["color"] defaults to "" (no color); must not produce a workspace-color tone.
        let tone = SidebarSelectionHighlightResolver().resolve(colorKey: "", isSelected: true, isChecked: false)
        XCTAssertEqual(tone, .selection,
                       "empty color key must fall back to .selection, consistent with TabColor.from(nil)==nil")
    }
}
