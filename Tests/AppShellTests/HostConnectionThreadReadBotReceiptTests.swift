import XCTest
@testable import AppShell
@testable import CoreModel
@testable import SocketServer
@testable import Persistence
import AgentRuntime

/// C5 perf receipts (host connection: `agent.thread.read` v1 and paired `bot.*`).
///
/// Opt-in measurement, not a pass/fail gate: run with
/// `RC_HOST_CONN_RECEIPTS=1 scripts/isolated-sandbox.sh test --filter HostConnectionThreadReadBotReceiptTests`.
/// Every scenario uses a file-backed AppContext (writer + WAL reader), the
/// production AppCommandRouter + BotsViewModel + JSONRPCDispatcher and a real
/// DirectHTTPServer over loopback TCP with a paired bearer. It only uses API
/// that exists before and after C5, so the same file produces both receipts.
///
/// "Main stall" is the longest a MainActor hop issued from a background task
/// waited while one request was in flight: how long the app's main thread (UI,
/// every other RPC, every event publish) was unavailable because of it.
final class HostConnectionThreadReadBotReceiptTests: XCTestCase {
    private static let warmups = 2
    private static let heldSamples = 7
    private static let idleSamples = 30
    private static let lockHoldSeconds: TimeInterval = 0.25
    private static let requestDelayIntoHoldSeconds: TimeInterval = 0.02
    private static let eventsPerThread = 128
    private static let botCount = 20
    private static let queuedPerBot = 10

    private struct Fixture {
        let context: AppContext
        let router: AppCommandRouter
        let botsViewModel: BotsViewModel
        let server: DirectHTTPServer
        let token: String
        let port: UInt16
        let threadA: AgentThreadID
        let threadB: AgentThreadID
        let bots: [BotID]
    }

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["RC_HOST_CONN_RECEIPTS"] == "1" else {
            throw XCTSkip("set RC_HOST_CONN_RECEIPTS=1 to record host-connection receipts")
        }
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let dir = NSTemporaryDirectory() + "RC2HostConnC5Receipt-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: context)
        context.router = router
        let botsViewModel = BotsViewModel(context: context, router: router)
        router.botsViewModel = botsViewModel
        let repo = DeviceTrustRepository(db: context.db)
        let code = try repo.createPairingCode()
        let paired = try XCTUnwrap(repo.redeemPairingCode(code.code, deviceName: "Receipt iPhone"))
        let auth = LocalAuthAdapter(repo: DeviceTrustRepository(db: context.db))

        // Two threads with a full v1 window each (128 events, ~700 B payloads).
        var threadIDs: [AgentThreadID] = []
        for name in ["A", "B"] {
            let thread = AgentThread(title: "receipt thread \(name)", provider: .codex, model: "gpt-5")
            try context.threadRepo.upsert(thread)
            let run = AgentRun(
                threadId: thread.id,
                provider: .codex,
                model: "gpt-5",
                status: .completed,
                startedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
            try context.runRepo.upsert(run)
            for seq in 1...Self.eventsPerThread {
                let turn = "\(name)-turn-\(seq)-" + String(repeating: "x", count: 640)
                try context.runRepo.appendStreamEvent(
                    runId: run.id,
                    seq: seq,
                    kind: "turnStarted",
                    payloadJSON: #"{"turnStarted":{"turnId":"\#(turn)"}}"#
                )
            }
            threadIDs.append(thread.id)
        }

        // 20 bots, 10 queued follow-ups each: the fleet-wide queue a paired
        // device's bot polls used to rescan and re-publish.
        var bots: [BotID] = []
        for index in 0..<Self.botCount {
            let bot = try botsViewModel.create(name: "Receipt Bot \(index)", title: "Receipt")
            bots.append(bot.id)
            for item in 0..<Self.queuedPerBot {
                _ = try context.botStore.enqueueQueuedFollowUp(BotQueuedFollowUpRecord(
                    botID: bot.id,
                    text: "queued follow-up \(item) " + String(repeating: "q", count: 160),
                    payloadJSON: "{}",
                    createdAt: Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(item))
                ))
            }
        }
        botsViewModel.reloadQueuedFollowUpsFromStore()

