import XCTest
@testable import SocketServer

final class ConnectionContractPhase0Tests: XCTestCase {
    func test_sharedContractFixtures_decodeAllStrictTypedFrames() throws {
        let names = [
            "welcome", "heartbeat", "closing", "error", "event",
            "baselineRequired", "snapshot",
        ]
        for name in names {
            let frame = try ConnectionTransportFrame.decodeStrict(try fixtureData(name))
            switch (name, frame) {
            case ("welcome", .welcome), ("heartbeat", .heartbeat),
                 ("closing", .closing), ("error", .error),
                 ("event", .event), ("baselineRequired", .baselineRequired),
                 ("snapshot", .snapshot):
                break
            default:
                XCTFail("\(name) decoded as the wrong typed transport frame")
            }
        }
    }

    func test_strictTransportRequiresExactKeysAndProtocolVersion() throws {
        try assertRejected("welcome", expected: .unknownFields) { $0["extra"] = true }
        try assertRejected("welcome", expected: .unknownFields) { $0.removeValue(forKey: "hostId") }
        try assertRejected("welcome", expected: .unsupportedVersion) { $0["protocolVersion"] = 2 }
        try assertRejected("welcome", expected: .unsupportedVersion) { $0["protocolVersion"] = 3.5 }
        try assertRejected("welcome", expected: .unsupportedVersion) { $0["protocolVersion"] = true }
        try assertRejected("welcome") { $0["bootEpoch"] = -1 }

        var zeroBoot = try fixtureObject("welcome")
        zeroBoot["bootEpoch"] = 0
        XCTAssertNoThrow(try ConnectionTransportFrame.decodeStrict(try jsonData(zeroBoot)),
                         "boot epoch zero is canonical for pre-first-boot fixtures")

        var unknownType = try fixtureObject("welcome")
        unknownType["type"] = "future"
        XCTAssertThrowsError(try ConnectionTransportFrame.decodeStrict(try jsonData(unknownType))) {
            XCTAssertEqual($0 as? ConnectionProtocolFailure, .unknownType)
        }
        XCTAssertThrowsError(try ConnectionTransportFrame.decodeStrict(Data("{".utf8))) {
            XCTAssertEqual($0 as? ConnectionProtocolFailure, .malformedJSON)
        }
        XCTAssertThrowsError(try ConnectionTransportFrame.decodeStrict(
            Data(repeating: 0x20, count: ConnectionTransportFrame.maximumEncodedBytes + 1)
        )) {
            XCTAssertEqual($0 as? ConnectionProtocolFailure, .frameTooLarge)
        }
    }

