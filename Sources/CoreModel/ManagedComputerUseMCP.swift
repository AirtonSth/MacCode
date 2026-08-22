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

    /// Decode a zavora-style tools/call result so screenshot/zoom images survive.
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
        observationTools + mutationTools
    }

    private let queue: ComputerUseHostQueue
    private let backend: any ComputerUseToolBackend

    public init(
        queue: ComputerUseHostQueue = .shared,
        backend: any ComputerUseToolBackend = ComputerUseNativeHostBackend()
    ) {
        self.queue = queue
        self.backend = backend
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
                "instructions": "RemoteCode computer-use. HID is host-queued so bots never share the pointer.",
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
        case screenshotTool:
            return "Capture the screen or a targeted app/window with native host capture."
        case "zoom":
            return "Inspect a screen region at full resolution."
        case leftClickTool:
            return "Left-click at coordinates. Optional target_app / target_window_id."
        case "right_click":
            return "Right-click at coordinates. Optional target_app / target_window_id."
        case "mouse_move":
            return "Move the pointer without clicking."
        case "scroll":
            return "Scroll at coordinates."
        case typeTool:
            return "Type Unicode text into the targeted window."
        case keyTool:
            return "Press a key or combo (e.g. command+s)."
        case "cursor_position":
            return "Read the current pointer position."
        case "list_windows":
            return "List on-screen windows, optionally filtered by bundle id."
        case "get_ui_tree":
            return "Accessibility tree for a window."
        case "open_application":
            return "Open and focus an app by bundle id."
        case "click_element":
            return "Click a UI element by role and label."
        case "doctor":
            return "Permission and native-backend diagnostics."
        default:
            return name
        }
    }

    private static func inputSchema(for name: String) -> [String: Any] {
        let targeting: [String: Any] = [
            "target_app": ["type": "string"],
            "target_pid": ["type": "integer"],
            "target_window_id": ["type": "number"],
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
            ]
        case "zoom":
            return [
                "type": "object",
                "properties": ["region": ["type": "array", "items": ["type": "number"]]],
                "required": ["region"],
            ]
        case leftClickTool, "right_click", "mouse_move":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "coordinate": ["type": "array", "items": ["type": "number"]],
                ]) { _, new in new },
                "required": ["coordinate"],
            ]
        case "scroll":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "coordinate": ["type": "array", "items": ["type": "number"]],
                    "direction": ["type": "string"],
                    "amount": ["type": "number"],
                ]) { _, new in new },
                "required": ["coordinate", "direction"],
            ]
        case typeTool:
            return [
                "type": "object",
                "properties": targeting.merging(["text": ["type": "string"]]) { _, new in new },
                "required": ["text"],
            ]
        case keyTool:
            return [
                "type": "object",
                "properties": targeting.merging(["text": ["type": "string"]]) { _, new in new },
                "required": ["text"],
            ]
        case "open_application":
            return [
                "type": "object",
                "properties": ["bundle_id": ["type": "string"]],
                "required": ["bundle_id"],
            ]
        case "click_element":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "role": ["type": "string"],
                    "label": ["type": "string"],
                ]) { _, new in new },
                "required": ["role", "label"],
            ]
        case "list_windows":
            return [
                "type": "object",
                "properties": ["bundle_id": ["type": "string"]],
            ]
        default:
            return ["type": "object", "properties": [String: Any]()]
        }
    }

    private static func targetPID(from arguments: [String: Any]) -> Int32? {
        if let value = arguments["target_pid"] as? Int {
            return Int32(exactly: value)
        }
        if let value = arguments["target_pid"] as? NSNumber {
            return value.int32Value
        }
        if let value = arguments["target_pid"] as? String {
            return Int32(value)
        }
        return nil
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
