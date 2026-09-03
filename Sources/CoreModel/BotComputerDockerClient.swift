import Foundation
import Darwin
import os

private let botComputerDockerLog = Logger(
    subsystem: "io.remotecode.app",
    category: "bot-computer-docker"
)

public enum BotComputerDockerRecovery: Equatable, Sendable {
    case installCLI
    case startDaemon
    case retryTimedOutProbe
    case retryProvisioning

    public var message: String {
        switch self {
        case .installCLI:
            return "Docker CLI is not installed. Install Docker Desktop or OrbStack, then try again."
        case .startDaemon:
            return "Docker is not running. Start Docker Desktop or OrbStack, then try again."
        case .retryTimedOutProbe:
            return "Checking Docker timed out. Try again."
        case .retryProvisioning:
            return "Could not start the Linux desktop. Try again after Docker is ready."
        }
    }

    public var accessibilityLabel: String { message }

    public var accessibilityAction: String {
        switch self {
        case .installCLI: return "Install Docker CLI"
        case .startDaemon: return "Start Docker"
        case .retryTimedOutProbe: return "Retry Docker check"
        case .retryProvisioning: return "Retry starting Linux desktop"
        }
    }

    public static func matching(_ message: String) -> BotComputerDockerRecovery? {
        [installCLI, startDaemon, retryTimedOutProbe, retryProvisioning]
            .first { message == $0.message || message.contains($0.message) }
    }
}

public enum BotComputerDockerError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case cliMissing
    case daemonUnavailable
    case probeTimedOut
    case outputTooLarge
    case networkAddressPoolExhausted
    case networkSubnetUnavailable
    case provisioningFailed

    public var recovery: BotComputerDockerRecovery {
        switch self {
        case .cliMissing: return .installCLI
        case .daemonUnavailable: return .startDaemon
        case .probeTimedOut: return .retryTimedOutProbe
        case .outputTooLarge: return .retryProvisioning
        case .networkAddressPoolExhausted, .networkSubnetUnavailable, .provisioningFailed:
            return .retryProvisioning
        }
    }

    public var description: String { recovery.message }
    public var errorDescription: String? { description }
}

public protocol BotComputerDockerClienting: Sendable {
    func info() throws -> String
    func imageExists(tag: String) throws -> Bool
    func imageLabel(tag: String, key: String) throws -> String
    func imageID(tag: String) throws -> String
    func build(context: URL, tag: String) throws
    func create(options: BotComputerContainerCreateOptions) throws -> String
    func start(name: String) throws
    func stop(name: String) throws
    func inspect(name: String) throws -> BotComputerContainerInspect
    func containerExists(name: String) throws -> Bool
    func exec(name: String, command: [String], user: String?, detach: Bool) throws -> Data
    func rename(from: String, to: String) throws
    func ensureNetwork(name: String) throws
    func removeNetwork(name: String) throws
    func remove(name: String) throws
    func removeMatching(namePrefix: String) throws
}

public extension BotComputerDockerClienting {
    func removeNetwork(name: String) throws {}

    func containerExists(name: String) throws -> Bool {
        do {
            _ = try inspect(name: name)
            return true
        } catch BotComputerGuestError.notReady {
            return false
        }
    }
}

public struct BotComputerContainerInspect: Equatable, Sendable {
    public var running: Bool
    public var imageID: String
    public var hostPort: Int
    public var networkNames: [String]
    public init(running: Bool, imageID: String, hostPort: Int, networkNames: [String] = []) {
        self.running = running
        self.imageID = imageID
        self.hostPort = hostPort
        self.networkNames = networkNames
    }
}

/// App-process CLI wrapper. Agent children must never receive this client.
public struct BotComputerDockerCLI: BotComputerDockerClienting {
    static let stdoutRetentionLimit = 8 * 1_024 * 1_024
    static let buildStdoutRetentionLimit = 64 * 1_024 * 1_024
    static let stderrRetentionLimit = 16 * 1_024
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

