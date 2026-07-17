import XCTest
import Darwin
@testable import SocketServer

final class UnixSocketServerTests: XCTestCase {
    @MainActor
    func testFailedStartClearsListenerOwnershipBeforeStopCanCloseAReusedFD() throws {
        // WHY: a failed start used to close the descriptor without resetting
        // listenFD. A later stop could then close an unrelated PTY that reused
        // the same integer descriptor.
        let tooLongPath = "/tmp/" + String(repeating: "x", count: 180)
        let server = UnixSocketServer(
            socketPath: tooLongPath,
            dispatcher: JSONRPCDispatcher(router: FakeRouter())
        )
        let createdFD = FDFlagBox()
        server.listenerFDObserverForTesting = { createdFD.value = $0 }

        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(server.listenFDForTesting, -1)
        let failedFD = try XCTUnwrap(createdFD.value)
        let reusedFD = open("/dev/null", O_RDONLY)
        XCTAssertEqual(reusedFD, failedFD, "the proof requires deterministic descriptor reuse")
        defer { close(reusedFD) }

        server.stop()
        XCTAssertGreaterThanOrEqual(
            fcntl(reusedFD, F_GETFD),
            0,
            "stop after failed start must not close a descriptor now owned by another subsystem"
        )
    }

    @MainActor
    func testBindFailureAlsoClearsListenerOwnership() throws {
        // WHY: bind/listen/chmod failures share the same stale-descriptor risk
        // as path validation and must leave stop idempotent.
        let missingParent = "/tmp/rc2-u-missing-\(UUID().uuidString.prefix(8))"
        let server = UnixSocketServer(
            socketPath: missingParent + "/server.sock",
            dispatcher: JSONRPCDispatcher(router: FakeRouter())
        )
        let createdFD = FDFlagBox()
        server.listenerFDObserverForTesting = { createdFD.value = $0 }

        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(server.listenFDForTesting, -1)
        let failedFD = try XCTUnwrap(createdFD.value)
        let reusedFD = open("/dev/null", O_RDONLY)
        XCTAssertEqual(reusedFD, failedFD, "the proof requires deterministic descriptor reuse")
        defer { close(reusedFD) }

        server.stop()
        XCTAssertGreaterThanOrEqual(fcntl(reusedFD, F_GETFD), 0)
    }

    @MainActor
    func testStopDuringStartCannotRecycleListenerBeforeStartObservesCancellation() throws {
        // WHY: stop previously closed the listener while start still held its
        // raw integer. A PTY could reuse that number before start's next fcntl
        // or bind, causing start to mutate an unrelated terminal descriptor.
        let socketURL = URL(
            fileURLWithPath: "/tmp/rc2-u-race-\(UUID().uuidString.prefix(8)).sock"
        )
        let server = UnixSocketServer(
            socketPath: socketURL.path,
            dispatcher: JSONRPCDispatcher(router: FakeRouter())
        )
        let listener = FDFlagBox()
        let listenerCreated = DispatchSemaphore(value: 0)
        let releaseStart = DispatchSemaphore(value: 0)
        let startFinished = DispatchSemaphore(value: 0)
        let startFailed = LockedUnixBool()
        server.listenerFDObserverForTesting = { descriptor in
            listener.value = descriptor
            listenerCreated.signal()
            _ = releaseStart.wait(timeout: .now() + 2)
        }

        DispatchQueue.global().async {
            do {
                try server.start()
            } catch {
                startFailed.value = true
            }
            startFinished.signal()
        }
        XCTAssertEqual(listenerCreated.wait(timeout: .now() + 1), .success)
        let listenerFD = try XCTUnwrap(listener.value)

        server.stop()
        let probe = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(probe, 0)
        defer { close(probe) }
        XCTAssertNotEqual(
            probe,
            listenerFD,
            "the in-flight start must retain its listener until it observes cancellation"
        )

        releaseStart.signal()
        XCTAssertEqual(startFinished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(startFailed.value)
        XCTAssertEqual(server.listenFDForTesting, -1)
        XCTAssertEqual(fcntl(probe, F_GETFD) & FD_CLOEXEC, 0,
                       "the cancelled start must not mutate the unrelated probe descriptor")
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }

    @MainActor
    func testRapidStopStartKeepsOldAcceptLoopsAndClientsInTheirGeneration() throws {
        // WHY: an old accept loop can wake after a fast restart. It must exit
        // on its captured generation instead of accepting from the new listener
        // or letting an old client resume when `running` becomes true again.
        let socketURL = URL(
            fileURLWithPath: "/tmp/rc2-u-gen-\(UUID().uuidString.prefix(8)).sock"
        )
        let server = UnixSocketServer(
            socketPath: socketURL.path,
            dispatcher: JSONRPCDispatcher(router: FakeRouter())
        )
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: socketURL)
        }

