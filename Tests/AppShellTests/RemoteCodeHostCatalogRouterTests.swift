import XCTest
import CoreModel
@testable import AgentRuntime
@testable import SocketServer
@testable import AppShell
@testable import Persistence

@MainActor
final class RemoteCodeHostCatalogRouterTests: XCTestCase {
    func test_missingWrongCrossRunStaleAndCapturedPermission() throws {
        let harness = try Harness()
        let capability = harness.fullAccessCapability
        try harness.router.authenticateManagedHostCall(
            threadID: harness.thread.id,
            runID: harness.runID,
            delegationCapability: capability,
            mutation: true,
            method: RemoteCodeHostCatalog.botCreateRPC
        )

        XCTAssertThrowsError(
            try harness.router.authenticateManagedHostCall(
                threadID: harness.thread.id,
                runID: harness.runID,
                delegationCapability: nil,
                mutation: true,
                method: RemoteCodeHostCatalog.botCreateRPC
            )
        ) { error in
            XCTAssertEqual((error as? JSONRPCError)?.code, -32047)
        }

        XCTAssertThrowsError(
            try harness.router.authenticateManagedHostCall(
                threadID: harness.thread.id,
                runID: harness.runID,
                delegationCapability: String(repeating: "cd", count: 32),
                mutation: true,
                method: RemoteCodeHostCatalog.botCreateRPC
            )
        ) { error in
            XCTAssertEqual((error as? JSONRPCError)?.code, -32047)
        }

        XCTAssertThrowsError(
            try harness.router.authenticateManagedHostCall(
                threadID: harness.thread.id,
                runID: AgentRunID(),
                delegationCapability: capability,
                mutation: true,
                method: RemoteCodeHostCatalog.botCreateRPC
            )
        ) { error in
            XCTAssertEqual((error as? JSONRPCError)?.code, -32047)
        }

        XCTAssertThrowsError(
            try harness.router.authenticateManagedHostCall(
                threadID: AgentThreadID(),
                runID: harness.runID,
                delegationCapability: capability,
                mutation: true,
                method: RemoteCodeHostCatalog.botCreateRPC
            )
        ) { error in
            XCTAssertEqual((error as? JSONRPCError)?.code, -32047)
        }

        XCTAssertThrowsError(
            try harness.router.authenticateManagedHostCall(
                threadID: harness.supervisedThread.id,
                runID: harness.supervisedRunID,
                delegationCapability: harness.supervisedCapability,
                mutation: true,
                method: RemoteCodeHostCatalog.botCreateRPC
            )
        ) { error in
            XCTAssertEqual((error as? JSONRPCError)?.code, -32048)
        }

        try harness.router.authenticateManagedHostCall(
            threadID: harness.supervisedThread.id,
            runID: harness.supervisedRunID,
            delegationCapability: harness.supervisedCapability,
            mutation: false,
            method: RemoteCodeHostCatalog.botListRPC
        )

        try harness.context.orchestrationRuntime.finalizeReceipt(
            runId: harness.runID,
            status: .completed
        )
        XCTAssertThrowsError(
            try harness.router.authenticateManagedHostCall(
                threadID: harness.thread.id,
                runID: harness.runID,
                delegationCapability: capability,
                mutation: true,
                method: RemoteCodeHostCatalog.botCreateRPC
            )
        ) { error in
            XCTAssertEqual((error as? JSONRPCError)?.code, -32047)
        }
    }

