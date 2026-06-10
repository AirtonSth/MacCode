import Foundation
import Darwin
import CryptoKit
import Persistence

/// Minimal HTTP/1.1 + WebSocket-stub server used as the desktop-side
/// foundation for a future direct-VPN/LAN mobile client. The intent is
/// architectural readiness (no relay, no cloud broker, loopback-only by
/// default); not to ship a full WebSocket protocol implementation in V1.
///
/// Endpoints in V1:
/// - GET  /v1/discovery
/// - GET  /v1/capabilities
/// - GET  /healthz
/// - GET  /__rc2_static/<grant>/<relative-path>
public protocol DirectAuthProvider: AnyObject {
    func verify(token: String) -> Bool
    func createPairingCode() -> String?
    func redeemPairingCode(_ code: String, deviceName: String) -> (deviceId: String, token: String)?
    /// Device-initiated: create a request and surface a Mac-side
    /// approve/deny modal. Returns the request id + the code to display.
    func createPairingRequest(deviceName: String) -> (requestId: String, code: String)?
    func createPairingRequest(deviceName: String, privateAccountAccessToken: String?) -> (requestId: String, code: String)?
    /// Poll a request. `token` is non-nil exactly once, on the first
    /// poll after approval, and is never persisted server-side.
    func pairingRequestStatus(requestId: String) -> (status: String, deviceId: String?, token: String?)?
    func listDevices() -> [[String: Any]]
    func revokeDevice(_ id: String)
}

/// Defaulted so existing conformers (e.g. test doubles) need no change
/// until they opt into the request/approve flow.
public extension DirectAuthProvider {
    func createPairingRequest(deviceName: String) -> (requestId: String, code: String)? { nil }
    func createPairingRequest(deviceName: String, privateAccountAccessToken: String?) -> (requestId: String, code: String)? {
        createPairingRequest(deviceName: deviceName)
    }
    func pairingRequestStatus(requestId: String) -> (status: String, deviceId: String?, token: String?)? { nil }
}

public final class DirectHTTPServer: @unchecked Sendable {
    static let maxRequestHeaderBytes = 64 * 1024
    static let maxRequestBodyBytes = 2 * 1024 * 1024
    static let maxClientFramePayloadBytes = 1024 * 1024
    static let maxWebSocketOutboundQueuedBytes = 1024 * 1024
    static let wsHeartbeatInterval: TimeInterval = 20

    public let port: UInt16
    public let bindLoopbackOnly: Bool
    public let dispatcher: JSONRPCDispatcher
    public weak var auth: DirectAuthProvider?
    /// Stable, persisted host identity. iOS pins this (RCA-022); it must
    /// survive process restarts or every relaunch looks like a different
    /// Mac and forces a re-pair (GAP-2).
    public let serverId: String

    /// Per-peer brute-force brake for the LAN pairing endpoints. The 6-digit
    /// code is brute-forceable over LAN without this throttle.
    let pairingThrottle = PairingThrottle()

    private var listenFD: Int32 = -1
    private var running = false
    private var accept: Thread?

