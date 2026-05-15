import Foundation
import Darwin

/// Minimal HTTP/1.1 + WebSocket-stub server used as the desktop-side
/// foundation for a future direct-VPN/LAN mobile client. The intent is
/// architectural readiness (no relay, no cloud broker, loopback-only by
/// default); not to ship a full WebSocket protocol implementation in V1.
///
/// Endpoints in V1:
/// - GET  /v1/discovery
/// - GET  /v1/capabilities
/// - GET  /healthz
public final class DirectHTTPServer: @unchecked Sendable {
    public let port: UInt16
    public let bindLoopbackOnly: Bool
    public let dispatcher: JSONRPCDispatcher

    private var listenFD: Int32 = -1
    private var running = false
    private var accept: Thread?

    public init(port: UInt16 = 18217, loopbackOnly: Bool = true, dispatcher: JSONRPCDispatcher) {
        self.port = port
        self.bindLoopbackOnly = loopbackOnly
        self.dispatcher = dispatcher
    }

    public func start() throws {
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        if listenFD < 0 { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = bindLoopbackOnly ? inet_addr("127.0.0.1") : INADDR_ANY.bigEndian
        let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listenFD, $0, addrLen) }
        }
        if rc < 0 {
            let msg = String(cString: strerror(errno))
            close(listenFD); listenFD = -1
            throw NSError(domain: "RC2.HTTP", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        if Darwin.listen(listenFD, 32) < 0 {
            close(listenFD); listenFD = -1
            throw POSIXError(.EIO)
        }
        running = true
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "RC2.HTTPAccept"
        t.start()
        accept = t
    }

    public func stop() {
        running = false
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            listenFD = -1
        }
    }

    private func acceptLoop() {
        while running {
            var caddr = sockaddr()
            var clen = socklen_t(MemoryLayout<sockaddr>.size)
            let fd = Darwin.accept(listenFD, &caddr, &clen)
            if fd < 0 { if !running { return }; continue }
            DispatchQueue.global().async { [weak self] in self?.handle(fd: fd) }
        }
    }

    private func handle(fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while running {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { return }
            buffer.append(tmp, count: n)
            // crude: wait for blank line
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return }
        let lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let path = String(parts[1])

        switch (method, path) {
        case ("GET", "/healthz"):
            send(fd: fd, status: 200, contentType: "text/plain", body: "ok\n".data(using: .utf8)!)
        case ("GET", "/v1/discovery"):
            let body: [String: Any] = [
                "server_id": ProcessInfo.processInfo.globallyUniqueString,
                "app": "remotecode2",
                "version": "0.1.0",
                "api_version": "2",
                "capabilities_version": "1",
                "auth_mode": "loopback-anonymous",
                "transports": ["http", "ws"],
                "host": "127.0.0.1",
                "port": port,
                "vpn_required": !bindLoopbackOnly,
                "relay": false
            ]
            sendJSON(fd: fd, status: 200, body: body)
        case ("GET", "/v1/capabilities"):
            let body: [String: Any] = [
                "surface_types": ["terminal", "browser", "agentApp"],
                "agent": ["providers": ["codex", "claude"]],
                "browser_automation": ["p0": ["navigate", "back", "forward", "reload", "url.get"], "p1_unsupported": true],
                "git": ["read_only": true],
                "feature_flags": ["remote_access_enabled": !bindLoopbackOnly]
            ]
            sendJSON(fd: fd, status: 200, body: body)
        default:
            send(fd: fd, status: 404, contentType: "text/plain", body: "not found\n".data(using: .utf8)!)
        }
    }

    private func send(fd: Int32, status: Int, contentType: String, body: Data) {
        let head = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        out.withUnsafeBytes { ptr in _ = Darwin.write(fd, ptr.baseAddress, out.count) }
    }

    private func sendJSON(fd: Int32, status: Int, body: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        send(fd: fd, status: status, contentType: "application/json", body: data)
    }

    private func reasonPhrase(_ s: Int) -> String {
        switch s { case 200: return "OK"; case 404: return "Not Found"; default: return "OK" }
    }
}
