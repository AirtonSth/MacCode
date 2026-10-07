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

    // MARK: - Fixtures

    private struct Repos {
        let db: SQLiteDB
        let threadRepo: AgentThreadRepository
    }

    private func makeRepos() throws -> Repos {
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root.path).run()
        return Repos(db: db, threadRepo: AgentThreadRepository(db: db))
    }

    private func makeAuthority(_ repos: Repos) -> BotPeerHandoffAuthority {
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
            appSupportDirectory: root
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

    private func startCapturing() {
        subscription = EventBus.shared.subscribeFromCurrent(filter: .agentThreadAndQueue) { [weak self] event in
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

    private func parseISO(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }
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
