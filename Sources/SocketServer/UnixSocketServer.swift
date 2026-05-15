import Foundation
import Darwin

public final class UnixSocketServer: @unchecked Sendable {
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
            throw NSError(domain: "RemoteCode2.Socket", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket path too long: \(socketPath)"])
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
            throw NSError(domain: "RemoteCode2.Socket", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "bind: \(msg)"])
        }
        if Darwin.listen(listenFD, 16) < 0 {
            let msg = String(cString: strerror(errno))
            close(listenFD)
            throw NSError(domain: "RemoteCode2.Socket", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "listen: \(msg)"])
        }
        // tighten permissions
        chmod(socketPath, 0o600)
        running = true

        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "RC2.SocketAccept"
        t.start()
        acceptThread = t
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
            DispatchQueue.global().async { [weak self] in
                self?.handleClient(fd: client)
            }
        }
    }

    private func handleClient(fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while running {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            buffer.append(tmp, count: n)
            // process line-delimited JSON
            while let nlIdx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nlIdx)
                buffer.removeSubrange(buffer.startIndex...nlIdx)
                if lineData.isEmpty { continue }
                respond(fd: fd, lineData: lineData)
            }
        }
    }

    private func respond(fd: Int32, lineData: Data) {
        let decoder = JSONDecoder()
        do {
            let req = try decoder.decode(JSONRPCRequest.self, from: lineData)
            let semaphore = DispatchSemaphore(value: 0)
            var captured: JSONRPCResponse?
            Task {
                let resp = await self.dispatcher.dispatch(req)
                captured = resp
                semaphore.signal()
            }
            semaphore.wait()
            if let resp = captured {
                write(fd: fd, response: resp)
            }
        } catch {
            let resp = JSONRPCResponse(id: nil, error: .parseError)
            write(fd: fd, response: resp)
        }
    }

    private func write(fd: Int32, response: JSONRPCResponse) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { ptr in
            _ = Darwin.write(fd, ptr.baseAddress, data.count)
        }
    }
}
