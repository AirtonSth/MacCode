import Foundation

/// Errors raised by the native Chrome DevTools host bridge.
public enum ChromeDevToolsHostClientError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case unavailableDebugEndpoint
    case staleReference
    case invalidURL
    case invalidAction(String)
    case transport(String)
    case protocolError(String)
    case timeout

    public var description: String {
        switch self {
        case .unavailableDebugEndpoint:
            return "Chrome DevTools debugging is unavailable."
        case .staleReference:
            return "The browser element reference is stale. Take a new snapshot and try again."
        case .invalidURL:
            return "A valid browser URL is required."
        case .invalidAction(let action):
            return "Unsupported browser action: \(action)"
        case .transport(let message):
            return "Chrome DevTools transport failed: \(message)"
        case .protocolError(let message):
            return "Chrome DevTools protocol failed: \(message)"
        case .timeout:
            return "Chrome DevTools timed out."
        }
    }

    public var errorDescription: String? { description }
}

/// Safe target creation is an explicit trust boundary. If Chrome cannot
/// provide a background target and target websocket, the bridge refuses to
/// fall back to an active tab or an application-focus change.
public enum BrowserBackgroundUnsupported: Error, Equatable, LocalizedError, CustomStringConvertible {
    case unsupported

    public var description: String {
        "Chrome cannot provide a safe background browser target."
    }

    public var errorDescription: String? { description }
}

public struct ChromeDevToolsEndpoint: Equatable, Sendable {
    public let httpBaseURL: URL
    public let browserWebSocketURL: URL

    public init(httpBaseURL: URL, browserWebSocketURL: URL) {
        self.httpBaseURL = httpBaseURL
        self.browserWebSocketURL = browserWebSocketURL
    }
}

/// Discovery is injectable so the synchronous Bot bridge can use a real
/// `/json/version` implementation while tests use a deterministic endpoint.
public protocol ChromeDevToolsEndpointDiscovering {
    func discover() throws -> ChromeDevToolsEndpoint
    func targetWebSocketURL(for targetID: String, endpoint: ChromeDevToolsEndpoint) throws -> URL?
}

public extension ChromeDevToolsEndpointDiscovering {
    func targetWebSocketURL(for targetID: String, endpoint: ChromeDevToolsEndpoint) throws -> URL? {
        nil
    }
}

public struct ClosureChromeDevToolsEndpointDiscovery: ChromeDevToolsEndpointDiscovering {
    private let closure: () throws -> ChromeDevToolsEndpoint
    private let targetClosure: (String, ChromeDevToolsEndpoint) throws -> URL?

    public init(
        discover: @escaping () throws -> ChromeDevToolsEndpoint,
        targetWebSocketURL: @escaping (String, ChromeDevToolsEndpoint) throws -> URL? = { _, _ in nil }
    ) {
        self.closure = discover
        self.targetClosure = targetWebSocketURL
    }

    public func discover() throws -> ChromeDevToolsEndpoint { try closure() }

    public func targetWebSocketURL(for targetID: String, endpoint: ChromeDevToolsEndpoint) throws -> URL? {
        try targetClosure(targetID, endpoint)
    }
}

/// The small transport seam keeps CDP command mapping independent of URLSession
/// and allows tests to assert every command without starting Chrome.
public protocol ChromeDevToolsTransport: AnyObject {
    func send(
        method: String,
        parameters: [String: Any],
        webSocketURL: URL
    ) throws -> [String: Any]
}

public struct ChromeDevToolsTarget: Equatable, Sendable {
    public let botID: BotID
    public let targetID: String
    public let webSocketURL: URL
    public let generation: UInt64

    public init(botID: BotID, targetID: String, webSocketURL: URL, generation: UInt64 = 1) {
        self.botID = botID
        self.targetID = targetID
        self.webSocketURL = webSocketURL
        self.generation = generation
    }
}

public struct ChromeDevToolsPageState: Equatable, Sendable {
    public let url: String
    public let title: String

    public init(url: String, title: String) {
        self.url = url
        self.title = title
    }
}

public struct ChromeDevToolsElement: Equatable, Sendable {
    public let ref: String
    public let role: String
    public let name: String
    public let value: String

    public init(ref: String, role: String, name: String, value: String = "") {
        self.ref = ref
        self.role = role
        self.name = name
        self.value = value
    }
}