    func test_createdBotGrantAndSkillBodyDigestReadback() throws {
        let harness = try Harness()
        let created = try harness.router.createHostBot(
            name: "Oliver",
            title: "QA",
            description: "Host catalog bot",
            handle: "oliver-qa",
            soul: "Prove skills.",
            callerRun: harness.runID
        )
        let botID = try XCTUnwrap(created.objectValue?["id"]?.stringValue)
        let listed = try harness.router.listHostBots()
        XCTAssertTrue(
            listed.objectValue?["bots"]?.arrayValue?.contains {
                $0.objectValue?["id"]?.stringValue == botID
            } == true
        )

        let body = """
        ---
        name: qa-proof
        description: Prove host catalog skill create/view.
        ---

        Return the exact phrase HOST-CATALOG-PROOF.
        """
        let createdSkill = try harness.router.createHostBotSkill(
            botID: BotID(UUID(uuidString: botID)!),
            skillID: "qa-proof",
            body: body,
            callerRun: harness.runID,
            callerThread: harness.thread.id
        )
        XCTAssertEqual(createdSkill.objectValue?["body"]?.stringValue, body)
        XCTAssertEqual(
            createdSkill.objectValue?["digest"]?.stringValue,
            RemoteCodeHostCatalog.bodyDigest(body)
        )
        let viewed = try harness.router.viewHostBotSkill(
            botID: BotID(UUID(uuidString: botID)!),
            skillID: "qa-proof",
            callerRun: harness.runID,
            callerThread: harness.thread.id
        )
        XCTAssertEqual(viewed.objectValue?["body"]?.stringValue, body)
        XCTAssertEqual(viewed.objectValue?["digest"]?.stringValue, RemoteCodeHostCatalog.bodyDigest(body))

        let outsider = try harness.context.botStore.create(
            name: "Outsider",
            title: "No grant",
            description: "",
            soul: "",
            provider: .claude,
            model: "opus"
        )
        XCTAssertThrowsError(
            try harness.router.createHostBotSkill(
                botID: outsider.id,
                skillID: "stolen",
                body: "nope",
                callerRun: harness.runID,
                callerThread: harness.thread.id
            )
        ) { error in
            XCTAssertEqual((error as? JSONRPCError)?.code, -32046)
        }

        let childRun = AgentRunID()
        XCTAssertThrowsError(
            try harness.router.viewHostBotSkill(
                botID: BotID(UUID(uuidString: botID)!),
                skillID: "qa-proof",
                callerRun: childRun,
                callerThread: harness.thread.id
            )
        ) { error in
            XCTAssertEqual((error as? JSONRPCError)?.code, -32046)
        }

        let thread = try harness.router.createHostBotThread(
            botID: BotID(UUID(uuidString: botID)!),
            title: "Desk thread"
        )
        XCTAssertEqual(thread.objectValue?["title"]?.stringValue, "Desk thread")
    }

