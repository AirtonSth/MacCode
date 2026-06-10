import Foundation
import Darwin

/// Pure helper: builds the `server.listener` EventBus event payload for the
/// Unix-domain socket server. Mirrors `serverListenerEventPayload` in
/// HTTPServer.swift so subscribers can treat both servers uniformly.
/// - Parameters:
///   - bound: `true` on success, `false` on failure.
///   - path: The filesystem path the socket was (attempted to be) bound to.
public func unixSocketListenerEventPayload(bound: Bool, path: String) -> [String: Any] {
    return [
        "bound": bound,
        "address": path,
        "port": 0
    ]
}

public final class UnixSocketServer: @unchecked Sendable {
    private static let maxClientLineBytes = 1024 * 1024

    public let socketPath: String
    private let dispatcher: JSONRPCDispatcher
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private var running = false

    public init(socketPath: String, dispatcher: JSONRPCDispatcher) {
        self.socketPath = socketPath
        self.dispatcher = dispatcher
    }

    public func start() throws {
        unlink(socketPath)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        if listenFD < 0 { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        if pathBytes.count > maxPath {
            throw NSError(domain: "RemoteCode.Socket", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket path too long: \(socketPath)"])
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tp in
            tp.withMemoryRebound(to: CChar.self, capacity: maxPath) { tbase in
                pathBytes.withUnsafeBufferPointer { src in
                    for i in 0..<src.count { tbase[i] = src[i] }
                }
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(listenFD, sa, addrLen)
            }
        }
        if bindResult < 0 {
            let msg = String(cString: strerror(errno))
            close(listenFD)
            let failPayload = unixSocketListenerEventPayload(bound: false, path: socketPath)
            EventBus.shared.publish(kind: "server.listener", payload: .object(failPayload.mapValues { v -> JSONValue in
                if let b = v as? Bool { return .bool(b) }
                if let i = v as? Int { return .number(Double(i)) }
                if let s = v as? String { return .string(s) }
                return .string("\(v)")
            }))
            throw NSError(domain: "RemoteCode.Socket", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "bind: \(msg)"])
        }
        if Darwin.listen(listenFD, 16) < 0 {
            let msg = String(cString: strerror(errno))
            close(listenFD)
            let failPayload = unixSocketListenerEventPayload(bound: false, path: socketPath)
            EventBus.shared.publish(kind: "server.listener", payload: .object(failPayload.mapValues { v -> JSONValue in
                if let b = v as? Bool { return .bool(b) }
                if let i = v as? Int { return .number(Double(i)) }
                if let s = v as? String { return .string(s) }
                return .string("\(v)")
            }))
            throw NSError(domain: "RemoteCode.Socket", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "listen: \(msg)"])
        }
        // tighten permissions
        chmod(socketPath, 0o600)
        running = true

        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "RC2.SocketAccept"
        t.start()
        acceptThread = t

        // Publish success event so AppDelegate (or any observer) can surface
        // the server status without polling. Mirrors HTTPServer's pattern.
        let successPayload = unixSocketListenerEventPayload(bound: true, path: socketPath)
        EventBus.shared.publish(kind: "server.listener", payload: .object(successPayload.mapValues { v -> JSONValue in
            if let b = v as? Bool { return .bool(b) }
            if let i = v as? Int { return .number(Double(i)) }
            if let s = v as? String { return .string(s) }
            return .string("\(v)")
        }))
    }

    public func stop() {
        running = false
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    private func acceptLoop() {
        while running {
            var clientAddr = sockaddr()
            var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listenFD, &clientAddr, &clientLen)
            if client < 0 {
                if !running { return }
                continue
            }
            disableSIGPIPE(fd: client)
            DispatchQueue.global().async { [weak self] in
                self?.handleClient(fd: client)
            }
        }
    }

    private func disableSIGPIPE(fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    private func handleClient(fd: Int32) {
        var streamSubID: UUID?
        let writeQueue = DispatchQueue(label: "rc2.unix.write")
        defer {
            if let s = streamSubID { EventBus.shared.unsubscribe(s) }
            writeQueue.sync {}
            close(fd)
        }
        var buffer = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while running {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            buffer.append(tmp, count: n)
            if buffer.count > Self.maxClientLineBytes {
                return
            }
            // process line-delimited JSON
            while let nlIdx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nlIdx)
                buffer.removeSubrange(buffer.startIndex...nlIdx)
                if lineData.isEmpty { continue }
                // Special-case events.stream so this connection becomes a
                // long-lived event feed instead of a single request/response.
                if let req = try? JSONDecoder().decode(JSONRPCRequest.self, from: lineData),
                   req.method == "events.stream" {
                    let since: Int64 = req.params?["after_seq"]?.intValue.map(Int64.init) ?? 0
                    let id = EventBus.shared.subscribe(since: since) { [weak self] ev in
                        guard let self else { return }
                        let payload: [String: JSONValue] = [
                            "seq": .number(Double(ev.seq)),
                            "kind": .string(ev.kind),
                            "ts": .number(ev.ts),
                            "payload": ev.payload
                        ]
                        let resp = JSONRPCResponse(id: req.id, result: .object(payload))
                        writeQueue.async { self.write(fd: fd, response: resp) }
                    }
                    streamSubID = id
                    // ack
                    let ack = JSONRPCResponse(id: req.id, result: .object([
                        "subscribed": .bool(true)
                    ]))
                    writeQueue.sync { write(fd: fd, response: ack) }
                    continue
                }
                respond(fd: fd, lineData: lineData, writeQueue: writeQueue)
            }
        }
    }

    private func respond(fd: Int32, lineData: Data, writeQueue: DispatchQueue) {
        let decoder = JSONDecoder()
        do {
            let req = try decoder.decode(JSONRPCRequest.self, from: lineData)
            let semaphore = DispatchSemaphore(value: 0)
            final class Slot: @unchecked Sendable { var value: JSONRPCResponse? }
            let slot = Slot()
            // The CommandRouting conformance is @preconcurrency, so the
            // compiler will not insert an actor hop when the dispatcher
            // calls a main-actor method. We hop to the main thread
            // ourselves before dispatching, and inherit that thread into
            // the Task so any synchronous calls into AppKit/SwiftUI
            // happen on the main thread.
            DispatchQueue.main.async {
                let task = Task { @MainActor in
                    let resp = await self.dispatcher.dispatch(req)
                    slot.value = resp
                    semaphore.signal()
                }
                _ = task // silence unused warning
            }
            semaphore.wait()
            if let resp = slot.value {
                writeQueue.sync { write(fd: fd, response: resp) }
            }
        } catch {
            let resp = JSONRPCResponse(id: nil, error: .parseError)
            writeQueue.sync { write(fd: fd, response: resp) }
        }
    }

    private func write(fd: Int32, response: JSONRPCResponse) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return }
                written += n
            }
        }
    }
}