        for cycle in 0..<25 {
            try server.start()
            let client = try connectUnix(path: socketURL.path)
            let cursor = EventBus.shared.currentSeq
            let request = #"{"jsonrpc":"2.0","id":"generation-\#(cycle)","method":"events.stream","params":{"after_seq":\#(cursor)}}"# + "\n"
            try writeAll(fd: client, data: Data(request.utf8))
            XCTAssertTrue(try readLine(fd: client).contains(#""subscribed":true"#))
            server.stop()
            Darwin.close(client)
        }

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, server.acceptedClientCountForTesting != 0 {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(server.acceptedClientCountForTesting, 0)
        XCTAssertEqual(server.activeRequestCountForTesting, 0)
        XCTAssertEqual(server.listenFDForTesting, -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }

    @MainActor
    func testStopShutsDownAndReleasesAllAcceptedIdleClients() throws {
        // WHY: closing only the listener leaves every idle local client handler,
        // descriptor, and server capture alive across app stop/relaunch.
        let socketURL = URL(
            fileURLWithPath: "/tmp/rc2-u-stop-\(UUID().uuidString.prefix(8)).sock"
        )
        let server = UnixSocketServer(
            socketPath: socketURL.path,
            dispatcher: JSONRPCDispatcher(router: FakeRouter())
        )
        try server.start()
        var clients: [Int32] = []
        defer {
            clients.forEach { close($0) }
            server.stop()
            try? FileManager.default.removeItem(at: socketURL)
        }

        for _ in 0..<8 { clients.append(try connectUnix(path: socketURL.path)) }
        let acceptedDeadline = Date().addingTimeInterval(2)
        while Date() < acceptedDeadline, server.acceptedClientCountForTesting != clients.count {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(server.acceptedClientCountForTesting, clients.count)

        server.stop()
        for client in clients {
            XCTAssertTrue(waitForEOF(fd: client, timeout: 2))
        }
        let releaseDeadline = Date().addingTimeInterval(2)
        while Date() < releaseDeadline, server.acceptedClientCountForTesting != 0 {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(server.acceptedClientCountForTesting, 0)
        XCTAssertEqual(server.activeRequestCountForTesting, 0)
    }

    @MainActor
    func testListenerAndAcceptedDescriptorsAreCloseOnExec() throws {
        // WHY: terminal shells exec inside the app process. Inheritable IPC
        // descriptors keep listeners and dead clients alive across every shell.
        let socketURL = URL(
            fileURLWithPath: "/tmp/rc2-clx-\(UUID().uuidString.prefix(8)).sock"
        )
        let server = UnixSocketServer(
            socketPath: socketURL.path,
            dispatcher: JSONRPCDispatcher(router: FakeRouter())
        )
        let accepted = FDFlagBox()
        let acceptedReady = DispatchSemaphore(value: 0)
        server.acceptedFDObserverForTesting = { fd in
            accepted.value = fcntl(fd, F_GETFD)
            acceptedReady.signal()
        }
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: socketURL)
        }

        let listenerFlags = fcntl(server.listenFDForTesting, F_GETFD)
        XCTAssertGreaterThanOrEqual(listenerFlags, 0)
        XCTAssertNotEqual(listenerFlags & FD_CLOEXEC, 0)
        let client = try connectUnix(path: socketURL.path)
        defer { Darwin.close(client) }
        XCTAssertEqual(acceptedReady.wait(timeout: .now() + 1), .success)
        let acceptedFlags = try XCTUnwrap(accepted.value)
        XCTAssertGreaterThanOrEqual(acceptedFlags, 0)
        XCTAssertNotEqual(acceptedFlags & FD_CLOEXEC, 0)
    }

    func testCloseOnExecSetupPreservesFlagsAndFailsClosed() {
        // WHY: ignoring F_GETFD/F_SETFD failure lets every future terminal
        // child inherit the local IPC listener or an accepted client socket.
        var installedFlags: Int32?
        XCTAssertTrue(UnixSocketServer.enableCloseOnExec(
            42,
            getFlags: { _ in 0x40 },
            setFlags: { _, flags in installedFlags = flags; return 0 }
        ))
        XCTAssertEqual(installedFlags, 0x40 | FD_CLOEXEC)

        XCTAssertFalse(UnixSocketServer.enableCloseOnExec(
            42,
            getFlags: { _ in -1 },
            setFlags: { _, _ in XCTFail("setter must not run"); return 0 }
        ))
        XCTAssertFalse(UnixSocketServer.enableCloseOnExec(
            42,
            getFlags: { _ in 0 },
            setFlags: { _, _ in -1 }
        ))

        var setterCalled = false
        XCTAssertTrue(UnixSocketServer.enableCloseOnExec(
            42,
            getFlags: { _ in FD_CLOEXEC },
            setFlags: { _, _ in setterCalled = true; return -1 }
        ))
        XCTAssertFalse(setterCalled)
    }

    @MainActor
    func testSocketIsCurrentUserOwnedAndMode0600BeforeClientsConnect() throws {
        let socketURL = URL(fileURLWithPath: "/tmp/rc2-p-\(UUID().uuidString.prefix(8)).sock")
        let server = UnixSocketServer(socketPath: socketURL.path, dispatcher: JSONRPCDispatcher(router: FakeRouter()))
        try server.start()
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
        XCTAssertEqual((attributes[.ownerAccountID] as? NSNumber)?.uint32Value, geteuid(),
                       "local IPC must be owned by the current user")
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.uint16Value, UInt16(0o600),
                       "local IPC must not grant group or other access")
    }

    @MainActor
    func testLocalIPCMutationUsesSharedHandlerWithoutRemoteWireIdentity() async throws {
        let router = FakeRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let response = await dispatcher.dispatchLocalIPC(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .string("local"),
            method: "workspace.create",
            params: ["name": .string("local"), "cwd": .string("/tmp")]
        ))

        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?.objectValue?["name"], .string("local"))
        XCTAssertEqual(router.workspaces.count, 1,
                       "owner-only local IPC must keep the CLI domain-handler path without remote receipt fields")
    }

