import Foundation
import XCTest
import AgentRuntime
import CoreModel
import Persistence
@testable import Surfaces
@testable import AppShell

@MainActor
final class BotContextRealHostFixtureTests: XCTestCase {
    private static let rootKey = "RC_CONTEXT_REAL_HOST_FIXTURE_ROOT"
    private static let verifyKey = "RC_CONTEXT_REAL_HOST_VERIFY"

    private struct Fixture: Codable {
        let hostID: String
        let botID: BotID
        let bBotID: BotID
        let workspaceID: WorkspaceID
        let expectedBRevision: Int64
    }

    func test_exportRealHostFixture() throws {
        guard let rootPath = ProcessInfo.processInfo.environment[Self.rootKey] else {
            throw XCTSkip("set RC_CONTEXT_REAL_HOST_FIXTURE_ROOT to export the real-host fixture")
        }
        let root = try Self.validatedRoot(rootPath)
        guard !FileManager.default.fileExists(atPath: root.path) else {
            XCTFail("export requires a fresh task-owned fixture directory")
            return
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let support = root.appendingPathComponent("source-support", isDirectory: true)
        let sourceDB = root.appendingPathComponent("source.sqlite")
        guard !FileManager.default.fileExists(atPath: sourceDB.path),
              !FileManager.default.fileExists(atPath: root.appendingPathComponent("app-support/remotecode.sqlite").path) else {
            XCTFail("refusing to modify an existing source or runtime fixture database")
            return
        }
        let ctx = try AppContext(channel: .debug, dbPathOverride: sourceDB.path, appSupportOverride: support.path, privateAccountAPI: SilentWakeRecordingAPI(), performLaunchRunReconciliation: false)
        ctx.router = AppCommandRouter(context: ctx)
        let store = ctx.botStore
        let host = ctx.liveActivityHostIdentity.serverId
        let botA = try store.create(name: "Context Integration Bot", title: "Context Integration Bot", description: "", handle: "context-integration", soul: "", provider: .distill, model: "test")
        let botB = try store.create(name: "Context Integration Bot B", title: "Context Integration Bot B", description: "", handle: "context-integration-b", soul: "", provider: .distill, model: "test")
        let grantB = try store.grantContext(hostID: host, botID: botB.id, context: .general, actions: [.read, .send], expectedRevision: 0)
        let workspacePath = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true)
        let workspace = try XCTUnwrap(ctx.router).createWorkspace(name: "Context Fixture", cwd: workspacePath.path)
        try ctx.settingsRepo.set("remote_access_enabled", "0")
        let authority = try XCTUnwrap(ctx.router?.botRoutineAuthority)
        _ = try authority.dispatch(method: "bot.routing.set", params: [
            "client_request_id": "fixture-route", "bot_id": botA.id.value.uuidString.lowercased(),
            "host_id": host, "provider": "distill", "provider_instance_id": "distill", "model": "fixture-context-main",
        ])
        let snapshot = root.appendingPathComponent("app-support", isDirectory: true).appendingPathComponent("remotecode.sqlite")
        try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: snapshot.path) else {
            XCTFail("refusing to overwrite existing fixture database")
            return
        }
        ctx.saveSnapshot()
        XCTAssertNotNil(try ctx.snapshotRepo.latest()?.layout.workspaces[workspace.id])
        let escaped = snapshot.path.replacingOccurrences(of: "'", with: "''")
        try ctx.db.execute("VACUUM INTO '\(escaped)';")
        let fixture = Fixture(hostID: host, botID: botA.id, bBotID: botB.id, workspaceID: workspace.id, expectedBRevision: grantB.policyRevision)
        try JSONEncoder().encode(fixture).write(to: root.appendingPathComponent("fixture.json"), options: .atomic)
    }

    func test_exportCanonicalNavigationFixture() throws {
        guard let rootPath = ProcessInfo.processInfo.environment[Self.rootKey] else {
            throw XCTSkip("set RC_CONTEXT_REAL_HOST_FIXTURE_ROOT to export the real-host fixture")
        }
        try test_exportRealHostFixture()
        let root = try Self.validatedRoot(rootPath)
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
        let support = root.appendingPathComponent("app-support", isDirectory: true)
        let runtimeDB = support.appendingPathComponent("remotecode.sqlite")
        let ctx = try AppContext(channel: .debug, dbPathOverride: runtimeDB.path, appSupportOverride: support.path, privateAccountAPI: SilentWakeRecordingAPI(), performLaunchRunReconciliation: false)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let store = ctx.botStore
        let workspaceBinding = try store.grantContext(hostID: fixture.hostID, botID: fixture.botID, context: .workspace(fixture.workspaceID), actions: [.read, .send], expectedRevision: nil)
        let generalBinding = try store.grantContext(hostID: fixture.hostID, botID: fixture.botID, context: .general, actions: [.read, .send], expectedRevision: nil)
        XCTAssertEqual(workspaceBinding.policyRevision, 1)
        XCTAssertEqual(generalBinding.policyRevision, 1)

        var workspaceThread = AgentThread(workspaceId: fixture.workspaceID, title: "Navigation Workspace A", provider: .distill, model: "fixture-context-main")
        workspaceThread.status = .completed
        let workspaceConversation = BotConversation(botID: fixture.botID, title: "Navigation Workspace A", linkedAgentThreadID: workspaceThread.id)
        try store.createContextualConversation(workspaceConversation, newThread: workspaceThread, hostID: fixture.hostID, context: .workspace(fixture.workspaceID), policyRevision: workspaceBinding.policyRevision)
        var generalThread = AgentThread(title: "Navigation General", provider: .distill, model: "fixture-context-main")
        generalThread.status = .completed
        let generalConversation = BotConversation(botID: fixture.botID, title: "Navigation General", linkedAgentThreadID: generalThread.id)
        try store.createContextualConversation(generalConversation, newThread: generalThread, hostID: fixture.hostID, context: .general, policyRevision: generalBinding.policyRevision)
        let finishedAt = Date()
        try ctx.runRepo.upsert(AgentRun(threadId: workspaceThread.id, provider: .distill, model: "fixture-context-main", status: .completed, startedAt: finishedAt, finishedAt: finishedAt))
        try ctx.runRepo.upsert(AgentRun(threadId: generalThread.id, provider: .distill, model: "fixture-context-main", status: .completed, startedAt: finishedAt, finishedAt: finishedAt))

        let descriptor = try router.createSurface(workspace: fixture.workspaceID, type: .agentApp, paneID: nil, title: "Navigation Workspace A")
        defer {
            if let surface = SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface {
                surface.close()
                SurfaceRegistry.shared.unregister(descriptor.id)
            }
        }
        try router.selectAgentThread(thread: workspaceThread.id, surfaceID: descriptor.id)
        ctx.saveSnapshot()
        XCTAssertNotNil(try ctx.snapshotRepo.latest()?.layout.workspaces[fixture.workspaceID])
        let navigation: [String: String] = [
            "hostID": fixture.hostID,
            "botID": fixture.botID.value.uuidString.lowercased(),
            "workspaceID": fixture.workspaceID.value.uuidString.lowercased(),
            "workspaceThreadID": workspaceThread.id.value.uuidString.lowercased(),
            "workspaceConversationID": workspaceConversation.id.value.uuidString.lowercased(),
            "generalThreadID": generalThread.id.value.uuidString.lowercased(),
            "generalConversationID": generalConversation.id.value.uuidString.lowercased(),
            "surfaceID": descriptor.id.value.uuidString.lowercased(),
        ]
        try JSONEncoder().encode(navigation).write(to: root.appendingPathComponent("navigation.json"), options: .atomic)
    }

    func test_verifyOfflineQueueRevocationAfterHostRestart() throws {
        guard ProcessInfo.processInfo.environment[Self.verifyKey] == "1" else {
            throw XCTSkip("set RC_CONTEXT_REAL_HOST_VERIFY=1 to verify the exported fixture")
        }
        guard let rootPath = ProcessInfo.processInfo.environment[Self.rootKey] else {
            throw XCTSkip("set RC_CONTEXT_REAL_HOST_FIXTURE_ROOT to locate the exported fixture")
        }
        let root = try Self.validatedRoot(rootPath)
        let supportDB = root.appendingPathComponent("app-support/remotecode.sqlite")
        guard FileManager.default.fileExists(atPath: supportDB.path) else {
            XCTFail("exported fixture database missing")
            return
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
        let navigation = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("navigation.json")))
        func uuid(_ key: String) throws -> UUID {
            try XCTUnwrap(navigation[key].flatMap(UUID.init(uuidString:)), "missing or invalid navigation UUID: \(key)")
        }
        let generalConversationID = BotConversationID(try uuid("generalConversationID"))
        let generalThreadID = AgentThreadID(try uuid("generalThreadID"))
        let workspaceConversationID = BotConversationID(try uuid("workspaceConversationID"))
        let workspaceThreadID = AgentThreadID(try uuid("workspaceThreadID"))
        XCTAssertNotEqual(generalConversationID, workspaceConversationID)
        XCTAssertNotEqual(generalThreadID, workspaceThreadID)
        XCTAssertEqual(try uuid("botID"), fixture.botID.value)
        XCTAssertEqual(try uuid("workspaceID"), fixture.workspaceID.value)

        let db = try SQLiteDB(path: supportDB.path, readonly: true)
        let store = BotStore(db: db)
        let bindingA = try XCTUnwrap(store.getContextBinding(hostID: fixture.hostID, botID: fixture.botID, context: .general))
        let bindingB = try XCTUnwrap(store.getContextBinding(hostID: fixture.hostID, botID: fixture.bBotID, context: .general))
        XCTAssertEqual(bindingA.policyRevision, 2)
        XCTAssertEqual(bindingA.state, .revoked)
        XCTAssertEqual(bindingB.policyRevision, fixture.expectedBRevision)
        XCTAssertEqual(bindingB.policyRevision, 1)
        XCTAssertEqual(bindingB.state, .active)
        let workspaceBinding = try XCTUnwrap(store.getContextBinding(hostID: fixture.hostID, botID: fixture.botID, context: .workspace(fixture.workspaceID)))
        XCTAssertEqual(workspaceBinding.policyRevision, 1)
        XCTAssertEqual(workspaceBinding.state, .active)
        XCTAssertTrue(try store.authorizes(hostID: fixture.hostID, botID: fixture.bBotID, context: .general, action: .read, policyRevision: bindingB.policyRevision))
        XCTAssertTrue(try store.authorizes(hostID: fixture.hostID, botID: fixture.bBotID, context: .general, action: .send, policyRevision: bindingB.policyRevision))

        let general = try XCTUnwrap(store.listConversations(botID: fixture.botID).first { $0.id == generalConversationID })
        let workspace = try XCTUnwrap(store.listConversations(botID: fixture.botID).first { $0.id == workspaceConversationID })
        XCTAssertEqual(general.linkedAgentThreadID, generalThreadID)
        XCTAssertEqual(workspace.linkedAgentThreadID, workspaceThreadID)
        let generalPin = try XCTUnwrap(store.conversationContextPin(conversationID: generalConversationID))
        let workspacePin = try XCTUnwrap(store.conversationContextPin(conversationID: workspaceConversationID))
        XCTAssertEqual(generalPin.hostID, fixture.hostID)
        XCTAssertEqual(generalPin.botID, fixture.botID)
        XCTAssertEqual(generalPin.context, .general)
        XCTAssertEqual(generalPin.policyRevision, 1)
        XCTAssertEqual(workspacePin.context, .workspace(fixture.workspaceID))
        XCTAssertEqual(workspacePin.policyRevision, 1)

        let threads = AgentThreadRepository(db: db)
        let generalThread = try XCTUnwrap(threads.get(id: generalThreadID))
        let workspaceThread = try XCTUnwrap(threads.get(id: workspaceThreadID))
        XCTAssertNil(generalThread.workspaceId)
        XCTAssertEqual(generalThread.actor, .bot(fixture.botID))
        XCTAssertEqual(workspaceThread.workspaceId, fixture.workspaceID)
        XCTAssertEqual(workspaceThread.actor, .bot(fixture.botID))
        for threadID in [generalThreadID, workspaceThreadID] {
            let runs = try db.prepare("SELECT COUNT(*) FROM agent_runs WHERE lower(thread_id)=?;")
            try runs.bind(1, threadID.value.uuidString.lowercased())
            XCTAssertTrue(try runs.step())
            XCTAssertEqual(runs.columnInt64(0), 1)
            let userMessages = try db.prepare("SELECT COUNT(*) FROM agent_messages WHERE lower(thread_id)=? AND role='user';")
            try userMessages.bind(1, threadID.value.uuidString.lowercased())
            XCTAssertTrue(try userMessages.step())
            XCTAssertEqual(userMessages.columnInt64(0), 0)
        }
        XCTAssertTrue(try AgentQueuedMessageRepository(db: db).list(threadId: generalThreadID).isEmpty)

        let reopenedDB = try SQLiteDB(path: supportDB.path, readonly: true)
        let reopenedStore = BotStore(db: reopenedDB)
        XCTAssertEqual(try reopenedStore.getContextBinding(hostID: fixture.hostID, botID: fixture.botID, context: .general)?.policyRevision, 2)
        XCTAssertEqual(try reopenedStore.getContextBinding(hostID: fixture.hostID, botID: fixture.botID, context: .general)?.state, .revoked)
        XCTAssertEqual(try reopenedStore.conversationContextPin(conversationID: generalConversationID)?.policyRevision, 1)
        XCTAssertEqual(try reopenedStore.conversationContextPin(conversationID: workspaceConversationID)?.context, .workspace(fixture.workspaceID))
    }

    func test_verifyRealHostFixtureAfterRevoke() throws {
        guard ProcessInfo.processInfo.environment[Self.verifyKey] == "1" else {
            throw XCTSkip("set RC_CONTEXT_REAL_HOST_VERIFY=1 to verify the exported fixture")
        }
        guard let rootPath = ProcessInfo.processInfo.environment[Self.rootKey] else {
            throw XCTSkip("set RC_CONTEXT_REAL_HOST_FIXTURE_ROOT to locate the exported fixture")
        }
        let root = try Self.validatedRoot(rootPath)
        let supportDB = root.appendingPathComponent("app-support/remotecode.sqlite")
        guard FileManager.default.fileExists(atPath: supportDB.path) else {
            XCTFail("exported fixture database missing")
            return
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
        let db = try SQLiteDB(path: supportDB.path)
        let store = BotStore(db: db)
        let context = BotContext.general
        let bindingA = try XCTUnwrap(store.getContextBinding(hostID: fixture.hostID, botID: fixture.botID, context: .general))
        let bindingB = try XCTUnwrap(store.getContextBinding(hostID: fixture.hostID, botID: fixture.bBotID, context: .general))
        XCTAssertEqual(bindingA.policyRevision, 2)
        XCTAssertEqual(bindingA.state, .revoked)
        XCTAssertFalse(try store.authorizes(hostID: fixture.hostID, botID: fixture.botID, context: .general, action: .read, policyRevision: bindingA.policyRevision))
        XCTAssertEqual(bindingB.policyRevision, fixture.expectedBRevision)
        XCTAssertEqual(bindingB.policyRevision, 1)
        XCTAssertTrue(try store.authorizes(hostID: fixture.hostID, botID: fixture.bBotID, context: .general, action: .read, policyRevision: bindingB.policyRevision))
        XCTAssertTrue(try store.authorizes(hostID: fixture.hostID, botID: fixture.bBotID, context: .general, action: .send, policyRevision: bindingB.policyRevision))
        let conversations = try store.listConversations(botID: fixture.botID)
        let contextualConversations = try conversations.filter { try store.conversationContextPin(conversationID: $0.id)?.context == context }
        for conversation in contextualConversations {
            let pin = try XCTUnwrap(store.conversationContextPin(conversationID: conversation.id))
            XCTAssertEqual(pin.hostID, fixture.hostID)
            XCTAssertEqual(pin.botID, fixture.botID)
            XCTAssertEqual(pin.context, .general)
            XCTAssertEqual(pin.policyRevision, 1)
        }
        let linkedThreads = contextualConversations.compactMap(\.linkedAgentThreadID)
        XCTAssertEqual(contextualConversations.count, 1, "real host must create exactly one canonical contextual conversation")
        guard contextualConversations.count == 1, let conversation = contextualConversations.first, !linkedThreads.isEmpty else { return }
        let savedSelection = try XCTUnwrap(SettingsRepository(db: db).get("bot.remote.selected_conversations"))
        let selections = try JSONDecoder().decode([String: String].self, from: Data(savedSelection.utf8))
        XCTAssertEqual(selections[fixture.botID.value.uuidString.lowercased()], conversation.id.value.uuidString.lowercased())
        let threadIDs = linkedThreads.map { $0.value.uuidString.lowercased() }.map { "'\($0)'" }.joined(separator: ",")
        let noRuns = try db.prepare("SELECT COUNT(*) FROM agent_runs WHERE lower(thread_id) IN (\(threadIDs));")
        XCTAssertTrue(try noRuns.step())
        XCTAssertEqual(noRuns.columnInt64(0), 0)
        let noMessages = try db.prepare("SELECT COUNT(*) FROM agent_messages WHERE lower(thread_id) IN (\(threadIDs)) AND role='user';")
        XCTAssertTrue(try noMessages.step())
        XCTAssertEqual(noMessages.columnInt64(0), 0)
    }
    private static func validatedRoot(_ path: String) throws -> URL {
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".sandbox-state", isDirectory: true)
        guard root.path.hasPrefix(base.path + "/context-real-host-"),
              root.lastPathComponent != "context-real-host-",
              root.resolvingSymlinksInPath().path == root.path else {
            throw NSError(domain: "ContextFixturePath", code: 1)
        }
        for child in ["source-support", "source.sqlite", "app-support", "app-support/remotecode.sqlite", "fixture.json", "navigation.json"] {
            let target = root.appendingPathComponent(child)
            guard target.resolvingSymlinksInPath().path == target.path,
                  (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                throw NSError(domain: "ContextFixturePath", code: 2)
            }
        }
        return root
    }

    func test_fixturePathsRejectSymlinkedDescendants() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".sandbox-state", isDirectory: true)
        let root = try Self.validatedRoot(base.appendingPathComponent("context-real-host-path-" + UUID().uuidString).path)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("context-fixture-target-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("app-support")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try Self.validatedRoot(root.path))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link.appendingPathComponent("remotecode.sqlite"), withDestinationURL: outside.appendingPathComponent("untouched.sqlite"))
        XCTAssertThrowsError(try Self.validatedRoot(root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("untouched.sqlite").path))
    }

}
