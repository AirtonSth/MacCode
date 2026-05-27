import XCTest
import CoreModel
@testable import AgentRuntime

final class CodexAppServerAdapterTests: XCTestCase {
    func test_adapterRunsCodexTurnThroughAppServerSessionAndFinishesFromNotifications() async throws {
        let client = MockCodexAppServerClient()
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let threadId = AgentThreadID()
        let request = AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "hello",
            permissionMode: .autoAcceptEdits,
            serviceTier: .fast
        )

        actor Sink {
            var events: [AssistantEvent] = []
            var finish: (AgentRunStatus, String?, String?)?
            func record(_ event: AgentRunEvent) {
                switch event {
                case .event(let event): events.append(event)
                case .finished(let status, let final, let providerThreadId): finish = (status, final, providerThreadId)
                case .status, .error: break
                }
            }
        }
        let sink = Sink()

        _ = try await adapter.sendTurn(request) { event in
            Task { await sink.record(event) }
        }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let finish = await sink.finish {
                XCTAssertEqual(finish.0, .completed)
                XCTAssertEqual(finish.1, "hello from app-server")
                XCTAssertEqual(finish.2, "codex-thread-1")
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let finish = await sink.finish
        XCTAssertNotNil(finish, "Codex app-server adapter must finish from turn/completed notifications instead of leaving Agent App running forever")
        XCTAssertEqual(client.openedRequests.first?.serviceTier, .fast)
        XCTAssertEqual(client.startedTurns.first?.providerThreadId, "codex-thread-1")
        XCTAssertTrue(adapter.hasSession(threadId: threadId))

        let events = await sink.events
        XCTAssertTrue(events.contains { if case .threadStarted(_, let providerThreadId) = $0 { return providerThreadId == "codex-thread-1" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemDelta(_, let body, _, _) = $0 { return body == "hello from app-server" } else { return false } })
        XCTAssertTrue(events.contains { if case .providerRuntime(let event) = $0 { return event.source == "codex.app-server" && event.method == "turn/completed" } else { return false } })
    }

    func test_adapterInterruptUsesActiveAppServerTurn() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let threadId = AgentThreadID()
        actor Sink {
            var finished: AgentRunStatus?
            func record(_ event: AgentRunEvent) {
                if case .finished(let status, _, _) = event {
                    finished = status
                }
            }
            func status() -> AgentRunStatus? { finished }
        }
        let sink = Sink()
        let handle = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "wait"
        )) { event in
            Task { await sink.record(event) }
        }

        handle.cancel()

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !client.interruptedTurns.isEmpty, await sink.status() == .cancelled { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(client.interruptedTurns.first?.providerThreadId, "codex-thread-1")
        XCTAssertEqual(client.interruptedTurns.first?.turnId, "turn-app-server-1")
        let finishedStatus = await sink.status()
        XCTAssertEqual(finishedStatus, .cancelled,
                       "Codex app-server cancellation must finish the local run so macOS and iOS do not stay running forever")
        XCTAssertTrue(client.didStop,
                      "Codex app-server cancellation must stop the provider process tree after interrupting the active turn")
    }

    func test_adapterFailsRunWhenAppServerProcessExitsBeforeTurnCompleted() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "count"
        )) { event in
            Task { await sink.record(event) }
        }

        client.simulateTermination()

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let finish = await sink.finish {
                XCTAssertEqual(finish.0, .failed)
                XCTAssertEqual(finish.2, "codex-thread-1")
                XCTAssertFalse(adapter.hasSession(threadId: threadId),
                               "dead Codex app-server sessions must be removed so the next turn starts cleanly")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Codex app-server process exit must finish the local run instead of leaving Agent App running forever")
    }

    func test_adapterRollbackUsesCompletedTurnHistoryInsteadOfParsingTurnIdDigits() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let threadId = AgentThreadID()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "history"
        )) { _ in }

        client.notificationHandler?("turn/completed", ["threadId": "codex-thread-1", "turnId": "turn-alpha"])
        client.notificationHandler?("turn/completed", ["threadId": "codex-thread-1", "turnId": "turn-beta"])
        client.notificationHandler?("turn/completed", ["threadId": "codex-thread-1", "turnId": "turn-gamma"])

        try adapter.rollbackThread(threadId: threadId, toTurnId: "turn-alpha")

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !client.rolledBackTurns.isEmpty { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(client.rolledBackTurns.first?.providerThreadId, "codex-thread-1")
        XCTAssertEqual(client.rolledBackTurns.first?.numTurns, 2)
    }

    func test_adapterRecoversAppServerSessionFromProviderThreadIdForReadAndRollback() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        client.readResponse = [
            "thread": [
                "id": "codex-thread-recovered",
                "turns": [
                    [
                        "id": "turn-alpha",
                        "status": "completed",
                        "items": [["id": "agent-alpha", "type": "agentMessage", "text": "alpha"]]
                    ],
                    [
                        "id": "turn-beta",
                        "status": "completed",
                        "items": [["id": "agent-beta", "type": "agentMessage", "text": "beta"]]
                    ]
                ]
            ]
        ]
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let threadId = AgentThreadID()

        try adapter.recoverSession(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "",
            providerThreadId: "codex-thread-recovered"
        )) { _ in }

        XCTAssertTrue(adapter.hasSession(threadId: threadId))
        XCTAssertEqual(client.openedRequests.first?.providerThreadId, "codex-thread-recovered")
        XCTAssertTrue(client.startedTurns.isEmpty, "Recovery for read/rollback must not start a new provider turn")

        let events = try adapter.readThread(threadId: threadId)
        XCTAssertTrue(events.contains { if case .turnCompleted(let turnId, _) = $0 { return turnId == "turn-beta" } else { return false } })
        XCTAssertEqual(client.readCalls.first?.providerThreadId, "codex-thread-recovered")

        try adapter.rollbackThread(threadId: threadId, toTurnId: "turn-alpha")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !client.rolledBackTurns.isEmpty { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(client.rolledBackTurns.first?.providerThreadId, "codex-thread-recovered")
        XCTAssertEqual(client.rolledBackTurns.first?.numTurns, 1)
    }

    func test_adapterRecoveryRestoresActiveTurnForInterrupt() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let threadId = AgentThreadID()

        try adapter.recoverSession(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "",
            providerThreadId: "codex-thread-recovered",
            extraArgs: ["remotecode.recovery.activeTurnId=turn-recovered-active"]
        )) { _ in }
        try adapter.interruptTurn(threadId: threadId)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !client.interruptedTurns.isEmpty { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(client.openedRequests.first?.providerThreadId, "codex-thread-recovered")
        XCTAssertEqual(client.interruptedTurns.first?.providerThreadId, "codex-thread-recovered")
        XCTAssertEqual(client.interruptedTurns.first?.turnId, "turn-recovered-active",
                       "app restart recovery must restore the active Codex turn id so Stop can call provider-native interrupt instead of only dropping local state")
    }

    func test_adapterBridgesAppServerApprovalRequestToUiResponse() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "needs approval"
        )) { event in
            Task { await sink.record(event) }
        }

        let responseTask = Task {
            try await client.serverRequestHandler?("item/commandExecution/requestApproval", [
                "threadId": "codex-thread-1",
                "turnId": "turn-app-server-1",
                "itemId": "cmd-1",
                "command": "swift test"
            ])
        }
        let request = try await waitForApproval(in: sink)
        XCTAssertEqual(request.kind, .commandExecution)
        XCTAssertEqual(request.detail, "swift test")

        try adapter.respondToRequest(threadId: threadId, requestId: request.id, response: .approveForSession)
        let rawResponse = try await responseTask.value
        let response = try XCTUnwrap(rawResponse as? [String: Any])
        XCTAssertEqual(response["decision"] as? String, "acceptForSession")
        let update = try XCTUnwrap(client.updatedThreadSettings.first,
                                   "Approve Session must update the live Codex thread settings so later approvals in the same turn are auto-approved")
        XCTAssertEqual(update.providerThreadId, "codex-thread-1")
        XCTAssertEqual(update.permissionMode, .fullAccess)
        let autoResponse = try await client.serverRequestHandler?("item/commandExecution/requestApproval", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "itemId": "cmd-2",
            "command": "npm install"
        ])
        let autoDecision = try XCTUnwrap(autoResponse as? [String: Any])
        XCTAssertEqual(autoDecision["decision"] as? String, "acceptForSession",
                       "After Approve Session, later approval requests in the same loaded session must be auto-approved instead of surfacing another pending card")
        let events = await sink.snapshot()
        XCTAssertTrue(events.contains { if case .requestResolved(let id, let state) = $0 { return id == request.id && state == .approved } else { return false } })
        let openedRequests = events.compactMap {
            if case .requestOpened(let request) = $0 { return request }
            return nil
        }
        XCTAssertEqual(openedRequests.map(\.id), [request.id])
    }

    func test_adapterHandlesDottedAppServerRequestAliases() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "ask me"
        )) { event in
            Task { await sink.record(event) }
        }

        let responseTask = Task {
            try await client.serverRequestHandler?("item.tool.requestUserInput", [
                "threadId": "codex-thread-1",
                "turnId": "turn-app-server-1",
                "itemId": "question-1",
                "questions": [[
                    "id": "choice-1",
                    "header": "Continue",
                    "question": "Continue?"
                ]]
            ])
        }
        let request = try await waitForUserInput(in: sink)

        try adapter.respondToUserInput(threadId: threadId, requestId: request.id, text: "continue")
        let rawResponse = try await responseTask.value
        let response = try XCTUnwrap(rawResponse as? [String: Any])
        XCTAssertNotNil(response["answers"],
                        "dotted app-server request aliases must still route through pending UI callbacks; otherwise the provider turn can freeze waiting for input")
    }

    func test_adapterMapsNestedApprovalPayloadIntoReadableRequestDetail() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "needs rich approval"
        )) { event in
            Task { await sink.record(event) }
        }

        let responseTask = Task {
            try await client.serverRequestHandler?("item/commandExecution/requestApproval", [
                "thread": ["id": "codex-thread-1"],
                "turn": ["id": "turn-app-server-1"],
                "item": ["id": "cmd-1"],
                "request": [
                    "command": ["swift", "test", "--filter", "AgentAppViewModelTests"],
                    "cwd": "/repo/remotecode",
                    "reason": "Verify reload recovery"
                ]
            ])
        }
        let request = try await waitForApproval(in: sink)

        XCTAssertEqual(request.turnId, "turn-app-server-1")
        XCTAssertEqual(request.detail, """
        Command: swift test --filter AgentAppViewModelTests
        Cwd: /repo/remotecode
        Reason: Verify reload recovery
        """, "rich provider approval payloads must stay readable instead of collapsing to raw JSON")

        try adapter.respondToRequest(threadId: threadId, requestId: request.id, response: .decline(nil))
        let rawResponse = try await responseTask.value
        let response = try XCTUnwrap(rawResponse as? [String: Any])
        XCTAssertEqual(response["decision"] as? String, "decline")
    }

    func test_adapterBridgesAppServerFileReadApprovalRequest() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "needs file read approval"
        )) { event in
            Task { await sink.record(event) }
        }

        let responseTask = Task {
            try await client.serverRequestHandler?("item/fileRead/requestApproval", [
                "turn": ["id": "turn-app-server-1"],
                "item": ["id": "read-1"],
                "request": [
                    "path": "/repo/Secrets.swift",
                    "reason": "Provider wants to inspect a protected file"
                ]
            ])
        }
        let request = try await waitForApproval(in: sink)
        XCTAssertEqual(request.kind, .fileRead)
        XCTAssertEqual(request.title, "File read approval")
        XCTAssertTrue(request.detail?.contains("/repo/Secrets.swift") == true,
                      "Codex app-server file-read approvals should use the same actionable approval UI as command and file-change approvals")

        try adapter.respondToRequest(threadId: threadId, requestId: request.id, response: .decline(nil))
        let rawResponse = try await responseTask.value
        let response = try XCTUnwrap(rawResponse as? [String: Any])
        XCTAssertEqual(response["decision"] as? String, "decline")
    }

    func test_adapterBridgesAppServerUserInputRequestToUiResponse() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "needs input"
        )) { event in
            Task { await sink.record(event) }
        }

        let responseTask = Task {
            try await client.serverRequestHandler?("item/tool/requestUserInput", [
                "threadId": "codex-thread-1",
                "turnId": "turn-app-server-1",
                "itemId": "question-item-1",
                "questions": [[
                    "id": "choice",
                    "header": "Mode",
                    "question": "Pick one",
                    "options": [
                        ["label": "Fast", "description": "Run fast"],
                        ["label": "Careful", "description": "Run carefully"]
                    ]
                ]]
            ])
        }
        let request = try await waitForUserInput(in: sink)
        XCTAssertEqual(request.prompt, "Mode: Pick one")
        XCTAssertEqual(request.options, ["Fast", "Careful"])

        try adapter.respondToUserInput(threadId: threadId, requestId: request.id, text: "Careful")
        let rawResponse = try await responseTask.value
        let response = try XCTUnwrap(rawResponse as? [String: Any])
        let answers = try XCTUnwrap(response["answers"] as? [String: [String: [String]]])
        XCTAssertEqual(answers["choice"]?["answers"], ["Careful"])
        let events = await sink.snapshot()
        XCTAssertTrue(events.contains { if case .userInputResolved(let id, let answer) = $0 { return id == request.id && answer == "Careful" } else { return false } })
    }

    func test_adapterMapsMultiQuestionUserInputAnswersByQuestionId() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "needs multiple inputs"
        )) { event in
            Task { await sink.record(event) }
        }

        let responseTask = Task {
            try await client.serverRequestHandler?("item/tool/requestUserInput", [
                "threadId": "codex-thread-1",
                "turnId": "turn-app-server-1",
                "itemId": "question-item-1",
                "questions": [
                    [
                        "id": "branch",
                        "header": "Branch",
                        "question": "Which branch?",
                        "options": []
                    ],
                    [
                        "id": "confirm",
                        "header": "Confirm",
                        "question": "Proceed?",
                        "options": [
                            ["label": "yes", "description": "Proceed"],
                            ["label": "no", "description": "Stop"]
                        ]
                    ]
                ]
            ])
        }
        let request = try await waitForUserInput(in: sink)
        XCTAssertEqual(request.prompt, "Branch: Which branch?\nConfirm: Proceed?")
        XCTAssertEqual(request.options, ["yes", "no"])

        try adapter.respondToUserInput(threadId: threadId, requestId: request.id, text: """
        branch: release/next
        confirm: yes
        """)
        let rawResponse = try await responseTask.value
        let response = try XCTUnwrap(rawResponse as? [String: Any])
        let answers = try XCTUnwrap(response["answers"] as? [String: [String: [String]]])
        XCTAssertEqual(answers["branch"]?["answers"], ["release/next"])
        XCTAssertEqual(answers["confirm"]?["answers"], ["yes"])
    }

    func test_adapterMapsNestedMultiSelectUserInputPayloadToCodexAnswers() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "needs nested multi-select input"
        )) { event in
            Task { await sink.record(event) }
        }

        let responseTask = Task {
            try await client.serverRequestHandler?("item/tool/requestUserInput", [
                "thread": ["id": "codex-thread-1"],
                "turn": ["id": "turn-app-server-1"],
                "item": ["id": "question-item-1"],
                "request": [
                    "questions": [[
                        "id": "checks",
                        "header": "Checks",
                        "question": "Which checks should run?",
                        "allowsMultipleSelection": true,
                        "options": [
                            ["label": "Unit", "description": "Run unit tests"],
                            ["label": "UI", "description": "Run UI tests"]
                        ]
                    ]]
                ]
            ])
        }
        let request = try await waitForUserInput(in: sink)
        XCTAssertEqual(request.turnId, "turn-app-server-1")
        XCTAssertEqual(request.prompt, "Checks: Which checks should run?")
        XCTAssertEqual(request.options, ["Unit", "UI"])
        XCTAssertTrue(request.allowsMultipleSelection,
                      "Codex app-server multi-select questions must reach the UI as multi-select instead of being flattened to a single-choice prompt")

        try adapter.respondToUserInput(threadId: threadId, requestId: request.id, text: "Unit, UI")
        let rawResponse = try await responseTask.value
        let response = try XCTUnwrap(rawResponse as? [String: Any])
        let answers = try XCTUnwrap(response["answers"] as? [String: [String: [String]]])
        XCTAssertEqual(answers["checks"]?["answers"], ["Unit", "UI"],
                       "provider multi-select callbacks require one answer array entry per selected option")
    }

    func test_adapterMarksSecretUserInputQuestions() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "needs secret"
        )) { event in
            Task { await sink.record(event) }
        }

        let responseTask = Task {
            try await client.serverRequestHandler?("item/tool/requestUserInput", [
                "turnId": "turn-app-server-1",
                "questions": [[
                    "id": "token",
                    "header": "Token",
                    "question": "Paste API token",
                    "inputType": "password"
                ]]
            ])
        }
        let request = try await waitForUserInput(in: sink)

        XCTAssertTrue(request.isSecret,
                      "secret provider questions must be marked so macOS and iOS render masked input instead of plain text")

        try adapter.respondToUserInput(threadId: threadId, requestId: request.id, text: "sk-test")
        _ = try await responseTask.value
    }

    func test_stopSessionCancelsPendingAppServerCallbacksSoServerRequestDoesNotHang() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "needs callbacks"
        )) { event in
            Task { await sink.record(event) }
        }

        let approvalTask = Task {
            try await client.serverRequestHandler?("item/commandExecution/requestApproval", [
                "threadId": "codex-thread-1",
                "turnId": "turn-app-server-1",
                "itemId": "cmd-1",
                "command": "swift test"
            ])
        }
        let userInputTask = Task {
            try await client.serverRequestHandler?("item/tool/requestUserInput", [
                "threadId": "codex-thread-1",
                "turnId": "turn-app-server-1",
                "itemId": "question-1",
                "questions": [[
                    "id": "continue",
                    "header": "Continue",
                    "question": "Continue?",
                    "options": []
                ]]
            ])
        }
        let approval = try await waitForApproval(in: sink)
        let userInput = try await waitForUserInput(in: sink)

        try adapter.stopSession(threadId: threadId)

        let rawApprovalResponse = try await approvalTask.value
        let approvalResponse = try XCTUnwrap(rawApprovalResponse as? [String: Any])
        XCTAssertEqual(approvalResponse["decision"] as? String, "cancel",
                       "stopping a Codex app-server session must resolve pending provider approvals so dead buttons cannot survive")
        let rawUserInputResponse = try await userInputTask.value
        let userInputResponse = try XCTUnwrap(rawUserInputResponse as? [String: Any])
        let answers = try XCTUnwrap(userInputResponse["answers"] as? [String: [String: [String]]])
        XCTAssertEqual(answers["continue"]?["answers"], [""],
                       "stopping a Codex app-server session must answer pending provider questions so provider requests do not hang forever")
        let events = await sink.snapshot()
        XCTAssertTrue(events.contains { if case .requestResolved(let id, let state) = $0 { return id == approval.id && state == .cancelled } else { return false } })
        XCTAssertTrue(events.contains { if case .userInputResolved(let id, let answer) = $0 { return id == userInput.id && answer == nil } else { return false } })
        XCTAssertFalse(adapter.hasSession(threadId: threadId),
                       "after settling callbacks, the adapter must drop the session so later responses fail loud instead of targeting stale provider state")
        XCTAssertTrue(client.didStop)
    }

    func test_unhandledAppServerRequestStillEmitsRawRuntimeEventBeforeFailing() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "unknown request"
        )) { event in
            Task { await sink.record(event) }
        }

        do {
            _ = try await client.serverRequestHandler?("item/newProviderCallback/requestReview", [
                "turnId": "turn-app-server-1",
                "requestId": "provider-request-1",
                "payload": ["kind": "future"]
            ])
            XCTFail("Unknown app-server requests should fail loudly until RemoteCode implements a typed handler")
        } catch {
            let runtime = try await waitForRuntimeEvent(in: sink, method: "item/newProviderCallback/requestReview")
            XCTAssertEqual(runtime.providerRequestId, "provider-request-1",
                           "raw provider request ids must be retained so unsupported app-server callbacks remain diagnosable")
            XCTAssertTrue(runtime.payloadJSON.contains("\"future\""),
                          "unsupported app-server server requests must preserve their raw payload instead of disappearing before failure")
        }
    }

    func test_readThreadMapsAppServerSnapshotIntoAssistantEvents() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        client.readResponse = [
            "thread": [
                "id": "codex-thread-1",
                "turns": [[
                    "id": "turn-snapshot-1",
                    "status": "completed",
                    "startedAt": 1_700_000_000,
                    "items": [
                        [
                            "id": "reasoning-1",
                            "type": "reasoning",
                            "summary": ["checked context"],
                            "content": ["thinking"]
                        ],
                        [
                            "id": "cmd-1",
                            "type": "commandExecution",
                            "command": "swift test",
                            "status": "completed",
                            "aggregatedOutput": "ok"
                        ],
                        [
                            "id": "agent-1",
                            "type": "agentMessage",
                            "text": "snapshot answer"
                        ],
                        [
                            "id": "browser-1",
                            "type": "browserScreenshot",
                            "url": "http://127.0.0.1:3000",
                            "status": "completed"
                        ]
                    ]
                ]]
            ]
        ]
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "read"
        )) { _ in }

        let events = try adapter.readThread(threadId: threadId)

        XCTAssertEqual(client.readCalls.first?.providerThreadId, "codex-thread-1")
        XCTAssertTrue(events.contains { if case .threadStarted(let threadId, let providerThreadId) = $0 { return threadId == "codex-thread-1" && providerThreadId == "codex-thread-1" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.id == "cmd-1" && item.type == .commandExecution && item.summary == "swift test" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemDelta(let itemId, _, let output, _) = $0 { return itemId == "cmd-1" && output == "ok" } else { return false } })
        XCTAssertTrue(events.contains { if case .providerRuntime(let runtime) = $0 { return runtime.method == "thread/read.item" && runtime.providerItemId == "browser-1" && runtime.payloadJSON.contains("browserScreenshot") } else { return false } },
                      "thread/read must keep raw app-server snapshot items so newly added Codex item subtypes are debuggable before RemoteCode has specialized UI mapping")
        XCTAssertTrue(events.contains { if case .itemDelta(let itemId, _, let output, _) = $0 { return itemId == "browser-1" && output?.contains("127.0.0.1") == true } else { return false } },
                      "unknown app-server snapshot items must still render their body instead of disappearing from restored thread history")
        XCTAssertTrue(events.contains { if case .turnCompleted(let turnId, let final) = $0 { return turnId == "turn-snapshot-1" && final == "snapshot answer" } else { return false } })
    }

    func test_readThreadRendersCommonStringAliasesForUncommonSnapshotItems() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        client.readResponse = [
            "thread": [
                "id": "codex-thread-aliases",
                "turns": [[
                    "id": "turn-aliases-1",
                    "status": "completed",
                    "items": [
                        [
                            "id": "web-1",
                            "type": "webSearch",
                            "query": "RemoteCode",
                            "output": "Search result summary"
                        ],
                        [
                            "id": "agent-content-1",
                            "type": "agentMessage",
                            "content": [
                                [
                                    "type": "text",
                                    "text": "Assistant content array text"
                                ]
                            ]
                        ],
                        [
                            "id": "user-content-1",
                            "type": "userMessage",
                            "content": [
                                [
                                    "type": "text",
                                    "text": "User content array text"
                                ]
                            ]
                        ],
                        [
                            "id": "hook-1",
                            "type": "hookPrompt",
                            "fragments": [
                                [
                                    "hookRunId": "hook-run-1",
                                    "text": "Hook prompt fragment"
                                ]
                            ]
                        ],
                        [
                            "id": "future-1",
                            "type": "futureProviderItem",
                            "message": "Provider-specific text"
                        ],
                        [
                            "id": "future-content-1",
                            "type": "futureProviderItem",
                            "content": [
                                [
                                    "type": "text",
                                    "text": "Future content array text"
                                ],
                                [
                                    "type": "image",
                                    "image_url": "file:///tmp/future.png"
                                ],
                                [
                                    "type": "text",
                                    "text": "Second content part"
                                ]
                            ]
                        ]
                    ]
                ]]
            ]
        ]
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "read aliases"
        )) { _ in }

        let events = try adapter.readThread(threadId: threadId)

        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.id == "web-1" && item.type == .webSearch && item.summary == "RemoteCode" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemDelta(let itemId, _, let output, _) = $0 { return itemId == "web-1" && output == "Search result summary" } else { return false } },
                      "Codex thread/read should render common string output aliases for known item types instead of falling back to missing or opaque JSON content")
        XCTAssertTrue(events.contains { if case .itemDelta(let itemId, let body, _, _) = $0 { return itemId == "agent-content-1" && body == "Assistant content array text" } else { return false } },
                      "agentMessage snapshots should render app-server content arrays as assistant text instead of raw JSON")
        XCTAssertFalse(events.contains { if case .itemStarted(let item) = $0 { return item.id == "user-content-1" } else { return false } },
                       "userMessage snapshots must not render as tool rows because the Agent App already shows the prompt as a user bubble")
        XCTAssertTrue(events.contains { if case .providerRuntime(let runtime) = $0 { return runtime.providerItemId == "user-content-1" && runtime.payloadJSON.contains("User content array text") } else { return false } },
                      "userMessage snapshots must stay available in raw runtime history even when hidden from the visible assistant timeline")
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.id == "hook-1" && item.summary == "Hook prompt" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemDelta(let itemId, _, let output, _) = $0 { return itemId == "hook-1" && output == "Hook prompt fragment" } else { return false } },
                      "hookPrompt snapshots should render fragment text instead of raw JSON")
        XCTAssertTrue(events.contains { if case .itemDelta(let itemId, _, let output, _) = $0 { return itemId == "future-1" && output == "Provider-specific text" } else { return false } },
                      "future provider-specific snapshot items should render common message/text fields while raw providerRuntime still preserves the full JSON")
        XCTAssertTrue(events.contains { if case .itemDelta(let itemId, _, let output, _) = $0, let output { return itemId == "future-content-1" && output.contains("Future content array text") && output.contains("image_url") && output.contains("file:") && output.contains("future.png") && output.contains("Second content part") } else { return false } },
                      "future provider-specific snapshot items should render text and non-text app-server content-array blocks before falling back to raw item JSON")
        XCTAssertTrue(events.contains { if case .providerRuntime(let runtime) = $0 { return runtime.providerItemId == "future-1" && runtime.payloadJSON.contains("futureProviderItem") } else { return false } })
    }

    func test_adapterCapturesAppServerPlanDeltaAsProposedPlan() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "plan",
            interactionMode: .plan
        )) { event in
            Task { await sink.record(event) }
        }

        client.notificationHandler?("item/plan/delta", [
            "threadId": "codex-thread-1",
            "turnId": "turn-plan-1",
            "itemId": "plan-item-1",
            "delta": "<proposed_plan>\n1. Inspect\n"
        ])
        client.notificationHandler?("item/plan/delta", [
            "threadId": "codex-thread-1",
            "turnId": "turn-plan-1",
            "itemId": "plan-item-1",
            "delta": "2. Patch\n</proposed_plan>"
        ])

        let proposedPlan = try await waitForProposedPlan(in: sink)
        let events = await sink.snapshot()
        XCTAssertEqual(proposedPlan.id, "plan-item-1")
        XCTAssertEqual(proposedPlan.turnId, "turn-plan-1")
        XCTAssertEqual(proposedPlan.markdown, "1. Inspect\n2. Patch")
        XCTAssertTrue(events.contains { if case .itemDelta(let itemId, _, let output, _) = $0 { return itemId == "plan-item-1" && output == "2. Patch\n</proposed_plan>" } else { return false } })
    }

    func test_adapterPromotesPlanModeFinalAssistantTextToProposedPlan() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "plan",
            interactionMode: .plan
        )) { event in
            Task { await sink.record(event) }
        }

        client.notificationHandler?("item/agentMessage/delta", [
            "threadId": "codex-thread-1",
            "turnId": "turn-plan-final-1",
            "itemId": "agent-message-1",
            "delta": "RC_AGENT_APP_PLAN_SURFACE\n1. Reply exactly RC_AGENT_APP_PLAN_IMPLEMENTED."
        ])
        client.notificationHandler?("turn/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-plan-final-1"
        ])

        let proposedPlan = try await waitForProposedPlan(in: sink)
        XCTAssertEqual(proposedPlan.id, "plan-turn-plan-final-1")
        XCTAssertEqual(proposedPlan.turnId, "turn-plan-final-1")
        XCTAssertTrue(proposedPlan.markdown.contains("RC_AGENT_APP_PLAN_SURFACE"),
                      "some Codex app-server Plan Mode builds emit the plan as final assistant text; the Agent App still needs a first-class proposed-plan card")
    }

    func test_adapterStartsStreamingAssistantItemOnlyOnceAcrossDeltas() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "count"
        )) { event in
            Task { await sink.record(event) }
        }

        client.notificationHandler?("item/started", [
            "threadId": "codex-thread-1",
            "turnId": "turn-stream-1",
            "item": [
                "id": "agent-message-1",
                "type": "agentMessage"
            ]
        ])
        client.notificationHandler?("item/agentMessage/delta", [
            "threadId": "codex-thread-1",
            "turnId": "turn-stream-1",
            "itemId": "agent-message-1",
            "delta": "1"
        ])
        client.notificationHandler?("item/agentMessage/delta", [
            "threadId": "codex-thread-1",
            "turnId": "turn-stream-1",
            "itemId": "agent-message-1",
            "delta": " 2 3"
        ])
        client.notificationHandler?("item/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-stream-1",
            "item": [
                "id": "agent-message-1",
                "type": "agentMessage",
                "text": "1 2 3"
            ]
        ])
        client.notificationHandler?("turn/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-stream-1"
        ])

        try await Task.sleep(nanoseconds: 50_000_000)
        let events = await sink.snapshot()
        let starts = events.filter {
            if case .itemStarted(let item) = $0 {
                return item.id == "agent-message-1" && item.type == .assistantMessage
            }
            return false
        }
        let body = events.compactMap { event -> String? in
            if case .turnCompleted(_, let final) = event { return final }
            return nil
        }.first
        let streamedBody = events.compactMap { event -> String? in
            if case .itemDelta(_, let body, _, _) = event { return body }
            return nil
        }.joined()

        XCTAssertEqual(starts.count, 1,
                       "Codex app-server deltas for one assistant item must not create duplicate empty transcript rows")
        XCTAssertEqual(body, "1 2 3",
                       "Codex app-server streamed deltas must be returned as final assistant text")
        XCTAssertEqual(streamedBody, "1 2 3",
                       "item/completed must not replay the full assistant text after deltas already streamed it")
    }

    func test_adapterTreatsSnakeCaseAgentMessageCompletionAsFinalAssistantResponse() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "count to 10"
        )) { event in
            Task { await sink.record(event) }
        }

        client.notificationHandler?("item/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-snake-agent-message-1",
            "item": [
                "id": "agent-message-snake-1",
                "type": "agent_message",
                "text": "1 2 3 4 5 6 7 8 9 10",
                "status": "completed"
            ]
        ])
        client.notificationHandler?("turn/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-snake-agent-message-1"
        ])

        try await Task.sleep(nanoseconds: 50_000_000)
        let events = await sink.snapshot()
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.id == "agent-message-snake-1" && item.type == .assistantMessage } else { return false } },
                      "Codex app-server may emit no assistant delta and only complete an agent_message item; users still need a normal assistant bubble, not a tool row")
        XCTAssertTrue(events.contains { if case .itemDelta(let itemId, let body, _, _) = $0 { return itemId == "agent-message-snake-1" && body == "1 2 3 4 5 6 7 8 9 10" } else { return false } },
                      "the completed agent_message text must render as assistant text when the provider skips streaming deltas")
        XCTAssertTrue(events.contains { if case .turnCompleted(let turnId, let final) = $0 { return turnId == "turn-snake-agent-message-1" && final == "1 2 3 4 5 6 7 8 9 10" } else { return false } },
                      "turn.completed without finalMessage must return the completed agent_message text as the final user-visible answer")
    }

    func test_adapterMapsAppServerTurnPlanUpdatedToActivePlanState() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "plan progress",
            interactionMode: .plan
        )) { event in
            Task { await sink.record(event) }
        }

        client.notificationHandler?("turn/plan/updated", [
            "threadId": "codex-thread-1",
            "turnId": "turn-plan-progress-1",
            "explanation": "Working",
            "plan": [
                ["id": "inspect", "step": "Inspect", "status": "completed"],
                ["id": "patch", "step": "Patch", "status": "inProgress"],
                ["id": "verify", "step": "Verify", "status": "pending"]
            ]
        ])

        let plan = try await waitForActivePlan(in: sink)
        XCTAssertEqual(plan.explanation, "Working")
        XCTAssertEqual(plan.steps.map(\.title), ["Inspect", "Patch", "Verify"])
        XCTAssertEqual(plan.steps.map(\.status), [.completed, .inProgress, .pending],
                       "native app-server plan updates must drive the active progress card, not only raw runtime logs")
    }

    func test_adapterKeepsNestedRuntimeRefsFromAppServerNotifications() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "nested refs"
        )) { event in
            Task { await sink.record(event) }
        }

        client.notificationHandler?("item/started", [
            "threadId": "codex-thread-1",
            "turn": ["id": "turn-nested-1"],
            "item": ["id": "cmd-nested-1", "type": "commandExecution", "command": "swift test"]
        ])

        let runtimeEvent = try await waitForRuntimeEvent(in: sink, method: "item/started")
        XCTAssertEqual(runtimeEvent.providerTurnId, "turn-nested-1")
        XCTAssertEqual(runtimeEvent.providerItemId, "cmd-nested-1",
                       "runtime logs must preserve app-server nested ids so long-run debugging can correlate raw events with visible items")
    }

    func test_readThreadMapsPlanSnapshotToProposedPlan() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        client.readResponse = [
            "thread": [
                "id": "codex-thread-1",
                "turns": [[
                    "id": "turn-plan-snapshot-1",
                    "status": "completed",
                    "startedAt": 1_700_000_000,
                    "items": [[
                        "id": "plan-snapshot-1",
                        "type": "plan",
                        "status": "completed",
                        "text": "<proposed_plan>\n1. Inspect\n2. Patch\n</proposed_plan>"
                    ]]
                ]]
            ]
        ]
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "read plan"
        )) { _ in }

        let events = try adapter.readThread(threadId: threadId)
        let proposedPlan = try XCTUnwrap(events.compactMap { event -> AssistantProposedPlan? in
            if case .proposedPlan(let plan) = event { return plan }
            return nil
        }.first)
        XCTAssertEqual(proposedPlan.id, "plan-snapshot-1")
        XCTAssertEqual(proposedPlan.turnId, "turn-plan-snapshot-1")
        XCTAssertEqual(proposedPlan.markdown, "1. Inspect\n2. Patch")
    }

    func test_adapterMapsAppServerTokenUsageAndCompactionNotifications() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "telemetry"
        )) { event in
            Task { await sink.record(event) }
        }

        client.notificationHandler?("thread/tokenUsage/updated", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "tokenUsage": [
                "total": ["inputTokens": 11833, "outputTokens": 6, "totalTokens": 11839],
                "last": ["inputTokens": 120, "outputTokens": 6, "totalTokens": 126],
                "modelContextWindow": 258400
            ]
        ])
        client.notificationHandler?("thread/compacted", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "summary": "Context compacted"
        ])
        client.notificationHandler?("item/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-2",
            "item": [
                "id": "native-context-compaction",
                "type": "contextCompaction"
            ]
        ])

        let usage = try await waitForTokenUsage(in: sink)
        XCTAssertEqual(usage.inputTokens, 120)
        XCTAssertEqual(usage.outputTokens, 6)
        XCTAssertEqual(usage.totalTokens, 126)
        XCTAssertEqual(usage.contextWindow, 258400)
        XCTAssertEqual(usage.compactsAutomatically, true,
                       "Codex app-server context windows auto-compact; RemoteCode must preserve that capability in the same context status surface as T3Code")
        _ = try await waitForContextCompaction(in: sink)
        let events = await sink.snapshot()
        XCTAssertTrue(events.contains { if case .contextCompaction(let summary) = $0 { return summary == "Context compacted" } else { return false } })
        XCTAssertTrue(events.contains { if case .contextCompaction(let summary) = $0 { return summary == "Context compaction" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.type == .contextCompaction && item.summary == "Context compacted" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.id == "native-context-compaction" && item.type == .contextCompaction && item.summary == "Context compaction" } else { return false } })
    }

    func test_adapterRendersTurnCompletedFinalPayloadWhenOnlyRuntimeItemsStreamed() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "count to 10"
        )) { event in
            Task { await sink.record(event) }
        }

        client.notificationHandler?("mcpServer.startupStatus.updated", [
            "serverName": "status",
            "status": "completed"
        ])
        client.notificationHandler?("turn.completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-count-1",
            "finalMessage": "1 2 3 4 5 6 7 8 9 10"
        ])

        try? await Task.sleep(nanoseconds: 50_000_000)
        let events = await sink.snapshot()
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "MCP server status" } else { return false } },
                      "runtime-only app-server activity must still stay available in the Work log")
        XCTAssertTrue(events.contains { if case .turnCompleted(let turnId, let final) = $0 { return turnId == "turn-count-1" && final == "1 2 3 4 5 6 7 8 9 10" } else { return false } },
                      "a simple completed Codex turn must render the human answer even when the app-server only streamed runtime/tool notifications")
    }

    func test_adapterMapsGeneratedAppServerOperationalNotificationsIntoVisibleEvents() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "generated notifications"
        )) { event in
            Task { await sink.record(event) }
        }

        client.notificationHandler?("thread/goal/updated", [
            "threadId": "codex-thread-1",
            "goal": [
                "objective": "finish audit",
                "status": "active",
                "tokensUsed": 42,
                "tokenBudget": 100
            ]
        ])
        client.notificationHandler?("thread/status/changed", [
            "threadId": "codex-thread-1",
            "status": ["type": "active", "activeFlags": ["waitingOnApproval"]]
        ])
        client.notificationHandler?("hook/started", [
            "id": "hook-1",
            "eventName": "PreToolUse",
            "handlerType": "command",
            "status": "running"
        ])
        client.notificationHandler?("hook/completed", [
            "id": "hook-1",
            "eventName": "PreToolUse",
            "handlerType": "command",
            "status": "completed",
            "entries": [["kind": "stdout", "text": "hook ok"]]
        ])
        client.notificationHandler?("item/autoApprovalReview/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "itemId": "review-1",
            "review": [
                "status": "approved",
                "riskLevel": "low",
                "rationale": "safe command"
            ]
        ])
        client.notificationHandler?("command/exec/outputDelta", [
            "commandId": "cmd-exec-1",
            "deltaBase64": "Y21kIG91dAo="
        ])
        client.notificationHandler?("process/outputDelta", [
            "processHandle": "proc-1",
            "stream": "stdout",
            "deltaBase64": "cHJvYyBvdXQK"
        ])
        client.notificationHandler?("process/exited", [
            "processHandle": "proc-1",
            "exitCode": 1,
            "stderr": "proc failed"
        ])
        client.notificationHandler?("serverRequest/resolved", [
            "threadId": "codex-thread-1",
            "requestId": "request-1"
        ])
        client.notificationHandler?("turn/diff/updated", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "diff": "diff --git a/file b/file"
        ])
        client.notificationHandler?("warning", [
            "threadId": "codex-thread-1",
            "message": "config warning"
        ])
        client.notificationHandler?("guardianWarning", [
            "threadId": "codex-thread-1",
            "message": "risky command"
        ])
        client.notificationHandler?("configWarning", [
            "summary": "bad config",
            "details": "fix config"
        ])
        client.notificationHandler?("deprecationNotice", [
            "summary": "old flag",
            "details": "use new flag"
        ])
        client.notificationHandler?("account/updated", [
            "authMode": "chatgpt",
            "planType": "plus"
        ])
        client.notificationHandler?("account/rateLimits/updated", [
            "rateLimits": [
                "limitName": "primary",
                "rateLimitReachedType": "hard",
                "primary": ["resetsAt": "2026-05-23T12:00:00Z"]
            ]
        ])
        client.notificationHandler?("mcpServer/startupStatus/updated", [
            "serverName": "filesystem",
            "status": "completed"
        ])
        client.notificationHandler?("model/rerouted", ["reason": "highRiskCyberActivity"])
        client.notificationHandler?("model/verification", ["verifications": ["trustedAccessForCyber"]])
        client.notificationHandler?("remoteControl/status/changed", [
            "environmentId": "env-1",
            "status": "connected"
        ])
        client.notificationHandler?("thread/realtime/started", [
            "realtimeSessionId": "rt-1",
            "model": "gpt-realtime",
            "voice": "alloy"
        ])
        client.notificationHandler?("thread/realtime/itemAdded", [
            "item": [
                "id": "rt-item-1",
                "type": "agentMessage",
                "content": [["type": "text", "text": "Realtime item text"]]
            ]
        ])
        client.notificationHandler?("thread/realtime/transcript/delta", [
            "itemId": "rt-transcript-1",
            "delta": "Realtime "
        ])
        client.notificationHandler?("thread/realtime/transcript/done", [
            "itemId": "rt-transcript-1",
            "text": "done"
        ])
        client.notificationHandler?("thread/realtime/outputAudio/delta", [
            "itemId": "rt-audio-1",
            "audio": "base64-audio"
        ])
        client.notificationHandler?("thread/realtime/sdp", [
            "realtimeSessionId": "rt-1",
            "sdp": "v=0"
        ])
        client.notificationHandler?("thread/realtime/error", [
            "message": "mic denied"
        ])
        client.notificationHandler?("thread/realtime/closed", [
            "realtimeSessionId": "rt-1",
            "reason": "user closed"
        ])
        client.notificationHandler?("fs/changed", ["changedPaths": ["/tmp/remotecode/a.swift"]])
        client.notificationHandler?("thread/goal/cleared", ["threadId": "codex-thread-1"])

        try? await Task.sleep(nanoseconds: 50_000_000)
        let events = await sink.snapshot()
        XCTAssertTrue(events.contains { if case .itemDelta(_, _, let output, let summary) = $0 { return summary == "Goal updated" && output?.contains("Objective: finish audit") == true && output?.contains("Tokens: 42 / 100") == true } else { return false } },
                      "generated app-server goal updates must be readable in the Agent App, not only preserved as raw runtime JSON")
        XCTAssertTrue(events.contains { if case .itemDelta(_, _, let output, let summary) = $0 { return summary == "Turn diff updated" && output == "diff --git a/file b/file" } else { return false } },
                      "turn/diff/updated should surface the aggregated provider diff as file-change activity")
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "Codex warning" && item.output == "config warning" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "Codex guardian warning" && item.output == "risky command" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "bad config" && item.output == "fix config" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "old flag" && item.output == "use new flag" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "Codex rate limit" && item.output?.contains("hard") == true && item.output?.contains("primary") == true } else { return false } },
                      "rate-limit notifications should become visible diagnostics before a long run appears frozen without marking a successful turn as failed")
        XCTAssertFalse(events.contains { if case .error(let message, _) = $0 { return message.contains("config warning") || message.contains("risky command") || message.contains("bad config") || message.contains("old flag") || message.contains("primary") } else { return false } },
                       "recoverable Codex warnings must not publish agent.run.error when the turn can still succeed")
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "Thread status changed" && item.output?.contains("waitingOnApproval") == true } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "Hook completed" && item.output?.contains("hook ok") == true } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "Auto approval review" && item.output?.contains("safe command") == true } else { return false } })
        XCTAssertTrue(events.contains { if case .itemDelta(let itemId, _, let output, _) = $0 { return itemId == "cmd-exec-1" && output == "cmd out\n" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemDelta(let itemId, _, let output, _) = $0 { return itemId == "proc-1" && output == "proc out\n" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.id == "proc-1" && item.state == .failed && item.output == "proc failed" } else { return false } })
        XCTAssertTrue(events.contains { if case .requestResolved(let requestId, let state) = $0 { return requestId == "request-1" && state == .resolved } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "Account updated" && item.output?.contains("Plan: plus") == true } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "MCP server status" && item.output?.contains("filesystem") == true } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "Model rerouted" && item.output?.contains("highRiskCyberActivity") == true } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "Model verification" && item.output?.contains("trustedAccessForCyber") == true } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "Remote control status" && item.output == "connected" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "Realtime session started" && item.output?.contains("Session: rt-1") == true } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.id == "rt-item-1" && item.summary == "Realtime item added" && item.output == "Realtime item text" } else { return false } },
                      "generated Codex realtime item notifications should become visible timeline activity instead of only raw runtime JSON")
        XCTAssertTrue(events.contains { if case .itemDelta(let itemId, let body, _, let summary) = $0 { return itemId == "rt-transcript-1" && body == "Realtime " && summary == "Realtime transcript" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemCompleted(let itemId, let state) = $0 { return itemId == "rt-transcript-1" && state == .completed } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.id == "rt-audio-1" && item.summary == "Realtime audio" && item.output == "base64-audio" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.id == "rt-1" && item.summary == "Realtime SDP" && item.output == "v=0" } else { return false } })
        XCTAssertTrue(events.contains { if case .error(let message, let recoverable) = $0 { return recoverable && message == "Codex realtime error: mic denied" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "Realtime session closed" && item.output == "user closed" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "Filesystem changed" && item.output?.contains("/tmp/remotecode/a.swift") == true } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "Goal cleared" && item.output == "Goal cleared" } else { return false } })
        XCTAssertTrue(events.contains { if case .providerRuntime(let runtime) = $0 { return runtime.method == "thread/goal/updated" } else { return false } },
                      "semantic notification mapping must remain additive to raw provider event capture")
    }

    func test_adapterMapsCommonAppServerItemLifecycleAndDeltas() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "items"
        )) { event in
            Task { await sink.record(event) }
        }

        client.notificationHandler?("item/started", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "item": ["id": "cmd-1", "type": "commandExecution", "command": "swift test"]
        ])
        client.notificationHandler?("item/commandExecution/outputDelta", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "itemId": "cmd-1",
            "delta": "ok\n"
        ])
        client.notificationHandler?("item/reasoning/textDelta", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "itemId": "reasoning-1",
            "delta": "thinking"
        ])
        client.notificationHandler?("item/fileChange/patchUpdated", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "itemId": "patch-1",
            "patch": "diff --git a/file b/file"
        ])
        client.notificationHandler?("item/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "item": ["id": "cmd-1", "type": "commandExecution", "status": "completed"]
        ])
        client.notificationHandler?("item/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "item": [
                "id": "raw-message-1",
                "type": "message",
                "status": "completed",
                "content": [["type": "output_text", "text": "raw assistant text"]]
            ]
        ])
        client.notificationHandler?("item/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "item": [
                "id": "raw-shell-1",
                "type": "local_shell_call",
                "status": "completed",
                "command": "swift test"
            ]
        ])
        client.notificationHandler?("item/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "item": [
                "id": "raw-web-1",
                "type": "web_search_call",
                "status": "completed",
                "query": "RemoteCode"
            ]
        ])

        _ = try await waitForItemCompleted(in: sink, itemId: "cmd-1")
        let events = await sink.snapshot()
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.id == "cmd-1" && item.type == .commandExecution && item.summary == "swift test" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemDelta(let itemId, _, let output, _) = $0 { return itemId == "cmd-1" && output == "ok\n" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemDelta(let itemId, _, let output, _) = $0 { return itemId == "reasoning-1" && output == "thinking" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemDelta(let itemId, _, let output, _) = $0 { return itemId == "patch-1" && output == "diff --git a/file b/file" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemCompleted(let itemId, let state) = $0 { return itemId == "cmd-1" && state == .completed } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.id == "raw-message-1" && item.type == .assistantMessage && item.summary == "Assistant message" } else { return false } },
                      "current Codex raw response message items must not collapse into generic tool rows")
        XCTAssertTrue(events.contains { if case .itemDelta(let itemId, let body, _, _) = $0 { return itemId == "raw-message-1" && body == "raw assistant text" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.id == "raw-shell-1" && item.type == .commandExecution && item.summary == "swift test" } else { return false } },
                      "current Codex raw local shell call items must render as command execution")
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.id == "raw-web-1" && item.type == .webSearch && item.summary == "RemoteCode" } else { return false } },
                      "current Codex raw web search call items must render as web search")
    }

    func test_readThreadMapsTokenUsageAndCompactedSnapshotState() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        client.readResponse = [
            "thread": [
                "id": "codex-thread-1",
                "state": "compacted",
                "summary": "Snapshot compacted",
                "tokenUsage": [
                    "last": ["inputTokens": 10, "outputTokens": 2, "totalTokens": 12],
                    "modelContextWindow": 100
                ],
                "turns": []
            ]
        ]
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "read telemetry"
        )) { _ in }

        let events = try adapter.readThread(threadId: threadId)
        XCTAssertTrue(events.contains { if case .tokenUsage(let usage) = $0 { return usage.totalTokens == 12 && usage.contextWindow == 100 } else { return false } })
        XCTAssertTrue(events.contains { if case .contextCompaction(let summary) = $0 { return summary == "Snapshot compacted" } else { return false } })
    }
}

