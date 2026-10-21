import Foundation
import XCTest
@testable import AgentRuntime

/// A Distill session is stored under the cwd of its first run. A resume from
/// another entry point must load it from that stored cwd, not the request cwd.
final class DistillSessionCwdTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DistillSessionCwdTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func test_findsCwdFromSummaryJSON_becauseSummaryIsTheAuthoritativeRecord() throws {
        let cwd = "/Users/sam/Library/Application Support/RemoteCode/bots/b1"
        let session = root.appendingPathComponent("opaque-group/s1", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["info": ["cwd": cwd]])
            .write(to: session.appendingPathComponent("summary.json"))

        XCTAssertEqual(DistillACPAdapter.storedSessionCwd(sessionsRoot: root, sessionId: "s1"), cwd)
    }

    func test_decodesPercentEncodedGroupName_whenSummaryIsMissing_becauseGroupNameEncodesCwd() throws {
        let session = root.appendingPathComponent(
            "%2FUsers%2Fsam%2Fdev%2Frepo/s2",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)

        XCTAssertEqual(
            DistillACPAdapter.storedSessionCwd(sessionsRoot: root, sessionId: "s2"),
            "/Users/sam/dev/repo"
        )
    }

    func test_returnsNil_whenSessionAbsent_becauseNoGuessIsSafe() throws {
        let other = root.appendingPathComponent("%2Ftmp/other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        XCTAssertNil(DistillACPAdapter.storedSessionCwd(sessionsRoot: root, sessionId: "missing"))
    }

    func test_rejectsTraversalSessionIds_becausePathMustStayUnderSessionsRoot() throws {
        let outside = root.appendingPathComponent("%2Ftmp/x", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)

        XCTAssertNil(DistillACPAdapter.storedSessionCwd(sessionsRoot: sessionsRoot, sessionId: "../x"))
        XCTAssertNil(DistillACPAdapter.storedSessionCwd(sessionsRoot: sessionsRoot, sessionId: "a/b"))
        XCTAssertNil(DistillACPAdapter.storedSessionCwd(sessionsRoot: sessionsRoot, sessionId: ""))
    }
}
