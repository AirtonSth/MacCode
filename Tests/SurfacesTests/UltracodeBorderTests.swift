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
