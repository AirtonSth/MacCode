import Darwin
import XCTest
@testable import SocketServer
import CoreModel
import Persistence
import AgentRuntime

/// Holds a mutation handler open until the test releases it. The wait is not
/// cancellation-aware, like a router that is inside its own effect.
private actor MutationShieldGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var hasEntered: Bool { entered }

    func hold() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Minimal durable-receipt router (same shape as the Phase 4 contract fake):
/// HTTP mutations only reach the handler through a `CommandReceiptStateRouting`
/// router with a `client_request_id`.
private final class MutationShieldRouter: FakeRouter, CommandReceiptStateRouting {
    private struct Receipt {
        let ownerFingerprint: String
        let paramsHash: String
        var state: String
        var result: JSONValue?
    }

    private struct ReceiptUnavailable: Error {}

    var deleteGate: MutationShieldGate?
    private(set) var deleteSawCancellation: Bool?
    private var receipts: [String: Receipt] = [:]

    override func deleteAgentThread(thread: AgentThreadID) async throws {
        if let deleteGate { await deleteGate.hold() }
        deleteSawCancellation = Task.isCancelled
        // The production router throws CancellationError from a cancelled
        // mutation, which the dispatcher fences as commandOutcomeUnknown.
        try Task.checkCancellation()
        try await super.deleteAgentThread(thread: thread)
    }

    func claimCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws -> CommandReceiptClaimResult {
        let key = "\(method):\(clientRequestId)"
        if let receipt = receipts[key] {
            guard receipt.ownerFingerprint == ownerFingerprint else { return .ownerMismatch }
            guard receipt.paramsHash == paramsHash else { return .requestMismatch }
            switch receipt.state {
            case "claimed": return .inProgress
            case "committed":
                let data = try JSONEncoder().encode(receipt.result ?? .null)
                return .committed(resultJSON: String(decoding: data, as: UTF8.self))
            default: return .unknown
            }
        }
        receipts[key] = Receipt(
            ownerFingerprint: ownerFingerprint,
            paramsHash: paramsHash,
            state: "claimed",
            result: nil
        )
        return .claimed
    }

    func commitCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue
    ) throws {
        let key = "\(method):\(clientRequestId)"
        guard var receipt = receipts[key],
              receipt.ownerFingerprint == ownerFingerprint,
              receipt.paramsHash == paramsHash,
              receipt.state == "claimed" else {
            throw ReceiptUnavailable()
        }
        receipt.state = "committed"
        receipt.result = result
        receipts[key] = receipt
    }

    func finalizeCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue,
        events: [EventBus.MutationEventIntent],
        minimumEventSequence: Int64
    ) throws -> [EventBus.Event] {
        try commitCommandReceipt(
            method: method,
            clientRequestId: clientRequestId,
            ownerFingerprint: ownerFingerprint,
            paramsHash: paramsHash,
            result: result
        )
        return events.enumerated().map { ordinal, event in
            EventBus.Event(
                seq: minimumEventSequence + Int64(ordinal) + 1,
                kind: event.kind.rawValue,
                payload: event.payload,
                ts: event.createdAt.timeIntervalSince1970
            )
        }
    }

    func markCommandReceiptUnknown(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws {
        let key = "\(method):\(clientRequestId)"
        guard var receipt = receipts[key] else { return }
        receipt.state = "unknown"
        receipts[key] = receipt
    }

    func releaseCommandReceiptClaim(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws {
        receipts["\(method):\(clientRequestId)"] = nil
    }

    func commandReceiptStatus(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String
    ) throws -> CommandReceiptStatusResult {
        guard let receipt = receipts["\(method):\(clientRequestId)"] else { return .absent }
        switch receipt.state {
        case "claimed": return .inProgress
        case "committed": return .committed
        default: return .unknown
        }
    }
}

private final class SnapshotReadFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    func set() { lock.lock(); stored = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
}

/// Snapshot router whose read is held off MainActor until the test signals.
private final class HeldSnapshotRouter: FakeRouter, ConnectionSnapshotRouting {
    let release = DispatchSemaphore(value: 0)
    let started = SnapshotReadFlag()

    func readConnectionSnapshotState() async throws -> ConnectionSnapshotReadState {
        let release = release
        let started = started
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue(label: "io.remotecode.test.shield-snapshot").async {
                started.set()
                _ = release.wait(timeout: .now() + 5)
                continuation.resume()
            }
        }
        let workspaceID = UUID().uuidString
        return ConnectionSnapshotReadState(
            selectedWorkspaceId: workspaceID,
            workspaces: [.object(["id": .string(workspaceID), "name": .string("Held")])],
            surfaces: [],
            agentThreads: [],
            browserStates: [],
            filesStates: []
        )
    }
}

