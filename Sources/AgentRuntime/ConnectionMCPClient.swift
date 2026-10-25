import Foundation
import CoreModel
import Darwin

private final class NoConnectionRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// One bounded MCP session. Never logs server payloads, headers, command arguments or errors.
actor ConnectionMCPClient {
    private let connection: AppConnection
    private let credentials: [String: String]
    private var stdio: ConnectionStdioTransport?
    private var negotiatedVersion: String?
    private static let supportedVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
    private var sessionID: String?
    private var sequence = 0
    private var ready: Task<Void, Error>?
    private let session: URLSession
    init(connection: AppConnection, credentials: [String: String]) {
        self.connection = connection; self.credentials = credentials
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        config.httpShouldSetCookies = false; config.urlCache = nil
        self.session = URLSession(configuration: config, delegate: NoConnectionRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel(); stdio?.close() }
    func request(_ method: String, params: [String: ConnectionJSONValue] = [:]) async throws -> [String: ConnectionJSONValue] {
        if ready == nil {
            ready = Task {
                let initialized = try await self.raw("initialize", params: [
                    "protocolVersion": .string("2025-11-25"), "capabilities": .object([:]),
                    "clientInfo": .object(["name": .string("MacCode Connections"), "version": .string("1")])
                ])
                guard let version = initialized["protocolVersion"]?.stringValue, Self.supportedVersions.contains(version) else { throw ConnectionError.invalidResponse }
                self.negotiatedVersion = version
                _ = try await self.raw("notifications/initialized", params: [:], notification: true)
            }
        }
        try await ready?.value
        try Task.checkCancellation()
        return try await raw(method, params: params)
    }
    func close() {
        ready?.cancel(); ready = nil
        stdio?.close(); stdio = nil
        session.invalidateAndCancel()
    }
    private func raw(_ method: String, params: [String: ConnectionJSONValue], notification: Bool = false) async throws -> [String: ConnectionJSONValue] {
        sequence += 1
        let id = sequence
        var message: [String: ConnectionJSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params)]
        if !notification { message["id"] = .number(Double(id)) }
        let data = try JSONEncoder().encode(message)
        let reply: Data
        if connection.kind == .stdio {
            if stdio == nil { stdio = try ConnectionStdioTransport(connection: connection, environment: credentials) }
            guard let transport = stdio else { throw ConnectionError.unavailable }
            reply = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        do { continuation.resume(returning: try transport.exchange(data, id: notification ? nil : id)) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
            } onCancel: { transport.close() }
        } else {
            guard let url = URL(string: connection.endpoint) else { throw ConnectionError.invalidConfiguration }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"; request.httpBody = data
            for (key, value) in credentials {
                guard !key.contains(where: { $0.isNewline || $0.asciiValue == 0 }), !value.contains(where: { $0.isNewline || $0.asciiValue == 0 }), !["host", "content-length"].contains(key.lowercased()) else { throw ConnectionError.invalidConfiguration }
                request.setValue(value, forHTTPHeaderField: key)
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let negotiatedVersion { request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            do {
                let (bytes, response) = try await session.bytes(for: request)
                defer { bytes.task.cancel() }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ConnectionError.unavailable }
                if let token = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = token }
                if notification { return [:] }
                let eventStream = http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true
                var received = Data(), line = Data(), event = Data()
                var matched: Data?
                for try await byte in bytes {
                    try Task.checkCancellation()
                    received.append(byte)
                    guard received.count <= 4_194_304 else { throw ConnectionError.invalidResponse }
                    if eventStream {
                        if byte == 10 {
                            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines)
                            line.removeAll(keepingCapacity: true)
                            if text.isEmpty {
                                if let object = try? JSONDecoder().decode([String: ConnectionJSONValue].self, from: event), object["id"] == .number(Double(id)) { matched = event; break }
                                event.removeAll(keepingCapacity: true)
                            } else if text.hasPrefix("data:") {
                                if !event.isEmpty { event.append(10) }
                                event.append(contentsOf: text.dropFirst(5).drop(while: { $0 == " " }).utf8)
                            }
                        } else { line.append(byte) }
                    }
                }
                if eventStream {
                    guard let matched else { throw ConnectionError.invalidResponse }
                    reply = matched
                } else { reply = received }
            } catch is CancellationError { throw CancellationError() }
            catch let error as ConnectionError { throw error }
            catch { throw Task.isCancelled ? CancellationError() : ConnectionError.timeout }
        }
        if notification { return [:] }
        let decoded: [String: ConnectionJSONValue]
        if let object = try? JSONDecoder().decode([String: ConnectionJSONValue].self, from: reply) { decoded = object }
        else {
            // Streamable HTTP may wrap the JSON-RPC response in SSE data lines.
            let candidates = String(decoding: reply, as: UTF8.self).components(separatedBy: "\n").compactMap { line -> [String: ConnectionJSONValue]? in
                guard line.hasPrefix("data:") else { return nil }
                return try? JSONDecoder().decode([String: ConnectionJSONValue].self, from: Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8))
            }
            guard let object = candidates.first(where: { $0["id"] == .number(Double(id)) }) else { throw ConnectionError.invalidResponse }
            decoded = object
        }
        guard decoded["id"] == .number(Double(id)), decoded["error"] == nil,
              let result = decoded["result"]?.objectValue else { throw ConnectionError.invalidResponse }
        return result
    }
}

