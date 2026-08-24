import XCTest
import CoreModel
@testable import Persistence

final class ManagedBotSelfConfigMCPTests: XCTestCase {
    private func parse(_ line: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(line?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_initializeAndToolsListCoverGetAndSetTwice() throws {
        // WHY: admit is useless if handshake does not advertise the live catalog.
        let server = ManagedBotSelfConfigMCP(environment: [:]) { _ in
            throw BotSelfConfigError.callerMissing
        }
        for id in [1, 2] {
            let initialized = try parse(server.handle(
                #"{"jsonrpc":"2.0","id":\#(id),"method":"initialize","params":{}}"#
            ))
            let info = try XCTUnwrap(
                (initialized["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
            )
            XCTAssertEqual(info["name"] as? String, BotSelfConfigCatalog.serverName)

            let listed = try parse(server.handle(
                #"{"jsonrpc":"2.0","id":\#(id + 10),"method":"tools/list"}"#
            ))
            let tools = try XCTUnwrap((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
            let names = tools.compactMap { $0["name"] as? String }
            XCTAssertEqual(
                Set(names),
                Set(BotSelfConfigCatalog.toolNames + RemoteCodeHostCatalog.toolNames)
            )
            XCTAssertFalse(names.contains(RemoteCodeHostCatalog.genericHostCallTool))
            XCTAssertTrue(names.contains(BotSelfConfigCatalog.getSettings))
            XCTAssertTrue(names.contains(BotSelfConfigCatalog.setSettings))
            XCTAssertTrue(names.contains(BotSelfConfigCatalog.writeHomeFile))
            XCTAssertFalse(names.contains(BotSelfConfigCatalog.setSkill))
            XCTAssertTrue(names.contains(BotSelfConfigCatalog.saveRoutine))
            XCTAssertTrue(names.contains(BotSelfConfigCatalog.listPeers))
            XCTAssertTrue(names.contains(BotSelfConfigCatalog.askPeer))
            for tool in RemoteCodeHostCatalog.toolNames {
                XCTAssertTrue(names.contains(tool), "host catalog must advertise \(tool)")
            }

            let askPeer = try XCTUnwrap(tools.first {
                ($0["name"] as? String) == BotSelfConfigCatalog.askPeer
            })
            let description = try XCTUnwrap(askPeer["description"] as? String)
            XCTAssertTrue(description.contains("focused prompt written by you"))
            XCTAssertTrue(description.contains("sent literally"))
            let schema = try XCTUnwrap(askPeer["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["required"] as? [String], ["handle", "prompt", "reply_mode"])
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let prompt = try XCTUnwrap(properties["prompt"] as? [String: Any])
            XCTAssertTrue((prompt["description"] as? String)?.contains("Only this text is sent") == true)
            let consultationID = try XCTUnwrap(
                properties[BotPeerDelegation.consultationIDParameterKey] as? [String: Any]
            )
            XCTAssertEqual(consultationID["type"] as? String, "string")
            XCTAssertEqual(consultationID["format"] as? String, "uuid")
            XCTAssertTrue(
                (consultationID["description"] as? String)?.contains("Omit") == true,
                "consultation_id must be optional so existing omission call sites stay fresh"
            )
            XCTAssertFalse(
                (schema["required"] as? [String])?.contains(BotPeerDelegation.consultationIDParameterKey) == true,
                "continuation is explicit; omission must remain the clean independent-review path"
            )
        }
    }

    func test_askPeerCatalogDescribesRepeatableConsultation() {
        let description = BotSelfConfigCatalog.description(for: BotSelfConfigCatalog.askPeer)
        let requiredGuidance = [
            "Calls are repeatable",
            "use `consult` as often as needed",
            "authoring each new prompt yourself based on real replies",
            "including only the prior-reply context relevant to the next Bot",
            "primary AI mediates and produces the final synthesis",
            "RemoteCode does not semantically route, sequence, or set a fixed iteration count",
            "`reply_only` is terminal",
            "no comparison, follow-up, mediation, or synthesis remains",
        ]

        for guidance in requiredGuidance {
            XCTAssertTrue(
                description.contains(guidance),
                "ask-peer catalog must tell the primary AI: \(guidance)"
            )
        }
    }

    func test_toolsCallUsesShippedStoreHelpers() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let bot = try store.create(
            name: "Piper", title: "Scout", description: "", soul: "Be brief.", provider: .claude
        )
        let environment = [BotSelfConfigCatalog.callerEnvironmentKey: bot.id.value.uuidString]
        let server = ManagedBotSelfConfigMCP(environment: environment) { _ in store }

        let listed = try parse(server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        let tools = try XCTUnwrap((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(
            Set(tools.compactMap { $0["name"] as? String }),
            Set(BotSelfConfigCatalog.toolNames + RemoteCodeHostCatalog.toolNames)
        )

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": BotSelfConfigCatalog.setSettings,
                "arguments": ["name": "Piper Live", "soul": "Own your settings."],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let line = try XCTUnwrap(String(data: data, encoding: .utf8))
        let obj = try parse(server.handle(line))
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("Piper Live"))
        XCTAssertEqual(try store.get(id: bot.id)?.name, "Piper Live")
    }
}
