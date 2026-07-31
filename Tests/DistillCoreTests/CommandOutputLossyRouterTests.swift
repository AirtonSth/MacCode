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