/// MHS-01 / MDP-02 / MLD-02: when the phone drops mid-RPC (radio handoff,
/// app suspended) the host used to cancel the running mutation. The mutation
/// already held its durable receipt claim, so the cancellation was fenced as
/// a permanent `commandOutcomeUnknown` (-32095): the retry that iOS sends with
/// the same `client_request_id` could never learn the outcome. A dropped peer
/// must only release its socket; the mutation runs to its receipt commit.
final class RPCDisconnectMutationShieldTests: XCTestCase {
    private let commandInProgress = -32096

    @MainActor
    func test_peerDropDuringMutation_letsItCommit_soTheRetryReadsTheResult() async throws {
        let router = MutationShieldRouter()
        let thread = AgentThread(workspaceId: nil, title: "shield", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        let gate = MutationShieldGate()
        router.deleteGate = gate
        let (live, port) = try startServer(router: router)
        defer { live.stop() }

        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "agent.thread.delete",
            "params": [
                "client_request_id": "shield-delete-1",
                "thread_id": thread.id.value.uuidString,
            ],
        ])
        let fd = connectClient(port: port)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let request = Array(
            "POST /v1/rpc HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8
        ) + Array(body)
        XCTAssertEqual(write(fd, request, request.count), request.count)
        let entered = await waitUntil(2) { await gate.hasEntered }
        XCTAssertTrue(entered, "the mutation must reach its handler")
        guard entered else {
            close(fd)
            await gate.release()
            return
        }

        close(fd)
        let released = await waitUntil(2) { live.acceptedSocketCountForTests == 0 }
        XCTAssertTrue(released, "a dropped peer must still release its socket")

        // The retry iOS sends after the drop, while the first attempt runs.
        let during = try await rpc(port: port, body: body)
        XCTAssertEqual(errorCode(during), commandInProgress)
        XCTAssertEqual(errorData(during)?["retryable"] as? Bool, true,
                       "while the mutation runs the retry must be told to come back")

        await gate.release()
        var after = during
        let deadline = Date().addingTimeInterval(3)
        while errorCode(after) == commandInProgress, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            after = try await rpc(port: port, body: body)
        }
        XCTAssertNil(after["error"],
                     "the retry must read the committed outcome, never a permanent unknown: \(after)")
        XCTAssertEqual(after["result"] as? Bool, true)
        XCTAssertEqual(router.deleteSawCancellation, false,
                       "a dropped peer must not cancel a mutation that holds a receipt claim")
        XCTAssertEqual(router.deleteAgentThreadCallCount, 1, "the retry must not run the effect again")
    }

    /// Guards the other half: read-only snapshot work is still abandoned when
    /// the peer is gone, so a slow baseline cannot keep host CPU.
    @MainActor
    func test_peerDropDuringBulkRead_stillAbandonsTheSnapshot() async throws {
        let router = HeldSnapshotRouter()
        let (live, port) = try startServer(router: router)
        defer {
            router.release.signal()
            live.stop()
        }

        let body = Data(
            #"{"jsonrpc":"2.0","id":1,"method":"sync.snapshot","params":{"supportedStateVersion":3}}"#.utf8
        )
        let fd = connectClient(port: port)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let request = Array(
            "POST /v1/rpc HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8
        ) + Array(body)
        XCTAssertEqual(write(fd, request, request.count), request.count)
        let started = await waitUntil(2) { router.started.value }
        XCTAssertTrue(started, "the snapshot read must be in flight")
        XCTAssertEqual(live.requestPhaseMetrics.snapshot().cancelledTotal, 0)

        close(fd)
        // The router read is still held: only a cancelled caller returns now.
        let cancelled = await waitUntil(2) { live.requestPhaseMetrics.snapshot().cancelledTotal >= 1 }
        XCTAssertTrue(cancelled, "a dropped peer must cancel its snapshot instead of waiting for the read")
    }

    // MARK: - Helpers

    @MainActor
    private func startServer(router: FakeRouter) throws -> (DirectHTTPServer, UInt16) {
        for _ in 0..<20 {
            let port = UInt16.random(in: 33_000...44_000)
            let candidate = DirectHTTPServer(
                port: port,
                loopbackOnly: true,
                dispatcher: JSONRPCDispatcher(router: router),
                bootEpoch: 1
            )
            if (try? candidate.start()) != nil { return (candidate, port) }
        }
        throw NSError(domain: "RPCDisconnectMutationShieldTests", code: 1)
    }

    /// Polls without blocking MainActor: the dispatcher needs it to run.
    @MainActor
    private func waitUntil(_ timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }

    private func connectClient(port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    private func rpc(port: UInt16, body: Data) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, _) = try await URLSession(configuration: .ephemeral).data(for: request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func errorCode(_ object: [String: Any]) -> Int? {
        (object["error"] as? [String: Any])?["code"] as? Int
    }

    private func errorData(_ object: [String: Any]) -> [String: Any]? {
        (object["error"] as? [String: Any])?["data"] as? [String: Any]
    }
}
