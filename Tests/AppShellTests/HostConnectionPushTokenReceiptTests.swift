import XCTest
@testable import AppShell
@testable import CoreModel
@testable import SocketServer
@testable import Persistence

/// C4 perf receipts: `private.push_token.update` re-sent unchanged on reconnect.
///
/// Opt-in measurement, not a pass/fail gate: run with
/// `RC_HOST_CONN_RECEIPTS=1 scripts/isolated-sandbox.sh test --filter HostConnectionPushTokenReceiptTests`.
/// File-backed AppContext (writer + WAL reader), production LocalAuthAdapter,
/// AppCommandRouter, JSONRPCDispatcher and a real DirectHTTPServer over loopback
/// TCP with a paired bearer. Every sample is a new `client_request_id` with the
/// same token, device and profile, which is what an iPhone sends on reconnect.
/// Only APIs present before C4 are used, so the same file measures both sides.
final class HostConnectionPushTokenReceiptTests: XCTestCase {
    private static let idleWarmups = 5
    private static let idleSamples = 30
    private static let heldWarmups = 2
    private static let heldSamples = 7
    private static let writerHoldSeconds: TimeInterval = 0.25
    private static let requestDelayIntoHoldSeconds: TimeInterval = 0.02

    private struct Fixture {
        let context: AppContext
        let server: DirectHTTPServer
        let token: String
        let port: UInt16
    }

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["RC_HOST_CONN_RECEIPTS"] == "1" else {
            throw XCTSkip("set RC_HOST_CONN_RECEIPTS=1 to record host-connection receipts")
        }
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let dir = NSTemporaryDirectory() + "RC2PushTokenReceipt-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: context)
        context.router = router
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
                return Fixture(context: context, server: server, token: paired.token, port: port)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "receipt", code: 1)
    }

    private static let pushParams: [String: Any] = [
        "push_token": "receipt-apns-token-0123456789abcdef",
        "push_token_type": "apns",
        "device_id": "receipt-device",
        "live_activity_token": "receipt-la-token",
        "profile_id": "receipt-profile",
    ]

    @MainActor
    func test_receipt_pushTokenUnchanged_idle() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        var sequence = 0
        // First registration always takes the full path.
        _ = try await Self.pushUpdate(fixture, sequence: &sequence)
        let receiptsBefore = try Self.scalar(fixture.context.db, Self.receiptCountSQL)
        let eventsBefore = try Self.scalar(fixture.context.db, Self.eventCountSQL)
        for _ in 0..<Self.idleWarmups { _ = try await Self.pushUpdate(fixture, sequence: &sequence) }
        var samples: [Double] = []
        for _ in 0..<Self.idleSamples {
            samples.append(try await Self.pushUpdate(fixture, sequence: &sequence))
        }
        EventBus.shared.flushPersistenceSubmissions()
        try await Task.sleep(nanoseconds: 300_000_000)
        let reconnects = Self.idleWarmups + Self.idleSamples
        Self.report("push_token_update_unchanged_idle", samples, extra: [
            "unchanged_requests": reconnects,
            "new_receipts": try Self.scalar(fixture.context.db, Self.receiptCountSQL) - receiptsBefore,
            "new_persisted_events": try Self.scalar(fixture.context.db, Self.eventCountSQL) - eventsBefore,
        ])
    }

    /// A rotated token every time: the full path runs before and after C4, so
    /// this is the regression check for the probe the short-circuit adds.
    @MainActor
    func test_receipt_pushTokenRotating_idle() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        var sequence = 0
        for _ in 0..<Self.idleWarmups {
            _ = try await Self.pushUpdate(fixture, sequence: &sequence, rotate: true)
        }
        var samples: [Double] = []
        for _ in 0..<Self.idleSamples {
            samples.append(try await Self.pushUpdate(fixture, sequence: &sequence, rotate: true))
        }
        Self.report("push_token_update_rotating_idle", samples)
    }

    /// Another thread holds the writer for 250 ms (stream batch, receipt
    /// finalize, pruning). Before C4 the unchanged update had to claim a receipt
    /// on the writer and wait it out.
    @MainActor
    func test_receipt_pushTokenUnchanged_whileInProcessWriterHeld() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        var sequence = 0
        _ = try await Self.pushUpdate(fixture, sequence: &sequence)
        var samples: [Double] = []
        for index in 0..<(Self.heldWarmups + Self.heldSamples) {
            let released = Self.holdWriter(fixture.context.db, hold: Self.writerHoldSeconds)
            try await Task.sleep(nanoseconds: UInt64(Self.requestDelayIntoHoldSeconds * 1_000_000_000))
            let latency = try await Self.pushUpdate(fixture, sequence: &sequence)
            await Self.waitForRelease(released)
            if index >= Self.heldWarmups { samples.append(latency) }
        }
        Self.report("push_token_update_unchanged_writer_held_250ms", samples)
    }

    // MARK: - Helpers

    private static let receiptCountSQL =
        "SELECT COUNT(*) FROM command_receipts WHERE method = 'private.push_token.update';"
    private static let eventCountSQL =
        "SELECT COUNT(*) FROM events WHERE kind = 'private.push_token.updated';"

    private static func scalar(_ db: SQLiteDB, _ sql: String) throws -> Int64 {
        let statement = try db.prepare(sql)
        _ = try statement.step()
        return statement.columnInt64(0)
    }

    private static func pushUpdate(
        _ fixture: Fixture,
        sequence: inout Int,
        rotate: Bool = false
    ) async throws -> Double {
        sequence += 1
        var params = pushParams
        if rotate { params["push_token"] = "receipt-apns-token-\(sequence)-\(UUID().uuidString)" }
        params["client_request_id"] = "receipt-push-\(UUID().uuidString.lowercased())"
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(fixture.port)/v1/rpc")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(fixture.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": sequence, "method": "private.push_token.update", "params": params,
        ])
        let t0 = DispatchTime.now()
        let (data, response) = try await URLSession.shared.data(for: request)
        let latency = ms(since: t0)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(object?["error"], "push_token.update failed: \(String(decoding: data, as: UTF8.self).prefix(300))")
        return latency
    }

    private static func ms(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }

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

    private static func report(_ name: String, _ samples: [Double], extra: [String: Any] = [:]) {
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let index = min(sorted.count - 1, Int((p * Double(sorted.count - 1)).rounded()))
            return sorted[index]
        }
        var payload: [String: Any] = [
            "scenario": name,
            "n": samples.count,
            "p50_ms": (percentile(0.5) * 1000).rounded() / 1000,
            "p95_ms": (percentile(0.95) * 1000).rounded() / 1000,
            "max_ms": ((sorted.last ?? 0) * 1000).rounded() / 1000,
            "samples_ms": samples.map { ($0 * 1000).rounded() / 1000 },
        ]
        for (key, value) in extra { payload[key] = value }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        print("RECEIPT \(String(decoding: data, as: UTF8.self))")
    }
}
