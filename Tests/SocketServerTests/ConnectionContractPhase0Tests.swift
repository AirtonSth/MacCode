import XCTest
@testable import SocketServer

final class ConnectionContractPhase0Tests: XCTestCase {
    func test_sharedContractFixtures_decodeTypedWelcomeHeartbeatClosingAndEvent() throws {
        for name in ["welcome", "heartbeat", "closing", "event"] {
            let data = try Data(contentsOf: fixtureRoot
                .appendingPathComponent("transport/\(name).json"))
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        }
        XCTFail("Phase 2 RED: strict typed ConnectionTransportFrame decoding is not implemented")
    }

    func test_allSharedTransportAndJSONRPCFixtures_decodeAsJSON() throws {
        for category in ["transport", "jsonrpc"] {
            let directory = fixtureRoot.appendingPathComponent(category)
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
            XCTAssertFalse(files.isEmpty, "\(category) fixture category must not be empty")
            for file in files {
                let data = try Data(contentsOf: file)
                XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data),
                                 "\(category)/\(file.lastPathComponent) must decode as JSON")
            }
        }
    }

    func test_localCopies_areByteIdenticalToCanonicalRoot_whenAvailable() throws {
        guard let root = ProcessInfo.processInfo.environment["REMOTE_CODE_ROOT"] else {
            throw XCTSkip("REMOTE_CODE_ROOT not set; canonical wrapper fixtures are unavailable")
        }
        let canonicalRoot = URL(fileURLWithPath: root)
            .appendingPathComponent("tests/connection-contract-v3/fixtures")
        guard FileManager.default.fileExists(atPath: canonicalRoot.path) else {
            throw XCTSkip("canonical wrapper fixtures are unavailable")
        }

        for category in ["transport", "jsonrpc"] {
            let localDirectory = fixtureRoot.appendingPathComponent(category)
            let files = try FileManager.default.contentsOfDirectory(
                at: localDirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
            for local in files {
                let canonical = canonicalRoot
                    .appendingPathComponent(category)
                    .appendingPathComponent(local.lastPathComponent)
                XCTAssertEqual(try Data(contentsOf: local), try Data(contentsOf: canonical),
                               "\(category)/\(local.lastPathComponent) drifted from the canonical contract fixture")
            }
        }
    }

    func test_CONN003_contiguousSequence_appliesExactlyOnce() {
        XCTFail("Phase 2 RED: contiguous sequence must apply once and duplicate sequence must be ignored")
    }

    func test_CONN005_sequenceGap_requestsReplayWithoutApplyingMutation() {
        XCTFail("Phase 2 RED: gap after 1042 must request replay from sequence 1043")
    }

    func test_CONN006_bootEpochChange_invalidatesCursorAndRequiresBaseline() {
        XCTFail("Phase 2 RED: boot epoch change must invalidate the cursor and require a baseline")
    }

    func test_CONN009_heartbeatTimeout_marksConnectionStaleAtDeadline() {
        XCTFail("Phase 2 RED: heartbeat must expire exactly at lastHeartbeat + timeout")
    }

    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/connection-contract-v3")
    }
}
