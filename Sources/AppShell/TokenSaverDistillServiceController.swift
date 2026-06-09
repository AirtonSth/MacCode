import AgentRuntime
import DistillCore
import Foundation
import Persistence

public enum TokenSaverDistillLaunchDecision: Sendable, Equatable {
    case start
    case skip(reason: String)
    case requireModel(reason: String?)
}

public struct TokenSaverDistillLaunchInput: Sendable, Equatable {
    public let hasPrivateAccount: Bool
    public let isSubscribed: Bool
    public let tokenSaverEnabled: Bool
    public let modelValidation: TokenSaverModelValidation

    public init(
        hasPrivateAccount: Bool,
        isSubscribed: Bool,
        tokenSaverEnabled: Bool,
        modelValidation: TokenSaverModelValidation
    ) {
        self.hasPrivateAccount = hasPrivateAccount
        self.isSubscribed = isSubscribed
        self.tokenSaverEnabled = tokenSaverEnabled
        self.modelValidation = modelValidation
    }
}

public enum TokenSaverDistillLaunchPlanner {
    public static func decide(_ input: TokenSaverDistillLaunchInput) -> TokenSaverDistillLaunchDecision {
        guard input.hasPrivateAccount else {
            return .skip(reason: "private account not signed in")
        }
        guard input.isSubscribed else {
            return .skip(reason: "subscription required")
        }
        guard input.tokenSaverEnabled else {
            return .skip(reason: "token saver disabled")
        }
        guard input.modelValidation.state == .installed else {
            return .requireModel(reason: input.modelValidation.reason)
        }
        return .start
    }
}

public enum TokenSaverDistillServiceStatus: Sendable, Equatable {
    case notStarted
    case blocked(String)
    case starting
    case running(DistillServiceReadyEvent)
    case failed(String)
}

private struct TokenSaverDistillCLIState: Codable {
    let baseURL: String
    let authToken: String
    let pid: Int32
    let runtime: String
    let modelID: String

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case authToken = "auth_token"
        case pid
        case runtime
        case modelID = "model_id"
    }
}

private struct TokenSaverDistillProcessEvent: Codable {
    let event: String
    let provider: String?
    let mode: String?
    let savedTokens: Int?

    enum CodingKeys: String, CodingKey {
        case event
        case provider
        case mode
        case savedTokens = "saved_tokens"
    }
}

@MainActor
public final class TokenSaverDistillServiceController {
    public typealias ExecutableURLResolver = @MainActor () -> URL?

    public private(set) var status: TokenSaverDistillServiceStatus = .notStarted
    public private(set) var bearerToken: String?

    private let appSupportDirectory: URL
    private let executableURLResolver: ExecutableURLResolver
    private var process: Process?
    private var readyOutputHandle: FileHandle?
    private var readyOutputBuffer = Data()

    public init(
        appSupportDirectory: URL,
        executableURLResolver: @escaping ExecutableURLResolver = TokenSaverDistillServiceController.defaultExecutableURL
    ) {
        self.appSupportDirectory = appSupportDirectory
        self.executableURLResolver = executableURLResolver
    }

    deinit {
        process?.terminate()
    }

    public func startIfEligible(
        session: PrivateAccountSession?,
        settings: AppSettings,
        modelValidation: TokenSaverModelValidation
    ) {
        let decision = TokenSaverDistillLaunchPlanner.decide(TokenSaverDistillLaunchInput(
            hasPrivateAccount: session != nil,
            isSubscribed: session?.user.subscribed == true,
            tokenSaverEnabled: settings.tokenSaverEnabled,
            modelValidation: modelValidation
        ))

        switch decision {
        case .start:
            start()
        case .skip(let reason):
            stop()
            status = .blocked(reason)
        case .requireModel(let reason):
            stop()
            status = .blocked(reason ?? "model download required")
        }
    }

    public func stop() {
        readyOutputHandle?.readabilityHandler = nil
        readyOutputHandle = nil
        readyOutputBuffer.removeAll(keepingCapacity: false)
        removeCLIState()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        bearerToken = nil
        if case .running = status {
            status = .notStarted
        }
    }

