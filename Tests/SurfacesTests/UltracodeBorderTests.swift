import XCTest
import SwiftUI
import CoreModel
@testable import Surfaces

@MainActor
final class UltracodeBorderTests: XCTestCase {
    func test_ultracodeBorder_showsOnlyForDistillWithUltracodeOn() {
        XCTAssertTrue(AgentUltracodeBorderPresentation.shows(provider: .distill, ultracode: true))
        XCTAssertFalse(AgentUltracodeBorderPresentation.shows(provider: .distill, ultracode: false))
        XCTAssertFalse(AgentUltracodeBorderPresentation.shows(provider: .claude, ultracode: true))
    }

    func test_ultracodeBorder_reduceMotionStopsAnimation() {
        XCTAssertFalse(AgentUltracodeBorderPresentation.isAnimated(reduceMotion: true))
        XCTAssertTrue(AgentUltracodeBorderPresentation.isAnimated(reduceMotion: false))
        XCTAssertEqual(AgentUltracodeBorderPresentation.lapSeconds, 4)
    }

    /// WHY: the 30 Hz rotation (gradient + blurred glow rebuilt every tick) only
    /// earns its cost where someone sees it. A non-key window or a hidden
    /// composer must hold still; Reduce Motion still wins everywhere.
    func test_ultracodeBorder_ticksOnlyInKeyWindowWhileOnScreen() {
        XCTAssertTrue(AgentUltracodeBorderPresentation.isTicking(reduceMotion: false, windowIsKey: true, onScreen: true))
        XCTAssertFalse(AgentUltracodeBorderPresentation.isTicking(reduceMotion: false, windowIsKey: false, onScreen: true))
        XCTAssertFalse(AgentUltracodeBorderPresentation.isTicking(reduceMotion: false, windowIsKey: true, onScreen: false))
        XCTAssertFalse(AgentUltracodeBorderPresentation.isTicking(reduceMotion: true, windowIsKey: true, onScreen: true))
    }

    /// Gradient frames built over `seconds` for a mounted border.
    /// `state` nil leaves the control state to the real (never key) test window.
    private func borderFrames(state: ControlActiveState?, hideHost: Bool = false, seconds: TimeInterval = 0.5) -> Int {
        let border = RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(.black)
            .frame(width: 420, height: 90)
            .modifier(UltracodeBorder(active: true))
            .padding(24)
        let view = Group {
            if let state { border.environment(\.controlActiveState, state) } else { border }
        }
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 500, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        if hideHost {
            // How cached Agent App tabs are parked: hidden, still in the window.
            host.isHidden = true
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        let start = UltracodeBorder.frameCountForTesting
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        let frames = UltracodeBorder.frameCountForTesting - start
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        return frames
    }

    /// WHY: measured before this change at ~30 frames/s in every case below —
    /// the TimelineView ignored key state and kept ticking inside hidden hosts.
    func test_ultracodeBorder_holdsStillWhenWindowNotKeyOrHostHidden() {
        let key = borderFrames(state: .key)
        XCTAssertGreaterThanOrEqual(key, 5, "a key, visible composer must keep rotating (the look stays)")
        XCTAssertLessThanOrEqual(borderFrames(state: nil), 1, "real non-key window: no per-frame rebuilds")
        XCTAssertLessThanOrEqual(borderFrames(state: .inactive), 1, "not key / app in background: no per-frame rebuilds")
        XCTAssertLessThanOrEqual(borderFrames(state: .key, hideHost: true), 1, "hidden tab host: no per-frame rebuilds")
    }

    /// WHY: tabs are parked by hiding an AppKit ancestor and shown again by
    /// unhiding it. Pausing there must not freeze the border for good: once the
    /// tab is back on screen in the key window, the rotation resumes.
    func test_ultracodeBorder_resumesWhenHiddenAncestorIsShownAgain() {
        let view = RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(.black)
            .frame(width: 420, height: 90)
            .modifier(UltracodeBorder(active: true))
            .padding(24)
            .environment(\.controlActiveState, .key)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 500, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let tab = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 180))
        let host = NSHostingView(rootView: view)
        host.frame = tab.bounds
        tab.addSubview(host)
        window.contentView = tab
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }

        func frames(after change: () -> Void) -> Int {
            change()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let start = UltracodeBorder.frameCountForTesting
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            return UltracodeBorder.frameCountForTesting - start
        }
        XCTAssertGreaterThanOrEqual(frames(after: {}), 5, "precondition: visible in a key window rotates")
        XCTAssertLessThanOrEqual(frames(after: { tab.isHidden = true }), 1, "parked tab holds still")
        XCTAssertGreaterThanOrEqual(frames(after: { tab.isHidden = false }), 5, "shown again: rotation resumes")
        XCTAssertLessThanOrEqual(frames(after: { host.removeFromSuperview() }), 1, "detached host holds still")
        XCTAssertGreaterThanOrEqual(frames(after: { tab.addSubview(host) }), 5, "re-attached host rotates again")
    }

    /// Render evidence; writes PNGs only when ULTRACODE_RENDER_DIR is set.
    func test_ultracodeBorder_rendersPNGs() throws {
        guard let dir = ProcessInfo.processInfo.environment["ULTRACODE_RENDER_DIR"] else {
            throw XCTSkip("ULTRACODE_RENDER_DIR not set")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for angle in [0.0, 120.0] {
            let view = RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.black)
                .frame(width: 420, height: 90)
                .modifier(UltracodeBorder(active: true, angleOverride: angle))
                .padding(24)
                .background(Color(red: 0.06, green: 0.08, blue: 0.1))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("ultracode-border-\(Int(angle)).png"))
        }
    }
}
