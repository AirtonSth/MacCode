import Foundation

public protocol BotComputerDockerClienting: Sendable {
    func info() throws -> String
    func imageExists(tag: String) throws -> Bool
    func build(context: URL, tag: String) throws
    func create(options: BotComputerContainerCreateOptions) throws -> String
    func start(name: String) throws
    func inspect(name: String) throws -> BotComputerContainerInspect
    func exec(name: String, command: [String]) throws -> Data
    func remove(name: String) throws
}

public struct BotComputerContainerInspect: Equatable, Sendable {
    public var running: Bool
    public var imageID: String
    public var hostPort: Int
    public init(running: Bool, imageID: String, hostPort: Int) {
        self.running = running
        self.imageID = imageID
        self.hostPort = hostPort
    }
}

/// App-process CLI wrapper. Agent children must never receive this client.
public struct BotComputerDockerCLI: BotComputerDockerClienting {
    public var run: @Sendable ([String]) throws -> Data

    public init(run: @escaping @Sendable ([String]) throws -> Data = BotComputerDockerCLI.defaultRun) {
        self.run = run
    }

    public func info() throws -> String {
        String(data: try run(["info"]), encoding: .utf8) ?? ""
    }

    public func imageExists(tag: String) throws -> Bool {
        do {
            _ = try run(["image", "inspect", tag])
            return true
        } catch {
            return false
        }
    }

    public func build(context: URL, tag: String) throws {
        _ = try run(["build", "-t", tag, context.path])
    }

    public func create(options: BotComputerContainerCreateOptions) throws -> String {
        var args = [
            "create",
            "--name", options.name,
            "--shm-size", "\(options.shmSize)",
            "-p", "\(options.hostIP):\(options.hostPort):\(options.containerPort)",
        ]
        for (key, value) in options.labels.sorted(by: { $0.key < $1.key }) {
            args += ["--label", "\(key)=\(value)"]
        }
        for bind in options.binds {
            args += ["-v", bind]
        }
        args.append(options.image)
        let data = try run(args)
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func start(name: String) throws {
        _ = try run(["start", name])
    }

    public func inspect(name: String) throws -> BotComputerContainerInspect {
        let data = try run([
            "inspect",
            "-f",
            "{{.State.Running}} {{.Image}} {{(index (index .NetworkSettings.Ports \"6080/tcp\") 0).HostPort}}",
            name,
        ])
        let parts = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
        let running = parts.first.map(String.init)?.lowercased() == "true"
        let image = parts.dropFirst().first.map(String.init) ?? ""
        let port = Int(parts.dropFirst(2).first.map(String.init) ?? "") ?? 0
        return BotComputerContainerInspect(running: running, imageID: image, hostPort: port)
    }

    public func exec(name: String, command: [String]) throws -> Data {
        try run(["exec", name] + command)
    }

    public func remove(name: String) throws {
        _ = try run(["rm", "-f", name])
    }

    public static func defaultRun(_ args: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker"] + args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            throw BotComputerGuestError.dockerUnavailable
        }
        return data
    }
}
