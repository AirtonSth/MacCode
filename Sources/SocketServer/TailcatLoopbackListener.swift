import Darwin
import Foundation

public protocol TailcatLoopbackListening: Sendable {
    @discardableResult
    func start() throws -> UInt16
    func stop()
}

public final class TailcatLoopbackListener: TailcatLoopbackListening, @unchecked Sendable {
    private let authenticator: TailcatRemoteConnectionAuthenticator
    private let lock = NSLock()
    private let preambleSockets = AcceptedSocketRegistry()
    private weak var httpServer: DirectHTTPServer?
    private var listenFD: Int32 = -1
    private var listenFD6: Int32 = -1
    private var boundPort: UInt16?

    public init(authenticator: TailcatRemoteConnectionAuthenticator) {
        self.authenticator = authenticator
    }

    deinit { stop() }

    public func setHTTPServer(_ server: DirectHTTPServer?) {
        lock.lock()
        httpServer = server
        lock.unlock()
    }

    @discardableResult
    public func start() throws -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        if let boundPort { return boundPort }

        // The direct/LAN server owns its configured public port. Let the kernel
        // choose a private per-launch port, then bind ::1 to that same port.
        let ipv4 = try Self.bindIPv4Loopback()
        do {
            let port = try Self.port(ofIPv4Socket: ipv4)
            let ipv6 = try Self.bindIPv6Loopback(port: port)
            let generation = preambleSockets.activate()
            listenFD = ipv4
            listenFD6 = ipv6
            boundPort = port
            Self.startAcceptThread(
                owner: self,
                descriptor: ipv4,
                generation: generation,
                name: "RC2.TailcatAccept4"
            )
            Self.startAcceptThread(
                owner: self,
                descriptor: ipv6,
                generation: generation,
                name: "RC2.TailcatAccept6"
            )
            return port
        } catch {
            Darwin.close(ipv4)
            throw error
        }
    }

    public func stop() {
        let server: DirectHTTPServer?
        lock.lock()
        preambleSockets.shutdownAll()
        if listenFD >= 0 {
            Darwin.shutdown(listenFD, SHUT_RDWR)
            Darwin.close(listenFD)
            listenFD = -1
        }
        if listenFD6 >= 0 {
            Darwin.shutdown(listenFD6, SHUT_RDWR)
            Darwin.close(listenFD6)
            listenFD6 = -1
        }
        boundPort = nil
        server = httpServer
        server?.shutdownTailcatConnections()
        lock.unlock()
    }

#if DEBUG
    var portForTesting: UInt16? {
        lock.lock(); defer { lock.unlock() }
        return boundPort
    }

    var boundAddressesForTesting: Set<String> {
        lock.lock(); defer { lock.unlock() }
        var addresses: Set<String> = []
        if listenFD >= 0 { addresses.insert("127.0.0.1") }
        if listenFD6 >= 0 { addresses.insert("::1") }
        return addresses
    }
#endif

    private static func startAcceptThread(
        owner: TailcatLoopbackListener,
        descriptor: Int32,
        generation: UInt64,
        name: String
    ) {
        let thread = Thread { [weak owner] in
            owner?.acceptLoop(descriptor: descriptor, generation: generation)
        }
        thread.name = name
        thread.start()
    }

    private func acceptLoop(descriptor: Int32, generation: UInt64) {
        while preambleSockets.isAccepting(generation: generation) {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let accepted = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(descriptor, $0, &length)
                }
            }
            if accepted < 0 {
                if !preambleSockets.isAccepting(generation: generation) { return }
                continue
            }
            guard DirectHTTPServer.enableCloseOnExec(accepted) else {
                Darwin.close(accepted)
                continue
            }
            var noSIGPIPE: Int32 = 1
            setsockopt(
                accepted,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSIGPIPE,
                socklen_t(MemoryLayout<Int32>.size)
            )
            guard case .accepted = preambleSockets.register(accepted, generation: generation) else {
                continue
            }
            let peer = DirectHTTPServer.peerIP(storage)
            let thread = Thread { [weak self] in
                guard let self else {
                    Darwin.close(accepted)
                    return
                }
                self.handle(fd: accepted, peer: peer)
            }
            thread.name = "rc2.tailcat.\(accepted)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    private func handle(fd: Int32, peer: String) {
        guard case .remoteAuthenticated = authenticator.classify(fd: fd, ordinaryReadTimeout: 2) else {
            preambleSockets.close(fd)
            return
        }
        lock.lock()
        guard preambleSockets.isActive(fd), let server = httpServer else {
            lock.unlock()
            preambleSockets.close(fd)
            return
        }
        guard server.registerTailcatConnection(fd: fd) else {
            preambleSockets.closeWithoutClosing(fd)
            lock.unlock()
            return
        }
        preambleSockets.closeWithoutClosing(fd)
        lock.unlock()
        server.serveTailcatConnection(fd: fd, peer: peer)
    }

    private static func bindIPv4Loopback() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        do {
            try configure(fd: fd)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0, Darwin.listen(fd, 32) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func bindIPv6Loopback(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        do {
            try configure(fd: fd)
            var yes: Int32 = 1
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(port).bigEndian
            address.sin6_addr = in6addr_loopback
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            guard result == 0, Darwin.listen(fd, 32) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func configure(fd: Int32) throws {
        guard DirectHTTPServer.enableCloseOnExec(fd) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func port(ofIPv4Socket fd: Int32) throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        let port = UInt16(bigEndian: address.sin_port)
        guard result == 0, port > 0 else { throw POSIXError(.EIO) }
        return port
    }
}
