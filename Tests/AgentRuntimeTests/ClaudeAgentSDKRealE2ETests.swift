import AppKit
import Foundation
import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// Authenticated Claude gates for Agent App contracts that cannot be proved by
/// fake SDK fixtures alone. Opt in with RC_REAL_CLAUDE_AGENT_APP_GATE=1.
final class ClaudeAgentSDKRealE2ETests: ProviderProcessTestCase {
    private let gateEnvironmentKey = "RC_REAL_CLAUDE_AGENT_APP_GATE"

    func test_realClaudeApprovalPreservesBashArguments() async throws {
        let claude = try requireRealGate()
        let cwd = try makeTemporaryDirectory(prefix: "claude-approval")
        defer { try? FileManager.default.removeItem(at: cwd) }
        let output = cwd.appendingPathComponent("approval-proof.txt")
        let nonce = "AG007-\(UUID().uuidString.prefix(8))"
        let threadId = AgentThreadID()
        let adapter = ClaudeAgentSDKBridgeAdapter(binaryNameOverride: claude)
        let box = ClaudeRealEventBox()
        defer {
            adapter.stopAll()
            _ = try? Self.deleteRealSessions([threadId.value.uuidString, box.providerThreadId].compactMap { $0 })
        }

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-sonnet-4-6",
            cwd: cwd.path,
            prompt: "Use the Bash tool exactly once to run this exact command, then reply only APPROVAL_OK: printf '%s' '\(nonce)' > '\(output.path)'",
            permissionMode: .supervised,
            providerBinary: claude
        )) { event in
            box.append(event)
            if case .event(.requestOpened(let pending)) = event {
                box.recordApprovalRequest(pending)
                Task {
                    do {
                        try await adapter.respondToRequest(
                            threadId: threadId,
                            requestId: pending.id,
                            response: .approve
                        )
                    } catch {
                        box.appendCallbackError(error)
                    }
                }
            }
        }

        try await box.waitFinished(timeout: 120)
        let finished = try XCTUnwrap(box.finished)
        XCTAssertEqual(finished.status, .completed, box.failureSummary)
        XCTAssertGreaterThanOrEqual(box.approvalRequestCount, 1,
                                    "the real supervised Bash call must cross the approval callback")
        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            nonce,
            "approved Bash must retain its exact command/path/content through updatedInput"
        )

        adapter.stopAll()
        XCTAssertTrue(try Self.deleteRealSessions([threadId.value.uuidString, finished.providerThreadId].compactMap { $0 }).isEmpty)
    }

    func test_realClaudeAskUserQuestionRoundTrip() async throws {
        let claude = try requireRealGate()
        let cwd = try makeTemporaryDirectory(prefix: "claude-question")
        defer { try? FileManager.default.removeItem(at: cwd) }
        let threadId = AgentThreadID()
        let adapter = ClaudeAgentSDKBridgeAdapter(binaryNameOverride: claude)
        let box = ClaudeRealEventBox()
        let question = "Which gate token should I use?"
        defer {
            adapter.stopAll()
            _ = try? Self.deleteRealSessions([threadId.value.uuidString, box.providerThreadId].compactMap { $0 })
        }

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-sonnet-4-6",
            cwd: cwd.path,
            prompt: "Call AskUserQuestion now. Ask exactly '\(question)' with choices ALPHA and BETA. After the answer, reply only SELECTED_<answer>.",
            permissionMode: .fullAccess,
            providerBinary: claude
        )) { event in
            box.append(event)
            if case .event(.userInputRequested(let request)) = event {
                box.recordUserInputRequest(request)
                let answerJSON = #"{"Which gate token should I use?":"ALPHA"}"#
                do {
                    try adapter.respondToUserInput(
                        threadId: threadId,
                        requestId: request.id,
                        text: answerJSON
                    )
                } catch {
                    box.appendCallbackError(error)
                }
            }
        }

        try await box.waitFinished(timeout: 120)
        let finished = try XCTUnwrap(box.finished)
        XCTAssertEqual(finished.status, .completed, box.failureSummary)
        XCTAssertEqual(box.userInputRequestCount, 1,
                       "real AskUserQuestion must surface one actionable structured request")
        XCTAssertTrue(box.finalText.uppercased().contains("SELECTED_ALPHA"), box.failureSummary)

        adapter.stopAll()
        XCTAssertTrue(try Self.deleteRealSessions([threadId.value.uuidString, finished.providerThreadId].compactMap { $0 }).isEmpty)
    }

    func test_realClaudePlanProducesArtifactAndResumesImplementation() async throws {
        let claude = try requireRealGate()
        let cwd = try makeTemporaryDirectory(prefix: "claude-plan")
        defer { try? FileManager.default.removeItem(at: cwd) }
        let output = cwd.appendingPathComponent("plan-proof.txt")
        let nonce = "AG021-\(UUID().uuidString.prefix(8))"
        let threadId = AgentThreadID()
        let adapter = ClaudeAgentSDKBridgeAdapter(binaryNameOverride: claude)
        let planBox = ClaudeRealEventBox()
        defer {
            adapter.stopAll()
            _ = try? Self.deleteRealSessions([threadId.value.uuidString, planBox.providerThreadId].compactMap { $0 })
        }

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-sonnet-4-6",
            cwd: cwd.path,
            prompt: "Create a concise plan to write exactly \(nonce) to \(output.path). Do not modify files. Use ExitPlanMode when the plan is ready.",
            permissionMode: .supervised,
            interactionMode: .plan,
            providerBinary: claude
        )) { event in
            planBox.append(event)
            if case .event(.requestOpened(let pending)) = event {
                planBox.recordApprovalRequest(pending)
                Task {
                    do {
                        try await adapter.respondToRequest(
                            threadId: threadId,
                            requestId: pending.id,
                            response: pending.title == "ExitPlanMode" ? .approve : .decline(nil)
                        )
                    } catch {
                        planBox.appendCallbackError(error)
                    }
                }
            }
        }

        try await planBox.waitFinished(timeout: 120)
        let planned = try XCTUnwrap(planBox.finished)
        XCTAssertEqual(planned.status, .completed,
                       "\(planBox.failureSummary); \(planBox.debugSummary); result=\(planBox.resultRuntimePayloads)")
        let plan = try XCTUnwrap(planBox.proposedPlan,
                                 "real ExitPlanMode output must produce a reviewable proposedPlan event; \(planBox.debugSummary); runtime=\(planBox.planRuntimePayloads)")
        XCTAssertFalse(plan.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "Plan mode must not execute the workspace mutation before implementation")
        let providerThreadId = try XCTUnwrap(planned.providerThreadId)

        let implementationBox = ClaudeRealEventBox()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-sonnet-4-6",
            cwd: cwd.path,
            prompt: AgentPlanImplementationPrompt.make(markdown: plan.markdown),
            providerThreadId: providerThreadId,
            permissionMode: .supervised,
            interactionMode: .default,
            providerBinary: claude
        )) { event in
            implementationBox.append(event)
            if case .event(.requestOpened(let pending)) = event {
                Task {
                    do {
                        try await adapter.respondToRequest(
                            threadId: threadId,
                            requestId: pending.id,
                            response: .approve
                        )
                    } catch {
                        implementationBox.appendCallbackError(error)
                    }
                }
            }
        }

        try await implementationBox.waitFinished(timeout: 120)
        let implemented = try XCTUnwrap(implementationBox.finished)
        XCTAssertEqual(implemented.status, .completed, implementationBox.failureSummary)
        XCTAssertEqual(implemented.providerThreadId, providerThreadId)
        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            nonce,
            "approved plan implementation must resume the same provider session and perform the planned change"
        )

        adapter.stopAll()
        XCTAssertTrue(try Self.deleteRealSessions([threadId.value.uuidString, providerThreadId]).isEmpty)
    }

    func test_realClaudeRelaunchContinueKeepsContextWithoutSyntheticUserMessage() async throws {
        let claude = try requireRealGate()
        let cwd = try makeTemporaryDirectory(prefix: "claude-continue")
        let appSupport = try makeTemporaryDirectory(prefix: "claude-continue-db")
        defer {
            try? FileManager.default.removeItem(at: cwd)
            try? FileManager.default.removeItem(at: appSupport)
        }
        let nonce = "AG015-\(UUID().uuidString.prefix(8))"
        let threadId = AgentThreadID()
        let parentAdapter = ClaudeAgentSDKBridgeAdapter(binaryNameOverride: claude)
        let parentBox = ClaudeRealEventBox()
        defer {
            parentAdapter.stopAll()
            _ = try? Self.deleteRealSessions([threadId.value.uuidString, parentBox.providerThreadId].compactMap { $0 })
        }

        _ = try await parentAdapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-sonnet-4-6",
            cwd: cwd.path,
            prompt: "For this conversation only, the test nonce is \(nonce). Reply only CONTEXT_STORED.",
            permissionMode: .fullAccess,
            providerBinary: claude
        )) { parentBox.append($0) }
        try await parentBox.waitFinished(timeout: 120)
        let parentFinished = try XCTUnwrap(parentBox.finished)
        XCTAssertEqual(parentFinished.status, .completed, parentBox.failureSummary)
        let providerThreadId = try XCTUnwrap(parentFinished.providerThreadId)
        parentAdapter.stopAll()

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport.path).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let thread = AgentThread(
            id: threadId,
            title: "real continue",
            provider: .claude,
            model: "claude-sonnet-4-6",
            providerThreadId: providerThreadId,
            status: .interrupted,
            permissionMode: .fullAccess
        )
        try threadRepo.upsert(thread)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: threadId,
            provider: .claude,
            status: .interrupted,
            resumeCursor: providerThreadId,
            cwd: cwd.path,
            model: "claude-sonnet-4-6",
            runtimeMode: .fullAccess,
            runtimePayloadJSON: #"{"interactionMode":"default"}"#
        ))

        let relaunchedAdapter = ClaudeAgentSDKBridgeAdapter(binaryNameOverride: claude)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providerAdapters: [.claude: relaunchedAdapter]
        )
        defer { relaunchedAdapter.stopAll() }
        let continueInstruction = "Continue the interrupted turn from the last saved context. Reply only with the test nonce."
        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "ignored-current-model",
            cwd: cwd.path,
            prompt: continueInstruction,
            providerThreadId: nil,
            permissionMode: .supervised,
            interactionMode: .plan,
            providerBinary: claude
        ), recordUserMessage: false)

        try await waitForRun(runId, coordinator: coordinator, timeout: 120)
        XCTAssertEqual(try coordinator.runStatus(runId), .completed)
        let messages = try messageRepo.list(threadId: threadId)
        XCTAssertTrue(messages.filter { $0.role == .user }.isEmpty,
                      "relaunch Continue must not persist a synthetic or empty user message")
        XCTAssertTrue(
            messages.filter { $0.role == .assistant }.contains { $0.content.uppercased().contains(nonce.uppercased()) },
            "real resumed Claude context must retain the nonce from before relaunch; messages=\(messages.map(\.content))"
        )

        relaunchedAdapter.stopAll()
        XCTAssertTrue(try Self.deleteRealSessions([threadId.value.uuidString, providerThreadId]).isEmpty)
    }

    func test_realClaudeStructuredImageAttachmentIsVisible() async throws {
        let claude = try requireRealGate()
        let cwd = try makeTemporaryDirectory(prefix: "claude-attachment")
        defer { try? FileManager.default.removeItem(at: cwd) }
        let image = cwd.appendingPathComponent("solid-red.png")
        try Self.writeSolidRedPNG(to: image)
        let threadId = AgentThreadID()
        let adapter = ClaudeAgentSDKBridgeAdapter(binaryNameOverride: claude)
        let box = ClaudeRealEventBox()
        defer {
            adapter.stopAll()
            _ = try? Self.deleteRealSessions([threadId.value.uuidString, box.providerThreadId].compactMap { $0 })
        }

        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-sonnet-4-6",
            cwd: cwd.path,
            prompt: "Inspect the attached image. Reply with only its dominant color in uppercase.",
            attachments: [AgentAttachment(
                path: image.path,
                displayName: image.lastPathComponent,
                kind: .image,
                mimeType: "image/png"
            )],
            permissionMode: .fullAccess,
            providerBinary: claude
        )) { box.append($0) }

        try await box.waitFinished(timeout: 120)
        let finished = try XCTUnwrap(box.finished)
        XCTAssertEqual(finished.status, .completed, box.failureSummary)
        XCTAssertTrue(box.finalText.uppercased().contains("RED"), box.failureSummary)

        adapter.stopAll()
        XCTAssertTrue(try Self.deleteRealSessions([threadId.value.uuidString, finished.providerThreadId].compactMap { $0 }).isEmpty)
    }

    private func requireRealGate() throws -> String {
        guard ProcessInfo.processInfo.environment[gateEnvironmentKey] == "1" else {
            throw XCTSkip("set \(gateEnvironmentKey)=1 for authenticated Claude Agent App gates")
        }
        guard let claude = ProcessLocator.resolve("claude") else {
            throw XCTSkip("claude binary not on PATH")
        }
        guard Self.isClaudeAuthenticated(binary: claude) else {
            throw XCTSkip("claude is installed but not authenticated")
        }
        return claude
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitForRun(
        _ runId: AgentRunID,
        coordinator: AgentRunCoordinator,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let status = try coordinator.runStatus(runId),
               status == .completed || status == .failed || status == .cancelled || status == .interrupted {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(
            domain: "ClaudeAgentSDKRealE2ETests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for run \(runId.value.uuidString)"]
        )
    }

    private static func isClaudeAuthenticated(binary: String) -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["auth", "status", "--json"]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return object["loggedIn"] as? Bool == true
        } catch {
            return false
        }
    }

    @discardableResult
    private static func deleteRealSessions(_ ids: [String]) throws -> [String] {
        let unique = Array(Set(ids.filter { !$0.isEmpty })).sorted()
        guard !unique.isEmpty else { return [] }
        guard let node = ProcessLocator.resolve("node") else { return unique }
        let sdkRoot = try sdkRuntimeRoot()
        let script = """
        import { deleteSession, getSessionInfo } from '@anthropic-ai/claude-agent-sdk';
        const ids = process.argv.slice(1);
        for (const id of ids) { try { await deleteSession(id); } catch {} }
        const remaining = [];
        for (const id of ids) { if (await getSessionInfo(id)) remaining.push(id); }
        process.stdout.write(JSON.stringify(remaining));
        """
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["--input-type=module", "-e", script] + unique
        process.currentDirectoryURL = sdkRoot
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "ClaudeAgentSDKRealE2ETests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: errorData, as: UTF8.self)]
            )
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String]) ?? unique
    }

    private static func sdkRuntimeRoot() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_CACHE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("RemoteCode", isDirectory: true)
            .appendingPathComponent("AgentRuntime", isDirectory: true)
            .appendingPathComponent("ClaudeAgentSDKBridge", isDirectory: true)
    }

    private static func writeSolidRedPNG(to url: URL) throws {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 64,
            pixelsHigh: 64,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 64 * 4,
            bitsPerPixel: 32
        ), let bytes = bitmap.bitmapData else {
            throw NSError(domain: "ClaudeAgentSDKRealE2ETests", code: 2)
        }
        for offset in stride(from: 0, to: 64 * 64 * 4, by: 4) {
            bytes[offset] = 255
            bytes[offset + 1] = 0
            bytes[offset + 2] = 0
            bytes[offset + 3] = 255
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ClaudeAgentSDKRealE2ETests", code: 3)
        }
        try data.write(to: url, options: .atomic)
    }
}

