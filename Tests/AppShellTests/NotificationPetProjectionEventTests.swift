import XCTest
@testable import AppShell
import CoreModel
import Persistence
@testable import SocketServer

@MainActor
final class NotificationPetProjectionEventTests: XCTestCase {
    func test_notificationRPCMutationsPublishExactlyOneSafeRefreshEventEach() async throws {
        let directory = NSTemporaryDirectory() + "RC2NotificationPetRPC-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Pet", cwd: NSTemporaryDirectory())
        let dispatcher = JSONRPCDispatcher(router: router)
        var events: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            if event.kind.hasPrefix("notification.") { events.append(event) }
        }
        defer { EventBus.shared.unsubscribe(token) }

        let created = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "notification.create",
            params: [
                "workspace_id": .string(workspace.id.value.uuidString),
                "title": .string("private prompt"),
                "body": .string("token=hunter2"),
                "category": .string(PetNotificationCategory.gitCompleted.rawValue)
            ]
        ))
        let id = try XCTUnwrap(created.result?.objectValue?["id"]?.stringValue)
        _ = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "notification.mark_read",
            params: ["id": .string(id)]
        ))
        _ = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(3),
            method: "notification.dismiss",
            params: ["id": .string(id)]
        ))

        XCTAssertEqual(events.map(\.kind), [
            "notification.created", "notification.read", "notification.dismissed"
        ], "Each committed RPC mutation must have one canonical refresh event.")
        let encoded = events.map { String(describing: $0.payload) }.joined(separator: " ")
        XCTAssertFalse(encoded.contains("private prompt"))
        XCTAssertFalse(encoded.contains("hunter2"))
        XCTAssertTrue(encoded.contains(id))
    }

    func test_notificationMutationsPublishSafeProjectionRefreshEvents() throws {
        let directory = NSTemporaryDirectory() + "RC2NotificationPet-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Pet", cwd: NSTemporaryDirectory())
        var events: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            if event.kind.hasPrefix("notification.") { events.append(event) }
        }
        defer { EventBus.shared.unsubscribe(token) }

        let id = try router.notificationCreate(
            workspaceId: workspace.id,
            title: "private prompt",
            body: "token=hunter2",
            category: PetNotificationCategory.gitCompleted.rawValue
        )
        try router.notificationMarkRead(id: id)
        try router.notificationDismiss(id: id)

        XCTAssertEqual(events.map(\.kind), [
            "notification.created", "notification.read", "notification.dismissed"
        ])
        let encoded = events.map { String(describing: $0.payload) }.joined(separator: " ")
        XCTAssertFalse(encoded.contains("private prompt"))
        XCTAssertFalse(encoded.contains("hunter2"))
        XCTAssertTrue(encoded.contains(id))
    }

    func test_serverFailureProjectionReopensStableRowAndPublishesSafeRefreshEvents() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let repository = NotificationRepository(db: db)
        var events: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            if event.kind.hasPrefix("notification.") { events.append(event) }
        }
        defer { EventBus.shared.unsubscribe(token) }

        let id = try AppDelegate.projectPetServerFailure(server: "rc2 socket", repository: repository)
        try AppDelegate.resolvePetServerFailure(server: "rc2 socket", repository: repository)
        _ = try AppDelegate.projectPetServerFailure(server: "rc2 socket", repository: repository)

        XCTAssertEqual(id, "pet.server-failure.rc2-socket")
        let unread = try XCTUnwrap(repository.list(unreadOnly: true).first)
        XCTAssertEqual(unread.id, id, "A recurring listener failure must become unread again after an earlier recovery.")
        XCTAssertEqual(unread.title, "Remote access needs attention")
        XCTAssertNil(unread.body, "Listener errors and addresses must never enter the Pet row.")
        XCTAssertEqual(events.map(\.kind), ["notification.created", "notification.read", "notification.created"])
        let encoded = events.map { String(describing: $0.payload) }.joined(separator: " ")
        XCTAssertTrue(encoded.contains(id))
        XCTAssertFalse(encoded.contains("socket error"))
    }

    func test_petBulkClearUsesCanonicalMutationEventsForEveryChangedRow() throws {
        let directory = NSTemporaryDirectory() + "RC2PetReadSync-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Pet", cwd: NSTemporaryDirectory())
        var thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "finished",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        thread.status = .completed
        thread.hasUnread = true
        try context.threadRepo.upsert(thread)
        let notificationID = try router.notificationCreate(
            workspaceId: workspace.id,
            title: "safe stored title",
            body: nil,
            category: PetNotificationCategory.gitCompleted.rawValue
        )
        var events: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            if event.kind == "agent.thread.read" || event.kind == "notification.read" {
                events.append(event)
            }
        }
        defer { EventBus.shared.unsubscribe(token) }
        let store = PetAttentionStore(
            threadRepository: context.threadRepo,
            callbackRepository: context.providerPendingCallbackRepo,
            notificationRepository: NotificationRepository(db: context.db),
            markAgentThreadRead: { try router.markAgentThreadRead(thread: $0) },
            markNotificationRead: { try router.notificationMarkRead(id: $0) }
        )

        XCTAssertEqual(try store.markAllRead(), 2)

        XCTAssertEqual(events.map(\.kind), ["agent.thread.read", "notification.read"])
        XCTAssertFalse(try XCTUnwrap(context.threadRepo.get(id: thread.id)).hasUnread)
        XCTAssertNotNil(try XCTUnwrap(
            NotificationRepository(db: context.db).list().first { $0.id == notificationID }
        ).readAt)
    }
}