    func test_strictTransportRejectsEveryFrameSemanticInvariant() throws {
        try assertRejected("welcome") { $0["connectionId"] = " " }
        try assertRejected("welcome") { $0["hostId"] = "" }
        try assertRejected("welcome") { $0["serverTimeEpochMs"] = -1 }
        try assertRejected("welcome") { $0["heartbeatIntervalMs"] = 0 }
        try assertRejected("welcome") { $0["heartbeatIntervalMs"] = 25_001 }
        try assertRejected("welcome") { $0["heartbeatTimeoutMs"] = $0["heartbeatIntervalMs"] }
        try assertRejected("welcome") { $0["heartbeatTimeoutMs"] = 90_001 }
        try assertRejected("welcome") { $0["snapshotTimeoutMs"] = 4_999 }
        try assertRejected("welcome") { $0["snapshotTimeoutMs"] = 60_001 }
        try assertRejected("welcome") { $0["currentSequence"] = -1 }
        try assertRejected("welcome") { $0["oldestReplaySequence"] = 1043 }
        try assertRejected("welcome") { $0["capabilities"] = [] }
        try assertRejected("welcome") { $0["capabilities"] = ["events.replay", "events.replay"] }
        try assertRejected("welcome") { $0["capabilities"] = [1] }

        try assertRejected("heartbeat") { $0["sentAtEpochMs"] = -1 }
        try assertRejected("heartbeat") { $0["lastReceivedSequence"] = -1 }
        try assertRejected("heartbeat") { $0["nonce"] = "\n" }

        try assertRejected("closing") { $0["code"] = 999 }
        try assertRejected("closing") { $0["code"] = 1005 }
        try assertRejected("closing") { $0["reason"] = "" }
        try assertRejected("closing") { $0["retryable"] = "yes" }
        try assertRejected("closing") { $0["retryAfterMs"] = -1 }
        try assertRejected("closing", expected: .unknownFields) { $0.removeValue(forKey: "retryAfterMs") }

        try assertRejected("error") { $0["code"] = " " }
        try assertRejected("error") { $0["message"] = "" }
        try assertRejected("error") { $0["retryable"] = 1 }
        try assertRejected("error") { $0["requestId"] = " " }
        try assertRejected("error", expected: .unknownFields) { $0.removeValue(forKey: "requestId") }

        try assertRejected("event") { $0["sequence"] = 0 }
        try assertRejected("event") { $0["eventId"] = "" }
        try assertRejected("event") { $0["occurredAtEpochMs"] = -1 }
        try assertRejected("event") { $0["kind"] = "Workspace.updated" }
        try assertRejected("event") { $0["kind"] = "workspace." }
        try assertRejected("event") { $0["kind"] = "workspace.updated\n" }
        try assertRejected("event") { $0["payload"] = [] }

        for reason in ["eventGap", "hostReset", "replayTruncated", "snapshotRejected"] {
            var object = try fixtureObject("baselineRequired")
            object["reason"] = reason
            XCTAssertNoThrow(try ConnectionTransportFrame.decodeStrict(try jsonData(object)))
        }
        try assertRejected("baselineRequired") { $0["reason"] = "unknown" }
        try assertRejected("baselineRequired") { $0["requestedAfterSequence"] = -1 }
        try assertRejected("baselineRequired") { $0["currentSequence"] = 1042 }
        try assertRejected("baselineRequired") { $0["snapshotMethod"] = "mirror.other" }

        var versionOne = try fixtureObject("snapshot")
        versionOne["stateVersion"] = 1
        XCTAssertThrowsError(try ConnectionTransportFrame.decodeStrict(try jsonData(versionOne)))
        try assertRejected("snapshot") { $0["sequence"] = -1 }
        try assertRejected("snapshot") { $0["snapshotId"] = " " }
        try assertRejected("snapshot") { $0["generatedAtEpochMs"] = -1 }
        try assertRejected("snapshot") { $0["stateVersion"] = 0 }
        try assertRejected("snapshot") { $0["state"] = [] }
        try assertRejected("snapshot") { object in
            var state = object["state"] as! [String: Any]
            state["unexpected"] = true
            object["state"] = state
        }
        try assertRejected("snapshot") { object in
            var state = object["state"] as! [String: Any]
            state.removeValue(forKey: "surfaces")
            object["state"] = state
        }
        try assertRejected("snapshot") { object in
            var state = object["state"] as! [String: Any]
            state["selectedWorkspaceId"] = " "
            object["state"] = state
        }
        try assertRejected("snapshot") { object in
            var state = object["state"] as! [String: Any]
            state["workspaces"] = [:]
            object["state"] = state
        }
    }

    func test_eventKindAcceptsCanonicalNamespaceWithUnderscore() throws {
        // WHY: token_saver.digest is the canonical macOS producer and iOS
        // reducer name. Rejecting an underscore only in the first namespace
        // segment makes every retained digest terminate WebSocket replay.
        var object = try fixtureObject("event")
        object["kind"] = "token_saver.digest"
        XCTAssertNoThrow(try ConnectionTransportFrame.decodeStrict(try jsonData(object)))
    }

