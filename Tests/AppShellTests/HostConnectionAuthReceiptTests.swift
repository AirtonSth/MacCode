import XCTest
@testable import AppShell
@testable import CoreModel
@testable import SocketServer
@testable import Persistence

/// C3 perf receipts (host connection: auth principal + read gateways).
///
/// Opt-in measurement, not a pass/fail gate: run with
/// `RC_HOST_CONN_RECEIPTS=1 scripts/isolated-sandbox.sh test --filter HostConnectionAuthReceiptTests`.
/// Every scenario uses a file-backed AppContext (writer + WAL reader, the same
/// wiring the app uses), the production LocalAuthAdapter, the production
/// AppCommandRouter + JSONRPCDispatcher and a real DirectHTTPServer over
/// loopback TCP with a bearer. Each scenario discards warm-up samples and prints
/// one `RECEIPT {json}` line with raw samples plus p50/p95/max in milliseconds.
final class HostConnectionAuthReceiptTests: XCTestCase {
    private static let warmups = 2
    private static let heldSamples = 7
    private static let idleSamples = 30
    private static let writerHoldSeconds: TimeInterval = 0.25
    private static let requestDelayIntoHoldSeconds: TimeInterval = 0.02

    private struct Fixture {
        let context: AppContext
        let router: AppCommandRouter
        let server: DirectHTTPServer
        let auth: LocalAuthAdapter
        let token: String
        let port: UInt16
        let threadID: AgentThreadID
    }

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["RC_HOST_CONN_RECEIPTS"] == "1" else {
            throw XCTSkip("set RC_HOST_CONN_RECEIPTS=1 to record host-connection receipts")
        }
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let dir = NSTemporaryDirectory() + "RC2HostConnReceipt-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: context)
        context.router = router
        let repo = DeviceTrustRepository(db: context.db)
        let code = try repo.createPairingCode()
        let paired = try XCTUnwrap(repo.redeemPairingCode(code.code, deviceName: "Receipt iPhone"))
        let auth = LocalAuthAdapter(repo: DeviceTrustRepository(db: context.db))
        // Realistic rail: 150 threads, one with a full 100-message transcript.
        var transcriptThread: AgentThread?
        for index in 0..<150 {
            var thread = AgentThread(title: "receipt thread \(index)", provider: .codex, model: "gpt-5")
            thread.updatedAt = Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(index))
            try context.threadRepo.upsert(thread)
            if index == 149 { transcriptThread = thread }
        }
        let thread = try XCTUnwrap(transcriptThread)
        for index in 0..<100 {
            let body = String(repeating: "receipt message \(index) body. ", count: 40)
            try context.messageRepo.append(AgentMessage(
                threadId: thread.id,
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: body,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(index))
            ))
        }
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
                    auth: auth,
                    token: paired.token,
                    port: port,
                    threadID: thread.id
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "receipt", code: 1)
    }

    // MARK: - Scenarios

    /// Adapter-level principal resolution with nothing else touching SQLite.
    @MainActor
    func test_receipt_authPrincipal_idle() throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        for _ in 0..<5 { _ = fixture.auth.authorizedRPCPrincipal(token: fixture.token) }
        var samples: [Double] = []
        for _ in 0..<200 {
            let t0 = DispatchTime.now()
            XCTAssertNotNil(fixture.auth.authorizedRPCPrincipal(token: fixture.token))
            samples.append(Self.ms(since: t0))
        }
        Self.report("auth_principal_idle", samples)
    }

    /// The writer connection is inside a long transaction on another thread
    /// (stream batch, receipt finalize, pruning). Principal resolution must not
    /// wait for it.
    @MainActor
    func test_receipt_authPrincipal_whileInProcessWriterHeld() throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        _ = fixture.auth.authorizedRPCPrincipal(token: fixture.token)
        var samples: [Double] = []
        for index in 0..<(Self.warmups + Self.heldSamples) {
            let latency = Self.whileWriterHeld(fixture.context.db) {
                let t0 = DispatchTime.now()
                XCTAssertNotNil(fixture.auth.authorizedRPCPrincipal(token: fixture.token))
                return Self.ms(since: t0)
            }
            if index >= Self.warmups { samples.append(latency) }
        }
        Self.report("auth_principal_in_process_writer_held_250ms", samples)
    }

    /// Another connection (helper process / second app connection) holds the
    /// SQLite write lock while this device's last_seen_at is more than a minute
    /// old, so the request path owes a last_seen write. A fresh adapter per
    /// sample models the first request after the cache window.
    @MainActor
    func test_receipt_authPrincipal_firstRequestOfMinute_whileOtherConnectionHoldsWriteLock() throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        let other = try SQLiteDB(path: fixture.context.db.path)
        var samples: [Double] = []
        for index in 0..<(Self.warmups + Self.heldSamples) {
            try fixture.context.db.execute(
                "UPDATE device_trust SET last_seen_at = '2001-01-01T00:00:00Z';"
            )
            let adapter = LocalAuthAdapter(repo: DeviceTrustRepository(db: fixture.context.db))
            let latency = Self.whileWriterHeld(other, hold: 1.0) {
                let t0 = DispatchTime.now()
                XCTAssertNotNil(adapter.authorizedRPCPrincipal(token: fixture.token))
                return Self.ms(since: t0)
            }
            if index >= Self.warmups { samples.append(latency) }
        }
        Self.report("auth_principal_first_of_minute_other_conn_write_lock_1000ms", samples)
    }

    /// End-to-end /v1/rpc with a bearer, nothing else running: regression check.
    @MainActor
    func test_receipt_rpcPing_idle() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        for _ in 0..<5 { _ = try await Self.rpc(fixture, method: "system.ping") }
        var samples: [Double] = []
        for _ in 0..<Self.idleSamples {
            samples.append(try await Self.rpc(fixture, method: "system.ping"))
        }
        Self.report("rpc_system_ping_idle", samples)
    }

    @MainActor
    func test_receipt_rpcThreadList_idle() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        for _ in 0..<5 { _ = try await Self.rpc(fixture, method: "agent.thread.list") }
        var samples: [Double] = []
        for _ in 0..<Self.idleSamples {
            samples.append(try await Self.rpc(fixture, method: "agent.thread.list"))
        }
        Self.report("rpc_agent_thread_list_150_idle", samples)
    }

    @MainActor
    func test_receipt_rpcMessagePage_idle() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        let params: [String: Any] = [
            "thread_id": fixture.threadID.value.uuidString, "limit": 50, "pagination": true,
        ]
        for _ in 0..<5 { _ = try await Self.rpc(fixture, method: "agent.message.list", params: params) }
        var samples: [Double] = []
        for _ in 0..<Self.idleSamples {
            samples.append(try await Self.rpc(fixture, method: "agent.message.list", params: params))
        }
        Self.report("rpc_agent_message_page_50_idle", samples)
    }

    @MainActor
    func test_receipt_rpcPing_whileInProcessWriterHeld() async throws {
        try await heldRPCReceipt(name: "rpc_system_ping_in_process_writer_held_250ms", method: "system.ping")
    }

    @MainActor
    func test_receipt_rpcThreadList_whileInProcessWriterHeld() async throws {
        try await heldRPCReceipt(name: "rpc_agent_thread_list_150_in_process_writer_held_250ms", method: "agent.thread.list")
    }

    @MainActor
    func test_receipt_rpcMessagePage_whileInProcessWriterHeld() async throws {
        try await heldRPCReceipt(
            name: "rpc_agent_message_page_50_in_process_writer_held_250ms",
            method: "agent.message.list",
            params: { ["thread_id": $0.threadID.value.uuidString, "limit": 50, "pagination": true] }
        )
    }

    @MainActor
    private func heldRPCReceipt(
        name: String,
        method: String,
        params: (Fixture) -> [String: Any] = { _ in [:] }
    ) async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        let body = params(fixture)
        _ = try await Self.rpc(fixture, method: method, params: body)
        var samples: [Double] = []
        for index in 0..<(Self.warmups + Self.heldSamples) {
            let released = Self.holdWriter(fixture.context.db, hold: Self.writerHoldSeconds)
            try await Task.sleep(nanoseconds: UInt64(Self.requestDelayIntoHoldSeconds * 1_000_000_000))
            let latency = try await Self.rpc(fixture, method: method, params: body)
            await Self.waitForRelease(released)
            if index >= Self.warmups { samples.append(latency) }
        }
        Self.report(name, samples)
    }

    // MARK: - Helpers

    private static func ms(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }

    /// Opens BEGIN IMMEDIATE on `db` from another thread and keeps the
    /// connection's operation gate for `hold` seconds.
    private static func holdWriter(_ db: SQLiteDB, hold: TimeInterval) -> DispatchSemaphore {
        let started = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            db.performSync { connection in
                try? connection.execute("BEGIN IMMEDIATE;")
                started.signal()
                Thread.sleep(forTimeInterval: hold)
                try? connection.execute("COMMIT;")
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

    private static func whileWriterHeld(
        _ db: SQLiteDB,
        hold: TimeInterval = writerHoldSeconds,
        _ body: () -> Double
    ) -> Double {
        let released = holdWriter(db, hold: hold)
        Thread.sleep(forTimeInterval: requestDelayIntoHoldSeconds)
        let value = body()
        released.wait()
        return value
    }

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
