import XCTest
import SwiftUI
import AppKit
import CoreModel
import DesignSystemKit
@testable import Surfaces

/// The strip must tell the user, in plain words, when a loop fires next and what state it is in.
final class DistillLoopStripTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func loop(
        _ id: String = "t1", next: TimeInterval? = 125, iterations: Int = 3,
        running: String? = nil, state: DistillLoopStatus = .active, reason: String? = nil
    ) -> DistillLoopState {
        DistillLoopState(
            taskID: id, prompt: "check the deploy", humanSchedule: "every 5 minutes",
            nextFireAt: next.map { now.addingTimeInterval($0) }, iterations: iterations,
            lastIteration: DistillLoopIteration(
                subagentID: "s1", status: .completed, durationMs: 4200, tokensUsed: 1234,
                outputPreview: "Deploy healthy."),
            runningSubagentID: running, state: state, pausedReason: reason)
    }

    func testCountdownFormatsMinutesSecondsAndDueNow() {
        XCTAssertEqual(DistillLoopPresentation.countdownText(nextFireAt: now.addingTimeInterval(125), now: now), "next in 2m 05s")
        XCTAssertEqual(DistillLoopPresentation.countdownText(nextFireAt: now.addingTimeInterval(9), now: now), "next in 9s")
        XCTAssertEqual(DistillLoopPresentation.countdownText(nextFireAt: now, now: now), "due now")
        XCTAssertEqual(DistillLoopPresentation.countdownText(nextFireAt: now.addingTimeInterval(-30), now: now), "due now")
        XCTAssertNil(DistillLoopPresentation.countdownText(nextFireAt: nil, now: now))
    }

    func testTitleRunsAndRunningText() {
        let l = loop(running: "s2")
        XCTAssertEqual(DistillLoopPresentation.title(l), "Loop · every 5 minutes")
        XCTAssertEqual(DistillLoopPresentation.runsText(l), "3 runs")
        XCTAssertEqual(DistillLoopPresentation.runsText(loop(iterations: 1)), "1 run")
        XCTAssertNil(DistillLoopPresentation.runsText(loop(iterations: 0)))
        XCTAssertEqual(DistillLoopPresentation.runningText(l), "Running iteration 4")
        XCTAssertNil(DistillLoopPresentation.runningText(loop()))
    }

    func testAccessibilityLabelMatchesContractAndStates() {
        XCTAssertEqual(
            DistillLoopPresentation.accessibilityLabel(loop(), now: now),
            "Loop every 5 minutes, next run in 2 minutes, 3 runs")
        XCTAssertEqual(
            DistillLoopPresentation.accessibilityLabel(loop(state: .paused, reason: "Offline"), now: now),
            "Loop every 5 minutes, Paused · Offline, 3 runs")
        XCTAssertEqual(
            DistillLoopPresentation.accessibilityLabel(loop(next: 0), now: now),
            "Loop every 5 minutes, next run due now, 3 runs")
    }

    func testStackCapsAtThreeWithMoreCount() {
        let loops = (0..<5).map { loop("t\($0)") }
        let shown = DistillLoopPresentation.visible(loops)
        XCTAssertEqual(shown.rows.map(\.taskID), ["t0", "t1", "t2"])
        XCTAssertEqual(shown.hidden, 2)
        XCTAssertEqual(DistillLoopPresentation.visible(Array(loops.prefix(2))).hidden, 0)
    }

    func testSidebarLabelOnlyForActiveLoops() {
        XCTAssertEqual(DistillLoopPresentation.sidebarAccessibilityLabel([loop()]), "Loop active, every 5 minutes")
        XCTAssertNil(DistillLoopPresentation.sidebarAccessibilityLabel([loop(state: .paused), loop("t2", state: .expired)]))
        XCTAssertNil(DistillLoopPresentation.sidebarAccessibilityLabel([]))
    }

    func testIterationSummary() {
        XCTAssertEqual(
            DistillLoopPresentation.iterationSummary(loop().lastIteration!),
            "Completed · 4.2s · 1234 tokens")
    }

    /// Renders the four review states to /tmp for visual review (dark appearance).
    @MainActor
    func testRendersReviewSnapshots() throws {
        let states: [(String, [DistillLoopState])] = [
            ("active", [loop(next: 125)]),
            ("running", [loop(running: "s2")]),
            ("paused", [loop(next: nil, state: .paused, reason: "Waiting for the agent session to resume")]),
            ("expired", [loop(next: nil, state: .expired)]),
        ]
        for (name, loops) in states {
            let view = DistillLoopStrip(loops: loops, onStop: { _ in }, onDismissExpired: { _ in }, onResume: { _ in })
                .frame(width: 640)
                .padding(.vertical, DS.Space.md)
                .background(DS.Palette.bg)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage, name)
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/loop-strip-\(name).png"))
        }
    }
}
