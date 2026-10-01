import XCTest
@testable import AgentRuntime

final class CodexDuplicateQuestionIDTests: XCTestCase {
    func test_duplicateQuestionIDsDoNotTrap_becauseProviderPayloadsAreUntrusted() {
        // WHY: Dictionary(uniqueKeysWithValues:) traps on a repeated provider question
        // id, killing the whole app while answering a user-input request.
        let single = CodexAppServerAdapter.codexAnswers(questionIds: ["q1", "q1"], text: "yes")
        XCTAssertEqual(single, ["q1": ["answers": ["yes"]]])

        let zipped = CodexAppServerAdapter.codexAnswers(questionIds: ["q1", "q1"], text: "first\nsecond")
        XCTAssertEqual(zipped["q1"]?["answers"], ["first"], "first answer wins for a repeated id")
        XCTAssertEqual(zipped.count, 1)
    }
}