public struct ChromeDevToolsSnapshot: Equatable, Sendable {
    public let target: ChromeDevToolsTarget
    public let token: String
    public let elements: [ChromeDevToolsElement]

    public init(target: ChromeDevToolsTarget, token: String, elements: [ChromeDevToolsElement]) {
        self.target = target
        self.token = token
        self.elements = elements
    }

    public var refs: [String] { elements.map(\.ref) }

    /// Compatibility spelling for bridges that call snapshot entries items.
    public var items: [ChromeDevToolsElement] { elements }
}

public struct ChromeDevToolsActionResult: Equatable, Sendable {
    public let target: ChromeDevToolsTarget
    public let action: String
    public let ref: String?

    public init(target: ChromeDevToolsTarget, action: String, ref: String? = nil) {
        self.target = target
        self.action = action
        self.ref = ref
    }
}

/// Synchronous native CDP client for the off-main Bot browser bridge.
///
/// The registry deliberately lives in this client instance: one client owns
/// one stable target per BotID, and no operation calls Target.activateTarget or
/// otherwise changes Chrome's active application/tab state.
public final class ChromeDevToolsHostClient: @unchecked Sendable {
    private struct Reference: Sendable {
        let target: ChromeDevToolsTarget
        let snapshotToken: String
        let domRef: String
    }

    private let endpointDiscovery: any ChromeDevToolsEndpointDiscovering
    private let transport: any ChromeDevToolsTransport
    private let lock = NSLock()
    private var targets: [BotID: ChromeDevToolsTarget] = [:]
    private var browserContexts: [BotID: String] = [:]
    private var references: [BotID: [String: Reference]] = [:]

    public init(
        endpointDiscovery: any ChromeDevToolsEndpointDiscovering,
        transport: any ChromeDevToolsTransport
    ) {
        self.endpointDiscovery = endpointDiscovery
        self.transport = transport
    }

    public convenience init(
        endpointDiscovery: @escaping () throws -> ChromeDevToolsEndpoint,
        transport: any ChromeDevToolsTransport
    ) {
        self.init(
            endpointDiscovery: ClosureChromeDevToolsEndpointDiscovery(discover: endpointDiscovery),
            transport: transport
        )
    }

    public convenience init(
        baseURL: URL = URL(string: "http://127.0.0.1:9222")!,
        transport: any ChromeDevToolsTransport = URLSessionChromeDevToolsTransport()
    ) {
        self.init(
            endpointDiscovery: URLSessionChromeDevToolsEndpointDiscovery(baseURL: baseURL),
            transport: transport
        )
    }

    /// Opens a URL in this Bot's background target without activating it.
    public func open(botID: BotID, url: String, title: String? = nil) throws -> ChromeDevToolsPageState {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsed = URL(string: trimmed), parsed.scheme != nil else {
            throw ChromeDevToolsHostClientError.invalidURL
        }
        let target = try target(for: botID)
        _ = try send(
            method: "Page.navigate",
            parameters: ["url": trimmed],
            target: target
        )
        return ChromeDevToolsPageState(url: trimmed, title: title ?? "")
    }

    /// Reads page state through Runtime.evaluate; no tab activation is needed.
    public func state(botID: BotID) throws -> ChromeDevToolsPageState {
        let target = try target(for: botID)
        let value = try evaluate(
            "(() => ({ url: String(location.href), title: String(document.title) }))()",
            target: target
        )
        guard let url = value["url"] as? String, let title = value["title"] as? String else {
            throw ChromeDevToolsHostClientError.protocolError("page state result is malformed")
        }
        return ChromeDevToolsPageState(url: url, title: title)
    }

    /// Takes a DOM snapshot and scopes every returned ref to this target and
    /// snapshot token. A later snapshot replaces the previous ref set.
    public func snapshot(botID: BotID) throws -> ChromeDevToolsSnapshot {
        let target = try target(for: botID)
        let token = UUID().uuidString.lowercased()
        let value = try evaluate(snapshotExpression(token: token), target: target)
        guard let rawElements = value["elements"] as? [[String: Any]] else {
            // The test seam also permits a bare array to keep protocol fixtures
            // small; the native expression always returns the keyed form.
            if let bare = value["value"] as? [[String: Any]] {
                return try storeSnapshot(botID: botID, target: target, token: token, rawElements: bare)
            }
            throw ChromeDevToolsHostClientError.protocolError("snapshot result is malformed")
        }
        return try storeSnapshot(botID: botID, target: target, token: token, rawElements: rawElements)
    }

