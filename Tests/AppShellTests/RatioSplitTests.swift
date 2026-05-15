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
        sv.addArrangedSubview(l)
        sv.addArrangedSubview(r)
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
        sv.addArrangedSubview(top)
        sv.addArrangedSubview(bottom)
        sv.adjustSubviews()
        let h0 = sv.subviews[0].frame.height
        let h1 = sv.subviews[1].frame.height
        XCTAssertEqual(h0, h1, accuracy: 1.0)
        XCTAssertEqual(h0 + h1 + sv.dividerThickness, 500, accuracy: 1.0)
        XCTAssertEqual(sv.subviews[0].frame.width, 300, accuracy: 0.5)
    }
}
