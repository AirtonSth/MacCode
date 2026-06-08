import AgentRuntime
import DistillCore
import Darwin
import Foundation
import Persistence

@main
struct RemoteCodeDistillServiceMain {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.contains("--help") {
                print(helpText)
                return
            }

            let configuration = try DistillServiceConfiguration.parse(arguments: arguments)
            let scheduler = DistillScheduler(
                runtime: try await runtime(for: configuration),
                maxConcurrentRequests: configuration.maxConcurrentRequests,
                maxQueueDepth: configuration.maxQueueDepth
            )
            let savingsRecorder = try DistillSavingsSidecarRecorder(appSupportDirectory: configuration.appSupportDirectory)
            let eventWriter = DistillSidecarEventWriter()
            let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler) { request, response in
                guard let record = DistillSavingsCalculator.record(for: request, response: response) else {
                    return
                }
                do {
                    try savingsRecorder.record(record)
                    eventWriter.writeSavingsRecorded(record)
                } catch {
                    FileHandle.standardError.write(Data("RemoteCodeDistillService savings record failed: \(error)\n".utf8))
                }
            }
            let ready = try await server.start()
            let encoder = JSONEncoder()
            let payload = try encoder.encode(ready)
            FileHandle.standardOutput.write(payload)
            FileHandle.standardOutput.write(Data("\n".utf8))

            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
            server.stop()
        } catch {
            FileHandle.standardError.write(Data("RemoteCodeDistillService failed: \(error)\n".utf8))
            Darwin.exit(2)
        }
    }

    private static func runtime(for configuration: DistillServiceConfiguration) async throws -> any DistillRuntime {
        if ProcessInfo.processInfo.environment["REMOTE_CODE_DISTILL_ALLOW_TEST_RUNTIME"] == "1" {
            return LocalDistillRuntime()
        }

        let appSupport = URL(fileURLWithPath: configuration.appSupportDirectory, isDirectory: true)
        let installer = TokenSaverModelInstaller(appSupportDirectory: appSupport)
        let validation = installer.validateInstalledModel()
        guard validation.state == .installed, let manifest = installer.loadManifest() else {
            throw DistillServiceError.modelValidationFailed(validation.reason)
        }
        return try await MLXDistillRuntime(modelDirectory: installer.modelStorageDirectory(revision: manifest.revision))
    }

    private static let helpText = """
    RemoteCodeDistillService

    Required:
      --auth-token <token>
      --app-support-dir <path>

    Optional:
      --host 127.0.0.1
      --port 0
      --runtime mlx
      --model-id samuelfaj/distill-1.7B-4bit-MLX
      --model-url https://huggingface.co/samuelfaj/distill-1.7B-4bit-MLX
      --max-concurrent-requests 8
      --max-queue-depth 64
      --idle-timeout-ms 300000
    """
}

private final class DistillSavingsSidecarRecorder: @unchecked Sendable {
    private let repo: TokenSaverSavingsRepository

    init(appSupportDirectory: String) throws {
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupportDirectory).run()
        self.repo = TokenSaverSavingsRepository(db: db)
    }

    func record(_ record: DistillSavingsRecord) throws {
        _ = try repo.record(
            provider: record.provider,
            mode: record.mode,
            inputTokens: record.inputTokens,
            outputTokens: record.outputTokens,
            savedTokens: record.savedTokens
        )
    }
}

private final class DistillSidecarEventWriter: @unchecked Sendable {
    private struct SavingsRecordedEvent: Codable {
        let event = "savings_recorded"
        let provider: String
        let mode: String
        let inputTokens: Int
        let outputTokens: Int
        let savedTokens: Int

        enum CodingKeys: String, CodingKey {
            case event
            case provider
            case mode
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case savedTokens = "saved_tokens"
        }
    }

    private let queue = DispatchQueue(label: "io.remotecode.distill.sidecar.events")
    private let encoder = JSONEncoder()

    func writeSavingsRecorded(_ record: DistillSavingsRecord) {
        queue.async {
            let event = SavingsRecordedEvent(
                provider: record.provider,
                mode: record.mode,
                inputTokens: record.inputTokens,
                outputTokens: record.outputTokens,
                savedTokens: record.savedTokens
            )
            guard let data = try? self.encoder.encode(event) else { return }
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}