    func test_createdBotSecretToolsUseActiveFullAccessGrantAndNeverReturnValues() throws {
        let harness = try Harness()
        let created = try harness.router.createHostBot(
            name: "Secret target",
            title: "QA",
            description: "",
            handle: "secret-target",
            soul: "",
            callerRun: harness.runID
        )
        let botID = try XCTUnwrap(created.objectValue?["id"]?.stringValue)
        let secretValue = "fixture-secret-value"

        let saved = try harness.router.invokeDelegatedBotSelfConfig(
            callerThread: harness.thread.id,
            callerRun: harness.runID,
            toolName: BotSelfConfigCatalog.saveSecret,
            arguments: [
                "bot_id": .string(botID),
                "name": .string("SERVICE_TOKEN"),
                "value": .string(secretValue),
                "user_confirmed": .bool(true),
            ],
            delegationCapability: harness.fullAccessCapability
        )
        XCTAssertEqual(saved.objectValue?["saved"]?.boolValue, true)
        XCTAssertNil(saved.objectValue?["value"])
        XCTAssertEqual(try harness.secretStore.load(
            botID: BotID(UUID(uuidString: botID)!),
            name: "SERVICE_TOKEN"
        ), secretValue)

        let listed = try harness.router.invokeDelegatedBotSelfConfig(
            callerThread: harness.thread.id,
            callerRun: harness.runID,
            toolName: BotSelfConfigCatalog.listSecrets,
            arguments: ["bot_id": .string(botID)],
            delegationCapability: harness.fullAccessCapability
        )
        XCTAssertEqual(listed.objectValue?["secrets"]?.arrayValue?.compactMap(\.stringValue), ["SERVICE_TOKEN"])
        XCTAssertFalse(String(describing: listed).contains(secretValue))

        let deleted = try harness.router.invokeDelegatedBotSelfConfig(
            callerThread: harness.thread.id,
            callerRun: harness.runID,
            toolName: BotSelfConfigCatalog.deleteSecret,
            arguments: [
                "bot_id": .string(botID),
                "name": .string("SERVICE_TOKEN"),
                "user_confirmed": .bool(true),
            ],
            delegationCapability: harness.fullAccessCapability
        )
        XCTAssertEqual(deleted.objectValue?["deleted"]?.boolValue, true)
        XCTAssertNil(deleted.objectValue?["value"])
        XCTAssertNil(try harness.secretStore.load(
            botID: BotID(UUID(uuidString: botID)!),
            name: "SERVICE_TOKEN"
        ))

        XCTAssertThrowsError(try harness.router.invokeDelegatedBotSelfConfig(
            callerThread: harness.supervisedThread.id,
            callerRun: harness.supervisedRunID,
            toolName: BotSelfConfigCatalog.saveSecret,
            arguments: [
                "bot_id": .string(botID),
                "name": .string("SERVICE_TOKEN"),
                "value": .string(secretValue),
                "user_confirmed": .bool(true),
            ],
            delegationCapability: harness.supervisedCapability
        )) { error in
            XCTAssertEqual((error as? JSONRPCError)?.code, -32048)
        }

        let outsider = try harness.context.botStore.create(
            name: "Unrelated",
            title: "No grant",
            description: "",
            soul: "",
            provider: .claude,
            model: "opus"
        )
        XCTAssertThrowsError(try harness.router.invokeDelegatedBotSelfConfig(
            callerThread: harness.thread.id,
            callerRun: harness.runID,
            toolName: BotSelfConfigCatalog.saveSecret,
            arguments: [
                "bot_id": .string(outsider.id.value.uuidString.lowercased()),
                "name": .string("OTHER_TOKEN"),
                "value": .string("must-not-store"),
                "user_confirmed": .bool(true),
            ],
            delegationCapability: harness.fullAccessCapability
        )) { error in
            XCTAssertEqual((error as? JSONRPCError)?.code, -32046)
            XCTAssertFalse(String(describing: error).contains("must-not-store"))
        }
        XCTAssertNil(try harness.secretStore.load(botID: outsider.id, name: "OTHER_TOKEN"))

        XCTAssertThrowsError(try harness.router.invokeDelegatedBotSelfConfig(
            callerThread: harness.thread.id,
            callerRun: harness.runID,
            toolName: BotSelfConfigCatalog.listSecrets,
            arguments: ["bot_id": .string(botID)],
            delegationCapability: nil
        )) { error in
            XCTAssertEqual((error as? JSONRPCError)?.code, -32047)
        }

        try harness.context.orchestrationRuntime.finalizeReceipt(runId: harness.runID, status: .completed)
        XCTAssertThrowsError(try harness.router.invokeDelegatedBotSelfConfig(
            callerThread: harness.thread.id,
            callerRun: harness.runID,
            toolName: BotSelfConfigCatalog.listSecrets,
            arguments: ["bot_id": .string(botID)],
            delegationCapability: harness.fullAccessCapability
        )) { error in
            XCTAssertEqual((error as? JSONRPCError)?.code, -32047)
        }
    }

