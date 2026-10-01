import CryptoKit
import Foundation
import Network

public enum DistillAccountProvider: String, CaseIterable, Codable, Sendable {
    case grok, chatgpt, claude, openrouter

    public var displayName: String {
        switch self {
        case .grok: return "Grok"
        case .chatgpt: return "ChatGPT"
        case .claude: return "Claude"
        case .openrouter: return "OpenRouter"
        }
    }

    /// OpenRouter has no Distill CLI login; it is handled natively.
    var cliLoginArguments: [String]? {
        switch self {
        case .grok: return ["login"]
        case .chatgpt: return ["login", "--chatgpt"]
        case .claude: return ["login", "--claude"]
        case .openrouter: return nil
        }
    }

    var cliLogoutArguments: [String]? {
        switch self {
        case .grok: return ["logout"]
        case .chatgpt: return ["logout", "--chatgpt"]
        case .claude: return ["logout", "--claude"]
        case .openrouter: return nil
        }
    }

    var credentialFileName: String {
        switch self {
        case .grok: return "auth.json"
        case .chatgpt: return "codex-auth.json"
        case .claude: return "claude-auth.json"
        case .openrouter: return "openrouter-auth.json"
        }
    }
}

public struct DistillAccountStatus: Equatable, Codable, Sendable {
    public let provider: DistillAccountProvider
    public let connected: Bool
    public let email: String?

    public init(provider: DistillAccountProvider, connected: Bool, email: String? = nil) {
        self.provider = provider
        self.connected = connected
        self.email = email
    }
}

public enum DistillAccountError: Error, Equatable, LocalizedError {
    case cancelled
    case timedOut
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in was cancelled."
        case .timedOut: return "Sign-in timed out. Please try again."
        case .failed(let message): return message
        }
    }
}

/// Reports and changes Distill's provider accounts (Distill 2.0.24 credential stores).
public final class DistillAccounts: Sendable {
    /// Status code + body of an OpenRouter exchange POST.
    public typealias HTTPPost = @Sendable (_ url: URL, _ jsonBody: Data) async throws -> (data: Data, status: Int)

    private static let openRouterAuthURL = "https://openrouter.ai/auth"
    private static let openRouterExchangeURL = URL(string: "https://openrouter.ai/api/v1/auth/keys")!

    private let home: URL
    private let binaryPath: String
    private let environment: [String: String]
    private let openURL: @Sendable (URL) -> Void
    private let httpPost: HTTPPost
    private let callbackTimeout: TimeInterval

    public convenience init(
        home: URL,
        binaryPath: String,
        environment: [String: String],
        openURL: @escaping @Sendable (URL) -> Void,
        httpPost: @escaping HTTPPost = DistillAccounts.urlSessionPost
    ) {
        self.init(
            home: home, binaryPath: binaryPath, environment: environment,
            openURL: openURL, httpPost: httpPost, callbackTimeout: 300)
    }

    init(
        home: URL,
        binaryPath: String,
        environment: [String: String],
        openURL: @escaping @Sendable (URL) -> Void,
        httpPost: @escaping HTTPPost,
        callbackTimeout: TimeInterval
    ) {
        self.home = home
        self.binaryPath = binaryPath
        self.environment = environment
        self.openURL = openURL
        self.httpPost = httpPost
        self.callbackTimeout = callbackTimeout
    }

    // MARK: Status

    public func statuses() -> [DistillAccountStatus] {
        DistillAccountProvider.allCases.map { provider in
            let account = accountDetails(provider)
            return DistillAccountStatus(provider: provider, connected: account.connected, email: account.email)
        }
    }