private final class ClaudeRealEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentRunEvent] = []
    private var callbackErrors: [String] = []
    private var approvals: [AssistantPendingRequest] = []
    private var userInputs: [AssistantUserInputRequest] = []
    private var text = ""
    private var terminal: (status: AgentRunStatus, finalMessage: String?, providerThreadId: String?)?

    func append(_ event: AgentRunEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
        switch event {
        case .event(.itemDelta(_, let body, _, _)):
            if let body { text += body }
        case .error(let message):
            callbackErrors.append(message)
        case .finished(let status, let finalMessage, let providerThreadId):
            terminal = (status, finalMessage, providerThreadId)
        default:
            break
        }
    }

    func appendCallbackError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        callbackErrors.append(String(describing: error))
    }

    func recordApprovalRequest(_ request: AssistantPendingRequest) {
        lock.lock(); defer { lock.unlock() }
        approvals.append(request)
    }

    func recordUserInputRequest(_ request: AssistantUserInputRequest) {
        lock.lock(); defer { lock.unlock() }
        userInputs.append(request)
    }

    var finished: (status: AgentRunStatus, finalMessage: String?, providerThreadId: String?)? {
        lock.lock(); defer { lock.unlock() }
        return terminal
    }

    var providerThreadId: String? { finished?.providerThreadId }

    var approvalRequestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return approvals.count
    }

    var userInputRequestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return userInputs.count
    }

    var proposedPlan: AssistantProposedPlan? {
        lock.lock(); defer { lock.unlock() }
        return events.compactMap { event in
            if case .event(.proposedPlan(let plan)) = event { return plan }
            return nil
        }.last
    }

    var finalText: String {
        lock.lock(); defer { lock.unlock() }
        return terminal?.finalMessage ?? text
    }

    var failureSummary: String {
        lock.lock(); defer { lock.unlock() }
        return "errors=\(callbackErrors) final=\(terminal?.finalMessage ?? text)"
    }

    var debugSummary: String {
        lock.lock(); defer { lock.unlock() }
        return events.map { event in
            switch event {
            case .event(let assistantEvent):
                return assistantEvent.debugDescription
            case .status(let status):
                return "status(\(status.rawValue))"
            case .finished(let status, let finalMessage, let providerThreadId):
                return "finished(\(status.rawValue), final=\(finalMessage ?? "nil"), provider=\(providerThreadId == nil ? "nil" : "set"))"
            case .error(let message):
                return "error(\(message))"
            }
        }.joined(separator: ", ")
    }

    var planRuntimePayloads: String {
        lock.lock(); defer { lock.unlock() }
        return events.compactMap { event -> String? in
            guard case .event(.providerRuntime(let runtime)) = event,
                  runtime.method == "user" || runtime.method == "permission_request" else { return nil }
            return String(runtime.payloadJSON.prefix(4_000))
        }.joined(separator: " | ")
    }

    var resultRuntimePayloads: String {
        lock.lock(); defer { lock.unlock() }
        return events.compactMap { event -> String? in
            guard case .event(.providerRuntime(let runtime)) = event,
                  runtime.method == "result" || runtime.method == "sdk_error" else { return nil }
            return runtime.payloadJSON
        }.joined(separator: " | ")
    }

    func waitFinished(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if finished != nil { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(
            domain: "ClaudeAgentSDKRealE2ETests",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "timed out: \(failureSummary)"]
        )
    }
}
