import XCTest
@testable import CoreModel

final class DistillMCPAdmitTests: XCTestCase {
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
