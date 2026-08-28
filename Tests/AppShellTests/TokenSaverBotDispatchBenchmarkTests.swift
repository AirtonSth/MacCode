import CryptoKit
import Foundation
import XCTest
import CoreModel
@testable import AgentRuntime
@testable import AppShell
@testable import Persistence

@MainActor
final class TokenSaverBotDispatchBenchmarkTests: XCTestCase {
    private static let fixtureID = "t016-bot-dispatch-primary-nested-v1"
    private static let workloadDescription = "real AppShell Desk primary acknowledgement-to-provider-start followed by one Bot peer acknowledgement-to-provider-start"
    private static let clockDescription = "DispatchTime.uptimeNanoseconds at acknowledged intent and AgentProviderRunner.startRun entry"
    private static let warmupDescription = "one identical primary+nested dispatch discarded before five measured samples"

    func test_primaryAndNestedDispatch_emitsFiveWarmedSamples() async throws {
        _ = try await measureDispatch(sampleIndex: -1)

        var samples: [Double] = []
        samples.reserveCapacity(5)
        for sampleIndex in 0..<5 {
            samples.append(try await measureDispatch(sampleIndex: sampleIndex))
        }

        XCTAssertEqual(samples.count, 5, "the immutable comparison contract requires exactly five warmed samples")
        XCTAssertTrue(samples.allSatisfy { $0.isFinite && $0 >= 0 })
        let median = samples.sorted()[2]
        let fixtureDigest = Self.sha256([
            Self.fixtureID,
            Self.workloadDescription,
            Self.clockDescription,
            Self.warmupDescription,
        ].joined(separator: "\n"))
        let environment = ProcessInfo.processInfo.environment
        let payload: [String: Any] = [
            "environment": [
                "sandbox_identity": environment["RC2_BUNDLE_ID"] ?? "io.remotecode.desktop.debug",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "architecture": Self.architecture,
                "build_configuration": _isDebugAssertConfiguration() ? "debug" : "release",
                "checkout_sha": environment["RC_T016_CHECKOUT_SHA"] ?? "gate-not-provided",
            ],
            "workload": [
                "identifier": Self.fixtureID,
                "sha256": fixtureDigest,
            ],
            "clock": [
                "identifier": "acknowledgement-to-provider-start-monotonic-v1",
                "points": ["acknowledged_intent", "provider_start_entry"],
                "sha256": Self.sha256(Self.clockDescription),
            ],
            "warmup": [
                "count": 1,
                "procedure": Self.warmupDescription,
                "sha256": Self.sha256(Self.warmupDescription),
            ],
            "samples": samples,
            "median": median,
            "harness_sha256": fixtureDigest,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        print("TOKEN_SAVER_BOT_DISPATCH_BENCHMARK_JSON=\(json)")
    }

    private func measureDispatch(sampleIndex: Int) async throws -> Double {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rc-t016-bot-dispatch-\(sampleIndex)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let context = try AppContext(channel: .debug, appSupportOverride: root.path)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = false }
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = TokenSaverBotDispatchRecordingRunner(provider: .codex)
        context.coordinator.replaceProvider(.codex, runner: runner)
        context.coordinator.tokenSaverOutboundSelector = { request in
            await TokenSaverBestOfThreeSelector.select(
                canonicalHuman: request.canonicalHuman,
                humanOutboundPrompt: request.admittedRequest.prompt,
                humanEffectiveEnvelope: request.admittedRequest.prompt,
                target: TokenSaverBestOfThreeSelector.Target(
                    provider: request.admittedRequest.provider.rawValue,
                    resolvedModel: request.admittedRequest.model,
                    counterID: "t016-controlled",
                    counterRevision: "1",
                    encoding: "synthetic"
                ),
                candidates: [],
                counter: nil
            )
        }
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex,
                models: [AgentModelDescriptor(id: "t016-model", label: "T016", provider: .codex)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "codex"
            ),
        ])
        let viewModel = BotsViewModel(context: context, router: router)
        router.botsViewModel = viewModel
        let host = try viewModel.create(name: "Piper", title: "Dispatch Host", provider: .codex, model: "t016-model")
        let peer = try viewModel.create(name: "Quinn", title: "Dispatch Peer", provider: .codex, model: "t016-model")
        viewModel.openDesk(host)
        viewModel.deskRouting = BotDeskRouting(
            provider: .codex,
            providerInstanceID: "codex",
            model: "t016-model",
            routingMode: .manual
        )

        let primaryPrompt = "T016 benchmark primary \(sampleIndex)"
        XCTAssertTrue(viewModel.send(primaryPrompt))
        XCTAssertTrue(viewModel.deskShowsLoading, "Desk must acknowledge the primary intent synchronously")
        let primaryAcknowledged = DispatchTime.now().uptimeNanoseconds
        let primaryRequest = try await runner.waitForRequest(count: 1)
        let primaryStarted = try XCTUnwrap(runner.startedAt(runID: primaryRequest.runId))

        let nestedAcknowledged = DispatchTime.now().uptimeNanoseconds
        let nestedCall = Task { @MainActor in
            try await router.askBotPeer(
                callerThread: primaryRequest.threadId,
                callerRun: primaryRequest.runId,
                handle: peer.handle,
                prompt: "T016 benchmark nested \(sampleIndex)",
                replyMode: .consult,
                delegationCapability: primaryRequest.environment[
                    AgentDelegationCapabilityTransport.environmentKey
                ]
            )
        }
        let nestedRequest = try await runner.waitForRequest(count: 2)
        let nestedStarted = try XCTUnwrap(runner.startedAt(runID: nestedRequest.runId))
        XCTAssertTrue(runner.finish(runID: nestedRequest.runId, reply: "synthetic nested reply"))
        _ = try await nestedCall.value
        XCTAssertTrue(runner.finish(runID: primaryRequest.runId, reply: "synthetic primary reply"))

        let primaryMS = Self.elapsedMilliseconds(from: primaryAcknowledged, to: primaryStarted)
        let nestedMS = Self.elapsedMilliseconds(from: nestedAcknowledged, to: nestedStarted)
        return primaryMS + nestedMS
    }

    private static func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end >= start ? end - start : 0) / 1_000_000
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static var architecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }
}

private final class TokenSaverBotDispatchRecordingRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider

    private struct Pending {
        let request: AgentRunRequest
        let turnID: String
        let onEvent: @Sendable (AgentRunEvent) -> Void
    }

    private let lock = NSLock()
    private var requests: [AgentRunRequest] = []
    private var starts: [AgentRunID: UInt64] = [:]
    private var pending: [AgentRunID: Pending] = [:]

    init(provider: AgentProvider) {
        self.provider = provider
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        let started = DispatchTime.now().uptimeNanoseconds
        let turnID = "turn-\(request.runId.value.uuidString.lowercased())"
        lock.withLock {
            requests.append(request)
            starts[request.runId] = started
            pending[request.runId] = Pending(request: request, turnID: turnID, onEvent: onEvent)
        }
        let providerThreadID = request.providerThreadId ?? request.threadId.value.uuidString
        onEvent(.status(.running))
        onEvent(.event(.threadStarted(threadId: providerThreadID, providerThreadId: providerThreadID)))
        onEvent(.event(.turnStarted(turnId: turnID)))
        return AgentRunHandle(runId: request.runId, process: nil) { [weak self] in
            _ = self?.finish(runID: request.runId, status: .cancelled, reply: nil)
        }
    }

    func waitForRequest(count: Int) async throws -> AgentRunRequest {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let request = lock.withLock({ requests.count >= count ? requests[count - 1] : nil }) {
                return request
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw NSError(
            domain: "TokenSaverBotDispatchBenchmarkTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "provider start did not arrive"]
        )
    }

    func startedAt(runID: AgentRunID) -> UInt64? {
        lock.withLock { starts[runID] }
    }

    @discardableResult
    func finish(
        runID: AgentRunID,
        status: AgentRunStatus = .completed,
        reply: String?
    ) -> Bool {
        guard let pending = lock.withLock({ self.pending.removeValue(forKey: runID) }) else {
            return false
        }
        let providerThreadID = pending.request.providerThreadId ?? pending.request.threadId.value.uuidString
        if status == .completed, let reply {
            let itemID = "assistant-\(runID.value.uuidString.lowercased())"
            pending.onEvent(.event(.itemStarted(item: AssistantItem(
                id: itemID,
                turnId: pending.turnID,
                type: .assistantMessage,
                startedAtMs: 1
            ))))
            pending.onEvent(.event(.itemDelta(itemId: itemID, bodyAppend: reply, outputAppend: nil, summary: nil)))
            pending.onEvent(.event(.itemCompleted(itemId: itemID, finalState: .completed)))
            pending.onEvent(.event(.turnCompleted(turnId: pending.turnID, finalMessage: reply)))
        }
        pending.onEvent(.status(status))
        pending.onEvent(.finished(status, finalMessage: reply, providerThreadId: providerThreadID))
        return true
    }
}
