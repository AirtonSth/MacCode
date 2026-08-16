import Foundation

/// Forwards tool calls to a long-lived `@zavora-ai/computer-use-mcp` child.
/// The host queue already serializes callers; this process is one bot's stdio
/// MCP and must not spawn an unqueued sibling per call.
public final class ComputerUseZavoraForwardBackend: ComputerUseToolBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var nextID = 100
    private var initialized = false

    public init() {}

    deinit {
        process?.terminate()
    }

    public func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult {
        do {
            try ensureChild()
            return try call(name: name, arguments: arguments)
        } catch {
            return ComputerUseToolResult(
                text: "upstream @zavora-ai/computer-use-mcp unavailable: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    private func ensureChild() throws {
        lock.lock()
        defer { lock.unlock() }
        if process?.isRunning == true, stdin != nil, stdout != nil {
            if !initialized {
                try sendLocked(method: "initialize", params: ["protocolVersion": "2024-11-05", "capabilities": [String: Any](), "clientInfo": ["name": ComputerUseHostQueue.serverName]])
                _ = try readLocked()
                _ = try sendLocked(method: "notifications/initialized", params: [String: Any](), id: nil)
                initialized = true
            }
            return
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = ["npx", "--yes", "--prefer-offline", "@zavora-ai/computer-use-mcp"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        child.standardInput = inPipe
        child.standardOutput = outPipe
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        stdin = inPipe.fileHandleForWriting
        stdout = outPipe.fileHandleForReading
        initialized = false
        try sendLocked(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [String: Any](),
            "clientInfo": ["name": ComputerUseHostQueue.serverName, "version": "1"],
        ])
        _ = try readLocked()
        _ = try sendLocked(method: "notifications/initialized", params: [String: Any](), id: nil)
        initialized = true
    }

    private func call(name: String, arguments: [String: Any]) throws -> ComputerUseToolResult {
        lock.lock()
        defer { lock.unlock() }
        try sendLocked(method: "tools/call", params: ["name": name, "arguments": arguments])
        return ComputerUseToolResult.parseUpstream(try readLocked())
    }

    @discardableResult
    private func sendLocked(method: String, params: [String: Any], id: Int? = 0) throws -> Int? {
        guard let stdin else { throw ComputerUseHostQueueError.lockFileUnavailable("zavora stdin") }
        var payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        var usedID: Int?
        if let id {
            nextID += 1
            usedID = nextID
            payload["id"] = usedID as Any
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        stdin.write(data)
        stdin.write(Data("\n".utf8))
        return usedID
    }

    private func readLocked() throws -> [String: Any] {
        guard let stdout else { throw ComputerUseHostQueueError.lockFileUnavailable("zavora stdout") }
        var buffer = Data()
        while true {
            let chunk = stdout.readData(ofLength: 1)
            if chunk.isEmpty { break }
            if chunk == Data("\n".utf8) { break }
            buffer.append(chunk)
        }
        guard let object = try JSONSerialization.jsonObject(with: buffer) as? [String: Any] else {
            throw ComputerUseHostQueueError.lockFileUnavailable("zavora json")
        }
        return object
    }
}
