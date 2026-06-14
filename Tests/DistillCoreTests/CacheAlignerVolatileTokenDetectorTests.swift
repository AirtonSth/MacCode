import XCTest
@testable import DistillCore

final class CacheAlignerVolatileTokenDetectorTests: XCTestCase {
    func test_detectsVolatileTokensWithoutMutatingInput() {
        let input = """
        request 7f8d2d3e-1234-4cde-8f90-abcdefabcdef at 2026-06-13T21:00:01Z
        token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.signature
        digest 0123456789abcdef0123456789abcdef
        """

        let scan = CacheAlignerVolatileTokenDetector.scan(input)

        XCTAssertEqual(scan.uuidCount, 1)
        XCTAssertEqual(scan.iso8601Count, 1)
        XCTAssertEqual(scan.jwtCount, 1)
        XCTAssertEqual(scan.hexCount, 1)
        XCTAssertEqual(scan.warningCount, 4)
    }

    func test_systemPromptHashIsStableAndChangesWithPromptContract() {
        let base = DistillRequest(
            mode: .commandOutput,
            input: "payload",
            question: "Did it pass?",
            cacheState: "tool_output_oneshot",
            maxOutputCharacters: 512
        )
        let sameContractDifferentPayload = DistillRequest(
            mode: .commandOutput,
            input: "different payload",
            question: "Did it pass?",
            cacheState: "tool_output_oneshot",
            maxOutputCharacters: 512
        )
        let changedQuestion = DistillRequest(
            mode: .commandOutput,
            input: "payload",
            question: "Did it fail?",
            cacheState: "tool_output_oneshot",
            maxOutputCharacters: 512
        )

        XCTAssertEqual(
            CacheAlignerPromptContract.systemPromptHash(for: base),
            CacheAlignerPromptContract.systemPromptHash(for: sameContractDifferentPayload),
            "cache-drift telemetry hashes the prompt contract, not volatile payload content"
        )
        XCTAssertNotEqual(
            CacheAlignerPromptContract.systemPromptHash(for: base),
            CacheAlignerPromptContract.systemPromptHash(for: changedQuestion),
            "a changed prompt contract must produce a new system_prompt_hash"
        )
    }
}
