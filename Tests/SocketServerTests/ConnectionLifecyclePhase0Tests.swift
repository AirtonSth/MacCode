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
            bootEpoch: 1,
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

    func test_shutdownAndHandlerCloseSerializeOwnershipBeforeDescriptorReuse() throws {
        // WHY: shutdownAll used to copy raw descriptor integers and release its
        // lock before calling shutdown. A handler could close one integer and a
        // terminal PTY could reuse it before the delayed shutdown syscall.
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { Darwin.close(descriptors[1]) }

        let shutdownEntered = DispatchSemaphore(value: 0)
        let releaseShutdown = DispatchSemaphore(value: 0)
        let shutdownFinished = DispatchSemaphore(value: 0)
        let closeFinished = DispatchSemaphore(value: 0)
        let closeResult = LockedLifecycleBool()
        let ownedDescriptor = descriptors[0]
        let registry = AcceptedSocketRegistry(shutdownDescriptor: { descriptor in
            shutdownEntered.signal()
            _ = releaseShutdown.wait(timeout: .now() + 2)
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        })
        XCTAssertTrue(registry.register(ownedDescriptor))

        DispatchQueue.global().async {
            registry.shutdownAll()
            shutdownFinished.signal()
        }
        XCTAssertEqual(shutdownEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            closeResult.value = registry.close(ownedDescriptor)
            closeFinished.signal()
        }
        XCTAssertEqual(
            closeFinished.wait(timeout: .now() + 0.05),
            .timedOut,
            "the handler close must wait while shutdown owns the descriptor registry lock"
        )

        releaseShutdown.signal()
        XCTAssertEqual(shutdownFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(closeResult.value)
        XCTAssertEqual(registry.count, 0)

        let reused = open("/dev/null", O_RDONLY)
        XCTAssertEqual(reused, ownedDescriptor, "the proof requires exact numeric descriptor reuse")
        defer { Darwin.close(reused) }
        XCTAssertFalse(registry.close(reused))
        XCTAssertGreaterThanOrEqual(
            fcntl(reused, F_GETFD),
            0,
            "no late handler or registry path may close the reused terminal descriptor"
        )
    }

    func test_activateDoesNotReactivateDescriptorsFromPriorServerGeneration() throws {
        // WHY: a fast stop/start must not make an old async RPC handler active
        // again merely because the registry resumed accepting new sockets.
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { Darwin.close(descriptors[1]) }

        let registry = AcceptedSocketRegistry()
        XCTAssertTrue(registry.register(descriptors[0]))
        registry.shutdownAll()
        registry.activate()

        XCTAssertFalse(registry.isActive(descriptors[0]))
        XCTAssertTrue(registry.close(descriptors[0]))
        XCTAssertEqual(registry.count, 0)
    }

    func test_acceptedSocketRegistryRejectsBeyondCapacityAndBoundsDiagnostics() throws {
        // WHY: the cap belongs at descriptor ownership, before protocol
        // parsing, so idle HTTP, partial headers, and long-lived WebSockets all
        // consume the same bounded budget.
        var pairs: [[Int32]] = []
        for _ in 0..<6 {
            var descriptors: [Int32] = [0, 0]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
            pairs.append(descriptors)
        }
        defer {
            for descriptors in pairs { Darwin.close(descriptors[1]) }
        }

        let registry = AcceptedSocketRegistry(maximumDescriptors: 2)
        let generation = registry.activate()
        guard case .accepted = registry.register(pairs[0][0], generation: generation),
              case .accepted = registry.register(pairs[1][0], generation: generation) else {
            XCTFail("the registry must accept descriptors until it reaches its cap")
            return
        }
        XCTAssertEqual(registry.count, 2)

        guard case let .atCapacity(active, limit, firstDiagnostic) = registry.register(
            pairs[2][0],
            generation: generation
        ) else {
            XCTFail("the first excess descriptor must be rejected at capacity")
            return
        }
        XCTAssertEqual(active, 2)
        XCTAssertEqual(limit, 2)
        XCTAssertTrue(firstDiagnostic)
        XCTAssertTrue(waitForPeerClosure(pairs[2][1], timeout: 0.25))

        guard case let .atCapacity(_, _, repeatedDiagnostic) = registry.register(
            pairs[3][0],
            generation: generation
        ) else {
            XCTFail("a sustained excess descriptor must remain rejected")
            return
        }
        XCTAssertFalse(repeatedDiagnostic,
                       "repeated excess accepts must not flood diagnostics while still saturated")
        XCTAssertTrue(waitForPeerClosure(pairs[3][1], timeout: 0.25))

        XCTAssertTrue(registry.close(pairs[0][0]))
        guard case .accepted = registry.register(pairs[4][0], generation: generation) else {
            XCTFail("releasing ownership below the cap must admit the next descriptor")
            return
        }
        guard case let .atCapacity(_, _, rearmedDiagnostic) = registry.register(
            pairs[5][0],
            generation: generation
        ) else {
            XCTFail("refilling the cap must reject the next descriptor")
            return
        }
        XCTAssertTrue(rearmedDiagnostic,
                      "a new saturation episode may publish one new diagnostic")
        XCTAssertTrue(waitForPeerClosure(pairs[5][1], timeout: 0.25))

        registry.shutdownAll()
        XCTAssertTrue(registry.close(pairs[1][0]))
        XCTAssertTrue(registry.close(pairs[4][0]))
        XCTAssertEqual(registry.count, 0)
    }

    func test_acceptedSocketRegistryCapsTailcatToReserveOrdinarySlots() throws {
        // WHY: the shared 64-descriptor budget must still leave LAN room.
        // Tailcat stops at 48 so at least 16 ordinary slots remain. The 8/6
        // fixture is the same policy (reserve 2 of 8, as 16 of 64).
        XCTAssertEqual(AcceptedSocketRegistry.defaultMaximumDescriptors, 64)
        XCTAssertEqual(AcceptedSocketRegistry.defaultTailcatMaximumDescriptors, 48)
        XCTAssertEqual(AcceptedSocketRegistry.defaultOrdinaryReserveDescriptors, 16)
        XCTAssertEqual(
            AcceptedSocketRegistry.defaultMaximumDescriptors
                - AcceptedSocketRegistry.defaultOrdinaryReserveDescriptors,
            AcceptedSocketRegistry.defaultTailcatMaximumDescriptors
        )

        var pairs: [[Int32]] = []
        for _ in 0..<16 {
            var descriptors: [Int32] = [0, 0]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
            pairs.append(descriptors)
        }
        defer {
            for descriptors in pairs { Darwin.close(descriptors[1]) }
        }

        let registry = AcceptedSocketRegistry(
            maximumDescriptors: 8,
            tailcatMaximumDescriptors: 6
        )
        let generation = registry.activate()

        for index in 0..<6 {
            guard case .accepted = registry.register(
                pairs[index][0],
                generation: generation,
                scope: .tailcat
            ) else {
                XCTFail("Tailcat must be admitted until its reserved cap")
                return
            }
        }
        XCTAssertEqual(registry.count, 6)

        guard case let .atCapacity(tailcatActive, tailcatLimit, firstTailcatDiagnostic) = registry.register(
            pairs[6][0],
            generation: generation,
            scope: .tailcat
        ) else {
            XCTFail("the first Tailcat beyond the Tailcat cap must be rejected while global room remains")
            return
        }
        XCTAssertEqual(tailcatActive, 6)
        XCTAssertEqual(tailcatLimit, 6)
        XCTAssertTrue(firstTailcatDiagnostic)
        XCTAssertEqual(registry.count, 6)
        XCTAssertTrue(waitForPeerClosure(pairs[6][1], timeout: 0.25))

        guard case let .atCapacity(_, _, repeatedTailcatDiagnostic) = registry.register(
            pairs[7][0],
            generation: generation,
            scope: .tailcat
        ) else {
            XCTFail("a sustained Tailcat excess must remain rejected")
            return
        }
        XCTAssertFalse(repeatedTailcatDiagnostic,
                       "repeated Tailcat rejects must not flood diagnostics while still at the Tailcat cap")
        XCTAssertTrue(waitForPeerClosure(pairs[7][1], timeout: 0.25))

        XCTAssertFalse(
            registry.register(pairs[8][0], scope: .tailcat),
            "HTTPServer.registerTailcatConnection's Bool API must also deny at the Tailcat cap"
        )
        XCTAssertTrue(waitForPeerClosure(pairs[8][1], timeout: 0.25))
        XCTAssertEqual(registry.count, 6)

        guard case .accepted = registry.register(
            pairs[9][0],
            generation: generation,
            scope: .ordinary
        ) else {
            XCTFail("ordinary/LAN must still be admitted after Tailcat is at its cap")
            return
        }
        guard case .accepted = registry.register(
            pairs[10][0],
            generation: generation
        ) else {
            XCTFail("ordinary/LAN must fill the reserved remainder up to the global cap")
            return
        }
        XCTAssertEqual(registry.count, 8)

        guard case let .atCapacity(globalActive, globalLimit, firstGlobalDiagnostic) = registry.register(
            pairs[11][0],
            generation: generation
        ) else {
            XCTFail("the global cap must remain a hard stop for ordinary/LAN")
            return
        }
        XCTAssertEqual(globalActive, 8)
        XCTAssertEqual(globalLimit, 8)
        XCTAssertTrue(
            firstGlobalDiagnostic,
            "Tailcat saturation must not suppress the first global-cap diagnostic"
        )
        XCTAssertTrue(waitForPeerClosure(pairs[11][1], timeout: 0.25))

        XCTAssertFalse(registry.register(pairs[12][0], scope: .tailcat))
        XCTAssertTrue(waitForPeerClosure(pairs[12][1], timeout: 0.25))
        XCTAssertEqual(registry.count, 8)

        XCTAssertTrue(registry.close(pairs[9][0]))
        XCTAssertEqual(registry.count, 7)
        guard case .accepted = registry.register(
            pairs[13][0],
            generation: generation,
            scope: .ordinary
        ) else {
            XCTFail("releasing an ordinary slot below the global cap must admit the next LAN descriptor")
            return
        }
        XCTAssertEqual(registry.count, 8)

        XCTAssertTrue(registry.close(pairs[0][0]))
        XCTAssertEqual(registry.count, 7)
        guard case .accepted = registry.register(
            pairs[14][0],
            generation: generation,
            scope: .tailcat
        ) else {
            XCTFail("releasing a Tailcat slot below the Tailcat cap must admit the next Tailcat descriptor")
            return
        }
        XCTAssertEqual(registry.count, 8)

        guard case let .atCapacity(_, _, rearmedTailcatDiagnostic) = registry.register(
            pairs[15][0],
            generation: generation,
            scope: .tailcat
        ) else {
            XCTFail("refilling the Tailcat cap must reject the next Tailcat descriptor")
            return
        }
        XCTAssertTrue(rearmedTailcatDiagnostic,
                      "a new Tailcat saturation episode may publish one new diagnostic")
        XCTAssertTrue(waitForPeerClosure(pairs[15][1], timeout: 0.25))
        XCTAssertEqual(registry.count, 8)

        registry.shutdownAll()
        XCTAssertTrue(registry.close(pairs[1][0]))
        XCTAssertTrue(registry.close(pairs[2][0]))
        XCTAssertTrue(registry.close(pairs[3][0]))
        XCTAssertTrue(registry.close(pairs[4][0]))
        XCTAssertTrue(registry.close(pairs[5][0]))
        XCTAssertTrue(registry.close(pairs[10][0]))
        XCTAssertTrue(registry.close(pairs[13][0]))
        XCTAssertTrue(registry.close(pairs[14][0]))
        XCTAssertEqual(registry.count, 0)
    }

    @MainActor
    func test_acceptedSocketLimitBoundsIdlePartialAndWebSocketClientsAndReleasesEveryDescriptor() throws {
        // WHY: the receive timeout bounded each handler's lifetime, but an
        // unbounded accept loop could still retain one descriptor and one
        // blocked worker per idle/partial HTTP or WebSocket client.
        let descriptorBaseline = processOpenDescriptorCount()
        XCTAssertGreaterThan(descriptorBaseline, 0)
        let port = try availableLoopbackPort()
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: FakeRouter()),
            bootEpoch: 1,
            clientReceiveTimeoutSeconds: 60
        )
        let acceptedConnectionCount = LockedLifecycleInt()
        let webSocketWelcomeWritten = LockedLifecycleBool()
        server.acceptedFDObserverForTesting = { _ in
            acceptedConnectionCount.increment()
        }
        server.afterWelcomeWriteForTests = { _ in
            webSocketWelcomeWritten.value = true
        }
        var clients: [Int32] = []
        defer {
            server.stop()
            for descriptor in clients { Darwin.close(descriptor) }
        }

        try server.start()
        let eventCursor = EventBus.shared.snapshot().lastSeq
        let maximumConnections = DirectHTTPServer.maximumAcceptedConnections
        let excessConnections = 8
        let partialWebSocketHeader = Data(
            "GET /v1/ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n".utf8
        )

        // Stage the first cap - 1 clients behind explicit server-side
        // acceptance barriers. A successful client connect only enters the TCP
        // backlog; it does not prove registry ownership. Without these barriers,
        // a delayed initial peer can be mistaken for an admitted excess peer.
        let initialConnections = maximumConnections - 1
        let acceptanceBatchSize = 16
        for index in 0..<initialConnections {
            let descriptor = try connectLoopback(port: port)
            clients.append(descriptor)
            if !index.isMultiple(of: 2) {
                let written = partialWebSocketHeader.withUnsafeBytes { bytes in
                    Darwin.write(descriptor, bytes.baseAddress, bytes.count)
                }
                XCTAssertEqual(written, partialWebSocketHeader.count)
            }

            let createdConnections = index + 1
            if createdConnections.isMultiple(of: acceptanceBatchSize)
                || createdConnections == initialConnections {
                XCTAssertTrue(
                    waitUntil(timeout: 2) {
                        acceptedConnectionCount.value == createdConnections
                            && server.acceptedSocketCountForTests == createdConnections
                    },
                    "every staged client must enter current registry ownership before the next batch"
                )
            }
        }

        let webSocketSinceSequence = EventBus.shared.snapshot().lastSeq
        let completeWebSocketUpgrade = Data(
            ("GET /v1/ws HTTP/1.1\r\n" +
             "Host: localhost\r\n" +
             "Upgrade: websocket\r\n" +
             "Connection: Upgrade\r\n" +
             "Sec-WebSocket-Version: 13\r\n" +
             "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
             "X-RC2-Since-Seq: \(webSocketSinceSequence)\r\n\r\n").utf8
        )
        let webSocketClient = try connectLoopback(port: port)
        clients.append(webSocketClient)
        let webSocketWritten = completeWebSocketUpgrade.withUnsafeBytes { bytes in
            Darwin.write(webSocketClient, bytes.baseAddress, bytes.count)
        }
        XCTAssertEqual(webSocketWritten, completeWebSocketUpgrade.count)
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                acceptedConnectionCount.value == maximumConnections
                    && server.acceptedSocketCountForTests == maximumConnections
                    && webSocketWelcomeWritten.value
            },
            "idle and partial-header clients must never push accepted ownership beyond the hard cap"
        )
        XCTAssertLessThanOrEqual(server.acceptedSocketCountForTests, maximumConnections)
        XCTAssertTrue(
            waitForData(Data("HTTP/1.1 101".utf8), from: webSocketClient, timeout: 1),
            "a fully upgraded live WebSocket must remain inside the same accepted-socket cap"
        )
        var excessClients: [Int32] = []
        for _ in 0..<excessConnections {
            let descriptor = try connectLoopback(port: port)
            clients.append(descriptor)
            excessClients.append(descriptor)
        }

        var rejectedClients = Set<Int32>()
        XCTAssertTrue(
            waitUntil(timeout: 1) {
                for descriptor in excessClients where !rejectedClients.contains(descriptor) {
                    if peerIsClosed(descriptor) { rejectedClients.insert(descriptor) }
                }
                return rejectedClients.count == excessConnections
                    && acceptedConnectionCount.value == maximumConnections
                    && server.acceptedSocketCountForTests == maximumConnections
            },
            "the server must shutdown and close exactly the connections rejected at the cap"
        )
        XCTAssertEqual(
            rejectedClients.count,
            excessConnections,
            "accept scheduling may choose any excess peers, but it must reject every slot above the cap"
        )
        XCTAssertEqual(
            acceptedConnectionCount.value,
            maximumConnections,
            "no excess connection may pass the post-registration acceptance observer"
        )
        XCTAssertEqual(server.acceptedSocketCountForTests, maximumConnections)
        let limitDiagnostics = EventBus.shared.snapshot().recent.filter {
            $0.seq > eventCursor && $0.kind == "diagnostic.http_connection_limit"
        }
        XCTAssertEqual(limitDiagnostics.count, 1,
                       "a sustained saturation episode must publish one bounded diagnostic")

        server.stop()
        for descriptor in clients { Darwin.close(descriptor) }
        clients.removeAll()
        XCTAssertTrue(waitUntil(timeout: 2) { server.acceptedSocketCountForTests == 0 })
        let returnedToDescriptorBaseline = waitUntil(timeout: 2) {
            processOpenDescriptorCount() <= descriptorBaseline
        }
        XCTAssertTrue(
            returnedToDescriptorBaseline,
            "stop plus owner release must return the process to its descriptor baseline " +
                "(baseline: \(descriptorBaseline), current: \(processOpenDescriptorCount()))"
        )
    }

    @MainActor
    func test_rapidRestartRejectsStaleAcceptLoopsAndDoesNotGrowDescriptors() throws {
        // WHY: stop does not join the blocking accept thread. A stale thread
        // must never accept from a newly reused listener descriptor or retain
        // sockets from an earlier generation.
        let descriptorBaseline = processOpenDescriptorCount()
        XCTAssertGreaterThan(descriptorBaseline, 0)
        let port = try availableLoopbackPort()
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: FakeRouter()),
            bootEpoch: 1,
            clientReceiveTimeoutSeconds: 60
        )
        defer { server.stop() }
        let partialHeader = Data("GET /v1/health HTTP/1.1\r\nHost: localhost\r\n".utf8)

        for cycle in 0..<20 {
            try server.start()
            var clients: [Int32] = []
            for index in 0..<8 {
                let descriptor = try connectLoopback(port: port)
                clients.append(descriptor)
                if !index.isMultiple(of: 2) {
                    _ = partialHeader.withUnsafeBytes { bytes in
                        Darwin.write(descriptor, bytes.baseAddress, bytes.count)
                    }
                }
            }
            XCTAssertTrue(
                waitUntil(timeout: 1) { server.acceptedSocketCountForTests == clients.count },
                "cycle \(cycle) must transfer every client into current-generation ownership"
            )
            XCTAssertLessThanOrEqual(
                server.acceptedSocketCountForTests,
                DirectHTTPServer.maximumAcceptedConnections
            )

            server.stop()
            for descriptor in clients { Darwin.close(descriptor) }
            clients.removeAll()
            XCTAssertTrue(
                waitUntil(timeout: 1) { server.acceptedSocketCountForTests == 0 },
                "cycle \(cycle) must release every accepted descriptor"
            )
            XCTAssertTrue(
                waitUntil(timeout: 1) { processOpenDescriptorCount() <= descriptorBaseline },
                "cycle \(cycle) must return to the pre-start descriptor baseline"
            )
        }
    }

    func test_httpWorkerReadLoopsUseDescriptorGenerationGate() throws {
        // WHY: a shared lifecycle Bool is both a data race and the wrong
        // identity. A fast stop/start can make it true for generation N+1
        // while a generation-N header/body/WebSocket worker is still exiting.
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/SocketServer/HTTPServer.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("private var running"),
                       "HTTP lifecycle must not use an unsynchronized shared running flag")
        XCTAssertFalse(source.contains("while running"),
                       "every blocking worker loop must be gated by descriptor ownership")
        XCTAssertEqual(
            source.components(separatedBy: "while acceptedSockets.isActive(fd)").count - 1,
            4,
            "keep-alive session, header, body, and WebSocket reads must each use the generation-aware registry gate"
        )
        XCTAssertEqual(
            source.components(separatedBy: "Self.readRetryingInterrupts").count - 1,
            3,
            "header, body, and WebSocket reads must retry transient EINTR instead of dropping the mirror"
        )

        var interruptedReadAttempts = 0
        let recoveredRead = DirectHTTPServer.readRetryingInterrupts {
            interruptedReadAttempts += 1
            if interruptedReadAttempts == 1 {
                errno = EINTR
                return -1
            }
            return 7
        }
        XCTAssertEqual(recoveredRead, 7)
        XCTAssertEqual(interruptedReadAttempts, 2)

        var timedOutReadAttempts = 0
        let timedOutRead = DirectHTTPServer.readRetryingInterrupts {
            timedOutReadAttempts += 1
            errno = EAGAIN
            return -1
        }
        XCTAssertEqual(timedOutRead, -1)
        XCTAssertEqual(timedOutReadAttempts, 1, "receive timeouts must remain terminal")

        var endOfFileReadAttempts = 0
        let endOfFileRead = DirectHTTPServer.readRetryingInterrupts {
            endOfFileReadAttempts += 1
            return 0
        }
        XCTAssertEqual(endOfFileRead, 0)
        XCTAssertEqual(endOfFileReadAttempts, 1, "peer EOF must remain terminal")
    }

    @MainActor
    func test_fastRestartInvalidatesOldHeaderBodyAndWebSocketWorkersWhileNewHTTPWorks() throws {
        // WHY: stop followed immediately by start must invalidate every old
        // worker even when the new listener is already accepting successfully.
        let descriptorBaseline = processOpenDescriptorCount()
        XCTAssertGreaterThan(descriptorBaseline, 0)
        let port = try availableLoopbackPort()
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: FakeRouter()),
            bootEpoch: 1,
            clientReceiveTimeoutSeconds: 60
        )
        let observedReadWaits = LockedConnectionReadWaits()
        server.connectionReadWaitObserverForTesting = { _, stage in
            observedReadWaits.record(stage)
        }
        var clients: [Int32] = []
        defer {
            server.stop()
            for descriptor in clients { Darwin.close(descriptor) }
        }

        try server.start()
        let partialHeaderClient = try connectLoopback(port: port)
        clients.append(partialHeaderClient)
        let partialHeader = Data("GET /v1/health HTTP/1.1\r\nHost: localhost\r\n".utf8)
        let partialHeaderWritten = partialHeader.withUnsafeBytes {
            Darwin.write(partialHeaderClient, $0.baseAddress, $0.count)
        }
        XCTAssertEqual(partialHeaderWritten, partialHeader.count)
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                server.acceptedSocketCountForTests == 1
                    && observedReadWaits.contains(.header(bufferedBytes: partialHeader.count))
            },
            "the header worker must consume the exact incomplete request and await more bytes"
        )

        let partialBodyClient = try connectLoopback(port: port)
        clients.append(partialBodyClient)
        let partialBody = Data(
            ("POST /v1/rpc HTTP/1.1\r\n" +
             "Host: localhost\r\n" +
             "Content-Type: application/json\r\n" +
             "Content-Length: 128\r\n\r\n" +
             "{\"jsonrpc\":\"2.0\"").utf8
        )
        let partialBodyWritten = partialBody.withUnsafeBytes {
            Darwin.write(partialBodyClient, $0.baseAddress, $0.count)
        }
        XCTAssertEqual(partialBodyWritten, partialBody.count)
        let partialBodyByteCount = Data("{\"jsonrpc\":\"2.0\"".utf8).count
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                server.acceptedSocketCountForTests == 2
                    && observedReadWaits.contains(
                        .body(bufferedBytes: partialBodyByteCount, expectedBytes: 128)
                    )
            },
            "the body worker must consume the exact incomplete body and await the declared remainder"
        )

        let webSocketClient = try connectLoopback(port: port)
        clients.append(webSocketClient)
        // This lifecycle test is not replay coverage. Start at the shared
        // EventBus head so retained events from earlier suites cannot terminate
        // the WebSocket after its HTTP 101 response.
        let webSocketSinceSequence = EventBus.shared.snapshot().lastSeq
        let webSocketUpgrade = Data(
            ("GET /v1/ws HTTP/1.1\r\n" +
             "Host: localhost\r\n" +
             "Upgrade: websocket\r\n" +
             "Connection: Upgrade\r\n" +
             "Sec-WebSocket-Version: 13\r\n" +
             "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
             "X-RC2-Since-Seq: \(webSocketSinceSequence)\r\n\r\n").utf8
        )
        let webSocketUpgradeWritten = webSocketUpgrade.withUnsafeBytes {
            Darwin.write(webSocketClient, $0.baseAddress, $0.count)
        }
        XCTAssertEqual(webSocketUpgradeWritten, webSocketUpgrade.count)

        XCTAssertTrue(
            waitForData(Data("HTTP/1.1 101".utf8), from: webSocketClient, timeout: 1),
            "the old-generation WebSocket must be live before restart"
        )
        XCTAssertTrue(
            waitUntil(timeout: 1) {
                server.acceptedSocketCountForTests == 3
                    && observedReadWaits.contains(.webSocket)
            },
            "stage-specific header, body, and WebSocket read barriers must all be active before restart"
        )
        XCTAssertLessThanOrEqual(
            server.acceptedSocketCountForTests,
            DirectHTTPServer.maximumAcceptedConnections
        )

        server.stop()
        try server.start()

        let currentClient = try connectLoopback(port: port)
        clients.append(currentClient)
        let currentRequest = Data("GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        let currentRequestWritten = currentRequest.withUnsafeBytes {
            Darwin.write(currentClient, $0.baseAddress, $0.count)
        }
        XCTAssertEqual(currentRequestWritten, currentRequest.count)
        XCTAssertTrue(
            waitForData(Data("HTTP/1.1 200".utf8), from: currentClient, timeout: 1),
            "the current-generation connection must remain functional during old-worker teardown"
        )
        XCTAssertLessThanOrEqual(
            server.acceptedSocketCountForTests,
            DirectHTTPServer.maximumAcceptedConnections
        )

        // Old-generation workers must release during stop/start.
        for (name, descriptor) in [
            ("partial-header", partialHeaderClient),
            ("partial-body", partialBodyClient),
            ("old-websocket", webSocketClient),
        ] {
            XCTAssertTrue(
                waitForPeerClosure(descriptor, timeout: 1),
                "\(name) worker must release its peer during generation transition"
            )
        }
        // C-07: current-health may stay open (HTTP keep-alive idle). It is
        // only required to drop on the next stop, not immediately after 200.
        XCTAssertTrue(
            waitUntil(timeout: 1) { server.acceptedSocketCountForTests >= 1 },
            "keep-alive should retain the current-generation health connection until stop or idle timeout"
        )

        server.stop()
        XCTAssertTrue(
            waitForPeerClosure(currentClient, timeout: 1),
            "stop must reclaim the keep-alive health connection"
        )
        XCTAssertTrue(waitUntil(timeout: 2) { server.acceptedSocketCountForTests == 0 })

        for descriptor in clients { Darwin.close(descriptor) }
        clients.removeAll()
        XCTAssertTrue(
            waitUntil(timeout: 2) { processOpenDescriptorCount() <= descriptorBaseline },
            "fast restart must return to the descriptor baseline"
        )
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

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }

    private func waitForPeerClosure(_ descriptor: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var bytes = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            let received = Darwin.recv(descriptor, &bytes, bytes.count, MSG_DONTWAIT)
            if received == 0 { return true }
            if received < 0 {
                if errno == ECONNRESET || errno == ENOTCONN { return true }
                if errno != EAGAIN && errno != EWOULDBLOCK { return false }
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return false
    }

    private func peerIsClosed(_ descriptor: Int32) -> Bool {
        var byte: UInt8 = 0
        let received = Darwin.recv(descriptor, &byte, 1, MSG_DONTWAIT | MSG_PEEK)
        if received == 0 { return true }
        if received < 0 {
            return errno == ECONNRESET || errno == ENOTCONN
        }
        return false
    }

    private func waitForData(_ expected: Data, from descriptor: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var received = Data()
        var bytes = [UInt8](repeating: 0, count: 512)
        while Date() < deadline {
            let count = Darwin.recv(descriptor, &bytes, bytes.count, MSG_DONTWAIT)
            if count > 0 {
                received.append(bytes, count: count)
                if received.range(of: expected) != nil { return true }
            } else if count == 0 {
                return false
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                return false
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return false
    }

    private func processOpenDescriptorCount() -> Int {
        let capacityBytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard capacityBytes > 0 else { return -1 }
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: Int(capacityBytes) / MemoryLayout<proc_fdinfo>.stride
        )
        let usedBytes = descriptors.withUnsafeMutableBytes { bytes in
            proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, bytes.baseAddress, Int32(bytes.count))
        }
        guard usedBytes >= 0 else { return -1 }
        return Int(usedBytes) / MemoryLayout<proc_fdinfo>.stride
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

private final class LockedLifecycleBool: @unchecked Sendable {
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

private final class LockedLifecycleInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock(); storage += 1; lock.unlock()
    }
}

private final class LockedConnectionReadWaits: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Set<DirectHTTPServer.ConnectionReadWaitStageForTesting> = []

    func record(_ stage: DirectHTTPServer.ConnectionReadWaitStageForTesting) {
        lock.lock(); storage.insert(stage); lock.unlock()
    }

    func contains(_ stage: DirectHTTPServer.ConnectionReadWaitStageForTesting) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storage.contains(stage)
    }
}
