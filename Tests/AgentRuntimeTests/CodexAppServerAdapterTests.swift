import XCTest
import CoreModel
@testable import AgentRuntime

final class CodexAppServerAdapterTests: ProviderProcessTestCase {
    func test_forkProtocolSchemaSupportFailsClosedWhenRequiredMarkerFieldDisappears() throws {
        // WHY: thread/fork is crash-safe only while the installed app-server can
        // persist our deterministic marker, list it with its parent, and delete
        // a duplicate/orphan during compensation. A partial/older schema must
        // disable the feature instead of making a best-effort provider mutation.
        let schemaDirectory = try makeCodexForkSchemaProjection()
        defer { try? FileManager.default.removeItem(at: schemaDirectory) }

        XCTAssertTrue(CodexForkProtocolSupport.inspect(schemaDirectory: schemaDirectory).isSupported)

        let forkParamsURL = schemaDirectory.appendingPathComponent("v2/ThreadForkParams.json")
        var forkParams = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: forkParamsURL)) as? [String: Any]
        )
        var properties = try XCTUnwrap(forkParams["properties"] as? [String: Any])
        properties.removeValue(forKey: "threadSource")
        forkParams["properties"] = properties
        try JSONSerialization.data(withJSONObject: forkParams, options: [.sortedKeys])
            .write(to: forkParamsURL)

        let unsupported = CodexForkProtocolSupport.inspect(schemaDirectory: schemaDirectory)
        XCTAssertFalse(unsupported.isSupported,
                       "a Codex release without threadSource cannot reconcile a lost fork response and must fail closed")
    }

    func test_currentServerRequestInventoryMatchesGeneratedCodexSchema_0_146_0() throws {
        // WHY: a hand-copied expectation can drift in lockstep with the switch.
        // Read the checked-in projection generated from ServerRequest.json so a
        // schema upgrade introduces a failing ownership decision by default.
        // 0.146 drops currentTime/read from ServerRequest; inventory must not list it.
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CodexAppServer/ServerRequestMethods-0.146.0.json")
        let data = try Data(contentsOf: fixture)
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(schema["generatedBy"] as? String,
                       "codex-cli 0.146.0 app-server generate-json-schema --experimental")
        let variants = try XCTUnwrap(schema["oneOf"] as? [[String: Any]])
        let schemaMethods = Set(variants.compactMap { variant -> String? in
            let properties = variant["properties"] as? [String: Any]
            let method = properties?["method"] as? [String: Any]
            return (method?["enum"] as? [String])?.first
        })

        XCTAssertEqual(schemaMethods.count, variants.count,
                       "every generated ServerRequest variant must expose exactly one method discriminator")
        XCTAssertFalse(schemaMethods.contains("currentTime/read"),
                       "0.146 ServerRequest no longer includes currentTime/read")
        XCTAssertEqual(CodexAppServerAdapter.currentServerRequestMethods, schemaMethods,
                       "upgrading the Codex app-server schema must force an explicit ownership decision for every server request")
    }

    func test_installedCodexServerRequestSchemaMatchesExplicitAdapterInventory() throws {
        guard ProcessInfo.processInfo.environment["RC_REAL_CODEX_SCHEMA_GATE"] == "1" else {
            throw XCTSkip("Set RC_REAL_CODEX_SCHEMA_GATE=1 for the installed Codex release-schema gate.")
        }
        guard let codex = ProcessLocator.resolve("codex") else {
            throw XCTSkip("codex binary is not available on PATH")
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-codex-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }

        let version = try runCodex(codex, arguments: ["--version"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(version, "codex-cli 0.146.0",
                       "the checked-in projection must be regenerated deliberately when the release Codex version changes")
        _ = try runCodex(codex, arguments: [
            "app-server", "generate-json-schema", "--experimental", "--out", output.path
        ])
        let schemaURL = output.appendingPathComponent("ServerRequest.json")
        let data = try Data(contentsOf: schemaURL)
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let variants = try XCTUnwrap(schema["oneOf"] as? [[String: Any]])
        let installedMethods = Set(variants.compactMap { variant -> String? in
            let properties = variant["properties"] as? [String: Any]
            let method = properties?["method"] as? [String: Any]
            return (method?["enum"] as? [String])?.first
        })

        XCTAssertEqual(installedMethods.count, variants.count,
                       "every installed ServerRequest variant must expose one method discriminator")
        XCTAssertEqual(CodexAppServerAdapter.currentServerRequestMethods, installedMethods,
                       "every installed server request must have an explicit ownership decision before release")

        let elicitationData = try Data(contentsOf: output.appendingPathComponent("McpServerElicitationRequestResponse.json"))
        let elicitationSchema = try XCTUnwrap(JSONSerialization.jsonObject(with: elicitationData) as? [String: Any])
        XCTAssertEqual(elicitationSchema["required"] as? [String], ["action"])
        let elicitationDefinitions = try XCTUnwrap(elicitationSchema["definitions"] as? [String: Any])
        let elicitationAction = try XCTUnwrap(elicitationDefinitions["McpServerElicitationAction"] as? [String: Any])
        XCTAssertEqual(elicitationAction["enum"] as? [String], ["accept", "decline", "cancel"],
                       "MCP elicitation response handling must track the installed action contract")

        let permissionsData = try Data(contentsOf: output.appendingPathComponent("PermissionsRequestApprovalResponse.json"))
        let permissionsSchema = try XCTUnwrap(JSONSerialization.jsonObject(with: permissionsData) as? [String: Any])
        XCTAssertEqual(permissionsSchema["required"] as? [String], ["permissions"])
        let permissionDefinitions = try XCTUnwrap(permissionsSchema["definitions"] as? [String: Any])
        let permissionScope = try XCTUnwrap(permissionDefinitions["PermissionGrantScope"] as? [String: Any])
        XCTAssertEqual(permissionScope["enum"] as? [String], ["turn", "session"],
                       "dynamic permission approval must use the provider-native scope contract")

        XCTAssertTrue(CodexForkProtocolSupport.inspect(schemaDirectory: output).isSupported,
                      "the installed Codex release must prove thread/fork marker, list reconciliation, and delete compensation before fork is exposed")
    }

    func test_realCodexForkRetainsParentContextAndCleansProviderThreads() async throws {
        guard ProcessInfo.processInfo.environment["RC_REAL_CODEX_FORK_GATE"] == "1" else {
            throw XCTSkip("Set RC_REAL_CODEX_FORK_GATE=1 for the authenticated native-fork context gate.")
        }
        guard let codex = ProcessLocator.resolve("codex") else {
            throw XCTSkip("codex binary is not available on PATH")
        }
        guard ProviderCLIProbe.authenticated(provider: .codex, binaryPath: codex) == true else {
            throw XCTSkip("installed Codex is not authenticated")
        }

        let adapter = CodexAppServerAdapter(binaryNameOverride: codex)
        let models = await adapter.listModels()
        guard let model = models.first?.id else {
            throw XCTSkip("installed Codex app-server returned no live model")
        }
        let phrase = "RCFORK\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        let marker = "remotecode-thread-fork:\(UUID().uuidString.lowercased())"
        let parentLocalId = AgentThreadID()
        let childLocalId = AgentThreadID()
        var providerThreadIds: [String] = []

        do {
            let parentSink = EventSink()
            _ = try await adapter.sendTurn(AgentRunRequest(
                threadId: parentLocalId,
                provider: .codex,
                model: model,
                cwd: FileManager.default.temporaryDirectory.path,
                prompt: "Remember this exact phrase for the next turn: \(phrase). Reply only READY.",
                permissionMode: .supervised
            )) { event in Task { await parentSink.record(event) } }
            let parentFinish = try await waitForFinish(in: parentSink, timeout: 120)
            XCTAssertEqual(parentFinish.0, .completed)
            let parentProviderId = try XCTUnwrap(parentFinish.2)
            providerThreadIds.append(parentProviderId)

            let request = AgentProviderForkRequest(
                sourceThreadId: parentLocalId,
                childThreadId: childLocalId,
                idempotencyKey: marker,
                workingDirectory: FileManager.default.temporaryDirectory.path
            )
            let childProviderId = try await adapter.forkThread(request)
            providerThreadIds.append(childProviderId)

            let childSink = EventSink()
            _ = try await adapter.sendTurn(AgentRunRequest(
                threadId: childLocalId,
                provider: .codex,
                model: model,
                cwd: FileManager.default.temporaryDirectory.path,
                prompt: "What exact phrase did I ask you to remember? Reply only with that phrase.",
                providerThreadId: childProviderId,
                permissionMode: .supervised
            )) { event in Task { await childSink.record(event) } }
            let childFinish = try await waitForFinish(in: childSink, timeout: 120)
            XCTAssertEqual(childFinish.0, .completed)
            XCTAssertEqual(childFinish.1?.trimmingCharacters(in: .whitespacesAndNewlines), phrase,
                           "the provider-native child must answer from the parent's forked context, not a copied/local-only transcript")
        } catch {
            adapter.stopAll()
            _ = await deleteRealCodexThreads(providerThreadIds, binary: codex)
            throw error
        }

        adapter.stopAll()
        let cleanupFailures = await deleteRealCodexThreads(providerThreadIds, binary: codex)
        XCTAssertTrue(cleanupFailures.isEmpty,
                      "real fork proof must delete every provider thread it created: \(cleanupFailures)")
    }

    private func runCodex(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "codex \(arguments.joined(separator: " ")) failed: \(errors)")
        return output
    }

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

    func test_adapterReconcilesTerminalThreadWhenCommandCompletionNotificationsAreLost() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        client.readResponse = [
            "thread": [
                "id": "codex-thread-1",
                "status": ["type": "idle"],
                "turns": [[
                    "id": "turn-app-server-1",
                    "status": "completed",
                    "items": [
                        [
                            "id": "cmd-1",
                            "type": "commandExecution",
                            "command": "sed -n '1,260p' SKILL.md",
                            "status": "completed",
                            "aggregatedOutput": "done"
                        ],
                        [
                            "id": "answer-1",
                            "type": "agentMessage",
                            "text": "SEO skill reviewed."
                        ]
                    ]
                ]]
            ]
        ]
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
            prompt: "review the skill"
        )) { event in
            Task { await sink.record(event) }
        }
        client.notificationHandler?("item/started", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "item": [
                "id": "cmd-1",
                "type": "commandExecution",
                "command": "sed -n '1,260p' SKILL.md",
                "status": "inProgress"
            ]
        ])

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, await sink.finish == nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let finish = await sink.finish
        XCTAssertEqual(finish?.0, .completed)
        XCTAssertEqual(finish?.1, "SEO skill reviewed.")
        XCTAssertEqual(finish?.2, "codex-thread-1")
        XCTAssertFalse(client.readCalls.isEmpty,
                       "a quiet command item must reconcile against thread/read so lost terminal notifications cannot leave Working stuck")
    }

    func test_followUpTurnReusesLiveAppServerClientInsteadOfResumingInSecondProcess() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let factoryCallCount = LockedCounter()
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            factoryCallCount.increment()
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
            prompt: "first"
        )) { event in
            Task { await sink.record(event) }
        }
        client.notificationHandler?("turn/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-1",
            "finalMessage": "first done"
        ])

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "second",
            providerThreadId: "codex-thread-1"
        )) { event in
            Task { await sink.record(event) }
        }

        XCTAssertEqual(factoryCallCount.value, 1,
                       "a follow-up turn must remain on the live app-server process so its notifications stay attached to the Agent App")
        XCTAssertEqual(client.openedRequests.count, 1,
                       "thread/resume is restart recovery, not the normal same-process follow-up path")
        XCTAssertEqual(client.startedTurns.map(\.request.prompt), ["first", "second"])
        XCTAssertFalse(client.didStop)
    }

    func test_activeThreadStatusDefersFinishAfterTurnCompletedUntilIdle() async throws {
        // WHY: Codex can report turn/completed while its app-server still reports
        // the thread active and keeps sending visible work updates. The Agent App
        // must keep the run busy so the composer queues/rejects new sends instead
        // of starting a second turn against a still-working Codex session.
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()
        let request = AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "long codex task"
        )

        _ = try await adapter.sendTurn(request) { event in
            Task { await sink.record(event) }
        }
        client.notificationHandler?("thread/status/changed", [
            "threadId": "codex-thread-1",
            "status": ["type": "active", "activeFlags": ["runningCommand"]]
        ])
        client.notificationHandler?("turn/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "finalMessage": "done"
        ])
        client.notificationHandler?("process/outputDelta", [
            "processHandle": "proc-after-completed",
            "stream": "stdout",
            "delta": "still working\n"
        ])

        try await Task.sleep(nanoseconds: 50_000_000)
        let prematureFinish = await sink.finish
        XCTAssertNil(prematureFinish,
                     "turn/completed must not finish the local run while Codex still reports the thread active")

        do {
            _ = try await adapter.sendTurn(request) { _ in }
            XCTFail("a second Codex turn must be rejected while the previous app-server thread is still active")
        } catch {
            // expected: active Codex status keeps the turn in flight.
        }

        client.notificationHandler?("thread/status/changed", [
            "threadId": "codex-thread-1",
            "status": ["type": "idle"]
        ])

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let finish = await sink.finish {
                XCTAssertEqual(finish.0, .completed)
                XCTAssertEqual(finish.1, "done")
                XCTAssertEqual(finish.2, "codex-thread-1")
                let events = await sink.snapshot()
                XCTAssertTrue(events.contains {
                    if case .itemStarted(let item) = $0 {
                        return item.summary == "Thread status changed"
                            && item.output == "idle"
                            && item.turnId == "turn-app-server-1"
                    }
                    return false
                }, "the idle status that releases a deferred finish must still attach to the completed Codex turn")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("idle Codex thread status must release the deferred completed turn")
    }

    func test_pendingFinishInactivityFlushesWhenThreadNeverGoesIdle() async throws {
        // WHY: removing absolute max left wedged pendingFinish with no exit if
        // idle never arrives. Quiet inactivity must flush the withheld finish
        // while continuous process output re-arms (see progress test).
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter(
            clientFactory: { _, notificationHandler, _ in
                client.notificationHandler = notificationHandler
                return client
            },
            pendingFinishInactivityTimeout: 0.3
        )
        let threadId = AgentThreadID()
        let sink = EventSink()
        let request = AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "wedged active"
        )
        _ = try await adapter.sendTurn(request) { event in
            Task { await sink.record(event) }
        }
        client.notificationHandler?("thread/status/changed", [
            "threadId": "codex-thread-1",
            "status": ["type": "active", "activeFlags": ["runningCommand"]]
        ])
        client.notificationHandler?("turn/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "finalMessage": "done-but-stuck"
        ])
        // No idle, no further activity — inactivity must flush.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let finish = await sink.finish {
                XCTAssertEqual(finish.0, .completed)
                XCTAssertEqual(finish.1, "done-but-stuck")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("pendingFinish inactivity must release a wedged active deferral")
    }

    func test_pendingFinishInactivityReArmsOnProcessOutput() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter(
            clientFactory: { _, notificationHandler, _ in
                client.notificationHandler = notificationHandler
                return client
            },
            pendingFinishInactivityTimeout: 0.35
        )
        let threadId = AgentThreadID()
        let sink = EventSink()
        let request = AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "long nested"
        )
        _ = try await adapter.sendTurn(request) { event in
            Task { await sink.record(event) }
        }
        client.notificationHandler?("thread/status/changed", [
            "threadId": "codex-thread-1",
            "status": ["type": "active"]
        ])
        client.notificationHandler?("turn/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "finalMessage": "still going"
        ])
        // Keep re-arming past the first inactivity window.
        for i in 0..<8 {
            try await Task.sleep(nanoseconds: 100_000_000)
            client.notificationHandler?("process/outputDelta", [
                "processHandle": "proc-\(i)",
                "stream": "stdout",
                "delta": "tick \(i)\n"
            ])
            if await sink.finish != nil {
                XCTFail("process output must re-arm pendingFinish inactivity")
                return
            }
        }
        // Stop activity; quiet should flush.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let finish = await sink.finish {
                XCTAssertEqual(finish.0, .completed)
                XCTAssertEqual(finish.1, "still going")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("quiet after process progress must flush pendingFinish")
    }

    func test_adapterInterruptUsesActiveAppServerTurn() async throws {
        let client = MockCodexAppServerClient(autoComplete: false, interruptDelayNanoseconds: 200_000_000)
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

        try await Task.sleep(nanoseconds: 50_000_000)
        let prematureStatus = await sink.status()
        XCTAssertNil(prematureStatus,
                     "Stop must not publish a terminal cancelled state before the native turn/interrupt RPC settles")

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

    func test_startTurnFailureStopsAndRemovesRecordedSession() async throws {
        let client = MockCodexAppServerClient(
            autoComplete: false,
            startTurnError: NSError(domain: "CodexStart", code: 1)
        )
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let threadId = AgentThreadID()

        do {
            _ = try await adapter.sendTurn(AgentRunRequest(
                threadId: threadId,
                provider: .codex,
                model: "gpt-5.5",
                cwd: "/tmp/remotecode-app-server-adapter",
                prompt: "fail start"
            )) { _ in }
            XCTFail("startTurn failure must propagate")
        } catch {
            XCTAssertFalse(adapter.hasSession(threadId: threadId),
                           "a session recorded before startTurn must be removed when startTurn fails")
            XCTAssertTrue(client.didStop,
                          "a failed startTurn must stop the app-server process instead of leaking it")
        }
    }

    func test_sendTurn_rejectsConcurrentInFlightTurn() async throws {
        // RUN-LIFECYCLE-STREAM-003: a second concurrent turn on a thread with a
        // live turn must be rejected, not silently replace the session.
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let threadId = AgentThreadID()
        func makeRequest() -> AgentRunRequest {
            AgentRunRequest(threadId: threadId, provider: .codex, model: "gpt-5.5",
                            cwd: "/tmp/remotecode-app-server-adapter", prompt: "wait")
        }
        let noop: @Sendable (AgentRunEvent) -> Void = { _ in }

        // First turn starts and stays in flight (autoComplete: false).
        _ = try await adapter.sendTurn(makeRequest(), onEvent: noop)

        do {
            _ = try await adapter.sendTurn(makeRequest(), onEvent: noop)
            XCTFail("a second concurrent turn on an in-flight thread must be rejected")
        } catch {
            // expected — the adapter throws rather than replacing the live session.
        }
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

    func test_turnCompletedWithFailedStatusFinishesRunAsFailed() async throws {
        // WHY: openai/codex app-server emits failures only as turn/completed with
        // turn.status=failed (+ turn.error.message). Treating that notification as
        // success paints Agent App green after auth/model failures (CODEX-APP-001).
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
            prompt: "will fail"
        )) { event in
            Task { await sink.record(event) }
        }

        client.notificationHandler?("turn/completed", [
            "threadId": "codex-thread-1",
            "turn": [
                "id": "turn-app-server-1",
                "status": "failed",
                "error": ["message": "model overloaded"]
            ]
        ])

        let finish = try await waitForFinish(in: sink, timeout: 3)
        XCTAssertEqual(finish.0, .failed, "turn/completed with status=failed must finish as .failed, not .completed")
        XCTAssertEqual(finish.1, "model overloaded")
        XCTAssertEqual(finish.2, "codex-thread-1")

        let events = await sink.snapshot()
        XCTAssertTrue(
            events.contains {
                if case .error(let message, let recoverable) = $0 {
                    return message == "model overloaded" && recoverable == false
                }
                return false
            },
            "failed turn/completed must emit a non-recoverable error event with turn.error.message"
        )
        XCTAssertFalse(
            events.contains { if case .turnCompleted = $0 { return true } else { return false } },
            "failed turn must not emit success turnCompleted"
        )
    }

    func test_turnCompletedWithInterruptedStatusFinishesRunAsCancelled() async throws {
        // WHY: interrupts arrive as turn/completed + turn.status=interrupted, not a
        // separate method. They must map to .cancelled like the user-stop path so
        // Agent App does not report a successful completed run (CODEX-APP-001).
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
            prompt: "will interrupt"
        )) { event in
            Task { await sink.record(event) }
        }

        client.notificationHandler?("turn/completed", [
            "threadId": "codex-thread-1",
            "turn": [
                "id": "turn-app-server-1",
                "status": "interrupted"
            ]
        ])

        let finish = try await waitForFinish(in: sink, timeout: 3)
        XCTAssertEqual(finish.0, .cancelled, "turn/completed with status=interrupted must finish as .cancelled")
        XCTAssertNil(finish.1)
        XCTAssertEqual(finish.2, "codex-thread-1")
    }

    func test_turnCompletedWithTopLevelFailedStatusFinishesRunAsFailed() async throws {
        // WHY: status may appear at top-level as a fallback when turn dict is flat;
        // still must not complete successfully.
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
            prompt: "will fail"
        )) { event in
            Task { await sink.record(event) }
        }

        client.notificationHandler?("turn/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "status": "Failed",
            "error": ["message": "rate limit exceeded"]
        ])

        let finish = try await waitForFinish(in: sink, timeout: 3)
        XCTAssertEqual(finish.0, .failed)
        XCTAssertEqual(finish.1, "rate limit exceeded")
    }

    func test_adapterForksNativeProviderSessionWithoutReusingParentIdentity() async throws {
        let client = MockCodexAppServerClient(supportsForkReconciliation: true)
        let adapter = CodexAppServerAdapter(
            clientFactory: { _, notificationHandler, _ in
                client.notificationHandler = notificationHandler
                return client
            },
            forkProtocolSupportOverride: client.forkProtocolSupport
        )
        let parentThreadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: parentThreadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "establish parent context",
            providerThreadId: "codex-parent"
        )) { event in
            Task { await sink.record(event) }
        }
        let finishDeadline = Date().addingTimeInterval(3)
        while await sink.finish == nil, Date() < finishDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let parentFinish = await sink.finish
        XCTAssertEqual(parentFinish?.0, .completed)

        let childProviderThreadId = try await adapter.forkThread(AgentProviderForkRequest(
            sourceThreadId: parentThreadId,
            childThreadId: AgentThreadID(),
            idempotencyKey: "remotecode-thread-fork:adapter-native-child",
            workingDirectory: "/tmp/remotecode-app-server-adapter"
        ))
        client.notificationHandler?("thread/started", ["thread": ["id": childProviderThreadId]])
        client.notificationHandler?("thread/status/changed", [
            "threadId": childProviderThreadId,
            "status": ["type": "active"]
        ])
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(childProviderThreadId, "codex-child")
        XCTAssertEqual(client.forkedThreadIds, ["codex-parent"],
                       "native fork must branch from the provider parent instead of copying only local transcript rows")
        XCTAssertNotEqual(childProviderThreadId, client.forkedThreadIds.first,
                          "the child must receive a distinct provider identity so later parent and child turns remain isolated")
        let events = await sink.snapshot()
        XCTAssertFalse(events.contains {
            if case .threadStarted(_, let providerThreadId) = $0 {
                return providerThreadId == childProviderThreadId
            }
            return false
        }, "a fork-created child notification on the parent client must not overwrite the parent's persisted identity")
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: parentThreadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "parent follow-up",
            providerThreadId: "codex-parent"
        )) { _ in }
    }

    func test_keyedForkRetryReusesMarkerAndNeverCreatesSecondProviderChild() async throws {
        let client = MockCodexAppServerClient(supportsForkReconciliation: true)
        let adapter = CodexAppServerAdapter(
            clientFactory: { _, notificationHandler, _ in
                client.notificationHandler = notificationHandler
                return client
            },
            forkProtocolSupportOverride: client.forkProtocolSupport
        )
        let parentThreadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: parentThreadId,
            provider: .codex,
            model: "gpt-test",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "establish parent",
            providerThreadId: "codex-parent"
        )) { event in Task { await sink.record(event) } }
        let finishDeadline = Date().addingTimeInterval(3)
        while await sink.finish == nil, Date() < finishDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let parentFinish = await sink.finish
        XCTAssertEqual(parentFinish?.0, .completed)
        let request = AgentProviderForkRequest(
            sourceThreadId: parentThreadId,
            childThreadId: AgentThreadID(),
            idempotencyKey: "remotecode-thread-fork:stable-child",
            workingDirectory: "/tmp/remotecode-app-server-adapter"
        )

        let first = try await adapter.forkThread(request)
        let retried = try await adapter.forkThread(request)

        XCTAssertEqual(retried, first)
        XCTAssertEqual(client.typedForkMarkers, [request.idempotencyKey],
                       "a lost local response must be reconciled by threadSource before another thread/fork is sent")
        XCTAssertEqual(client.providerChildren.count, 1)
        XCTAssertEqual(adapter.forkSafety(threadId: parentThreadId),
                       .keyedIdempotent(compensationSupported: true))
    }

    func test_duplicateForkMarkerIsDeletedAndFailsLoudBeforeLocalCommit() async throws {
        let client = MockCodexAppServerClient(supportsForkReconciliation: true)
        let marker = "remotecode-thread-fork:duplicate-child"
        client.seedProviderChild(id: "duplicate-a", parentId: "codex-parent", marker: marker, createdAt: 1)
        client.seedProviderChild(id: "duplicate-b", parentId: "codex-parent", marker: marker, createdAt: 2)
        let adapter = CodexAppServerAdapter(
            clientFactory: { _, notificationHandler, _ in
                client.notificationHandler = notificationHandler
                return client
            },
            forkProtocolSupportOverride: client.forkProtocolSupport
        )
        let parentThreadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: parentThreadId,
            provider: .codex,
            model: "gpt-test",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "establish parent",
            providerThreadId: "codex-parent"
        )) { event in Task { await sink.record(event) } }
        let finishDeadline = Date().addingTimeInterval(3)
        while await sink.finish == nil, Date() < finishDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let parentFinish = await sink.finish
        XCTAssertEqual(parentFinish?.0, .completed)

        do {
            _ = try await adapter.forkThread(AgentProviderForkRequest(
                sourceThreadId: parentThreadId,
                childThreadId: AgentThreadID(),
                idempotencyKey: marker
            ))
            XCTFail("duplicate provider children must not be collapsed silently")
        } catch let error as CodexForkReconciliationError {
            XCTAssertTrue(error.description.contains("marker conflict was cleaned"))
        }
        XCTAssertEqual(Set(client.deletedThreadIds), Set(["duplicate-a", "duplicate-b"]))
        XCTAssertTrue(client.providerChildren.isEmpty)
        XCTAssertTrue(client.typedForkMarkers.isEmpty,
                      "cleanup must finish before any replacement fork can be attempted")
    }

    func test_forkCompensationIsIdempotentAcrossLostDeleteResponseRetry() async throws {
        let client = MockCodexAppServerClient(supportsForkReconciliation: true)
        let adapter = CodexAppServerAdapter(
            clientFactory: { _, notificationHandler, _ in
                client.notificationHandler = notificationHandler
                return client
            },
            forkProtocolSupportOverride: client.forkProtocolSupport
        )
        let parentThreadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: parentThreadId,
            provider: .codex,
            model: "gpt-test",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "establish parent",
            providerThreadId: "codex-parent"
        )) { event in Task { await sink.record(event) } }
        let finishDeadline = Date().addingTimeInterval(3)
        while await sink.finish == nil, Date() < finishDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let parentFinish = await sink.finish
        XCTAssertEqual(parentFinish?.0, .completed)
        let request = AgentProviderForkRequest(
            sourceThreadId: parentThreadId,
            childThreadId: AgentThreadID(),
            idempotencyKey: "remotecode-thread-fork:compensated-child"
        )
        let child = try await adapter.forkThread(request)

        try await adapter.compensateFork(request, providerChildThreadId: child)
        try await adapter.compensateFork(request, providerChildThreadId: child)

        XCTAssertEqual(client.deletedThreadIds, [child],
                       "retry after successful delete must resolve from absence without sending a second mutation")
        XCTAssertTrue(client.providerChildren.isEmpty)
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

        try await adapter.rollbackThread(threadId: threadId, toTurnId: "turn-alpha")

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

        try await adapter.recoverSession(AgentRunRequest(
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

        let events = try await adapter.readThread(threadId: threadId)
        XCTAssertTrue(events.contains { if case .turnCompleted(let turnId, _) = $0 { return turnId == "turn-beta" } else { return false } })
        XCTAssertEqual(client.readCalls.first?.providerThreadId, "codex-thread-recovered")

        try await adapter.rollbackThread(threadId: threadId, toTurnId: "turn-alpha")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !client.rolledBackTurns.isEmpty { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(client.rolledBackTurns.first?.providerThreadId, "codex-thread-recovered")
        XCTAssertEqual(client.rolledBackTurns.first?.numTurns, 1)

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "continue recovered context",
            providerThreadId: "codex-thread-recovered"
        )) { _ in }
        XCTAssertEqual(client.startedTurns.last?.providerThreadId, "codex-thread-recovered",
                       "a passive relaunch recovery must allow Continue on the same provider context")
    }

    func test_adapterReplacesTimedOutResumeClientBeforeStartingFreshThread() async throws {
        // WHY: a single timed-out resume used to start a brand-new thread and
        // drop context. Recovery now retries resume on a fresh client first;
        // start-fresh is only the last resort after the bounded resume budget.
        let timedOut = MockCodexAppServerClient(
            autoComplete: false,
            openThreadError: CodexAppServerError.requestTimedOut(method: "thread/resume", timeout: 30)
        )
        let recovered = MockCodexAppServerClient(autoComplete: false)
        let factoryCalls = LockedCounter()
        let adapter = CodexAppServerAdapter(
            clientFactory: { _, notificationHandler, _ in
                factoryCalls.increment()
                let client = factoryCalls.value == 1 ? timedOut : recovered
                client.notificationHandler = notificationHandler
                return client
            },
            threadResumeRetryPolicy: CodexThreadResumeRetryPolicy(
                maxAttempts: 2,
                backoffNanoseconds: [],
                perAttemptTimeoutHint: 30
            )
        )
        let threadId = AgentThreadID()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "continue after a dead app server",
            providerThreadId: "persisted-thread"
        )) { _ in }

        XCTAssertTrue(timedOut.didStop,
                      "the deadline-stopped resume client must never receive a fallback request")
        XCTAssertEqual(timedOut.openedRequests.map(\.providerThreadId), ["persisted-thread"],
                       "the first client must attempt the persisted resume exactly once")
        XCTAssertEqual(recovered.openedRequests.map(\.providerThreadId), ["persisted-thread"],
                       "the replacement client must retry the same thread/resume, not drop context immediately")
        XCTAssertEqual(recovered.startedTurns.map(\.providerThreadId), ["persisted-thread"],
                       "only the recovered resume client may begin the requested provider turn")
    }

    func test_slowThreadResumeThenSuccessDoesNotFailTheRun() async throws {
        // WHY: a single slow thread/resume used to hard-fail the run. One
        // transient timeout must not destroy a continue-on-existing-thread turn.
        let timedOut = MockCodexAppServerClient(
            autoComplete: false,
            openThreadError: CodexAppServerError.requestTimedOut(method: "thread/resume", timeout: 0.05)
        )
        let recovered = MockCodexAppServerClient(autoComplete: false)
        let factoryCalls = LockedCounter()
        let adapter = CodexAppServerAdapter(
            clientFactory: { _, notificationHandler, _ in
                factoryCalls.increment()
                let client = factoryCalls.value == 1 ? timedOut : recovered
                client.notificationHandler = notificationHandler
                return client
            },
            threadResumeRetryPolicy: CodexThreadResumeRetryPolicy(
                maxAttempts: 3,
                backoffNanoseconds: [],
                perAttemptTimeoutHint: 0.05
            )
        )
        let threadId = AgentThreadID()
        let sink = EventSink()

        let handle = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "continue after a slow resume",
            providerThreadId: "slow-thread"
        )) { event in
            Task { await sink.record(event) }
        }

        XCTAssertEqual(factoryCalls.value, 2, "one timed-out resume client plus one successful retry")
        XCTAssertEqual(recovered.openedRequests.map(\.providerThreadId), ["slow-thread"])
        XCTAssertEqual(recovered.startedTurns.map(\.providerThreadId), ["slow-thread"])
        XCTAssertTrue(adapter.hasSession(threadId: threadId),
                      "a recovered resume must leave a live session instead of failing the run")
        handle.cancel()
    }

    func test_permanentlyUnresponsiveResumeTerminatesWithActionableMessage() async throws {
        // WHY: a dead/silent app-server must not hang or retry forever. The
        // bounded budget ends with a message that names the operation and bound.
        let factoryCalls = LockedCounter()
        let adapter = CodexAppServerAdapter(
            clientFactory: { _, notificationHandler, _ in
                factoryCalls.increment()
                let client = MockCodexAppServerClient(
                    autoComplete: false,
                    openThreadError: CodexAppServerError.requestTimedOut(method: "thread/resume", timeout: 0.05)
                )
                client.notificationHandler = notificationHandler
                return client
            },
            threadResumeRetryPolicy: CodexThreadResumeRetryPolicy(
                maxAttempts: 2,
                backoffNanoseconds: [],
                perAttemptTimeoutHint: 0.05
            )
        )
        let startedAt = Date()

        do {
            _ = try await adapter.sendTurn(AgentRunRequest(
                threadId: AgentThreadID(),
                provider: .codex,
                model: "gpt-5.5",
                cwd: "/tmp/remotecode-app-server-adapter",
                prompt: "must not hang",
                providerThreadId: "dead-thread"
            )) { _ in }
            XCTFail("an unresponsive app-server must terminate within the resume bound")
        } catch let error as CodexAppServerError {
            guard case .threadResumeUnavailable(let attempts, let elapsedBound) = error else {
                return XCTFail("expected threadResumeUnavailable, got \(error)")
            }
            XCTAssertEqual(attempts, 2)
            XCTAssertEqual(elapsedBound, 0.1, accuracy: 0.000_1)
            let message = String(describing: error)
            XCTAssertTrue(message.contains("thread/resume"), "error must name the operation: \(message)")
            XCTAssertTrue(message.contains("0.1s") || message.contains("0.1"),
                          "error must name the elapsed bound: \(message)")
            XCTAssertTrue(message.localizedCaseInsensitiveContains("retry")
                            || message.localizedCaseInsensitiveContains("new"),
                          "error must tell the user what to do: \(message)")
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1,
                              "must not hang or retry unbounded")
            // 2 resume attempts + 1 start-fresh fallback
            XCTAssertEqual(factoryCalls.value, 3)
        }
    }

    func test_cancellationDuringResumeRetryStopsPromptly() async throws {
        // WHY: user Stop (Task cancel) during a resume retry/backoff must not
        // wait out the full multi-attempt budget.
        let openEntered = expectation(description: "first openThread entered")
        let factoryCalls = LockedCounter()
        let adapter = CodexAppServerAdapter(
            clientFactory: { _, notificationHandler, _ in
                factoryCalls.increment()
                let client = MockCodexAppServerClient(
                    autoComplete: false,
                    openThreadBehavior: .hangUntilCancelled(onEnter: {
                        if factoryCalls.value == 1 {
                            openEntered.fulfill()
                        }
                    })
                )
                client.notificationHandler = notificationHandler
                return client
            },
            threadResumeRetryPolicy: CodexThreadResumeRetryPolicy(
                maxAttempts: 3,
                backoffNanoseconds: [5_000_000_000, 5_000_000_000],
                perAttemptTimeoutHint: 30
            )
        )
        let threadId = AgentThreadID()
        let startedAt = Date()
        let task = Task {
            try await adapter.sendTurn(AgentRunRequest(
                threadId: threadId,
                provider: .codex,
                model: "gpt-5.5",
                cwd: "/tmp/remotecode-app-server-adapter",
                prompt: "cancel me during resume",
                providerThreadId: "cancel-thread"
            )) { _ in }
        }

        await fulfillment(of: [openEntered], timeout: 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled resume open must not succeed")
        } catch is CancellationError {
            // expected
        } catch {
            // Some paths wrap cancellation; accept either shape if the run ends promptly.
            let message = String(describing: error).lowercased()
            XCTAssertTrue(
                error is CancellationError || message.contains("cancel"),
                "expected cancellation, got \(error)"
            )
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1,
                          "cancel during resume retry must stop promptly, not wait out backoff/timeouts")
        XCTAssertEqual(factoryCalls.value, 1,
                       "cancel must not continue spawning further resume retry clients")
    }

    func test_adapterIgnoresDelayedTerminationFromReplacedTimedOutResumeClient() async throws {
        // WHY: stopping the timed-out resume client does not guarantee its
        // process-exit callback cannot arrive after the recovered session is stored.
        let timedOut = MockCodexAppServerClient(
            autoComplete: false,
            openThreadError: CodexAppServerError.requestTimedOut(method: "thread/resume", timeout: 30)
        )
        let recovered = MockCodexAppServerClient(autoComplete: false)
        let factoryCalls = LockedCounter()
        let adapter = CodexAppServerAdapter(
            clientFactory: { _, notificationHandler, _ in
                factoryCalls.increment()
                let client = factoryCalls.value == 1 ? timedOut : recovered
                client.notificationHandler = notificationHandler
                return client
            },
            threadResumeRetryPolicy: CodexThreadResumeRetryPolicy(
                maxAttempts: 2,
                backoffNanoseconds: [],
                perAttemptTimeoutHint: 30
            )
        )
        let threadId = AgentThreadID()

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "continue after a dead app server",
            providerThreadId: "persisted-thread"
        )) { _ in }

        timedOut.simulateTermination()

        XCTAssertTrue(adapter.hasSession(threadId: threadId),
                      "a delayed callback from the stopped resume client must not remove the recovered session")
        XCTAssertFalse(recovered.didStop,
                       "the replacement client must remain usable after the old client exits late")
    }

    func test_adapterRecoveryFallbackDoesNotRestoreStaleActiveTurn() async throws {
        // WHY: when resume keeps timing out and we fall back to thread/start, the
        // persisted active turn belongs to the old peer, not the replacement session.
        let timedOut = MockCodexAppServerClient(
            autoComplete: false,
            openThreadError: CodexAppServerError.requestTimedOut(method: "thread/resume", timeout: 30)
        )
        let freshStart = MockCodexAppServerClient(autoComplete: false)
        let factoryCalls = LockedCounter()
        let adapter = CodexAppServerAdapter(
            clientFactory: { _, notificationHandler, _ in
                factoryCalls.increment()
                // Exhaust the resume budget with timeouts, then allow start-fresh.
                let client = factoryCalls.value <= 2 ? timedOut : freshStart
                client.notificationHandler = notificationHandler
                return client
            },
            threadResumeRetryPolicy: CodexThreadResumeRetryPolicy(
                maxAttempts: 2,
                backoffNanoseconds: [],
                perAttemptTimeoutHint: 30
            )
        )
        let threadId = AgentThreadID()
        let sink = EventSink()

        try await adapter.recoverSession(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "",
            providerThreadId: "persisted-thread",
            extraArgs: ["remotecode.recovery.activeTurnId=stale-turn"]
        )) { event in
            Task { await sink.record(event) }
        }
        try adapter.interruptTurn(threadId: threadId)

        XCTAssertTrue(timedOut.didStop)
        XCTAssertEqual(freshStart.openedRequests.map(\.providerThreadId), [nil])
        XCTAssertEqual(adapter.listSessions().first?.status, .completed,
                       "a fresh fallback has no recovered active turn and must not be marked running")
        XCTAssertTrue(freshStart.interruptedTurns.isEmpty,
                      "Stop must not send the stale turn id to the new provider thread")
        let events = try await waitForEvents(in: sink) { events in
            events.contains {
                if case .error(let message, let recoverable) = $0 {
                    return recoverable && message.contains("starting a new session")
                }
                return false
            }
        }
        XCTAssertTrue(events.contains {
            if case .error(let message, let recoverable) = $0 {
                return recoverable && message.contains("starting a new session")
            }
            return false
        }, "recovery must disclose that it opened a new session instead of resuming the old turn")
    }

    func test_adapterRecoveryRestoresActiveTurnForInterrupt() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let threadId = AgentThreadID()

        try await adapter.recoverSession(AgentRunRequest(
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

        try await adapter.respondToRequest(threadId: threadId, requestId: request.id, response: .approveForSession)
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

    func test_applyPatchApprovalUsesReviewDecisionDialect() async throws {
        // WHY: applyPatchApproval / execCommandApproval use ReviewDecision
        // (approved|approved_for_session|{denied}|abort), not the accept dialect.
        // Sending accept* makes Codex 0.146 reject the JSON-RPC result.
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId, provider: .codex, model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter", prompt: "patch"
        )) { event in Task { await sink.record(event) } }

        var seenRequestIds = Set<String>()
        func decision(
            method: String,
            response: AgentProviderRequestResponse,
            itemId: String
        ) async throws -> [String: Any] {
            let responseTask = Task {
                try await client.serverRequestHandler?(method, [
                    "threadId": "codex-thread-1",
                    "turnId": "turn-app-server-1",
                    "itemId": itemId,
                    "command": "apply_patch"
                ])
            }
            // waitForApproval always returns the first opened card; skip already-handled ids.
            let request: AssistantPendingRequest = try await {
                let deadline = Date().addingTimeInterval(3)
                while Date() < deadline {
                    let events = await sink.snapshot()
                    if let request = events.compactMap({
                        if case .requestOpened(let request) = $0 { return request }
                        return nil
                    }).first(where: { !seenRequestIds.contains($0.id) }) {
                        return request
                    }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                throw CodexAdapterTestWaitError.timedOut("approval request \(itemId)")
            }()
            seenRequestIds.insert(request.id)
            try await adapter.respondToRequest(threadId: threadId, requestId: request.id, response: response)
            let raw = try await responseTask.value
            return try XCTUnwrap(raw as? [String: Any])
        }

        // Interactive decisions first (before Approve Session promotes fullAccess).
        let approved = try await decision(method: "applyPatchApproval", response: .approve, itemId: "patch-approve")
        XCTAssertEqual(approved["decision"] as? String, "approved")

        let declined = try await decision(
            method: "applyPatchApproval",
            response: .decline("not this path"),
            itemId: "patch-decline"
        )
        let denied = try XCTUnwrap(declined["decision"] as? [String: Any])
        let rejection = try XCTUnwrap(denied["denied"] as? [String: Any])
        XCTAssertEqual(rejection["rejection"] as? String, "not this path")

        let declinedDefault = try await decision(
            method: "execCommandApproval",
            response: .decline(nil),
            itemId: "exec-decline"
        )
        let deniedDefault = try XCTUnwrap(declinedDefault["decision"] as? [String: Any])
        let rejectionDefault = try XCTUnwrap(deniedDefault["denied"] as? [String: Any])
        XCTAssertEqual(rejectionDefault["rejection"] as? String, "declined")

        let aborted = try await decision(method: "execCommandApproval", response: .cancel, itemId: "exec-cancel")
        XCTAssertEqual(aborted["decision"] as? String, "abort")

        let approvedSession = try await decision(
            method: "applyPatchApproval",
            response: .approveForSession,
            itemId: "patch-session"
        )
        XCTAssertEqual(approvedSession["decision"] as? String, "approved_for_session")

        // After Approve Session, fullAccess auto-approve must also use ReviewDecision.
        let autoPatch = try await client.serverRequestHandler?("applyPatchApproval", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "itemId": "patch-auto",
            "command": "apply_patch"
        ])
        let autoPatchDecision = try XCTUnwrap(autoPatch as? [String: Any])
        XCTAssertEqual(autoPatchDecision["decision"] as? String, "approved_for_session",
                       "fullAccess auto-approve for applyPatch must use approved_for_session, not acceptForSession")

        let autoExec = try await client.serverRequestHandler?("execCommandApproval", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "itemId": "exec-auto",
            "command": "ls"
        ])
        let autoExecDecision = try XCTUnwrap(autoExec as? [String: Any])
        XCTAssertEqual(autoExecDecision["decision"] as? String, "approved_for_session")
    }

    func test_commandExecutionApprovalStillUsesAcceptDialect() async throws {
        // WHY: item/* requestApproval methods keep accept|acceptForSession|decline|cancel.
        // ReviewDecision must not leak into the modern path.
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId, provider: .codex, model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter", prompt: "cmd"
        )) { event in Task { await sink.record(event) } }

        let responseTask = Task {
            try await client.serverRequestHandler?("item/commandExecution/requestApproval", [
                "threadId": "codex-thread-1",
                "turnId": "turn-app-server-1",
                "itemId": "cmd-accept",
                "command": "swift test"
            ])
        }
        let request = try await waitForApproval(in: sink)
        try await adapter.respondToRequest(threadId: threadId, requestId: request.id, response: .approve)
        let raw = try await responseTask.value
        let response = try XCTUnwrap(raw as? [String: Any])
        XCTAssertEqual(response["decision"] as? String, "accept")
    }

    func test_approveForSessionSettingsFailureSettlesProviderContinuation() async throws {
        let client = MockCodexAppServerClient(
            autoComplete: false,
            updateSettingsError: NSError(domain: "CodexSettings", code: 1)
        )
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId, provider: .codex, model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter", prompt: "needs approval"
        )) { event in Task { await sink.record(event) } }

        let responseTask = Task {
            try await client.serverRequestHandler?("item/commandExecution/requestApproval", [
                "turnId": "turn-app-server-1", "itemId": "cmd-settings", "command": "swift test"
            ])
        }
        let request = try await waitForApproval(in: sink)

        do {
            try await adapter.respondToRequest(threadId: threadId, requestId: request.id, response: .approveForSession)
            XCTFail("settings promotion failure must be surfaced")
        } catch { }
        do {
            _ = try await responseTask.value
            XCTFail("the provider continuation must settle with an error when session settings promotion fails")
        } catch { }
    }

    func test_currentPermissionsRequestIsExplicitlyBridged() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId, provider: .codex, model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter", prompt: "permission"
        )) { event in Task { await sink.record(event) } }

        let responseTask = Task {
            try await client.serverRequestHandler?("item/permissions/requestApproval", [
                "turnId": "turn-app-server-1",
                "itemId": "permission-1",
                "reason": "Use network",
                "permissions": ["network": ["enabled": true]]
            ])
        }
        let request = try await waitForApproval(in: sink)
        XCTAssertEqual(request.kind, .dynamic)
        try await adapter.respondToRequest(threadId: threadId, requestId: request.id, response: .decline(nil))
        let rawResponse = try await responseTask.value
        let response = try XCTUnwrap(rawResponse as? [String: Any])
        XCTAssertNil(response["decision"], "Codex 0.146 rejects the legacy decision shape for permissions")
        XCTAssertEqual(response["scope"] as? String, "turn")
        XCTAssertEqual((response["permissions"] as? [String: Any])?.count, 0,
                       "decline grants an empty permission profile")
    }

    func test_currentPermissionsApprovalGrantsExactlyRequestedProfileAndNativeSessionScope() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId, provider: .codex, model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter", prompt: "permission"
        )) { event in Task { await sink.record(event) } }

        let requested: [String: Any] = [
            "network": ["enabled": true],
            "fileSystem": ["write": ["/tmp/fixture"]]
        ]
        let responseTask = Task {
            try await client.serverRequestHandler?("item/permissions/requestApproval", [
                "threadId": "codex-thread-1",
                "turnId": "turn-app-server-1",
                "itemId": "permission-session",
                "startedAtMs": 1,
                "cwd": "/tmp/remotecode-app-server-adapter",
                "permissions": requested
            ])
        }
        let request = try await waitForApproval(in: sink)
        try await adapter.respondToRequest(
            threadId: threadId,
            requestId: request.id,
            response: .approveForSession
        )

        let rawResponse = try await responseTask.value
        let response = try XCTUnwrap(rawResponse as? [String: Any])
        XCTAssertEqual(response["scope"] as? String, "session")
        let granted = try XCTUnwrap(response["permissions"] as? [String: Any])
        XCTAssertEqual(Set(granted.keys), Set(requested.keys))
        XCTAssertEqual((granted["network"] as? [String: Any])?["enabled"] as? Bool, true)
        XCTAssertEqual((granted["fileSystem"] as? [String: Any])?["write"] as? [String], ["/tmp/fixture"],
                       "approval must grant exactly the requested profile")
        XCTAssertTrue(client.updatedThreadSettings.isEmpty,
                      "dynamic permission scope must not silently promote the whole thread to full access")
    }

    func test_mcpFormElicitationReturnsSchemaTypedActionAndContent() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId, provider: .codex, model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter", prompt: "typed elicitation"
        )) { event in Task { await sink.record(event) } }

        let responseTask = Task {
            try await client.serverRequestHandler?("mcpServer/elicitation/request", [
                "message": "Configure deployment",
                "mode": "form",
                "requestedSchema": [
                    "type": "object",
                    "required": ["environment", "replicas", "dryRun"],
                    "properties": [
                        "environment": ["type": "string", "title": "Environment", "enum": ["staging", "production"]],
                        "replicas": ["type": "integer", "title": "Replicas"],
                        "dryRun": ["type": "boolean", "title": "Dry run"]
                    ]
                ]
            ])
        }
        let request = try await waitForUserInput(in: sink)
        XCTAssertEqual(request.prompt, "Configure deployment")
        XCTAssertEqual(Set(request.questions.map(\.id)), Set(["environment", "replicas", "dryRun"]))

        try adapter.respondToUserInput(
            threadId: threadId,
            requestId: request.id,
            text: #"{"environment":"staging","replicas":3,"dryRun":true}"#
        )
        let rawResponse = try await responseTask.value
        let response = try XCTUnwrap(rawResponse as? [String: Any])
        XCTAssertEqual(response["action"] as? String, "accept")
        XCTAssertNil(response["answers"], "MCP elicitation does not accept request_user_input answers")
        let content = try XCTUnwrap(response["content"] as? [String: Any])
        XCTAssertEqual(content["environment"] as? String, "staging")
        XCTAssertEqual(content["replicas"] as? Int, 3)
        XCTAssertEqual(content["dryRun"] as? Bool, true)
    }

    func test_mcpFormElicitationCancelReturnsActionWithoutContent() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId, provider: .codex, model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter", prompt: "cancel elicitation"
        )) { event in Task { await sink.record(event) } }
        let responseTask = Task {
            try await client.serverRequestHandler?("mcpServer/elicitation/request", [
                "message": "Enter value",
                "mode": "form",
                "requestedSchema": [
                    "type": "object",
                    "properties": ["value": ["type": "string"]]
                ]
            ])
        }
        let request = try await waitForUserInput(in: sink)
        try adapter.cancelUserInput(threadId: threadId, requestId: request.id)
        let rawResponse = try await responseTask.value
        let response = try XCTUnwrap(rawResponse as? [String: Any])
        XCTAssertEqual(response["action"] as? String, "cancel")
        XCTAssertNil(response["content"])
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

    func test_cancelUserInputResolvesOnlyCallbackAndKeepsCodexSession() async throws {
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
            prompt: "ask then continue"
        )) { event in Task { await sink.record(event) } }

        let responseTask = Task {
            try await client.serverRequestHandler?("item/tool/requestUserInput", [
                "threadId": "codex-thread-1",
                "turnId": "turn-app-server-1",
                "itemId": "question-cancel",
                "questions": [["id": "choice", "question": "Choose?"]]
            ])
        }
        let request = try await waitForUserInput(in: sink)

        try adapter.cancelUserInput(threadId: threadId, requestId: request.id)
        let rawResponse = try await responseTask.value
        let response = try XCTUnwrap(rawResponse as? [String: Any])
        XCTAssertEqual((response["answers"] as? [String: Any])?.count, 0,
                       "Codex cancellation must resolve this callback with no fabricated answer")
        XCTAssertTrue(adapter.hasSession(threadId: threadId),
                      "cancelling a question must preserve the provider session and context")
        XCTAssertFalse(client.didStop,
                       "question cancellation must not stop the Codex app-server process")
        let events = await sink.snapshot()
        XCTAssertTrue(events.contains {
            if case .userInputResolved(let id, let answer) = $0 {
                return id == request.id && answer == nil
            }
            return false
        })
        try adapter.stopSession(threadId: threadId)
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

        try await adapter.respondToRequest(threadId: threadId, requestId: request.id, response: .decline(nil))
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

        try await adapter.respondToRequest(threadId: threadId, requestId: request.id, response: .decline(nil))
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
                        "allowsMultipleSelection": true,
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
        XCTAssertEqual(request.questions.map(\.id), ["branch", "confirm"])
        XCTAssertEqual(request.questions.map(\.prompt), ["Which branch?", "Proceed?"])
        XCTAssertEqual(request.questions[1].options.map(\.label), ["yes", "no"])
        XCTAssertEqual(request.questions.map(\.allowsMultipleSelection), [false, true])

        try adapter.respondToUserInput(
            threadId: threadId,
            requestId: request.id,
            text: #"{"Which branch?":"release/next","Proceed?":["yes","no"]}"#
        )
        let rawResponse = try await responseTask.value
        let response = try XCTUnwrap(rawResponse as? [String: Any])
        let answers = try XCTUnwrap(response["answers"] as? [String: [String: [String]]])
        XCTAssertEqual(answers["branch"]?["answers"], ["release/next"])
        XCTAssertEqual(answers["confirm"]?["answers"], ["yes", "no"])
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

    func test_authFailurePublishesSignInActionMetadata() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId, provider: .codex, model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter", prompt: "auth"
        )) { event in Task { await sink.record(event) } }

        client.notificationHandler?("turn/failed", [
            "turnId": "turn-app-server-1",
            "error": ["code": "token_expired", "message": "Login required"]
        ])

        let runtime = try await waitForRuntimeEvent(in: sink, method: "remotecode/authRequired")
        XCTAssertTrue(runtime.payloadJSON.contains("Sign in"))
        XCTAssertTrue(runtime.payloadJSON.contains("codex login"))
    }

    func test_imageViewSnapshotUsesBasenameAndNeverExposesAbsolutePath() async throws {
        let client = MockCodexAppServerClient(autoComplete: false)
        client.readResponse = ["thread": ["id": "codex-thread-image", "turns": [[
            "id": "turn-image", "status": "completed", "items": [[
                "id": "image-1", "type": "imageView", "path": "/Users/private/work/generated.png"
            ]]
        ]]]]
        let adapter = CodexAppServerAdapter { _, notificationHandler, serverRequestHandler in
            client.notificationHandler = notificationHandler
            client.serverRequestHandler = serverRequestHandler
            return client
        }
        let threadId = AgentThreadID()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId, provider: .codex, model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter", prompt: "read image"
        )) { _ in }

        let events = try await adapter.readThread(threadId: threadId)
        let item = try XCTUnwrap(events.compactMap { event -> AssistantItem? in
            if case .itemStarted(let item) = event, item.id == "image-1" { return item }
            return nil
        }.first)
        XCTAssertEqual(item.summary, "generated.png")
        XCTAssertEqual(item.resourcePath, "/Users/private/work/generated.png",
                       "the full path must remain private action metadata for Open/Reveal, not transcript text")
        XCTAssertFalse(item.body.contains("/Users/private"))
        XCTAssertFalse(item.output?.contains("/Users/private") == true)
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

        let events = try await adapter.readThread(threadId: threadId)

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

        let events = try await adapter.readThread(threadId: threadId)

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

    func test_adapterFinalMessageIsLastAgentMessageItemNotConcatenationOfPreambles() async throws {
        // A single turn can emit several assistant-message items: short preamble
        // notes ("State:/Action:") before tool calls, then the real answer. The
        // final answer must be the LAST message only, NOT the concatenation of
        // every preamble — otherwise the answer bubble (and the persisted, reload-
        // surviving message) shows the whole narration of the turn.
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
            prompt: "do work"
        )) { event in
            Task { await sink.record(event) }
        }

        for (itemId, text) in [("msg-1", "Reading the config."), ("msg-2", "Running the tests."), ("msg-3", "All checks passed.")] {
            client.notificationHandler?("item/agentMessage/delta", [
                "threadId": "codex-thread-1",
                "turnId": "turn-preambles-1",
                "itemId": itemId,
                "delta": text
            ])
        }
        client.notificationHandler?("turn/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-preambles-1"
        ])

        try await Task.sleep(nanoseconds: 50_000_000)
        let events = await sink.snapshot()
        let final = events.compactMap { event -> String? in
            if case .turnCompleted(_, let final) = event { return final }
            return nil
        }.first

        XCTAssertEqual(final, "All checks passed.",
                       "the final answer must be the last assistant message item, not every preamble concatenated")
        XCTAssertNotEqual(final, "Reading the config.Running the tests.All checks passed.",
                       "preamble messages from earlier in the turn must not leak into the final answer")
    }

    func test_adapterAccumulatesMultipleDeltasOfSameAgentMessageItem() async throws {
        // Per-item reset must NOT break intra-item streaming: multiple deltas that
        // share one item id are still concatenated into that item's full text.
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

        client.notificationHandler?("item/agentMessage/delta", [
            "threadId": "codex-thread-1",
            "turnId": "turn-same-item-1",
            "itemId": "msg-1",
            "delta": "1 2 3"
        ])
        client.notificationHandler?("item/agentMessage/delta", [
            "threadId": "codex-thread-1",
            "turnId": "turn-same-item-1",
            "itemId": "msg-1",
            "delta": " 4 5"
        ])
        client.notificationHandler?("turn/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-same-item-1"
        ])

        try await Task.sleep(nanoseconds: 50_000_000)
        let events = await sink.snapshot()
        let final = events.compactMap { event -> String? in
            if case .turnCompleted(_, let final) = event { return final }
            return nil
        }.first

        XCTAssertEqual(final, "1 2 3 4 5",
                       "streamed deltas that share one assistant item id must accumulate into that item's full text")
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

    func test_adapterIgnoresRoleUserMessageItemsSoPromptsDoNotBecomeAssistantReplies() async throws {
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
            prompt: "now count to 15"
        )) { event in
            Task { await sink.record(event) }
        }

        client.notificationHandler?("item/started", [
            "threadId": "codex-thread-1",
            "turnId": "turn-role-user-1",
            "item": [
                "id": "user-message-1",
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": "now count to 15"]]
            ]
        ])
        client.notificationHandler?("item/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-role-user-1",
            "item": [
                "id": "user-message-1",
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": "now count to 15"]]
            ]
        ])
        client.notificationHandler?("item/started", [
            "threadId": "codex-thread-1",
            "turnId": "turn-role-user-1",
            "item": [
                "id": "assistant-message-1",
                "type": "message",
                "role": "assistant",
                "content": []
            ]
        ])
        client.notificationHandler?("item/agentMessage/delta", [
            "threadId": "codex-thread-1",
            "turnId": "turn-role-user-1",
            "itemId": "assistant-message-1",
            "delta": "1 2 3 4 5 6 7 8 9 10 11 12 13 14 15"
        ])
        client.notificationHandler?("turn/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-role-user-1"
        ])

        try await Task.sleep(nanoseconds: 50_000_000)
        let events = await sink.snapshot()
        XCTAssertFalse(events.contains { if case .itemStarted(let item) = $0 { return item.id == "user-message-1" } else { return false } },
                       "Codex app-server `type=message role=user` items are the submitted prompt; rendering them as assistant messages makes the UI look like the agent failed to answer")
        XCTAssertFalse(events.contains { if case .itemDelta(let itemId, let body, _, _) = $0 { return itemId == "user-message-1" || body == "now count to 15" } else { return false } },
                       "user prompts must not contaminate the accumulated final assistant response")
        XCTAssertTrue(events.contains { if case .turnCompleted(let turnId, let final) = $0 { return turnId == "turn-role-user-1" && final == "1 2 3 4 5 6 7 8 9 10 11 12 13 14 15" } else { return false } },
                      "the next user message must still produce a clean assistant final response")
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

        let events = try await adapter.readThread(threadId: threadId)
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
                "last": ["inputTokens": 120, "outputTokens": 6, "totalTokens": 126, "costUSD": 0.0042],
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
        XCTAssertEqual(usage.resolvedSemantics, .cumulative,
                       "app-server token usage updates replace the prior turn snapshot")
        XCTAssertEqual(usage.reportedCostMicros, 4_200,
                       "Codex monetary receipts must be preserved when the app-server provides one")
        XCTAssertEqual(usage.contextWindow, 258400)
        XCTAssertEqual(usage.contextTokens, 126,
                       "context occupancy must come from the per-turn last bucket, not session-cumulative total")
        XCTAssertEqual(usage.compactsAutomatically, true,
                       "Codex app-server context windows auto-compact; RemoteCode must preserve that capability in the same context status surface as T3Code")
        let events = try await waitForEvents(in: sink) { events in
            events.contains { if case .contextCompaction(let summary) = $0 { return summary == "Context compacted" } else { return false } }
                && events.contains { if case .contextCompaction(let summary) = $0 { return summary == "Context compaction" } else { return false } }
                && events.contains { if case .itemStarted(let item) = $0 { return item.type == .contextCompaction && item.summary == "Context compacted" } else { return false } }
                && events.contains { if case .itemStarted(let item) = $0 { return item.id == "native-context-compaction" && item.type == .contextCompaction && item.summary == "Context compaction" } else { return false } }
        }
        XCTAssertTrue(events.contains { if case .contextCompaction(let summary) = $0 { return summary == "Context compacted" } else { return false } })
        XCTAssertTrue(events.contains { if case .contextCompaction(let summary) = $0 { return summary == "Context compaction" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.type == .contextCompaction && item.summary == "Context compacted" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.id == "native-context-compaction" && item.type == .contextCompaction && item.summary == "Context compaction" } else { return false } })
    }

    /// Live Codex rows can expose a multi-million `total.totalTokens` while `last`
    /// is the true per-turn occupancy. contextTokens must never take the cumulative
    /// total (that is what produced Claude-style 999% gauges when misread).
    func test_adapterTokenUsage_contextTokensFromLast_notHugeCumulativeTotal() async throws {
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
            cwd: "/tmp/remotecode-app-server-adapter-context-tokens",
            prompt: "telemetry"
        )) { event in
            Task { await sink.record(event) }
        }

        client.notificationHandler?("thread/tokenUsage/updated", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-ctx",
            "tokenUsage": [
                "total": ["inputTokens": 66_000_000, "outputTokens": 78_449, "totalTokens": 66_078_449],
                "last": ["inputTokens": 167_400, "outputTokens": 151, "totalTokens": 167_551],
                "modelContextWindow": 258_400
            ]
        ])

        let usage = try await waitForTokenUsage(in: sink)
        XCTAssertEqual(usage.totalTokens, 167_551,
                       "existing last-preferred totalTokens contract must not change")
        XCTAssertEqual(usage.contextTokens, 167_551)
        XCTAssertNotEqual(usage.contextTokens, 66_078_449)
        XCTAssertEqual(usage.contextWindow, 258_400)
    }

    func test_adapterTokenUsage_totalOnly_leavesContextTokensNil() async throws {
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
            cwd: "/tmp/remotecode-app-server-adapter-total-only",
            prompt: "telemetry"
        )) { event in
            Task { await sink.record(event) }
        }

        client.notificationHandler?("thread/tokenUsage/updated", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-total-only",
            "tokenUsage": [
                "total": ["inputTokens": 66_000_000, "outputTokens": 78_449, "totalTokens": 66_078_449],
                "modelContextWindow": 258_400
            ]
        ])

        let usage = try await waitForTokenUsage(in: sink)
        XCTAssertEqual(usage.totalTokens, 66_078_449,
                       "without last, totalTokens still falls back to total for billing")
        XCTAssertNil(usage.contextTokens,
                     "cumulative total-only payload must not claim context occupancy")
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
                "primary": [
                    "usedPercent": 5,
                    "windowDurationMins": 10_080,
                    "resetsAt": "2026-05-23T12:00:00Z"
                ]
            ],
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": [
                        "usedPercent": 33,
                        "windowDurationMins": 10_080,
                        "resetsAt": "2026-05-23T12:00:00Z"
                    ]
                ],
                "other": [
                    "primary": [
                        "usedPercent": 91,
                        "windowDurationMins": 10_080,
                        "resetsAt": "2026-05-23T12:00:00Z"
                    ]
                ]
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
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "Goal updated" && item.output?.contains("Objective: finish audit") == true && item.output?.contains("Tokens: 42 / 100") == true } else { return false } },
                      "generated app-server goal updates must be readable in the Agent App, not only preserved as raw runtime JSON")
        XCTAssertTrue(events.contains { if case .itemDelta(_, _, let output, let summary) = $0 { return summary == "Turn diff updated" && output == "diff --git a/file b/file" } else { return false } },
                      "turn/diff/updated should surface the aggregated provider diff as file-change activity")
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "Codex warning" && item.output == "config warning" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "Codex guardian warning" && item.output == "risky command" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "bad config" && item.output == "fix config" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "old flag" && item.output == "use new flag" } else { return false } })
        XCTAssertTrue(events.contains { if case .itemStarted(let item) = $0 { return item.summary == "Codex rate limit" && item.output?.contains("hard") == true && item.output?.contains("primary") == true } else { return false } },
                      "rate-limit notifications should become visible diagnostics before a long run appears frozen without marking a successful turn as failed")
        XCTAssertTrue(events.contains { if case .accountUsage(let usage) = $0 { return usage.provider == .codex && usage.weeklyUsedPercent == 33 && usage.weeklyWindowDurationMinutes == 10_080 } else { return false } },
                      "Codex account/rateLimits/updated must feed Token Saver weekly account usage instead of showing fake 100% remaining")
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

    func test_secondGoalUpdateReplacesGoalDetailInsteadOfAppending() async throws {
        // WHY: the app-server re-sends thread/goal/updated with the FULL goal
        // state on every progress tick. The single goal transcript row must
        // always show ONLY the latest state; append semantics glue stale and
        // new snapshots together ("...Tokens: 42 / 100Objective: ...") and
        // garble the row a little more on every update.
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let log = OrderedEventLog()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "/goal finish audit"
        )) { log.record($0) }

        func goalPayload(tokensUsed: Int) -> [String: Any] {
            [
                "threadId": "codex-thread-1",
                "goal": [
                    "objective": "finish audit",
                    "status": "active",
                    "tokensUsed": tokensUsed,
                    "tokenBudget": 100
                ]
            ]
        }
        client.notificationHandler?("thread/goal/updated", goalPayload(tokensUsed: 42))
        client.notificationHandler?("thread/goal/updated", goalPayload(tokensUsed: 58))

        var timeline = AssistantTimelineState()
        for event in log.assistantEvents { timeline.apply(event) }
        let goalItems = timeline.turns.flatMap(\.items).filter { $0.summary == "Goal updated" }
        XCTAssertEqual(goalItems.count, 1, "repeated goal updates within one turn must merge into a single goal row")
        XCTAssertEqual(goalItems.first?.output,
                       "Objective: finish audit\nStatus: active\nTokens: 58 / 100",
                       "the goal row must show ONLY the latest goal state; appending renders stale+new snapshots concatenated")
    }

    func test_goalEventsWithNoActiveTurnAttachToLatestTurnWithTurnScopedItemIds() async throws {
        // WHY: goal notifications can land when no turn is active (e.g.
        // thread/goal/cleared right after turn/completed). With turnId "" they
        // merge into the FIRST phantom ""-id turn the reducer ever created —
        // several turns up the transcript — and a single global goal item id
        // shared across turns breaks the reducer's unique-item-id invariant.
        let client = MockCodexAppServerClient(autoComplete: false)
        let adapter = CodexAppServerAdapter { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        }
        let log = OrderedEventLog()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .codex,
            model: "gpt-5.5",
            cwd: "/tmp/remotecode-app-server-adapter",
            prompt: "/goal finish audit"
        )) { log.record($0) }

        func goalItems(summary: String) -> [AssistantItem] {
            log.assistantEvents.compactMap {
                if case .itemStarted(let item) = $0, item.summary == summary { return item }
                return nil
            }
        }
        let goalPayload: [String: Any] = [
            "threadId": "codex-thread-1",
            "goal": ["objective": "finish audit", "status": "active"]
        ]

        client.notificationHandler?("thread/goal/updated", goalPayload)
        let inTurn = try XCTUnwrap(goalItems(summary: "Goal updated").first)
        XCTAssertEqual(inTurn.turnId, "turn-app-server-1")

        // Turn completes: activeTurnId is cleared but the session and its
        // notification handler stay registered.
        client.notificationHandler?("turn/completed", ["threadId": "codex-thread-1", "turnId": "turn-app-server-1"])
        client.notificationHandler?("thread/goal/updated", goalPayload)
        client.notificationHandler?("thread/goal/cleared", ["threadId": "codex-thread-1"])

        let betweenTurns = try XCTUnwrap(goalItems(summary: "Goal updated").last)
        XCTAssertEqual(betweenTurns.turnId, "turn-app-server-1",
                       "a goal update with no active turn must attach to the last completed turn, not a phantom \"\" turn")
        let cleared = try XCTUnwrap(goalItems(summary: "Goal cleared").first)
        XCTAssertEqual(cleared.turnId, "turn-app-server-1",
                       "goal cleared right after turn/completed must attach to that turn, not a phantom \"\" turn")

        // A later turn must produce a DIFFERENT goal item id: item ids are
        // unique across turns (invariant relied on by the reducer's
        // newest-first item lookup and SR1 translation eviction).
        client.notificationHandler?("turn/started", ["threadId": "codex-thread-1", "turnId": "turn-app-server-2"])
        client.notificationHandler?("thread/goal/updated", goalPayload)
        let secondTurnGoal = try XCTUnwrap(goalItems(summary: "Goal updated").last)
        XCTAssertEqual(secondTurnGoal.turnId, "turn-app-server-2")
        XCTAssertNotEqual(secondTurnGoal.id, inTurn.id,
                          "goal item ids must be turn-scoped so two turns never share one item id")
    }

    func test_itemCompletedWithDeclinedStatusMapsToCancelled() async throws {
        // WHY: openai/codex emits item/completed with status=declined when the user
        // denies a command/fileChange approval. Mapping only completed/failed/cancelled
        // left declined on the default .streaming path so items looked forever in-progress
        // (CODEX-APP-002). Terminal cancel is the correct denial signal.
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
            prompt: "will decline command"
        )) { event in
            Task { await sink.record(event) }
        }

        client.notificationHandler?("item/started", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "item": ["id": "cmd-declined-1", "type": "commandExecution", "command": "rm -rf /"]
        ])
        client.notificationHandler?("item/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "item": [
                "id": "cmd-declined-1",
                "type": "commandExecution",
                "command": "rm -rf /",
                "status": "declined"
            ]
        ])

        _ = try await waitForItemCompleted(in: sink, itemId: "cmd-declined-1")
        let events = await sink.snapshot()
        XCTAssertTrue(
            events.contains {
                if case .itemCompleted(let itemId, let state) = $0 {
                    return itemId == "cmd-declined-1" && state == .cancelled
                }
                return false
            },
            "item/completed with status=declined must emit finalState .cancelled, not remain streaming"
        )
    }

    func test_hookCompletedNestedRunStatusMapsToTerminalStates() async throws {
        // WHY: openai/codex HookCompletedNotification nests HookRunSummary under `run`
        // with HookRunStatus blocked/stopped (camelCase). Reading only flat/hook/summary
        // left live hooks without ids/status and itemState defaulted blocked/stopped to
        // .streaming so hook rows spun forever (CODEX-APP-003).
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
            prompt: "hooks"
        )) { event in
            Task { await sink.record(event) }
        }

        client.notificationHandler?("hook/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "run": [
                "id": "hook-run-blocked-1",
                "eventName": "PreToolUse",
                "handlerType": "command",
                "status": "blocked",
                "entries": [["kind": "stop", "text": "blocked by policy"]]
            ]
        ])
        client.notificationHandler?("hook/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "run": [
                "id": "hook-run-stopped-1",
                "eventName": "PostToolUse",
                "handlerType": "command",
                "status": "stopped"
            ]
        ])

        let events = try await waitForEvents(in: sink) { events in
            events.contains {
                if case .itemStarted(let item) = $0 {
                    return item.id == "hook-run-stopped-1" && item.state == .cancelled
                }
                return false
            }
        }
        XCTAssertTrue(
            events.contains {
                if case .itemStarted(let item) = $0 {
                    return item.id == "hook-run-blocked-1" && item.state == .failed
                }
                return false
            },
            "hook/completed nested run.status=blocked must be terminal .failed, not .streaming"
        )
        XCTAssertTrue(
            events.contains {
                if case .itemStarted(let item) = $0 {
                    return item.id == "hook-run-stopped-1" && item.state == .cancelled
                }
                return false
            },
            "hook/completed nested run.status=stopped must be terminal .cancelled, not .streaming"
        )
    }

    func test_autoApprovalReviewUsesReviewIdAndTerminalStatuses() async throws {
        // WHY: ItemGuardianApprovalReviewCompletedNotification carries reviewId +
        // GuardianApprovalReviewStatus (approved/denied/timedOut/aborted). Missing
        // reviewId forced random UUIDs; approved/timedOut/aborted fell through itemState
        // default to .streaming so review chips never settled (CODEX-APP-004).
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
            prompt: "guardian review"
        )) { event in
            Task { await sink.record(event) }
        }

        client.notificationHandler?("item/autoApprovalReview/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "reviewId": "review-stable-1",
            "targetItemId": "cmd-1",
            "review": [
                "status": "approved",
                "riskLevel": "low",
                "rationale": "safe"
            ]
        ])
        client.notificationHandler?("item/autoApprovalReview/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "reviewId": "review-timeout-1",
            "review": ["status": "timedOut"]
        ])
        client.notificationHandler?("item/autoApprovalReview/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-app-server-1",
            "reviewId": "review-aborted-1",
            "review": ["status": "aborted"]
        ])

        let events = try await waitForEvents(in: sink) { events in
            events.contains {
                if case .itemStarted(let item) = $0 {
                    return item.id == "review-aborted-1" && item.state == .cancelled
                }
                return false
            }
        }
        XCTAssertTrue(
            events.contains {
                if case .itemStarted(let item) = $0 {
                    return item.id == "review-stable-1"
                        && item.type == .review
                        && item.state == .completed
                }
                return false
            },
            "autoApprovalReview must use reviewId and map approved → .completed"
        )
        XCTAssertTrue(
            events.contains {
                if case .itemStarted(let item) = $0 {
                    return item.id == "review-timeout-1" && item.state == .failed
                }
                return false
            },
            "timedOut guardian review must be terminal .failed"
        )
        XCTAssertTrue(
            events.contains {
                if case .itemStarted(let item) = $0 {
                    return item.id == "review-aborted-1" && item.state == .cancelled
                }
                return false
            },
            "aborted guardian review must be terminal .cancelled"
        )
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

        _ = try await waitForItemCompleted(in: sink, itemId: "raw-web-1")
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

        let events = try await adapter.readThread(threadId: threadId)
        XCTAssertTrue(events.contains { if case .tokenUsage(let usage) = $0 { return usage.totalTokens == 12 && usage.contextWindow == 100 } else { return false } })
        XCTAssertTrue(events.contains { if case .contextCompaction(let summary) = $0 { return summary == "Snapshot compacted" } else { return false } })
    }

    /// Shell-detached foreground command_execution (e.g. `cmd > f 2>&1 &` + `PID=$!`)
    /// with idle thread status must stamp [[RC_AWAITING]] onto both turnCompleted
    /// and finished — host recovery keys on final-message text only.
    func test_shellDetachedCommandExecution_stampsAwaitingMarkerOnCompletedTurn() async throws {
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
            prompt: "fan out workers"
        )) { event in
            Task { await sink.record(event) }
        }

        let detachCmd = "grok --prompt-file /tmp/w2-c02.txt --output-format json > /tmp/w2-c02-result.json 2>&1 &\nPID_C02=$!\necho started"
        client.notificationHandler?("item/started", [
            "threadId": "codex-thread-1",
            "turnId": "turn-detach-1",
            "item": [
                "id": "cmd-detach-1",
                "type": "commandExecution",
                "command": detachCmd,
                "status": "inProgress"
            ]
        ])
        client.notificationHandler?("turn/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-detach-1",
            "finalMessage": "Workers launched; keeping polling active."
        ])

        let finish = try await waitForFinish(in: sink, timeout: 3)
        let marker = BackgroundAwaitContinuation.awaitingMarker
        XCTAssertEqual(finish.0, .completed)
        XCTAssertTrue(finish.1?.contains(marker) == true,
                      "finished.finalMessage must carry [[RC_AWAITING]]; got \(finish.1 ?? "nil")")
        let events = await sink.snapshot()
        let turnFinals = events.compactMap { event -> String? in
            if case .turnCompleted(_, let msg) = event { return msg }
            return nil
        }
        XCTAssertTrue(turnFinals.contains(where: { $0.contains(marker) }),
                      "turnCompleted finalMessage must also carry the marker; got \(turnFinals)")
        // Exactly once in the finished text.
        let finished = try XCTUnwrap(finish.1)
        XCTAssertEqual(finished.components(separatedBy: marker).count - 1, 1,
                       "marker must appear exactly once in finished finalMessage")
    }

    /// Non-detaching commands and failed turns must never be stamped. Deferred
    /// detach stamping is covered by
    /// `test_shellDetachedCommandExecution_deferredReleaseCarriesAwaitingMarker`.
    func test_nonDetachingAndFailedTurns_doNotStampAwaitingMarker() async throws {
        let marker = BackgroundAwaitContinuation.awaitingMarker

        // 1) Ordinary non-detaching command.
        do {
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
                prompt: "build"
            )) { event in
                Task { await sink.record(event) }
            }
            client.notificationHandler?("item/started", [
                "threadId": "codex-thread-1",
                "turnId": "turn-build-1",
                "item": [
                    "id": "cmd-build-1",
                    "type": "commandExecution",
                    "command": "swift build && echo ok",
                    "status": "inProgress"
                ]
            ])
            client.notificationHandler?("turn/completed", [
                "threadId": "codex-thread-1",
                "turnId": "turn-build-1",
                "finalMessage": "build ok"
            ])
            let finish = try await waitForFinish(in: sink, timeout: 3)
            XCTAssertEqual(finish.1, "build ok",
                           "non-detaching command must not stamp [[RC_AWAITING]]")
            XCTAssertFalse(finish.1?.contains(marker) == true)
        }

        // 2) turn/failed is never stamped (even with a detaching command item).
        do {
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
                prompt: "fail"
            )) { event in
                Task { await sink.record(event) }
            }
            client.notificationHandler?("item/started", [
                "threadId": "codex-thread-1",
                "turnId": "turn-fail-1",
                "item": [
                    "id": "cmd-fail",
                    "type": "commandExecution",
                    "command": "nohup sleep 99 &",
                    "status": "inProgress"
                ]
            ])
            client.notificationHandler?("turn/failed", [
                "threadId": "codex-thread-1",
                "turnId": "turn-fail-1",
                "error": ["message": "boom"]
            ])
            let finish = try await waitForFinish(in: sink, timeout: 3)
            XCTAssertEqual(finish.0, .failed)
            XCTAssertFalse(finish.1?.contains(marker) == true,
                           "turn/failed must never stamp [[RC_AWAITING]]")
        }
    }

    /// Detaching command_execution while thread status is ACTIVE arms PendingFinish
    /// and must STILL stamp [[RC_AWAITING]] onto the canonical final: deferral and
    /// detach evidence are orthogonal. Both `.turnCompleted` and the later idle
    /// `.finished` release must carry the marker (UI reads turnCompleted; nudge
    /// reads finished).
    func test_shellDetachedCommandExecution_deferredReleaseCarriesAwaitingMarker() async throws {
        let marker = BackgroundAwaitContinuation.awaitingMarker
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
            prompt: "deferred detach"
        )) { event in
            Task { await sink.record(event) }
        }
        client.notificationHandler?("thread/status/changed", [
            "threadId": "codex-thread-1",
            "status": ["type": "active", "activeFlags": ["runningCommand"]]
        ])
        client.notificationHandler?("item/started", [
            "threadId": "codex-thread-1",
            "turnId": "turn-deferred-detach",
            "item": [
                "id": "cmd-deferred",
                "type": "commandExecution",
                "command": "sleep 30 &\nPID=$!\necho started",
                "status": "inProgress"
            ]
        ])
        client.notificationHandler?("turn/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-deferred-detach",
            "finalMessage": "still working"
        ])
        try await Task.sleep(nanoseconds: 50_000_000)
        let premature = await sink.finish
        XCTAssertNil(premature,
                     "active thread status must defer finish (no immediate .finished)")
        let midEvents = await sink.snapshot()
        let midFinals = midEvents.compactMap { event -> String? in
            if case .turnCompleted(_, let msg) = event { return msg }
            return nil
        }
        XCTAssertTrue(midFinals.contains(where: { $0.contains(marker) && $0.contains("still working") }),
                      "deferred turnCompleted must carry [[RC_AWAITING]] on the canonical final; got \(midFinals)")
        // Release PendingFinish via idle thread status — same stamped final.
        client.notificationHandler?("thread/status/changed", [
            "threadId": "codex-thread-1",
            "status": ["type": "idle"]
        ])
        let finish = try await waitForFinish(in: sink, timeout: 3)
        XCTAssertEqual(finish.0, .completed)
        XCTAssertTrue(finish.1?.contains(marker) == true,
                      "deferred .finished release must carry [[RC_AWAITING]]; got \(finish.1 ?? "nil")")
        XCTAssertTrue(finish.1?.contains("still working") == true)
        let finished = try XCTUnwrap(finish.1)
        XCTAssertEqual(finished.components(separatedBy: marker).count - 1, 1,
                       "marker must appear exactly once on deferred finished finalMessage")
    }

    /// Cross-turn isolation: turn A detaches + defers; turn B completes without
    /// detaching before idle release. B must overwrite the single PendingFinish
    /// slot and the released `.finished` must carry B's unmarked final — never A's.
    func test_deferredDetachThenNonDetachTurn_finishedCarriesLaterUnmarkedFinal() async throws {
        let marker = BackgroundAwaitContinuation.awaitingMarker
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
            prompt: "cross-turn detach"
        )) { event in
            Task { await sink.record(event) }
        }

        // Turn A: detach + active thread → PendingFinish armed with stamped final.
        client.notificationHandler?("thread/status/changed", [
            "threadId": "codex-thread-1",
            "status": ["type": "active", "activeFlags": ["runningCommand"]]
        ])
        client.notificationHandler?("item/started", [
            "threadId": "codex-thread-1",
            "turnId": "turn-A",
            "item": [
                "id": "cmd-A",
                "type": "commandExecution",
                "command": "sleep 30 &\nPID=$!\necho started",
                "status": "inProgress"
            ]
        ])
        client.notificationHandler?("turn/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-A",
            "finalMessage": "turn-A-detached"
        ])
        try await Task.sleep(nanoseconds: 50_000_000)
        let prematureA = await sink.finish
        XCTAssertNil(prematureA, "turn A must defer finish while thread is active")
        let afterA = await sink.snapshot()
        let aFinals = afterA.compactMap { event -> String? in
            if case .turnCompleted(let turnId, let msg) = event, turnId == "turn-A" { return msg }
            return nil
        }
        XCTAssertTrue(aFinals.contains(where: { $0.contains(marker) && $0.contains("turn-A-detached") }),
                      "turn A turnCompleted must be marked; got \(aFinals)")

        // Turn B: starts (resets per-turn detach flag) and completes without detach.
        // Still active → overwrites the single PendingFinish slot with B's unmarked final.
        client.notificationHandler?("turn/started", [
            "threadId": "codex-thread-1",
            "turnId": "turn-B"
        ])
        client.notificationHandler?("item/started", [
            "threadId": "codex-thread-1",
            "turnId": "turn-B",
            "item": [
                "id": "cmd-B",
                "type": "commandExecution",
                "command": "echo only-foreground",
                "status": "inProgress"
            ]
        ])
        client.notificationHandler?("turn/completed", [
            "threadId": "codex-thread-1",
            "turnId": "turn-B",
            "finalMessage": "turn-B-clean"
        ])
        try await Task.sleep(nanoseconds: 50_000_000)
        let prematureB = await sink.finish
        XCTAssertNil(prematureB, "turn B must also defer while thread stays active")
        let afterB = await sink.snapshot()
        let bFinals = afterB.compactMap { event -> String? in
            if case .turnCompleted(let turnId, let msg) = event, turnId == "turn-B" { return msg }
            return nil
        }
        XCTAssertTrue(bFinals.contains(where: { $0 == "turn-B-clean" }),
                      "turn B turnCompleted must stay unmarked; got \(bFinals)")
        XCTAssertFalse(bFinals.contains(where: { $0.contains(marker) }),
                       "turn B must not inherit turn A's detach stamp")

        // Idle release: single-slot PendingFinish holds B only.
        client.notificationHandler?("thread/status/changed", [
            "threadId": "codex-thread-1",
            "status": ["type": "idle"]
        ])
        let finish = try await waitForFinish(in: sink, timeout: 3)
        XCTAssertEqual(finish.0, .completed)
        XCTAssertEqual(finish.1, "turn-B-clean",
                       "released .finished must carry B's unmarked final, never A's; got \(finish.1 ?? "nil")")
        XCTAssertFalse(finish.1?.contains(marker) == true)
        XCTAssertFalse(finish.1?.contains("turn-A-detached") == true)
    }
}

