import Foundation

/// Process seam for the app-owned headless Chrome instance. Tests inject a
/// recorder; the product launcher never asks the user to start debugging.
public protocol ManagedChromeHostProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    func terminate()
}

/// The small client surface needed by the composite bridge. Keeping this
/// protocol here lets routing tests exercise translation without a socket.
public protocol NativeChromeHostBrowsing: AnyObject, Sendable {
    func open(botID: BotID, url: String, title: String?) throws -> ChromeDevToolsPageState
    func state(botID: BotID) throws -> ChromeDevToolsPageState
    func snapshot(botID: BotID) throws -> ChromeDevToolsSnapshot
    func perform(
        botID: BotID,
        action: String,
        ref: String?,
        text: String,
        deltaX: Double,
        deltaY: Double
    ) throws -> ChromeDevToolsActionResult
}

extension ChromeDevToolsHostClient: NativeChromeHostBrowsing {}

public enum ManagedChromeHostBrowserBridgeError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case chromeExecutableMissing
    case endpointUnavailable
    case processExited

    public var description: String {
        switch self {
        case .chromeExecutableMissing:
            return "Google Chrome is not installed on this Mac. The native browser bridge cannot start."
        case .endpointUnavailable:
            return "The app-managed Google Chrome DevTools endpoint did not become available."
        case .processExited:
            return "The app-managed Google Chrome process exited before its DevTools endpoint became available."
        }
    }

    public var errorDescription: String? { description }
}

/// Composite bridge used by AppCommandRouter. Playwright routes retain their
/// existing child implementation; logical Desktop gets one app-owned,
/// headless Chrome process and one native CDP target per Bot.
public final class ManagedChromeHostBrowserBridge: BotBrowserBridging, @unchecked Sendable {
    public typealias LaunchProcess = @Sendable (URL, [String]) throws -> any ManagedChromeHostProcess
    public typealias MakeClient = @Sendable (ChromeDevToolsEndpoint) -> any NativeChromeHostBrowsing
    public typealias ReadFile = @Sendable (URL) -> Data?
    public typealias CreateDirectory = @Sendable (URL) throws -> Void
    public typealias RemoveFile = @Sendable (URL) throws -> Void
    public typealias Sleep = @Sendable (TimeInterval) -> Void

    private struct Session {
        let process: any ManagedChromeHostProcess
        let client: any NativeChromeHostBrowsing
    }

    private let playwright: any BotBrowserBridging
    private let resolveExecutable: @Sendable () -> URL?
    private let launchProcess: LaunchProcess
    private let makeClient: MakeClient
    private let readFile: ReadFile
    private let createDirectory: CreateDirectory
    private let removeFile: RemoveFile
    private let sleep: Sleep
    private let endpointTimeout: TimeInterval
    private let endpointPollInterval: TimeInterval
    private let navigationTimeout: TimeInterval
    private let navigationPollInterval: TimeInterval
    private let queue = DispatchQueue(label: "io.remotecode.bot-browser-composite")
    private var sessions: [String: Session] = [:]

    public init(
        playwright: any BotBrowserBridging = BotBrowserPlaywrightHost(),
        resolveExecutable: @escaping @Sendable () -> URL? = {
            ManagedChromeHostBrowserBridge.installedChromeExecutable()
        },
        launchProcess: @escaping LaunchProcess = { executable, arguments in
            try ManagedChromeHostBrowserBridge.defaultLaunchProcess(executable: executable, arguments: arguments)
        },
        makeClient: @escaping MakeClient = { endpoint in
            let discovery = ClosureChromeDevToolsEndpointDiscovery(
                discover: { endpoint },
                targetWebSocketURL: { targetID, endpoint in
                    try URLSessionChromeDevToolsEndpointDiscovery(
                        baseURL: endpoint.httpBaseURL
                    ).targetWebSocketURL(for: targetID, endpoint: endpoint)
                }
            )
            return ChromeDevToolsHostClient(
                endpointDiscovery: discovery,
                transport: URLSessionChromeDevToolsTransport()
            )
        },
        readFile: @escaping ReadFile = { url in
            try? Data(contentsOf: url, options: [.mappedIfSafe])
        },
        createDirectory: @escaping CreateDirectory = { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        },
        removeFile: @escaping RemoveFile = { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        },
        sleep: @escaping Sleep = { interval in
            Thread.sleep(forTimeInterval: interval)
        },
        endpointTimeout: TimeInterval = 5,
        endpointPollInterval: TimeInterval = 0.05,
        navigationTimeout: TimeInterval = 5,
        navigationPollInterval: TimeInterval = 0.05
    ) {
        self.playwright = playwright
        self.resolveExecutable = resolveExecutable
        self.launchProcess = launchProcess
        self.makeClient = makeClient
        self.readFile = readFile
        self.createDirectory = createDirectory
        self.removeFile = removeFile
        self.sleep = sleep
        self.endpointTimeout = max(0, endpointTimeout)
        self.endpointPollInterval = max(0, endpointPollInterval)
        self.navigationTimeout = max(0, navigationTimeout)
        self.navigationPollInterval = max(0, navigationPollInterval)
    }

