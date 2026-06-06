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

@MainActor
public final class TokenSaverDistillServiceController {
    public typealias ExecutableURLResolver = @MainActor () -> URL?

    public private(set) var status: TokenSaverDistillServiceStatus = .notStarted
    public private(set) var bearerToken: String?

    private let appSupportDirectory: URL
    private let executableURLResolver: ExecutableURLResolver
    private var process: Process?

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
            readReadyEvent(from: stdout.fileHandleForReading, process: process)
        } catch {
            self.status = .failed("RemoteCodeDistillService launch failed")
            self.bearerToken = nil
            self.process = nil
        }
    }

    private func readReadyEvent(from handle: FileHandle, process: Process) {
        Task.detached(priority: .userInitiated) {
            let data = handle.readData(ofLength: 4096)
            guard !data.isEmpty else {
                await MainActor.run {
                    if process.isRunning {
                        self.status = .failed("RemoteCodeDistillService ready event missing")
                    }
                }
                return
            }
            let lineData: Data
            if let newline = data.firstIndex(of: 10) {
                lineData = data[..<newline]
            } else {
                lineData = data
            }
            let ready = try? JSONDecoder().decode(DistillServiceReadyEvent.self, from: lineData)
            await MainActor.run {
                guard self.process === process else { return }
                if let ready {
                    self.status = .running(ready)
                } else {
                    self.status = .failed("RemoteCodeDistillService ready event invalid")
                }
            }
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
