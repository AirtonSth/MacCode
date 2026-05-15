import Foundation
import Darwin
import CryptoKit

/// Minimal HTTP/1.1 + WebSocket-stub server used as the desktop-side
/// foundation for a future direct-VPN/LAN mobile client. The intent is
/// architectural readiness (no relay, no cloud broker, loopback-only by
/// default); not to ship a full WebSocket protocol implementation in V1.
///
/// Endpoints in V1:
/// - GET  /v1/discovery
/// - GET  /v1/capabilities
/// - GET  /healthz
public protocol DirectAuthProvider: AnyObject {
    func verify(token: String) -> Bool
    func createPairingCode() -> String?
    func redeemPairingCode(_ code: String, deviceName: String) -> (deviceId: String, token: String)?
    func listDevices() -> [[String: Any]]
    func revokeDevice(_ id: String)
}

public final class DirectHTTPServer: @unchecked Sendable {
    public let port: UInt16
    public let bindLoopbackOnly: Bool
    public let dispatcher: JSONRPCDispatcher
    public weak var auth: DirectAuthProvider?

    private var listenFD: Int32 = -1
    private var running = false
    private var accept: Thread?

    public init(port: UInt16 = 18217, loopbackOnly: Bool = true, dispatcher: JSONRPCDispatcher, auth: DirectAuthProvider? = nil) {
        self.port = port
        self.bindLoopbackOnly = loopbackOnly
        self.dispatcher = dispatcher
        self.auth = auth
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
        var subID: UUID?
        defer {
            if let s = subID { EventBus.shared.unsubscribe(s) }
            close(fd)
        }
        var buffer = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while running {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { return }
            buffer.append(tmp, count: n)
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

        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let r = line.range(of: ":") {
                let k = String(line[..<r.lowerBound]).lowercased().trimmingCharacters(in: .whitespaces)
                let v = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }

        // Read remaining body bytes if Content-Length declares more
        // than we already have.
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStartAbsolute = headerEnd.upperBound
        var bodyHave = buffer.count - bodyStartAbsolute
        while running, bodyHave < contentLength {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            buffer.append(tmp, count: n)
            bodyHave += n
        }

        // WebSocket upgrade
        if method == "GET", path == "/v1/ws",
           headers["upgrade"]?.lowercased() == "websocket",
           let key = headers["sec-websocket-key"] {
            performWSHandshake(fd: fd, key: key)
            // bind subscription
            let id = EventBus.shared.subscribe(since: 0) { [weak self] ev in
                guard let self else { return }
                let obj: [String: Any] = [
                    "seq": ev.seq,
                    "kind": ev.kind,
                    "ts": ev.ts,
                    "payload": Self.jsonValueToAny(ev.payload)
                ]
                guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
                self.sendWSText(fd: fd, data: data)
            }
            subID = id
            // keep connection open; read incoming frames (ping/pong/close)
            wsServeLoop(fd: fd)
            return
        }

        // Auth gate: when not loopback-only, require valid token for /v1/*
        // (except /v1/discovery, /v1/pair, /v1/pair/redeem).
        if !bindLoopbackOnly, path.hasPrefix("/v1"),
           !["/v1/discovery", "/v1/pair", "/v1/pair/redeem"].contains(path),
           let auth = auth {
            let token = headers["authorization"].flatMap { $0.split(separator: " ").last.map(String.init) } ?? headers["x-rc2-token"]
            if let t = token, auth.verify(token: t) {
                // ok
            } else {
                send(fd: fd, status: 401, contentType: "text/plain", body: "unauthorized\n".data(using: .utf8)!); return
            }
        }

        // POST body for pair endpoints; honor Content-Length read above.
        let bodyData = buffer.subdata(in: bodyStartAbsolute..<min(bodyStartAbsolute + contentLength, buffer.endIndex))

        switch (method, path) {
        case ("GET", "/healthz"):
            send(fd: fd, status: 200, contentType: "text/plain", body: "ok\n".data(using: .utf8)!)
        case ("POST", "/v1/pair"):
            guard let auth = auth, let code = auth.createPairingCode() else {
                send(fd: fd, status: 503, contentType: "text/plain", body: "pairing disabled\n".data(using: .utf8)!); return
            }
            sendJSON(fd: fd, status: 200, body: ["code": code, "expires_in": 600])
        case ("POST", "/v1/pair/redeem"):
            guard let auth = auth,
                  let obj = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
                  let code = obj["code"] as? String,
                  let name = obj["device_name"] as? String else {
                send(fd: fd, status: 400, contentType: "text/plain", body: "bad request\n".data(using: .utf8)!); return
            }
            if let (deviceId, token) = auth.redeemPairingCode(code, deviceName: name) {
                sendJSON(fd: fd, status: 200, body: ["device_id": deviceId, "token": token])
            } else {
                send(fd: fd, status: 410, contentType: "text/plain", body: "code expired or already redeemed\n".data(using: .utf8)!)
            }
        case ("GET", "/v1/devices"):
            guard let auth = auth else { send(fd: fd, status: 503, contentType: "text/plain", body: "disabled\n".data(using: .utf8)!); return }
            sendJSON(fd: fd, status: 200, body: ["devices": auth.listDevices()])
        case ("POST", "/v1/devices/revoke"):
            guard let auth = auth,
                  let obj = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
                  let id = obj["id"] as? String else {
                send(fd: fd, status: 400, contentType: "text/plain", body: "bad request\n".data(using: .utf8)!); return
            }
            auth.revokeDevice(id)
            sendJSON(fd: fd, status: 200, body: ["revoked": id])
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
        switch s { case 200: return "OK"; case 404: return "Not Found"; case 101: return "Switching Protocols"; default: return "OK" }
    }

    // MARK: WebSocket

    private static let wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    private func performWSHandshake(fd: Int32, key: String) {
        let toHash = key + Self.wsGUID
        let digest = Insecure.SHA1.hash(data: Data(toHash.utf8))
        let accept = Data(digest).base64EncodedString()
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        let data = Data(head.utf8)
        data.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, data.count) }
    }

