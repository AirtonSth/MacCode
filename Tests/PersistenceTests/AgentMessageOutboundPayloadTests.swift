import XCTest
@testable import CoreModel
@testable import Persistence

final class AgentMessageOutboundPayloadTests: XCTestCase {
    func testOriginalMessageAndExactProviderPayloadRemainSeparateAcrossReload() throws {
        // WHY: the default transcript and copy action must preserve the user's
        // words while the opt-in toggle proves the exact SR2 bytes sent.
        let directory = NSTemporaryDirectory() + "rc-outbound-payload-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: directory).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let thread = AgentThread(title: "outbound", provider: .codex, model: "test")
        try threadRepo.upsert(thread)
        let message = AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "Depois de verificar, faça deploy."
        )
        let outbound = "@sr2 v1\nflow:verify>deploy\ndone:flow\no:cont"
        try messageRepo.append(message)
        try messageRepo.upsertOutboundPayload(
            messageId: message.id,
            threadId: thread.id,
            outboundText: outbound,
            createdAt: message.createdAt
        )

        XCTAssertEqual(try messageRepo.get(id: message.id)?.content, message.content)
        XCTAssertEqual(try AgentMessageRepository(db: db).outboundPayloads(threadId: thread.id)[message.id], outbound)
    }
}