    public func imageLabel(tag: String, key: String) throws -> String {
        let data = try run([
            "inspect",
            "-f",
            "{{index .Config.Labels \"\(key)\"}}",
            tag,
        ])
        return (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func imageID(tag: String) throws -> String {
        let data = try run(["inspect", "-f", "{{.Id}}", tag])
        return (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func build(context: URL, tag: String) throws {
        _ = try run([
            "build",
            "-t", tag,
            "--label",
            "\(BotComputerGuestSpec.recipeLabelKey)=\(BotComputerGuestSpec.recipeRevision)",
            context.path,
        ])
    }

    public func create(options: BotComputerContainerCreateOptions) throws -> String {
        var args = [
            "create",
            "--name", options.name,
            "--shm-size", "\(options.shmSize)",
            "-p", "\(options.hostIP):\(options.hostPort):\(options.containerPort)",
        ]
        if let network = options.network, !network.isEmpty {
            args += ["--network", network]
        }
        for (key, value) in options.labels.sorted(by: { $0.key < $1.key }) {
            args += ["--label", "\(key)=\(value)"]
        }
        for (key, value) in options.environment.sorted(by: { $0.key < $1.key }) {
            args += ["--env", "\(key)=\(value)"]
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

    public func stop(name: String) throws {
        _ = try run(["stop", name])
    }

    public func rename(from: String, to: String) throws {
        _ = try run(["rename", from, to])
    }

    public func ensureNetwork(name: String) throws {
        do {
            _ = try run(["network", "create", name])
            return
        } catch let automaticCreationError {
            do {
                _ = try run(["network", "inspect", name])
                return
            } catch {
                guard automaticCreationError as? BotComputerDockerError == .networkAddressPoolExhausted else {
                    throw automaticCreationError
                }
            }
        }

        var lastError: Error = BotComputerDockerError.networkAddressPoolExhausted
        for subnet in Self.isolatedNetworkSubnets(name: name) {
            do {
                _ = try run([
                    "network", "create",
                    "--driver", "bridge",
                    "--opt", "com.docker.network.bridge.enable_icc=false",
                    "--subnet", subnet,
                    "--label", "io.remotecode.bot.network=true",
                    name,
                ])
                return
            } catch let candidateError {
                do {
                    _ = try run(["network", "inspect", name])
                    return
                } catch {
                    guard candidateError as? BotComputerDockerError == .networkSubnetUnavailable else {
                        throw candidateError
                    }
                    lastError = candidateError
                }
            }
        }
        throw lastError
    }

    static func isolatedNetworkSubnets(name: String, limit: Int = 64) -> [String] {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        let networkCount = 1 << 18
        let start = Int(hash) % networkCount
        let base: UInt32 = 0x0AF0_0000
        return (0..<max(1, limit)).map { offset in
            let index = (start + offset) % networkCount
            let address = base + UInt32(index * 4)
            return "\(address >> 24).\((address >> 16) & 0xff).\((address >> 8) & 0xff).\(address & 0xff)/30"
        }
    }

    public func inspect(name: String) throws -> BotComputerContainerInspect {
        let data = try run([
            "inspect",
            "-f",
            "{{.State.Running}} {{.Image}} {{with (index .NetworkSettings.Ports \"6080/tcp\")}}{{(index . 0).HostPort}}{{else}}0{{end}} {{range $k, $_ := .NetworkSettings.Networks}}{{$k}},{{end}}",
            name,
        ])
        let parts = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
        let running = parts.first.map { $0.caseInsensitiveCompare("true") == .orderedSame } ?? false
        let image = parts.dropFirst().first.map(String.init) ?? ""
        let port = Int(parts.dropFirst(2).first.map(String.init) ?? "") ?? 0
        let networks = parts.dropFirst(3).first.map(String.init)?
            .split(separator: ",")
            .map(String.init) ?? []
        return BotComputerContainerInspect(
            running: running,
            imageID: image,
            hostPort: port,
            networkNames: networks
        )
    }

    public func containerExists(name: String) throws -> Bool {
        let data = try run(["ps", "-aq", "--filter", "name=^/\(name)$"])
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
    }

    public func exec(name: String, command: [String], user: String? = nil, detach: Bool = false) throws -> Data {
        var args = ["exec"]
        if detach { args.append("-d") }
        if let user, !user.isEmpty {
            args += ["-u", user]
        }
        args.append(name)
        args += command
        return try run(args)
    }

    public func remove(name: String) throws {
        _ = try run(["rm", "-f", name])
    }

    public func removeNetwork(name: String) throws {
        _ = try run(["network", "rm", name])
    }

    public func removeMatching(namePrefix: String) throws {
        let data = try run(["ps", "-aq", "--filter", "name=\(namePrefix)"])
        let names = (String(data: data, encoding: .utf8) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for name in names {
            try? remove(name: name)
        }
    }

    public static func defaultRun(_ args: [String]) throws -> Data {
        let executable = try BotComputerDockerResolver.shared.resolveHealthyExecutable()
        let timeout = timeoutForArguments(args)
        let result: (data: Data, errorData: Data, terminationStatus: Int32, timedOut: Bool)
        do {
            result = try runProcess(
                executableURL: URL(fileURLWithPath: executable),
                arguments: args,
                timeout: timeout,
                stdoutLimit: stdoutLimit(for: args),
                failOnStdoutLimit: args.first != "build"
            )
        } catch BotComputerDockerProcessError.stdoutLimitExceeded {
            throw args.first == "info"
                ? BotComputerDockerError.daemonUnavailable
                : BotComputerDockerError.outputTooLarge
        }
        if result.timedOut {
            throw timeoutError(for: args)
        }
        if result.terminationStatus != 0 {
            BotComputerDockerResolver.shared.invalidateIfMatches(executable)
            throw failureError(for: args, stderr: result.errorData)
        }
        return result.data
    }

    static func failureError(for args: [String], stderr: Data) -> BotComputerDockerError {
        if args.starts(with: ["network", "create"]) {
            let detail = String(decoding: stderr, as: UTF8.self).lowercased()
            if detail.contains("all predefined address pools have been fully subnetted") {
                return .networkAddressPoolExhausted
            }
            if detail.contains("pool overlaps with other one on this address space") {
                return .networkSubnetUnavailable
            }
        }
        return args.first == "info" ? .daemonUnavailable : .provisioningFailed
    }

    static func timeoutForArguments(_ args: [String]) -> TimeInterval {
        switch args.first {
        case "info": return 5
        case "build": return 600
        default: return 15
        }
    }

    static func timeoutError(for args: [String]) -> BotComputerDockerError {
        args.first == "info" ? .probeTimedOut : .provisioningFailed
    }

    static func stdoutLimit(for args: [String]) -> Int {
        args.first == "build" ? buildStdoutRetentionLimit : stdoutRetentionLimit
    }

    static func runProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = 15,
        stdoutLimit: Int = stdoutRetentionLimit,
        failOnStdoutLimit: Bool = true
    ) throws -> (data: Data, errorData: Data, terminationStatus: Int32, timedOut: Bool) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let exitDone = DispatchGroup()
        exitDone.enter()
        process.terminationHandler = { _ in exitDone.leave() }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            exitDone.leave()
            throw error
        }
        let pid = process.processIdentifier
        let collected = LockedBoundedExactDataBox(limit: stdoutLimit)
        let errorCollected = LockedDataSuffixBox(limit: stderrRetentionLimit)
        let drainDone = DispatchGroup()
        drainDone.enter()
        DispatchQueue.global(qos: .utility).async {
            var terminatedForOverflow = false
            while true {
                let chunk = stdout.fileHandleForReading.readData(ofLength: 4_096)
                guard !chunk.isEmpty else { break }
                if !collected.append(chunk), failOnStdoutLimit, !terminatedForOverflow {
                    terminatedForOverflow = true
                    terminateOwnedTree(pid: pid)
                }
            }
            drainDone.leave()
        }
        drainDone.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = stderr.fileHandleForReading.readData(ofLength: 4_096)
                guard !chunk.isEmpty else { break }
                errorCollected.append(chunk)
            }
            drainDone.leave()
        }
        let boundedTimeout = max(0, timeout.isFinite ? timeout : 15)
        let timedOut = exitDone.wait(timeout: .now() + boundedTimeout) == .timedOut
        if timedOut {
            terminateOwnedTree(pid: pid)
            _ = exitDone.wait(timeout: .now() + 1)
        }
        if !process.isRunning {
            process.waitUntilExit()
        }
        _ = drainDone.wait(timeout: .now() + 1)
        if failOnStdoutLimit && collected.exceededLimit {
            throw BotComputerDockerProcessError.stdoutLimitExceeded
        }
        return (
            collected.data,
            errorCollected.data,
            process.isRunning ? -1 : process.terminationStatus,
            timedOut
        )
    }

    static func terminateOwnedTree(pid: pid_t) {
        guard pid > 1 else { return }
        let needed = rc_proc_listchildpids(pid, nil, 0)
        if needed > 0 {
            var children = [pid_t](repeating: 0, count: Int(needed))
            let written = children.withUnsafeMutableBufferPointer { ptr in
                rc_proc_listchildpids(
                    pid,
                    ptr.baseAddress,
                    needed * Int32(MemoryLayout<pid_t>.size)
                )
            }
            if written > 0 {
                for index in 0..<Int(written) {
                    terminateOwnedTree(pid: children[index])
                }
            }
        }
        kill(pid, SIGKILL)
    }
}

enum BotComputerDockerProcessError: Error, Equatable {
    case stdoutLimitExceeded
}

@_silgen_name("proc_listchildpids")
private func rc_proc_listchildpids(_ ppid: pid_t, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

public final class BotComputerDockerResolver: @unchecked Sendable {
    public static let shared = BotComputerDockerResolver()

    private let lock = NSLock()
    private var cachedExecutable: String?
    private let candidates: [String]
    private let probeTimeout: TimeInterval
    private let probe: (@Sendable (String, TimeInterval) throws -> BotComputerDockerProbeOutcome)?

    public init(
        candidates: [String] = BotComputerDockerResolver.defaultCandidates(),
        probeTimeout: TimeInterval = 5,
        probe: (@Sendable (String, TimeInterval) throws -> BotComputerDockerProbeOutcome)? = nil
    ) {
        self.candidates = candidates
        self.probeTimeout = max(0.05, probeTimeout)
        self.probe = probe
    }

    public static func defaultCandidates(
        pathEnvironment: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        homeDirectory: String = NSHomeDirectory()
    ) -> [String] {
        var ordered: [String] = []
        func append(_ path: String) {
            guard !path.isEmpty, !ordered.contains(path) else { return }
            ordered.append(path)
        }
        for directory in pathEnvironment.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent("docker").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                append(candidate)
                break
            }
        }
        append("/usr/local/bin/docker")
        append("/opt/homebrew/bin/docker")
        append("/Applications/Docker.app/Contents/Resources/bin/docker")
        append("/Applications/OrbStack.app/Contents/MacOS/xbin/docker")
        append((homeDirectory as NSString).appendingPathComponent(".orbstack/bin/docker"))
        return ordered
    }

    public func resolveHealthyExecutable() throws -> String {
        lock.lock()
        if let cachedExecutable {
            lock.unlock()
            return cachedExecutable
        }
        let snapshot = candidates
        let timeout = probeTimeout
        let customProbe = probe
        lock.unlock()

        var sawExecutable = false
        var sawTimeout = false
        var sawDaemonFailure = false
        for (index, candidate) in snapshot.enumerated() {
            let outcome: BotComputerDockerProbeOutcome
            do {
                if let customProbe {
                    outcome = try customProbe(candidate, timeout)
                } else {
                    outcome = probeCandidate(candidate, timeout: timeout)
                }
            } catch {
                outcome = .failed
            }
            botComputerDockerLog.info(
                "docker.candidate index=\(index, privacy: .public) outcome=\(outcome.diagnosticName, privacy: .public)"
            )
            switch outcome {
            case .missing:
                continue
            case .healthy:
                lock.lock()
                cachedExecutable = candidate
                lock.unlock()
                return candidate
            case .failed:
                sawExecutable = true
                sawDaemonFailure = true
            case .timedOut:
                sawExecutable = true
                sawTimeout = true
            }
        }
        if !sawExecutable { throw BotComputerDockerError.cliMissing }
        if sawTimeout { throw BotComputerDockerError.probeTimedOut }
        if sawDaemonFailure { throw BotComputerDockerError.daemonUnavailable }
        throw BotComputerDockerError.cliMissing
    }

    /// Non-CLI executors (the bot Playwright guest bridge) share the CLI's
    /// healthy-binary resolution instead of growing a second docker lookup.
    public static func resolveSharedHealthyExecutable() throws -> String {
        try shared.resolveHealthyExecutable()
    }

    public func invalidate() {
        lock.lock()
        cachedExecutable = nil
        lock.unlock()
    }

    func invalidateIfMatches(_ executable: String) {
        lock.lock()
        if cachedExecutable == executable {
            cachedExecutable = nil
        }
        lock.unlock()
    }

    private func probeCandidate(_ candidate: String, timeout: TimeInterval) -> BotComputerDockerProbeOutcome {
        guard FileManager.default.isExecutableFile(atPath: candidate) else { return .missing }
        do {
            let result = try BotComputerDockerCLI.runProcess(
                executableURL: URL(fileURLWithPath: candidate),
                arguments: ["info"],
                timeout: timeout
            )
            if result.timedOut { return .timedOut }
            return result.terminationStatus == 0 ? .healthy : .failed
        } catch {
            return .failed
        }
    }
}

public enum BotComputerDockerProbeOutcome: Equatable, Sendable {
    case missing
    case healthy
    case failed
    case timedOut

    fileprivate var diagnosticName: String {
        switch self {
        case .missing: return "missing"
        case .healthy: return "healthy"
        case .failed: return "failed"
        case .timedOut: return "timed_out"
        }
    }
}

private final class LockedBoundedExactDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var exceeded = false

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func append(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !exceeded, data.count <= limit - storage.count else {
            exceeded = true
            storage.removeAll(keepingCapacity: false)
            return false
        }
        storage.append(data)
        return true
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var exceededLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exceeded
    }
}

private final class LockedDataSuffixBox: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if data.count >= limit {
            storage = Data(data.suffix(limit))
            return
        }
        storage.append(data)
        if storage.count > limit {
            storage.removeFirst(storage.count - limit)
        }
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
