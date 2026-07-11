import XCTest
@testable import CoreModel

/// UX-MAC_AGENT-OPEN-SPLIT: "open in the split panel to the right" reuses the
/// pane the user visually sees next to the agent surface. These tests pin the
/// neighbor lookup to visual order (horizontal children are laid left→right in
/// array order) so reuse never targets a pane on the wrong side.
final class SplitTreeRightNeighborTests: XCTestCase {
    private func pane(_ id: PaneID = PaneID()) -> PaneNode { PaneNode(id: id) }

    func test_lonePane_hasNoRightNeighbor() {
        let p = pane()
        XCTAssertNil(LayoutNode.pane(p).rightNeighborPane(of: p.id),
                     "a single pane must create a split instead of reusing a neighbor")
    }

    func test_horizontalSplit_returnsRightSibling() {
        let left = pane(), right = pane()
        let tree = LayoutNode.split(SplitNode(orientation: .horizontal, children: [.pane(left), .pane(right)]))
        XCTAssertEqual(tree.rightNeighborPane(of: left.id)?.id, right.id)
        XCTAssertNil(tree.rightNeighborPane(of: right.id),
                     "the right-most pane has no neighbor — a new split must be created")
    }

    func test_verticalSplit_hasNoRightNeighbor() {
        let top = pane(), bottom = pane()
        let tree = LayoutNode.split(SplitNode(orientation: .vertical, children: [.pane(top), .pane(bottom)]))
        XCTAssertNil(tree.rightNeighborPane(of: top.id),
                     "a pane below is not 'to the right' — vertical stacks must not be reused")
    }

    func test_rightSiblingSubtree_resolvesToItsLeftmostPane() {
        // [agent | (top / bottom)] — the visually adjacent pane is the subtree's
        // first (top-left) pane, not an arbitrary leaf.
        let agent = pane(), top = pane(), bottom = pane()
        let rightColumn = LayoutNode.split(SplitNode(orientation: .vertical, children: [.pane(top), .pane(bottom)]))
        let tree = LayoutNode.split(SplitNode(orientation: .horizontal, children: [.pane(agent), rightColumn]))
        XCTAssertEqual(tree.rightNeighborPane(of: agent.id)?.id, top.id)
    }

    func test_nestedPane_climbsToNearestHorizontalAncestorWithRightSibling() {
        // ((a | b) | c): b is right-most in its own split, so its neighbor comes
        // from the outer split — c.
        let a = pane(), b = pane(), c = pane()
        let inner = LayoutNode.split(SplitNode(orientation: .horizontal, children: [.pane(a), .pane(b)]))
        let tree = LayoutNode.split(SplitNode(orientation: .horizontal, children: [inner, .pane(c)]))
        XCTAssertEqual(tree.rightNeighborPane(of: b.id)?.id, c.id)
        XCTAssertEqual(tree.rightNeighborPane(of: a.id)?.id, b.id,
                       "the NEAREST horizontal ancestor decides — a's neighbor is b, not c")
        XCTAssertNil(tree.rightNeighborPane(of: c.id))
    }

    func test_paneInsideVerticalStack_usesEnclosingHorizontalSplit() {
        // [(top / agent) | right]: the agent sits in a vertical stack; its visual
        // right neighbor is still the horizontal sibling.
        let top = pane(), agent = pane(), right = pane()
        let leftColumn = LayoutNode.split(SplitNode(orientation: .vertical, children: [.pane(top), .pane(agent)]))
        let tree = LayoutNode.split(SplitNode(orientation: .horizontal, children: [leftColumn, .pane(right)]))
        XCTAssertEqual(tree.rightNeighborPane(of: agent.id)?.id, right.id)
    }

    func test_unknownPane_returnsNil() {
        let a = pane(), b = pane()
        let tree = LayoutNode.split(SplitNode(orientation: .horizontal, children: [.pane(a), .pane(b)]))
        XCTAssertNil(tree.rightNeighborPane(of: PaneID()))
    }
}