    public func click(botID: BotID, ref: String) throws -> ChromeDevToolsActionResult {
        try perform(botID: botID, action: "click", ref: ref, text: "", deltaX: 0, deltaY: 0)
    }

    public func type(botID: BotID, ref: String, text: String) throws -> ChromeDevToolsActionResult {
        try perform(botID: botID, action: "type", ref: ref, text: text, deltaX: 0, deltaY: 0)
    }

    public func fill(botID: BotID, ref: String, text: String) throws -> ChromeDevToolsActionResult {
        try perform(botID: botID, action: "fill", ref: ref, text: text, deltaX: 0, deltaY: 0)
    }

    public func hover(botID: BotID, ref: String) throws -> ChromeDevToolsActionResult {
        try perform(botID: botID, action: "hover", ref: ref, text: "", deltaX: 0, deltaY: 0)
    }

    public func scroll(
        botID: BotID,
        ref: String? = nil,
        deltaX: Double = 0,
        deltaY: Double = 600
    ) throws -> ChromeDevToolsActionResult {
        try perform(botID: botID, action: "scroll", ref: ref, text: "", deltaX: deltaX, deltaY: deltaY)
    }

    /// String action mapping used by the existing bot_browser_act semantics.
    public func perform(
        botID: BotID,
        action: String,
        ref: String,
        text: String = ""
    ) throws -> ChromeDevToolsActionResult {
        try perform(botID: botID, action: action, ref: Optional(ref), text: text, deltaX: 0, deltaY: 600)
    }

    public func perform(
        botID: BotID,
        action: String,
        ref: String?,
        text: String = "",
        deltaX: Double = 0,
        deltaY: Double = 600
    ) throws -> ChromeDevToolsActionResult {
        let normalized = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["click", "type", "fill", "hover", "scroll"].contains(normalized) else {
            throw ChromeDevToolsHostClientError.invalidAction(action)
        }
        let resolvedRef: Reference?
        if normalized == "scroll", ref == nil {
            resolvedRef = nil
        } else {
            guard let ref, let resolved = reference(botID: botID, ref: ref) else {
                throw ChromeDevToolsHostClientError.staleReference
            }
            resolvedRef = resolved
        }
        let target = try target(for: botID)
        if let resolvedRef, resolvedRef.target != target {
            throw ChromeDevToolsHostClientError.staleReference
        }

        let expression: String
        switch normalized {
        case "click":
            expression = actionExpression(ref: resolvedRef!.domRef, action: "click", text: "", deltaX: 0, deltaY: 0)
        case "type", "fill":
            expression = actionExpression(ref: resolvedRef!.domRef, action: normalized, text: text, deltaX: 0, deltaY: 0)
        case "hover":
            expression = actionExpression(ref: resolvedRef!.domRef, action: "hover", text: "", deltaX: 0, deltaY: 0)
        case "scroll":
            expression = actionExpression(ref: resolvedRef?.domRef, action: "scroll", text: "", deltaX: deltaX, deltaY: deltaY)
        default:
            throw ChromeDevToolsHostClientError.invalidAction(action)
        }
        let value = try evaluate(expression, target: target)
        if let ok = value["ok"] as? Bool, !ok {
            if value["error"] as? String == "stale_ref" {
                throw ChromeDevToolsHostClientError.staleReference
            }
            throw ChromeDevToolsHostClientError.protocolError("browser action was rejected")
        }
        return ChromeDevToolsActionResult(target: target, action: normalized, ref: ref)
    }

