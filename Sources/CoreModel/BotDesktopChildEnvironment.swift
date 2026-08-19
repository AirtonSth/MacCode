import Foundation

/// Child-process environment for a published desktop kind.
/// Docker-with-GUI runs must not resolve host `docker` or live `macos-harness`.
public enum BotDesktopChildEnvironment {
    public static let dockerStubNames = ["docker", "docker-compose", "com.docker.cli"]
    public static let harnessName = "macos-harness"
    public static let harnessDisabledMessage =
        "macos-harness is disabled for Docker with GUI. Use bot_computer_observe then bot_computer_act."
    public static let dockerDisabledMessage =
        "docker is not available to this bot run."

    public static func apply(
        kind: BotDesktopKind,
        env: [String: String],
        stubDirectory: URL
    ) -> [String: String] {
        guard BotDesktopAdmission.forPublished(kind).allowsGuestComputer else {
            return env
        }
        var next = env
        for key in ["DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "DOCKER_API_VERSION"] {
            next.removeValue(forKey: key)
        }
        try? installStubs(at: stubDirectory)
        let stubPath = stubDirectory.path
        let current = next["PATH"] ?? ""
        let parts = current
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0 != stubPath && !$0.isEmpty }
        next["PATH"] = ([stubPath] + parts).joined(separator: ":")
        return next
    }

    public static func installStubs(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeExecutable(
            directory.appendingPathComponent(harnessName),
            script: "#!/bin/sh\necho \"\(harnessDisabledMessage)\" >&2\nexit 1\n"
        )
        let dockerScript = "#!/bin/sh\necho \"\(dockerDisabledMessage)\" >&2\nexit 127\n"
        for name in dockerStubNames {
            try writeExecutable(directory.appendingPathComponent(name), script: dockerScript)
        }
    }

    private static func writeExecutable(_ url: URL, script: String) throws {
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
    }
}
