import Foundation
import Network

public enum DistillApprovedModel {
    public static let id = "samuelfaj/distill-1.7B-4bit-MLX"
    public static let url = "https://huggingface.co/samuelfaj/distill-1.7B-4bit-MLX"
    public static let runtime = "mlx"
}

public enum DistillServiceError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingRequiredOption(String)
    case invalidIntegerOption(String, String)
    case unsupportedRuntime(String)
    case unsupportedModel(modelID: String, modelURL: String)
    case unsupportedHost(String)
    case modelValidationFailed(String?)
    case mlxRuntimeUnavailable(String)

    public var description: String {
        switch self {
        case .missingRequiredOption(let option):
            return "missing required option \(option)"
        case .invalidIntegerOption(let option, let value):
            return "invalid integer option \(option)=\(value)"
        case .unsupportedRuntime(let runtime):
            return "unsupported runtime \(runtime)"
        case .unsupportedModel(let modelID, let modelURL):
            return "unsupported model \(modelID) \(modelURL)"
        case .unsupportedHost(let host):
            return "unsupported host \(host)"
        case .modelValidationFailed(let reason):
            return "approved MLX model validation failed: \(reason ?? "unknown reason")"
        case .mlxRuntimeUnavailable(let reason):
            return "MLX runtime unavailable: \(reason)"
        }
    }
}

public struct DistillServiceConfiguration: Sendable, Equatable {
    public let host: String
    public let port: UInt16
    public let authToken: String
    public let appSupportDirectory: String
    public let runtime: String
    public let modelID: String
    public let modelURL: String
    public let maxConcurrentRequests: Int
    public let maxQueueDepth: Int
    public let idleTimeoutMS: Int

    public init(
        host: String = "127.0.0.1",
        port: UInt16 = 0,
        authToken: String,
        appSupportDirectory: String,
        runtime: String = DistillApprovedModel.runtime,
        modelID: String = DistillApprovedModel.id,
        modelURL: String = DistillApprovedModel.url,
        maxConcurrentRequests: Int = 8,
        maxQueueDepth: Int = 64,
        idleTimeoutMS: Int = 300_000
    ) throws {
        guard host == "127.0.0.1" || host == "localhost" else {
            throw DistillServiceError.unsupportedHost(host)
        }
        guard !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DistillServiceError.missingRequiredOption("--auth-token")
        }
        guard !appSupportDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DistillServiceError.missingRequiredOption("--app-support-dir")
        }
        guard runtime == DistillApprovedModel.runtime else {
            throw DistillServiceError.unsupportedRuntime(runtime)
        }
        guard modelID == DistillApprovedModel.id, modelURL == DistillApprovedModel.url else {
            throw DistillServiceError.unsupportedModel(modelID: modelID, modelURL: modelURL)
        }

        self.host = host
        self.port = port
        self.authToken = authToken
        self.appSupportDirectory = appSupportDirectory
        self.runtime = runtime
        self.modelID = modelID
        self.modelURL = modelURL
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        self.maxQueueDepth = max(0, maxQueueDepth)
        self.idleTimeoutMS = max(1_000, idleTimeoutMS)
    }

    public static func parse(arguments: [String]) throws -> DistillServiceConfiguration {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--") else {
                throw DistillServiceError.missingRequiredOption(key)
            }
            guard index + 1 < arguments.count else {
                throw DistillServiceError.missingRequiredOption(key)
            }
            values[String(key.dropFirst(2))] = arguments[index + 1]
            index += 2
        }

        func intValue(_ key: String, default defaultValue: Int) throws -> Int {
            guard let raw = values[key] else { return defaultValue }
            guard let parsed = Int(raw) else {
                throw DistillServiceError.invalidIntegerOption("--\(key)", raw)
            }
            return parsed
        }

        let rawPort = try intValue("port", default: 0)
        guard rawPort >= 0 && rawPort <= Int(UInt16.max) else {
            throw DistillServiceError.invalidIntegerOption("--port", "\(rawPort)")
        }

        return try DistillServiceConfiguration(
            host: values["host"] ?? "127.0.0.1",
            port: UInt16(rawPort),
            authToken: values["auth-token"] ?? "",
            appSupportDirectory: values["app-support-dir"] ?? "",
            runtime: values["runtime"] ?? DistillApprovedModel.runtime,
            modelID: values["model-id"] ?? DistillApprovedModel.id,
            modelURL: values["model-url"] ?? DistillApprovedModel.url,
            maxConcurrentRequests: try intValue("max-concurrent-requests", default: 8),
            maxQueueDepth: try intValue("max-queue-depth", default: 64),
            idleTimeoutMS: try intValue("idle-timeout-ms", default: 300_000)
        )
    }
}