    private func target(for botID: BotID) throws -> ChromeDevToolsTarget {
        lock.lock()
        defer { lock.unlock() }
        if let existing = targets[botID] { return existing }

        let endpoint: ChromeDevToolsEndpoint
        do {
            endpoint = try endpointDiscovery.discover()
        } catch let error as ChromeDevToolsHostClientError {
            throw error
        } catch {
            throw ChromeDevToolsHostClientError.unavailableDebugEndpoint
        }
        let browserContextID = try browserContext(for: botID, endpoint: endpoint)
        let creation: [String: Any]
        do {
            creation = try transport.send(
                method: "Target.createTarget",
                parameters: [
                    "url": "about:blank",
                    "browserContextId": browserContextID,
                    "background": true,
                    "hidden": true,
                    "newWindow": false,
                    "focus": false
                ],
                webSocketURL: endpoint.browserWebSocketURL
            )
        } catch let error as BrowserBackgroundUnsupported {
            throw error
        } catch let error as ChromeDevToolsHostClientError {
            if case .protocolError = error {
                throw BrowserBackgroundUnsupported.unsupported
            }
            throw error
        } catch {
            throw BrowserBackgroundUnsupported.unsupported
        }
        guard let result = creation["result"] as? [String: Any],
              let targetID = result["targetId"] as? String,
              !targetID.isEmpty else {
            throw BrowserBackgroundUnsupported.unsupported
        }
        if let background = result["background"] as? Bool, !background {
            throw BrowserBackgroundUnsupported.unsupported
        }
        if let focused = result["focused"] as? Bool, focused {
            throw BrowserBackgroundUnsupported.unsupported
        }
        if let focus = result["focus"] as? Bool, focus {
            throw BrowserBackgroundUnsupported.unsupported
        }

        let webSocketURL: URL?
        if let raw = result["webSocketDebuggerUrl"] as? String {
            webSocketURL = URL(string: raw)
        } else {
            webSocketURL = try? endpointDiscovery.targetWebSocketURL(for: targetID, endpoint: endpoint)
        }
        guard let webSocketURL, webSocketURL.scheme == "ws" || webSocketURL.scheme == "wss" else {
            throw BrowserBackgroundUnsupported.unsupported
        }
        if targets.values.contains(where: { $0.targetID == targetID }) {
            // Reusing a target across Bot IDs is never a safe recovery. Keep
            // the bridge fail-closed rather than silently crossing isolation.
            throw BrowserBackgroundUnsupported.unsupported
        }
        let target = ChromeDevToolsTarget(
            botID: botID,
            targetID: targetID,
            webSocketURL: webSocketURL,
            generation: UInt64(targets.count + 1)
        )
        targets[botID] = target
        return target
    }

    private func browserContext(for botID: BotID, endpoint: ChromeDevToolsEndpoint) throws -> String {
        if let existing = browserContexts[botID] { return existing }

        let creation: [String: Any]
        do {
            creation = try transport.send(
                method: "Target.createBrowserContext",
                parameters: ["disposeOnDetach": false],
                webSocketURL: endpoint.browserWebSocketURL
            )
        } catch let error as BrowserBackgroundUnsupported {
            throw error
        } catch let error as ChromeDevToolsHostClientError {
            if case .protocolError = error {
                throw BrowserBackgroundUnsupported.unsupported
            }
            throw error
        } catch {
            throw BrowserBackgroundUnsupported.unsupported
        }
        guard let result = creation["result"] as? [String: Any],
              let contextID = result["browserContextId"] as? String,
              !contextID.isEmpty else {
            throw BrowserBackgroundUnsupported.unsupported
        }
        if browserContexts.values.contains(contextID) {
            // BrowserContext IDs are isolation boundaries. Never silently
            // attach two Bot IDs to one context if Chrome returns a duplicate.
            throw BrowserBackgroundUnsupported.unsupported
        }
        browserContexts[botID] = contextID
        return contextID
    }

    private func send(
        method: String,
        parameters: [String: Any],
        target: ChromeDevToolsTarget
    ) throws -> [String: Any] {
        do {
            let response = try transport.send(
                method: method,
                parameters: parameters,
                webSocketURL: target.webSocketURL
            )
            if let error = response["error"] as? [String: Any] {
                throw ChromeDevToolsHostClientError.protocolError(
                    error["message"] as? String ?? "unknown CDP error"
                )
            }
            return response
        } catch let error as ChromeDevToolsHostClientError {
            throw error
        } catch {
            throw ChromeDevToolsHostClientError.transport(String(describing: error))
        }
    }

    private func evaluate(_ expression: String, target: ChromeDevToolsTarget) throws -> [String: Any] {
        let response = try send(
            method: "Runtime.evaluate",
            parameters: [
                "expression": expression,
                "returnByValue": true,
                "awaitPromise": true
            ],
            target: target
        )
        guard let result = response["result"] as? [String: Any] else {
            throw ChromeDevToolsHostClientError.protocolError("Runtime.evaluate result is missing")
        }
        if result["exceptionDetails"] != nil {
            throw ChromeDevToolsHostClientError.protocolError("Runtime.evaluate raised an exception")
        }
        guard let value = result["result"] as? [String: Any],
              let object = value["value"] as? [String: Any] else {
            throw ChromeDevToolsHostClientError.protocolError("Runtime.evaluate value is malformed")
        }
        return object
    }

