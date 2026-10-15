import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreModel
import RemoteCodeTreaty
@testable import SocketServer
@testable import AppShell
@testable import Persistence

/// WHY: the iPhone shows the images an agent reply talks about; Mac-local
/// ones only reach it through the host. End to end through the real router
/// and message store: a referenced image comes back, an unreferenced one
/// (same folder, same thread) does not.
@MainActor
final class AgentMessageImageGetRemoteTests: XCTestCase {
    func test_routerServesReferencedImageAndRefusesUnreferencedOne() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2MessageImageGet-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let workspace = try router.createWorkspace(name: "message-image-ws", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id, title: "Images", provider: .codex, model: "fake-model",
            permissionMode: .supervised, reasoningEffort: .medium
        )

        func writePNG(_ name: String) throws -> String {
            let url = workspaceDir.appendingPathComponent(name)
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return url.path
        }
        let shown = try writePNG("shown.png")
        let hidden = try writePNG("hidden.png")
        let message = AgentMessage(threadId: thread.id, role: .assistant, content: "Rendered: ![chart](\(shown))")
        try ctx.messageRepo.append(message)

        let dispatcher = JSONRPCDispatcher(router: router)
        func get(_ ref: String) async -> JSONRPCResponse {
            await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.message.image.get", params: [
                "thread_id": .string(thread.id.value.uuidString),
                "message_id": .string(message.id.value.uuidString),
                "ref": .string(ref),
                "max_pixel": .number(512),
            ]))
        }

        let ok = await get(shown)
        XCTAssertNil(ok.error)
        let result = try JSONDecoder().decode(AgentMessageImageGet.Result.self, from: JSONEncoder().encode(try XCTUnwrap(ok.result)))
        XCTAssertEqual(result.width, 64)
        XCTAssertEqual(result.height, 32)
        XCTAssertNotNil(Data(base64Encoded: result.dataBase64))

        let refused = await get(hidden)
        XCTAssertEqual(refused.error?.code, AgentMessageImageGetWire.notFoundCode,
                       "a file the message does not mention is not readable, even next to one it does")
        XCTAssertEqual(refused.error?.data?.objectValue?["missing"]?.stringValue, "ref")
    }
}