    public static func defaultLaunchProcess(
        executable: URL,
        arguments: [String]
    ) throws -> any ManagedChromeHostProcess {
        try FoundationManagedChromeHostProcess.launch(executable: executable, arguments: arguments)
    }

    deinit {
        for session in sessions.values {
            session.process.terminate()
        }
    }

    /// Stops every app-owned Chrome process and waits for its process seam to
    /// report exit. This is intentionally scoped to this bridge's private
    /// sessions; it cannot affect the user's Chrome profile or focus.
    @discardableResult
    func shutdown(timeout: TimeInterval = 5) -> Bool {
        let processes: [any ManagedChromeHostProcess] = queue.sync {
            let processes = sessions.values.map { $0.process }
            sessions.removeAll()
            processes.forEach { $0.terminate() }
            return processes
        }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        for process in processes {
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return processes.allSatisfy { !$0.isRunning }
    }

    /// One stable app-owned profile per app-support root, shared by all Bots.
    public static func profileDirectory(appSupport: URL) -> URL {
        appSupport
            .appendingPathComponent("BotBrowsers", isDirectory: true)
            .appendingPathComponent("chrome-host", isDirectory: true)
    }

    public static func activePortFile(appSupport: URL) -> URL {
        profileDirectory(appSupport: appSupport).appendingPathComponent("DevToolsActivePort")
    }

    /// The flags deliberately select a private, headless process and never
    /// attach to the user's active Chrome profile or tab.
    public static func launchArguments(profileDirectory: URL) -> [String] {
        [
            "--headless=new",
            "--remote-debugging-port=0",
            "--user-data-dir=\(profileDirectory.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "about:blank",
        ]
    }

    /// Parses Chrome's two-line DevToolsActivePort file without network or UI
    /// work. The second line is normally `/devtools/browser/<uuid>`.
    public static func endpoint(fromActivePort raw: String) -> ChromeDevToolsEndpoint? {
        let lines = raw.split(whereSeparator: \.isNewline).map(String.init)
        guard let port = lines.first.flatMap(Int.init), (1...65_535).contains(port),
              let path = lines.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        let webSocketURL: URL?
        if path.hasPrefix("ws://") || path.hasPrefix("wss://") {
            webSocketURL = URL(string: path)
        } else {
            let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
            webSocketURL = URL(string: "ws://127.0.0.1:\(port)\(normalizedPath)")
        }
        guard let webSocketURL, webSocketURL.scheme == "ws" || webSocketURL.scheme == "wss" else {
            return nil
        }
        return ChromeDevToolsEndpoint(
            httpBaseURL: URL(string: "http://127.0.0.1:\(port)")!,
            browserWebSocketURL: webSocketURL
        )
    }

    /// Foundation-only executable lookup. No NSWorkspace activation or user
    /// prompt is involved, and an absent binary fails loudly at first use.
    public static func installedChromeExecutable(
        fileManager: FileManager = .default,
        homeDirectory: String = NSHomeDirectory()
    ) -> URL? {
        let candidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
            "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
            "\(homeDirectory)/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "\(homeDirectory)/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
        ]
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    public func perform(
        botID: BotID,
        route: BotBrowserRoute,
        kind: String,
        action: String,
        ref: String,
        text: String,
        url: String,
        appSupport: URL
    ) throws -> [String: Any] {
        try queue.sync {
            switch route {
            case .chromeHost:
                return try performChrome(
                    botID: botID,
                    kind: kind,
                    action: action,
                    ref: ref,
                    text: text,
                    url: url,
                    appSupport: appSupport
                )
            case .playwrightLocal, .playwrightGuest:
                return try playwright.perform(
                    botID: botID,
                    route: route,
                    kind: kind,
                    action: action,
                    ref: ref,
                    text: text,
                    url: url,
                    appSupport: appSupport
                )
            case .refused(let message):
                throw BotBrowserPlaywrightBridgeError.invalid(message)
            }
        }
    }

    private func performChrome(
        botID: BotID,
        kind: String,
        action: String,
        ref: String,
        text: String,
        url: String,
        appSupport: URL
    ) throws -> [String: Any] {
        let client = try client(for: appSupport)
        switch kind {
        case BotBrowserPlaywrightKind.open:
            // Read the current target before navigating so an unchanged old
            // page cannot masquerade as a successful redirect. A first-use
            // target may not answer yet, so this probe is deliberately best
            // effort and the settle loop remains bounded.
            let priorURL = try? client.state(botID: botID).url
            _ = try client.open(botID: botID, url: url, title: nil)
            let page = try settleNavigation(
                client: client,
                botID: botID,
                expectedURL: url,
                priorURL: priorURL
            )
            let snapshot = try client.snapshot(botID: botID)
            return Self.payload(page: page, content: Self.snapshotContent(snapshot, page: page))
        case BotBrowserPlaywrightKind.state:
            let page = try client.state(botID: botID)
            return Self.payload(page: page, content: "")
        case BotBrowserPlaywrightKind.snapshot:
            let snapshot = try client.snapshot(botID: botID)
            let page = try client.state(botID: botID)
            return Self.payload(page: page, content: Self.snapshotContent(snapshot, page: page))
        case BotBrowserPlaywrightKind.act:
            _ = try client.perform(
                botID: botID,
                action: action,
                ref: ref.isEmpty ? nil : ref,
                text: text,
                deltaX: 0,
                deltaY: 600
            )
            let page = try settleNavigation(
                client: client,
                botID: botID,
                expectedURL: nil,
                priorURL: nil
            )
            let snapshot = try client.snapshot(botID: botID)
            return Self.payload(page: page, content: Self.snapshotContent(snapshot, page: page))
        default:
            throw BotBrowserPlaywrightBridgeError.invalid("unknown bot browser action kind: \(kind)")
        }
    }

    private func client(for appSupport: URL) throws -> any NativeChromeHostBrowsing {
        let key = appSupport.standardizedFileURL.path
        if let session = sessions[key], session.process.isRunning {
            return session.client
        }
        if let stale = sessions.removeValue(forKey: key) {
            stale.process.terminate()
        }
        guard let executable = resolveExecutable() else {
            throw ManagedChromeHostBrowserBridgeError.chromeExecutableMissing
        }
        let profile = Self.profileDirectory(appSupport: appSupport)
        try createDirectory(profile)
        let activePort = Self.activePortFile(appSupport: appSupport)
        try removeFile(activePort)
        let process = try launchProcess(executable, Self.launchArguments(profileDirectory: profile))
        do {
            guard process.isRunning else {
                throw ManagedChromeHostBrowserBridgeError.processExited
            }
            guard let endpoint = waitForEndpoint(activePort: activePort, process: process) else {
                throw ManagedChromeHostBrowserBridgeError.endpointUnavailable
            }
            let client = makeClient(endpoint)
            sessions[key] = Session(process: process, client: client)
            return client
        } catch {
            process.terminate()
            throw error
        }
    }

    private func waitForEndpoint(
        activePort: URL,
        process: any ManagedChromeHostProcess
    ) -> ChromeDevToolsEndpoint? {
        let interval = endpointPollInterval
        let attempts = max(0, Int(ceil(endpointTimeout / max(interval, 0.001))))
        for attempt in 0...attempts {
            guard process.isRunning else { return nil }
            if let data = readFile(activePort),
               let raw = String(data: data, encoding: .utf8),
               let endpoint = Self.endpoint(fromActivePort: raw) {
                return endpoint
            }
            if attempt < attempts, interval > 0 {
                sleep(interval)
            }
        }
        return nil
    }

    private func settleNavigation(
        client: any NativeChromeHostBrowsing,
        botID: BotID,
        expectedURL: String?,
        priorURL: String?
    ) throws -> ChromeDevToolsPageState {
        let interval = navigationPollInterval
        let attempts = max(0, Int(ceil(navigationTimeout / max(interval, 0.001))))
        var page = try client.state(botID: botID)
        let expected = expectedURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prior = priorURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        func settled(_ candidate: ChromeDevToolsPageState) -> Bool {
            guard candidate.isReady, !candidate.url.isEmpty else { return false }
            guard let expected, !expected.isEmpty else { return true }
            if candidate.url == expected { return true }
            let baseline = (prior?.isEmpty == false ? prior! : "about:blank")
            return candidate.url != baseline
        }
        if settled(page) { return page }
        for _ in 0..<attempts {
            if interval > 0 { sleep(interval) }
            page = try client.state(botID: botID)
            if settled(page) { return page }
        }
        throw ChromeDevToolsHostClientError.timeout
    }

    private static func payload(page: ChromeDevToolsPageState, content: String) -> [String: Any] {
        ["url": page.url, "title": page.title, "content": content]
    }

    private static func snapshotContent(
        _ snapshot: ChromeDevToolsSnapshot,
        page: ChromeDevToolsPageState
    ) -> String {
        var lines = [
            "### Page",
            "- Page URL: \(page.url)",
            "- Page Title: \(page.title)",
            "### Snapshot",
        ]
        for element in snapshot.elements {
            var line = "- \(element.role) \"\(element.name)\" [ref=\(element.ref)]"
            if !element.value.isEmpty {
                line += " value=\"\(element.value)\""
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

private final class FoundationManagedChromeHostProcess: ManagedChromeHostProcess, @unchecked Sendable {
    private let process: Process

    private init(process: Process) {
        self.process = process
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    static func launch(executable: URL, arguments: [String]) throws -> FoundationManagedChromeHostProcess {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return FoundationManagedChromeHostProcess(process: process)
    }
}