    @MainActor
    func testTimedOutRequestsStayGloballyBoundedUntilTheirTasksActuallyFinish() async throws {
        // WHY: a deadline can close the Unix client, but Swift cannot force a
        // non-cooperative domain handler to return. Those orphaned Tasks must
        // remain counted so repeated clients cannot stack memory forever.
        let socketURL = URL(
            fileURLWithPath: "/tmp/rc2-u-cap-\(UUID().uuidString.prefix(8)).sock"
        )
        let suspended = SuspendedUnixResponses()
        let server = UnixSocketServer(
            socketPath: socketURL.path,
            dispatcher: JSONRPCDispatcher(router: FakeRouter()),
            localRequestTimeoutForTesting: .milliseconds(40),
            activeRequestLimitForTesting: 2,
            localRequestHandlerForTesting: { _ in
                await suspended.response()
            }
        )
        try server.start()
        var clients: [Int32] = []
        defer {
            suspended.resumeAll()
            clients.forEach { Darwin.close($0) }
            server.stop()
            try? FileManager.default.removeItem(at: socketURL)
        }

        let request = Data((#"{"jsonrpc":"2.0","id":"bounded","method":"workspace.list"}"# + "\n").utf8)
        for _ in 0..<2 {
            let client = try connectUnix(path: socketURL.path)
            clients.append(client)
            try writeAll(fd: client, data: request)
        }

        let reachedLimit = await waitUntil(timeout: 2) {
            server.activeRequestCountForTesting == 2 && suspended.count == 2
        }
        XCTAssertTrue(reachedLimit)
        let timedOutClientsReleased = await waitUntil(timeout: 2) {
            server.acceptedClientCountForTesting == 0
        }
        XCTAssertTrue(timedOutClientsReleased,
                      "timed-out client handlers must release their sockets")
        XCTAssertEqual(server.activeRequestCountForTesting, 2,
                       "timed-out but unfinished Tasks must still consume the global cap")

        let diagnosticCursor = EventBus.shared.currentSeq
        let rejected = try connectUnix(path: socketURL.path)
        clients.append(rejected)
        try writeAll(fd: rejected, data: request)
        let limitDiagnosed = await waitUntil(timeout: 1) {
            EventBus.shared.recentEvents(since: diagnosticCursor, maxBytes: nil).events
                .contains(where: { $0.kind == "diagnostic.unix_request_limit" })
        }
        XCTAssertTrue(limitDiagnosed)
        XCTAssertTrue(waitForEOF(fd: rejected, timeout: 1))
        XCTAssertEqual(server.activeRequestCountForTesting, 2)
        XCTAssertEqual(suspended.count, 2,
                       "the rejected request must not create a third domain Task")

        suspended.resumeAll()
        let tasksReleased = await waitUntil(timeout: 2) {
            server.activeRequestCountForTesting == 0
        }
        XCTAssertTrue(tasksReleased)
    }

    @MainActor
    func testEventStreamDeliversLiveEventsOverSerializedUnixSocketWriter() throws {
        let socketURL = URL(
            fileURLWithPath: "/tmp/rc2-u-live-\(UUID().uuidString.prefix(8)).sock"
        )
        let server = UnixSocketServer(socketPath: socketURL.path, dispatcher: JSONRPCDispatcher(router: FakeRouter()))
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: socketURL)
        }
        Thread.sleep(forTimeInterval: 0.05)

        let fd = try connectUnix(path: socketURL.path)
        defer { Darwin.close(fd) }

        let startSeq = EventBus.shared.snapshot().lastSeq
        let request = #"{"jsonrpc":"2.0","id":"stream","method":"events.stream","params":{"after_seq":\#(startSeq)}}"# + "\n"
        try writeAll(fd: fd, data: Data(request.utf8))
        let ack = try readLine(fd: fd)

        let kind = "unix.test.\(UUID().uuidString)"
        EventBus.shared.publish(kind: kind, payload: .string("ok"))
        let event = try readLine(fd: fd)

        XCTAssertTrue(ack.contains(#""subscribed":true"#),
                      "event stream clients need an ack before waiting for live events")
        XCTAssertTrue(event.contains(kind),
                      "live events must be serialized through the Unix socket writer without dropping the frame")
    }

    @MainActor
    func testSlowEventStreamClientIsClosedAtBoundedQueueInsteadOfStackingTerminalOutput() throws {
        // WHY: surface.output can carry tens of KiB per event. A client that
        // stops reading must be disconnected at a fixed byte cap; one queued
        // DispatchWorkItem per event otherwise grows for the app's lifetime.
        let socketURL = URL(
            fileURLWithPath: "/tmp/rc2-u-slow-\(UUID().uuidString.prefix(8)).sock"
        )
        let server = UnixSocketServer(
            socketPath: socketURL.path,
            dispatcher: JSONRPCDispatcher(router: FakeRouter())
        )
        let writeGate = UnixLargeWriteGate()
        server.outboundWriteWillBeginForTesting = { writeGate.blockFirstLargeWrite($0) }
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: socketURL)
        }
        defer { writeGate.release() }
        Thread.sleep(forTimeInterval: 0.05)