    public init(port: UInt16 = 18217, loopbackOnly: Bool = true, dispatcher: JSONRPCDispatcher, auth: DirectAuthProvider? = nil, serverId: String = ProcessInfo.processInfo.globallyUniqueString) {
        self.port = port
        self.bindLoopbackOnly = loopbackOnly
        self.dispatcher = dispatcher
        self.auth = auth
        self.serverId = serverId
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
            disableSIGPIPE(fd: fd)
            let peer = Self.peerIP(caddr)
            DispatchQueue.global().async { [weak self] in self?.handle(fd: fd, peer: peer) }
        }
    }

    private func disableSIGPIPE(fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Numeric source IP of an accepted connection, used as the throttle key.
    /// Falls back to "unknown" so a peer we can't parse still shares a single
    /// throttle bucket rather than bypassing the limiter.
    static func peerIP(_ addr: sockaddr) -> String {
        var addr = addr
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(addr.sa_len)
        let rc = withUnsafePointer(to: &addr) { ptr in
            getnameinfo(ptr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        }
        return rc == 0 ? String(cString: host) : "unknown"
    }

    private func handle(fd: Int32, peer: String) {
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
            if buffer.count > Self.maxRequestHeaderBytes {
                send(fd: fd, status: 431, contentType: "text/plain", body: Data("request header too large\n".utf8))
                return
            }
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
        let requestTarget = String(parts[1])
        let path = requestTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? requestTarget

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
        let contentLength: Int
        if let rawContentLength = headers["content-length"] {
            guard let parsed = Int(rawContentLength), parsed >= 0 else {
                send(fd: fd, status: 400, contentType: "text/plain", body: Data("bad content length\n".utf8))
                return
            }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        guard contentLength <= Self.maxRequestBodyBytes else {
            send(fd: fd, status: 413, contentType: "text/plain", body: Data("request body too large\n".utf8))
            return
        }
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
            let wsCompressionEnabled = headers["x-rc2-ws-encoding"]?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .contains(PayloadCodec.lzfse.wireName) == true
            let wsFilter = EventStreamFilter.parse(headers["x-rc2-ws-filter"])
            let subIDBox = LockedSubscriberID()
            let outbound = WebSocketOutboundQueue(
                maxQueuedBytes: Self.maxWebSocketOutboundQueuedBytes,
                writer: { [weak self] data in
                    guard let self else { return false }
                    return self.sendWSEvent(fd: fd, data: data, compressed: wsCompressionEnabled)
                },
                onClose: { [weak self] reason in
                    // QA-008: structured log on the WS slow-client disconnect
                    // path so flaky-sync reports are diagnosable beyond the
                    // single diagnostic.ws_slow_client event.
                    NSLog("[RC2.WS] slow-client close: reason=%@ baseline_required=true", reason)
                    if let id = subIDBox.value { EventBus.shared.unsubscribe(id) }
                    EventBus.shared.publish(kind: "diagnostic.ws_slow_client", payload: .object([
                        "reason": .string(reason),
                        "baseline_required": .bool(true)
                    ]))
                    // UX-001: tell the client *why* the socket is closing and
                    // what to do, so it can show a transient banner and
                    // auto-reconnect with a baseline instead of silently freezing.
                    if let self,
                       let closeObj = try? JSONSerialization.data(withJSONObject: [
                           "type": "server_close",
                           "reason": reason,
                           "action": "reconnect_with_baseline"
                       ]) {
                        self.sendWSText(fd: fd, data: closeObj)
                    }
                    shutdown(fd, SHUT_RDWR)
                }
            )
            let batcher = WebSocketEventBatcher(enabled: wsFilter == .cellularSafe,
                                                filter: wsFilter) { data in
                _ = outbound.enqueue(data)
            }
            let id = EventBus.shared.subscribe(since: 0, filter: wsFilter) { ev in
                let obj: [String: Any] = [
                    "seq": ev.seq,
                    "kind": ev.kind,
                    "ts": ev.ts,
                    "payload": Self.jsonValueToAny(ev.payload)
                ]
                guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
                batcher.enqueue(event: ev, data: data)
            }
            subIDBox.value = id
            subID = id
            // UX-003: server-initiated heartbeat so the client can tell
            // "idle but healthy" from "silently dead socket" and surface an
            // honest live/stale indicator ("last synced Ns ago"). Seq-less so
            // it never collides with the ordered event stream.
            let heartbeat = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
            heartbeat.schedule(deadline: .now() + Self.wsHeartbeatInterval, repeating: Self.wsHeartbeatInterval)
            heartbeat.setEventHandler {
                guard let data = try? JSONSerialization.data(withJSONObject: [
                    "type": "heartbeat",
                    "ts": Date().timeIntervalSince1970
                ]) else { return }
                _ = outbound.enqueue(data)
            }
            heartbeat.resume()
            // keep connection open; read incoming frames (ping/pong/close)
            wsServeLoop(fd: fd, outbound: outbound)
            heartbeat.cancel()
            outbound.drain()
            return
        }

        if method == "GET", path.hasPrefix(DirectStaticFileRegistry.routePrefix) {
            guard let file = DirectStaticFileRegistry.shared.resolve(routePath: path) else {
                send(fd: fd, status: 404, contentType: "text/plain", body: Data("not found\n".utf8))
                return
            }
            sendFile(fd: fd, status: 200, contentType: file.contentType, url: file.url)
            return
        }

        // Auth gate: when not loopback-only, require valid token for /v1/*
        // except the pre-token discovery/pairing surface. GAP-9:
        // /v1/capabilities is fetched UNauthenticated by the mobile
        // client before a token exists (mirrors /v1/discovery); gating
        // it makes every LAN connect fail with 401 → permanent
        // "Not authorized". It must be exempt like discovery.
        if !bindLoopbackOnly, path.hasPrefix("/v1"),
           !["/v1/discovery", "/v1/capabilities", "/v1/pair", "/v1/pair/redeem", "/v1/pair/status"].contains(path),
           let auth = auth {
            let token = headers["authorization"].flatMap { $0.split(separator: " ").last.map(String.init) } ?? headers["x-rc2-token"]
            if let t = token, auth.verify(token: t) {
                // ok
            } else {
                send(fd: fd, status: 401, contentType: "text/plain", body: "unauthorized\n".data(using: .utf8)!); return
            }
        }

        // POST body for pair endpoints; honor Content-Length read above.
        var bodyData = buffer.subdata(in: bodyStartAbsolute..<min(bodyStartAbsolute + contentLength, buffer.endIndex))
        if let contentEncoding = headers["content-encoding"], !contentEncoding.isEmpty {
            do {
                bodyData = try PayloadCodec.codec(for: contentEncoding).decode(bodyData, expectedSize: nil)
            } catch {
                send(fd: fd, status: 400, contentType: "text/plain", body: Data("bad encoded body\n".utf8))
                return
            }
            guard bodyData.count <= Self.maxRequestBodyBytes else {
                send(fd: fd, status: 413, contentType: "text/plain", body: Data("request body too large\n".utf8))
                return
            }
        }

        switch (method, path) {
        case ("GET", "/healthz"):
            send(fd: fd, status: 200, contentType: "text/plain", body: "ok\n".data(using: .utf8)!)
        case ("GET", "/v1/health"):
            // IMP-MAC_SERVER_SYNC-009: authenticated sync diagnostics so
            // power users / support can answer "why is sync slow". Gated by
            // the /v1 auth check above (not in the exempt list). Sourced from
            // EventBus's public snapshot — last emitted seq plus the retained
            // replay window (count + encoded bytes) the client re-baselines
            // against. Subscriber/WS-client counts and provider-session status
            // need the reserved EventBus/Dispatcher surface and are omitted.
            let snap = EventBus.shared.snapshot()
            let retainedBytes = snap.recent.reduce(0) { acc, ev in
                acc + ((try? JSONEncoder().encode(ev).count) ?? 0)
            }
            let body: [String: Any] = [
                "status": "ok",
                "server_id": serverId,
                "server_time": Date().timeIntervalSince1970,
                "events": [
                    "last_seq": snap.lastSeq,
                    "retained_count": snap.recent.count,
                    "retained_bytes": retainedBytes,
                    "oldest_retained_seq": snap.recent.first?.seq ?? 0
                ]
            ]
            sendJSON(fd: fd, status: 200, body: body, acceptEncoding: headers["accept-encoding"])
        case ("POST", "/v1/rpc"):
            // GAP-1: the authenticated JSON-RPC surface the mobile client
            // uses for every feature call. Routes to the same dispatcher
            // the Unix socket uses, hopping to the main actor.
            let respData = dispatchRPCSync(bodyData)
            send(fd: fd, status: 200, contentType: "application/json", body: respData, acceptEncoding: headers["accept-encoding"])
        case ("POST", "/v1/pair"):
            // Device-initiated request → Mac shows an approve/deny modal.
            // Returns immediately; the device polls /v1/pair/status. The
            // server never blocks on the user's decision.
            guard let auth = auth else {
                send(fd: fd, status: 503, contentType: "text/plain", body: "pairing disabled\n".data(using: .utf8)!); return
            }
            // Cap simultaneously-outstanding requests per peer so one device
            // cannot flood the approve/deny queue.
            guard pairingThrottle.reserveOutstanding(peer: peer) else {
                send(fd: fd, status: 429, contentType: "text/plain", body: "too many outstanding pairing requests\n".data(using: .utf8)!); return
            }
            let obj = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
            let deviceName = (obj?["device_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Unnamed device"
            let privateAccountAccessToken = (obj?["private_account_access_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard let r = auth.createPairingRequest(deviceName: deviceName, privateAccountAccessToken: privateAccountAccessToken) else {
                pairingThrottle.releaseOutstanding(peer: peer)
                send(fd: fd, status: 503, contentType: "text/plain", body: "pairing disabled\n".data(using: .utf8)!); return
            }
            sendJSON(fd: fd, status: 200, body: ["request_id": r.requestId, "code": r.code, "expires_in": 300], acceptEncoding: headers["accept-encoding"])
        case ("POST", "/v1/pair/status"):
            guard let auth = auth,
                  let obj = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
                  let requestId = obj["request_id"] as? String else {
                send(fd: fd, status: 400, contentType: "text/plain", body: "bad request\n".data(using: .utf8)!); return
            }
            guard let s = auth.pairingRequestStatus(requestId: requestId) else {
                send(fd: fd, status: 404, contentType: "text/plain", body: "unknown request\n".data(using: .utf8)!); return
            }
            var resp: [String: Any] = ["status": s.status]
            if let d = s.deviceId { resp["device_id"] = d }
            if let t = s.token { resp["token"] = t }
            sendJSON(fd: fd, status: 200, body: resp, acceptEncoding: headers["accept-encoding"])
        case ("POST", "/v1/pair/redeem"):
            guard let auth = auth,
                  let obj = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
                  let code = obj["code"] as? String,
                  let name = obj["device_name"] as? String else {
                send(fd: fd, status: 400, contentType: "text/plain", body: "bad request\n".data(using: .utf8)!); return
            }
            // Brute-force brake: refuse while the peer is locked out, count
            // wrong codes toward an exponential backoff, and reset on success.
            if case .denied(let retryAfter) = pairingThrottle.check(peer: peer) {
                let secs = Int(retryAfter.rounded(.up))
                send(fd: fd, status: 429, contentType: "text/plain",
                     body: "too many attempts, retry in \(secs)s\n".data(using: .utf8)!)
                return
            }
            if let (deviceId, token) = auth.redeemPairingCode(code, deviceName: name) {
                pairingThrottle.recordSuccess(peer: peer)
                pairingThrottle.releaseOutstanding(peer: peer)
                sendJSON(fd: fd, status: 200, body: ["device_id": deviceId, "token": token], acceptEncoding: headers["accept-encoding"])
            } else {
                pairingThrottle.recordFailure(peer: peer)
                send(fd: fd, status: 410, contentType: "text/plain", body: "code expired or already redeemed\n".data(using: .utf8)!)
            }
        case ("GET", "/v1/devices"):
            guard let auth = auth else { send(fd: fd, status: 503, contentType: "text/plain", body: "disabled\n".data(using: .utf8)!); return }
            sendJSON(fd: fd, status: 200, body: ["devices": auth.listDevices()], acceptEncoding: headers["accept-encoding"])
        case ("POST", "/v1/devices/revoke"):
            guard let auth = auth,
                  let obj = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
                  let id = obj["id"] as? String else {
                send(fd: fd, status: 400, contentType: "text/plain", body: "bad request\n".data(using: .utf8)!); return
            }
            auth.revokeDevice(id)
            sendJSON(fd: fd, status: 200, body: ["revoked": id], acceptEncoding: headers["accept-encoding"])
        case ("GET", "/v1/discovery"):
            let body: [String: Any] = [
                "server_id": serverId,                                  // GAP-2: stable, persisted
                "app": "remotecode",
                "version": AppVersion.short,
                "api_version": "2",
                "capabilities_version": "1",
                "auth_mode": bindLoopbackOnly ? "loopback-anonymous" : "token-required",
                "transports": ["http", "ws"],
                "host": bindLoopbackOnly ? "127.0.0.1" : "0.0.0.0",
                "port": port,
                "vpn_required": !bindLoopbackOnly,
                "relay": false,
                // IMP-MAC_SERVER_SYNC-001: anchor for client clock-drift /
                // freshness math. Pairs with the WS `heartbeat` frame (ts) so
                // the client can show an honest "live / last synced Ns ago".
                "server_time": Date().timeIntervalSince1970
            ]
            sendJSON(fd: fd, status: 200, body: body, acceptEncoding: headers["accept-encoding"])
        case ("GET", "/v1/capabilities"):
            // GAP-3: advertise what the dispatcher actually implements.
            // git mutations + full browser automation are real (see
            // Dispatcher.swift git.*/browser.*); hiding them on the
            // client breaks parity.
            let body: [String: Any] = [
                "surface_types": ["terminal", "ssh", "browser", "agentApp", "files", "markdown", "filePreview", "rightSidebarTool"],
                "ssh": [
                    "methods": ["ssh.host.list", "ssh.host.upsert", "ssh.host.delete", "ssh.connect", "ssh.disconnect", "ssh.transfer.upload", "ssh.transfer.download", "ssh.files.local.list", "ssh.files.remote.list"]
                ],
                "agent": ["providers": ["codex", "claude"], "supports_stream_events": true, "supports_resume": true],
                "browser_automation": [
                    "p0": ["navigate", "back", "forward", "reload", "url.get", "mirror_url.get"],
                    "p1": ["click", "fill", "type", "focus", "hover", "check", "uncheck", "select", "eval", "snapshot", "screenshot", "wait"],
                    "p1_unsupported": false
                ],
                "files": [
                    "methods": ["fs.workspace.list", "fs.workspace.read", "fs.workspace.preview_url", "fs.workspace.create_file", "fs.workspace.rename", "fs.workspace.delete", "files.tab.open", "files.tab.split", "files.state.get", "files.state.update", "files.edit.open", "files.edit.apply_patch", "files.edit.save", "files.edit.discard", "files.edit.close"]
                ],
                "git": ["read_only": false],
                "feature_flags": ["remote_access_enabled": !bindLoopbackOnly]
            ]
            sendJSON(fd: fd, status: 200, body: body, acceptEncoding: headers["accept-encoding"])
        default:
            send(fd: fd, status: 404, contentType: "text/plain", body: "not found\n".data(using: .utf8)!)
        }
    }

    /// PERF-001: cap how many pool threads may be parked on the
    /// main-actor hop at once. A burst of concurrent RPCs (iOS foreground
    /// firing list/status/get) would otherwise grow the global pool with
    /// N semaphore-blocked workers all queued behind the serial main actor.
    /// Bounding the gate keeps thread-pool growth and head-of-line blocking
    /// in check; main-actor dispatch is already serial so throughput is
    /// unchanged.
    private static let rpcHopGate = DispatchSemaphore(value: 8)

    /// QA-003: pure async request/response seam — decode → dispatch →
    /// encode with no semaphore and no socket. Lets framing, compression,
    /// and auth-gating be unit-tested deterministically by feeding body
    /// bytes and awaiting the response bytes, instead of driving a real
    /// socket and a real main runloop. The socket path (`dispatchRPCSync`)
    /// is a thin synchronous bridge over this.
    public func dispatchRPC(bodyData: Data) async -> Data {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        guard let req = try? decoder.decode(JSONRPCRequest.self, from: bodyData) else {
            let resp = JSONRPCResponse(id: nil, error: .parseError)
            return (try? encoder.encode(resp)) ?? Data("{}".utf8)
        }
        let resp = await dispatcher.dispatch(req)
        return (try? encoder.encode(resp)) ?? Data("{}".utf8)
    }

    /// Decode + dispatch one JSON-RPC request on the main actor and
    /// return the encoded response bytes. Mirrors UnixSocketServer's
    /// hop pattern so synchronous AppKit/SwiftUI calls stay on main.
    private func dispatchRPCSync(_ bodyData: Data) -> Data {
        Self.rpcHopGate.wait()
        defer { Self.rpcHopGate.signal() }
        let semaphore = DispatchSemaphore(value: 0)
        final class Slot: @unchecked Sendable { var value: Data? }
        let slot = Slot()
        DispatchQueue.main.async {
            let task = Task { @MainActor in
                slot.value = await self.dispatchRPC(bodyData: bodyData)
                semaphore.signal()
            }
            _ = task
        }
        semaphore.wait()
        return slot.value ?? (try? JSONEncoder().encode(JSONRPCResponse(id: nil, error: .internalError))) ?? Data("{}".utf8)
    }

    private func send(fd: Int32, status: Int, contentType: String, body: Data, acceptEncoding: String? = nil) {
        var responseBody = body
        var extraHeaders = ""
        if contentType.contains("application/json"),
           let codec = PayloadCodec.preferredResponseCodec(acceptEncoding: acceptEncoding),
           body.count >= 128,
           let compressed = try? codec.encode(body),
           compressed.count < body.count {
            responseBody = compressed
            extraHeaders += "Content-Encoding: \(codec.wireName)\r\n"
        }
        let head = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\nContent-Type: \(contentType)\r\n\(extraHeaders)Content-Length: \(responseBody.count)\r\nConnection: close\r\n\r\n"
        // PERF-010: write headers then body separately (as sendFile does)
        // instead of concatenating into one Data — avoids a full-body copy
        // per response, which doubled transient memory for large payloads
        // (agent.message.list / git.diff).
        guard writeAll(fd: fd, data: Data(head.utf8)) else { return }
        if !responseBody.isEmpty {
            _ = writeAll(fd: fd, data: responseBody)
        }
    }

    private func sendFile(fd: Int32, status: Int, contentType: String, url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let handle = try? FileHandle(forReadingFrom: url) else {
            send(fd: fd, status: 404, contentType: "text/plain", body: Data("not found\n".utf8))
            return
        }
        defer { try? handle.close() }
        let head = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\nContent-Type: \(contentType)\r\nContent-Length: \(size)\r\nConnection: close\r\n\r\n"
        guard writeAll(fd: fd, data: Data(head.utf8)) else { return }
        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { return }
            guard writeAll(fd: fd, data: chunk) else { return }
        }
    }

    private func sendJSON(fd: Int32, status: Int, body: [String: Any], acceptEncoding: String? = nil) {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        send(fd: fd, status: status, contentType: "application/json", body: data, acceptEncoding: acceptEncoding)
    }

    private func reasonPhrase(_ s: Int) -> String {
        switch s {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 101: return "Switching Protocols"
        default: return "OK"
        }
    }

    // MARK: WebSocket

    private static let wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    private func performWSHandshake(fd: Int32, key: String) {
        let toHash = key + Self.wsGUID
        let digest = Insecure.SHA1.hash(data: Data(toHash.utf8))
        let accept = Data(digest).base64EncodedString()
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        let data = Data(head.utf8)
        _ = writeAll(fd: fd, data: data)
    }

    private func sendWSEvent(fd: Int32, data: Data, compressed: Bool) -> Bool {
        if compressed,
           let envelope = try? PayloadCodec.encodeWebSocketEnvelope(data),
           envelope.count < data.count {
            return sendWSFrame(fd: fd, opcode: 0x2, data: envelope)
        }
        return sendWSFrame(fd: fd, opcode: 0x1, data: data)
    }

    private func sendWSText(fd: Int32, data: Data) {
        _ = sendWSFrame(fd: fd, opcode: 0x1, data: data)
    }

    private func sendWSFrame(fd: Int32, opcode: UInt8, data: Data) -> Bool {
        // server frames are unmasked
        var frame = Data()
        frame.append(0x80 | opcode)
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
        return writeAll(fd: fd, data: frame)
    }

    private func wsServeLoop(fd: Int32, outbound: WebSocketOutboundQueue) {
        // PERF-009: keep a contiguous [UInt8] buffer with a read offset
        // instead of Data + removeFirst(consumed). removeFirst is O(n) per
        // frame (shifting the whole buffer), which is quadratic under
        // pipelined input; advancing an offset is O(1). The buffer is
        // compacted only once the offset passes its midpoint.
        var buf = [UInt8]()
        var offset = 0
        var tmp = [UInt8](repeating: 0, count: 4096)
        while running {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { return }
            buf.append(contentsOf: tmp[0..<n])
            while let (frame, consumed) = parseClientFrame(buf, from: offset) {
                offset += consumed
                switch frame.opcode {
                case 0x8: // close
                    sendCloseFrame(fd: fd); return
                case 0x9: // ping -> pong
                    guard frame.payload.count <= 125 else {
                        sendCloseFrame(fd: fd)
                        return
                    }
                    sendPongFrame(fd: fd, payload: frame.payload)
                case 0xA: // pong
                    continue
                case 0x1, 0x2:
                    continue // client text/binary -- ignore for now
                default: continue
                }
            }
            if offset > 0 {
                if offset >= buf.count {
                    buf.removeAll(keepingCapacity: true)
                } else if offset > buf.count / 2 {
                    buf.removeFirst(offset)
                } else {
                    continue
                }
                offset = 0
            }
        }
    }

    private struct WSFrame { let opcode: UInt8; let payload: Data }

    /// Pure frame-header parse result. No I/O, no actor. `internal` for unit tests.
    ///
    /// - `shouldReject`: true when the frame is invalid regardless of masking
    ///   (e.g. overflow length or oversized payload). The caller must close.
    /// - `masked`: reflects the MASK bit; RFC6455 s5.3 requires clients to mask.
    /// - `headerEnd`: offset from `start` to the end of length fields (before
    ///   the 4-byte mask key). Only meaningful when `shouldReject` is false.
    struct WSFrameHeader {
        let opcode: UInt8
        let masked: Bool
        let payloadLen: Int
        let headerEnd: Int
        let shouldReject: Bool
    }

    /// Parses the two-byte fixed header plus extended-length fields from `buf`
    /// starting at `start`. Returns nil when more bytes are needed.
    static func wsFrameHeader(buf: [UInt8], from start: Int) -> WSFrameHeader? {
        let available = buf.count - start
        guard available >= 2 else { return nil }
        let b0 = buf[start]
        let b1 = buf[start + 1]
        let opcode = b0 & 0x0F
        let masked = (b1 & 0x80) != 0
        var len = Int(b1 & 0x7F)
        var idx = 2
        if len == 126 {
            guard available >= 4 else { return nil }
            len = (Int(buf[start + 2]) << 8) | Int(buf[start + 3])
            idx = 4
        } else if len == 127 {
            guard available >= 10 else { return nil }
            var wideLen: UInt64 = 0
            for i in 0..<8 {
                wideLen = (wideLen << 8) | UInt64(buf[start + 2 + i])
            }
            guard wideLen <= UInt64(Int.max) else {
                return WSFrameHeader(opcode: opcode, masked: masked,
                                     payloadLen: 0, headerEnd: 10, shouldReject: true)
            }
            len = Int(wideLen)
            idx = 10
        }
        if len > maxClientFramePayloadBytes {
            return WSFrameHeader(opcode: opcode, masked: masked,
                                 payloadLen: 0, headerEnd: idx, shouldReject: true)
        }
        return WSFrameHeader(opcode: opcode, masked: masked,
                             payloadLen: len, headerEnd: idx, shouldReject: false)
    }

    private func parseClientFrame(_ buf: [UInt8], from start: Int) -> (WSFrame, Int)? {
        guard let hdr = Self.wsFrameHeader(buf: buf, from: start) else { return nil }

        // Oversized / overflow -- close regardless of masking.
        if hdr.shouldReject {
            return (WSFrame(opcode: 0x8, payload: Data()), hdr.headerEnd)
        }

        // RFC6455 s5.3: clients MUST mask all frames sent to the server.
        // An unmasked client frame is a protocol error; close with 1002.
        guard hdr.masked else {
            return (WSFrame(opcode: 0x8, payload: Data()), hdr.headerEnd)
        }

        var idx = hdr.headerEnd
        let available = buf.count - start
        var maskKey: [UInt8] = [0, 0, 0, 0]
        guard available >= idx + 4 else { return nil }
        for i in 0..<4 { maskKey[i] = buf[start + idx + i] }
        idx += 4

        guard available >= idx + hdr.payloadLen else { return nil }
        let payloadStart = start + idx
        var payload = [UInt8](repeating: 0, count: hdr.payloadLen)
        for i in 0..<hdr.payloadLen {
            payload[i] = buf[payloadStart + i] ^ maskKey[i & 3]
        }
        return (WSFrame(opcode: hdr.opcode, payload: Data(payload)), idx + hdr.payloadLen)
    }

    private func sendPongFrame(fd: Int32, payload: Data) {
        let frame = Self.pongFrame(payload: payload)
        _ = writeAll(fd: fd, data: frame)
    }

    static func pongFrame(payload: Data) -> Data {
        let safePayload = payload.prefix(125)
        var frame = Data()
        frame.append(0x8A) // FIN + pong
        frame.append(UInt8(safePayload.count))
        frame.append(safePayload)
        return frame
    }

    private func sendCloseFrame(fd: Int32) {
        var frame = Data()
        frame.append(0x88) // FIN + close
        frame.append(0x00) // empty payload
        _ = writeAll(fd: fd, data: frame)
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var written = 0
            while written < data.count {
                let n = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return false }
                written += n
            }
            return true
        }
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

public struct DirectStaticFileGrant: Sendable, Equatable {
    public let token: String
    public let rootPath: String
    public let routePath: String
}

public final class DirectStaticFileRegistry: @unchecked Sendable {
    public static let shared = DirectStaticFileRegistry()
    public static let routePrefix = "/__rc2_static/"

    private struct Grant {
        let rootPath: String
        let createdAt: Date
    }

    private let lock = NSLock()
    private var grants: [String: Grant] = [:]
    private let ttl: TimeInterval = 60 * 60
    // QA-002: clock is an injectable instance dependency, not a per-call
    // `Date()` default that every grant test must remember to override. The
    // per-call `now:` parameters still work (explicit override wins), but
    // when omitted they read this clock — so a test injects a fixed clock
    // once via `setClockForTests` and all TTL-dependent paths use it.
    private var clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    public func register(fileURL: URL, now: Date? = nil) -> DirectStaticFileGrant? {
        let now = now ?? currentTime()
        guard fileURL.isFileURL else { return nil }
        let standardized = fileURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        let root = standardized.deletingLastPathComponent().path
        let relative = standardized.lastPathComponent
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let routePath = Self.routePrefix + token + "/" + Self.encodeRelativePath(relative)

        lock.lock()
        purgeExpired(now: now)
        grants[token] = Grant(rootPath: root, createdAt: now)
        lock.unlock()

        return DirectStaticFileGrant(token: token, rootPath: root, routePath: routePath)
    }

    public func resolve(routePath: String, now: Date? = nil) -> (url: URL, contentType: String)? {
        let now = now ?? currentTime()
        guard routePath.hasPrefix(Self.routePrefix) else { return nil }
        let rest = String(routePath.dropFirst(Self.routePrefix.count))
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let token = String(rest[..<slash])
        let encodedRelative = String(rest[rest.index(after: slash)...])
        guard !encodedRelative.isEmpty,
              let relative = encodedRelative.removingPercentEncoding,
              !relative.split(separator: "/").contains("..") else { return nil }

        lock.lock()
        purgeExpired(now: now)
        guard let grant = grants[token] else { lock.unlock(); return nil }
        lock.unlock()

        let rootURL = URL(fileURLWithPath: grant.rootPath, isDirectory: true).standardizedFileURL
        let candidate = rootURL.appendingPathComponent(relative).standardizedFileURL
        let rootPath = rootURL.path
        guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return (candidate, Self.contentType(for: candidate.pathExtension))
    }

    public func resetForTests() {
        lock.lock()
        grants.removeAll()
        lock.unlock()
    }

    /// QA-002: inject a fixed/controllable clock so TTL-dependent grant
    /// tests are deterministic without threading `now:` through every call.
    public func setClockForTests(_ clock: @escaping @Sendable () -> Date) {
        lock.lock()
        self.clock = clock
        lock.unlock()
    }

    private func currentTime() -> Date {
        lock.lock(); defer { lock.unlock() }
        return clock()
    }

    private func purgeExpired(now: Date) {
        grants = grants.filter { now.timeIntervalSince($0.value.createdAt) <= ttl }
    }

    private static func encodeRelativePath(_ relative: String) -> String {
        relative.split(separator: "/", omittingEmptySubsequences: false)
            .map { part in
                String(part).addingPercentEncoding(withAllowedCharacters: pathComponentAllowed) ?? String(part)
            }
            .joined(separator: "/")
    }

    private static let pathComponentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return set
    }()

    private static func contentType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "heic": return "image/heic"
        case "avif": return "image/avif"
        case "svg": return "image/svg+xml"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "pdf": return "application/pdf"
        case "md", "markdown": return "text/markdown; charset=utf-8"
        case "wasm": return "application/wasm"
        case "map": return "application/json"
        case "ico": return "image/x-icon"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
