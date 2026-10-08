import XCTest
@testable import SocketServer
import CoreModel

/// IST-09: an event the transport cannot encode (a kind that is not a dotted
/// name) used to close the socket with a retryable `invalidEvent`. The phone
/// reconnected with its cursor still below that event, the replay hit it
/// again and the socket closed again, for as long as the event stayed in the
/// ring. The event must be skipped like any other sequence the socket does
/// not carry, with the established `baselineRequired` recovery, and the
/// stream must go on.
final class WebSocketUnencodableEventTests: XCTestCase {
    private final class FrameCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [[String: Any]] = []

        /// One receive loop for the whole test: a timed-out receive would
        /// leave an orphaned `task.receive` behind.
        func start(_ task: URLSessionWebSocketTask) {
            task.receive { [weak self] result in
                guard let self, case .success(let message) = result else { return }
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: data = Data()
                }
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.lock.lock(); self.frames.append(object); self.lock.unlock()
                }
                self.start(task)
            }
        }

        var all: [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return frames
        }
    }

    @MainActor
    private func startServer() throws -> (DirectHTTPServer, UInt16) {
        for _ in 0..<20 {
            let port = UInt16.random(in: 33_000...44_000)
            let server = DirectHTTPServer(
                port: port,
                loopbackOnly: true,
                dispatcher: JSONRPCDispatcher(router: FakeRouter()),
                serverId: "unencodable-host",
                bootEpoch: 42
            )
            if (try? server.start()) != nil { return (server, port) }
        }
        throw NSError(domain: "WebSocketUnencodableEventTests", code: 1)
    }

    @MainActor
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func uniqueSuffix() -> String {
        UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    @MainActor
    func test_eventThatCannotBeEncoded_isSkippedWithBaselineRequired_andTheSocketStaysOpen() async throws {
        // The unencodable event stays in the process-wide ring; roll it out
        // (after this server stopped) so no later connection replays it.
        let fillerKind = "test.ws.unencodable_roll.\(uniqueSuffix())"
        defer {
            for _ in 0...EventBus.defaultRecentLimit {
                EventBus.shared.publishRawForTesting(kind: fillerKind, payload: .object([:]))
            }
        }
        let (server, port) = try startServer()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        request.setValue("\(EventBus.shared.currentSeq)", forHTTPHeaderField: "x-rc2-since-seq")
        let task = URLSession.shared.webSocketTask(with: request)
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let frames = FrameCollector()
        task.resume()
        frames.start(task)
        let welcomed = await waitUntil(2) { frames.all.contains { $0["type"] as? String == "welcome" } }
        XCTAssertTrue(welcomed)

        // Not a dotted name: `ConnectionEventFrame` refuses to encode it.
        let unencodableKind = "nodot\(uniqueSuffix())"
        let laterKind = "test.ws.after_unencodable.\(uniqueSuffix())"
        EventBus.shared.publishRawForTesting(kind: unencodableKind, payload: .object([:]))
        EventBus.shared.publishRawForTesting(kind: laterKind, payload: .object(["marker": .bool(true)]))

        let delivered = await waitUntil(3) { frames.all.contains { $0["kind"] as? String == laterKind } }

        XCTAssertTrue(delivered, "the stream must continue past an event it cannot encode")
        XCTAssertFalse(
            frames.all.contains { $0["type"] as? String == "closing" },
            "closing here makes every reconnect replay the same event and close again"
        )
        XCTAssertTrue(
            frames.all.contains { $0["type"] as? String == "baselineRequired" },
            "the skipped sequence is reported through the established recovery frame"
        )
        XCTAssertFalse(frames.all.contains { $0["kind"] as? String == unencodableKind })
    }
}