    private func reference(botID: BotID, ref: String) -> Reference? {
        lock.lock()
        defer { lock.unlock() }
        return references[botID]?[ref]
    }

    private func storeSnapshot(
        botID: BotID,
        target: ChromeDevToolsTarget,
        token: String,
        rawElements: [[String: Any]]
    ) throws -> ChromeDevToolsSnapshot {
        let elements = try rawElements.enumerated().map { index, raw -> ChromeDevToolsElement in
            guard let role = raw["role"] as? String,
                  let name = raw["name"] as? String else {
                throw ChromeDevToolsHostClientError.protocolError("snapshot element \(index) is malformed")
            }
            // The DOM expression and the local registry both derive refs from
            // this snapshot token. Never trust a provider-supplied ref that
            // could accidentally alias an older snapshot or another target.
            let ref = "\(token).\(index)"
            return ChromeDevToolsElement(
                ref: ref,
                role: role,
                name: name,
                value: raw["value"] as? String ?? ""
            )
        }
        var stored: [String: Reference] = [:]
        for element in elements {
            stored[element.ref] = Reference(
                target: target,
                snapshotToken: token,
                domRef: element.ref
            )
        }
        lock.lock()
        references[botID] = stored
        lock.unlock()
        return ChromeDevToolsSnapshot(target: target, token: token, elements: elements)
    }

    private func snapshotExpression(token: String) -> String {
        """
        (() => {
          const token = '\(token)';
          const visible = (element) => {
            const rect = element.getBoundingClientRect();
            const style = getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
          };
          const selector = 'a,button,input,textarea,select,[role],[tabindex]';
          const elements = Array.from(document.querySelectorAll(selector)).filter(visible).slice(0, 100);
          return { elements: elements.map((element, index) => {
            const ref = token + '.' + index;
            element.setAttribute('data-remotecode-ref', ref);
            return {
              ref,
              role: element.getAttribute('role') || element.tagName.toLowerCase(),
              name: (element.getAttribute('aria-label') || element.innerText || element.getAttribute('name') || '').trim(),
              value: 'value' in element ? String(element.value || '') : ''
            };
          }) };
        })()
        """
    }

    private func actionExpression(
        ref: String?,
        action: String,
        text: String,
        deltaX: Double,
        deltaY: Double
    ) -> String {
        let refLiteral = ref.map(javascriptStringLiteral) ?? "null"
        let textLiteral = javascriptStringLiteral(text)
        switch action {
        case "click":
            return """
            (() => { const ref = \(refLiteral); const element = document.querySelector('[data-remotecode-ref="' + ref + '"]'); if (!element) return {ok:false,error:'stale_ref'}; element.click(); return {ok:true}; })()
            """
        case "type", "fill":
            return """
            (() => { const ref = \(refLiteral); const element = document.querySelector('[data-remotecode-ref="' + ref + '"]'); if (!element) return {ok:false,error:'stale_ref'}; element.focus(); element.value = \(textLiteral); element.dispatchEvent(new Event('input',{bubbles:true})); element.dispatchEvent(new Event('change',{bubbles:true})); return {ok:true}; })()
            """
        case "hover":
            return """
            (() => { const ref = \(refLiteral); const element = document.querySelector('[data-remotecode-ref="' + ref + '"]'); if (!element) return {ok:false,error:'stale_ref'}; const rect = element.getBoundingClientRect(); const init = {bubbles:true,clientX:rect.left + rect.width / 2,clientY:rect.top + rect.height / 2}; element.dispatchEvent(new MouseEvent('mouseover',init)); element.dispatchEvent(new MouseEvent('mouseenter',init)); element.dispatchEvent(new MouseEvent('mousemove',init)); return {ok:true}; })()
            """
        case "scroll":
            let scrollTarget = ref.map { "document.querySelector('[data-remotecode-ref=\\\"' + \(javascriptStringLiteral($0)) + '\\\"]')" } ?? "null"
            return """
            (() => { const element = \(scrollTarget); if (element && !element.isConnected) return {ok:false,error:'stale_ref'}; if (element) element.scrollBy(\(deltaX),\(deltaY)); else window.scrollBy(\(deltaX),\(deltaY)); return {ok:true}; })()
            """
        default:
            return "({ok:false,error:'unsupported_action'})"
        }
    }

