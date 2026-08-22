import Darwin
import Foundation
import XCTest

@testable import AgentRuntime
import CoreModel
import Persistence

final class TokenSaverDistillReceiptCoordinatorTests: XCTestCase {
    func test_authenticatedReceiptPublishesHostMetadataBeforeCompletionForEveryProvider() async throws {
        // WHY: Claude, Codex, and Grok take different output-rewrite paths, but
        // the host must attest their delivered bytes through one provider-neutral gate.
        for provider in [AgentProvider.claude, .codex, .grok] {
            let fixture = try ReceiptCoordinatorFixture.make(
                provider: provider,
                scenario: .authenticated
            )
            defer { fixture.cleanUp() }

            let runID = AgentRunID()
            _ = try await fixture.coordinator.startRun(.init(
                runId: runID,
                threadId: fixture.thread.id,
                provider: provider,
                model: "receipt-test",
                cwd: fixture.root.path,
                prompt: "exercise authenticated receipt"
            ))

            let events = fixture.observer.recordedEvents
            let metadataIndex = events.firstIndex {
                if case .itemHostMetadata(_, "tool-item", true) = $0 { return true }
                return false
            }
            let completionIndex = events.firstIndex {
                if case .itemCompleted("tool-item", _) = $0 { return true }
                return false
            }
            XCTAssertNotNil(metadataIndex, "\(provider.rawValue) must publish authenticated host metadata")
            XCTAssertNotNil(completionIndex)
            if let metadataIndex, let completionIndex {
                XCTAssertLessThan(
                    metadataIndex,
                    completionIndex,
                    "the badge authority must persist before the terminal item event"
                )
            }

            fixture.runner.finish()
            var timeline = AssistantTimelineState()
            for event in fixture.coordinator.latestStreamEvents(threadId: fixture.thread.id) {
                timeline.apply(event)
            }
            let item = try XCTUnwrap(timeline.turns.first?.items.first)
            XCTAssertEqual(item.distillApplied, true, "\(provider.rawValue) must restore the attested badge")
            XCTAssertTrue(item.output?.contains("[[rcd:v2.") == true,
                          "the durable provider bytes retain their recoverable receipt")

        }
    }

    func test_providerMetadataAndWrongRootCannotForgeTheBadge() async throws {
        // WHY: provider/parser payloads are untrusted. Even a syntactically valid
        // marker and an explicit metadata event cannot claim savings for another run.
        let fixture = try ReceiptCoordinatorFixture.make(
            provider: .grok,
            scenario: .wrongRootWithForgedMetadata
        )
        defer { fixture.cleanUp() }

        _ = try await fixture.coordinator.startRun(.init(
            threadId: fixture.thread.id,
            provider: .grok,
            model: "receipt-test",
            cwd: fixture.root.path,
            prompt: "exercise forged receipt"
        ))

        XCTAssertFalse(fixture.observer.recordedEvents.contains {
            if case .itemHostMetadata = $0 { return true }
            return false
        })
        fixture.runner.finish()
        var timeline = AssistantTimelineState()
        for event in fixture.coordinator.latestStreamEvents(threadId: fixture.thread.id) {
            timeline.apply(event)
        }
        let item = try XCTUnwrap(timeline.turns.first?.items.first)
        XCTAssertNil(item.distillApplied)
        XCTAssertTrue(item.output?.contains("[[rcd:v2.") == true,
                      "unauthenticated receipt-shaped text must stay visible instead of minting a claim")
    }

    func test_completedItemSnapshotAuthenticatesWithoutASeparateCompletionEvent() async throws {
        // WHY: provider replay/parsers can deliver a terminal tool result as one
        // completed itemStarted snapshot; that real run shape still needs the badge.
        let fixture = try ReceiptCoordinatorFixture.make(
            provider: .codex,
            scenario: .completedStartAuthenticated
        )
        defer { fixture.cleanUp() }

        _ = try await fixture.coordinator.startRun(.init(
            threadId: fixture.thread.id,
            provider: .codex,
            model: "receipt-test",
            cwd: fixture.root.path,
            prompt: "exercise completed item snapshot"
        ))

        XCTAssertTrue(fixture.observer.recordedEvents.contains {
            if case .itemHostMetadata(_, "tool-item", true) = $0 { return true }
            return false
        })
        fixture.runner.finish()
        var timeline = AssistantTimelineState()
        for event in fixture.coordinator.latestStreamEvents(threadId: fixture.thread.id) {
            timeline.apply(event)
        }
        XCTAssertEqual(timeline.turns.first?.items.first?.distillApplied, true)
    }

