import XCTest
@testable import AppShell
@testable import CoreModel
@testable import SocketServer
@testable import Persistence

/// C8 perf receipts (host connection: durable replay on resume).
///
/// Opt-in measurement, not a pass/fail gate: run with
/// `RC_HOST_CONN_RECEIPTS=1 scripts/isolated-sandbox.sh test --filter HostConnectionDurableReplayReceiptTests`.
/// A file-backed AppContext with the production event persister, the
/// production AppCommandRouter and JSONRPCDispatcher, and a real
/// DirectHTTPServer over loopback TCP with a paired bearer. The host holds
/// 9 workspaces x 20 agent threads (the snapshot a baseline costs).
///
/// Each sample simulates an iPhone that saw through `cursor`, then was away
/// for 5 minutes or 1 hour while the host kept the live event mix: 32.5
/// agent deltas/s on two streaming threads and 0.5 persisted state events/s
/// (the live DB: about 33 events/s, about 5000 persisted rows per 2h49m).
/// The client then reconnects with its cursor and the opt-in header and
/// follows what iOS does: on `replayFromSequence == cursor` it reads until
/// `replayComplete`; otherwise (baselineRequired) it calls `sync.snapshot`.
/// "Time to live" runs from the upgrade request to the last byte it needs.
/// The file only uses raw HTTP/WS, so the same source runs before and after
/// C8 (before C8 the header is ignored and every sample takes the snapshot).
final class HostConnectionDurableReplayReceiptTests: XCTestCase {
    private static let warmups = 3
    private static let samples = 7
    private static let workspaceCount = 9
    private static let threadsPerWorkspace = 20

    private struct Fixture {
        let context: AppContext
        let server: DirectHTTPServer
        let token: String
        let port: UInt16
        let workspace: String
    }