    private func javascriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2 else {
            return "\"\""
        }
        return String(encoded.dropFirst().dropLast())
    }
}

/// Internal seam for deterministic tests of the Foundation WebSocket session.
/// Production uses the URLSession adapter below; tests provide a queued socket
/// without starting Chrome or a server process.
protocol ChromeDevToolsWebSocketTasking: AnyObject {
    func resume()
    func cancel()
    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping (Error?) -> Void
    )
    func receive(
        completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    )
}

private final class URLSessionChromeDevToolsWebSocketTask: ChromeDevToolsWebSocketTasking {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func resume() { task.resume() }
    func cancel() { task.cancel() }

    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping (Error?) -> Void
    ) {
        task.send(message, completionHandler: completionHandler)
    }

    func receive(
        completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    ) {
        task.receive(completionHandler: completionHandler)
    }
}

/// One persistent CDP WebSocket session. Commands on one session are
/// serialized, while different browser/target URLs retain independent lanes.
/// CDP events have no `id` and are consumed until the command's exact id
/// arrives; a different numeric id is a protocol violation, not a response to
/// accept or a reason to retry against a visible target.
private final class ChromeDevToolsPersistentWebSocket: @unchecked Sendable {
    private let task: any ChromeDevToolsWebSocketTasking
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var nextCommandID = 1

    init(task: any ChromeDevToolsWebSocketTasking, timeout: TimeInterval) {
        self.task = task
        self.timeout = timeout
        task.resume()
    }

    func close() { task.cancel() }

    deinit { close() }

    func send(method: String, parameters: [String: Any]) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        let commandID = nextCommandID
        nextCommandID += 1
        let body: [String: Any] = [
            "id": commandID,
            "method": method,
            "params": parameters
        ]
        guard JSONSerialization.isValidJSONObject(body) else {
            throw ChromeDevToolsHostClientError.protocolError("command is not JSON")
        }
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        guard let message = String(data: data, encoding: .utf8) else {
            throw ChromeDevToolsHostClientError.protocolError("command could not be encoded")
        }
        try sendMessage(.string(message))

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let object = try receiveObject(until: deadline)
            // CDP event frames (for example Page.loadEventFired) arrive before
            // a command reply and intentionally have no id.
            guard let rawID = object["id"] else { continue }
            guard let responseID = Self.commandID(rawID) else {
                throw ChromeDevToolsHostClientError.protocolError("CDP response id is malformed")
            }
            guard responseID == commandID else {
                throw ChromeDevToolsHostClientError.protocolError(
                    "CDP response id \(responseID) did not match command id \(commandID)"
                )
            }
            return object
        }
    }

    private func sendMessage(_ message: URLSessionWebSocketTask.Message) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var sendError: Error?
        task.send(message) { error in
            sendError = error
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw ChromeDevToolsHostClientError.timeout
        }
        if let sendError {
            throw ChromeDevToolsHostClientError.transport(String(describing: sendError))
        }
    }

    private func receiveObject(until deadline: Date) throws -> [String: Any] {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw ChromeDevToolsHostClientError.timeout }

        let semaphore = DispatchSemaphore(value: 0)
        var received: URLSessionWebSocketTask.Message?
        var receiveError: Error?
        task.receive { result in
            switch result {
            case .success(let message): received = message
            case .failure(let error): receiveError = error
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + remaining) == .success else {
            throw ChromeDevToolsHostClientError.timeout
        }
        if let receiveError {
            throw ChromeDevToolsHostClientError.transport(String(describing: receiveError))
        }
        guard let received else {
            throw ChromeDevToolsHostClientError.transport("empty WebSocket response")
        }
        let responseData: Data
        switch received {
        case .string(let string):
            responseData = Data(string.utf8)
        case .data(let data):
            responseData = data
        @unknown default:
            throw ChromeDevToolsHostClientError.transport("unknown WebSocket response")
        }
        guard let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw ChromeDevToolsHostClientError.protocolError("WebSocket response is not a JSON object")
        }
        return object
    }

    private static func commandID(_ value: Any) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}

/// Foundation-only synchronous transport with persistent browser/target CDP
/// sessions. The host bridge is intentionally off-main, so narrow semaphore
/// waits preserve its synchronous integration contract without UI work.
public final class URLSessionChromeDevToolsTransport: ChromeDevToolsTransport, @unchecked Sendable {
    private let timeout: TimeInterval
    private let webSocketFactory: (URL) -> any ChromeDevToolsWebSocketTasking
    private let socketsLock = NSLock()
    private var sockets: [URL: ChromeDevToolsPersistentWebSocket] = [:]

