import XCTest
@testable import DistillCore

final class CommandOutputLossyRouterTests: XCTestCase {
    func test_stackTraceIsLossyCandidateAndCrushesWithHandle() {
        var stack = "Traceback (most recent call last):\n"
        for i in 0..<8 {
            stack += "  File \"app.py\", line \(i), in run\n    boom()\n"
        }
        // Duplicate frames so crusher can elide.
        let frame = "  File \"lib.py\", line 1, in helper\n"
        stack += String(repeating: frame, count: 5)
        stack += "RuntimeError: fail\n"

        XCTAssertTrue(CommandOutputLossyRouter.isLossyCandidate(stack))
        let crushed = CommandOutputLossyRouter.routeIfBeneficial(
            input: stack,
            handle: "test-handle-1"
        )
        XCTAssertNotNil(crushed)
        XCTAssertTrue(crushed!.output.contains("[[rc:test-handle-1]]") || crushed!.output.count < stack.count)
        XCTAssertLessThan(crushed!.output.utf8.count, stack.utf8.count)
    }

    func test_xctestTranscriptIsLossyCandidate() {
        var report = "Test Suite 'Selected tests' started at 2026-08-15 02:49:27.000.\n"
        for index in 1...12 {
            report += "Test Case '-[Suite test_\(index)]' started.\n"
            report += "Test Case '-[Suite test_\(index)]' passed (0.001 seconds).\n"
        }
        report += " Executed 12 tests, with 0 failures (0 unexpected) in 0.1 (0.1 seconds)\n"
        XCTAssertTrue(CommandOutputLossyRouter.isLossyCandidate(report))
        let crushed = CommandOutputLossyRouter.routeIfBeneficial(input: report, handle: "xc-h")
        XCTAssertNotNil(crushed)
        XCTAssertTrue(crushed!.output.contains("[[rc:xc-h]]"))
        XCTAssertTrue(crushed!.output.contains("Executed 12 tests, with 0 failures"))
        XCTAssertLessThan(crushed!.output.utf8.count, report.utf8.count)
    }

    func test_spmBuildProgressIsLossyCandidate() {
        var report = "Building for debugging...\n"
        for index in 1...12 {
            report += "[\(index)/12] Compiling Module File\(index).swift\n"
        }
        report += "Build complete! (2.0s)\n"
        XCTAssertTrue(CommandOutputLossyRouter.isLossyCandidate(report))
        let crushed = CommandOutputLossyRouter.routeIfBeneficial(input: report, handle: "bld-h")
        XCTAssertNotNil(crushed)
        XCTAssertTrue(crushed!.output.contains("[[rc:bld-h]]"))
        XCTAssertTrue(crushed!.output.contains("Build complete!"))
        XCTAssertLessThan(crushed!.output.utf8.count, report.utf8.count)
    }

    func test_smallProseIsNotLossyCandidate() {
        XCTAssertFalse(CommandOutputLossyRouter.isLossyCandidate("hello world\n"))
        XCTAssertNil(CommandOutputLossyRouter.routeIfBeneficial(
            input: "hello world\n",
            handle: "h"
        ))
    }

    func test_imageGuardDetectsBase64JPEG() {
        let blob = String(repeating: "/9j/4AAQ", count: 20)
        XCTAssertTrue(ToolOutputMultimodalGuard.looksLikeImagePayload(blob))
        XCTAssertFalse(ToolOutputMultimodalGuard.looksLikeImagePayload("short"))
    }
}
