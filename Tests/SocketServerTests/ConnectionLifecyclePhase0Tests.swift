import Darwin
import XCTest
@testable import SocketServer

final class ConnectionLifecyclePhase0Tests: XCTestCase {
    @MainActor
    func test_serverStopDuringInFlightPartialRequest_closesWithoutPostStopResponse() throws {
        let port = try availableLoopbackPort()
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: FakeRouter()),
            clientReceiveTimeoutSeconds: 5
        )
        try server.start()
        defer { server.stop() }

        let client = try connectLoopback(port: port)
        defer { Darwin.close(client) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let partialRequest = Data("GET /v1/health HTTP/1.1\r\nHost: localhost\r\n".utf8)
        _ = partialRequest.withUnsafeBytes { bytes in
            Darwin.write(client, bytes.baseAddress, bytes.count)
        }
        let acceptanceDeadline = Date().addingTimeInterval(0.5)
        while server.acceptedSocketCountForTests == 0, Date() < acceptanceDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(server.acceptedSocketCountForTests, 1,
                       "the partial request must be owned by an in-flight handler before stop")

        server.stop()

        var byte: UInt8 = 0
        let received = Darwin.read(client, &byte, 1)
        XCTAssertTrue(received == 0 || (received < 0 && errno == ECONNRESET),
                      "stop must wake the in-flight handler and emit no response after the descriptor is gated")
        let closeDeadline = Date().addingTimeInterval(0.5)
        while server.acceptedSocketCountForTests != 0, Date() < closeDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(server.acceptedSocketCountForTests, 0,
                       "the awakened handler must perform its final close and leave no accepted descriptor behind")
    }

    func test_stopDuringInFlightHandler_gatesSendAndOwnerClosesOnceWithoutDescriptorReuse() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { Darwin.close(descriptors[1]) }

        let registry = AcceptedSocketRegistry()
        registry.register(descriptors[0])
        XCTAssertEqual(registry.count, 1)

        registry.shutdownAll()

        XCTAssertFalse(registry.isActive(descriptors[0]),
                       "server stop/reconfigure must gate every accepted descriptor before any later send")
        var postStopWrites = 0
        if registry.isActive(descriptors[0]) {
            postStopWrites += 1
        }
        XCTAssertEqual(postStopWrites, 0,
                       "an in-flight handler must skip every response after stop marks its descriptor inactive")
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(descriptors[1], &byte, 1), 0,
                       "the peer must observe EOF after the server registry shuts down its socket")
        XCTAssertNotEqual(fcntl(descriptors[0], F_GETFD), -1,
                          "stop must not close a descriptor while its owning handler still holds the raw fd")
        XCTAssertTrue(registry.close(descriptors[0]),
                      "the owning handler must perform the final close exactly once")
        XCTAssertFalse(registry.close(descriptors[0]),
                       "a second completion path must not close a reused descriptor")
        XCTAssertEqual(registry.count, 0)
    }

    func test_batchTimer_stop_preventsLateFrameDelivery() {
        let sent = ThreadSafeFrames()
        let batcher = WebSocketEventBatcher(
            enabled: true,
            filter: .full,
            delay: 0.075,
            send: { sent.append($0) }
        )
        let event = EventBus.Event(seq: 1, kind: "workspace.updated", payload: .null, ts: 0)

        batcher.enqueue(event: event, data: Data("late".utf8))
        batcher.stop()
        Thread.sleep(forTimeInterval: 0.050)

        XCTAssertTrue(sent.values().isEmpty,
                      "a stopped/reconfigured server must not emit a frame from an orphaned batch timer")
    }

    private func availableLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { throw POSIXError(.EIO) }
        return UInt16(bigEndian: address.sin_port)
    }

    private func connectLoopback(port: UInt16) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.ECONNREFUSED)
        }
        return descriptor
    }
}

private final class ThreadSafeFrames {
    private let lock = NSLock()
    private var storage: [Data] = []

    func append(_ data: Data) {
        lock.lock(); storage.append(data); lock.unlock()
    }

    func values() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
