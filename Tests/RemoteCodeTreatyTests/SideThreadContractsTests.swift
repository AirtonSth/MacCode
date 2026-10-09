import XCTest
@testable import RemoteCodeTreaty

/// Side/fork treaty contract shapes shared with iOS (`/tmp/side-host-rpc.md`).
final class SideThreadContractsTests: XCTestCase {
    private let decoder = JSONDecoder()

    func test_methodsMatchTheDocumentedNames() {
        XCTAssertEqual(AgentThreadFork.method, "agent.thread.fork")
        XCTAssertEqual(AgentThreadSide.method, "agent.thread.side")
        XCTAssertEqual(AgentThreadSideClose.method, "agent.thread.side.close")
        XCTAssertEqual(AgentThreadBtw.method, "agent.thread.btw")
    }

    func test_forkAndSideParams_decodeSnakeCaseThreadID() throws {
        let fork = try decoder.decode(AgentThreadFork.Params.self, from: Data(#"{"thread_id":"t-1"}"#.utf8))
        XCTAssertEqual(fork.threadID, "t-1")
        XCTAssertNil(fork.messageID)

        let side = try decoder.decode(AgentThreadSide.Params.self, from: Data(#"{"thread_id":"t-1","text":"hi"}"#.utf8))
        XCTAssertEqual(side.text, "hi")

        let close = try decoder.decode(AgentThreadSideClose.Params.self, from: Data(#"{"thread_id":"s-1"}"#.utf8))
        XCTAssertEqual(close.threadID, "s-1")

        let btw = try decoder.decode(AgentThreadBtw.Params.self, from: Data(#"{"thread_id":"t-1","question":"why?"}"#.utf8))
        XCTAssertEqual(btw.question, "why?")
        XCTAssertEqual(try decoder.decode(AgentThreadBtw.Result.self, from: Data(#"{"answer":"because"}"#.utf8)).answer, "because")
    }
}