// Records assistant events synchronously in emission order (the adapter's emit
// path is synchronous). The actor-based EventSink records through unordered
// Tasks, which cannot back ordering-sensitive assertions such as
// "the LAST goal update wins".
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock(); defer { lock.unlock() }
        storage += 1
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

private final class OrderedEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AssistantEvent] = []

    func record(_ event: AgentRunEvent) {
        guard case .event(let assistantEvent) = event else { return }
        lock.lock()
        events.append(assistantEvent)
        lock.unlock()
    }

    var assistantEvents: [AssistantEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
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

private func waitForFinish(
    in sink: EventSink,
    timeout: TimeInterval
) async throws -> (AgentRunStatus, String?, String?) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let finish = await sink.finish { return finish }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw CodexAdapterTestWaitError.timedOut("provider finish")
}

private func deleteRealCodexThreads(_ threadIds: [String], binary: String) async -> [String] {
    guard !threadIds.isEmpty else { return [] }
    let client: CodexAppServerClient
    do {
        client = try CodexAppServerClient(
            binary: binary,
            arguments: ["app-server"],
            cwd: FileManager.default.temporaryDirectory.path
        )
        _ = try await client.initialize()
    } catch {
        return ["maintenance client: \(error)"]
    }
    defer { client.stop() }
    var failures: [String] = []
    for threadId in threadIds.reversed() {
        do {
            try await client.deleteThread(providerThreadId: threadId)
        } catch {
            failures.append("\(threadId): \(error)")
        }
    }
    return failures
}