    private func sendWSText(fd: Int32, data: Data) {
        // server frames are unmasked
        var frame = Data()
        frame.append(0x81) // FIN + text
        let len = data.count
        if len <= 125 {
            frame.append(UInt8(len))
        } else if len <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(len >> 8)); frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((len >> shift) & 0xFF))
            }
        }
        frame.append(data)
        frame.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, frame.count) }
    }

    private func wsServeLoop(fd: Int32) {
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while running {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { return }
            buf.append(tmp, count: n)
            while let (frame, consumed) = parseClientFrame(buf) {
                buf.removeFirst(consumed)
                switch frame.opcode {
                case 0x8: // close
                    sendCloseFrame(fd: fd); return
                case 0x9: // ping -> pong
                    sendPongFrame(fd: fd, payload: frame.payload)
                case 0xA: // pong
                    continue
                case 0x1, 0x2:
                    continue // client text/binary -- ignore for now
                default: continue
                }
            }
        }
    }

    private struct WSFrame { let opcode: UInt8; let payload: Data }

    private func parseClientFrame(_ buf: Data) -> (WSFrame, Int)? {
        guard buf.count >= 2 else { return nil }
        let b0 = buf[buf.startIndex]
        let b1 = buf[buf.index(buf.startIndex, offsetBy: 1)]
        let opcode = b0 & 0x0F
        let masked = (b1 & 0x80) != 0
        var len = Int(b1 & 0x7F)
        var idx = 2
        if len == 126 {
            guard buf.count >= 4 else { return nil }
            len = (Int(buf[buf.index(buf.startIndex, offsetBy: 2)]) << 8) | Int(buf[buf.index(buf.startIndex, offsetBy: 3)])
            idx = 4
        } else if len == 127 {
            guard buf.count >= 10 else { return nil }
            len = 0
            for i in 0..<8 { len = (len << 8) | Int(buf[buf.index(buf.startIndex, offsetBy: 2 + i)]) }
            idx = 10
        }
        var maskKey: [UInt8] = [0, 0, 0, 0]
        if masked {
            guard buf.count >= idx + 4 else { return nil }
            for i in 0..<4 { maskKey[i] = buf[buf.index(buf.startIndex, offsetBy: idx + i)] }
            idx += 4
        }
        guard buf.count >= idx + len else { return nil }
        var payload = Data(count: len)
        for i in 0..<len {
            let b = buf[buf.index(buf.startIndex, offsetBy: idx + i)]
            payload[i] = masked ? (b ^ maskKey[i % 4]) : b
        }
        return (WSFrame(opcode: opcode, payload: payload), idx + len)
    }

    private func sendPongFrame(fd: Int32, payload: Data) {
        var frame = Data()
        frame.append(0x8A) // FIN + pong
        frame.append(UInt8(payload.count))
        frame.append(payload)
        frame.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, frame.count) }
    }

    private func sendCloseFrame(fd: Int32) {
        var frame = Data()
        frame.append(0x88) // FIN + close
        frame.append(0x00) // empty payload
        frame.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, frame.count) }
    }

    static func jsonValueToAny(_ v: JSONValue) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(jsonValueToAny)
        case .object(let o):
            var out: [String: Any] = [:]
            for (k, vv) in o { out[k] = jsonValueToAny(vv) }
            return out
        }
    }
}
