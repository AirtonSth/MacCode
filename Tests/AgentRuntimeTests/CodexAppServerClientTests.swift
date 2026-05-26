import XCTest
import CoreModel
@testable import AgentRuntime

final class CodexAppServerClientTests: XCTestCase {
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
        XCTAssertEqual(input[1]["type"] as? String, "image")
        XCTAssertEqual(input[1]["url"] as? String, "file:///tmp/screenshot.png")
        XCTAssertEqual(input[2]["type"] as? String, "mention")
        XCTAssertEqual(input[2]["name"] as? String, "notes.txt")
        XCTAssertEqual(input[2]["path"] as? String, "/tmp/notes.txt")

        let collaboration = try XCTUnwrap(params["collaborationMode"] as? [String: Any])
        XCTAssertEqual(collaboration["mode"] as? String, "plan")
        let settings = try XCTUnwrap(collaboration["settings"] as? [String: Any])
        XCTAssertEqual(settings["model"] as? String, "gpt-5.5")
        XCTAssertEqual(settings["reasoning_effort"] as? String, "high")
        XCTAssertTrue((settings["developer_instructions"] as? String)?.contains("plan only") == true,
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
        for line in sys.stdin:
            msg = json.loads(line)
            method = msg.get("method")
            if method == "initialize":
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
            elif method == "turn/interrupt":
                print(json.dumps({
                    "id": msg["id"],
                    "result": {
                        "lastMethod": method,
                        "lastParams": msg.get("params", {})
                    }
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
