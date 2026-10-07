import XCTest
@testable import AppShell
@testable import CoreModel
@testable import SocketServer
@testable import Persistence

/// C7 perf receipts (host connection: `sync.snapshot` join, fence, encode, bound).
///
/// Opt-in measurement, not a pass/fail gate: run with
/// `RC_HOST_CONN_RECEIPTS=1 scripts/isolated-sandbox.sh test --filter HostConnectionSnapshotReceiptTests`.
/// Every scenario uses a file-backed AppContext with the production event
/// persister, the production AppCommandRouter and JSONRPCDispatcher, and a
/// real DirectHTTPServer over loopback TCP with a paired bearer. The host is
/// seeded with 9 workspaces x 20 agent threads (180, close to the 177
/// workspace-bound threads in the live DB). The file only sends raw JSON, so
/// the same source runs before and after C7; a parameter the old host does
/// not know is recorded as its error code.
///
/// "Main stall" is the longest a MainActor hop issued from a background task
/// waited while the request was in flight.
final class HostConnectionSnapshotReceiptTests: XCTestCase {
    private static let warmups = 5
    private static let samples = 15
    private static let workspaceCount = 9
    private static let threadsPerWorkspace = 20

    private struct Fixture {
        let context: AppContext
        let router: AppCommandRouter
        let server: DirectHTTPServer
        let token: String
        let port: UInt16
        let workspaces: [WorkspaceID]
    }