    private func accountDetails(_ provider: DistillAccountProvider) -> (connected: Bool, email: String?) {
        let url = home.appendingPathComponent(provider.credentialFileName)
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (false, nil) }
        func nonEmpty(_ value: Any?) -> Bool {
            guard let text = value as? String else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        switch provider {
        case .chatgpt:
            return (nonEmpty((root["tokens"] as? [String: Any])?["access_token"]), nil)
        case .claude:
            let connected = nonEmpty(root["access_token"])
            let email = (root["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (connected, email?.isEmpty == false ? email : nil)
        case .openrouter:
            return (nonEmpty(root["key"]), nil)
        case .grok:
            // Scoped map of OAuth sessions; the `xai::api_key` scope is a plain API key, not an account sign-in.
            let oauth = root.sorted { $0.key < $1.key }.first { scope, value in
                scope != "xai::api_key" && nonEmpty((value as? [String: Any])?["key"])
            }
            let email = ((oauth?.value as? [String: Any])?["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (oauth != nil, email?.isEmpty == false ? email : nil)
        }
    }

    // MARK: Login / logout

    public func login(
        _ provider: DistillAccountProvider,
        onURL: @escaping @Sendable (URL) -> Void
    ) async throws {
        guard let arguments = provider.cliLoginArguments else {
            try await loginOpenRouter(onURL: onURL)
            return
        }
        // `distill login` does not need a TTY (stdin is only read for pasted URLs when it is a terminal).
        try await runCLI(arguments, onURL: onURL)
    }

    public func logout(_ provider: DistillAccountProvider) async throws {
        guard let arguments = provider.cliLogoutArguments else {
            let url = home.appendingPathComponent(provider.credentialFileName)
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
            } catch {
                throw DistillAccountError.failed(error.localizedDescription)
            }
            return
        }
        try await runCLI(arguments, onURL: nil)
    }

    // MARK: CLI child

    private func runCLI(
        _ arguments: [String],
        onURL: (@Sendable (URL) -> Void)?
    ) async throws {
        if Task.isCancelled { throw DistillAccountError.cancelled }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        var env = environment
        env["DISTILL_HOME"] = home.path
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe

        let collector = StderrCollector(onURL: onURL)
        let eofGroup = DispatchGroup()
        eofGroup.enter()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                collector.finish()
                eofGroup.leave()
            } else {
                collector.append(data)
            }
        }

        let exit = OneShot<Int32>()
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            // A grandchild may keep stderr open; do not wait for EOF forever.
            DispatchQueue.global().async {
                _ = eofGroup.wait(timeout: .now() + 1)
                exit.finish(.success(status))
            }
        }

        do {
            try process.run()
        } catch {
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw DistillAccountError.failed("Could not start distill: \(error.localizedDescription)")
        }

        let status = try await withTaskCancellationHandler {
            try await exit.wait()
        } onCancel: {
            Self.terminate(process)
        }

        if Task.isCancelled { throw DistillAccountError.cancelled }
        guard status == 0 else {
            throw DistillAccountError.failed(collector.lastLine ?? "distill exited with status \(status)")
        }
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    // MARK: OpenRouter

    /// Mirrors Distill's `openrouter_auth::run_tui_login`: PKCE S256 + random loopback callback path.
    private func loginOpenRouter(onURL: @escaping @Sendable (URL) -> Void) async throws {
        if Task.isCancelled { throw DistillAccountError.cancelled }

        let verifier = Self.randomBase64URL()
        let callbackPath = "/auth/callback/\(Self.randomBase64URL())"
        let codeWaiter = OneShot<String>()
        let listener = try makeListener(callbackPath: callbackPath, codeWaiter: codeWaiter)
        defer { listener.cancel() }

        let port = try await Self.waitUntilReady(listener)
        guard let url = Self.authorizationURL(
            callbackURL: "http://localhost:\(port)\(callbackPath)", verifier: verifier)
        else { throw DistillAccountError.failed("Could not build the OpenRouter sign-in URL.") }

        onURL(url)
        openURL(url)

        let timer = DispatchWorkItem { codeWaiter.finish(.failure(DistillAccountError.timedOut)) }
        DispatchQueue.global().asyncAfter(deadline: .now() + callbackTimeout, execute: timer)
        defer { timer.cancel() }
        let code = try await withTaskCancellationHandler {
            try await codeWaiter.wait()
        } onCancel: {
            codeWaiter.finish(.failure(DistillAccountError.cancelled))
        }
        listener.cancel()

        let key = try await exchange(code: code, verifier: verifier)
        try writeOpenRouterKey(key)
    }

    static func pkceChallenge(verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func authorizationURL(callbackURL: String, verifier: String) -> URL? {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let pairs = [
            ("callback_url", callbackURL),
            ("code_challenge", pkceChallenge(verifier: verifier)),
            ("code_challenge_method", "S256"),
            ("key_label", "Distill"),
        ]
        let query = pairs.map {
            "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")"
        }.joined(separator: "&")
        return URL(string: "\(openRouterAuthURL)?\(query)")
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomBase64URL() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    private func exchange(code: String, verifier: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [
            "code": code,
            "code_verifier": verifier,
            "code_challenge_method": "S256",
        ])
        let response: (data: Data, status: Int)
        do {
            response = try await httpPost(Self.openRouterExchangeURL, body)
        } catch is CancellationError {
            throw DistillAccountError.cancelled
        } catch {
            throw DistillAccountError.failed(
                "Could not exchange the OpenRouter authorization code: \(error.localizedDescription)")
        }
        if Task.isCancelled { throw DistillAccountError.cancelled }
        guard (200..<300).contains(response.status) else {
            throw DistillAccountError.failed(
                "OpenRouter authorization failed (HTTP \(response.status)). Please try again.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let key = object["key"] as? String
        else { throw DistillAccountError.failed("Invalid OpenRouter authorization response.") }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DistillAccountError.failed("OpenRouter returned an empty API key.")
        }
        return key
    }

    private func writeOpenRouterKey(_ key: String) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: ["key": key])
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let target = home.appendingPathComponent(DistillAccountProvider.openrouter.credentialFileName)
            let temp = home.appendingPathComponent(".openrouter-auth.\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(
                atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600])
            else { throw CocoaError(.fileWriteUnknown) }
            guard rename(temp.path, target.path) == 0 else {
                let code = errno
                try? FileManager.default.removeItem(at: temp)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        } catch {
            throw DistillAccountError.failed("Could not save OpenRouter credentials: \(error.localizedDescription)")
        }
    }

    private func makeListener(callbackPath: String, codeWaiter: OneShot<String>) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw DistillAccountError.failed("Could not start the local sign-in listener: \(error.localizedDescription)")
        }
        listener.newConnectionHandler = { connection in
            Self.serve(connection, callbackPath: callbackPath, codeWaiter: codeWaiter)
        }
        return listener
    }

    private static func waitUntilReady(_ listener: NWListener) async throws -> UInt16 {
        let ready = OneShot<UInt16>()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port?.rawValue { ready.finish(.success(port)) }
            case .failed(let error):
                ready.finish(.failure(DistillAccountError.failed(
                    "Could not start the local sign-in listener: \(error.localizedDescription)")))
            case .cancelled:
                ready.finish(.failure(DistillAccountError.cancelled))
            default:
                break
            }
        }
        listener.start(queue: .global())
        return try await ready.wait()
    }

    private static func serve(_ connection: NWConnection, callbackPath: String, codeWaiter: OneShot<String>) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, _ in
            var status = "404 Not Found"
            var page = "Not found."
            if let data, let request = String(data: data, encoding: .utf8),
               let line = request.split(separator: "\r\n", maxSplits: 1).first {
                let parts = line.split(separator: " ")
                if parts.count >= 2, parts[0] == "GET",
                   let components = URLComponents(string: "http://localhost" + parts[1]),
                   components.path == callbackPath {
                    let items = components.queryItems ?? []
                    if items.contains(where: { $0.name == "error" }) {
                        status = "200 OK"
                        page = "Authorization was declined. You can close this tab."
                        codeWaiter.finish(.failure(DistillAccountError.failed(
                            "OpenRouter authorization was declined. Please try again.")))
                    } else if let code = items.first(where: { $0.name == "code" })?.value,
                              !code.trimmingCharacters(in: .whitespaces).isEmpty {
                        status = "200 OK"
                        page = "Authorization received. You can close this tab."
                        codeWaiter.finish(.success(code))
                    } else {
                        status = "400 Bad Request"
                        page = "Missing authorization code. Return to OpenRouter to finish signing in."
                    }
                }
            }
            let body = "<!doctype html><meta charset=utf-8><title>Distill</title><p>\(page)</p>"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    @Sendable
    public static func urlSessionPost(url: URL, body: Data) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Single-result rendezvous that tolerates finish-before-wait.
