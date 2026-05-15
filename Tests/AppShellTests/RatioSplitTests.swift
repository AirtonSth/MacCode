import XCTest
import AppKit
@testable import AppShell
@testable import CoreModel

@MainActor
final class RatioSplitTests: XCTestCase {
    func test_reducer_freshSplit_isFiftyFifty() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "w", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let b = SurfaceDescriptor(type: .terminal, title: "b")
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let pid = s.workspaces[wid]!.layout.paneIDs().first!
        s = try r.reduce(s, .splitPane(wid, paneID: pid, direction: .right, newSurface: b))
        guard case .split(let split) = s.workspaces[wid]!.layout else { return XCTFail() }
        XCTAssertEqual(split.ratios.count, 2)
        XCTAssertEqual(split.ratios[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(split.ratios[1], 0.5, accuracy: 0.0001)
    }

    func test_ratioSplitView_vertical_dividesWidthInHalf() {
        let sv = RatioSplitView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        sv.isVertical = true
        sv.ratios = [0.5, 0.5]
        let l = NSView(); let r = NSView()
        sv.addSubview(l)
        sv.addSubview(r)
        sv.adjustSubviews()
        let lw = sv.subviews[0].frame.width
        let rw = sv.subviews[1].frame.width
        XCTAssertEqual(lw, rw, accuracy: 1.0, "panes must be within 1pt of each other")
        XCTAssertEqual(lw + rw + sv.dividerThickness, 400, accuracy: 1.0)
        XCTAssertEqual(sv.subviews[0].frame.height, 200, accuracy: 0.5)
    }

    func test_ratioSplitView_horizontal_dividesHeightInHalf() {
        let sv = RatioSplitView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        sv.isVertical = false
        sv.ratios = [0.5, 0.5]
        let top = NSView(); let bottom = NSView()
        sv.addSubview(top)
        sv.addSubview(bottom)
        sv.adjustSubviews()
        let h0 = sv.subviews[0].frame.height
        let h1 = sv.subviews[1].frame.height
        XCTAssertEqual(h0, h1, accuracy: 1.0)
        XCTAssertEqual(h0 + h1 + sv.dividerThickness, 500, accuracy: 1.0)
        XCTAssertEqual(sv.subviews[0].frame.width, 300, accuracy: 0.5)
        XCTAssertGreaterThan(sv.subviews[0].frame.minY, sv.subviews[1].frame.minY,
                             "stacked splits must keep the first child visually above the second child")
    }

    func test_ratioSplitView_nestedHorizontalSplitRelayoutsChildren() {
        let outer = RatioSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        outer.isVertical = true
        outer.ratios = [0.5, 0.5]

        let left = NSView()
        let rightNested = RatioSplitView()
        rightNested.isVertical = false
        rightNested.ratios = [0.5, 0.5]
        let top = NSView()
        let bottom = NSView()
        rightNested.addSubview(top)
        rightNested.addSubview(bottom)

        outer.addSubview(left)
        outer.addSubview(rightNested)
        outer.adjustSubviews()

        XCTAssertEqual(top.frame.width, rightNested.bounds.width, accuracy: 0.5)
        XCTAssertEqual(bottom.frame.width, rightNested.bounds.width, accuracy: 0.5)
        XCTAssertEqual(top.frame.height, bottom.frame.height, accuracy: 1.0,
                       "a vertical/down split inside another split must stack panes, not leave stale side-by-side frames")
    }

    func test_ratioSplitView_relayoutsPaneSubviewConstraintsAfterFrameChange() {
        let sv = RatioSplitView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        sv.isVertical = true
        sv.ratios = [0.5, 0.5]

        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = true
        let surface = NSView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: pane.topAnchor),
            surface.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: pane.trailingAnchor)
        ])

        sv.addSubview(pane)
        sv.addSubview(NSView())
        sv.adjustSubviews()

        XCTAssertEqual(surface.frame.width, pane.bounds.width, accuracy: 0.5,
                       "pane content must relayout immediately after a split changes pane width, or terminal text can bleed into neighboring panes")
    }
}
