import XCTest
import CoreModel
import SocketServer
@testable import AppShell

@MainActor
final class HostBrowserScreenshotTests: XCTestCase {
    func test_selectsOnlyBrowserInCallingWorkspace() throws {
        let browser = SurfaceDescriptor(type: .browser, title: "Frontend")
        let terminal = SurfaceDescriptor(type: .terminal, title: "Terminal")
        XCTAssertEqual(
            try AppCommandRouter.hostBrowserScreenshotSurface(in: [terminal, browser], requested: nil),
            browser.id
        )
        XCTAssertThrowsError(try AppCommandRouter.hostBrowserScreenshotSurface(
            in: [terminal, browser], requested: terminal.id
        ))
        XCTAssertThrowsError(try AppCommandRouter.hostBrowserScreenshotSurface(
            in: [browser], requested: SurfaceID()
        ), "A surface outside the calling workspace must never be captured.")
    }

    func test_ambiguousAndAbsentBrowserRequireUserChoice() throws {
        let first = SurfaceDescriptor(type: .browser, title: "First frontend")
        let second = SurfaceDescriptor(type: .browser, title: "Second frontend")
        XCTAssertThrowsError(try AppCommandRouter.hostBrowserScreenshotSurface(in: [], requested: nil))
        XCTAssertThrowsError(try AppCommandRouter.hostBrowserScreenshotSurface(
            in: [first, second], requested: nil
        ), "Capturing the globally selected browser could disclose the wrong workspace.")
        XCTAssertEqual(
            try AppCommandRouter.hostBrowserScreenshotSurface(in: [first, second], requested: second.id),
            second.id
        )
    }

    func test_publishedImagePersistsBeforePairedEventAndSurvivesReopen() async throws {
        let directory = NSTemporaryDirectory() + "rc-host-image-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        let thread = AgentThread(workspaceId: nil, title: "Screenshot", provider: .distill, model: "test")
        try context.threadRepo.upsert(thread)
        let eventSeen = expectation(description: "paired image message appended")
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            if event.kind == "agent.message.appended",
               event.payload.objectValue?["threadId"]?.objectValue?["value"]?.stringValue == thread.id.value.uuidString {
                eventSeen.fulfill()
            }
        }
        defer { EventBus.shared.unsubscribe(subscription) }
        let image = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aHXsAAAAASUVORK5CYII="))
        let published = try router.publishAssistantImage(
            threadID: thread.id, data: image, displayName: "frontend.png",
            mimeType: "image/png", content: "Mac browser: Frontend"
        )
        let stored = try XCTUnwrap(context.messageRepo.get(id: published.message.id))
        let attachment = try XCTUnwrap(stored.attachments.first)
        XCTAssertEqual(attachment.id, published.attachmentID)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: attachment.path)), image)
        await fulfillment(of: [eventSeen], timeout: 2)
        let reopened = try AppContext(channel: .debug, appSupportOverride: directory)
        let restored = try XCTUnwrap(reopened.messageRepo.get(id: stored.id))
        XCTAssertEqual(restored.attachments, stored.attachments)
        XCTAssertEqual(restored.threadId, thread.id)
    }

    func test_missingConversationFailsBeforeCapture() throws {
        let directory = NSTemporaryDirectory() + "rc-host-screenshot-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        XCTAssertThrowsError(try router.captureHostBrowserToChat(
            callerThread: AgentThreadID(), surface: nil, reason: "Frontend"
        ))
    }
}
