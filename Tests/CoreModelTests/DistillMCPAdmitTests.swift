import XCTest
@testable import CoreModel

final class DistillMCPAdmitTests: XCTestCase {
    func test_claudeServerCarriesCommandArgsAndOnlyRecoveryEnvKeys() {
        let server = DistillMCPAdmit.claudeServer(
            command: "/tmp/RemoteCodeDistillService",
            environment: [
                "RC_TOKEN_SAVER_THREAD_ID": "t-1",
                "UNRELATED_SECRET": "nope",
            ]
        )
        XCTAssertEqual(server["command"] as? String, "/tmp/RemoteCodeDistillService")
        XCTAssertEqual(server["args"] as? [String], ["mcp"])
        let env = server["env"] as? [String: String]
        XCTAssertEqual(env, ["RC_TOKEN_SAVER_THREAD_ID": "t-1"],
                       "only recovery-scope keys may be forwarded; unrelated environment must stay out")

        let bare = DistillMCPAdmit.claudeServer(command: "/tmp/RemoteCodeDistillService")
        XCTAssertNil(bare["env"], "no recovery keys → no env block at all")
    }

    func test_claudeAutomaticallyAllowedToolsUseServerScopedNames() {
        XCTAssertEqual(
            Set(DistillMCPAdmit.claudeAutomaticallyAllowedTools),
            Set(DistillMCPAdmit.toolNames.map { "mcp__remotecode-distill__\($0)" }),
            "Claude permission names must be scoped to the admitted server name"
        )
    }

    func test_admitGrokACPInsertsRemotecodeDistill() {
        let admitted = DistillMCPAdmit.admitGrokACP(
            existing: [["name": "other"]],
            command: "/tmp/RemoteCodeDistillService"
        )
        XCTAssertTrue(DistillMCPAdmit.containsAdmittedGrokACP(admitted))
        XCTAssertEqual(admitted.count, 2)
        let distill = admitted.compactMap { $0 as? [String: Any] }.first { $0["name"] as? String == DistillMCPAdmit.serverName }
        XCTAssertEqual(distill?["command"] as? String, "/tmp/RemoteCodeDistillService")
        let args = distill?["args"] as? [String]
        XCTAssertEqual(args, ["mcp"])
    }
}