        var lastError: Error?
        for _ in 0..<20 {
            let port = UInt16.random(in: 33000...44000)
            let server = DirectHTTPServer(
                port: port,
                loopbackOnly: true,
                dispatcher: JSONRPCDispatcher(router: router),
                auth: auth,
                serverId: "receipt-host",
                bootEpoch: 1
            )
            do {
                try server.start()
                return Fixture(
                    context: context,
                    router: router,
                    botsViewModel: botsViewModel,
                    server: server,
                    token: paired.token,
                    port: port,
                    threadA: threadIDs[0],
                    threadB: threadIDs[1],
                    bots: bots
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "receipt", code: 1)
    }

    private static func threadReadV1Params(_ thread: AgentThreadID) -> [String: Any] {
        [
            "thread_id": thread.value.uuidString,
            "response_version": 1,
            "include_event_watermark": true,
        ]
    }

    // MARK: - agent.thread.read v1

    @MainActor
    func test_receipt_threadReadV1_idle() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        let params = Self.threadReadV1Params(fixture.threadB)
        for _ in 0..<5 { _ = try await Self.rpc(fixture, method: "agent.thread.read", params: params) }
        var latency: [Double] = []
        var stall: [Double] = []
        for _ in 0..<Self.idleSamples {
            let sample = try await Self.rpcWithMainStall(fixture, method: "agent.thread.read", params: params)
            latency.append(sample.latency)
            stall.append(sample.mainStall)
        }
        Self.report("rpc_thread_read_v1_128_events_idle", latency)
        Self.report("main_stall_thread_read_v1_128_events_idle", stall)
    }

