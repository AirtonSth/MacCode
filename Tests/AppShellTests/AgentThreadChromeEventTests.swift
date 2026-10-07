import XCTest
@testable import AppShell
import AgentRuntime
import CoreModel
import Persistence
import RemoteCodeTreaty
import SocketServer
import Surfaces

/// Narrow `agent_threads` writes (bot peer projections, bot-reply unread, the
/// surface's own start/fail stamps) used to commit without any `agent.*` state
/// event. Nothing advanced `domainRevisions.agentThreads`, so a reconnecting
/// iOS client sent its known revisions, got a partial snapshot without
/// `agentThreads`, and kept the stale status/unread badge until a full reload.
@MainActor
final class AgentThreadChromeEventTests: XCTestCase {
    private var root: URL!
    private var subscription: UUID?
    private let lock = NSLock()
    private var captured: [EventBus.Event] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-thread-chrome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: "bots.peerTurns.v2")
    }

    override func tearDownWithError() throws {
        if let subscription { EventBus.shared.unsubscribe(subscription) }
        UserDefaults.standard.removeObject(forKey: "bots.peerTurns.v2")
        try? FileManager.default.removeItem(at: root)
    }

    func test_botPeerProjectionStatusWrite_advancesAgentThreadsRevisionAndEmitsOneEvent() throws {
        let fixture = try makeRepos()
        let origin = try seedOriginThread(fixture.threadRepo)
        seedRestoredPeerHandoffs(originThreadID: origin.id, count: 1)
        let before = EventBus.shared.snapshotMetadata().domainRevisions.agentThreads
        startCapturing()

        // Restore reconciles the stranded peer leg to needsAttention, which
        // projects a failed status + unread onto the Agent App origin thread.
        let authority = makeAuthority(fixture)
        defer { withExtendedLifetime(authority) {} }

        let row = try XCTUnwrap(try fixture.threadRepo.get(id: origin.id))
        XCTAssertEqual(row.status, .failed, "fixture: the projection really wrote status")
        XCTAssertTrue(row.hasUnread, "fixture: the projection really wrote unread")

        let events = threadUpdatedEvents(for: origin.id)
        XCTAssertEqual(events.count, 1, "one committed projection write must publish exactly one event")
        let event = try XCTUnwrap(events.first)
        let payload = try XCTUnwrap(event.payload.objectValue)
        XCTAssertEqual(payload["status"]?.stringValue, AgentRunStatus.failed.rawValue)
        XCTAssertEqual(payload["has_unread"]?.boolValue, true)
        XCTAssertEqual(
            parseISO(payload["updated_at"]?.stringValue)?.timeIntervalSince1970 ?? 0,
            row.updatedAt.timeIntervalSince1970,
            accuracy: 0,
            "the event must carry the exact committed updated_at, not a client-side now"
        )

        let after = EventBus.shared.snapshotMetadata().domainRevisions.agentThreads
        XCTAssertGreaterThan(after, before)
        XCTAssertGreaterThanOrEqual(
            after, event.seq,
            "a reconnect with the pre-write revision must be told agentThreads changed"
        )
    }

    func test_restoreProjectingManyHandoffsOntoOneThread_publishesOnceAfterTheLastWrite() throws {
        let fixture = try makeRepos()
        let origin = try seedOriginThread(fixture.threadRepo)
        seedRestoredPeerHandoffs(originThreadID: origin.id, count: 3)
        let writesBefore = fixture.threadRepo.updateStatusCountForTesting
        startCapturing()

        let authority = makeAuthority(fixture)
        defer { withExtendedLifetime(authority) {} }

        XCTAssertEqual(
            fixture.threadRepo.updateStatusCountForTesting - writesBefore, 3,
            "fixture: every restored handoff committed its own status write"
        )
        let events = threadUpdatedEvents(for: origin.id)
        XCTAssertEqual(events.count, 1, "a restore loop must not storm one event per handoff")
        let payload = try XCTUnwrap(events.first?.payload.objectValue)
        let row = try XCTUnwrap(try fixture.threadRepo.get(id: origin.id))
        XCTAssertEqual(payload["status"]?.stringValue, row.status.rawValue)
        XCTAssertEqual(
            parseISO(payload["updated_at"]?.stringValue)?.timeIntervalSince1970 ?? 0,
            row.updatedAt.timeIntervalSince1970,
            accuracy: 0,
            "the coalesced event must describe the final committed row"
        )
    }

    func test_projectionOnSelectedThread_preservesUnreadAndOmitsItFromThePayload() throws {
        // A selected thread's terminal stamp must not clear unread on mirrors
        // either: the payload leaves has_unread out so iOS keeps its value.
        let fixture = try makeRepos()
        let origin = try seedOriginThread(fixture.threadRepo, hasUnread: true)
        let write = try XCTUnwrap(BotPeerHandoffAuthority.writeAgentAppProjectionChrome(
            threadRepo: fixture.threadRepo,
            threadID: origin.id,
            terminalStatus: .completed,
            markUnread: false
        ))
        let payload = try XCTUnwrap(write.eventPayload.objectValue)
        XCTAssertEqual(payload["status"]?.stringValue, AgentRunStatus.completed.rawValue)
        XCTAssertNil(payload["has_unread"])
        XCTAssertNil(payload["hasUnread"])
        XCTAssertEqual(try fixture.threadRepo.get(id: origin.id)?.hasUnread, true)
    }

    func test_alreadyUnreadThreadWithoutTerminalStatus_writesNothingAndPublishesNothing() throws {
        let fixture = try makeRepos()
        let origin = try seedOriginThread(fixture.threadRepo, hasUnread: true)
        XCTAssertNil(try BotPeerHandoffAuthority.writeAgentAppProjectionChrome(
            threadRepo: fixture.threadRepo,
            threadID: origin.id,
            terminalStatus: nil,
            markUnread: true
        ), "no commit means no event")
    }

    func test_restoreBeforeTheEventLogIsWired_holdsThenPersistsOneEventAboveTheDurableHead() async throws {
        // App launch builds the authority (via `context.router`) before the
        // event log is wired and reloaded. An event published then gets a seq
        // the reload discards, is never persisted, and reaches no client.
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path
        )
        let durableHead: Int64 = 40
        try ctx.eventLog.append(seq: durableHead, kind: "test.seed", payloadJSON: "{}")
        let origin = try seedOriginThread(ctx.threadRepo)
        seedRestoredPeerHandoffs(originThreadID: origin.id, count: 2)
        let bus = EventBus()
        let delivered = DeliveredEvents()
        _ = bus.subscribeFromCurrent(filter: .agentThreadAndQueue) { delivered.append($0) }

        let authority = makeAuthority(
            Repos(db: ctx.db, threadRepo: ctx.threadRepo),
            eventBus: bus,
            holdsThreadChromeUntilEventLogReady: true
        )
        defer { withExtendedLifetime(authority) {} }
        XCTAssertEqual(try ctx.threadRepo.status(of: origin.id), .failed, "fixture: restore committed chrome")
        XCTAssertTrue(delivered.events.isEmpty, "nothing may publish before the event log is ready")
        XCTAssertEqual(bus.currentSeq, 0)

        // Same order as AppDelegate: wire, reload to the durable head, flush.
        AppDelegate.wireEventPersistence(context: ctx, eventBus: bus)
        bus.reloadFromPersistence(lastSeq: try ctx.eventLog.lastSeq(), recent: [])
        authority.publishRestoredThreadChrome()
        authority.publishRestoredThreadChrome()

        let events = delivered.events.filter { $0.payload.objectValue?["thread_id"]?.stringValue == origin.id.value.uuidString }
        XCTAssertEqual(events.count, 1, "one event per restored thread, and a second flush publishes nothing")
        let event = try XCTUnwrap(events.first)
        XCTAssertGreaterThan(event.seq, durableHead, "the restored event must sort after the durable head")
        XCTAssertGreaterThanOrEqual(bus.snapshotMetadata().domainRevisions.agentThreads, event.seq)

        let deadline = Date().addingTimeInterval(5)
        var persisted: [EventLogRepository.Row] = []
        while Date() < deadline {
            persisted = try ctx.eventLog.read(since: durableHead).filter {
                $0.kind == RemoteCodeEventKind.agentThreadUpdated.rawValue
            }
            if !persisted.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(persisted.map(\.seq), [event.seq], "the restored event must reach the event log for C8 replay")
    }

    func test_newRunCursorAfterRunStarted_publishesOneCursorEventWithTheStoredUpdatedAt() throws {
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path
        )
        let origin = try seedOriginThread(ctx.threadRepo)
        let runID = AgentRunID()
        startCapturing(filter: .kindPrefixes(["agent.thread.", "agent.run."]))

        ctx.coordinator.onRunStarted?(origin.id, runID)
        // The coordinator commits the cursor before it forwards `.threadStarted`.
        let cursorAt = Date(timeIntervalSince1970: 5_000)
        try ctx.threadRepo.updateProviderThreadId(id: origin.id, providerThreadId: "cursor-1", at: cursorAt)
        ctx.coordinator.onAssistantEvent?(
            .threadStarted(threadId: "cursor-1", providerThreadId: nil), origin.id, runID
        )

        XCTAssertEqual(runStartedEvents(for: origin.id).count, 1, "run.started stays deduplicated")
        let events = threadUpdatedEvents(for: origin.id)
        XCTAssertEqual(events.count, 1, "the cursor commit after run.started must be mirrored once")
        let payload = try XCTUnwrap(events.first?.payload.objectValue)
        XCTAssertEqual(payload["provider_thread_id"]?.stringValue, "cursor-1")
        XCTAssertNil(payload["status"], "a cursor write must not claim a status")
        XCTAssertEqual(
            parseISO(payload["updated_at"]?.stringValue)?.timeIntervalSince1970 ?? 0,
            cursorAt.timeIntervalSince1970,
            accuracy: 0
        )
    }

    func test_resumeOnlyThreadStarted_publishesRunStartedAndNoChromeEvent() throws {
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path
        )
        let origin = try seedOriginThread(ctx.threadRepo)
        let runID = AgentRunID()
        startCapturing(filter: .kindPrefixes(["agent.thread.", "agent.run."]))

        try ctx.threadRepo.updateProviderThreadId(id: origin.id, providerThreadId: "resumed", at: Date())
        ctx.coordinator.onAssistantEvent?(
            .threadStarted(threadId: "resumed", providerThreadId: nil), origin.id, runID
        )

        XCTAssertEqual(runStartedEvents(for: origin.id).count, 1, "resume paths only emit .threadStarted")
        XCTAssertTrue(threadUpdatedEvents(for: origin.id).isEmpty, "run.started already covers this commit")
    }

    func test_cursorThatDidNotLand_publishesNoChromeEvent() throws {
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path
        )
        let origin = try seedOriginThread(ctx.threadRepo)
        let runID = AgentRunID()
        startCapturing(filter: .kindPrefixes(["agent.thread.", "agent.run."]))

        ctx.coordinator.onRunStarted?(origin.id, runID)
        // No cursor write: the coordinator's update failed.
        ctx.coordinator.onAssistantEvent?(
            .threadStarted(threadId: "never-stored", providerThreadId: nil), origin.id, runID
        )

        XCTAssertTrue(threadUpdatedEvents(for: origin.id).isEmpty)
    }

    // MARK: - Fixtures

    private struct Repos {
        let db: SQLiteDB
        let threadRepo: AgentThreadRepository
    }

    private func makeRepos() throws -> Repos {
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root.path).run()
        return Repos(db: db, threadRepo: AgentThreadRepository(db: db))
    }

    private func makeAuthority(
        _ repos: Repos,
        eventBus: EventBus = .shared,
        holdsThreadChromeUntilEventLogReady: Bool = false
    ) -> BotPeerHandoffAuthority {
        let runRepo = AgentRunRepository(db: repos.db)
        let messageRepo = AgentMessageRepository(db: repos.db)
        let checkpointRepo = AgentTurnCheckpointRepository(db: repos.db)
        return BotPeerHandoffAuthority(
            botStore: BotStore(db: repos.db),
            threadRepo: repos.threadRepo,
            runRepo: runRepo,
            messageRepo: messageRepo,
            queuedMessageRepo: AgentQueuedMessageRepository(db: repos.db),
            checkpointRepo: checkpointRepo,
            settingsRepo: SettingsRepository(db: repos.db),
            coordinator: AgentRunCoordinator(
                runRepo: runRepo,
                messageRepo: messageRepo,
                threadRepo: repos.threadRepo,
                checkpointRepo: checkpointRepo,
                providers: [:]
            ),
            appSupportDirectory: root,
            eventBus: eventBus,
            holdsThreadChromeUntilEventLogReady: holdsThreadChromeUntilEventLogReady
        )
    }

    private func seedOriginThread(
        _ threadRepo: AgentThreadRepository,
        hasUnread: Bool = false
    ) throws -> AgentThread {
        var thread = AgentThread(
            title: "Agent App origin",
            provider: .codex,
            model: "fake-model",
            status: .running
        )
        thread.hasUnread = hasUnread
        thread.updatedAt = Date(timeIntervalSince1970: 1_000)
        try threadRepo.upsert(thread)
        return thread
    }

    /// Restored peer legs that never got a peer run: reconcile settles each to
    /// needsAttention and, with no host continuation, projects `.failed`.
    private func seedRestoredPeerHandoffs(originThreadID: AgentThreadID, count: Int) {
        let route = RouteFixture(
            provider: .claude,
            model: "fake-model",
            runAsUser: AgentRunAsUser(
                generatedUID: "chrome-event-fixture",
                shortName: "fixture",
                uid: 0,
                gid: 0,
                homePath: "/tmp/chrome-event-fixture"
            )
        )
        var rows: [UUID: HandoffFixture] = [:]
        for index in 0..<count {
            let activityID = UUID()
            rows[activityID] = HandoffFixture(
                version: 2,
                activityID: activityID,
                originAgentThreadID: originThreadID,
                peerBotID: BotID(),
                peerConversationID: BotConversationID(),
                inboundMessageID: activityID,
                peerName: "Quinn \(index)",
                peerTitle: "CRM Controller",
                peerHandle: "quinn-\(index)",
                outboundText: "stranded peer leg \(index)",
                createdAt: Date(timeIntervalSince1970: 2_000 + Double(index)),
                peerRoute: route,
                hostContinuationRequired: false,
                phase: .peerRunning
            )
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(rows), forKey: "bots.peerTurns.v2")
    }

    private func startCapturing(filter: EventStreamFilter = .agentThreadAndQueue) {
        subscription = EventBus.shared.subscribeFromCurrent(filter: filter) { [weak self] event in
            guard let self else { return }
            self.lock.lock()
            self.captured.append(event)
            self.lock.unlock()
        }.id
    }

    private func threadUpdatedEvents(for threadID: AgentThreadID) -> [EventBus.Event] {
        lock.lock()
        defer { lock.unlock() }
        return captured.filter {
            $0.kind == RemoteCodeEventKind.agentThreadUpdated.rawValue
                && $0.payload.objectValue?["thread_id"]?.stringValue == threadID.value.uuidString
        }
    }

    private func runStartedEvents(for threadID: AgentThreadID) -> [EventBus.Event] {
        lock.lock()
        defer { lock.unlock() }
        return captured.filter {
            $0.kind == RemoteCodeEventKind.agentRunStarted.rawValue
                && $0.payload.objectValue?["thread_id"]?.stringValue == threadID.value.uuidString.lowercased()
        }
    }

    private func parseISO(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }
}

private final class DeliveredEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [EventBus.Event] = []
    var events: [EventBus.Event] { lock.withLock { storage } }
    func append(_ event: EventBus.Event) { lock.withLock { storage.append(event) } }
}

private struct RouteFixture: Codable {
    let provider: AgentProvider
    let model: String
    let runAsUser: AgentRunAsUser
}

private struct HandoffFixture: Codable {
    let version: Int
    let activityID: UUID
    let originAgentThreadID: AgentThreadID
    let peerBotID: BotID
    let peerConversationID: BotConversationID
    let inboundMessageID: UUID
    let peerName: String
    let peerTitle: String
    let peerHandle: String
    let outboundText: String
    let createdAt: Date
    let peerRoute: RouteFixture
    let hostContinuationRequired: Bool
    let phase: BotPeerHandoffPhase
}
