import XCTest
@testable import AppShell
import CoreModel
import Persistence
import SocketServer

final class PetAttentionStoreTests: XCTestCase {
    private struct Fixture {
        let db: SQLiteDB
        let threads: AgentThreadRepository
        let callbacks: ProviderPendingCallbackRepository
        let notifications: NotificationRepository
        let store: PetAttentionStore
    }

    private func fixture() throws -> Fixture {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let threads = AgentThreadRepository(db: db)
        let callbacks = ProviderPendingCallbackRepository(db: db)
        let notifications = NotificationRepository(db: db)
        return Fixture(
            db: db,
            threads: threads,
            callbacks: callbacks,
            notifications: notifications,
            store: PetAttentionStore(
                threadRepository: threads,
                callbackRepository: callbacks,
                notificationRepository: notifications,
                workspaceNameProvider: { _ in "star" }
            )
        )
    }

    private func thread(
        id: String,
        workspaceID: WorkspaceID,
        status: AgentRunStatus,
        updatedAt: TimeInterval,
        hasUnread: Bool = true,
        title: String = "raw prompt must stay private"
    ) -> AgentThread {
        AgentThread(
            id: AgentThreadID(UUID(uuidString: id)!),
            workspaceId: workspaceID,
            title: title,
            provider: .codex,
            model: "gpt-5.5",
            status: status,
            createdAt: Date(timeIntervalSince1970: updatedAt - 10),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            hasUnread: hasUnread
        )
    }

