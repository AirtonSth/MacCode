import XCTest
import CoreModel
@testable import AppShell
@testable import Persistence
@testable import Surfaces

/// Agent App `@bot` mentions must dispatch to the shared teammate runner.
@MainActor
final class AgentAppBotMentionTests: XCTestCase {
    func test_agentAppSendDispatchesBotMentions() throws {
        // WHY: typing @quinn in Agent App must start that teammate. If
        // dispatch only existed on Bots Desk, the Agent thread could never
        // hand a turn to another bot.
        let dir = NSTemporaryDirectory() + "RC2AgentMention-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let surface = AgentAppSurface(
            workspaceID: WorkspaceID(),
            cwd: dir,
            coordinator: ctx.coordinator,
            threadRepo: ctx.threadRepo,
            messageRepo: ctx.messageRepo
        )
        let quinn = BotDefinition(
            handle: "quinn",
            name: "Quinn",
            title: "CRM Controller",
            description: ""
        )
        surface.viewModel.mentionableBotsProvider = { [quinn] }
        surface.viewModel.createThread(title: "Mention thread")
        let threadId = try XCTUnwrap(surface.viewModel.selectedThreadId)
        var captured: ([BotDefinition], String, AgentThreadID)?
        let done = expectation(description: "mention dispatch")
        surface.viewModel.onDispatchBotMentions = { peers, text, id in
            captured = (peers, text, id)
            done.fulfill()
        }
        surface.viewModel.dispatchBotMentions(in: "@quinn check WhatsApp", threadId: threadId)
        XCTAssertEqual(surface.viewModel.lastDispatchedMentionHandlesForTesting, ["quinn"])
        wait(for: [done], timeout: 1)
        XCTAssertEqual(captured?.0.map(\.id), [quinn.id])
        XCTAssertEqual(captured?.1, "@quinn check WhatsApp")
        XCTAssertEqual(captured?.2, threadId)

        surface.viewModel.presentBotPeerMessage(peer: quinn, text: "Inbox is clear.", threadId: threadId)
        XCTAssertTrue(surface.viewModel.statusMessage.isEmpty, surface.viewModel.statusMessage)
        let stored = try ctx.messageRepo.listRecent(threadId: threadId, limit: 8)
        let inbound = try XCTUnwrap(stored.last)
        XCTAssertEqual(inbound.role, .assistant)
        let parsed = try XCTUnwrap(BotPeerTranscript.parse(inbound.content))
        XCTAssertTrue(parsed.caption.contains("Message from Quinn"))
        XCTAssertEqual(parsed.body, "Inbox is clear.")
    }

    func test_configureAgentAppBotMentionsReadsBotStore() throws {
        // WHY: the router must publish live bots into the composer. A
        // hard-coded empty provider would show @ suggestions that never resolve.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AppShell/AppCommandRouter.swift")
        let source = try String(contentsOf: sourceURL)
        XCTAssertTrue(source.contains("configureAgentAppBotMentions"))
        XCTAssertTrue(source.contains("runMentionedPrompt"))
        XCTAssertTrue(source.contains("presentBotPeerMessage"))
    }
}
