import XCTest
import CoreModel
import Darwin
@testable import AgentRuntime

final class CodexAppServerClientTests: ProviderProcessTestCase {
    override func tearDown() {
        TokenSaverCensusSeam.sharedStore = TokenSaverCensusStore()
        super.tearDown()
    }

    func test_productionCodexLaunchForwardsRequestedRunAsIdentity() throws {
        // WHY: the persisted thread user must be the OS identity of the real
        // app-server process, including ownership tagging and foreign-UID reap.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let adapter = try String(
            contentsOf: root.appendingPathComponent("Sources/AgentRuntime/CodexAppServerAdapter.swift"),
            encoding: .utf8
        )
        let client = try String(
            contentsOf: root.appendingPathComponent("Sources/AgentRuntime/CodexAppServerClient.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(adapter.contains("runAsUser: request.runAsUser"))
        XCTAssertTrue(client.contains("runAsUser: runAsUser"))
        XCTAssertTrue(client.contains("foreignUserLaunch: foreignUserUID != nil"))
        XCTAssertTrue(client.contains("foreignUserUID: foreignUserUID"))
    }

    func test_turnStartCensus_preservesCodexWireBytesAndDoesNotInventTokens() async throws {
        let script = try makeFakeAppServerPeer()
        let store = TokenSaverCensusStore()
        TokenSaverCensusSeam.sharedStore = store
        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path,
            tokenSaverCensusAllowed: true
        )
        defer { client.stop() }
        _ = try await client.initialize()
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .codex,
            model: "test-model",
            cwd: FileManager.default.temporaryDirectory.path,
            prompt: "census payload"
        )

        _ = try await client.startTurn(providerThreadId: "thread-1", for: request)

