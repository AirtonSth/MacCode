import XCTest
import AgentRuntime
import CoreModel
@testable import AppShell
@testable import Persistence

/// WHY: a bot's manual-action request and screenshots must land in durable state the chat
/// can render, even though the host posts them from a background thread.
@MainActor
final class ManualActionHostTests: XCTestCase {
    private func makeRouter() throws -> (AppContext, AppCommandRouter, AgentThread) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ManualAction-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let workspace = try router.createWorkspace(name: "ma-ws", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "Manual action thread",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        return (ctx, router, thread)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func test_manualActionRequestedNotification_persistsRequest() async throws {
        let (_, router, thread) = try makeRouter()
        let request = ManualActionRequest(botID: BotID(), threadID: thread.id, kind: .login, reason: "Entre")
        NotificationCenter.default.post(
            name: .botManualActionRequested,
            object: nil,
            userInfo: [BotHostNotificationKey.request: request]
        )
        await waitUntil { router.manualActionStore.open(threadID: thread.id) != nil }
        XCTAssertEqual(router.manualActionStore.open(threadID: thread.id)?.id, request.id)
    }

    func test_screenshotPostedNotification_appendsImageMessage() async throws {
        let (ctx, _, thread) = try makeRouter()
        NotificationCenter.default.post(
            name: .botScreenshotPosted,
            object: nil,
            userInfo: [
                BotHostNotificationKey.botID: BotID(),
                BotHostNotificationKey.threadID: thread.id,
                BotHostNotificationKey.jpeg: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02]),
                BotHostNotificationKey.reason: "tela de login",
                BotHostNotificationKey.kind: "login"
            ]
        )
        await waitUntil { ((try? ctx.messageRepo.hasAny(threadId: thread.id)) ?? false) }
        let page = try ctx.messageRepo.list(threadId: thread.id)
        let message = try XCTUnwrap(page.last)
        XCTAssertEqual(message.role, .assistant)
        XCTAssertEqual(message.content, "📷 tela de login")
        XCTAssertEqual(message.attachments.first?.kind, .image)
    }
}