    private func start() {
        if let process, process.isRunning {
            return
        }
        guard let executableURL = executableURLResolver() else {
            status = .failed("RemoteCodeDistillService executable missing")
            return
        }

        let token = UUID().uuidString
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.standardOutput = stdout
        process.standardError = stderr
        process.arguments = [
            "--auth-token", token,
            "--app-support-dir", appSupportDirectory.path,
            "--host", "127.0.0.1",
            "--port", "0",
            "--runtime", DistillApprovedModel.runtime,
            "--model-id", DistillApprovedModel.id,
            "--model-url", DistillApprovedModel.url,
            "--max-concurrent-requests", "8",
            "--max-queue-depth", "64",
            "--idle-timeout-ms", "300000"
        ]

        do {
            try process.run()
            self.process = process
            self.bearerToken = token
            self.status = .starting
            // Drain stderr continuously so the pipe buffer never fills.
            // Without this handler the sidecar blocks on any stderr write once
            // the 64 KB kernel pipe buffer is full, producing a deadlock.
            stderr.fileHandleForReading.readabilityHandler = { handle in
                _ = handle.availableData   // discard; keeps the buffer empty
            }
            readReadyEvent(from: stdout.fileHandleForReading, process: process)
        } catch {
            self.status = .failed("RemoteCodeDistillService launch failed")
            self.bearerToken = nil
            self.process = nil
        }
    }

    private func readReadyEvent(from handle: FileHandle, process: Process) {
        readyOutputHandle?.readabilityHandler = nil
        readyOutputHandle = handle
        readyOutputBuffer.removeAll(keepingCapacity: false)
        handle.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                Task { @MainActor [weak self, weak process] in
                    guard let self, let process, self.process === process else { return }
                    handle.readabilityHandler = nil
                    self.readyOutputHandle = nil
                    if process.isRunning, case .starting = self.status {
                        self.status = .failed("RemoteCodeDistillService ready event missing")
                    }
                }
                return
            }

            Task { @MainActor [weak self, weak process] in
                guard let self, let process, self.process === process else { return }
                self.readyOutputBuffer.append(data)
                while let newline = self.readyOutputBuffer.firstIndex(of: 10) {
                    let lineData = Data(self.readyOutputBuffer[..<newline])
                    self.readyOutputBuffer.removeSubrange(...newline)
                    self.handleOutputLine(lineData)
                }
            }
        }
    }

    private func handleOutputLine(_ lineData: Data) {
        if case .starting = status {
            let ready = try? JSONDecoder().decode(DistillServiceReadyEvent.self, from: lineData)
            if let ready {
                writeCLIState(ready: ready)
                status = .running(ready)
            } else {
                status = .failed("RemoteCodeDistillService ready event invalid")
            }
            return
        }

        guard let event = try? JSONDecoder().decode(TokenSaverDistillProcessEvent.self, from: lineData),
              event.event == "savings_recorded" else {
            return
        }
        NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)
    }

    private var cliStateURL: URL {
        appSupportDirectory
            .appendingPathComponent("Distill", isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
    }

    private func writeCLIState(ready: DistillServiceReadyEvent) {
        guard let bearerToken else { return }
        let state = TokenSaverDistillCLIState(
            baseURL: ready.baseURL,
            authToken: bearerToken,
            pid: ready.pid,
            runtime: ready.runtime,
            modelID: ready.modelID
        )
        do {
            let url = cliStateURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("RemoteCode Token Saver distill CLI state write failed: \(error)")
        }
    }

    private func removeCLIState() {
        let url = cliStateURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            NSLog("RemoteCode Token Saver distill CLI state remove failed: \(error)")
        }
    }

    public static func defaultExecutableURL() -> URL? {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            Bundle.main.bundlePath.hasSuffix(".xctest") ||
            Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) ||
            NSClassFromString("XCTest.XCTestCase") != nil ||
            NSClassFromString("XCTestCase") != nil {
            return nil
        }
        let fileManager = FileManager.default
        let bundled = Bundle.main.url(forAuxiliaryExecutable: "RemoteCodeDistillService")
        if let bundled, fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        let currentExecutable = URL(fileURLWithPath: CommandLine.arguments[0])
        let sibling = currentExecutable
            .deletingLastPathComponent()
            .appendingPathComponent("RemoteCodeDistillService")
        if fileManager.isExecutableFile(atPath: sibling.path) {
            return sibling
        }

        let debugBuild = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/RemoteCodeDistillService")
        if fileManager.isExecutableFile(atPath: debugBuild.path) {
            return debugBuild
        }
        return nil
    }
}