private actor EventSink {
    var events: [AssistantEvent] = []
    var finish: (AgentRunStatus, String?, String?)?

    func record(_ event: AgentRunEvent) {
        switch event {
        case .event(let event): events.append(event)
        case .finished(let status, let final, let providerThreadId): finish = (status, final, providerThreadId)
        case .status, .error: break
        }
    }

    func snapshot() -> [AssistantEvent] {
        events
    }
}

private func waitForApproval(in sink: EventSink) async throws -> AssistantPendingRequest {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        let events = await sink.snapshot()
        if let request = events.compactMap({
            if case .requestOpened(let request) = $0 { return request }
            return nil
        }).first {
            return request
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw XCTSkip("Timed out waiting for approval request")
}

private func waitForUserInput(in sink: EventSink) async throws -> AssistantUserInputRequest {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        let events = await sink.snapshot()
        if let request = events.compactMap({
            if case .userInputRequested(let request) = $0 { return request }
            return nil
        }).first {
            return request
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw XCTSkip("Timed out waiting for user-input request")
}

private func waitForProposedPlan(in sink: EventSink) async throws -> AssistantProposedPlan {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        let events = await sink.snapshot()
        if let plan = events.compactMap({
            if case .proposedPlan(let plan) = $0 { return plan }
            return nil
        }).first {
            return plan
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw XCTSkip("Timed out waiting for proposed plan")
}

private func waitForActivePlan(in sink: EventSink) async throws -> AssistantActivePlan {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        let events = await sink.snapshot()
        if let plan = events.compactMap({
            if case .activePlanUpdated(let plan) = $0 { return plan }
            return nil
        }).first {
            return plan
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw XCTSkip("Timed out waiting for active plan")
}

private func waitForRuntimeEvent(in sink: EventSink, method: String) async throws -> ProviderRuntimeEvent {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        let events = await sink.snapshot()
        if let event = events.compactMap({
            if case .providerRuntime(let event) = $0, event.method == method { return event }
            return nil
        }).first {
            return event
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw XCTSkip("Timed out waiting for runtime event")
}

private func waitForTokenUsage(in sink: EventSink) async throws -> AssistantTokenUsage {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        let events = await sink.snapshot()
        if let usage = events.compactMap({
            if case .tokenUsage(let usage) = $0 { return usage }
            return nil
        }).first {
            return usage
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw XCTSkip("Timed out waiting for token usage")
}

private func waitForContextCompaction(in sink: EventSink) async throws -> String? {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        let events = await sink.snapshot()
        if let summary = events.compactMap({
            if case .contextCompaction(let summary) = $0 { return summary }
            return nil
        }).first {
            return summary
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw XCTSkip("Timed out waiting for context compaction")
}

private func waitForItemCompleted(in sink: EventSink, itemId: String) async throws -> AssistantItemState {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        let events = await sink.snapshot()
        if let state = events.compactMap({
            if case .itemCompleted(let id, let state) = $0, id == itemId { return state }
            return nil
        }).first {
            return state
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw XCTSkip("Timed out waiting for item completion")
}

private final class MockCodexAppServerClient: CodexAppServerControlling, @unchecked Sendable {
    struct StartedTurn {
        let providerThreadId: String
        let request: AgentRunRequest
    }
    struct InterruptedTurn {
        let providerThreadId: String
        let turnId: String
    }
    struct RolledBackTurn {
        let providerThreadId: String
        let numTurns: Int
    }
    struct ReadCall {
        let providerThreadId: String
        let includeTurns: Bool
    }
    struct UpdatedThreadSettings {
        let providerThreadId: String
        let permissionMode: AgentPermissionMode
    }

    var notificationHandler: CodexAppServerClient.NotificationHandler?
    var serverRequestHandler: CodexAppServerClient.ServerRequestHandler?
    var terminationHandler: (@Sendable (Error) -> Void)?
    var readResponse: CodexAppServerClient.JSONObject = ["thread": ["id": "codex-thread-1", "turns": []]]
    let autoComplete: Bool
    private let lock = NSLock()
    private var _didStop = false
    private var _openedRequests: [AgentRunRequest] = []
    private var _startedTurns: [StartedTurn] = []
    private var _interruptedTurns: [InterruptedTurn] = []
    private var _rolledBackTurns: [RolledBackTurn] = []
    private var _readCalls: [ReadCall] = []
    private var _updatedThreadSettings: [UpdatedThreadSettings] = []

    init(autoComplete: Bool = true) {
        self.autoComplete = autoComplete
    }

    var openedRequests: [AgentRunRequest] {
        lock.lock(); defer { lock.unlock() }
        return _openedRequests
    }

    var startedTurns: [StartedTurn] {
        lock.lock(); defer { lock.unlock() }
        return _startedTurns
    }

    var interruptedTurns: [InterruptedTurn] {
        lock.lock(); defer { lock.unlock() }
        return _interruptedTurns
    }

    var rolledBackTurns: [RolledBackTurn] {
        lock.lock(); defer { lock.unlock() }
        return _rolledBackTurns
    }

    var readCalls: [ReadCall] {
        lock.lock(); defer { lock.unlock() }
        return _readCalls
    }

    var updatedThreadSettings: [UpdatedThreadSettings] {
        lock.lock(); defer { lock.unlock() }
        return _updatedThreadSettings
    }

    var didStop: Bool {
        lock.lock(); defer { lock.unlock() }
        return _didStop
    }

    func simulateTermination() {
        terminationHandler?(CodexAppServerError.processExited)
    }

    func initialize(clientName: String, clientTitle: String, clientVersion: String) async throws -> CodexAppServerInitializeResult {
        CodexAppServerInitializeResult(userAgent: "mock", codexHome: nil, platformFamily: nil, platformOs: nil)
    }

    func openThread(for request: AgentRunRequest) async throws -> CodexAppServerThreadOpenResult {
        recordOpened(request)
        let providerThreadId = request.providerThreadId?.isEmpty == false ? request.providerThreadId! : "codex-thread-1"
        return CodexAppServerThreadOpenResult(providerThreadId: providerThreadId, response: ["id": providerThreadId])
    }

    func startTurn(providerThreadId: String, for request: AgentRunRequest) async throws -> CodexAppServerClient.JSONObject {
        recordStarted(StartedTurn(providerThreadId: providerThreadId, request: request))
        if autoComplete {
            Task {
                notificationHandler?("item/agentMessage/delta", [
                    "threadId": providerThreadId,
                    "turnId": "turn-app-server-1",
                    "itemId": "item-1",
                    "delta": "hello from app-server"
                ])
                notificationHandler?("turn/completed", [
                    "threadId": providerThreadId,
                    "turnId": "turn-app-server-1"
                ])
            }
        }
        return ["turn": ["id": "turn-app-server-1"]]
    }

    func interruptTurn(providerThreadId: String, turnId: String) async throws {
        recordInterrupted(InterruptedTurn(providerThreadId: providerThreadId, turnId: turnId))
    }

    func readThread(providerThreadId: String, includeTurns: Bool) async throws -> CodexAppServerClient.JSONObject {
        recordRead(ReadCall(providerThreadId: providerThreadId, includeTurns: includeTurns))
        return readResponse
    }

    func rollbackThread(providerThreadId: String, numTurns: Int) async throws -> CodexAppServerClient.JSONObject {
        recordRolledBack(RolledBackTurn(providerThreadId: providerThreadId, numTurns: numTurns))
        return ["thread": ["id": providerThreadId, "turns": []]]
    }

    func updateThreadSettings(providerThreadId: String, permissionMode: AgentPermissionMode) async throws {
        recordUpdatedThreadSettings(UpdatedThreadSettings(providerThreadId: providerThreadId, permissionMode: permissionMode))
    }

    private func recordUpdatedThreadSettings(_ update: UpdatedThreadSettings) {
        lock.lock()
        _updatedThreadSettings.append(update)
        lock.unlock()
    }

    func stop() {
        lock.lock()
        _didStop = true
        lock.unlock()
    }

    private func recordOpened(_ request: AgentRunRequest) {
        lock.lock()
        _openedRequests.append(request)
        lock.unlock()
    }

    private func recordStarted(_ turn: StartedTurn) {
        lock.lock()
        _startedTurns.append(turn)
        lock.unlock()
    }

    private func recordInterrupted(_ turn: InterruptedTurn) {
        lock.lock()
        _interruptedTurns.append(turn)
        lock.unlock()
    }

    private func recordRolledBack(_ turn: RolledBackTurn) {
        lock.lock()
        _rolledBackTurns.append(turn)
        lock.unlock()
    }

    private func recordRead(_ call: ReadCall) {
        lock.lock()
        _readCalls.append(call)
        lock.unlock()
    }
}