    private struct Sample {
        let timeToLiveMs: Double
        let bytes: Int
        let path: String
        let replayedEvents: Int
        let streamGaps: Int
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
        let dir = NSTemporaryDirectory() + "RC2HostConnC8Receipt-" + UUID().uuidString
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
                    context: context, server: server, token: paired.token, port: port,
                    workspace: workspaces[0].value.uuidString
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "receipt", code: 1)
    }

    // MARK: - Scenarios

    @MainActor
    func test_receipt_resumeAfter5MinuteGap_durable() async throws {
        try await runCell(name: "resume_after_5_min_gap", seconds: 300, durable: true)
    }

    @MainActor
    func test_receipt_resumeAfter1HourGap_durable() async throws {
        try await runCell(name: "resume_after_1_h_gap", seconds: 3_600, durable: true)
    }

    @MainActor
    func test_receipt_resumeAfter5MinuteGap_legacyClient() async throws {
        try await runCell(name: "resume_after_5_min_gap_legacy_client", seconds: 300, durable: false)
    }

    @MainActor
    private func runCell(name: String, seconds: Int, durable: Bool) async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        var samples: [Sample] = []
        for index in 0..<(Self.warmups + Self.samples) {
            let cursor = EventBus.shared.currentSeq
            Self.simulateGap(seconds: seconds, workspace: fixture.workspace, round: index)
            fixture.context.flushEventPersistence()
            let sample = try await Self.resume(fixture, cursor: cursor, durable: durable)
            if index >= Self.warmups { samples.append(sample) }
        }
        let latencies = samples.map(\.timeToLiveMs)
        Self.report(name, latencies, extra: [
            "header_sent": durable,
            "paths": samples.map(\.path),
            "bytes": samples.map(\.bytes),
            "bytes_p50": samples.map(\.bytes).sorted()[samples.count / 2],
            "replayed_events": samples.map(\.replayedEvents),
            "stream_gaps": samples.map(\.streamGaps),
        ])
    }

    // MARK: - Workload

    /// One simulated second: 32-33 deltas over two streaming threads, plus a
    /// persisted state event every other second, rotating the kinds that
    /// dominate the live event log.
    private static func simulateGap(seconds: Int, workspace: String, round: Int) {
        let bus = EventBus.shared
        let threads = ["receipt-stream-a-\(round)", "receipt-stream-b-\(round)"]
        let text = String(repeating: "token ", count: 12)
        for second in 0..<seconds {
            let deltas = second % 2 == 0 ? 32 : 33
            for index in 0..<deltas {
                let thread = threads[index % 2]
                bus.publish(kind: .agentItemDelta, payload: .object([
                    "thread_id": .string(thread),
                    "item_id": .string("item-\(thread)-\(second / 60)"),
                    "delta": .string(text),
                ]))
            }
            guard second % 2 == 0 else { continue }
            let thread = threads[(second / 2) % 2]
            switch (second / 2) % 4 {
            case 0:
                bus.publish(kind: .agentThreadUpdated, payload: .object([
                    "thread_id": .string(thread), "workspace_id": .string(workspace),
                    "has_unread": .bool(true), "status": .string("running"),
                    "updated_at": .string("2026-10-07T01:00:00Z"),
                ]))
            case 1:
                bus.publish(kind: .agentThreadTokenUsage, payload: .object([
                    "thread_id": .string(thread), "input_tokens": .number(120_000),
                    "output_tokens": .number(4_200), "cached_input_tokens": .number(98_000),
                    "context_window": .number(400_000),
                ]))
            case 2:
                bus.publish(kind: .surfaceRenamed, payload: .object([
                    "workspace_id": .string(workspace), "id": .string("surface-\(round)"),
                    "title": .string("npm run test -- --watch"),
                ]))
            default:
                bus.publish(kind: .agentItemCompleted, payload: .object([
                    "thread_id": .string(thread), "item_id": .string("item-\(thread)-\(second / 60)"),
                    "kind": .string("assistant_message"),
                    "text": .string(String(repeating: "The change is in place and the tests pass. ", count: 8)),
                ]))
            }
        }
    }

    // MARK: - Client

    private final class ByteCounter: @unchecked Sendable {
        var bytes = 0
    }

    private static func resume(_ fixture: Fixture, cursor: Int64, durable: Bool) async throws -> Sample {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(fixture.port)/v1/ws")!)
        request.setValue("Bearer \(fixture.token)", forHTTPHeaderField: "Authorization")
        request.setValue("\(cursor)", forHTTPHeaderField: "X-RC2-Since-Seq")
        request.setValue("receipt-host", forHTTPHeaderField: "X-RC2-Resume-Host-Id")
        request.setValue("1", forHTTPHeaderField: "X-RC2-Resume-Boot-Epoch")
        if durable { request.setValue("v1", forHTTPHeaderField: "X-RC2-Durable-Replay") }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let t0 = DispatchTime.now()
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 8 * 1_024 * 1_024
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        var bytes = 0
        func next() async throws -> [String: Any] {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .data(let value): data = value
            case .string(let value): data = Data(value.utf8)
            @unknown default: data = Data()
            }
            bytes += data.count
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        let welcome = try await next()
        let replayFrom = (welcome["replayFromSequence"] as? NSNumber)?.int64Value
        if replayFrom == cursor {
            var events = 0
            var gaps = 0
            while true {
                let frame = try await next()
                switch frame["type"] as? String {
                case "event": events += 1
                case "streamGap": gaps += 1
                case "replayComplete":
                    return Sample(timeToLiveMs: ms(since: t0), bytes: bytes, path: "durable_replay",
                                  replayedEvents: events, streamGaps: gaps)
                case "baselineRequired":
                    let snapshotBytes = try await snapshot(fixture)
                    return Sample(timeToLiveMs: ms(since: t0), bytes: bytes + snapshotBytes,
                                  path: "durable_then_baseline", replayedEvents: events, streamGaps: gaps)
                default: continue
                }
            }
        }
        while true {
            let frame = try await next()
            if frame["type"] as? String == "baselineRequired" { break }
        }
        let snapshotBytes = try await snapshot(fixture)
        return Sample(timeToLiveMs: ms(since: t0), bytes: bytes + snapshotBytes, path: "baseline_snapshot",
                      replayedEvents: 0, streamGaps: 0)
    }

    private static func snapshot(_ fixture: Fixture) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(fixture.port)/v1/rpc")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(fixture.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "sync.snapshot",
            "params": ["supportedStateVersion": 3],
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(object?["error"], "snapshot must succeed for the receipt to count")
        return data.count
    }

    private static func ms(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
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
