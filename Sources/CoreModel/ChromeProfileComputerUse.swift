import Darwin
import Foundation

/// Native messaging connects Chrome's extension to a local, user-only socket.
/// No debugging port, browser restart, profile copy, or cookie export is needed.
public enum ChromeProfileConnection {
    public static let hostName = "io.remotecode.computer_use"
    public static let extensionID = "ejnjfchbceelacijgldkmckpmjfpdgip"
    public static let hostArgument = "chrome-native-host"
    public static let setupURL = URL(string: "chrome://extensions/")!
    static let maximumFrameBytes = 1_048_576

    public static var directory: URL {
        directory(in: FileManager.default.homeDirectoryForCurrentUser)
    }

    private static func directory(in home: URL) -> URL {
        home
            .appendingPathComponent("Library/Application Support/RemoteCode/ChromeComputerUse")
    }

    public static var socketPath: String { directory.appendingPathComponent("bridge.sock").path }

    public static func installationSteps(for folder: URL) -> [String] {
        [
            "Open chrome://extensions/ in the Chrome profile you want RemoteCode to use.",
            "Turn on Developer mode, then click Load unpacked.",
            "In the folder picker, press Command-Shift-G, paste \(folder.path), press Return, then click Select.",
            "Keep this folder in place. Chrome loads the extension directly from it.",
        ]
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else { throw Failure(message: "Chrome bridge socket path is too long.") }
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { pointer in
                bytes.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: $0.count) }
            }
        }
        return address
    }

    static func wait(_ fd: Int32, events: Int16, until deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw Failure(message: "Chrome bridge timed out. Check the tab before retrying an action.") }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000, 30_000)))
            if result < 0 && errno == EINTR { continue }
            guard result > 0, descriptor.revents & events != 0 else {
                throw Failure(message: "Chrome bridge disconnected or timed out. Check the tab before retrying an action.")
            }
            return
        }
    }

    static func readBytes(_ count: Int, fd: Int32, until deadline: Date) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                try wait(fd, events: Int16(POLLIN), until: deadline)
                let size = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { throw Failure(message: "Chrome bridge closed the connection.") }
                offset += size
            }
        }
        return data
    }

    static func readFrame(fd: Int32, until deadline: Date) throws -> [String: Any] {
        let header = try readBytes(4, fd: fd, until: deadline)
        let size = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard size > 0, size <= maximumFrameBytes else { throw Failure(message: "Invalid Chrome message size.") }
        let data = try readBytes(Int(size), fd: fd, until: deadline)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Invalid Chrome message.")
        }
        return object
    }

    static func writeFrame(_ object: [String: Any], fd: Int32, until deadline: Date) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= maximumFrameBytes else { throw Failure(message: "Chrome message exceeds 1 MB.") }
        var size = UInt32(data.count).littleEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(data)
        try frame.withUnsafeBytes { buffer in
            var offset = 0
            while offset < frame.count {
                try wait(fd, events: Int16(POLLOUT), until: deadline)
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), frame.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw Failure(message: "Could not write to Chrome bridge.") }
                offset += written
            }
        }
    }

    static func noSIGPIPE(_ fd: Int32) {
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    public static func request(_ object: [String: Any], path: String = socketPath) throws -> [String: Any] {
        var address = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "Could not create Chrome bridge connection.") }
        defer { Darwin.close(fd) }
        noSIGPIPE(fd)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw Failure(message: "Chrome extension is not connected. Call browser_setup to install or repair it automatically.")
        }
        let deadline = Date().addingTimeInterval(20)
        var request = object
        let id = UUID().uuidString
        request["id"] = id
        try writeFrame(request, fd: fd, until: deadline)
        let response = try readFrame(fd: fd, until: deadline)
        guard response["id"] as? String == id else { throw Failure(message: "Chrome response did not match this request.") }
        return response
    }

    /// Chrome launches exactly this host via its allowlisted native manifest.
    /// Blocking poll keeps the connected host idle until a real request arrives.
    public static func runHost(origin: String, path: String = socketPath) throws {
        guard origin == "chrome-extension://\(extensionID)/" else {
            throw Failure(message: "Unexpected Chrome extension origin.")
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = Darwin.open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw Failure(message: "Could not lock Chrome bridge.") }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw Failure(message: "Another Chrome profile is connected. Disconnect its extension first.")
        }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Failure(message: "Could not start Chrome bridge.") }
        defer { Darwin.close(listener); unlink(path) }
        var address = try address(path)
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(listener, 8) == 0 else {
            throw Failure(message: "Could not listen for Chrome requests.")
        }
        signal(SIGPIPE, SIG_IGN)
        while true {
            var descriptors = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)]
            let ready = poll(&descriptors, 2, -1)
            if ready < 0 && errno == EINTR { continue }
            // Chrome's pipe closing means the extension disconnected. Never
            // leave a host daemon or an outstanding action behind.
            guard ready > 0, descriptors[1].revents == 0 else { return }
            guard descriptors[0].revents & Int16(POLLIN) != 0 else { return }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            defer { Darwin.close(client) }
            noSIGPIPE(client)
            let request: [String: Any]
            do { request = try readFrame(fd: client, until: Date().addingTimeInterval(2)) }
            catch { continue }
            let deadline = Date().addingTimeInterval(15)
            try writeFrame(request, fd: STDOUT_FILENO, until: deadline)
            var response = try readFrame(fd: STDIN_FILENO, until: deadline)
            guard response["id"] as? String == request["id"] as? String else {
                throw Failure(message: "Unexpected Chrome response. Reconnect the extension.")
            }
            response["chrome_pid"] = getppid()
            // A caller can disappear after an action. Do not replay it.
            try? writeFrame(response, fd: client, until: deadline)
        }
    }

    /// Install only this extension's native host registration and resources.
    /// Loading the unpacked extension remains an explicit Chrome UI action.
    public static func install(executable: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let manager = FileManager.default
        let directory = directory(in: homeDirectory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent("extension")
        // Match the shipped Contents/Resources layout. Bundle.module embeds a
        // developer build path and can fatalError in the installed app.
        let executableURL = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        let executableDirectory = executableURL.deletingLastPathComponent()
        let bundles = [
            executableDirectory.deletingLastPathComponent().appendingPathComponent("Resources/RemoteCode_CoreModel.bundle"),
            executableDirectory.appendingPathComponent("RemoteCode_CoreModel.bundle"),
        ]
        guard let source = bundles.compactMap({ Bundle(url: $0)?.url(forResource: "ChromeComputerUse", withExtension: nil) }).first else {
            throw Failure(message: "Chrome extension resources are missing from this build.")
        }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["manifest.json", "background.js"] {
            try Data(contentsOf: source.appendingPathComponent(name)).write(to: destination.appendingPathComponent(name), options: .atomic)
        }
        let host = directory.appendingPathComponent("native-host")
        let quoted = "'" + executableURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try Data("#!/bin/sh\nexec \(quoted) \(hostArgument) \"$@\"\n".utf8).write(to: host, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: host.path)
        let registration = homeDirectory.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")
        try manager.createDirectory(at: registration, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["name": hostName, "description": "RemoteCode background Chrome control",
                                       "path": host.path, "type": "stdio",
                                       "allowed_origins": ["chrome-extension://\(extensionID)/"]]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: registration.appendingPathComponent(hostName + ".json"), options: .atomic)
        return destination
    }
}