        let observations = store.snapshot()
        XCTAssertEqual(observations.count, 1, "only provider-bound turn/start is census eligible")
        XCTAssertEqual(observations[0].bindingDimensions["provider"], "codex")
        XCTAssertEqual(observations[0].bindingDimensions["tool_shape"], "turn_start_json_line")
        XCTAssertGreaterThan(observations[0].eligibleBytes, 0)
        XCTAssertFalse(observations[0].hasMeasuredEligibleTokens)
        XCTAssertFalse(store.aggregates()[0].isValidForGate)
    }

    func test_invalidatedAcceptancePermitBlocksTurnStartBeforeWireWrite() async throws {
        let script = try makeFakeAppServerPeer()
        let store = TokenSaverCensusStore()
        TokenSaverCensusSeam.sharedStore = store
        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path,
            tokenSaverCensusAllowed: true
        )
        defer { client.stop() }
        _ = try await client.initialize()
        let permit = AgentRunAcceptancePermit()
        permit.invalidate()
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .codex,
            model: "test-model",
            cwd: FileManager.default.temporaryDirectory.path,
            prompt: "must not cross turn/start",
            acceptancePermit: permit
        )

        do {
            _ = try await client.startTurn(providerThreadId: "thread-1", for: request)
            XCTFail("suppression must win before the Codex turn/start write")
        } catch is AgentRunAcceptanceError {}

        XCTAssertTrue(store.snapshot().isEmpty,
                      "the provider-visible census proves no turn/start bytes were written")
    }

    func test_rpcDeadlineFailsWithoutStoppingSilentAppServer() async throws {
        let script = try makeSilentAppServerPeer()
        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path,
            requestTimeout: 0.05
        )
        defer { client.stop() }
        let pid = try silentPeerPID(for: script)
        let startedAt = Date()

        do {
            let _: [String: Any] = try await client.requestJSONObject(method: "test/neverRespond")
            XCTFail("a silent app-server RPC must fail within its configured deadline")
        } catch let error as CodexAppServerError {
            guard case .requestTimedOut(let method, _) = error else {
                return XCTFail("expected requestTimedOut, got \(error)")
            }
            XCTAssertEqual(method, "test/neverRespond")
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1,
                              "all app-server RPCs must have a real bounded deadline")
            XCTAssertTrue(isProcessAlive(pid),
                          "a timed-out RPC must leave a peer available for later requests")
        }
    }

    func test_timedOutRequestDiscardsLateResponseAndPreservesPeerForLaterRPC() async throws {
        let script = try makeLateResponseAppServerPeer()
        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path,
            requestTimeout: 0.03
        )
        defer { client.stop() }
        let pid = try silentPeerPID(for: script)
        let startedAt = Date()

        do {
            let _: [String: Any] = try await client.requestJSONObject(method: "test/lateResponse")
            XCTFail("the deliberately delayed RPC must still honor its deadline")
        } catch let error as CodexAppServerError {
            guard case .requestTimedOut(let method, _) = error else {
                return XCTFail("expected requestTimedOut, got \(error)")
            }
            XCTAssertEqual(method, "test/lateResponse")
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1,
                              "the first RPC must retain its bounded deadline")
        }

        XCTAssertTrue(waitForFile(script + ".late"),
                      "the fake peer must emit the first response after the local deadline")
        XCTAssertTrue(isProcessAlive(pid),
                      "a late response is not protocol desynchronization and must not kill the peer")

        let followUp: [String: Any] = try await client.requestJSONObject(method: "test/afterLateResponse")
        XCTAssertEqual(followUp["response"] as? String, "follow-up",
                       "the late response id must be discarded instead of resolving the later RPC")
    }

    func test_everyProductionRPCUsesTheDeadlineAndKeepsItsSilentPeerRunning() async throws {
        let cwd = FileManager.default.temporaryDirectory.path
        let startRequest = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .codex,
            model: "test-model",
            cwd: cwd,
            prompt: "deadline"
        )
        let resumeRequest = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .codex,
            model: "test-model",
            cwd: cwd,
            prompt: "deadline",
            providerThreadId: "provider-thread"
        )
        let operations: [(method: String, invoke: (CodexAppServerClient) async throws -> Void)] = [
            ("initialize", { _ = try await $0.initialize() }),
            ("model/list", { _ = try await $0.listModels() }),
            ("thread/start", { _ = try await $0.openThread(for: startRequest) }),
            ("thread/resume", { _ = try await $0.openThread(for: resumeRequest) }),
            ("turn/start", { _ = try await $0.startTurn(providerThreadId: "provider-thread", for: startRequest) }),
            ("turn/interrupt", { try await $0.interruptTurn(providerThreadId: "provider-thread", turnId: "turn") }),
            ("thread/read", { _ = try await $0.readThread(providerThreadId: "provider-thread") }),
            ("thread/fork", { _ = try await $0.forkThread(providerThreadId: "provider-thread") }),
            ("thread/rollback", { _ = try await $0.rollbackThread(providerThreadId: "provider-thread", numTurns: 1) }),
            ("thread/settings/update", { try await $0.updateThreadSettings(providerThreadId: "provider-thread", permissionMode: .fullAccess) })
        ]

        for operation in operations {
            let script = try makeSilentAppServerPeer()
            let client = try CodexAppServerClient(
                binary: script,
                arguments: [],
                cwd: cwd,
                requestTimeout: 0.03
            )
            let pid = try silentPeerPID(for: script)
            let startedAt = Date()
            do {
                try await operation.invoke(client)
                XCTFail("\(operation.method) must not outlive its deadline")
            } catch let error as CodexAppServerError {
                guard case .requestTimedOut(let method, _) = error else {
                    client.stop()
                    return XCTFail("\(operation.method) expected requestTimedOut, got \(error)")
                }
                XCTAssertEqual(method, operation.method)
                XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
                XCTAssertTrue(isProcessAlive(pid),
                              "\(operation.method) timeout must leave its app-server peer available")
            }
            client.stop()
        }
    }

    func test_appServerClientInitializesAndRoutesServerMessagesWithoutJsonrpcField() async throws {
        let script = try makeFakeAppServerPeer()
        let notifications = LockedPairs()
        let requests = LockedPairs()

        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path,
            notificationHandler: { method, params in
                let itemId = (params as? [String: Any])?["itemId"] as? String ?? ""
                notifications.append((method, itemId))
            },
            serverRequestHandler: { method, params in
                let itemId = (params as? [String: Any])?["itemId"] as? String ?? ""
                requests.append((method, itemId))
                return [
                    "answers": [
                        "approved": [
                            "answers": ["yes"]
                        ]
                    ]
                ]
            }
        )
        defer { client.stop() }

        let initialized = try await client.initialize(
            clientName: "remotecode-test",
            clientTitle: "RemoteCode Test",
            clientVersion: "0.0.0"
        )
        let thread: [String: Any] = try await client.requestJSONObject(
            method: "thread/start",
            params: ["cwd": "/tmp/remotecode-app-server-test"]
        )

        XCTAssertEqual(initialized.userAgent, "fake-codex-app-server")
        XCTAssertEqual(initialized.codexHome, "/tmp/fake-codex-home")
        XCTAssertEqual(initialized.platformFamily, "unix")
        XCTAssertEqual(initialized.platformOs, "macos")
        let recordedNotifications = notifications.values()
        let recordedRequests = requests.values()
        XCTAssertEqual(recordedNotifications.first?.0, "item/agentMessage/delta",
                       "RemoteCode must consume app-server notifications while an initialize request is still pending")
        XCTAssertEqual(recordedNotifications.first?.1, "item-1")
        XCTAssertEqual(recordedRequests.first?.0, "item/tool/requestUserInput",
                       "RemoteCode must answer app-server server-to-client requests, otherwise approvals/user input can freeze the agent turn")
        XCTAssertEqual(recordedRequests.first?.1, "item-approval-1")
        XCTAssertEqual(thread["id"] as? String, "thread-1")
        XCTAssertEqual(thread["origin"] as? String, "codex-app-server")
    }

    func test_appServerClientRespondsToStringIdServerRequests() async throws {
        let script = try makeFakeAppServerPeer()
        let requests = LockedPairs()

        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path,
            serverRequestHandler: { method, params in
                let itemId = (params as? [String: Any])?["itemId"] as? String ?? ""
                requests.append((method, itemId))
                return ["answers": ["question-1": ["answers": ["continue"]]]]
            }
        )
        defer { client.stop() }

        _ = try await client.initialize()
        let result: [String: Any] = try await client.requestJSONObject(
            method: "test/stringIdRequest",
            params: [:]
        )

        let recordedRequests = requests.values()
        XCTAssertTrue(recordedRequests.contains { $0.0 == "item/tool/requestUserInput" && $0.1 == "item-string-request-1" },
                       "Codex app-server may use JSON-RPC string ids for provider questions; RemoteCode must answer them or the turn can wait forever without a final response")
        XCTAssertEqual(result["answered"] as? Bool, true)
    }

    func test_openThreadResumesAndFallsBackToStartOnlyForRecoverableStaleThread() async throws {
        let script = try makeFakeAppServerPeer()
        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path
        )
        defer { client.stop() }

        _ = try await client.initialize()
        let opened = try await client.openThread(for: AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .codex,
            model: "gpt-5.3-codex",
            cwd: "/tmp/remotecode-app-server-test",
            prompt: "continue",
            providerThreadId: "stale-thread",
            permissionMode: .fullAccess,
            serviceTier: .fast
        ))

        XCTAssertEqual(opened.providerThreadId, "fresh-thread",
                       "stale app-server resume cursors must recover with a fresh thread/start instead of leaving Agent App stuck running forever")
        XCTAssertEqual(opened.response["lastMethod"] as? String, "thread/start")
        let params = try XCTUnwrap(opened.response["lastParams"] as? [String: Any])
        XCTAssertEqual(params["cwd"] as? String, "/tmp/remotecode-app-server-test")
        XCTAssertEqual(params["model"] as? String, "gpt-5.3-codex")
        XCTAssertEqual(params["serviceTier"] as? String, "fast")
        XCTAssertEqual(params["approvalPolicy"] as? String, "never")
        XCTAssertEqual(params["sandbox"] as? String, "danger-full-access")
    }

    func test_timedOutThreadResumeRequiresFreshClientRecovery() {
        XCTAssertTrue(
            CodexAppServerClient.requiresFreshClientAfterThreadResumeFailure(
                CodexAppServerError.requestTimedOut(method: "thread/resume", timeout: 30)
            ),
            "a timed-out resume has uncertain thread-open state, so recovery retries it with a new client"
        )
        XCTAssertFalse(
            CodexAppServerClient.requiresFreshClientAfterThreadResumeFailure(
                CodexAppServerError.requestTimedOut(method: "turn/start", timeout: 30)
            ),
            "a turn-start timeout is not a context-loss signal and must not be converted into a new-thread fallback"
        )
        XCTAssertTrue(
            CodexAppServerClient.isDeadAppServerFailure(
                CodexAppServerError.processExited(stderrTail: "panic")
            ),
            "a dead app-server must fail fast instead of spending the slow-resume budget"
        )
        XCTAssertFalse(
            CodexAppServerClient.isDeadAppServerFailure(
                CodexAppServerError.requestTimedOut(method: "thread/resume", timeout: 30)
            ),
            "a still-alive but slow resume is retriable, not a dead-peer signal"
        )
        let timeoutMessage = String(describing: CodexAppServerError.requestTimedOut(method: "thread/resume", timeout: 30))
        XCTAssertTrue(timeoutMessage.contains("thread/resume"), timeoutMessage)
        XCTAssertTrue(timeoutMessage.contains("30s") || timeoutMessage.contains("30"), timeoutMessage)
        XCTAssertTrue(
            timeoutMessage.localizedCaseInsensitiveContains("retry")
                || timeoutMessage.localizedCaseInsensitiveContains("new thread"),
            "timeout text must tell the user what to do: \(timeoutMessage)"
        )
        let exhausted = String(describing: CodexAppServerError.threadResumeUnavailable(attempts: 3, elapsedBound: 91.5))
        XCTAssertTrue(exhausted.contains("thread/resume"), exhausted)
        XCTAssertTrue(exhausted.contains("3"), exhausted)
    }

    func test_forkThread_usesNativeProviderBranchAndReturnsChildThreadId() async throws {
        let script = try makeFakeAppServerPeer()
        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path
        )
        defer { client.stop() }

        _ = try await client.initialize()
        let childProviderThreadId = try await client.forkThread(
            providerThreadId: "parent-thread",
            lastTurnId: "turn-2"
        )

        XCTAssertEqual(childProviderThreadId, "forked-parent-thread-through-turn-2",
                       "thread/fork must send the exact parent threadId and optional lastTurnId, then decode result.thread.id")
    }

    func test_keyedForkListAndDeletePreserveExactReconciliationIdentity() async throws {
        let script = try makeFakeAppServerPeer()
        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path,
            forkProtocolSupportOverride: CodexForkProtocolSupport(
                isSupported: true,
                reason: "test schema"
            )
        )
        defer { client.stop() }
        _ = try await client.initialize()

        let marker = "remotecode-thread-fork:child-a"
        let first = try await client.forkThread(
            providerThreadId: "parent-thread",
            lastTurnId: nil,
            threadSource: marker
        )
        _ = try await client.forkThread(
            providerThreadId: "other-parent",
            lastTurnId: nil,
            threadSource: "other-marker"
        )

        XCTAssertEqual(first.forkedFromId, "parent-thread")
        XCTAssertEqual(first.threadSource, marker,
                       "the provider response must echo the exact durable marker before RemoteCode accepts the child identity")
        let firstPage = try await client.listThreads(cursor: nil, archived: false)
        XCTAssertEqual(firstPage.threads.map(\.threadSource), [marker])
        let secondPage = try await client.listThreads(cursor: firstPage.nextCursor, archived: false)
        XCTAssertEqual(secondPage.threads.map(\.threadSource), ["other-marker"],
                       "thread/list pagination must expose every candidate so a retry cannot miss an older provider child")
        XCTAssertNil(secondPage.nextCursor)

        try await client.deleteThread(providerThreadId: first.id)
        let remaining = try await client.listThreads(cursor: nil, archived: false)
        XCTAssertFalse(remaining.threads.contains { $0.id == first.id },
                       "thread/delete must remove the exact compensated provider child")
    }

    func test_modelListDiscoversReasoningFastTierAndContextWindowFromAppServer() async throws {
        let script = try makeFakeAppServerPeer()
        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path
        )
        defer { client.stop() }

        _ = try await client.initialize()
        let models = try await client.listModels()

        let primary = try XCTUnwrap(models.first { $0.id == "gpt-5.7-codex" })
        XCTAssertEqual(primary.label, "GPT-5.7 Codex")
        XCTAssertEqual(primary.supportedReasoningEfforts, [.low, .medium, .high, .xhigh],
                       "Codex app-server model/list must drive legal reasoning controls instead of static RemoteCode guesses")
        XCTAssertTrue(primary.supportsServiceTier,
                      "Codex fast-tier UI must come from app-server additionalSpeedTiers when available")
        XCTAssertEqual(primary.contextWindowTokens, 400_000)

        let economy = try XCTUnwrap(models.first { $0.id == "gpt-5.7-economy" })
        XCTAssertFalse(economy.supportsServiceTier,
                       "models without the fast speed tier must not expose Codex fast mode")
    }

    func test_staticModelParserAcceptsStringReasoningFallbackShape() {
        let models = CodexAppServerClient.modelDescriptors(fromModelListResponse: [
            "models": [[
                "id": "gpt-5.7-mini",
                "name": "GPT-5.7 Mini",
                "supportedReasoningEfforts": ["low", "medium"],
                "additional_speed_tiers": ["fast"],
                "maxTokens": "128000"
            ]]
        ])

        XCTAssertEqual(models.first?.id, "gpt-5.7-mini")
        XCTAssertEqual(models.first?.supportedReasoningEfforts, [.low, .medium])
        XCTAssertEqual(models.first?.supportsServiceTier, true)
        XCTAssertEqual(models.first?.contextWindowTokens, 128_000)
    }

    func test_startTurnSendsPromptImagesModeAndRuntimePolicyThroughAppServerProtocol() async throws {
        let script = try makeFakeAppServerPeer()
        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path
        )
        defer { client.stop() }

        _ = try await client.initialize()
        let response = try await client.startTurn(
            providerThreadId: "thread-app-server-1",
            for: AgentRunRequest(
                threadId: AgentThreadID(),
                provider: .codex,
                model: "gpt-5.5",
                cwd: "/tmp/remotecode-app-server-test",
                prompt: "draft a plan",
                attachments: [
                    AgentAttachment(path: "/tmp/screenshot.png", kind: .image),
                    AgentAttachment(path: "/tmp/notes.txt", kind: .file)
                ],
                permissionMode: .autoAcceptEdits,
                reasoningEffort: .high,
                serviceTier: .fast,
                interactionMode: .plan
            )
        )

        XCTAssertEqual((response["turn"] as? [String: Any])?["id"] as? String, "turn-started-1")
        let params = try XCTUnwrap(response["lastParams"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "thread-app-server-1")
        XCTAssertEqual(params["approvalPolicy"] as? String, "on-request")
        XCTAssertEqual(params["serviceTier"] as? String, "fast")
        XCTAssertEqual(params["effort"] as? String, "high")
        XCTAssertEqual((params["sandboxPolicy"] as? [String: Any])?["type"] as? String, "workspaceWrite")

        let input = try XCTUnwrap(params["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 3, "app-server turns must send image attachments and file mentions through native protocol input items")
        XCTAssertEqual(input[0]["type"] as? String, "text")
        XCTAssertEqual(input[0]["text"] as? String, "draft a plan")
        let textElements = try XCTUnwrap(input[0]["text_elements"] as? [Any],
                                         "Codex 0.146 UserInput text requires text_elements")
        XCTAssertTrue(textElements.isEmpty, "unused text spans must still be sent as an empty array")
        XCTAssertEqual(input[1]["type"] as? String, "localImage")
        XCTAssertEqual(input[1]["path"] as? String, "/tmp/screenshot.png")
        XCTAssertNil(input[1]["url"], "local images must use the app-server localImage/path contract, never a file:// remote-image URL")
        XCTAssertEqual(input[2]["type"] as? String, "mention")
        XCTAssertEqual(input[2]["name"] as? String, "notes.txt")
        XCTAssertEqual(input[2]["path"] as? String, "/tmp/notes.txt")

        let collaboration = try XCTUnwrap(params["collaborationMode"] as? [String: Any])
        XCTAssertEqual(collaboration["mode"] as? String, "plan")
        let settings = try XCTUnwrap(collaboration["settings"] as? [String: Any])
        XCTAssertEqual(settings["model"] as? String, "gpt-5.5")
        XCTAssertEqual(settings["reasoning_effort"] as? String, "high")
        XCTAssertTrue((settings["developer_instructions"] as? String)?.contains("Plan only") == true,
                      "Plan mode must travel as app-server collaborationMode, not only as prompt text")
    }

    func test_startTurnClampsMinimalReasoningToLowForAppServerToolsAndCompaction() async throws {
        let script = try makeFakeAppServerPeer()
        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path
        )
        defer { client.stop() }

        _ = try await client.initialize()
        let response = try await client.startTurn(
            providerThreadId: "thread-app-server-1",
            for: AgentRunRequest(
                threadId: AgentThreadID(),
                provider: .codex,
                model: "gpt-5.5",
                cwd: "/tmp/remotecode-app-server-test",
                prompt: "compact-safe",
                reasoningEffort: .minimal
            )
        )

        let params = try XCTUnwrap(response["lastParams"] as? [String: Any])
        XCTAssertEqual(params["effort"] as? String, "low",
                       "Codex app-server enables provider tools such as image_gen/web_search; minimal effort makes native compaction fail.")
        let collaboration = try XCTUnwrap(params["collaborationMode"] as? [String: Any])
        let settings = try XCTUnwrap(collaboration["settings"] as? [String: Any])
        XCTAssertEqual(settings["reasoning_effort"] as? String, "low",
                       "Manual/native compaction inherits collaborationMode settings, so the clamped effort must be present there too.")
    }

    func test_threadReadRollbackAndInterruptUseNativeCodexAppServerMethods() async throws {
        let script = try makeFakeAppServerPeer()
        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path
        )
        defer { client.stop() }

        _ = try await client.initialize()
        let read = try await client.readThread(providerThreadId: "thread-app-server-1")
        let rolledBack = try await client.rollbackThread(providerThreadId: "thread-app-server-1", numTurns: 2)
        try await client.interruptTurn(providerThreadId: "thread-app-server-1", turnId: "turn-app-server-1")

        XCTAssertEqual(read["lastMethod"] as? String, "thread/read")
        XCTAssertEqual((read["lastParams"] as? [String: Any])?["includeTurns"] as? Bool, true)
        XCTAssertEqual(rolledBack["lastMethod"] as? String, "thread/rollback")
        XCTAssertEqual((rolledBack["lastParams"] as? [String: Any])?["numTurns"] as? Int, 2)
    }

    func test_updateThreadSettingsSendsFullAccessRuntimePolicy() async throws {
        let script = try makeFakeAppServerPeer()
        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path
        )
        defer { client.stop() }

        _ = try await client.initialize()
        let response = try await client.requestJSONObject(method: "thread/read", params: ["threadId": "thread-app-server-1"])
        XCTAssertEqual(response["lastMethod"] as? String, "thread/read")

        try await client.updateThreadSettings(providerThreadId: "thread-app-server-1", permissionMode: .fullAccess)
        let update = try await client.requestJSONObject(method: "test/lastThreadSettingsUpdate")
        XCTAssertEqual(update["lastMethod"] as? String, "thread/settings/update")
        let params = try XCTUnwrap(update["lastParams"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "thread-app-server-1")
        XCTAssertEqual(params["approvalPolicy"] as? String, "never")
        XCTAssertEqual((params["sandboxPolicy"] as? [String: Any])?["type"] as? String, "dangerFullAccess")
    }

    func test_startTurnTokenSaverActiveSupervisedAddsNetworkAccessToReadOnlySandbox() async throws {
        // WHY: Codex's seatbelt denies all network by default under readOnly/workspaceWrite,
        // blocking the Token Saver ledger POST. When Token Saver is admitted for this run,
        // networkAccess is added so the ledger POST can succeed; filesystem restrictions from
        // readOnly are unaffected. This must apply the SAME way to a primary run, a
        // same-provider subagent, and a cross-provider nested run — the gate is "is Token
        // Saver active", never "what kind of run is this".
        let script = try makeFakeAppServerPeer()
        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path
        )
        defer { client.stop() }

        _ = try await client.initialize()
        let response = try await client.startTurn(
            providerThreadId: "thread-app-server-1",
            for: AgentRunRequest(
                threadId: AgentThreadID(),
                provider: .codex,
                model: "gpt-5.5",
                cwd: "/tmp/remotecode-app-server-test",
                prompt: "token saver active supervised",
                permissionMode: .supervised,
                environment: ["RC_TOKEN_SAVER_DISTILL_HINT": "1"]
            )
        )

        let params = try XCTUnwrap(response["lastParams"] as? [String: Any])
        let sandboxPolicy = try XCTUnwrap(params["sandboxPolicy"] as? [String: Any])
        XCTAssertEqual(sandboxPolicy["type"] as? String, "readOnly")
        XCTAssertEqual(sandboxPolicy["networkAccess"] as? Bool, true)
    }

    func test_startTurnTokenSaverActiveAutoAcceptEditsAddsNetworkAccessToWorkspaceWriteSandbox() async throws {
        let script = try makeFakeAppServerPeer()
        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path
        )
        defer { client.stop() }

        _ = try await client.initialize()
        let response = try await client.startTurn(
            providerThreadId: "thread-app-server-1",
            for: AgentRunRequest(
                threadId: AgentThreadID(),
                provider: .codex,
                model: "gpt-5.5",
                cwd: "/tmp/remotecode-app-server-test",
                prompt: "token saver active workspace write",
                permissionMode: .autoAcceptEdits,
                environment: ["RC_TOKEN_SAVER_DISTILL_HINT": "1"]
            )
        )

        let params = try XCTUnwrap(response["lastParams"] as? [String: Any])
        let sandboxPolicy = try XCTUnwrap(params["sandboxPolicy"] as? [String: Any])
        XCTAssertEqual(sandboxPolicy["type"] as? String, "workspaceWrite")
        XCTAssertEqual(sandboxPolicy["networkAccess"] as? Bool, true)
        XCTAssertEqual(sandboxPolicy["writableRoots"] as? [String], [])
        XCTAssertEqual(sandboxPolicy["excludeTmpdirEnvVar"] as? Bool, false)
        XCTAssertEqual(sandboxPolicy["excludeSlashTmp"] as? Bool, false)
    }

    func test_startTurnTokenSaverActiveFullAccessNeverGetsNetworkAccessKey() async throws {
        // WHY: Full Access has no seatbelt at all (already unrestricted). It must stay exactly
        // {"type": "dangerFullAccess"} — adding networkAccess there would be meaningless and
        // could mask a future protocol change silently.
        let script = try makeFakeAppServerPeer()
        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path
        )
        defer { client.stop() }

        _ = try await client.initialize()
        let response = try await client.startTurn(
            providerThreadId: "thread-app-server-1",
            for: AgentRunRequest(
                threadId: AgentThreadID(),
                provider: .codex,
                model: "gpt-5.5",
                cwd: "/tmp/remotecode-app-server-test",
                prompt: "token saver active full access",
                permissionMode: .fullAccess,
                environment: ["RC_TOKEN_SAVER_DISTILL_HINT": "1"]
            )
        )

        let params = try XCTUnwrap(response["lastParams"] as? [String: Any])
        let sandboxPolicy = try XCTUnwrap(params["sandboxPolicy"] as? [String: Any])
        XCTAssertEqual(sandboxPolicy["type"] as? String, "dangerFullAccess")
        XCTAssertNil(sandboxPolicy["networkAccess"], "dangerFullAccess must never carry a networkAccess key")
        XCTAssertEqual(sandboxPolicy.count, 1, "dangerFullAccess sandbox policy must stay exactly {type} even with Token Saver active")
    }

    func test_turnStartParams_sandboxPolicyIsCompleteWithAndWithoutTokenSaver() throws {
        // WHY: Codex 0.146 SandboxPolicy requires complete objects (networkAccess on
        // readOnly; writableRoots/networkAccess/exclude* on workspaceWrite). Token Saver
        // only flips networkAccess true/false — it must not omit required keys when off.
        // Uses static turnStartParams so this is independent of the fake peer process.
        func policy(mode: AgentPermissionMode, tokenSaver: Bool) throws -> [String: Any] {
            var env: [String: String] = ["RC_REMOTE_CODE_SUBAGENT_THREAD_ID": UUID().uuidString]
            if tokenSaver { env["RC_TOKEN_SAVER_DISTILL_HINT"] = "1" }
            let params = CodexAppServerClient.turnStartParams(
                providerThreadId: "thread-app-server-1",
                for: AgentRunRequest(
                    threadId: AgentThreadID(),
                    provider: .codex,
                    model: "gpt-5.5",
                    cwd: "/tmp/remotecode-app-server-test",
                    prompt: "sandbox \(mode) ts=\(tokenSaver)",
                    permissionMode: mode,
                    environment: env
                )
            )
            return try XCTUnwrap(params["sandboxPolicy"] as? [String: Any])
        }

        // Token Saver off — complete policies with networkAccess: false.
        let supervisedOff = try policy(mode: .supervised, tokenSaver: false)
        XCTAssertEqual(supervisedOff["type"] as? String, "readOnly")
        XCTAssertEqual(supervisedOff["networkAccess"] as? Bool, false,
                       "TS off: networkAccess must be explicit false, not omitted")

        let workspaceOff = try policy(mode: .autoAcceptEdits, tokenSaver: false)
        XCTAssertEqual(workspaceOff["type"] as? String, "workspaceWrite")
        XCTAssertEqual(workspaceOff["networkAccess"] as? Bool, false)
        XCTAssertEqual(workspaceOff["writableRoots"] as? [String], [])
        XCTAssertEqual(workspaceOff["excludeTmpdirEnvVar"] as? Bool, false)
        XCTAssertEqual(workspaceOff["excludeSlashTmp"] as? Bool, false)

        let fullOff = try policy(mode: .fullAccess, tokenSaver: false)
        XCTAssertEqual(fullOff["type"] as? String, "dangerFullAccess")
        XCTAssertNil(fullOff["networkAccess"])
        XCTAssertEqual(fullOff.count, 1)

        // Token Saver on — same complete shape, networkAccess true for sandboxed modes.
        let supervisedOn = try policy(mode: .supervised, tokenSaver: true)
        XCTAssertEqual(supervisedOn["type"] as? String, "readOnly")
        XCTAssertEqual(supervisedOn["networkAccess"] as? Bool, true)

        let workspaceOn = try policy(mode: .autoAcceptEdits, tokenSaver: true)
        XCTAssertEqual(workspaceOn["type"] as? String, "workspaceWrite")
        XCTAssertEqual(workspaceOn["networkAccess"] as? Bool, true)
        XCTAssertEqual(workspaceOn["writableRoots"] as? [String], [])
        XCTAssertEqual(workspaceOn["excludeTmpdirEnvVar"] as? Bool, false)
        XCTAssertEqual(workspaceOn["excludeSlashTmp"] as? Bool, false)

        let fullOn = try policy(mode: .fullAccess, tokenSaver: true)
        XCTAssertEqual(fullOn["type"] as? String, "dangerFullAccess")
        XCTAssertNil(fullOn["networkAccess"])
        XCTAssertEqual(fullOn.count, 1)
    }

    func test_turnStartParams_textInputIncludesEmptyTextElements() throws {
        // WHY: Codex 0.146 UserInput text requires text_elements (empty when unused).
        let params = CodexAppServerClient.turnStartParams(
            providerThreadId: "thread-app-server-1",
            for: AgentRunRequest(
                threadId: AgentThreadID(),
                provider: .codex,
                model: "gpt-5.5",
                cwd: "/tmp/remotecode-app-server-test",
                prompt: "hello text elements"
            )
        )
        let input = try XCTUnwrap(params["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["type"] as? String, "text")
        XCTAssertEqual(input.first?["text"] as? String, "hello text elements")
        let textElements = try XCTUnwrap(input.first?["text_elements"] as? [Any])
        XCTAssertTrue(textElements.isEmpty)
    }

    func test_initializeCapabilities_includesRequestAttestationFalse() throws {
        // WHY: InitializeCapabilities requires requestAttestation. RemoteCode does not
        // implement attestation/generate, so it must negotiate false explicitly.
        let capabilities = CodexAppServerClient.initializeCapabilities()
        XCTAssertEqual(capabilities["experimentalApi"] as? Bool, true)
        XCTAssertEqual(capabilities["requestAttestation"] as? Bool, false,
                       "must refuse attestation opt-in so Codex does not send attestation/generate")
    }

    func test_tokenSaverHint_drivesFullDistillSpecInDeveloperInstructions() async throws {
        let script = try makeFakeAppServerPeer()
        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path
        )
        defer { client.stop() }
        _ = try await client.initialize()

        // WHY: Distill is paid (Token Saver). developer_instructions carry language +
        // `| distill` only when RC_TOKEN_SAVER_DISTILL_HINT=1 — never via ~/.codex/skills.
        let withHint = try await client.startTurn(
            providerThreadId: "thread-app-server-1",
            for: AgentRunRequest(
                threadId: AgentThreadID(),
                provider: .codex,
                model: "gpt-5.5",
                cwd: "/tmp/remotecode-app-server-test",
                prompt: "explore",
                environment: ["RC_TOKEN_SAVER_DISTILL_HINT": "1"]
            )
        )
        let hintInstructions = try XCTUnwrap(collaborationSettings(from: withHint)["developer_instructions"] as? String)
        XCTAssertTrue(
            hintInstructions.contains("| distill"),
            "Token Saver on: Codex developer_instructions must instruct `| distill`"
        )
        // Parity with Claude's per-session systemPrompt: full distill LANGUAGE spec per turn.
        // "Registers:" is the register/prefix legend from the full distill body; a bare
        // "| distill" pipe rule never carries it, so this proves the full spec is injected.
        XCTAssertTrue(
            hintInstructions.contains("R0 micro") && hintInstructions.contains("R1 work"),
            "Codex developer_instructions must carry the full distill language spec, not only the pipe rule"
        )
        XCTAssertEqual(
            hintInstructions.components(separatedBy: TokenSaverProviderSafetyABI.block).count - 1,
            1,
            "Codex receives the versioned Token Saver safety ABI exactly once"
        )
        XCTAssertEqual(
            (AgentSkillInstaller.distillAgentInstructionsTemplate + "\n\n" + hintInstructions)
                .components(separatedBy: TokenSaverProviderSafetyABI.block).count - 1,
            1,
            "Codex effective disk plus runtime context receives the safety ABI exactly once"
        )

        // Token Saver off → base mode instructions only, no Distill.
        let withoutHint = try await client.startTurn(
            providerThreadId: "thread-app-server-1",
            for: AgentRunRequest(
                threadId: AgentThreadID(),
                provider: .codex,
                model: "gpt-5.5",
                cwd: "/tmp/remotecode-app-server-test",
                prompt: "explore"
            )
        )
        let emptyEnvInstructions = try XCTUnwrap(
            try collaborationSettings(from: withoutHint)["developer_instructions"] as? String
        )
        XCTAssertFalse(
            emptyEnvInstructions.contains("| distill"),
            "Token Saver off must not inject Distill into Codex"
        )
        XCTAssertFalse(
            emptyEnvInstructions.contains(TokenSaverProviderSafetyABI.block),
            "Token Saver off must not inject safety ABI"
        )
    }

    func test_developerInstructions_includeBackgroundAwaitDirectiveNotClaudeMCP() async throws {
        // WHY: Codex never received systemPromptDirective, so the deterministic
        // [[RC_AWAITING]] self-declare path was dead even when the model would
        // comply. Injection must be additive and must NOT pull Claude-only MCP rules.
        let script = try makeFakeAppServerPeer()
        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path
        )
        defer { client.stop() }
        _ = try await client.initialize()

        let response = try await client.startTurn(
            providerThreadId: "thread-app-server-1",
            for: AgentRunRequest(
                threadId: AgentThreadID(),
                provider: .codex,
                model: "gpt-5.5",
                cwd: "/tmp/remotecode-app-server-test",
                prompt: "explore"
            )
        )
        let instructions = try XCTUnwrap(
            try collaborationSettings(from: response)["developer_instructions"] as? String
        )
        XCTAssertTrue(
            instructions.contains(BackgroundAwaitContinuation.awaitingMarker),
            "Codex developer_instructions must include the exact [[RC_AWAITING]] token"
        )
        XCTAssertTrue(
            instructions.contains("Background-await protocol"),
            "Codex must receive systemPromptDirective"
        )
        XCTAssertFalse(
            instructions.contains(BackgroundAwaitContinuation.mcpToolAvailabilityDirective),
            "must not inject Claude-only mcpToolAvailabilityDirective"
        )
        XCTAssertFalse(
            instructions.contains(BackgroundAwaitContinuation.mcpConnectWaitDirective),
            "must not inject Claude-only mcpConnectWaitDirective"
        )
        XCTAssertFalse(
            instructions.contains("RefreshMcpTools"),
            "Claude-only MCP connect-wait wording must not appear on Codex"
        )
    }

    func test_nonJSONStdoutNoiseLineDoesNotFailPendingRPCs() async throws {
        // WHY: the codex binary can print plain-text banners/update notices to
        // stdout between JSON-RPC frames. One such line must not fail every
        // in-flight request (thread/resume, turn/start) — the server is healthy
        // and answers right after the noise, so failing the pending RPCs would
        // abort a run start for no reason.
        let script = try makeFakeAppServerPeer()
        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path
        )
        defer { client.stop() }

        _ = try await client.initialize()
        let result = try await client.requestJSONObject(method: "test/noise")
        XCTAssertEqual(result["ok"] as? Bool, true,
                       "an RPC in flight while a non-JSON stdout line arrives must still resolve from its real JSON response")
    }

    func test_processExitIncludesStderrTailInTerminationError() async throws {
        // WHY: when `codex app-server` panics/exits early, the actual reason is
        // on stderr. The processExited error must carry that tail — otherwise
        // the user's error banner is the tautological "process exited: process
        // exited" and the one line explaining the failure is discarded.
        let script = try makeCrashingAppServerPeer(stderrMessage: "thread 'main' panicked: unsupported --flag")
        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path
        )
        defer { client.stop() }

        do {
            _ = try await client.initialize()
            XCTFail("initialize must fail when the app-server dies before answering")
        } catch {
            XCTAssertTrue(String(describing: error).contains("unsupported --flag"),
                          "the processExited error must include the stderr tail explaining why the server died; got: \(error)")
        }
    }

    func test_notificationAfterProcessExitThrowsTypedErrorInsteadOfWritingClosedStdin() async throws {
        // WHY: a provider can die between RPCs. The next host notification must
        // fail at the adapter boundary instead of raising SIGPIPE or hanging.
        let script = try makeInitializingThenExitingAppServerPeer()
        let terminated = expectation(description: "app-server terminated")
        let client = try CodexAppServerClient(
            binary: script,
            arguments: [],
            cwd: FileManager.default.temporaryDirectory.path
        )
        client.terminationHandler = { _ in terminated.fulfill() }
        defer { client.stop() }

        _ = try await client.initialize()
        await fulfillment(of: [terminated], timeout: 3)

        XCTAssertThrowsError(try client.notify(method: "host/after_exit")) { error in
            guard case CodexAppServerError.processExited = error else {
                return XCTFail("expected typed processExited, got \(error)")
            }
        }
    }

    private func collaborationSettings(from response: [String: Any]) throws -> [String: Any] {
        let params = try XCTUnwrap(response["lastParams"] as? [String: Any])
        let collaboration = try XCTUnwrap(params["collaborationMode"] as? [String: Any])
        return try XCTUnwrap(collaboration["settings"] as? [String: Any])
    }

    private func makeFakeAppServerPeer() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remotecode-codex-app-server-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("fake-codex-app-server.py")
        let source = """
        #!/usr/bin/env python3
        import json
        import sys

        last_thread_settings_update = {}
        last_initialize = {}
        forked_threads = []
        for line in sys.stdin:
            msg = json.loads(line)
            method = msg.get("method")
            if method == "initialize":
                last_initialize = {
                    "lastMethod": method,
                    "lastParams": msg.get("params", {})
                }
                print(json.dumps({
                    "method": "item/agentMessage/delta",
                    "params": {
                        "delta": "hello",
                        "itemId": "item-1",
                        "threadId": "thread-1",
                        "turnId": "turn-1"
                    }
                }), flush=True)
                print(json.dumps({
                    "id": 77,
                    "method": "item/tool/requestUserInput",
                    "params": {
                        "itemId": "item-approval-1",
                        "threadId": "thread-1",
                        "turnId": "turn-1",
                        "questions": [
                            {
                                "id": "approved",
                                "header": "Approve",
                                "question": "Continue?"
                            }
                        ]
                    }
                }), flush=True)
                print(json.dumps({
                    "id": msg["id"],
                    "result": {
                        "userAgent": "fake-codex-app-server",
                        "codexHome": "/tmp/fake-codex-home",
                        "platformFamily": "unix",
                        "platformOs": "macos"
                    }
                }), flush=True)
            elif method == "thread/start":
                print(json.dumps({
                    "id": msg["id"],
                    "result": {
                        "id": "thread-1",
                        "origin": "codex-app-server",
                        "lastMethod": method,
                        "lastParams": msg.get("params", {}),
                        "thread": {
                            "id": "fresh-thread",
                            "turns": [],
                            "status": {"state": "idle", "activeFlags": []}
                        },
                        "turns": []
                    }
                }), flush=True)
            elif method == "thread/resume":
                print(json.dumps({
                    "id": msg["id"],
                    "error": {
                        "code": -32603,
                        "message": "thread not found"
                    }
                }), flush=True)
            elif method == "thread/fork":
                params = msg.get("params", {})
                thread = {
                    "id": "forked-" + params.get("threadId", "missing") + "-through-" + params.get("lastTurnId", "all"),
                    "forkedFromId": params.get("threadId"),
                    "threadSource": params.get("threadSource"),
                    "createdAt": len(forked_threads) + 1,
                    "turns": [],
                    "status": {"state": "idle", "activeFlags": []}
                }
                forked_threads.append(thread)
                print(json.dumps({
                    "id": msg["id"],
                    "result": {
                        "thread": thread
                    }
                }), flush=True)
            elif method == "thread/list":
                params = msg.get("params", {})
                if params.get("archived"):
                    page = []
                    next_cursor = None
                else:
                    offset = int(params.get("cursor", "0"))
                    page = forked_threads[offset:offset + 1]
                    next_cursor = str(offset + 1) if offset + 1 < len(forked_threads) else None
                print(json.dumps({
                    "id": msg["id"],
                    "result": {"data": page, "nextCursor": next_cursor}
                }), flush=True)
            elif method == "thread/delete":
                thread_id = msg.get("params", {}).get("threadId")
                forked_threads[:] = [thread for thread in forked_threads if thread.get("id") != thread_id]
                print(json.dumps({"id": msg["id"], "result": {}}), flush=True)
            elif method == "model/list":
                cursor = msg.get("params", {}).get("cursor")
                if cursor == "page-2":
                    print(json.dumps({
                        "id": msg["id"],
                        "result": {
                            "data": [
                                {
                                    "model": "gpt-5.7-economy",
                                    "displayName": "GPT-5.7 Economy",
                                    "supportedReasoningEfforts": [
                                        {"reasoningEffort": "low"},
                                        {"reasoningEffort": "medium"}
                                    ],
                                    "defaultReasoningEffort": "medium",
                                    "additionalSpeedTiers": [],
                                    "modelContextWindow": 200000
                                }
                            ]
                        }
                    }), flush=True)
                else:
                    print(json.dumps({
                        "id": msg["id"],
                        "result": {
                            "data": [
                                {
                                    "model": "gpt-5.7-codex",
                                    "displayName": "GPT-5.7 Codex",
                                    "supportedReasoningEfforts": [
                                        {"reasoningEffort": "low"},
                                        {"reasoningEffort": "medium"},
                                        {"reasoningEffort": "high"},
                                        {"reasoningEffort": "xhigh"}
                                    ],
                                    "defaultReasoningEffort": "medium",
                                    "additionalSpeedTiers": ["fast"],
                                    "modelContextWindow": 400000
                                }
                            ],
                            "nextCursor": "page-2"
                        }
                    }), flush=True)
            elif method == "turn/start":
                print(json.dumps({
                    "id": msg["id"],
                    "result": {
                        "lastMethod": method,
                        "lastParams": msg.get("params", {}),
                        "turn": {
                            "id": "turn-started-1"
                        }
                    }
                }), flush=True)
            elif method == "thread/read":
                print(json.dumps({
                    "id": msg["id"],
                    "result": {
                        "lastMethod": method,
                        "lastParams": msg.get("params", {}),
                        "thread": {
                            "id": msg.get("params", {}).get("threadId", ""),
                            "turns": [],
                            "status": {"state": "idle", "activeFlags": []}
                        }
                    }
                }), flush=True)
            elif method == "thread/rollback":
                print(json.dumps({
                    "id": msg["id"],
                    "result": {
                        "lastMethod": method,
                        "lastParams": msg.get("params", {}),
                        "thread": {
                            "id": msg.get("params", {}).get("threadId", ""),
                            "turns": [],
                            "status": {"state": "idle", "activeFlags": []}
                        }
                    }
                }), flush=True)
            elif method == "thread/settings/update":
                last_thread_settings_update = {
                    "lastMethod": method,
                    "lastParams": msg.get("params", {})
                }
                print(json.dumps({
                    "id": msg["id"],
                    "result": last_thread_settings_update
                }), flush=True)
            elif method == "test/lastThreadSettingsUpdate":
                print(json.dumps({
                    "id": msg["id"],
                    "result": last_thread_settings_update
                }), flush=True)
            elif method == "test/lastInitialize":
                print(json.dumps({
                    "id": msg["id"],
                    "result": last_initialize
                }), flush=True)
            elif method == "test/stringIdRequest":
                print(json.dumps({
                    "id": "request-string-1",
                    "method": "item/tool/requestUserInput",
                    "params": {
                        "itemId": "item-string-request-1",
                        "threadId": "thread-1",
                        "turnId": "turn-1",
                        "questions": [
                            {
                                "id": "question-1",
                                "header": "Continue",
                                "question": "Continue?"
                            }
                        ]
                    }
                }), flush=True)
                for response_line in sys.stdin:
                    response = json.loads(response_line)
                    if response.get("id") == "request-string-1":
                        print(json.dumps({
                            "id": msg["id"],
                            "result": {"answered": True, "response": response}
                        }), flush=True)
                        break
            elif method == "turn/interrupt":
                print(json.dumps({
                    "id": msg["id"],
                    "result": {
                        "lastMethod": method,
                        "lastParams": msg.get("params", {})
                    }
                }), flush=True)
            elif method == "test/noise":
                print("codex v99 update available! run `codex upgrade` to update.", flush=True)
                print(json.dumps({
                    "id": msg["id"],
                    "result": {"ok": True}
                }), flush=True)
            elif msg.get("id") == 77:
                continue
            elif method == "initialized":
                continue
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    /// A peer that accepts the first request, prints a failure reason to
    /// stderr, and dies — the "codex app-server panics at startup" shape.
    /// It reads one stdin line first so the client's request write succeeds
    /// deterministically before the process exits.
    private func makeCrashingAppServerPeer(stderrMessage: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remotecode-codex-app-server-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("crashing-codex-app-server.py")
        let source = """
        #!/usr/bin/env python3
        import sys

        sys.stdin.readline()
        print("\(stderrMessage)", file=sys.stderr, flush=True)
        sys.exit(2)
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private func makeInitializingThenExitingAppServerPeer() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remotecode-codex-app-server-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("initializing-then-exiting-codex-app-server.py")
        let source = #"""
        #!/usr/bin/env python3
        import json, sys

        request = json.loads(sys.stdin.readline())
        print(json.dumps({"id": request["id"], "result": {"userAgent": "closed-stdin-peer"}}), flush=True)
        sys.stdin.readline()
        sys.exit(0)
        """#
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private func makeSilentAppServerPeer() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remotecode-codex-app-server-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("silent-codex-app-server.py")
        let source = """
        #!/usr/bin/env python3
        import os, pathlib, sys

        pathlib.Path(__file__ + '.pid').write_text(str(os.getpid()))

        for _ in sys.stdin:
            pass
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private func makeLateResponseAppServerPeer() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remotecode-codex-app-server-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("late-response-codex-app-server.py")
        let source = """
        #!/usr/bin/env python3
        import json, os, pathlib, sys, time

        pathlib.Path(__file__ + '.pid').write_text(str(os.getpid()))

        first = json.loads(sys.stdin.readline())
        time.sleep(0.08)
        print(json.dumps({"id": first["id"], "result": {"response": "late"}}), flush=True)
        pathlib.Path(__file__ + '.late').write_text('sent')

        for line in sys.stdin:
            request = json.loads(line)
            print(json.dumps({"id": request["id"], "result": {"response": "follow-up"}}), flush=True)
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private func silentPeerPID(for script: String) throws -> pid_t {
        let pidFile = script + ".pid"
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
               let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        throw NSError(domain: "CodexAppServerClientTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "silent peer did not persist its PID"
        ])
    }

    private func waitForFile(_ path: String) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return FileManager.default.fileExists(atPath: path)
    }

    private func isProcessAlive(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }
}

private final class LockedPairs: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(String, String)] = []

    func append(_ value: (String, String)) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    func values() -> [(String, String)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
