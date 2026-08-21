import XCTest
import CoreModel
@testable import Persistence

final class RemoteCodeHostCatalogMCPTests: XCTestCase {
    private func parse(_ line: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(line?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_toolsListAdvertisesEveryNamedHostToolAndRejectsGenericCall() throws {
        let server = ManagedBotSelfConfigMCP(environment: [:]) { _ in
            throw BotSelfConfigError.callerMissing
        }
        let listed = try parse(server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        let tools = try XCTUnwrap((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        for tool in RemoteCodeHostCatalog.toolNames {
            XCTAssertTrue(names.contains(tool), tool)
            let schema = try XCTUnwrap(tools.first { ($0["name"] as? String) == tool }?["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        }
        XCTAssertFalse(names.contains(RemoteCodeHostCatalog.genericHostCallTool))

        let unknown = try parse(server.handle(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"rc_host_call","arguments":{}}}"#
        ))
        let error = try XCTUnwrap(unknown["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    func test_mutationsRequireOperationIDBeforeSocket() throws {
        let server = ManagedBotSelfConfigMCP(environment: [:]) { _ in
            throw BotSelfConfigError.callerMissing
        }
        for tool in RemoteCodeHostCatalog.mutationToolNames {
            let payload: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": [
                    "name": tool,
                    "arguments": ["name": "Oliver", "bot_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "skill_id": "qa", "text": "hi"],
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let line = try XCTUnwrap(String(data: data, encoding: .utf8))
            let obj = try parse(server.handle(line))
            let result = try XCTUnwrap(obj["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, true, tool)
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            XCTAssertTrue(
                (content.first?["text"] as? String)?.contains("operation_id") == true,
                tool
            )
        }
    }

    func test_namedReadsFailClosedWithoutRunContextInsteadOfOpeningSQLite() throws {
        let server = ManagedBotSelfConfigMCP(environment: [:]) { _ in
            XCTFail("host catalog must not open BotStore")
            throw BotSelfConfigError.callerMissing
        }
        let listed = try parse(server.handle(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"rc_bot_list","arguments":{}}}"#
        ))
        let result = try XCTUnwrap(listed["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }
}
