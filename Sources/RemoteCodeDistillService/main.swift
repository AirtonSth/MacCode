import AgentRuntime
import DistillCore
import Darwin
import Foundation

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
            let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
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
