import XCTest
@testable import AppShell
@testable import CoreModel
@testable import SocketServer
@testable import Persistence

/// C6 perf receipts (host connection: durable receipt claim/finalize pipeline).
///
/// Opt-in measurement, not a pass/fail gate: run with
/// `RC_HOST_CONN_RECEIPTS=1 scripts/isolated-sandbox.sh test --filter HostConnectionReceiptPipelineReceiptTests`.
/// Every scenario uses a file-backed AppContext with the production event
/// persister wired to `EventBus.shared`, the production AppCommandRouter and
/// JSONRPCDispatcher, and a real DirectHTTPServer over loopback TCP with a
/// paired bearer. The mutation is `workspace.rename`, which takes the full
/// path: durable claim, effect, one captured event, finalize with the commit
/// fence. It only uses API that exists before and after C6, so the same file
/// produces both receipts.
///
/// "Main stall" is the longest a MainActor hop issued from a background task
/// waited while one request was in flight.
final class HostConnectionReceiptPipelineReceiptTests: XCTestCase {
    private static let warmups = 2
    private static let heldSamples = 7
    private static let idleSamples = 30
    private static let holdSeconds: TimeInterval = 0.25
    private static let requestDelayIntoHoldSeconds: TimeInterval = 0.02

    private struct Fixture {
        let context: AppContext
        let router: AppCommandRouter
        let server: DirectHTTPServer
        let token: String
        let port: UInt16
        let workspace: WorkspaceID
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
        let dir = NSTemporaryDirectory() + "RC2HostConnC6Receipt-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: context)
        context.router = router
        AppDelegate.wireEventPersistence(context: context)
        let workspace = try router.listWorkspaces().first?.id
            ?? router.createWorkspace(name: "Receipt", cwd: dir).id
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
                    workspace: workspace
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "receipt", code: 1)
    }

    private static func renameParams(_ fixture: Fixture, index: Int) -> [String: Any] {
        [
            "client_request_id": "receipt-rename-\(index)-\(UUID().uuidString)",
            "id": fixture.workspace.value.uuidString,
            "name": "Receipt \(index)",
        ]
    }

    // MARK: - Scenarios

    @MainActor
    func test_receipt_workspaceRename_idle() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        for index in 0..<5 {
            _ = try await Self.rpc(fixture, method: "workspace.rename", params: Self.renameParams(fixture, index: -1 - index))
        }
        var latency: [Double] = []
        var stall: [Double] = []
        for index in 0..<Self.idleSamples {
            let sample = try await Self.rpcWithMainStall(
                fixture,
                method: "workspace.rename",
                params: Self.renameParams(fixture, index: index)
            )
            latency.append(sample.latency)
            stall.append(sample.mainStall)
        }
        Self.report("rpc_workspace_rename_idle", latency)
        Self.report("main_stall_workspace_rename_idle", stall)
    }

    /// Unrelated work (a long snapshot save or storage cleanup) occupies the
    /// utility writer queue for 250 ms. Before C6 the finalize fence drained
    /// that whole queue.
    @MainActor
    func test_receipt_workspaceRename_writerQueueBusy() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        try await heldReceipt(fixture, name: "workspace_rename_writer_queue_busy_250ms") {
            let started = DispatchSemaphore(value: 0)
            let released = DispatchSemaphore(value: 0)
            fixture.context.backgroundWriterQueue.async {
                started.signal()
                Thread.sleep(forTimeInterval: Self.holdSeconds)
                released.signal()
            }
            started.wait()
            return released
        }
    }

    /// Another thread holds the SQLite writer for 250 ms (a long stream flush
    /// or prune). Before C6 the claim waited for it on MainActor.
    @MainActor
    func test_receipt_workspaceRename_sqliteWriterHeld() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        let db = fixture.context.db
        try await heldReceipt(fixture, name: "workspace_rename_sqlite_writer_held_250ms") {
            let started = DispatchSemaphore(value: 0)
            let released = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                db.performSync { _ in
                    started.signal()
                    Thread.sleep(forTimeInterval: Self.holdSeconds)
                }
                released.signal()
            }
            started.wait()
            return released
        }
    }

    @MainActor
    private func heldReceipt(
        _ fixture: Fixture,
        name: String,
        hold: () -> DispatchSemaphore
    ) async throws {
        _ = try await Self.rpc(fixture, method: "workspace.rename", params: Self.renameParams(fixture, index: -1))
        var latency: [Double] = []
        var stall: [Double] = []
        for index in 0..<(Self.warmups + Self.heldSamples) {
            let released = hold()
            try await Task.sleep(nanoseconds: UInt64(Self.requestDelayIntoHoldSeconds * 1_000_000_000))
            let sample = try await Self.rpcWithMainStall(
                fixture,
                method: "workspace.rename",
                params: Self.renameParams(fixture, index: index)
            )
            await Self.waitForRelease(released)
            if index >= Self.warmups {
                latency.append(sample.latency)
                stall.append(sample.mainStall)
            }
        }
        Self.report("rpc_" + name, latency)
        Self.report("main_stall_" + name, stall)
    }

    // MARK: - Helpers (same probe and report format as the C5 harness)

    private static func ms(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }

    private static func waitForRelease(_ released: DispatchSemaphore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                released.wait()
                continuation.resume()
            }
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