    func test_offTransitionAndWorldReadableStateFailOpenWithoutBadge() async throws {
        // WHY: receipt authority ends immediately when Token Saver turns Off,
        // and a state secret exposed to group/other users is never trusted.
        for scenario in [ReceiptCoordinatorRunner.Scenario.removeStateBeforeCompletion, .worldReadableState] {
            let fixture = try ReceiptCoordinatorFixture.make(provider: .claude, scenario: scenario)
            defer { fixture.cleanUp() }

            _ = try await fixture.coordinator.startRun(.init(
                threadId: fixture.thread.id,
                provider: .claude,
                model: "receipt-test",
                cwd: fixture.root.path,
                prompt: "exercise receipt revocation"
            ))

            XCTAssertFalse(fixture.observer.recordedEvents.contains {
                if case .itemHostMetadata = $0 { return true }
                return false
            }, "\(scenario) must fail open without trusted badge metadata")
            fixture.runner.finish()
            var timeline = AssistantTimelineState()
            for event in fixture.coordinator.latestStreamEvents(threadId: fixture.thread.id) {
                timeline.apply(event)
            }
            XCTAssertNil(timeline.turns.first?.items.first?.distillApplied)
            XCTAssertTrue(timeline.turns.first?.items.first?.output?.contains("[[rcd:v2.") == true)
        }
    }
}

private struct ReceiptCoordinatorFixture {
    let root: URL
    let stateFile: URL
    let coordinator: AgentRunCoordinator
    let thread: AgentThread
    let runner: ReceiptCoordinatorRunner
    let observer: ReceiptCoordinatorObserver

