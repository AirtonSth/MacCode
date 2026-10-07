import Darwin
import XCTest
@testable import AppShell
@testable import CoreModel
@testable import SocketServer
@testable import Persistence

/// C9 perf receipts (host connection: the in-flight `/v1/rpc` disconnect
/// watchdog, plus settled RPC latency as a regression check).
///
/// The rejected C9 sub-changes (TCP_NODELAY, writev, WS gathered drain,
/// TaskGroup batches) were measured with an interleaved A/B build of this
/// harness; that instrumentation lives in
/// `docs/perf-receipts/host-connection/c9-ab-instrumentation.diff`.
///
/// Opt-in measurement, not a pass/fail gate: run with
/// `RC_HOST_CONN_RECEIPTS=1 scripts/isolated-sandbox.sh test --filter HostConnectionTransportReceiptTests`.
/// A file-backed AppContext, the production AppCommandRouter and
/// JSONRPCDispatcher, and a real DirectHTTPServer over loopback TCP with a
/// paired bearer. The client is URLSession (the iOS transport). Each scenario
/// discards warm-up samples and prints one `RECEIPT {json}` line.
final class HostConnectionTransportReceiptTests: XCTestCase {
    private struct Fixture {
        let context: AppContext
        let server: DirectHTTPServer
        let token: String
        let port: UInt16
        let threads: [AgentThreadID]
    }

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["RC_HOST_CONN_RECEIPTS"] == "1" else {
            throw XCTSkip("set RC_HOST_CONN_RECEIPTS=1 to record host-connection receipts")
        }
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let dir = NSTemporaryDirectory() + "RC2HostConnC9Receipt-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: context)
        context.router = router
        let repo = DeviceTrustRepository(db: context.db)
        let code = try repo.createPairingCode()
        let paired = try XCTUnwrap(repo.redeemPairingCode(code.code, deviceName: "Receipt iPhone"))
        let auth = LocalAuthAdapter(repo: DeviceTrustRepository(db: context.db))
        // 150 threads; the newest carries a 100-message transcript.
        var threads: [AgentThreadID] = []
        for index in 0..<150 {
            var thread = AgentThread(title: "receipt thread \(index)", provider: .codex, model: "gpt-5")
            thread.updatedAt = Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(index))
            try context.threadRepo.upsert(thread)
            if index == 149 { threads.append(thread.id) }
        }
        for index in 0..<100 {
            try context.messageRepo.append(AgentMessage(
                threadId: threads[0],
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: String(repeating: "receipt message \(index) body. ", count: 40),
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
                return Fixture(context: context, server: server, token: paired.token, port: port, threads: threads)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "receipt", code: 1)
    }

    // MARK: - HTTP request/response (settled-latency regression check)

    /// Small response on a reused keep-alive connection.
    @MainActor
    func test_receipt_rpcPing_keepAlive() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        for _ in 0..<10 { _ = try await Self.rpc(fixture, method: "system.ping") }
        var samples: [Double] = []
        for _ in 0..<60 { samples.append(try await Self.rpc(fixture, method: "system.ping")) }
        Self.report("rpc_system_ping_keepalive", samples)
    }

    /// Larger response body (50 messages).
    @MainActor
    func test_receipt_rpcMessagePage_keepAlive() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        let params: [String: Any] = [
            "thread_id": fixture.threads[0].value.uuidString, "limit": 50, "pagination": true,
        ]
        for _ in 0..<5 { _ = try await Self.rpc(fixture, method: "agent.message.list", params: params) }
        var samples: [Double] = []
        for _ in 0..<30 {
            samples.append(try await Self.rpc(fixture, method: "agent.message.list", params: params))
        }
        Self.report("rpc_agent_message_page_50_keepalive", samples)
    }

    // MARK: - In-flight RPC watchdog

    /// Eight RPCs wait on a busy main actor for one second (a long synchronous
    /// main-thread stretch). Records process CPU and context switches spent
    /// while they wait; the main thread itself is asleep.
    @MainActor
    func test_receipt_inflightRPCs_whileMainBlocked() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        for _ in 0..<3 { _ = try await Self.rpc(fixture, method: "system.ping") }
        var cpu: [Double] = []
        var switches: [Double] = []
        for round in 0..<(2 + 7) {
            let tasks = (0..<8).map { _ in
                Task.detached { try await Self.rpc(fixture, method: "system.ping") }
            }
            Thread.sleep(forTimeInterval: 0.1)
            let r0 = Self.usage()
            Thread.sleep(forTimeInterval: 1.0)
            let r1 = Self.usage()
            for task in tasks { _ = try await task.value }
            if round >= 2 {
                cpu.append(r1.cpuMs - r0.cpuMs)
                switches.append(r1.switches - r0.switches)
            }
        }
        Self.report("inflight_rpc_x8_main_blocked_1s_process_cpu_ms", cpu)
        Self.report("inflight_rpc_x8_main_blocked_1s_context_switches", switches)
    }

    /// A peer drops while its RPC waits on a blocked main actor. Measures drop
    /// → socket released by the watchdog.
    @MainActor
    func test_receipt_peerDropMidRPC_releaseLatency() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        var samples: [Double] = []
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "system.ping", "params": [:] as [String: Any],
        ])
        for round in 0..<(2 + 7) {
            let baseline = fixture.server.acceptedSocketCountForTests
            let fd = try Self.rawConnect(port: fixture.port)
            let request = "POST /v1/rpc HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(fixture.token)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
            var bytes = Data(request.utf8)
            bytes.append(body)
            // Main stays blocked (sleep + busy wait below), so the RPC is in
            // flight when the peer drops.
            _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            Thread.sleep(forTimeInterval: 0.05)
            let t0 = DispatchTime.now()
            Darwin.close(fd)
            var released: Double = -1
            while Self.ms(since: t0) < 500 {
                if fixture.server.acceptedSocketCountForTests <= baseline {
                    released = Self.ms(since: t0)
                    break
                }
                usleep(100)
            }
            XCTAssertGreaterThanOrEqual(released, 0, "socket never released")
            if round >= 2 { samples.append(released) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Self.report("peer_drop_mid_rpc_release_ms", samples)
    }

    // MARK: - Helpers

    private static func usage() -> (cpuMs: Double, switches: Double) {
        var r = rusage()
        getrusage(RUSAGE_SELF, &r)
        let user = Double(r.ru_utime.tv_sec) * 1_000 + Double(r.ru_utime.tv_usec) / 1_000
        let system = Double(r.ru_stime.tv_sec) * 1_000 + Double(r.ru_stime.tv_usec) / 1_000
        return (user + system, Double(r.ru_nvcsw + r.ru_nivcsw))
    }

    private static func ms(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }

    private static func rawConnect(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw NSError(domain: "receipt", code: Int(errno)) }
        return fd
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

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int((p * Double(sorted.count - 1)).rounded()))
        return sorted[index]
    }

    private static func report(_ name: String, _ samples: [Double]) {
        let sorted = samples.sorted()
        var payload: [String: Any] = [
            "scenario": name,
            "n": samples.count,
            "p50_ms": (percentile(sorted, 0.5) * 1000).rounded() / 1000,
            "p95_ms": (percentile(sorted, 0.95) * 1000).rounded() / 1000,
            "max_ms": ((sorted.last ?? 0) * 1000).rounded() / 1000,
        ]
        payload["samples_ms"] = samples.map { ($0 * 1000).rounded() / 1000 }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        // Unbuffered: a killed run must not lose receipts already taken.
        FileHandle.standardError.write(Data("RECEIPT \(String(decoding: data, as: UTF8.self))\n".utf8))
    }
}