private final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?

    func finish(_ value: Result<T, Error>) {
        let pending: CheckedContinuation<T, Error>? = lock.withLock {
            guard result == nil else { return nil }
            result = value
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: value)
    }

    func wait() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<T, Error>? = lock.withLock {
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}

/// Splits child stderr into lines; reports the first https URL and remembers the last non-empty line.
private final class StderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let onURL: (@Sendable (URL) -> Void)?
    private var pending = ""
    private var urlSent = false
    private var last: String?

    init(onURL: (@Sendable (URL) -> Void)?) { self.onURL = onURL }

    var lastLine: String? { lock.withLock { last } }

    func append(_ data: Data) {
        let lines: [String] = lock.withLock {
            pending += String(decoding: data, as: UTF8.self)
            var out: [String] = []
            while let newline = pending.firstIndex(of: "\n") {
                out.append(String(pending[..<newline]))
                pending = String(pending[pending.index(after: newline)...])
            }
            return out
        }
        lines.forEach(handle)
    }

    func finish() {
        let rest: String = lock.withLock {
            defer { pending = "" }
            return pending
        }
        handle(rest)
    }

    private func handle(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        let found: URL? = lock.withLock {
            last = line
            guard !urlSent, let range = line.range(of: "https://") else { return nil }
            let token = line[range.lowerBound...].prefix { !$0.isWhitespace }
            guard let url = URL(string: String(token)) else { return nil }
            urlSent = true
            return url
        }
        if let found { onURL?(found) }
    }
}
