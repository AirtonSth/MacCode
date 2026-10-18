import XCTest
@testable import SocketServer
import CoreModel

/// F7, lane M1: the pure contract of `resume.head.v1` and the welcome field
/// `headSequence` (no server; plans come from a private `EventBus()`).
/// A phone that reads `headSequence` equal to its cursor takes no snapshot, so
/// a head stated to the wrong socket, or with the wrong shape, shows old data
/// as current; and iPhones decode the welcome with an exact key set, so the
/// key must reach only a socket that listed the token.
final class ResumeHeadContractTests: XCTestCase {
    /// The welcome key set every client that did not ask decodes with exact-key checks.
    private static let legacyWelcomeKeys: Set<String> = [
        "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
        "serverTimeEpochMs", "heartbeatIntervalMs", "heartbeatTimeoutMs",
        "snapshotTimeoutMs", "currentSequence", "oldestReplaySequence", "capabilities",
    ]
    private static let rotationNotice = "other.feature.v1"

    func test_featureHeader_matchesOnlyTheExactResumeHeadToken() {
        // A looser match sends a welcome key the client cannot parse, which is
        // terminal; and one header carries two features, each gating its own key.
        XCTAssertEqual(ConnectionClientFeatures.resumeHead, "resume.head.v1")
        XCTAssertEqual(ConnectionClientFeatures.headSequenceWelcomeKey, "headSequence")
        XCTAssertTrue(ConnectionClientFeatures.requestsResumeHead(header: "resume.head.v1"))
        XCTAssertTrue(ConnectionClientFeatures.requestsResumeHead(
            header: "\(Self.rotationNotice), resume.head.v1"
        ))
        XCTAssertTrue(ConnectionClientFeatures.requestsResumeHead(
            header: "resume.head.v1,\(Self.rotationNotice)"
        ))
        XCTAssertTrue(ConnectionClientFeatures.requestsResumeHead(header: "Resume.Head.V1"))
        XCTAssertFalse(ConnectionClientFeatures.requestsResumeHead(header: nil))
        XCTAssertFalse(ConnectionClientFeatures.requestsResumeHead(header: ""))
        XCTAssertFalse(ConnectionClientFeatures.requestsResumeHead(header: "resume.head.v2"))
        XCTAssertFalse(ConnectionClientFeatures.requestsResumeHead(header: "resume.head.v10"))
        XCTAssertFalse(ConnectionClientFeatures.requestsResumeHead(header: "resume.v1"))
        XCTAssertFalse(ConnectionClientFeatures.requestsResumeHead(header: "identity.v1"))
        XCTAssertFalse(ConnectionClientFeatures.requestsResumeHead(header: Self.rotationNotice))
    }

    func test_welcomeHead_isOmittedByDefault_andStrictWhenPresent() throws {
        let plain = try ConnectionTransportFrame.welcome(welcomeFrame()).encoded()
        XCTAssertEqual(try keys(plain), Self.legacyWelcomeKeys,
                       "absent must mean no statement: no key and no null placeholder")

        let data = try ConnectionTransportFrame.welcome(welcomeFrame(replayFrom: 3, head: 5)).encoded()
        XCTAssertEqual(try keys(data), Self.legacyWelcomeKeys.union(["replayFromSequence", "headSequence"]))
        guard case .welcome(let decoded) = try ConnectionTransportFrame.decodeStrict(data) else {
            return XCTFail("expected a welcome frame")
        }
        XCTAssertEqual(decoded.headSequence, 5)
        XCTAssertEqual(decoded.replayFromSequence, 3)

        // `JSONDecoder` alone reads a null as absent and `5.0` as 5: a client
        // that decodes with an exact key set and strict integers would not.
        let source = try XCTUnwrap(String(data: data, encoding: .utf8))
        for bad in ["null", "5.0", #""5""#, "true"] {
            let mutated = source.replacingOccurrences(
                of: #""headSequence":5"#, with: #""headSequence":\#(bad)"#
            )
            XCTAssertNotEqual(mutated, source, "the encoded welcome must carry the integer head")
            XCTAssertThrowsError(try ConnectionTransportFrame.decodeStrict(Data(mutated.utf8)), bad) {
                XCTAssertEqual($0 as? ConnectionProtocolFailure, .invalidFrame)
            }
        }

        // Two different heads in one frame, or a head for a phone with no
        // cursor, is a false statement: the Mac's own encoder refuses it.
        let falseStatements = [
            welcomeFrame(replayFrom: 3, head: 4),
            welcomeFrame(replayFrom: nil, head: 5),
            welcomeFrame(replayFrom: 0, head: 5),
        ]
        for frame in falseStatements {
            XCTAssertThrowsError(
                try ConnectionTransportFrame.welcome(frame).encoded(),
                "replayFrom=\(String(describing: frame.replayFromSequence)) head=\(String(describing: frame.headSequence))"
            ) { XCTAssertEqual($0 as? ConnectionProtocolFailure, .invalidFrame) }
        }
    }

