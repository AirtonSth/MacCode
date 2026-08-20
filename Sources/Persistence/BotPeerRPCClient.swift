import Foundation
import Darwin
import CoreModel

enum BotPeerRPCError: Error, CustomStringConvertible {
    case missingContext(String)
    case invalidContext(String)
    case socket(String)
    case invalidResponse
    case remote(String)

    var description: String {
        switch self {
        case .missingContext(let key): return "Bot delegation requires \(key) on the active provider run."
        case .invalidContext(let key): return "Bot delegation received an invalid \(key)."
        case .socket(let message): return message
        case .invalidResponse: return "RemoteCode returned an invalid Bot delegation response."
        case .remote(let message): return message
        }
    }
}

/// Blocking Unix-socket client used by the stdio MCP subprocess. The provider
/// is already blocked on its tool call while the app asynchronously runs the
/// peer Bot, so no polling or prompt inference belongs in this process.
struct BotPeerRPCClient {
    private static let maximumResponseBytes = 2 * 1_024 * 1_024

    let environment: [String: String]

    func call(method: String, arguments: [String: Any]) throws -> [String: Any] {
        let context = try requestContext()
        var params = arguments
        params["thread_id"] = context.threadID
        params["run_id"] = context.runID

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw BotPeerRPCError.socket("Bot delegation socket(): \(String(cString: strerror(errno)))")
        }
        defer { Darwin.close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = context.socketPath.utf8CString
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            throw BotPeerRPCError.socket("Bot delegation socket path is too long.")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
            tuplePointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                pathBytes.withUnsafeBufferPointer { source in
                    for index in source.indices { destination[index] = source[index] }
                }
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw BotPeerRPCError.socket(
                "Bot delegation could not connect to RemoteCode: \(String(cString: strerror(errno)))"
            )
        }

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ]
        var payload = try JSONSerialization.data(withJSONObject: request)
        payload.append(0x0A)
        let write = RC2CLIWriteLoop.writeAll(fd: fd, data: payload)
        guard write.success else {
            throw BotPeerRPCError.socket("Bot delegation request could not be written.")
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while response.last != 0x0A {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw BotPeerRPCError.socket("RemoteCode closed the Bot delegation request before replying.")
            }
            response.append(buffer, count: count)
            guard response.count <= Self.maximumResponseBytes else {
                throw BotPeerRPCError.invalidResponse
            }
        }
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw BotPeerRPCError.invalidResponse
        }
        if let error = object["error"] as? [String: Any] {
            throw BotPeerRPCError.remote(error["message"] as? String ?? "Bot delegation failed.")
        }
        guard let result = object["result"] as? [String: Any] else {
            throw BotPeerRPCError.invalidResponse
        }
        return result
    }

    private func requestContext() throws -> (socketPath: String, threadID: String, runID: String) {
        func required(_ key: String) throws -> String {
            guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { throw BotPeerRPCError.missingContext(key) }
            return value
        }
        let socketPath = try required(BotPeerDelegation.socketEnvironmentKey)
        let threadID = try required(BotPeerDelegation.threadEnvironmentKey)
        let runID = try required(BotPeerDelegation.runEnvironmentKey)
        guard UUID(uuidString: threadID) != nil else {
            throw BotPeerRPCError.invalidContext(BotPeerDelegation.threadEnvironmentKey)
        }
        guard UUID(uuidString: runID) != nil else {
            throw BotPeerRPCError.invalidContext(BotPeerDelegation.runEnvironmentKey)
        }
        return (socketPath, threadID, runID)
    }
}