    func test_skillAuthorityComesFromAuthenticatedThreadNotCallerBotParameter() async throws {
        // WHY: provider-controlled JSON may claim any caller_bot_id. The host
        // must derive self-Bot identity from the authenticated thread linkage.
        let harness = try Harness()
        let outsider = try harness.context.botStore.create(
            name: "Outsider",
            title: "No grant",
            description: "",
            soul: "",
            provider: .claude,
            model: "opus"
        )
        let dispatcher = JSONRPCDispatcher(router: harness.router)
        let response = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: RemoteCodeHostCatalog.botSkillViewRPC,
            params: [
                "thread_id": .string(harness.thread.id.value.uuidString.lowercased()),
                "run_id": .string(harness.runID.value.uuidString.lowercased()),
                BotPeerDelegation.capabilityRPCParameterKey: .string(harness.fullAccessCapability),
                "bot_id": .string(outsider.id.value.uuidString.lowercased()),
                "skill_id": .string("forged"),
                "caller_bot_id": .string(outsider.id.value.uuidString.lowercased()),
            ]
        ))
        XCTAssertEqual(response.error?.code, -32046)

        let conversation = BotConversation(
            botID: outsider.id,
            title: "Owned thread",
            linkedAgentThreadID: harness.thread.id
        )
        try harness.context.botStore.upsertConversation(conversation)
        let body = "---\nname: self-owned\n---\nHost-derived self authority.\n"
        let created = try harness.router.createHostBotSkill(
            botID: outsider.id,
            skillID: "self-owned",
            body: body,
            callerRun: harness.runID,
            callerThread: harness.thread.id
        )
        XCTAssertEqual(created.objectValue?["body"]?.stringValue, body)
    }

    func test_createdBotDoesNotPersistAProviderOrModel() throws {
        // WHY: host creation defines Bot identity and brain only. Provider and
        // model are chosen later by the user on the calling thread.
        let harness = try Harness()
        let created = try harness.router.createHostBot(
            name: "Grok QA",
            title: "QA",
            description: "",
            handle: nil,
            soul: "",
            callerRun: harness.runID
        )
        let botID = try XCTUnwrap(created.objectValue?["id"]?.stringValue)
        let bot = try XCTUnwrap(harness.context.botStore.get(id: BotID(UUID(uuidString: botID)!)))
        let revisionID = try XCTUnwrap(bot.currentRevisionID)
        let revision = try XCTUnwrap(harness.context.botStore.getRevision(id: revisionID))
        let revisionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(revision)) as? [String: Any]
        )
        XCTAssertNil(revisionObject["provider"])
        XCTAssertNil(revisionObject["providerInstanceID"])
        XCTAssertNil(revisionObject["model"])
        XCTAssertNil(created.objectValue?["provider"])
        XCTAssertNil(created.objectValue?["model"])
    }

    func test_hostCatalogKillSwitchFailsClosedWithoutDisablingOtherRepairs() throws {
        // WHY: operators must be able to disable only the new provider mutation
        // surface without reverting Stop, attention, or Docker correctness fixes.
        let harness = try Harness()
        let store = SettingsStore(db: harness.context.db)
        var settings = store.load()
        settings.botsControlPlaneEnabled = false
        store.save(settings)

        XCTAssertThrowsError(
            try harness.router.authenticateManagedHostCall(
                threadID: harness.thread.id,
                runID: harness.runID,
                delegationCapability: harness.fullAccessCapability,
                mutation: false,
                method: RemoteCodeHostCatalog.botListRPC
            )
        ) { error in
            XCTAssertEqual((error as? JSONRPCError)?.code, -32049)
        }
    }

    private struct Harness {
        let context: AppContext
        let router: AppCommandRouter
        let secretStore: InMemoryBotSecretStore
        let thread: AgentThread
        let runID: AgentRunID
        let fullAccessCapability: String
        let supervisedThread: AgentThread
        let supervisedRunID: AgentRunID
        let supervisedCapability: String

        @MainActor
        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("rc-host-catalog-\(UUID().uuidString)", isDirectory: true)
            context = try AppContext(
                channel: .debug,
                appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path
            )
            secretStore = InMemoryBotSecretStore()
            router = AppCommandRouter(
                context: context,
                sshPasswordStore: KeychainSSHPasswordStore(),
                secretStore: secretStore
            )
            context.router = router
            thread = AgentThread(title: "host-catalog", provider: .claude, model: "opus", permissionMode: .fullAccess)
            try context.threadRepo.upsert(thread)
            runID = AgentRunID()
            fullAccessCapability = AgentDelegationCapability.issue()
            _ = try context.orchestrationRuntime.recordExternalRoot(
                runId: runID,
                threadId: thread.id,
                provider: .claude,
                providerInstanceId: "claude",
                model: "opus",
                permissionMode: .fullAccess,
                delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(fullAccessCapability)
            )
            supervisedThread = AgentThread(
                title: "supervised",
                provider: .claude,
                model: "opus",
                permissionMode: .supervised
            )
            try context.threadRepo.upsert(supervisedThread)
            supervisedRunID = AgentRunID()
            supervisedCapability = AgentDelegationCapability.issue()
            _ = try context.orchestrationRuntime.recordExternalRoot(
                runId: supervisedRunID,
                threadId: supervisedThread.id,
                provider: .claude,
                providerInstanceId: "claude",
                model: "opus",
                permissionMode: .supervised,
                delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(supervisedCapability)
            )
        }
    }
}
