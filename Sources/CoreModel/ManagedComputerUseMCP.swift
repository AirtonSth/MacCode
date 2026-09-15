import Foundation

public struct ComputerUseContentPart: Sendable, Equatable {
    public var type: String
    public var text: String?
    public var data: String?
    public var mimeType: String?

    public init(type: String, text: String? = nil, data: String? = nil, mimeType: String? = nil) {
        self.type = type
        self.text = text
        self.data = data
        self.mimeType = mimeType
    }

    public static func text(_ value: String) -> ComputerUseContentPart {
        ComputerUseContentPart(type: "text", text: value)
    }

    public static func image(data: String, mimeType: String) -> ComputerUseContentPart {
        ComputerUseContentPart(type: "image", data: data, mimeType: mimeType)
    }

    /// Decode one zavora / MCP content item. Image parts keep data + mimeType.
    public static func parse(_ object: [String: Any]) -> ComputerUseContentPart? {
        guard let type = object["type"] as? String, !type.isEmpty else { return nil }
        return ComputerUseContentPart(
            type: type,
            text: object["text"] as? String,
            data: object["data"] as? String,
            mimeType: object["mimeType"] as? String
        )
    }

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = ["type": type]
        if let text { object["text"] = text }
        if let data { object["data"] = data }
        if let mimeType { object["mimeType"] = mimeType }
        return object
    }
}

public struct ComputerUseToolResult: Sendable, Equatable {
    public var content: [ComputerUseContentPart]
    public var isError: Bool

    public init(content: [ComputerUseContentPart], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public init(text: String, isError: Bool = false) {
        self.content = [.text(text)]
        self.isError = isError
    }

    /// Decode an injected/backend tools/call result so screenshot/zoom images survive.
    public static func parseUpstream(_ object: [String: Any]) -> ComputerUseToolResult {
        if let error = object["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? String(describing: error)
            return ComputerUseToolResult(text: message, isError: true)
        }
        let result = object["result"] as? [String: Any] ?? object
        let raw = result["content"] as? [[String: Any]] ?? []
        let parts = raw.compactMap(ComputerUseContentPart.parse)
        return ComputerUseToolResult(
            content: parts,
            isError: result["isError"] as? Bool ?? false
        )
    }

    public func jsonContent() -> [[String: Any]] {
        content.map { $0.jsonObject() }
    }
}

public protocol ComputerUseToolBackend: Sendable {
    func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult
}

/// Test backend: records that the host queue admitted the call. Production uses
/// the shipped native backend; callers can inject another backend for tests.
public struct ComputerUseQueuedPassthroughBackend: ComputerUseToolBackend {
    public init() {}

    public func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult {
        let keys = arguments.keys.sorted().joined(separator: ",")
        return ComputerUseToolResult(
            text: "queued \(name)\(keys.isEmpty ? "" : " keys=\(keys)")",
            isError: false
        )
    }
}

/// MCP stdio handler for the shipped native host backend: screenshot plus
/// targeted semantic/input operations. Mutating and observation tools share
/// `ComputerUseHostQueue` so two bots never interleave HID.
public struct ManagedComputerUseMCP: Sendable {
    public static let serverName = ComputerUseHostQueue.serverName
    public static let screenshotTool = "screenshot"
    public static let leftClickTool = "left_click"
    public static let typeTool = "type"
    public static let keyTool = "key"

    public static let observationTools: [String] = [
        screenshotTool,
        "zoom",
        "cursor_position",
        "list_windows",
        "get_ui_tree",
        "doctor",
    ]

    public static let mutationTools: [String] = [
        leftClickTool,
        "right_click",
        "mouse_move",
        "scroll",
        typeTool,
        keyTool,
        "open_application",
        "click_element",
    ]

    public static var advertisedToolNames: [String] {
        observationTools + mutationTools + ChromeProfileComputerUseBackend.tools
    }

    private let queue: ComputerUseHostQueue
    private let backend: any ComputerUseToolBackend
    private let browserBackend: any ComputerUseToolBackend