public final class ChromeProfileComputerUseBackend: ComputerUseToolBackend, @unchecked Sendable {
    public static let tools = ["browser_setup", "browser_open", "browser_snapshot", "browser_act", "browser_close", "browser_status"]
    private let sessionID = UUID().uuidString
    private let prepare: @Sendable () throws -> URL
    private let installInChrome: @Sendable (URL, Int32?) async throws -> Void
    private let send: @Sendable ([String: Any]) throws -> [String: Any]
    private let queue = DispatchQueue(label: "io.remotecode.chrome-profile")

    public init(
        prepare: @escaping @Sendable () throws -> URL = {
            try ChromeProfileConnection.install(executable: CommandLine.arguments[0])
        },
        installInChrome: @escaping @Sendable (URL, Int32?) async throws -> Void = {
            try await ChromeExtensionInstallAutomation.install(folder: $0, targetPID: $1)
        },
        send: @escaping @Sendable ([String: Any]) throws -> [String: Any] = { try ChromeProfileConnection.request($0) }
    ) {
        self.prepare = prepare
        self.installInChrome = installInChrome
        self.send = send
    }

    public func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult {
        if name == "browser_setup" { return await setup(arguments: arguments) }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                do {
                    guard Self.tools.contains(name) else { throw ChromeProfileConnection.Failure(message: "Unknown browser tool.") }
                    let response: [String: Any]
                    if name == "browser_status" {
                        let status: [String: Any]
                        do { status = try send(["operation": "browser_status", "session": sessionID, "arguments": [:]]) }
                        catch { status = ["ok": false, "error": error.localizedDescription] }
                        if status["ok"] as? Bool == true, status["connected"] as? Bool == true {
                            response = status
                        } else {
                            response = [
                                "ok": true, "connected": false, "next_tool": "browser_setup",
                                "message": status["error"] as? String ?? "Load or enable the RemoteCode extension in Chrome.",
                            ]
                        }
                    } else {
                        response = try send(["operation": name, "session": sessionID, "arguments": arguments])
                    }
                    let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
                    continuation.resume(returning: ComputerUseToolResult(
                        text: String(decoding: data, as: UTF8.self), isError: response["ok"] as? Bool != true
                    ))
                } catch {
                    continuation.resume(returning: ComputerUseToolResult(text: error.localizedDescription, isError: true))
                }
            }
        }
    }

    private func setup(arguments: [String: Any]) async -> ComputerUseToolResult {
        do {
            let targetPID = ComputerUseNativeHostBackend.exactInt32(arguments["target_pid"])
            if arguments["target_pid"] != nil && (targetPID == nil || targetPID! <= 0) {
                throw ChromeProfileConnection.Failure(message: "target_pid must identify a running Google Chrome process.")
            }
            let current = await invoke(name: "browser_status", arguments: [:])
            if try isConnected(current, targetPID: targetPID) { return current }
            let folder = try await Task.detached { [prepare] in try prepare() }.value
            try Task.checkCancellation()
            try await installInChrome(folder, targetPID)
            var status = current
            for _ in 0..<20 {
                try Task.checkCancellation()
                status = await invoke(name: "browser_status", arguments: [:])
                if try isConnected(status, targetPID: targetPID) { return status }
                try await Task.sleep(for: .milliseconds(250))
            }
            return ComputerUseToolResult(
                text: "Chrome loaded the extension, but the native connection could not be verified. Installation is not complete. Inspect the RemoteCode extension's error in Chrome before retrying browser_setup.\n\(status.content.first?.text ?? "")",
                isError: true
            )
        } catch {
            return ComputerUseToolResult(text: error.localizedDescription, isError: true)
        }
    }

    private func isConnected(_ result: ComputerUseToolResult, targetPID: Int32?) throws -> Bool {
        let data = Data((result.content.first?.text ?? "{}").utf8)
        let status = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard !result.isError && status?["ok"] as? Bool == true && status?["connected"] as? Bool == true else { return false }
        if let targetPID, ComputerUseNativeHostBackend.exactInt32(status?["chrome_pid"]) != targetPID {
            throw ChromeProfileConnection.Failure(message: "Another Chrome process is connected, or its identity cannot be verified. Disconnect that profile's RemoteCode extension before setting up the requested Chrome process.")
        }
        return true
    }
}