        let fd = try connectUnix(path: socketURL.path)
        defer { Darwin.close(fd) }
        var receiveBuffer: Int32 = 1_024
        XCTAssertEqual(
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVBUF,
                &receiveBuffer,
                socklen_t(MemoryLayout<Int32>.size)
            ),
            0
        )

        let streamStart = EventBus.shared.currentSeq
        let request = #"{"jsonrpc":"2.0","id":"slow","method":"events.stream","params":{"after_seq":\#(streamStart)}}"# + "\n"
        try writeAll(fd: fd, data: Data(request.utf8))
        XCTAssertTrue(try readLine(fd: fd).contains(#""subscribed":true"#))

        let diagnosticCursor = EventBus.shared.currentSeq
        let terminalPayload = String(repeating: "A", count: 64 * 1024)
        EventBus.shared.publish(kind: "surface.output", payload: .object([
            "surface_id": .string("slow-unix-terminal"),
            "seq": .number(1),
            "base64": .string(terminalPayload)
        ]))
        XCTAssertTrue(writeGate.waitUntilBlocked(timeout: 1))
        var diagnostic: EventBus.Event?
        for index in 1..<64 {
            EventBus.shared.publish(kind: "surface.output", payload: .object([
                "surface_id": .string("slow-unix-terminal"),
                "seq": .number(Double(index + 1)),
                "base64": .string(terminalPayload)
            ]))
            diagnostic = EventBus.shared
                .recentEvents(since: diagnosticCursor, maxBytes: nil)
                .events
                .first(where: { $0.kind == "diagnostic.unix_slow_client" })
            if diagnostic != nil { break }
        }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, diagnostic == nil {
            diagnostic = EventBus.shared
                .recentEvents(since: diagnosticCursor, maxBytes: nil)
                .events
                .first(where: { $0.kind == "diagnostic.unix_slow_client" })
            if diagnostic == nil { Thread.sleep(forTimeInterval: 0.01) }
        }
        let payload = try XCTUnwrap(
            diagnostic?.payload.objectValue,
            "a queue overflow must fail loud with a Unix slow-client diagnostic"
        )
        XCTAssertEqual(payload["reason"], .string("queue_full"))
        XCTAssertEqual(
            payload["max_queued_bytes"],
            .number(Double(UnixSocketServer.maxStreamQueuedBytes))
        )
        XCTAssertLessThanOrEqual(
            payload["queued_bytes"]?.intValue ?? Int.max,
            UnixSocketServer.maxStreamQueuedBytes,
            "queued terminal event payloads must never exceed the per-connection byte cap"
        )
        XCTAssertTrue(
            waitForEOF(fd: fd, timeout: 3),
            "queue overflow must shutdown the slow Unix stream so the blocked writer and subscription terminate"
        )
    }

    @MainActor
    func testReplayOverflowReleasesSubscriptionAfterSynchronousSubscribeReturns() throws {
        // WHY: EventBus installs a subscriber and replays synchronously before
        // subscribe returns its UUID. If replay closes the outbound queue first,
        // the socket cleanup must still remove the UUID returned moments later.
        let socketURL = URL(
            fileURLWithPath: "/tmp/rc2-u-replay-\(UUID().uuidString.prefix(8)).sock"
        )
        let server = UnixSocketServer(
            socketPath: socketURL.path,
            dispatcher: JSONRPCDispatcher(router: FakeRouter())
        )
        let writeGate = UnixLargeWriteGate()
        server.outboundWriteWillBeginForTesting = { writeGate.blockFirstLargeWrite($0) }
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: socketURL)
        }
        defer { writeGate.release() }
        Thread.sleep(forTimeInterval: 0.05)

        let subscriberBaseline = EventBus.shared.subscriberCountForTests
        let replayCursor = EventBus.shared.currentSeq
        let terminalPayload = String(repeating: "R", count: 64 * 1024)
        for index in 0..<128 {
            EventBus.shared.publish(kind: "surface.output", payload: .object([
                "surface_id": .string("unix-replay-overflow"),
                "seq": .number(Double(index + 1)),
                "base64": .string(terminalPayload)
            ]))
        }
        let diagnosticCursor = EventBus.shared.currentSeq

        let fd = try connectUnix(path: socketURL.path)
        defer { Darwin.close(fd) }
        var receiveBuffer: Int32 = 1_024
        XCTAssertEqual(
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVBUF,
                &receiveBuffer,
                socklen_t(MemoryLayout<Int32>.size)
            ),
            0
        )
        let request = #"{"jsonrpc":"2.0","id":"replay-overflow","method":"events.stream","params":{"after_seq":\#(replayCursor)}}"# + "\n"
        try writeAll(fd: fd, data: Data(request.utf8))

        let diagnosticDeadline = Date().addingTimeInterval(3)
        var sawOverflow = false
        while Date() < diagnosticDeadline, !sawOverflow {
            sawOverflow = EventBus.shared
                .recentEvents(since: diagnosticCursor, maxBytes: nil)
                .events
                .contains(where: { $0.kind == "diagnostic.unix_slow_client" })
            if !sawOverflow { Thread.sleep(forTimeInterval: 0.01) }
        }
        XCTAssertTrue(sawOverflow, "the synchronous replay must reach the bounded outbound cap")
        XCTAssertTrue(waitForEOF(fd: fd, timeout: 3), "replay overflow must close the socket")

        let releaseDeadline = Date().addingTimeInterval(3)
        while Date() < releaseDeadline,
              EventBus.shared.subscriberCountForTests != subscriberBaseline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(
            EventBus.shared.subscriberCountForTests,
            subscriberBaseline,
            "the subscriber UUID returned after synchronous replay must not remain orphaned"
        )

        EventBus.shared.publish(kind: "unix.replay.post-close", payload: .string("probe"))
        XCTAssertEqual(EventBus.shared.subscriberCountForTests, subscriberBaseline)
    }

    private func connectUnix(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        XCTAssertLessThanOrEqual(bytes.count, maxPath)
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: maxPath) { target in
                for i in 0..<bytes.count { target[i] = bytes[i] }
            }
        }
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc < 0 {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }

    private func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                written += n
            }
        }
    }

    private func readLine(fd: Int32) throws -> String {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &byte, 1)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if byte == 0x0A { break }
            data.append(byte)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func waitForEOF(fd: Int32, timeout: TimeInterval) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while Date() < deadline {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return true }
            if count < 0, errno != EINTR, errno != EAGAIN, errno != EWOULDBLOCK {
                return true
            }
            if count < 0 { Thread.sleep(forTimeInterval: 0.005) }
        }
        return false
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
}

private final class FDFlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int32?

    var value: Int32? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private final class LockedUnixBool: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock(); storage = newValue; lock.unlock()
        }
    }
}

private final class UnixLargeWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didBlock = false
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func blockFirstLargeWrite(_ data: Data) {
        guard data.count > 4_096 else { return }
        lock.lock()
        let shouldBlock = !didBlock
        didBlock = true
        lock.unlock()
        guard shouldBlock else { return }
        entered.signal()
        _ = released.wait(timeout: .now() + 5)
    }

    func waitUntilBlocked(timeout: TimeInterval) -> Bool {
        entered.wait(timeout: .now() + timeout) == .success
    }

    func release() {
        released.signal()
    }
}

@MainActor
private final class SuspendedUnixResponses {
    private var continuations: [CheckedContinuation<JSONRPCResponse, Never>] = []

    var count: Int { continuations.count }

    func response() async -> JSONRPCResponse {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeAll() {
        let pending = continuations
        continuations.removeAll(keepingCapacity: false)
        for continuation in pending {
            continuation.resume(returning: JSONRPCResponse(
                id: .string("bounded"),
                result: .object(["ok": .bool(true)])
            ))
        }
    }
}
