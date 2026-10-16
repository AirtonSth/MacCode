import Foundation
import XCTest
import AgentRuntime
import CoreModel
import Persistence
import SocketServer
@testable import AppShell

final class BotContextGuestResourcesTests: XCTestCase {
    private final class CountingSecrets: BotSecretStore, @unchecked Sendable {
        private let backing = InMemoryBotSecretStore()
        private let lock = NSLock()
        private(set) var reads = 0

        func list(botID: BotID) throws -> [BotSecretMetadata] {
            lock.lock(); reads += 1; lock.unlock()
            return try backing.list(botID: botID)
        }
        func save(botID: BotID, name: String, value: String) throws { try backing.save(botID: botID, name: name, value: value) }
        func load(botID: BotID, name: String) throws -> String? {
            lock.lock(); reads += 1; lock.unlock()
            return try backing.load(botID: botID, name: name)
        }
        func delete(botID: BotID, name: String) throws { try backing.delete(botID: botID, name: name) }
        func deleteAll(botID: BotID) throws { try backing.deleteAll(botID: botID) }
    }

    private func fixture() throws -> (URL, BotStore, AgentThreadRepository, Workspace, AgentThread, BotContext, String, Int64) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BotContextGuestResources-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: root.appendingPathComponent("bots.sqlite").path)
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let bot = try store.create(name: "Context bot", title: "Context", description: "", handle: "context-bot", soul: "", provider: .claude, model: "opus")
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let workspace = Workspace.empty(name: "Workspace", cwd: workspaceDir.path)
        let host = "trusted-host"
        let context = BotContext.workspace(workspace.id)
        let grant = try store.grantContext(hostID: host, botID: bot.id, context: context, actions: [.read, .send, .configure, .files], expectedRevision: nil)
        let thread = AgentThread(workspaceId: workspace.id, title: "Pinned", provider: .distill, model: "distill")
        let conversation = BotConversation(botID: bot.id, title: "Pinned", linkedAgentThreadID: thread.id)
        _ = try store.createContextualConversation(conversation, newThread: thread, hostID: host, context: context, policyRevision: grant.policyRevision)
        let repository = AgentThreadRepository(db: db)
        return (root, store, repository, workspace, try XCTUnwrap(repository.get(id: thread.id)), context, host, grant.policyRevision)
    }

    private func assertRejected(root: URL, store: BotStore, repo: AgentThreadRepository, workspace: Workspace, thread: AgentThread, host: String, secrets: CountingSecrets) {
        let support = root.appendingPathComponent("support", isDirectory: true)
        let service = BotComputerGuestService(appSupport: support, docker: BotComputerDockerCLI(), observeAttempts: 1, observeDelay: 0)
        let request = AgentRunRequest(threadId: thread.id, provider: .distill, model: "distill", cwd: workspace.cwd, prompt: "test")
        XCTAssertThrowsError(try BotContextGuestResources.prepare(request: request, hostID: host, store: store, threadRepo: repo, service: service, appSupport: support, workspace: workspace, registeredWorkspaces: [workspace.cwd], secretStore: secrets))
        XCTAssertEqual(secrets.reads, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: BotComputerGuestSpec.guestHomeRoot(appSupport: support).path))
    }

    func testWrongTrustedHostRejectedBeforeSecretReadOrHomeCreation() throws {
        let (root, store, repo, workspace, thread, _, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = CountingSecrets()
        assertRejected(root: root, store: store, repo: repo, workspace: workspace, thread: thread, host: "wrong-host", secrets: secrets)
    }

    func testPersistedRunAsUserRejectedWhenRequestOmitsIt() throws {
        let (root, store, repo, workspace, original, _, host, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let user = AgentRunAsUser(generatedUID: "other-user", shortName: "other", uid: getuid() + 1, gid: getgid(), homePath: "/Users/other")
        var thread = original
        thread.runAsUser = user
        try repo.upsert(thread)
        XCTAssertEqual(try repo.get(id: thread.id)?.runAsUser, user)
        let secrets = CountingSecrets()
        assertRejected(root: root, store: store, repo: repo, workspace: workspace, thread: thread, host: host, secrets: secrets)
    }
}