    func test_headIsVouchedOnlyForADurableCursorOfThisBootAcceptedAsSent() throws {
        // Table M-1. Each omitted row is a way to show old data as current.
        let bus = EventBus()
        for index in 1...5 {
            bus.publish(kind: .workspaceUpdated, payload: .object([
                "workspace_id": .string("w-f7-head"), "name": .string("event-\(index)"),
            ]))
        }
        let head = bus.currentSeq
        XCTAssertEqual(head, 5)
        let atHead = bus.durableReplayPlan(since: head)
        let belowHead = bus.durableReplayPlan(since: 2)

        func vouched(
            requested: Bool = true,
            plan: EventBus.DurableReplayPlan?,
            needsBaseline: Bool = false,
            since: Int64,
            cursorBootProven: Bool = true,
            previousBoot: Bool = false
        ) -> Int64? {
            DurableReplayContract.welcomeHeadSequence(
                requested: requested,
                plan: plan,
                needsBaseline: needsBaseline,
                requestedSinceSequence: since,
                cursorBootProven: cursorBootProven,
                previousBoot: previousBoot
            )
        }

        // Row 8: a cursor at the head (nothing to replay) and one below it.
        XCTAssertEqual(vouched(plan: atHead, since: head), head)
        XCTAssertEqual(vouched(plan: belowHead, since: 2), head)

        XCTAssertNil(vouched(requested: false, plan: atHead, since: head),
                     "row 1: a socket that did not ask ends its stream on an unknown welcome key")
        XCTAssertNil(vouched(plan: nil, since: head),
                     "row 2: without a plan the head was read before the subscription")
        XCTAssertNil(vouched(plan: atHead, needsBaseline: true, since: head),
                     "row 3: a baselineRequired follows; the welcome cannot also offer a head")
        XCTAssertNil(vouched(plan: atHead, since: head, cursorBootProven: false),
                     "row 4: no envelope says which boot the cursor is from")
        XCTAssertNil(vouched(plan: belowHead, since: 2, previousBoot: true),
                     "row 5: the boot changed; the phone must reload")
        let empty = EventBus().durableReplayPlan(since: 0)
        XCTAssertEqual(empty.head, 0)
        XCTAssertNil(vouched(plan: empty, since: 0),
                     "row 6: a phone with no cursor has no state to call current")
        XCTAssertNil(vouched(plan: atHead, since: head + 1_000_000),
                     "row 7: the cursor was clamped; the Mac did not subscribe the one the phone holds")

        // A frame the encoder refuses costs the socket its welcome with no error.
        for plan in [atHead, belowHead] {
            let frame = welcomeFrame(
                currentSequence: plan.head,
                oldestReplay: min(plan.since + 1, plan.head),
                replayFrom: plan.since,
                head: vouched(plan: plan, since: plan.since)
            )
            let data = try ConnectionTransportFrame.welcome(frame).encoded()
            guard case .welcome(let decoded) = try ConnectionTransportFrame.decodeStrict(data) else {
                return XCTFail("expected a welcome frame")
            }
            XCTAssertEqual(decoded.headSequence, head)
            XCTAssertEqual(decoded.replayFromSequence, plan.since)
        }
    }

    // MARK: - Helpers

    /// The welcome of a durable socket, shaped as the server builds it.
    private func welcomeFrame(
        currentSequence: Int64 = 5,
        oldestReplay: Int64 = 1,
        replayFrom: Int64? = nil,
        head: Int64? = nil
    ) -> ConnectionWelcomeFrame {
        ConnectionWelcomeFrame(
            protocolVersion: 3, type: "welcome", connectionId: "connection-1",
            hostId: "host-1", bootEpoch: 7, serverTimeEpochMs: 1,
            heartbeatIntervalMs: 10_000, heartbeatTimeoutMs: 30_000,
            snapshotTimeoutMs: 15_000, currentSequence: currentSequence,
            oldestReplaySequence: oldestReplay,
            capabilities: ["events.replay"],
            replayFromSequence: replayFrom,
            headSequence: head
        )
    }

    private func keys(_ data: Data) throws -> Set<String> {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }
}