    public init(
        queue: ComputerUseHostQueue = .shared,
        backend: any ComputerUseToolBackend = ComputerUseNativeHostBackend(),
        browserBackend: any ComputerUseToolBackend = ChromeProfileComputerUseBackend()
    ) {
        self.queue = queue
        self.backend = backend
        self.browserBackend = browserBackend
    }

    public func handle(_ line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = message["method"] as? String else {
            return nil
        }
        let id = message["id"]
        if id == nil || method.hasPrefix("notifications/") {
            return nil
        }
        switch method {
        case "initialize":
            return reply(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": Self.serverName, "version": "1"],
                "instructions": "RemoteCode computer-use. Prefer browser_* for Chrome: these tools use your current profile in owned background tabs through the RemoteCode extension. Selecting an owned tab gives control to the user; automation must release it with browser_close. Native app actions require exact window identity and fresh state, yield to human activity, and never activate windows or move the physical pointer.",
            ])
        case "tools/list":
            return reply(id: id, result: ["tools": Self.toolCatalog()])
        case "tools/call":
            let params = message["params"] as? [String: Any]
            let name = params?["name"] as? String ?? ""
            let arguments = params?["arguments"] as? [String: Any] ?? [:]
            guard Self.advertisedToolNames.contains(name) else {
                return errorReply(id: id, code: -32602, message: "unknown tool: \(name)")
            }
            // Chrome's own background tabs do not use host HID or its lease.
            if ChromeProfileComputerUseBackend.tools.contains(name) {
                let result = await browserBackend.invoke(name: name, arguments: arguments)
                return reply(id: id, result: ["content": result.jsonContent(), "isError": result.isError])
            }
            let kind: ComputerUseHostQueue.Kind = Self.mutationTools.contains(name) ? .mutation : .observation
            let targetPID = Self.targetPID(from: arguments)
            do {
                let result = try await queue.withExclusive(kind: kind, targetPID: targetPID) {
                    await backend.invoke(name: name, arguments: arguments)
                }
                return reply(id: id, result: [
                    "content": result.jsonContent(),
                    "isError": result.isError,
                ])
            } catch is CancellationError {
                return errorReply(id: id, code: -32800, message: "computer-use call cancelled")
            } catch {
                return errorReply(id: id, code: -32000, message: String(describing: error))
            }
        default:
            return errorReply(id: id, code: -32601, message: "method not found: \(method)")
        }
    }

    public func closeBrowser() async {
        _ = await browserBackend.invoke(name: "browser_close", arguments: [:])
    }

    public static func toolCatalog() -> [[String: Any]] {
        advertisedToolNames.map { name in
            [
                "name": name,
                "description": description(for: name),
                "inputSchema": inputSchema(for: name),
            ]
        }
    }

    private static func description(for name: String) -> String {
        switch name {
        case "browser_open":
            return "Open an HTTP(S) URL in your session's inactive, muted tab in the user's current Chrome profile, using existing logins. Requires the RemoteCode Chrome extension. Returns immediately; call browser_snapshot next."
        case "browser_snapshot":
            return "Read text and element refs from your Chrome tab without activating it. Refs are replaced by each snapshot and after navigation."
        case "browser_act":
            return "Click, fill, append text, or scroll in your background Chrome tab using a fresh element ref. Yields if the user selects the tab. Never controls the OS pointer or clipboard."
        case "browser_close":
            return "Close only your owned background Chrome tab. If the user selected it, release ownership and leave it open."
        case "browser_status":
            return "Check whether the Chrome extension is connected, without opening a tab."
        case screenshotTool:
            return "Capture the exact target window; returned image coordinates are pixels with a top-left origin."
        case "zoom":
            return "Return an exact integral pixel crop from the target window; crop coordinates and returned image coordinates use a top-left origin."
        case leftClickTool:
            return "Left-click pixel coordinates relative to the returned screenshot or zoom image in the exact background target; requires its state token and never activates."
        case "right_click":
            return "Right-click at coordinates for the exact target; requires a state token and fails closed without focus-safe support."
        case "mouse_move":
            return "Move the pointer for the exact target; requires a state token and fails closed without activation."
        case "scroll":
            return "Scroll the exact target; requires a state token and fails closed without activation."
        case typeTool:
            return "Type Unicode text into a settable AX-focused element in the exact background target."
        case keyTool:
            return "Press a key or combo only with an exact target state token; unsupported focus-stealing input fails closed."
        case "cursor_position":
            return "Read the current pointer position."
        case "list_windows":
            return "List on-screen windows, optionally filtered by bundle id."
        case "get_ui_tree":
            return "Accessibility tree for a window."
        case "open_application":
            return "Report activation as forbidden; the native backend never opens or focuses an application."
        case "click_element":
            return "Press an AX element by role and label in the exact background target."
        case "doctor":
            return "Permission and native-backend diagnostics."
        default:
            return name
        }
    }

