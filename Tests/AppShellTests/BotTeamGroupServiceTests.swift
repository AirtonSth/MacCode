import XCTest
import AgentRuntime
import CoreModel
import RemoteCodeTreaty
@testable import SocketServer
@testable import AppShell
@testable import Persistence

/// WHY: teams and group rooms must behave the same from the Mac and from a
/// paired iPhone. Every change must reach the other side as an event, a
/// refused request must change nothing and be answered as refused (not as
/// "couldn't confirm"), a retried send must never post twice, and a stale
/// edit must never overwrite a newer one.
@MainActor
final class BotTeamGroupServiceTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    private struct Fixture {
        let ctx: AppContext
        let router: AppCommandRouter
        let runner: ControlledBotHandoffRunner
        let ana: BotDefinition
        let bob: BotDefinition
        @MainActor var service: BotTeamGroupService { ctx.botTeamGroupService }
    }

    private func makeFixture() throws -> Fixture {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2BotTeamGroup-\(UUID().uuidString)", isDirectory: true).path
        let ctx = try AppContext(channel: .debug, appSupportOverride: support)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = ControlledBotHandoffRunner(provider: .codex)
        ctx.coordinator.replaceProviderAdapter(.codex, adapter: TerminalRetiringOneShotAdapter(runner: runner))
        let model = BotsViewModel.defaultModel(for: .codex)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex,
                models: [AgentModelDescriptor(id: model, label: model, provider: .codex)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "codex"
            )
        ])
        ctx.botGroupOrchestrator.vmPreflight = { _ in nil }
        let ana = try ctx.botStore.create(name: "Ana", title: "Writer", description: "", handle: "ana", soul: "ANA-SOUL")
        let bob = try ctx.botStore.create(name: "Bob", title: "Critic", description: "", handle: "bob", soul: "BOB-SOUL")
        return Fixture(ctx: ctx, router: router, runner: runner, ana: ana, bob: bob)
    }

    // MARK: - Helpers

    private func key(_ uuid: UUID) -> JSONValue { .string(uuid.uuidString.lowercased()) }

    private func rpc(_ f: Fixture, _ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        var params = params
        params["client_request_id"] = .string(UUID().uuidString)
        return try await f.router.dispatchPairedBotRemote(method: method, params: params)
    }

    /// The refusal a remote caller gets, or nil when the call succeeded.
    private func refusal(_ f: Fixture, _ method: String, _ params: [String: JSONValue]) async -> JSONRPCError? {
        do {
            _ = try await rpc(f, method, params)
            return nil
        } catch let rejection as DefiniteMutationRejection {
            return rejection.underlying as? JSONRPCError
        } catch {
            XCTFail("\(method) failed without a definite rejection: \(error)")
            return nil
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func waitUntil(timeout: TimeInterval = 6, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(kind: String, payload: [String: JSONValue])] = []
        func append(_ kind: String, _ payload: [String: JSONValue]) { lock.withLock { stored.append((kind, payload)) } }
        func changes(_ kind: String, id key: String, _ value: String) -> [String] {
            lock.withLock {
                stored.filter { $0.kind == kind && $0.payload[key]?.stringValue == value }
                    .compactMap { $0.payload["change"]?.stringValue }
            }
        }
        func payloads(_ kind: String) -> [[String: JSONValue]] {
            lock.withLock { stored.filter { $0.kind == kind }.map(\.payload) }
        }
    }

    private func recordEvents() -> (EventLog, UUID) {
        let log = EventLog()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard ["bot.team.updated", "bot.group.updated", "bot.group.turn.updated"].contains(event.kind),
                  let object = event.payload.objectValue else { return }
            log.append(event.kind, object)
        }
        return (log, subscription)
    }

    private func createGroup(_ f: Fixture, bots: [BotDefinition], extra: [String: JSONValue] = [:]) async throws -> BotGroupRow {
        var params: [String: JSONValue] = [
            "title": .string("Launch room"),
            "participant_bot_ids": .array(bots.map { key($0.id.value) }),
        ]
        for (name, value) in extra { params[name] = value }
        return try decode(BotGroupCreate.Result.self, try await rpc(f, "bot.group.create", params)).readback.group
    }

    private func groupAttentionItems(_ f: Fixture) async throws -> [[String: JSONValue]] {
        let listed = try await f.router.dispatchPairedBotRemote(method: "bot.attention.list", params: [:])
        return (listed.objectValue?["items"]?.arrayValue ?? [])
            .compactMap(\.objectValue)
            .filter { $0["kind"]?.stringValue == "group" }
    }

    // MARK: - Teams

    func test_teamRPCsEditManyToManyTeamsWithEventsAndRejectStaleRevisions() async throws {
        let f = try makeFixture()
        let (log, subscription) = recordEvents()
        defer { EventBus.shared.unsubscribe(subscription) }

        let writers = try decode(BotTeamCreate.Result.self, try await rpc(f, "bot.team.create", [
            "name": .string("Writers"),
            "member_bot_ids": .array([key(f.ana.id.value), key(f.bob.id.value)]),
        ])).readback.team
        XCTAssertEqual(writers.memberBotIDs, [f.ana.id.value.uuidString.lowercased(), f.bob.id.value.uuidString.lowercased()])
        XCTAssertEqual(writers.revision, 1)
        let reviewers = try decode(BotTeamCreate.Result.self, try await rpc(f, "bot.team.create", [
            "name": .string("Reviewers"),
            "member_bot_ids": .array([key(f.ana.id.value)]),
        ])).readback.team
        XCTAssertEqual(log.changes("bot.team.updated", id: "team_id", writers.id), ["created"],
                       "a team made on either side reaches the other")

        // Many-to-many: Ana is listed under both teams.
        let listed = try decode(BotTeamList.Result.self, try await rpc(f, "bot.team.list", [:])).teams
        XCTAssertEqual(listed.map(\.id), [writers.id, reviewers.id])
        XCTAssertTrue(listed.allSatisfy { $0.memberBotIDs.contains(f.ana.id.value.uuidString.lowercased()) })

        // A stale editor (A) loses to the newer edit (B) and changes nothing.
        let renamed = try decode(BotTeamUpdate.Result.self, try await rpc(f, "bot.team.update", [
            "team_id": .string(writers.id), "expected_revision": .number(1), "name": .string("Authors"),
        ])).readback.team
        XCTAssertEqual(renamed.name, "Authors")
        XCTAssertEqual(renamed.revision, 2)
        let stale = await refusal(f, "bot.team.set_members", [
            "team_id": .string(writers.id), "expected_revision": .number(1), "bot_ids": .array([]),
        ])
        XCTAssertEqual(stale?.code, BotTeamGroupService.revisionConflictCode)
        XCTAssertEqual(try f.ctx.botStore.listTeamMembers(teamID: BotTeamID(UUID(uuidString: writers.id)!)).count, 2)

        let emptied = try decode(BotTeamSetMembers.Result.self, try await rpc(f, "bot.team.set_members", [
            "team_id": .string(writers.id), "expected_revision": .number(2), "bot_ids": .array([]),
        ])).readback.team
        XCTAssertEqual(emptied.memberBotIDs, [])

        let reordered = try decode(BotTeamReorder.Result.self, try await rpc(f, "bot.team.reorder", [
            "team_ids": .array([.string(reviewers.id), .string(writers.id)]),
        ])).readback.teams
        XCTAssertEqual(reordered.map(\.id), [reviewers.id, writers.id])

        let deleted = try decode(BotTeamDelete.Result.self, try await rpc(f, "bot.team.delete", ["team_id": .string(writers.id)]))
        XCTAssertTrue(deleted.readback.deleted)
        XCTAssertEqual(try f.ctx.botStore.listTeams().map(\.name), ["Reviewers"])
        XCTAssertNotNil(try f.ctx.botStore.get(id: f.ana.id), "deleting a team never deletes its bots")
        XCTAssertEqual(
            log.changes("bot.team.updated", id: "team_id", writers.id),
            ["created", "updated", "members", "deleted"]
        )
        let gone = await refusal(f, "bot.team.delete", ["team_id": .string(writers.id)])
        XCTAssertEqual(gone?.code, BotTeamGroupService.notFoundCode)
    }

    /// The iPhone's retry after a lost response reuses its client_request_id:
    /// the ledger must answer with the first result and not make a second team.
    func test_remoteTeamCreateReplaysByRequestIDAndPublishesOnce() async throws {
        let f = try makeFixture()
        let (log, subscription) = recordEvents()
        defer { EventBus.shared.unsubscribe(subscription) }
        let dispatcher = JSONRPCDispatcher(router: f.router)
        let context = MutationRequestContext(ownerFingerprint: "owner-teams", hostId: "host-teams", bootEpoch: 1)
        let params: [String: JSONValue] = [
            "client_request_id": .string("team-create-1"),
            "connection_id": .string("conn"),
            "expected_host_id": .string("host-teams"),
            "expected_boot_epoch": .number(1),
            "name": .string("Writers"),
        ]
        let request = JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "bot.team.create", params: params)

        let first = await dispatcher.dispatch(request, mutationContext: context)
        let retry = await dispatcher.dispatch(request, mutationContext: context)

        XCTAssertNil(first.error)
        let firstTeam = try decode(BotTeamCreate.Result.self, try XCTUnwrap(first.result)).readback.team
        let retryTeam = try decode(BotTeamCreate.Result.self, try XCTUnwrap(retry.result)).readback.team
        XCTAssertEqual(retryTeam.id, firstTeam.id)
        XCTAssertEqual(try f.ctx.botStore.listTeams().count, 1, "no second team")
        let published = await waitUntil { log.changes("bot.team.updated", id: "team_id", firstTeam.id) == ["created"] }
        XCTAssertTrue(published, "the service event is committed with the receipt, once")
        XCTAssertEqual(
            try decode(BotTeamCreate.Result.self, try XCTUnwrap(first.result)).requestID,
            "team-create-1"
        )
    }

    // MARK: - Group send: immediate, eventual, replay

    func test_remoteGroupSendAcknowledgesAtOnceReplaysBySubmitKeyAndSettlesWithAttention() async throws {
        let f = try makeFixture()
        let (log, subscription) = recordEvents()
        defer { EventBus.shared.unsubscribe(subscription) }
        let group = try await createGroup(f, bots: [f.ana, f.bob])
        XCTAssertEqual(group.participants.map(\.botID), [f.ana, f.bob].map { $0.id.value.uuidString.lowercased() })
        XCTAssertEqual(group.policy, "roundtable")
        XCTAssertEqual(log.changes("bot.group.updated", id: "group_id", group.id), ["created"])
        let room = AgentThreadID(UUID(uuidString: group.roomThreadID)!)

        let started = Date()
        let sent = try decode(BotGroupSend.Result.self, try await rpc(f, "bot.group.send", [
            "group_id": .string(group.id), "text": .string("Plan the launch"), "submit_key": .string("k1"),
        ]))
        let acknowledged = Date().timeIntervalSince(started)

        // Immediate: the user row and one waiting row per bot, before any run.
        XCTAssertLessThan(acknowledged, 0.1, "user row plus waiting rows within 100 ms")
        let rows = try f.ctx.messageRepo.list(threadId: room)
        XCTAssertEqual(rows.map(\.role), [.user, .assistant, .assistant])
        XCTAssertEqual(rows.first?.id.value.uuidString.lowercased(), sent.readback.userMessageID)
        XCTAssertEqual(rows.dropFirst().map { $0.id.value.uuidString.lowercased() },
                       sent.readback.turns.map(\.roomMessageID))
        XCTAssertEqual(sent.readback.turns.map(\.state), ["planned", "planned"])

        // A retry with a new request id but the same submit key posts nothing.
        let replay = try decode(BotGroupSend.Result.self, try await rpc(f, "bot.group.send", [
            "group_id": .string(group.id), "text": .string("Plan the launch"), "submit_key": .string("k1"),
        ]))
        XCTAssertEqual(replay.readback.roundID, sent.readback.roundID)
        XCTAssertEqual(replay.readback.userMessageID, sent.readback.userMessageID)
        XCTAssertEqual(try f.ctx.messageRepo.list(threadId: room).count, 3)

        // Eventual exact completion.
        let anaStarted = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(anaStarted)
        XCTAssertTrue(f.runner.finish(runID: f.runner.requests[0].runId, status: .completed, reply: "Monday."))
        let bobStarted = await waitUntil { f.runner.requests.count == 2 }
        XCTAssertTrue(bobStarted)
        XCTAssertTrue(f.runner.finish(runID: f.runner.requests[1].runId, status: .completed, reply: "Too soon."))
        let groupID = BotGroupID(UUID(uuidString: group.id)!)
        let settled = await waitUntil {
            (try? f.ctx.botStore.listGroupTurns(groupID: groupID).allSatisfy { $0.state == .completed }) == true
        }
        XCTAssertTrue(settled)
        f.service.flushAttention()

        let detail = try decode(BotGroupGet.Result.self, try await rpc(f, "bot.group.get", ["group_id": .string(group.id)]))
        XCTAssertEqual(detail.turns.map(\.state), ["completed", "completed"])
        XCTAssertEqual(detail.group.attentionState, "unread_activity")
        XCTAssertTrue(detail.group.unread)
        XCTAssertTrue(detail.group.participants.allSatisfy { $0.memberThreadID != nil },
                      "each bot answered on its own private thread")
        let inbox = try await groupAttentionItems(f)
        XCTAssertEqual(inbox.map { $0["state"]?.stringValue }, ["finished"])
        XCTAssertEqual(inbox.first?["group_id"]?.stringValue, group.id)

        let selected = try decode(BotGroupSelect.Result.self, try await rpc(f, "bot.group.select", ["group_id": .string(group.id)]))
        XCTAssertEqual(selected.readback.group.attentionState, "none")
        XCTAssertFalse(selected.readback.group.unread)
        let cleared = try await groupAttentionItems(f)
        XCTAssertTrue(cleared.isEmpty)
        let changes = log.changes("bot.group.updated", id: "group_id", group.id)
        XCTAssertTrue(changes.contains("attention"))
        XCTAssertEqual(changes.last, "selected")
    }

    func test_refusedSendsWriteNothingAndAreAnsweredAsRefusals() async throws {
        let f = try makeFixture()
        let group = try await createGroup(f, bots: [f.ana], extra: ["policy": .string("mentions_only")])
        let room = AgentThreadID(UUID(uuidString: group.roomThreadID)!)

        let attachment = await refusal(f, "bot.group.send", [
            "group_id": .string(group.id), "text": .string("@ana look"), "submit_key": .string("k1"),
            "attachment_ids": .array([.string("a1")]),
        ])
        XCTAssertEqual(attachment?.code, -32602)
        XCTAssertEqual(attachment?.message, "Attachments are not supported in group conversations yet.")
        let noMention = await refusal(f, "bot.group.send", [
            "group_id": .string(group.id), "text": .string("anyone?"), "submit_key": .string("k2"),
        ])
        XCTAssertEqual(noMention?.code, -32602)
        let missing = await refusal(f, "bot.group.send", [
            "group_id": .string(UUID().uuidString), "text": .string("hi"), "submit_key": .string("k3"),
        ])
        XCTAssertEqual(missing?.code, BotTeamGroupService.notFoundCode)
        XCTAssertTrue(try f.ctx.messageRepo.list(threadId: room).isEmpty)
        XCTAssertTrue(try f.ctx.botStore.listGroupTurns(groupID: BotGroupID(UUID(uuidString: group.id)!)).isEmpty)

        // Through the receipt ledger: a refusal frees the request id.
        let dispatcher = JSONRPCDispatcher(router: f.router)
        let context = MutationRequestContext(ownerFingerprint: "owner-send", hostId: "host-send", bootEpoch: 1)
        let response = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "bot.group.send",
            params: [
                "client_request_id": .string("send-refused"), "connection_id": .string("conn"),
                "expected_host_id": .string("host-send"), "expected_boot_epoch": .number(1),
                "group_id": .string(group.id), "text": .string("anyone?"), "submit_key": .string("k4"),
            ]
        ), mutationContext: context)
        XCTAssertEqual(response.error?.code, -32602)
        XCTAssertEqual(
            try f.ctx.commandReceiptRepo.status(
                method: "bot.group.send", clientRequestId: "send-refused", ownerFingerprint: "owner-send"
            ),
            .absent,
            "never a permanent 'couldn't confirm'"
        )
    }

    // MARK: - Failure, retry, stop, participants, delete

    func test_failedTurnNeedsAttentionAndRetryRunsItAgainInPlace() async throws {
        let f = try makeFixture()
        let group = try await createGroup(f, bots: [f.ana])
        let sent = try decode(BotGroupSend.Result.self, try await rpc(f, "bot.group.send", [
            "group_id": .string(group.id), "text": .string("Draft it"), "submit_key": .string("k1"),
        ]))
        let turnID = BotGroupTurnID(UUID(uuidString: sent.readback.turns[0].turnID)!)
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started)
        f.runner.finish(runID: f.runner.requests[0].runId, status: .failed, reply: nil)
        let failed = await waitUntil { (try? f.ctx.botStore.groupTurn(id: turnID)?.state) == .failed }
        XCTAssertTrue(failed)
        f.service.flushAttention()
        let items = try await groupAttentionItems(f)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item["state"]?.stringValue, "needs_attention")
        XCTAssertEqual(item["turn_id"]?.stringValue, sent.readback.turns[0].turnID)

        let retried = try decode(BotGroupRetryTurn.Result.self, try await rpc(f, "bot.group.retry_turn", [
            "group_id": .string(group.id), "turn_id": .string(sent.readback.turns[0].turnID),
        ]))
        XCTAssertEqual(retried.readback.turn.state, "planned")
        XCTAssertNil(retried.readback.turn.error)
        let row = try XCTUnwrap(try f.ctx.messageRepo.get(id: AgentMessageID(UUID(uuidString: sent.readback.turns[0].roomMessageID)!)))
        XCTAssertEqual(BotPeerTranscript.parseActivity(row.content)?.phase, .waiting, "the same row waits again")

        let again = await waitUntil { f.runner.requests.count == 2 }
        XCTAssertTrue(again, "the retried turn runs")
        f.runner.finish(runID: f.runner.requests[1].runId, status: .completed, reply: "Here it is.")
        let completed = await waitUntil { (try? f.ctx.botStore.groupTurn(id: turnID)?.state) == .completed }
        XCTAssertTrue(completed)
        let reply = try XCTUnwrap(try f.ctx.messageRepo.get(id: row.id))
        XCTAssertEqual(BotPeerTranscript.parse(reply.content)?.body, "Here it is.")

        let refused = await refusal(f, "bot.group.retry_turn", [
            "group_id": .string(group.id), "turn_id": .string(sent.readback.turns[0].turnID),
        ])
        XCTAssertEqual(refused?.code, -32602, "a completed turn is never re-run")
        XCTAssertEqual(f.runner.requests.count, 2)
    }

    func test_removingAParticipantSettlesItsWaitingRowAndStopReturnsCancelledTurns() async throws {
        let f = try makeFixture()
        let (log, subscription) = recordEvents()
        defer { EventBus.shared.unsubscribe(subscription) }
        let group = try await createGroup(f, bots: [f.ana, f.bob])
        let sent = try decode(BotGroupSend.Result.self, try await rpc(f, "bot.group.send", [
            "group_id": .string(group.id), "text": .string("Go"), "submit_key": .string("k1"),
        ]))
        let anaRunning = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(anaRunning)
        let bobTurn = sent.readback.turns[1]

        let edited = try decode(BotGroupSetParticipants.Result.self, try await rpc(f, "bot.group.set_participants", [
            "group_id": .string(group.id),
            "expected_revision": .number(Double(group.revision)),
            "bot_ids": .array([key(f.ana.id.value)]),
        ])).readback.group
        XCTAssertEqual(edited.participants.filter { $0.leftAt == nil }.map(\.botID), [f.ana.id.value.uuidString.lowercased()])
        XCTAssertEqual(try f.ctx.botStore.groupTurn(id: BotGroupTurnID(UUID(uuidString: bobTurn.turnID)!))?.state, .cancelled)
        let bobRow = try XCTUnwrap(try f.ctx.messageRepo.get(id: AgentMessageID(UUID(uuidString: bobTurn.roomMessageID)!)))
        XCTAssertTrue(bobRow.content.contains(BotGroupOrchestrator.removedNote), "the waiting row never spins forever")
        let bobStates = log.payloads("bot.group.turn.updated")
            .filter { $0["turn_id"]?.stringValue == bobTurn.turnID }
            .compactMap { $0["state"]?.stringValue }
        XCTAssertEqual(bobStates.last, "cancelled")
        XCTAssertTrue(log.changes("bot.group.updated", id: "group_id", group.id).contains("participants"))

        let stopped = try decode(BotGroupStop.Result.self, try await rpc(f, "bot.group.stop", ["group_id": .string(group.id)]))
        XCTAssertEqual(stopped.readback.turns.map(\.turnID), [sent.readback.turns[0].turnID])
        XCTAssertEqual(stopped.readback.turns.map(\.state), ["cancelled"])
    }

    func test_deleteGroupRemovesItsRoomAndPrivateThreadsAndPublishes() async throws {
        let f = try makeFixture()
        let (log, subscription) = recordEvents()
        defer { EventBus.shared.unsubscribe(subscription) }
        let group = try await createGroup(f, bots: [f.ana])
        _ = try await rpc(f, "bot.group.send", [
            "group_id": .string(group.id), "text": .string("Hi"), "submit_key": .string("k1"),
        ])
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started)
        let memberThread = f.runner.requests[0].threadId
        let room = AgentThreadID(UUID(uuidString: group.roomThreadID)!)
        f.runner.finish(runID: f.runner.requests[0].runId, status: .completed, reply: "Hello.")
        let groupID = BotGroupID(UUID(uuidString: group.id)!)
        let answered = await waitUntil {
            (try? f.ctx.botStore.listGroupTurns(groupID: groupID).first?.state) == .completed
        }
        XCTAssertTrue(answered)

        let deleted = try decode(BotGroupDelete.Result.self, try await rpc(f, "bot.group.delete", ["group_id": .string(group.id)]))
        XCTAssertTrue(deleted.readback.deleted)
        XCTAssertNil(try f.ctx.threadRepo.get(id: room))
        XCTAssertNil(try f.ctx.threadRepo.get(id: memberThread), "the bot's private thread for this group goes too")
        XCTAssertNotNil(try f.ctx.botStore.get(id: f.ana.id), "bots stay")
        XCTAssertEqual(log.changes("bot.group.updated", id: "group_id", group.id).last, "deleted")
        let gone = await refusal(f, "bot.group.get", ["group_id": .string(group.id)])
        XCTAssertEqual(gone?.code, BotTeamGroupService.notFoundCode)
        let lists = try decode(BotGroupList.Result.self, try await rpc(f, "bot.group.list", [:]))
        XCTAssertTrue(lists.groups.isEmpty)
    }

    func test_updateGroupAppliesOnlyGivenFieldsAndClearsLinksExplicitly() async throws {
        let f = try makeFixture()
        let team = try f.service.createTeam(name: "Writers", memberBotIDs: [f.ana.id, f.bob.id])
        let group = try await createGroup(f, bots: [f.ana, f.bob], extra: ["team_id": key(team.id.value)])
        XCTAssertEqual(group.teamID, team.id.value.uuidString.lowercased())

        let led = try decode(BotGroupUpdate.Result.self, try await rpc(f, "bot.group.update", [
            "group_id": .string(group.id), "expected_revision": .number(Double(group.revision)),
            "policy": .string("lead"), "lead_bot_id": key(f.bob.id.value), "max_auto_hops": .number(2),
        ])).readback.group
        XCTAssertEqual(led.policy, "lead")
        XCTAssertEqual(led.leadBotID, f.bob.id.value.uuidString.lowercased())
        XCTAssertEqual(led.maxAutoHops, 2)
        XCTAssertEqual(led.title, "Launch room", "absent fields keep their value")
        XCTAssertEqual(led.teamID, group.teamID)

        let unlinked = try decode(BotGroupUpdate.Result.self, try await rpc(f, "bot.group.update", [
            "group_id": .string(group.id), "expected_revision": .number(Double(led.revision)),
            "clear_team_id": .bool(true),
        ])).readback.group
        XCTAssertNil(unlinked.teamID)

        let tooMany = await refusal(f, "bot.group.update", [
            "group_id": .string(group.id), "expected_revision": .number(Double(unlinked.revision)),
            "max_auto_hops": .number(9),
        ])
        XCTAssertEqual(tooMany?.code, -32602, "the hop budget is capped at 8")
        let badPolicy = await refusal(f, "bot.group.update", [
            "group_id": .string(group.id), "expected_revision": .number(Double(unlinked.revision)),
            "policy": .string("chaos"),
        ])
        XCTAssertEqual(badPolicy?.code, -32602)
        XCTAssertEqual(try f.ctx.botStore.group(id: BotGroupID(UUID(uuidString: group.id)!))?.revision, unlinked.revision)
    }
}