    func test_optionalFieldsEncodeAsExplicitNullAndRemainStrictlyDecodable() throws {
        let closing = ConnectionTransportFrame.closing(ConnectionClosingFrame(
            protocolVersion: 3, type: "closing", connectionId: "connection-1",
            hostId: "host-1", bootEpoch: 0, code: 1000, reason: "normal",
            retryable: false, retryAfterMs: nil
        ))
        let error = ConnectionTransportFrame.error(ConnectionErrorFrame(
            protocolVersion: 3, type: "error", connectionId: "connection-1",
            hostId: "host-1", bootEpoch: 0, code: "invalidFrame", message: "Invalid frame",
            retryable: false, requestId: nil
        ))
        for (frame, key) in [(closing, "retryAfterMs"), (error, "requestId")] {
            let data = try frame.encoded()
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertTrue(object[key] is NSNull, "\(key) must be encoded explicitly as null")
            XCTAssertNoThrow(try ConnectionTransportFrame.decodeStrict(data))
        }
    }

    func test_integerFieldsRejectFloatingPointJSONTokens() throws {
        let fields: [String: [String]] = [
            "welcome": [
                "bootEpoch", "serverTimeEpochMs", "heartbeatIntervalMs",
                "heartbeatTimeoutMs", "snapshotTimeoutMs",
                "currentSequence", "oldestReplaySequence",
            ],
            "heartbeat": ["bootEpoch", "sentAtEpochMs", "lastReceivedSequence"],
            "closing": ["bootEpoch", "code", "retryAfterMs"],
            "error": ["bootEpoch"],
            "event": ["bootEpoch", "sequence", "occurredAtEpochMs"],
            "baselineRequired": ["bootEpoch", "requestedAfterSequence", "currentSequence"],
            "snapshot": ["bootEpoch", "sequence", "generatedAtEpochMs", "stateVersion"],
        ]
        for (name, keys) in fields {
            for key in keys {
                let source = try XCTUnwrap(String(data: fixtureData(name), encoding: .utf8))
                let mutated = source.replacingOccurrences(
                    of: #""\#(key)"\s*:\s*([0-9]+)"#,
                    with: #""\#(key)": $1.0"#,
                    options: .regularExpression
                )
                XCTAssertNotEqual(mutated, source, "fixture must contain integer field \(name).\(key)")
                XCTAssertThrowsError(
                    try ConnectionTransportFrame.decodeStrict(Data(mutated.utf8)),
                    "\(name).\(key) must reject a floating-point JSON token"
                ) {
                    XCTAssertEqual($0 as? ConnectionProtocolFailure, .invalidFrame)
                }
            }
        }
    }

    func test_outboundTypedFrameRejectsEncodedPayloadAboveOneMiB() {
        let frame = ConnectionTransportFrame.event(ConnectionEventFrame(
            protocolVersion: 3, type: "event", connectionId: "connection-1",
            hostId: "host-1", bootEpoch: 1, sequence: 1, eventId: "event-1",
            occurredAtEpochMs: 1, kind: "workspace.updated",
            payload: .object([
                "blob": .string(String(repeating: "x", count: ConnectionTransportFrame.maximumEncodedBytes)),
            ])
        ))
        XCTAssertThrowsError(try frame.encoded()) {
            XCTAssertEqual($0 as? ConnectionProtocolFailure, .frameTooLarge)
        }
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
                let relativePath = "\(category)/\(local.lastPathComponent)"
                let canonical = canonicalRoot
                    .appendingPathComponent(category)
                    .appendingPathComponent(local.lastPathComponent)
                XCTAssertEqual(try Data(contentsOf: local), try Data(contentsOf: canonical),
                               "\(relativePath) drifted from the canonical contract fixture")
            }
        }
    }

    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/connection-contract-v3")
    }

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureRoot.appendingPathComponent("transport/\(name).json"))
    }

    private func fixtureObject(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData(name)) as? [String: Any])
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func assertRejected(
        _ name: String,
        expected: ConnectionProtocolFailure = .invalidFrame,
        mutate: (inout [String: Any]) -> Void
    ) throws {
        var object = try fixtureObject(name)
        mutate(&object)
        XCTAssertThrowsError(try ConnectionTransportFrame.decodeStrict(try jsonData(object)), name) {
            XCTAssertEqual($0 as? ConnectionProtocolFailure, expected, name)
        }
    }
}