private enum CodexAdapterTestWaitError: Error {
    case timedOut(String)
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
    throw CodexAdapterTestWaitError.timedOut("approval request")
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
    throw CodexAdapterTestWaitError.timedOut("user-input request")
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
    throw CodexAdapterTestWaitError.timedOut("proposed plan")
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
    throw CodexAdapterTestWaitError.timedOut("active plan")
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
    throw CodexAdapterTestWaitError.timedOut("runtime event \(method)")
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
    throw CodexAdapterTestWaitError.timedOut("token usage")
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
    throw CodexAdapterTestWaitError.timedOut("context compaction")
}

private func waitForEvents(in sink: EventSink, matching predicate: @escaping ([AssistantEvent]) -> Bool) async throws -> [AssistantEvent] {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        let events = await sink.snapshot()
        if predicate(events) {
            return events
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw CodexAdapterTestWaitError.timedOut("expected events")
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
    throw CodexAdapterTestWaitError.timedOut("item completion \(itemId)")
}

private enum MockOpenThreadBehavior: Sendable {
    case succeed
    case throwError(Error)
    /// Deterministic cancel path: await until the surrounding Task is cancelled.
    case hangUntilCancelled(onEnter: @Sendable () -> Void)
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
    let forkProtocolSupport: CodexForkProtocolSupport
    var readResponse: CodexAppServerClient.JSONObject = ["thread": ["id": "codex-thread-1", "turns": []]]
    let autoComplete: Bool
    let interruptDelayNanoseconds: UInt64
    let startTurnError: Error?
    let openThreadBehavior: MockOpenThreadBehavior
    let updateSettingsError: Error?
    private let lock = NSLock()
    private var _didStop = false
    private var _openedRequests: [AgentRunRequest] = []
    private var _startedTurns: [StartedTurn] = []
    private var _interruptedTurns: [InterruptedTurn] = []
    private var _forkedThreadIds: [String] = []
    private var _typedForkMarkers: [String] = []
    private var _providerChildren: [CodexAppServerThreadSummary] = []
    private var _deletedThreadIds: [String] = []
    private var _rolledBackTurns: [RolledBackTurn] = []
    private var _readCalls: [ReadCall] = []
    private var _updatedThreadSettings: [UpdatedThreadSettings] = []

    init(
        autoComplete: Bool = true,
        interruptDelayNanoseconds: UInt64 = 0,
        startTurnError: Error? = nil,
        openThreadError: Error? = nil,
        openThreadBehavior: MockOpenThreadBehavior? = nil,
        updateSettingsError: Error? = nil,
        supportsForkReconciliation: Bool = false
    ) {
        self.autoComplete = autoComplete
        self.interruptDelayNanoseconds = interruptDelayNanoseconds
        self.startTurnError = startTurnError
        if let openThreadBehavior {
            self.openThreadBehavior = openThreadBehavior
        } else if let openThreadError {
            self.openThreadBehavior = .throwError(openThreadError)
        } else {
            self.openThreadBehavior = .succeed
        }
        self.updateSettingsError = updateSettingsError
        self.forkProtocolSupport = supportsForkReconciliation
            ? CodexForkProtocolSupport(isSupported: true, reason: "test schema")
            : .unsupported
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

    var forkedThreadIds: [String] {
        lock.lock(); defer { lock.unlock() }
        return _forkedThreadIds
    }

    var typedForkMarkers: [String] {
        lock.lock(); defer { lock.unlock() }
        return _typedForkMarkers
    }

    var providerChildren: [CodexAppServerThreadSummary] {
        lock.lock(); defer { lock.unlock() }
        return _providerChildren
    }

    var deletedThreadIds: [String] {
        lock.lock(); defer { lock.unlock() }
        return _deletedThreadIds
    }

    func seedProviderChild(id: String, parentId: String, marker: String, createdAt: Int64) {
        lock.lock(); defer { lock.unlock() }
        _providerChildren.append(CodexAppServerThreadSummary(
            id: id,
            forkedFromId: parentId,
            threadSource: marker,
            createdAt: createdAt
        ))
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
        terminationHandler?(CodexAppServerError.processExited(stderrTail: ""))
    }

    func initialize(clientName: String, clientTitle: String, clientVersion: String) async throws -> CodexAppServerInitializeResult {
        CodexAppServerInitializeResult(userAgent: "mock", codexHome: nil, platformFamily: nil, platformOs: nil)
    }

    func openThread(for request: AgentRunRequest) async throws -> CodexAppServerThreadOpenResult {
        recordOpened(request)
        switch openThreadBehavior {
        case .succeed:
            break
        case .throwError(let error):
            throw error
        case .hangUntilCancelled(let onEnter):
            onEnter()
            // Cooperative cancel: Task.sleep throws CancellationError when the
            // parent Task is cancelled — no wall-clock timeout dependency.
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CancellationError()
        }
        let providerThreadId = request.providerThreadId?.isEmpty == false ? request.providerThreadId! : "codex-thread-1"
        return CodexAppServerThreadOpenResult(providerThreadId: providerThreadId, response: ["id": providerThreadId])
    }

    func startTurn(providerThreadId: String, for request: AgentRunRequest) async throws -> CodexAppServerClient.JSONObject {
        recordStarted(StartedTurn(providerThreadId: providerThreadId, request: request))
        if let startTurnError { throw startTurnError }
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
        if interruptDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: interruptDelayNanoseconds)
        }
        recordInterrupted(InterruptedTurn(providerThreadId: providerThreadId, turnId: turnId))
    }

    func readThread(providerThreadId: String, includeTurns: Bool) async throws -> CodexAppServerClient.JSONObject {
        recordRead(ReadCall(providerThreadId: providerThreadId, includeTurns: includeTurns))
        return readResponse
    }

    func forkThread(providerThreadId: String, lastTurnId: String?) async throws -> String {
        withLock {
            _forkedThreadIds.append(providerThreadId)
            return "codex-child"
        }
    }

    func forkThread(
        providerThreadId: String,
        lastTurnId: String?,
        threadSource: String
    ) async throws -> CodexAppServerThreadSummary {
        withLock {
            _forkedThreadIds.append(providerThreadId)
            _typedForkMarkers.append(threadSource)
            let child = CodexAppServerThreadSummary(
                id: _providerChildren.isEmpty ? "codex-child" : "codex-child-\(_providerChildren.count + 1)",
                forkedFromId: providerThreadId,
                threadSource: threadSource,
                createdAt: Int64(_providerChildren.count + 1)
            )
            _providerChildren.append(child)
            return child
        }
    }

    func listThreads(cursor: String?, archived: Bool) async throws -> CodexAppServerThreadPage {
        withLock {
            guard !archived else {
                return CodexAppServerThreadPage(threads: [], nextCursor: nil)
            }
            let offset = cursor.flatMap(Int.init) ?? 0
            guard offset < _providerChildren.count else {
                return CodexAppServerThreadPage(threads: [], nextCursor: nil)
            }
            let next = offset + 1 < _providerChildren.count ? String(offset + 1) : nil
            return CodexAppServerThreadPage(threads: [_providerChildren[offset]], nextCursor: next)
        }
    }

    func deleteThread(providerThreadId: String) async throws {
        withLock {
            _deletedThreadIds.append(providerThreadId)
            _providerChildren.removeAll { $0.id == providerThreadId }
        }
    }

    func rollbackThread(providerThreadId: String, numTurns: Int) async throws -> CodexAppServerClient.JSONObject {
        recordRolledBack(RolledBackTurn(providerThreadId: providerThreadId, numTurns: numTurns))
        return ["thread": ["id": providerThreadId, "turns": []]]
    }

    func updateThreadSettings(providerThreadId: String, permissionMode: AgentPermissionMode) async throws {
        if let updateSettingsError { throw updateSettingsError }
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

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

private func makeCodexForkSchemaProjection() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("remotecode-codex-fork-schema-\(UUID().uuidString)", isDirectory: true)
    let v2 = root.appendingPathComponent("v2", isDirectory: true)
    try FileManager.default.createDirectory(at: v2, withIntermediateDirectories: true)

    let clientRequest: [String: Any] = [
        "oneOf": ["thread/fork", "thread/list", "thread/delete"].map { method in
            ["properties": ["method": ["enum": [method]]]]
        }
    ]
    let threadSource: [String: Any] = ["anyOf": [
        ["$ref": "#/definitions/ThreadSource"],
        ["type": "null"]
    ]]
    let threadProperties: [String: Any] = [
        "id": ["type": "string"],
        "forkedFromId": ["type": ["string", "null"]],
        "threadSource": threadSource,
        "createdAt": ["type": "integer"]
    ]
    let threadDefinitions: [String: Any] = [
        "Thread": [
            "required": ["id", "createdAt"],
            "properties": threadProperties
        ],
        "ThreadSource": ["type": "string"]
    ]
    let documents: [(String, [String: Any])] = [
        ("../ClientRequest.json", clientRequest),
        ("ThreadForkParams.json", [
            "required": ["threadId"],
            "properties": [
                "threadId": ["type": "string"],
                "threadSource": threadSource
            ],
            "definitions": ["ThreadSource": ["type": "string"]]
        ]),
        ("ThreadForkResponse.json", [
            "required": ["thread"],
            "properties": ["thread": ["$ref": "#/definitions/Thread"]],
            "definitions": threadDefinitions
        ]),
        ("ThreadListParams.json", [
            "properties": [
                "cursor": ["type": ["string", "null"]],
                "archived": ["type": ["boolean", "null"]]
            ]
        ]),
        ("ThreadListResponse.json", [
            "required": ["data"],
            "properties": [
                "data": ["type": "array", "items": ["$ref": "#/definitions/Thread"]],
                "nextCursor": ["type": ["string", "null"]]
            ],
            "definitions": threadDefinitions
        ]),
        ("ThreadDeleteParams.json", [
            "required": ["threadId"],
            "properties": ["threadId": ["type": "string"]]
        ]),
        ("ThreadDeleteResponse.json", ["type": "object"])
    ]

    for (relativePath, document) in documents {
        let url = v2.appendingPathComponent(relativePath).standardizedFileURL
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try data.write(to: url)
    }
    return root
}