    func test_refresh_prioritizesCallbacksSuppressesDuplicateThreadOutcomeAndFiltersDeterministically() throws {
        let fixture = try fixture()
        let workspaceID = WorkspaceID(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        let blocked = thread(
            id: "11111111-1111-1111-1111-111111111111",
            workspaceID: workspaceID,
            status: .completed,
            updatedAt: 300,
            title: "Run rm -rf /Users/private token=secret"
        )
        let failed = thread(
            id: "22222222-2222-2222-2222-222222222222",
            workspaceID: workspaceID,
            status: .failed,
            updatedAt: 200
        )
        let running = thread(
            id: "33333333-3333-3333-3333-333333333333",
            workspaceID: workspaceID,
            status: .running,
            updatedAt: 400
        )
        try fixture.threads.upsert(blocked)
        try fixture.threads.upsert(failed)
        try fixture.threads.upsert(running)
        try fixture.callbacks.record(
            threadId: blocked.id,
            request: AssistantPendingRequest(
                id: "approval-1",
                turnId: "turn-1",
                kind: .commandExecution,
                title: "Run rm -rf /Users/private",
                detail: "Authorization: Bearer secret-token",
                createdAtMs: 100_000
            )
        )
        try fixture.notifications.insert(AppNotification(
            id: "git-1",
            workspaceId: workspaceID,
            title: "unsafe command output /Users/private",
            body: "password=hunter2",
            category: PetNotificationCategory.gitFailed.rawValue,
            createdAt: Date(timeIntervalSince1970: 150)
        ))
        try fixture.notifications.insert(AppNotification(
            id: "not-whitelisted",
            workspaceId: workspaceID,
            title: "must stay hidden",
            category: "pet.arbitrary",
            createdAt: Date(timeIntervalSince1970: 500)
        ))

        let first = try fixture.store.refresh()
        let second = try fixture.store.refresh()

        XCTAssertEqual(first, second, "Unchanged persistence must produce stable rows and order.")
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(first.items.map(\.classification), [.needsYou, .completed, .completed])
        XCTAssertEqual(first.items.map(\.title), [
            "Approve: Run command",
            "Agent run failed",
            "Git delivery failed"
        ])
        XCTAssertEqual(first.items.map(\.detail), [
            "star - Codex - \(AgentThreadTitle.display("Run rm -rf /Users/private token=secret"))",
            "star - Codex - raw prompt must stay private",
            nil
        ])
        XCTAssertEqual(first.items.map(\.workspaceName), ["star", "star", "star"])
        XCTAssertTrue(first.items[0].id.contains("approval-1"))
        XCTAssertTrue(first.items[1].id.contains(failed.id.value.uuidString))
        XCTAssertEqual(first.items[2].id, "notification:git-1")
        XCTAssertFalse(first.items.contains { $0.id.contains(blocked.id.value.uuidString) && $0.kind == .agentOutcome(.completed) })
        XCTAssertFalse(first.items.contains { $0.id.contains(running.id.value.uuidString) })
        XCTAssertFalse(first.items.contains { $0.id.contains("not-whitelisted") })

        let visibleCopy = first.items.flatMap { [$0.title, $0.detail].compactMap { $0 } }.joined(separator: " ")
        // Credentials stay redacted; workspace + truncated thread title are intentionally visible.
        for secret in ["secret-token", "hunter2", "token=secret", "Bearer secret"] {
            XCTAssertFalse(visibleCopy.contains(secret), "Pet rows must never expose credentials.")
        }
        XCTAssertTrue(visibleCopy.contains("star - Codex"))
        XCTAssertTrue(visibleCopy.contains("Approve: Run command"))

        guard case .agentThread(let threadID, let routeWorkspaceID) = first.items[0].route else {
            return XCTFail("Callback must route to its exact agent thread.")
        }
        XCTAssertEqual(threadID, blocked.id)
        XCTAssertEqual(routeWorkspaceID, workspaceID)
        XCTAssertEqual(try fixture.store.refresh(filter: .needsYou).items.map(\.id), [first.items[0].id])
        XCTAssertEqual(
            try fixture.store.refresh(filter: .completed).items.map(\.id),
            Array(first.items.dropFirst()).map(\.id)
        )
    }

    func test_refresh_globallySortsNeedsYouBeforeCompletedThenNewestAndStableID() throws {
        let fixture = try fixture()
        let workspaceID = WorkspaceID(UUID())
        let blocked = thread(
            id: "77777777-7777-7777-7777-777777777777",
            workspaceID: workspaceID,
            status: .completed,
            updatedAt: 800
        )
        let completed = thread(
            id: "88888888-8888-8888-8888-888888888888",
            workspaceID: workspaceID,
            status: .completed,
            updatedAt: 700
        )
        try fixture.threads.upsert(blocked)
        try fixture.threads.upsert(completed)
        try fixture.callbacks.record(
            threadId: blocked.id,
            request: AssistantPendingRequest(
                id: "approval-old",
                turnId: nil,
                kind: .exec,
                title: "private command",
                createdAtMs: 100_000
            )
        )
        for notification in [
            AppNotification(
                id: "file-new",
                workspaceId: workspaceID,
                surfaceId: SurfaceID(UUID()),
                title: "unsafe",
                category: PetNotificationCategory.fileConflict.rawValue,
                createdAt: Date(timeIntervalSince1970: 500)
            ),
            AppNotification(
                id: "ssh-a",
                workspaceId: workspaceID,
                surfaceId: SurfaceID(UUID()),
                title: "unsafe",
                category: PetNotificationCategory.sshUnexpectedDisconnect.rawValue,
                createdAt: Date(timeIntervalSince1970: 400)
            ),
            AppNotification(
                id: "ssh-b",
                workspaceId: workspaceID,
                surfaceId: SurfaceID(UUID()),
                title: "unsafe",
                category: PetNotificationCategory.sshUnexpectedDisconnect.rawValue,
                createdAt: Date(timeIntervalSince1970: 400)
            ),
            AppNotification(
                id: "git-newest",
                workspaceId: workspaceID,
                title: "unsafe",
                category: PetNotificationCategory.gitCompleted.rawValue,
                createdAt: Date(timeIntervalSince1970: 900)
            ),
        ] {
            try fixture.notifications.insert(notification)
        }

        let snapshot = try fixture.store.refresh()
        let callbackID = try XCTUnwrap(snapshot.items.first { item in
            item.source == .callback(
                threadID: blocked.id,
                requestID: "approval-old",
                kind: .approval
            )
        }?.id)
        XCTAssertEqual(snapshot.items.map(\.id), [
            "notification:file-new",
            "notification:ssh-a",
            "notification:ssh-b",
            callbackID,
            "notification:git-newest",
            "thread:\(completed.id.value.uuidString)",
        ], "Needs-you rows must globally precede newer completed work, with deterministic newest-first ordering inside each class.")
        XCTAssertFalse(
            snapshot.items.contains { $0.id == "thread:\(blocked.id.value.uuidString)" },
            "A callback must remain the single source of attention for its blocked thread."
        )
        XCTAssertEqual(
            try fixture.store.refresh(filter: .needsYou).items.map(\.id),
            Array(snapshot.items.prefix(4)).map(\.id)
        )
        XCTAssertEqual(
            try fixture.store.refresh(filter: .completed).items.map(\.id),
            Array(snapshot.items.suffix(2)).map(\.id)
        )
    }

    func test_staleCallbacksRemainFirstAndUseFixedCopyWithoutStaleReason() throws {
        let fixture = try fixture()
        let workspaceID = WorkspaceID(UUID())
        var thread = thread(
            id: "44444444-4444-4444-4444-444444444444",
            workspaceID: workspaceID,
            status: .failed,
            updatedAt: 300,
            hasUnread: false
        )
        thread.provider = .claude
        try fixture.threads.upsert(thread)
        try fixture.callbacks.record(
            threadId: thread.id,
            userInput: AssistantUserInputRequest(
                id: "question-1",
                turnId: "turn-1",
                prompt: "Paste a production secret",
                options: [],
                createdAtMs: 10_000
            )
        )
        try fixture.callbacks.markStale(
            threadId: thread.id,
            requestId: "question-1",
            kind: .userInput,
            reason: "Provider path /Users/private token=secret"
        )

        let item = try XCTUnwrap(fixture.store.refresh().items.first)
        XCTAssertEqual(item.kind, .callback(.question, isStale: true))
        XCTAssertEqual(item.classification, .needsYou)
        XCTAssertEqual(item.title, "Input request expired")
        XCTAssertEqual(item.detail, "star - Claude - raw prompt must stay private")
        XCTAssertEqual(item.workspaceName, "star")
    }

    func test_openAndMarkRead_mutatesOnlyAfterRouteVerificationAndNeverResolvesCallback() throws {
        let fixture = try fixture()
        let workspaceID = WorkspaceID(UUID())
        let thread = thread(
            id: "55555555-5555-5555-5555-555555555555",
            workspaceID: workspaceID,
            status: .completed,
            updatedAt: 100
        )
        try fixture.threads.upsert(thread)
        let threadItem = try XCTUnwrap(fixture.store.refresh().items.first)

        XCTAssertEqual(
            try fixture.store.openAndMarkRead(itemID: threadItem.id) { route in
                XCTAssertEqual(route, threadItem.route)
                return false
            },
            .routeRejected
        )
        XCTAssertTrue(try XCTUnwrap(fixture.threads.get(id: thread.id)).hasUnread)

        XCTAssertEqual(
            try fixture.store.openAndMarkRead(itemID: threadItem.id) { route in
                route == threadItem.route
            },
            .marked
        )
        XCTAssertFalse(try XCTUnwrap(fixture.threads.get(id: thread.id)).hasUnread)

        try fixture.callbacks.record(
            threadId: thread.id,
            request: AssistantPendingRequest(
                id: "approval-keep",
                turnId: nil,
                kind: .exec,
                title: "Raw command",
                createdAtMs: 200_000
            )
        )
        let callbackItem = try XCTUnwrap(fixture.store.refresh().items.first)
        XCTAssertEqual(
            try fixture.store.openAndMarkRead(itemID: callbackItem.id) { _ in true },
            .retainedBlocker
        )
        XCTAssertEqual(
            try fixture.callbacks.get(
                threadId: thread.id,
                requestId: "approval-keep",
                kind: .approval
            )?.state,
            .pending
        )

        try fixture.callbacks.markStale(
            threadId: thread.id,
            requestId: "approval-keep",
            kind: .approval,
            reason: "provider session ended"
        )
        let staleItem = try XCTUnwrap(fixture.store.refresh().items.first)
        XCTAssertEqual(
            try fixture.store.openAndMarkRead(itemID: staleItem.id) { _ in true },
            .marked,
            "Opening the exact recovery destination acknowledges a stale callback without invoking it."
        )
        XCTAssertEqual(
            try fixture.callbacks.get(
                threadId: thread.id,
                requestId: "approval-keep",
                kind: .approval
            )?.state,
            .acknowledged
        )
        XCTAssertTrue(try fixture.store.refresh().items.isEmpty)
    }

    func test_openAndMarkRead_preservesNotificationRouteMetadata() throws {
        let fixture = try fixture()
        let workspaceID = WorkspaceID(UUID())
        let surfaceID = SurfaceID(UUID())
        try fixture.notifications.insert(AppNotification(
            id: "ssh-1",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            title: "ignored",
            category: PetNotificationCategory.sshTransferFailed.rawValue,
            createdAt: Date(timeIntervalSince1970: 10)
        ))
        let item = try XCTUnwrap(fixture.store.refresh().items.first)

        XCTAssertEqual(item.route, .surface(surfaceID: surfaceID, workspaceID: workspaceID))
        XCTAssertEqual(
            try fixture.store.openAndMarkRead(itemID: item.id) { route in
                route == .surface(surfaceID: surfaceID, workspaceID: workspaceID)
            },
            .marked
        )
        XCTAssertTrue(try fixture.notifications.list(unreadOnly: true).isEmpty)
    }

    func test_gitNotificationsPreferExactSurfaceAndRetainLegacyWorkspaceRoute() throws {
        let fixture = try fixture()
        let workspaceID = WorkspaceID(UUID())
        let surfaceID = SurfaceID(UUID())
        try fixture.notifications.insert(AppNotification(
            id: "git-exact",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            title: "ignored",
            category: PetNotificationCategory.gitCompleted.rawValue,
            createdAt: Date(timeIntervalSince1970: 20)
        ))
        try fixture.notifications.insert(AppNotification(
            id: "git-legacy",
            workspaceId: workspaceID,
            title: "ignored",
            category: PetNotificationCategory.gitFailed.rawValue,
            createdAt: Date(timeIntervalSince1970: 10)
        ))

        let routes = Dictionary(uniqueKeysWithValues: try fixture.store.refresh().items.map {
            ($0.id, $0.route)
        })

        XCTAssertEqual(
            routes["notification:git-exact"],
            .surface(surfaceID: surfaceID, workspaceID: workspaceID)
        )
        XCTAssertEqual(
            routes["notification:git-legacy"],
            .workspace(workspaceID: workspaceID),
            "Persisted pre-surface Git rows must remain actionable after upgrading."
        )
    }

    func test_openAndMarkRead_retainsActionRequiredNotificationsUntilCanonicalResolution() throws {
        let fixture = try fixture()
        let workspaceID = WorkspaceID(UUID())
        let surfaceID = SurfaceID(UUID())
        for (id, category, surface) in [
            ("file-blocker", PetNotificationCategory.fileConflict, surfaceID),
            ("ssh-blocker", PetNotificationCategory.sshUnexpectedDisconnect, surfaceID),
            ("listener-blocker", PetNotificationCategory.serverListenerFailed, nil),
        ] {
            try fixture.notifications.insert(AppNotification(
                id: id,
                workspaceId: workspaceID,
                surfaceId: surface,
                title: "ignored",
                category: category.rawValue
            ))
        }

        for item in try fixture.store.refresh().items {
            XCTAssertEqual(item.classification, .needsYou)
            XCTAssertEqual(
                try fixture.store.openAndMarkRead(itemID: item.id) { _ in true },
                .retainedBlocker,
                "Opening an actionable destination must not acknowledge unresolved work."
            )
        }
        XCTAssertEqual(
            Set(try fixture.notifications.list(unreadOnly: true).map(\.id)),
            Set(["file-blocker", "ssh-blocker", "listener-blocker"])
        )
    }

    func test_settingsNotificationsUseTypedSettingsDestinationsWithoutFallback() throws {
        let fixture = try fixture()
        try fixture.notifications.insert(AppNotification(
            id: "provider-update",
            title: "unsafe provider output",
            category: PetNotificationCategory.providerUpdateFailed.rawValue,
            createdAt: Date(timeIntervalSince1970: 10)
        ))
        try fixture.notifications.insert(AppNotification(
            id: "listener-failure",
            title: "unsafe listener path",
            category: PetNotificationCategory.serverListenerFailed.rawValue,
            createdAt: Date(timeIntervalSince1970: 20)
        ))

        let routes = Dictionary(uniqueKeysWithValues: try fixture.store.refresh().items.map { ($0.id, $0.route) })
        XCTAssertEqual(routes["notification:provider-update"], .settings(.providers))
        XCTAssertEqual(routes["notification:listener-failure"], .settings(.general))
    }

    func test_operationNotificationsWithoutVerifiableDestinationAreNotProjectedOrBulkCleared() throws {
        let fixture = try fixture()
        for (id, category) in [
            ("git-missing-workspace", PetNotificationCategory.gitCompleted),
            ("project-missing-surface", PetNotificationCategory.projectScriptCompleted),
            ("ssh-missing-surface", PetNotificationCategory.sshTransferFailed),
            ("file-missing-destination", PetNotificationCategory.fileConflict),
        ] {
            try fixture.notifications.insert(AppNotification(
                id: id,
                title: "unsafe",
                category: category.rawValue
            ))
        }

        XCTAssertTrue(try fixture.store.refresh().items.isEmpty)
        XCTAssertEqual(try fixture.store.markAllRead(), 0)
        XCTAssertEqual(
            Set(try fixture.notifications.list(unreadOnly: true).map(\.id)),
            Set([
                "git-missing-workspace",
                "project-missing-surface",
                "ssh-missing-surface",
                "file-missing-destination",
            ])
        )
    }

    func test_markAllRead_marksOnlyProjectedOutcomesAndNeverTouchesCallbacks() throws {
        let fixture = try fixture()
        let workspaceID = WorkspaceID(UUID())
        let thread = thread(
            id: "66666666-6666-6666-6666-666666666666",
            workspaceID: workspaceID,
            status: .failed,
            updatedAt: 100
        )
        try fixture.threads.upsert(thread)
        try fixture.callbacks.record(
            threadId: thread.id,
            request: AssistantPendingRequest(
                id: "approval-bulk",
                turnId: nil,
                kind: .fileChange,
                title: "Apply private patch",
                createdAtMs: 100_000
            )
        )
        try fixture.notifications.insert(AppNotification(
            id: "pet-visible",
            workspaceId: workspaceID,
            title: "ignored",
            category: PetNotificationCategory.gitCompleted.rawValue
        ))
        try fixture.notifications.insert(AppNotification(
            id: "ordinary",
            title: "ordinary notification",
            category: "build.completed"
        ))
        try fixture.notifications.insert(AppNotification(
            id: "file-blocker",
            surfaceId: SurfaceID(UUID()),
            title: "ignored",
            category: PetNotificationCategory.fileConflict.rawValue
        ))
        try fixture.notifications.insert(AppNotification(
            id: "listener-blocker",
            title: "ignored",
            category: PetNotificationCategory.serverListenerFailed.rawValue
        ))
        try fixture.notifications.insert(AppNotification(
            id: "ssh-blocker",
            surfaceId: SurfaceID(UUID()),
            title: "ignored",
            category: PetNotificationCategory.sshUnexpectedDisconnect.rawValue
        ))

        XCTAssertEqual(try fixture.store.markAllRead(), 2)
        XCTAssertFalse(try XCTUnwrap(fixture.threads.get(id: thread.id)).hasUnread)
        XCTAssertEqual(
            try fixture.callbacks.get(
                threadId: thread.id,
                requestId: "approval-bulk",
                kind: .approval
            )?.state,
            .pending,
            "Bulk read must never masquerade as a provider callback resolution."
        )
        XCTAssertEqual(
            Set(try fixture.notifications.list(unreadOnly: true).map(\.id)),
            Set(["ordinary", "file-blocker", "listener-blocker", "ssh-blocker"]),
            "Bulk viewing must retain every action-required notification blocker."
        )
        XCTAssertEqual(try fixture.store.refresh().items.map(\.classification), [
            .needsYou, .needsYou, .needsYou, .needsYou,
        ])
    }

    func test_terminalRecorder_usesDeterministicIDsFixedCopyAndIdempotentPersistence() throws {
        let fixture = try fixture()
        let recorder = PetTerminalNotificationRecorder(repository: fixture.notifications)
        let workspaceID = WorkspaceID(UUID())
        let surfaceID = SurfaceID(UUID())
        let createdAt = Date(timeIntervalSince1970: 1_234)

        let first = try recorder.record(
            eventSequence: 42,
            kind: .sshTransfer(.failed),
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            createdAt: createdAt
        )
        let second = try recorder.record(
            eventSequence: 42,
            kind: .sshTransfer(.failed),
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            createdAt: createdAt
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.id, "pet.event.42")
        XCTAssertEqual(first.title, "SSH transfer failed")
        XCTAssertNil(first.body)
        XCTAssertEqual(first.category, PetNotificationCategory.sshTransferFailed.rawValue)
        XCTAssertEqual(try fixture.notifications.list().count, 1)

        try fixture.notifications.markRead(id: first.id)
        _ = try recorder.record(
            eventSequence: 42,
            kind: .sshTransfer(.failed),
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            createdAt: createdAt
        )
        XCTAssertTrue(
            try fixture.notifications.list(unreadOnly: true).isEmpty,
            "Replaying a stable event must not resurrect an acknowledged Pet row."
        )
    }

    func test_fileConflictRecorder_usesStableSafeRowAndResolutionNeverResurrectsIt() throws {
        let fixture = try fixture()
        let recorder = PetTerminalNotificationRecorder(repository: fixture.notifications)
        let workspaceID = WorkspaceID(UUID())
        let surfaceID = SurfaceID(UUID())
        let payload: [String: JSONValue] = [
            "workspace_id": .string(workspaceID.value.uuidString),
            "surface_id": .string(surfaceID.value.uuidString),
            "session_id": .string("edit-session-1"),
            "path": .string("private/secret.txt"),
            "content": .string("token=hunter2")
        ]
        let conflict = EventBus.Event(
            seq: 90,
            kind: "files.edit.conflict",
            payload: .object(payload),
            ts: 100
        )

        let recorded = try XCTUnwrap(recorder.record(event: conflict))
        XCTAssertEqual(recorded.id, "pet.file-conflict.edit-session-1")
        XCTAssertEqual(recorded.title, "File conflict needs review")
        XCTAssertNil(recorded.body)
        XCTAssertEqual(recorded.workspaceId, workspaceID)
        XCTAssertEqual(recorded.surfaceId, surfaceID)

        let saved = EventBus.Event(seq: 91, kind: "files.edit.saved", payload: .object(payload), ts: 101)
        XCTAssertNil(try recorder.record(event: saved))
        XCTAssertTrue(try fixture.notifications.list(unreadOnly: true).isEmpty)

        _ = try recorder.record(event: conflict, replaying: true)
        XCTAssertTrue(
            try fixture.notifications.list(unreadOnly: true).isEmpty,
            "A replayed conflict event must not resurrect its already resolved stable row."
        )

        let repeatedConflict = EventBus.Event(
            seq: 92,
            kind: "files.edit.conflict",
            payload: .object(payload),
            ts: 102
        )
        _ = try recorder.record(event: repeatedConflict)
        XCTAssertEqual(
            try fixture.notifications.list(unreadOnly: true).map(\.id),
            ["pet.file-conflict.edit-session-1"],
            "A new live conflict in the same edit session must reopen its stable blocker."
        )
    }

    func test_everyFileTerminalEventResolvesItsExactConflictIdentity() throws {
        for (index, terminalKind) in ["files.edit.saved", "files.edit.discarded", "files.edit.closed"].enumerated() {
            let fixture = try fixture()
            let recorder = PetTerminalNotificationRecorder(repository: fixture.notifications)
            let workspaceID = WorkspaceID(UUID())
            let surfaceID = SurfaceID(UUID())
            let sessionID = "edit-session-\(index)"
            let payload: [String: JSONValue] = [
                "workspace_id": .string(workspaceID.value.uuidString),
                "surface_id": .string(surfaceID.value.uuidString),
                "session_id": .string(sessionID),
                "path": .string("/Users/private/secret.txt"),
            ]
            _ = try recorder.record(event: EventBus.Event(
                seq: Int64(index * 2 + 1),
                kind: "files.edit.conflict",
                payload: .object(payload),
                ts: 100
            ))

            XCTAssertNil(try recorder.record(event: EventBus.Event(
                seq: Int64(index * 2 + 2),
                kind: terminalKind,
                payload: .object(payload),
                ts: 101
            )))
            XCTAssertTrue(
                try fixture.notifications.list(unreadOnly: true).isEmpty,
                "\(terminalKind) must resolve only the stable blocker for its session identity."
            )
        }
    }

    func test_unexpectedSSHDisconnectUsesStableSurfaceBlockerAndConnectedResolvesIt() throws {
        let fixture = try fixture()
        let recorder = PetTerminalNotificationRecorder(repository: fixture.notifications)
        let workspaceID = WorkspaceID(UUID())
        let surfaceID = SurfaceID(UUID())
        func event(_ sequence: Int64, status: String, reason: String? = nil) -> EventBus.Event {
            var payload: [String: JSONValue] = [
                "workspace_id": .string(workspaceID.value.uuidString),
                "surface_id": .string(surfaceID.value.uuidString),
                "status": .string(status),
                "destination": .string("private.example"),
                "path": .string("/Users/private/key"),
                "token": .string("secret-token"),
            ]
            if let reason { payload["reason"] = .string(reason) }
            return EventBus.Event(
                seq: sequence,
                kind: "ssh.session.updated",
                payload: .object(payload),
                ts: 500 + Double(sequence)
            )
        }

        let first = try XCTUnwrap(recorder.record(event: event(
            100,
            status: "disconnected",
            reason: "unexpected_child_exit"
        )))
        XCTAssertEqual(first.id, "pet.ssh-disconnect.\(surfaceID.value.uuidString)")
        XCTAssertEqual(first.category, PetNotificationCategory.sshUnexpectedDisconnect.rawValue)
        XCTAssertEqual(first.title, "SSH connection needs attention")
        XCTAssertNil(first.body)
        XCTAssertEqual(first.workspaceId, workspaceID)
        XCTAssertEqual(first.surfaceId, surfaceID)
        XCTAssertEqual(try fixture.store.refresh().items.first?.route, .surface(
            surfaceID: surfaceID,
            workspaceID: workspaceID
        ))

        _ = try recorder.record(event: event(101, status: "disconnected", reason: "unexpected_child_exit"))
        XCTAssertEqual(try fixture.notifications.list(unreadOnly: true).count, 1)
        XCTAssertNil(try recorder.record(event: event(102, status: "disconnected", reason: "user_requested")))
        XCTAssertTrue(
            try fixture.notifications.list(unreadOnly: true).isEmpty,
            "Explicit disconnect or surface close resolves an unrouteable SSH blocker."
        )

        _ = try recorder.record(event: event(102, status: "disconnected", reason: "unexpected_child_exit"))
        XCTAssertNil(try recorder.record(event: event(103, status: "connected")))
        XCTAssertTrue(try fixture.notifications.list(unreadOnly: true).isEmpty)

        _ = try recorder.record(event: event(104, status: "disconnected", reason: "connection_failed"))
        XCTAssertEqual(
            try fixture.notifications.list(unreadOnly: true).map(\.id),
            [first.id],
            "A later disconnect is a new unresolved state and must reopen the same stable surface blocker."
        )

        let visible = try fixture.store.refresh().items
            .flatMap { [$0.title, $0.detail].compactMap { $0 } }
            .joined(separator: " ")
        for secret in ["private.example", "/Users/private", "secret-token"] {
            XCTAssertFalse(visible.contains(secret))
        }
    }

    func test_terminalRecorder_decodesOnlySafeNonAgentTerminalEvents() throws {
        let fixture = try fixture()
        let recorder = PetTerminalNotificationRecorder(repository: fixture.notifications)
        let workspaceID = WorkspaceID(UUID())
        let surfaceID = SurfaceID(UUID())

        let git = EventBus.Event(
            seq: 9,
            kind: "git.deliver",
            payload: .object([
                "workspace_id": .string(workspaceID.value.uuidString),
                "surface_id": .string(surfaceID.value.uuidString),
                "ok": .bool(false),
                "branch": .string("secret/path"),
                "output": .string("token=private")
            ]),
            ts: 500
        )
        let recorded = try XCTUnwrap(try recorder.record(event: git))

        XCTAssertEqual(recorded.id, "pet.event.9")
        XCTAssertEqual(recorded.title, "Git delivery failed")
        XCTAssertNil(recorded.body)
        XCTAssertEqual(recorded.workspaceId, workspaceID)
        XCTAssertEqual(recorded.surfaceId, surfaceID)
        XCTAssertNil(try recorder.record(event: EventBus.Event(
            seq: 10,
            kind: "agent.run.finished",
            payload: .object(["status": .string("completed")]),
            ts: 501
        )), "Agent outcomes are owned by AgentThread.hasUnread and must not be duplicated.")
        XCTAssertNil(try recorder.record(event: EventBus.Event(
            seq: 11,
            kind: "agent.provider.updated",
            payload: .object(["ok": .bool(true), "stdout": .string("private")]),
            ts: 502
        )), "Successful provider updates do not require user attention.")
    }
}