public struct DistillServiceReadyEvent: Codable, Sendable, Equatable {
    public let event: String
    public let baseURL: String
    public let host: String
    public let port: UInt16
    public let pid: Int32
    public let protocolVersion: Int
    public let runtime: String
    public let modelID: String
    public let maxConcurrentRequests: Int
    public let maxQueueDepth: Int

    public enum CodingKeys: String, CodingKey {
        case event
        case baseURL = "base_url"
        case host
        case port
        case pid
        case protocolVersion = "protocol"
        case runtime
        case modelID = "model_id"
        case maxConcurrentRequests = "max_concurrent_requests"
        case maxQueueDepth = "max_queue_depth"
    }
}

public struct DistillServiceMetrics: Codable, Sendable, Equatable {
    public let activeRequests: Int
    public let totalRequests: Int
    public let successfulRequests: Int
    public let failedRequests: Int
    public let maxConcurrentRequests: Int

    public enum CodingKeys: String, CodingKey {
        case activeRequests = "active_requests"
        case totalRequests = "total_requests"
        case successfulRequests = "successful_requests"
        case failedRequests = "failed_requests"
        case maxConcurrentRequests = "max_concurrent_requests"
    }
}

public actor DistillServiceMetricsRecorder {
    private var totalRequests = 0
    private var successfulRequests = 0
    private var failedRequests = 0

    public init() {}

    public func recordRequest() {
        totalRequests += 1
    }

    public func recordSuccess() {
        successfulRequests += 1
    }

    public func recordFailure() {
        failedRequests += 1
    }

    public func snapshot(activeRequests: Int, maxConcurrentRequests: Int) -> DistillServiceMetrics {
        DistillServiceMetrics(
            activeRequests: activeRequests,
            totalRequests: totalRequests,
            successfulRequests: successfulRequests,
            failedRequests: failedRequests,
            maxConcurrentRequests: maxConcurrentRequests
        )
    }
}