    /// Thread A's mirror lock is held for 250 ms (a long stream flush or a
    /// concurrent A snapshot). The device reads thread B.
    @MainActor
    func test_receipt_threadReadV1_otherThreadMirrorLockHeld() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        try await lockHeldReceipt(
            fixture,
            holding: fixture.threadA,
            reading: fixture.threadB,
            name: "thread_read_v1_other_thread_mirror_lock_held_250ms"
        )
    }

    /// Thread A's mirror lock is held for 250 ms and the device reads thread A.
    /// The read must wait (correctness); the main thread must not.
    @MainActor
    func test_receipt_threadReadV1_sameThreadMirrorLockHeld() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        try await lockHeldReceipt(
            fixture,
            holding: fixture.threadA,
            reading: fixture.threadA,
            name: "thread_read_v1_same_thread_mirror_lock_held_250ms"
        )
    }

    @MainActor
    private func lockHeldReceipt(
        _ fixture: Fixture,
        holding: AgentThreadID,
        reading: AgentThreadID,
        name: String
    ) async throws {
        let params = Self.threadReadV1Params(reading)
        _ = try await Self.rpc(fixture, method: "agent.thread.read", params: params)
        var latency: [Double] = []
        var stall: [Double] = []
        for index in 0..<(Self.warmups + Self.heldSamples) {
            let released = Self.holdMirrorLock(fixture.context.coordinator, thread: holding)
            try await Task.sleep(nanoseconds: UInt64(Self.requestDelayIntoHoldSeconds * 1_000_000_000))
            let sample = try await Self.rpcWithMainStall(fixture, method: "agent.thread.read", params: params)
            await Self.waitForRelease(released)
            if index >= Self.warmups {
                latency.append(sample.latency)
                stall.append(sample.mainStall)
            }
        }
        Self.report("rpc_" + name, latency)
        Self.report("main_stall_" + name, stall)
    }

    // MARK: - bot.*

    @MainActor
    func test_receipt_botReceiptStatus_idle() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        let params: [String: Any] = ["client_request_id": "receipt-unknown-request"]
        try await idleBotReceipt(fixture, name: "bot_receipt_status_20_bots_200_queued_idle", method: "bot.receipt.status") { _ in params }
    }

    @MainActor
    func test_receipt_botList_idle() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        try await idleBotReceipt(fixture, name: "bot_list_20_bots_200_queued_idle", method: "bot.list") { _ in [:] }
    }

    @MainActor
    func test_receipt_botSetPinned_idle() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        let bot = fixture.bots[0].value.uuidString.lowercased()
        try await idleBotReceipt(fixture, name: "bot_set_pinned_20_bots_200_queued_idle", method: "bot.set_pinned") { index in
            [
                "client_request_id": "receipt-pin-\(index)-\(UUID().uuidString)",
                "bot_id": bot,
                "pinned": index.isMultiple(of: 2),
            ]
        }
    }

    @MainActor
    private func idleBotReceipt(
        _ fixture: Fixture,
        name: String,
        method: String,
        params: (Int) -> [String: Any]
    ) async throws {
        for index in 0..<5 { _ = try await Self.rpc(fixture, method: method, params: params(-1 - index)) }
        var latency: [Double] = []
        var stall: [Double] = []
        for index in 0..<Self.idleSamples {
            let sample = try await Self.rpcWithMainStall(fixture, method: method, params: params(index))
            latency.append(sample.latency)
            stall.append(sample.mainStall)
        }
        Self.report("rpc_" + name, latency)
        Self.report("main_stall_" + name, stall)
    }

    // MARK: - Helpers

    private static func ms(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }

    /// Holds `thread`'s mirror lock for `lockHoldSeconds` on another thread,
    /// through the public v1 snapshot entry point (its body runs under the lock).
    private static func holdMirrorLock(_ coordinator: AgentRunCoordinator, thread: AgentThreadID) -> DispatchSemaphore {
        let started = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? coordinator.withMirrorEventSnapshotForThreadReadV1(
                threadId: thread,
                eventLimit: 1,
                maxPayloadBytes: 1_024
            ) { _ in
                started.signal()
                Thread.sleep(forTimeInterval: lockHoldSeconds)
            }
            released.signal()
        }
        started.wait()
        return released
    }

    private static func waitForRelease(_ released: DispatchSemaphore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                released.wait()
                continuation.resume()
            }
        }
    }

    /// Polls MainActor availability from a background task while `body` runs.
    private final class MainStallProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private var worst: Double = 0

        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

        func record(_ value: Double) {
            lock.lock(); worst = max(worst, value); lock.unlock()
        }

        func stop() -> Double {
            lock.lock(); defer { lock.unlock() }
            running = false
            return worst
        }
    }

    @MainActor
    private static func rpcWithMainStall(
        _ fixture: Fixture,
        method: String,
        params: [String: Any]
    ) async throws -> (latency: Double, mainStall: Double) {
        let probe = MainStallProbe()
        let poller = Task.detached(priority: .userInitiated) {
            while probe.isRunning {
                let t0 = DispatchTime.now()
                await MainActor.run {}
                probe.record(ms(since: t0))
                try? await Task.sleep(nanoseconds: 250_000)
            }
        }
        let latency = try await rpc(fixture, method: method, params: params)
        let stall = probe.stop()
        await poller.value
        return (latency, stall)
    }

    @MainActor
    private static func rpc(
        _ fixture: Fixture,
        method: String,
        params: [String: Any] = [:]
    ) async throws -> Double {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(fixture.port)/v1/rpc")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(fixture.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
        ])
        let t0 = DispatchTime.now()
        let (data, response) = try await URLSession.shared.data(for: request)
        let latency = ms(since: t0)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(object?["error"], "\(method) failed: \(String(decoding: data, as: UTF8.self).prefix(300))")
        return latency
    }

    private static func report(_ name: String, _ samples: [Double]) {
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let index = min(sorted.count - 1, Int((p * Double(sorted.count - 1)).rounded()))
            return sorted[index]
        }
        let rounded = samples.map { ($0 * 1000).rounded() / 1000 }
        let payload: [String: Any] = [
            "scenario": name,
            "n": samples.count,
            "p50_ms": (percentile(0.5) * 1000).rounded() / 1000,
            "p95_ms": (percentile(0.95) * 1000).rounded() / 1000,
            "max_ms": ((sorted.last ?? 0) * 1000).rounded() / 1000,
            "samples_ms": rounded,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        print("RECEIPT \(String(decoding: data, as: UTF8.self))")
    }
}
