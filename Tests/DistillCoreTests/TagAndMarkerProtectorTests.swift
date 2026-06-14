import XCTest
@testable import DistillCore

final class TagAndMarkerProtectorTests: XCTestCase {
    func test_protectsAndRestoresXMLTagsAndRetrieveMarkers() {
        let input = "Keep <tool_call id=\"abc\">open</tool_call> and [[rc:deadbeef]] intact."
        let protected = TagAndMarkerProtector.protect(input)

        XCTAssertFalse(protected.text.contains("<tool_call"))
        XCTAssertFalse(protected.text.contains("[[rc:deadbeef]]"))

        let modelOutput = "Summary: \(protected.text)"
        XCTAssertEqual(
            protected.restore(in: modelOutput),
            "Summary: Keep <tool_call id=\"abc\">open</tool_call> and [[rc:deadbeef]] intact."
        )
    }

    func test_lossyRequestProtectionOnlyAppliesToProseModes() {
        let input = "Keep <note>exact</note> [[rc:cafebabe]]"

        let protectedLongText = MLXDistillRuntime.requestByProtectingTagsAndMarkers(
            DistillRequest(mode: .longText, input: input)
        )
        XCTAssertNotEqual(protectedLongText.request.input, input)
        XCTAssertEqual(protectedLongText.payload.restore(in: protectedLongText.request.input), input)

        let commandOutput = MLXDistillRuntime.requestByProtectingTagsAndMarkers(
            DistillRequest(mode: .commandOutput, input: input)
        )
        XCTAssertEqual(commandOutput.request.input, input)
        XCTAssertTrue(commandOutput.payload.isEmpty)
    }

    func test_lossyRequestProtectionPreservesRunMode() {
        let input = "Keep <note>exact</note> while simulating."
        let protected = MLXDistillRuntime.requestByProtectingTagsAndMarkers(
            DistillRequest(mode: .longText, input: input, runMode: .simulate)
        )

        XCTAssertEqual(protected.request.effectiveRunMode, .simulate,
                       "tag protection must not turn SIMULATE/AUDIT requests into optimize requests")
    }
}