private final class ConnectionStdioTransport: @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    init(connection: AppConnection, environment: [String: String]) throws {
        guard FileManager.default.isExecutableFile(atPath: connection.endpoint) else { throw ConnectionError.unavailable }
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: connection.endpoint); process.arguments = connection.arguments
        let inherited = ProcessInfo.processInfo.environment
        var isolated = inherited.filter { ["PATH", "HOME", "TMPDIR", "USER", "LANG"].contains($0.key) }
        isolated.merge(environment) { _, value in value }
        process.environment = isolated
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        self.process = process; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        do { try process.run() } catch { throw ConnectionError.unavailable }
        _ = fcntl(input.fileDescriptor, F_SETFL, fcntl(input.fileDescriptor, F_GETFL) | O_NONBLOCK)
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
    }
    func close() {
        // terminate is safe while the reader polls; don't wait for its exchange lock.
        if process.isRunning {
            process.terminate()
            let owned = process
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if owned.isRunning { kill(owned.processIdentifier, SIGKILL) }
            }
        }
    }
    deinit { close(); try? input.close(); try? output.close() }
    func exchange(_ data: Data, id: Int?) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard process.isRunning else { throw ConnectionError.unavailable }
        guard data.count <= 1_048_576 else { throw ConnectionError.invalidConfiguration }
        let deadline = Date().addingTimeInterval(30)
        let wire = data + Data([10])
        var offset = 0
        try wire.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw ConnectionError.invalidResponse }
            while offset < wire.count {
                guard Date() < deadline, process.isRunning else { close(); throw ConnectionError.timeout }
                var descriptor = pollfd(fd: input.fileDescriptor, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&descriptor, 1, 100)
                if ready < 0 { if errno == EINTR { continue }; throw ConnectionError.unavailable }
                if ready == 0 { continue }
                let count = Darwin.write(input.fileDescriptor, base.advanced(by: offset), min(8192, wire.count - offset))
                if count < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw ConnectionError.unavailable }
                offset += count
            }
        }
        guard let id else { return Data() }
        while Date() < deadline {
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                if let object = try? JSONDecoder().decode([String: ConnectionJSONValue].self, from: line), object["id"] == .number(Double(id)) { return line }
            }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let count = poll(&descriptor, 1, 100)
            if count < 0 { if errno == EINTR { continue }; throw ConnectionError.unavailable }
            if count == 0 { if !process.isRunning { throw ConnectionError.unavailable }; continue }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let readCount = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            guard readCount > 0 else { throw ConnectionError.unavailable }
            buffer.append(contentsOf: bytes.prefix(readCount))
            guard buffer.count <= 4_194_304 else { close(); throw ConnectionError.invalidResponse }
        }
        close(); throw ConnectionError.timeout
    }
}