public final class DistillHTTPServer: @unchecked Sendable {
    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private struct ErrorBody: Codable {
        let error: String
        let message: String
    }

    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else { return false }
            didResume = true
            return true
        }
    }

    private let configuration: DistillServiceConfiguration
    private let scheduler: DistillScheduler
    private let metrics = DistillServiceMetricsRecorder()
    private let queue = DispatchQueue(label: "io.remotecode.distill.http", qos: .userInitiated)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var listener: NWListener?
    private var actualPort: UInt16 = 0

    public init(configuration: DistillServiceConfiguration, scheduler: DistillScheduler) {
        self.configuration = configuration
        self.scheduler = scheduler
    }

    public func start() async throws -> DistillServiceReadyEvent {
        let requestedPort = NWEndpoint.Port(rawValue: configuration.port) ?? .any
        let listener = try NWListener(using: .tcp, on: requestedPort)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(connection: connection, buffer: Data())
        }

        return try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeGate()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    self.actualPort = listener.port?.rawValue ?? self.configuration.port
                    continuation.resume(returning: self.readyEvent())
                case .failed(let error):
                    guard gate.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    public func readyEvent() -> DistillServiceReadyEvent {
        let port = actualPort == 0 ? configuration.port : actualPort
        return DistillServiceReadyEvent(
            event: "ready",
            baseURL: "http://\(configuration.host):\(port)",
            host: configuration.host,
            port: port,
            pid: ProcessInfo.processInfo.processIdentifier,
            protocolVersion: 1,
            runtime: configuration.runtime,
            modelID: configuration.modelID,
            maxConcurrentRequests: configuration.maxConcurrentRequests,
            maxQueueDepth: configuration.maxQueueDepth
        )
    }

    private func receive(connection: NWConnection, buffer: Data) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete, data == nil {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if self.requestIsComplete(nextBuffer) {
                Task {
                    await self.handle(buffer: nextBuffer, connection: connection)
                }
            } else {
                self.receive(connection: connection, buffer: nextBuffer)
            }
        }
    }

    private func requestIsComplete(_ data: Data) -> Bool {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return false
        }
        let contentLength = headerText
            .split(separator: "\r\n")
            .dropFirst()
            .compactMap { line -> Int? in
                let pieces = line.split(separator: ":", maxSplits: 1)
                guard pieces.count == 2,
                      pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "content-length" else {
                    return nil
                }
                return Int(pieces[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }
            .first ?? 0
        return data.count >= headerRange.upperBound + contentLength
    }

    private func handle(buffer: Data, connection: NWConnection) async {
        guard let request = parse(buffer: buffer) else {
            send(status: 400, body: ErrorBody(error: "bad_request", message: "invalid http request"), connection: connection)
            return
        }

        if request.path == "/healthz" {
            send(status: 200, body: ["status": "ok"], connection: connection)
            return
        }

        guard request.headers["authorization"] == "Bearer \(configuration.authToken)" else {
            send(status: 401, body: ErrorBody(error: "unauthorized", message: "missing bearer token"), connection: connection)
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/readyz"):
            send(status: 200, body: readyEvent(), connection: connection)
        case ("GET", "/metrics"):
            let active = await scheduler.activeRequestCount
            let snapshot = await metrics.snapshot(
                activeRequests: active,
                maxConcurrentRequests: configuration.maxConcurrentRequests
            )
            send(status: 200, body: snapshot, connection: connection)
        case ("POST", "/v1/distill"):
            await handleDistill(request: request, connection: connection)
        case (_, "/v1/distill"):
            send(status: 405, body: ErrorBody(error: "method_not_allowed", message: "use POST"), connection: connection)
        default:
            send(status: 404, body: ErrorBody(error: "not_found", message: request.path), connection: connection)
        }
    }

    private func handleDistill(request: HTTPRequest, connection: NWConnection) async {
        await metrics.recordRequest()
        do {
            let distillRequest = try decoder.decode(DistillRequest.self, from: request.body)
            let response = try await scheduler.submit(distillRequest)
            await metrics.recordSuccess()
            send(status: 200, body: response, connection: connection)
        } catch let error as DistillError {
            await metrics.recordFailure()
            switch error {
            case .emptyInput:
                send(status: 400, body: ErrorBody(error: "empty_input", message: "input is empty"), connection: connection)
            case .queueFull:
                send(status: 429, body: ErrorBody(error: "queue_full", message: "bounded distill worker is full"), connection: connection)
            case .invalidOutput:
                send(status: 502, body: ErrorBody(error: "invalid_output", message: "runtime returned empty output"), connection: connection)
            }
        } catch {
            await metrics.recordFailure()
            send(status: 400, body: ErrorBody(error: "bad_request", message: "invalid distill request"), connection: connection)
        }
    }

    private func parse(buffer: Data) -> HTTPRequest? {
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: buffer[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }
        var lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            headers[pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let bodyStart = headerRange.upperBound
        let body = buffer.count > bodyStart ? buffer[bodyStart...] : Data()
        return HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: String(requestLine[1]).split(separator: "?").first.map(String.init) ?? "/",
            headers: headers,
            body: Data(body)
        )
    }

    private func send<T: Encodable>(status: Int, body: T, connection: NWConnection) {
        let payload: Data
        do {
            payload = try encoder.encode(body)
        } catch {
            payload = Data(#"{"error":"encoding_failed"}"#.utf8)
        }
        let phrase: String
        switch status {
        case 200: phrase = "OK"
        case 400: phrase = "Bad Request"
        case 401: phrase = "Unauthorized"
        case 404: phrase = "Not Found"
        case 405: phrase = "Method Not Allowed"
        case 429: phrase = "Too Many Requests"
        case 502: phrase = "Bad Gateway"
        default: phrase = "Error"
        }
        var data = Data("HTTP/1.1 \(status) \(phrase)\r\n".utf8)
        data.append(Data("Content-Type: application/json\r\n".utf8))
        data.append(Data("Content-Length: \(payload.count)\r\n".utf8))
        data.append(Data("Connection: close\r\n\r\n".utf8))
        data.append(payload)

        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
