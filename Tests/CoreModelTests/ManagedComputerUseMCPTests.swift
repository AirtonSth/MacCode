import XCTest
@testable import CoreModel

final class ManagedComputerUseMCPTests: XCTestCase {
    private func parse(_ line: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(line?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeServer(backend: (any ComputerUseToolBackend)? = nil) -> ManagedComputerUseMCP {
        let lock = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-cu-mcp-\(UUID().uuidString).lock")
        return ManagedComputerUseMCP(
            queue: ComputerUseHostQueue(lockURL: lock),
            backend: backend ?? ComputerUseQueuedPassthroughBackend()
        )
    }

    func test_initializeAndToolsListIncludeScreenshotAndMouse() async throws {
        let server = makeServer()
        let initialized = try parse(await server.handle(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        ))
        let info = try XCTUnwrap(
            (initialized["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
        )
        XCTAssertEqual(info["name"] as? String, ComputerUseHostQueue.serverName)

        let listed = try parse(await server.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let tools = try XCTUnwrap((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains(ManagedComputerUseMCP.screenshotTool), "zavora surface includes screenshot")
        XCTAssertTrue(names.contains(ManagedComputerUseMCP.leftClickTool), "zavora surface includes mouse")
        XCTAssertTrue(names.contains(ManagedComputerUseMCP.typeTool) || names.contains(ManagedComputerUseMCP.keyTool))
        XCTAssertEqual(names, Set(ManagedComputerUseMCP.advertisedToolNames))
    }

    func test_twoConcurrentMutatingCallsShareTheShippedQueue() async throws {
        let backend = CountingBackend()
        let server = makeServer(backend: backend)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in 3...4 {
                group.addTask {
                    let line = #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"left_click","arguments":{"coordinate":[1,2]}}}"#
                    let obj = try await self.parse(await server.handle(line))
                    XCTAssertNotNil(obj["result"], "shipped tools/call must succeed")
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(backend.maxActive, 1, "HID calls must not overlap inside the shipped MCP queue")
        XCTAssertEqual(backend.invocations, 2)
    }

    func test_screenshotToolsCallEmitsImageContentFromShippedBackendResult() async throws {
        // WHY: zavora screenshot/zoom return type=image. A text-only MCP
        // envelope would hide the pixels from every bot.
        let pixels = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1s="
        let backend = ImageBackend(data: pixels, mimeType: "image/png")
        let server = makeServer(backend: backend)
        let obj = try parse(await server.handle(
            #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"screenshot","arguments":{"width":64}}}"#
        ))
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "image")
        XCTAssertEqual(content[0]["data"] as? String, pixels)
        XCTAssertEqual(content[0]["mimeType"] as? String, "image/png")
        XCTAssertNil(content[0]["text"])
        XCTAssertEqual(result["isError"] as? Bool, false)
    }

    func test_parseUpstreamKeepsZavoraImageAndDoesNotInventOkText() {
        // WHY: the zavora forwarder must use this shipped parser; dropping
        // type=image or substituting "ok" is how bots lose screenshots.
        let pixels = "ZmFrZS1qcGVn"
        let upstream: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 7,
            "result": [
                "content": [
                    ["type": "text", "text": "1024x640"],
                    ["type": "image", "data": pixels, "mimeType": "image/jpeg"],
                ],
                "isError": false,
            ],
        ]
        let parsed = ComputerUseToolResult.parseUpstream(upstream)
        XCTAssertEqual(parsed.content.count, 2)
        XCTAssertEqual(parsed.content[0], .text("1024x640"))
        XCTAssertEqual(parsed.content[1], .image(data: pixels, mimeType: "image/jpeg"))
        XCTAssertFalse(parsed.isError)
        XCTAssertFalse(parsed.content.contains { $0.text == "ok" })
        XCTAssertEqual(
            (parsed.jsonContent()[1]["data"] as? String),
            pixels,
            "MCP wire content must still carry the image bytes"
        )
    }
}

private final class CountingBackend: ComputerUseToolBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var maxActive = 0
    private(set) var invocations = 0

    func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult {
        lock.lock()
        active += 1
        invocations += 1
        maxActive = max(maxActive, active)
        lock.unlock()
        try? await Task.sleep(nanoseconds: 40_000_000)
        lock.lock()
        active -= 1
        lock.unlock()
        return ComputerUseToolResult(text: "hid \(name)")
    }
}

private struct ImageBackend: ComputerUseToolBackend {
    var data: String
    var mimeType: String

    func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult {
        ComputerUseToolResult(content: [.image(data: data, mimeType: mimeType)])
    }
}
