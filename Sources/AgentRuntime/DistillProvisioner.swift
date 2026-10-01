import Foundation
import CoreModel

/// Install plan for the official distill harness. Built as argv so the app never
/// builds a shell string by interpolation.
public struct DistillInstallPlan: Equatable, Sendable {
    public let shellPath: String
    public let shellArguments: [String]
    /// The exact official one-liner, for logging and for operators to copy.
    public let commandLine: String

    public init(shellPath: String, shellArguments: [String], commandLine: String) {
        self.shellPath = shellPath
        self.shellArguments = shellArguments
        self.commandLine = commandLine
    }

    /// Full argv for `Process`/`posix_spawn`.
    public var argv: [String] { [shellPath] + shellArguments }
}

public enum DistillProvisioningDecision: Equatable, Sendable {
    case alreadyInstalled(path: String)
    case install
}

public enum DistillProvisioningError: Error, Equatable, CustomStringConvertible {
    case installFailed(status: Int32)
    case binaryNotFoundAfterInstall

    public var description: String {
        switch self {
        case .installFailed(let status):
            return "distill installer exited with status \(status)"
        case .binaryNotFoundAfterInstall:
            return "distill installer finished but no \(DistillProvisioner.binaryName) binary was found"
        }
    }
}

/// Resolve-or-install provisioning for the `distill` harness.
///
/// remote-code ships no harness of its own: when no `distill` binary is present it
/// runs the official installer from `github.com/samuelfaj/distill`, then resolves
/// the installed binary. When distill is already installed nothing is run.
public enum DistillProvisioner {
    public static let binaryName = "distill"
    /// Official installer, exactly as documented in the distill README.
    public static let installScriptURL =
        "https://raw.githubusercontent.com/samuelfaj/distill/main/install.sh"

    /// The installer is a POSIX shell pipeline, so it runs through `/bin/sh -c`.
    public static let installerShellPath = "/bin/sh"

    public static func installPlan() -> DistillInstallPlan {
        let commandLine = "curl -fsSL \(installScriptURL) | sh"
        return DistillInstallPlan(
            shellPath: installerShellPath,
            shellArguments: ["-c", commandLine],
            commandLine: commandLine
        )
    }

    /// Distill home: instance home, else app `DISTILL_HOME`, else `<userHome>/.distill`.
    /// `~/.grok` is never adopted.
    public static func homeURL(
        instanceHomePath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> URL {
        for candidate in [instanceHomePath, environment["DISTILL_HOME"]] {
            if let path = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return URL(fileURLWithPath: userHome, isDirectory: true)
            .appendingPathComponent(".distill", isDirectory: true)
    }

    /// Pure decision: a non-empty resolved path means the installer must not run.
    public static func decide(resolvedBinary: String?) -> DistillProvisioningDecision {
        guard let resolvedBinary,
              !resolvedBinary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .install
        }
        return .alreadyInstalled(path: resolvedBinary)
    }

    /// Resolve the harness binary. A user-configured override wins; otherwise the
    /// shipped locator searches the official install directory, PATH and the
    /// usual toolchain directories.
    public static func resolveInstalledBinary(
        override: String? = nil,
        environmentPath: String? = ProcessInfo.processInfo.environment["PATH"],
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String? {
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let hit = ProcessLocator.resolveDistillAgent(
                override,
                environmentPath: environmentPath,
                homeDirectory: homeDirectory,
                managedHomes: [homeDirectory]
            ) {
                return hit
            }
        }
        return ProcessLocator.resolveDistillAgent(
            binaryName,
            environmentPath: environmentPath,
            homeDirectory: homeDirectory,
            managedHomes: [homeDirectory]
        )
    }

    public struct Outcome: Equatable, Sendable {
        public let binaryPath: String
        public let didInstall: Bool
        public let plan: DistillInstallPlan?

        public init(binaryPath: String, didInstall: Bool, plan: DistillInstallPlan?) {
            self.binaryPath = binaryPath
            self.didInstall = didInstall
            self.plan = plan
        }
    }

    /// Real provisioning entry point. Returns the binary to launch, installing it
    /// first only when it is absent.
    ///
    /// `runInstaller` is injected so the missing/installed decision and the exact
    /// installer argv are testable without touching the network.
    @discardableResult
    public static func ensureInstalled(
        override: String? = nil,
        environmentPath: String? = ProcessInfo.processInfo.environment["PATH"],
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        runInstaller: (DistillInstallPlan) throws -> Int32 = DistillProvisioner.runInstallerProcess
    ) throws -> Outcome {
        let existing = resolveInstalledBinary(
            override: override,
            environmentPath: environmentPath,
            homeDirectory: homeDirectory
        )
        if case .alreadyInstalled(let path) = decide(resolvedBinary: existing) {
            return Outcome(binaryPath: path, didInstall: false, plan: nil)
        }

        let plan = installPlan()
        let status = try runInstaller(plan)
        guard status == 0 else { throw DistillProvisioningError.installFailed(status: status) }

        guard let installed = resolveInstalledBinary(
            override: override,
            environmentPath: environmentPath,
            homeDirectory: homeDirectory
        ) else {
            throw DistillProvisioningError.binaryNotFoundAfterInstall
        }
        return Outcome(binaryPath: installed, didInstall: true, plan: plan)
    }

    /// Default runner: the real installer process.
    public static let runInstallerProcess: (DistillInstallPlan) throws -> Int32 = { plan in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.shellPath)
        process.arguments = plan.shellArguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