    private static func inputSchema(for name: String) -> [String: Any] {
        if ChromeProfileComputerUseBackend.tools.contains(name) {
            switch name {
            case "browser_open":
                return ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"]]
            case "browser_act":
                return ["type": "object", "properties": [
                    "action": ["type": "string", "enum": ["click", "fill", "type", "scroll"]],
                    "ref": ["type": "string"], "text": ["type": "string"],
                    "delta_x": ["type": "number"], "delta_y": ["type": "number"],
                ], "required": ["action"]]
            default:
                return ["type": "object", "properties": [String: Any]()]
            }
        }
        let targeting: [String: Any] = [
            "target_app": ["type": "string"],
            "target_pid": ["type": "integer"],
            "target_window_id": ["type": "integer"],
            "focus_strategy": ["type": "string"],
            "expected_state_token": ["type": "string"],
        ]
        switch name {
        case screenshotTool:
            return [
                "type": "object",
                "properties": targeting.merging([
                    "width": ["type": "number"],
                    "quality": ["type": "number"],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id"],
            ]
        case "zoom":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "region": ["type": "array", "description": "Integral [x,y,width,height] pixels in the full window image, top-left origin.", "items": ["type": "integer"]],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "region"],
            ]
        case leftClickTool, "right_click", "mouse_move":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "coordinate": ["type": "array", "description": "Pixel coordinates relative to the returned screenshot or zoom image, top-left origin.", "items": ["type": "number"]],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token", "coordinate"],
            ]
        case "scroll":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "coordinate": ["type": "array", "items": ["type": "number"]],
                    "direction": ["type": "string"],
                    "amount": ["type": "number"],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token", "coordinate", "direction"],
            ]
        case typeTool:
            return [
                "type": "object",
                "properties": targeting.merging(["text": ["type": "string"]]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token", "text"],
            ]
        case keyTool:
            return [
                "type": "object",
                "properties": targeting.merging(["text": ["type": "string"]]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token", "text"],
            ]
        case "open_application":
            return [
                "type": "object",
                "properties": targeting.merging(["bundle_id": ["type": "string"]]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token", "bundle_id"],
            ]
        case "click_element":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "role": ["type": "string"],
                    "label": ["type": "string"],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token", "role", "label"],
            ]
        case "list_windows":
            return [
                "type": "object",
                "properties": ["bundle_id": ["type": "string"]],
            ]
        case "doctor", "get_ui_tree", "cursor_position":
            return [
                "type": "object",
                "properties": targeting,
                "required": ["target_pid", "target_window_id"],
            ]
        default:
            return [
                "type": "object",
                "properties": targeting,
                "required": ["target_pid", "target_window_id"],
            ]
        }
    }

    private static func targetPID(from arguments: [String: Any]) -> Int32? {
        ComputerUseNativeHostBackend.exactInt32(arguments["target_pid"])
    }

    private func reply(id: Any?, result: [String: Any]) -> String? {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func errorReply(id: Any?, code: Int, message: String) -> String? {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }
}