    public init(session: URLSession = .shared, timeout: TimeInterval = 15) {
        self.timeout = timeout
        self.webSocketFactory = { url in
            URLSessionChromeDevToolsWebSocketTask(task: session.webSocketTask(with: url))
        }
    }

    /// Injectable socket construction keeps persistence, event draining, and
    /// response-id correlation testable without a Chrome process.
    init(
        timeout: TimeInterval = 15,
        webSocketFactory: @escaping (URL) -> any ChromeDevToolsWebSocketTasking
    ) {
        self.timeout = timeout
        self.webSocketFactory = webSocketFactory
    }

    deinit {
        socketsLock.lock()
        let sessions = Array(sockets.values)
        sockets.removeAll()
        socketsLock.unlock()
        // Deinitialization closes each persistent CDP session, including the
        // browser session that owns hidden target lifetime.
        sessions.forEach { $0.close() }
    }

    public func send(
        method: String,
        parameters: [String: Any],
        webSocketURL: URL
    ) throws -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(parameters) else {
            throw ChromeDevToolsHostClientError.protocolError("command parameters are not JSON")
        }
        let socket = persistentSocket(for: webSocketURL)
        do {
            return try socket.send(method: method, parameters: parameters)
        } catch {
            remove(socket: socket, for: webSocketURL)
            throw error
        }
    }

    private func persistentSocket(for url: URL) -> ChromeDevToolsPersistentWebSocket {
        socketsLock.lock()
        defer { socketsLock.unlock() }
        if let existing = sockets[url] { return existing }
        let socket = ChromeDevToolsPersistentWebSocket(
            task: webSocketFactory(url),
            timeout: timeout
        )
        sockets[url] = socket
        return socket
    }

    private func remove(socket: ChromeDevToolsPersistentWebSocket, for url: URL) {
        socketsLock.lock()
        defer { socketsLock.unlock() }
        guard sockets[url] === socket else { return }
        sockets.removeValue(forKey: url)
    }
}

/// Native `/json/version` and `/json/list` discovery for Chrome's debugging
/// endpoint. It never opens, focuses, or activates a browser target.
public final class URLSessionChromeDevToolsEndpointDiscovery: ChromeDevToolsEndpointDiscovering, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let timeout: TimeInterval

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:9222")!,
        session: URLSession = .shared,
        timeout: TimeInterval = 10
    ) {
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
    }

    public func discover() throws -> ChromeDevToolsEndpoint {
        let object = try get(path: "json/version")
        guard let raw = object["webSocketDebuggerUrl"] as? String,
              let webSocketURL = URL(string: raw),
              webSocketURL.scheme == "ws" || webSocketURL.scheme == "wss" else {
            throw ChromeDevToolsHostClientError.unavailableDebugEndpoint
        }
        return ChromeDevToolsEndpoint(httpBaseURL: baseURL, browserWebSocketURL: webSocketURL)
    }

    public func targetWebSocketURL(for targetID: String, endpoint: ChromeDevToolsEndpoint) throws -> URL? {
        let object = try get(path: "json/list", baseURL: endpoint.httpBaseURL)
        guard let list = object["targets"] as? [[String: Any]] else { return nil }
        guard let target = list.first(where: { $0["id"] as? String == targetID }),
              let raw = target["webSocketDebuggerUrl"] as? String else { return nil }
        return URL(string: raw)
    }

    private func get(path: String, baseURL: URL? = nil) throws -> [String: Any] {
        let root = baseURL ?? self.baseURL
        let url = root.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var responseError: Error?
        session.dataTask(with: request) { value, _, error in
            data = value
            responseError = error
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw ChromeDevToolsHostClientError.timeout
        }
        if let responseError { throw ChromeDevToolsHostClientError.transport(String(describing: responseError)) }
        guard let data else { throw ChromeDevToolsHostClientError.unavailableDebugEndpoint }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw ChromeDevToolsHostClientError.unavailableDebugEndpoint
        }
        if let dictionary = object as? [String: Any] { return dictionary }
        if let array = object as? [[String: Any]] { return ["targets": array] }
        throw ChromeDevToolsHostClientError.unavailableDebugEndpoint
    }
}