    private struct Sample {
        let latency: Double
        let errorCode: Int?
        let bytes: Int
    }

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["RC_HOST_CONN_RECEIPTS"] == "1" else {
            throw XCTSkip("set RC_HOST_CONN_RECEIPTS=1 to record host-connection receipts")
        }
    }

    override func tearDown() {
        EventBus.shared.persister = nil
        EventBus.shared.persistenceCommitFence = nil
        super.tearDown()
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let dir = NSTemporaryDirectory() + "RC2HostConnC7Receipt-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: context)
        context.router = router
        AppDelegate.wireEventPersistence(context: context)
        var workspaces = try router.listWorkspaces().map(\.id)
        while workspaces.count < Self.workspaceCount {
            workspaces.append(try router.createWorkspace(name: "Receipt \(workspaces.count)", cwd: dir).id)
        }
        let now = Date()
        for (w, workspace) in workspaces.prefix(Self.workspaceCount).enumerated() {
            for t in 0..<Self.threadsPerWorkspace {
                let index = w * Self.threadsPerWorkspace + t
                try context.threadRepo.upsert(AgentThread(
                    workspaceId: workspace,
                    title: "Receipt thread \(index) with a realistic sidebar title length",
                    provider: index % 2 == 0 ? .codex : .claude,
                    model: index % 2 == 0 ? "gpt-5" : "claude-opus",
                    status: t == 0 ? .running : .completed,
                    createdAt: now.addingTimeInterval(-Double(index) * 600),
                    updatedAt: now.addingTimeInterval(-Double(index) * 60),
                    diffAdditions: index,
                    diffDeletions: index / 2,
                    hasUnread: t % 7 == 0
                ))
            }
        }
        let repo = DeviceTrustRepository(db: context.db)
        let code = try repo.createPairingCode()
        let paired = try XCTUnwrap(repo.redeemPairingCode(code.code, deviceName: "Receipt iPhone"))
        let auth = LocalAuthAdapter(repo: DeviceTrustRepository(db: context.db))

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
                    server: server,
                    token: paired.token,
                    port: port,
                    workspaces: Array(workspaces.prefix(Self.workspaceCount))
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "receipt", code: 1)
    }

    private static let fullParams: [String: Any] = ["supportedStateVersion": 3]
    private static let boundedParams: [String: Any] = [
        "supportedStateVersion": 3,
        "agentThreadsRecentPerWorkspace": 5,
    ]

    // MARK: - Scenarios

    /// One caller, quiet host: end-to-end latency, main stall and bytes.
    @MainActor
    func test_receipt_syncSnapshot_idle() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        var latency: [Double] = []
        var stall: [Double] = []
        var bytes = 0
        for index in 0..<(Self.warmups + Self.samples) {
            let probe = Self.startMainStallProbe()
            let sample = try await Self.rpc(fixture, params: Self.fullParams)
            let worst = await probe()
            XCTAssertNil(sample.errorCode)
            if index >= Self.warmups {
                latency.append(sample.latency)
                stall.append(worst)
                bytes = sample.bytes
            }
        }
        Self.report("sync_snapshot_idle", latency, extra: ["response_bytes": bytes])
        Self.report("main_stall_sync_snapshot_idle", stall)
    }

    /// Two devices reconnect at the same moment: both send `sync.snapshot`
    /// before either read finishes.
    @MainActor
    func test_receipt_syncSnapshot_twoConcurrentCallers() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        var latency: [Double] = []
        var succeeded = 0
        var failedCodes: [Int] = []
        for index in 0..<(Self.warmups + Self.samples) {
            async let first = Self.rpc(fixture, params: Self.fullParams)
            async let second = Self.rpc(fixture, params: Self.fullParams)
            let pair = try await [first, second]
            guard index >= Self.warmups else { continue }
            for sample in pair {
                latency.append(sample.latency)
                if let code = sample.errorCode { failedCodes.append(code) } else { succeeded += 1 }
            }
        }
        Self.report("sync_snapshot_two_concurrent_callers", latency, extra: [
            "calls": latency.count,
            "succeeded": succeeded,
            "failed_codes": failedCodes,
        ])
    }

    /// A busy terminal (and an agent touching its thread row) publishes
    /// idempotent state events while the snapshot is read: one
    /// `surface.renamed` and one `agent.thread.updated` every 2 ms.
    @MainActor
    func test_receipt_syncSnapshot_underTitleAndThreadUpdates() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        let workspace = fixture.workspaces[0].value.uuidString
        let surface = UUID().uuidString
        let thread = UUID().uuidString
        let churn = ChurnLoop()
        let churnThread = Thread {
            var frame = 0
            while churn.isRunning {
                frame += 1
                EventBus.shared.publish(kind: .surfaceRenamed, payload: .object([
                    "workspace_id": .string(workspace),
                    "id": .string(surface),
                    "title": .string("◐ build \(frame)"),
                ]))
                EventBus.shared.publish(kind: .agentThreadUpdated, payload: .object([
                    "thread_id": .string(thread),
                    "has_unread": .bool(frame % 2 == 0),
                ]))
                Thread.sleep(forTimeInterval: 0.002)
            }
            churn.finished()
        }
        churnThread.start()
        defer { churn.stopAndWait() }

        var latency: [Double] = []
        var succeeded = 0
        var failedCodes: [Int] = []
        for index in 0..<(Self.warmups + Self.samples) {
            let sample = try await Self.rpc(fixture, params: Self.fullParams)
            guard index >= Self.warmups else { continue }
            latency.append(sample.latency)
            if let code = sample.errorCode { failedCodes.append(code) } else { succeeded += 1 }
        }
        Self.report("sync_snapshot_under_title_and_thread_updates_2ms", latency, extra: [
            "calls": latency.count,
            "succeeded": succeeded,
            "failed_codes": failedCodes,
        ])
    }

    /// Opt-in bounded thread window: 5 recent threads per workspace plus the
    /// running ones. An old host rejects the unknown parameter.
    @MainActor
    func test_receipt_syncSnapshot_boundedThreads() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        var latency: [Double] = []
        var bytes = 0
        var errorCode: Int?
        for index in 0..<(Self.warmups + Self.samples) {
            let sample = try await Self.rpc(fixture, params: Self.boundedParams)
            errorCode = sample.errorCode
            if index >= Self.warmups {
                latency.append(sample.latency)
                bytes = sample.bytes
            }
        }
        Self.report("sync_snapshot_bounded_threads_5_per_workspace", latency, extra: [
            "response_bytes": bytes,
            "error_code": errorCode ?? 0,
        ])
    }

    // MARK: - Helpers

    private final class ChurnLoop: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private let done = DispatchSemaphore(value: 0)
        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
        func finished() { done.signal() }
        func stopAndWait() {
            lock.lock(); running = false; lock.unlock()
            done.wait()
        }
    }

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

    private static func ms(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }

    private static func startMainStallProbe() -> () async -> Double {
        let probe = MainStallProbe()
        let poller = Task.detached(priority: .userInitiated) {
            while probe.isRunning {
                let t0 = DispatchTime.now()
                await MainActor.run {}
                probe.record(ms(since: t0))
                try? await Task.sleep(nanoseconds: 250_000)
            }
        }
        return {
            let worst = probe.stop()
            await poller.value
            return worst
        }
    }

    private static func rpc(_ fixture: Fixture, params: [String: Any]) async throws -> Sample {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(fixture.port)/v1/rpc")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(fixture.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "sync.snapshot", "params": params,
        ])
        let t0 = DispatchTime.now()
        let (data, response) = try await URLSession.shared.data(for: request)
        let latency = ms(since: t0)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let code = (object?["error"] as? [String: Any])?["code"] as? Int
        return Sample(latency: latency, errorCode: code, bytes: data.count)
    }

    private static func report(_ name: String, _ samples: [Double], extra: [String: Any] = [:]) {
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let index = min(sorted.count - 1, Int((p * Double(sorted.count - 1)).rounded()))
            return sorted[index]
        }
        let rounded = samples.map { ($0 * 1000).rounded() / 1000 }
        var payload: [String: Any] = [
            "scenario": name,
            "n": samples.count,
            "p50_ms": (percentile(0.5) * 1000).rounded() / 1000,
            "p95_ms": (percentile(0.95) * 1000).rounded() / 1000,
            "max_ms": ((sorted.last ?? 0) * 1000).rounded() / 1000,
            "samples_ms": rounded,
        ]
        payload.merge(extra) { _, new in new }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        print("RECEIPT \(String(decoding: data, as: UTF8.self))")
    }
}
