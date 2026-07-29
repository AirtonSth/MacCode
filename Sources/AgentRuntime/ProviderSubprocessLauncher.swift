import Foundation
import CoreModel

/// The only supported construction path for a provider agent subprocess.
///
/// Keeping environment construction and run-as-user rewriting here makes the
/// Token Saver receipt and provider identity part of the launch contract rather
/// than a convention repeated by each provider adapter.
public enum ProviderSubprocessLauncher {
    public static func makeProcess(
        provider: AgentProvider,
        executablePath: String,
        arguments: [String],
        currentDirectory: String,
        environment overrides: [String: String],
        runAsUser: AgentRunAsUser? = nil,
        askpassPath: String? = nil
    ) throws -> Process {
        let environment = CodexRunner.processEnvironment(
            overrides: overrides,
            purpose: .agentTurn(provider)
        )
        let plan = try RunAsUserProcessBootstrap.plan(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            runAsUser: runAsUser,
            askpassPath: askpassPath
        )
        let process = Process()
        RunAsUserProcessBootstrap.apply(plan, to: process)
        return process
    }
}
