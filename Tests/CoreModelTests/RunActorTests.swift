import XCTest
@testable import CoreModel

final class RunActorTests: XCTestCase {
    private let botUUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    private func sortedJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    func test_runActorJSONShapeIsStableBecausePersistedRowsDependOnIt() throws {
        XCTAssertEqual(try sortedJSON(RunActor.none), #"{"kind":"none"}"#)
        XCTAssertEqual(
            try sortedJSON(RunActor.bot(BotID(botUUID))),
            #"{"botId":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","kind":"bot"}"#
        )
        for actor in [RunActor.none, .bot(BotID(botUUID))] {
            let data = try JSONEncoder().encode(actor)
            XCTAssertEqual(try JSONDecoder().decode(RunActor.self, from: data), actor)
        }
        XCTAssertNil(RunActor.none.botID)
        XCTAssertEqual(RunActor.bot(BotID(botUUID)).botID, BotID(botUUID))
    }

    func test_runActorRejectsMalformedBotID() {
        let json = Data(#"{"kind":"bot","botId":"nope"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RunActor.self, from: json))
    }

    func test_executionTargetJSONIsRawString() throws {
        XCTAssertEqual(try sortedJSON(["t": ExecutionTarget.vm]), #"{"t":"vm"}"#)
        XCTAssertEqual(try JSONDecoder().decode([String: ExecutionTarget].self, from: Data(#"{"t":"mac"}"#.utf8))["t"], .mac)
    }

    func test_agentThreadActorFieldsRoundTrip() throws {
        let lock = Date(timeIntervalSince1970: 1_700_000_000)
        let thread = AgentThread(
            title: "t",
            provider: .distill,
            model: "m",
            actor: .bot(BotID(botUUID)),
            actorLockedAt: lock,
            executionTarget: .vm
        )
        let data = try JSONEncoder().encode(thread)
        let decoded = try JSONDecoder().decode(AgentThread.self, from: data)
        XCTAssertEqual(decoded, thread)
        XCTAssertEqual(decoded.actor, .bot(BotID(botUUID)))
        XCTAssertEqual(decoded.actorLockedAt, lock)
        XCTAssertEqual(decoded.executionTarget, .vm)
    }

    func test_legacyAgentThreadJSONWithoutActorKeysDecodesAsNoActor() throws {
        let thread = AgentThread(
            title: "t",
            provider: .distill,
            model: "m",
            actor: .bot(BotID(botUUID)),
            actorLockedAt: Date(timeIntervalSince1970: 1_700_000_000),
            executionTarget: .vm
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(thread)) as? [String: Any])
        for key in ["actor", "actorLockedAt", "executionTarget"] {
            XCTAssertNotNil(object.removeValue(forKey: key), "\(key) must be encoded")
        }
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AgentThread.self, from: legacy)
        XCTAssertEqual(decoded.actor, .none)
        XCTAssertNil(decoded.actorLockedAt)
        XCTAssertNil(decoded.executionTarget)
        XCTAssertEqual(decoded.title, "t")
    }

    func test_botExecutionDefaultIsVMOnlyForDockerDesktop() {
        func revision(_ kind: BotDesktopKind) -> BotRevision {
            BotRevision(
                botID: BotID(botUUID),
                revisionNumber: 1,
                name: "n",
                title: "t",
                description: "d",
                soul: "s",
                permissionMode: .supervised,
                desktopKind: kind,
                digest: "x"
            )
        }
        XCTAssertEqual(BotExecutionDefault.target(for: revision(.dockerDesktop)), .vm)
        XCTAssertEqual(BotExecutionDefault.target(for: revision(.logicalExecutionSpace)), .mac)
        XCTAssertEqual(BotExecutionDefault.target(for: revision(.botOwnedBrowser)), .mac)
        XCTAssertEqual(BotExecutionDefault.target(for: nil), .mac)
    }
}