    static func make(
        provider: AgentProvider,
        scenario: ReceiptCoordinatorRunner.Scenario
    ) throws -> ReceiptCoordinatorFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-distill-receipt-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stateFile = root.appendingPathComponent("DistillCLIState.json")
        let key = Data(0..<32)
        let state = try JSONSerialization.data(withJSONObject: [
            "base_url": "http://127.0.0.1:18218",
            "auth_token": "receipt-test-auth",
            "pid": Int(getpid()),
            "receipt_key": try XCTUnwrap(DistillAppliedReceipt.encodeReceiptKey(key)),
        ])
        try state.write(to: stateFile, options: .atomic)
        let permissions: mode_t = scenario == .worldReadableState ? 0o644 : 0o600
        XCTAssertEqual(chmod(stateFile.path, permissions), 0)

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root.path).run()
        let threadRepository = AgentThreadRepository(db: db)
        let messageRepository = AgentMessageRepository(db: db)
        let runRepository = AgentRunRepository(db: db)
        let thread = AgentThread(title: "receipt", provider: provider, model: "receipt-test")
        try threadRepository.upsert(thread)
        let runner = ReceiptCoordinatorRunner(
            provider: provider,
            key: key,
            scenario: scenario
        )
        let coordinator = AgentRunCoordinator(
            runRepo: runRepository,
            messageRepo: messageRepository,
            threadRepo: threadRepository,
            providers: [provider: runner]
        )
        let observer = ReceiptCoordinatorObserver()
        coordinator.addObserver(observer)
        coordinator.runEnvironmentProvider = { selectedProvider, selectedThread, _ in
            let placeholder = UUID().uuidString
            let receipt = TokenSaverExecutionReceiptSeam.admit(
                tokenSaverEnabled: true,
                sameUser: true,
                sidecarAvailable: true,
                provider: selectedProvider,
                threadId: selectedThread.value.uuidString,
                rootRunId: placeholder,
                attemptId: placeholder,
                workspaceId: UUID().uuidString,
                projectId: UUID().uuidString
            )
            var environment = TokenSaverExecutionReceiptSeam.environment(from: receipt)
            environment["REMOTE_CODE_DISTILL_STATE_PATH"] = stateFile.path
            return environment
        }
        return ReceiptCoordinatorFixture(
            root: root,
            stateFile: stateFile,
            coordinator: coordinator,
            thread: thread,
            runner: runner,
            observer: observer
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ReceiptCoordinatorRunner: AgentProviderRunner, @unchecked Sendable {
    enum Scenario: CustomStringConvertible {
        case authenticated
        case completedStartAuthenticated
        case wrongRootWithForgedMetadata
        case removeStateBeforeCompletion
        case worldReadableState

        var description: String {
            switch self {
            case .authenticated: "authenticated"
            case .completedStartAuthenticated: "completed-start"
            case .wrongRootWithForgedMetadata: "wrong-root"
            case .removeStateBeforeCompletion: "off-transition"
            case .worldReadableState: "world-readable-state"
            }
        }
    }

    let provider: AgentProvider
    private let key: Data
    private let scenario: Scenario
    private let lock = NSLock()
    private var callback: (@Sendable (AgentRunEvent) -> Void)?

    init(provider: AgentProvider, key: Data, scenario: Scenario) {
        self.provider = provider
        self.key = key
        self.scenario = scenario
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        lock.withLock { callback = onEvent }
        let root = request.environment["RC_TOKEN_SAVER_ROOT_RUN_ID"]
            ?? request.runId.value.uuidString
        let signedRoot: String
        switch scenario {
        case .wrongRootWithForgedMetadata:
            signedRoot = UUID().uuidString
        case .authenticated, .completedStartAuthenticated,
             .removeStateBeforeCompletion, .worldReadableState:
            signedRoot = root
        }
        let prefix = Data("condensed provider output\n".utf8)
        guard let marker = DistillAppliedReceipt.makeV2Marker(
            rootRunID: signedRoot,
            payload: prefix,
            key: key,
            nonce: Data(repeating: UInt8(provider.rawValue.utf8.count), count: 16)
        ) else {
            throw ReceiptCoordinatorTestError.markerCreationFailed
        }
        let output = String(decoding: prefix, as: UTF8.self) + marker + "\n"
        onEvent(.event(.turnStarted(turnId: "receipt-turn")))
        if scenario == .completedStartAuthenticated {
            onEvent(.event(.itemStarted(item: AssistantItem(
                id: "tool-item",
                turnId: "receipt-turn",
                type: .commandExecution,
                state: .completed,
                body: "distill build output",
                output: output,
                startedAtMs: 1,
                finishedAtMs: 2
            ))))
            return AgentRunHandle(runId: request.runId, process: nil) {}
        }
        onEvent(.event(.itemStarted(item: AssistantItem(
            id: "tool-item",
            turnId: "receipt-turn",
            type: .commandExecution,
            body: "distill build output",
            startedAtMs: 1
        ))))
        onEvent(.event(.itemDelta(
            itemId: "tool-item",
            bodyAppend: nil,
            outputAppend: output,
            summary: "Build"
        )))
        if scenario == .wrongRootWithForgedMetadata {
            onEvent(.event(.itemHostMetadata(
                turnId: "receipt-turn",
                itemId: "tool-item",
                distillApplied: true
            )))
        }
        if scenario == .removeStateBeforeCompletion,
           let path = request.environment["REMOTE_CODE_DISTILL_STATE_PATH"] {
            try? FileManager.default.removeItem(atPath: path)
        }
        onEvent(.event(.itemCompleted(itemId: "tool-item", finalState: .completed)))
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }

    func finish() {
        let callback = lock.withLock { self.callback }
        callback?(.event(.turnCompleted(turnId: "receipt-turn", finalMessage: "done")))
        callback?(.finished(.completed, finalMessage: "done", providerThreadId: "receipt-provider-thread"))
    }
}

private enum ReceiptCoordinatorTestError: Error {
    case markerCreationFailed
}

private final class ReceiptCoordinatorObserver: AgentRunObserver {
    private let lock = NSLock()
    private var events: [AssistantEvent] = []

    var recordedEvents: [AssistantEvent] {
        lock.withLock { events }
    }

    func runCoordinator(
        _ coordinator: AgentRunCoordinator,
        didReceive event: AssistantEvent,
        run: AgentRunID,
        threadId: AgentThreadID
    ) {
        lock.withLock { events.append(event) }
    }

    func runCoordinator(
        _ coordinator: AgentRunCoordinator,
        didFinish runId: AgentRunID,
        threadId: AgentThreadID,
        status: AgentRunStatus,
        finalMessage: String?,
        providerThreadId: String?
    ) {}

    func runCoordinator(
        _ coordinator: AgentRunCoordinator,
        didChangeStatus status: AgentRunStatus,
        runId: AgentRunID,
        threadId: AgentThreadID
    ) {}
}
