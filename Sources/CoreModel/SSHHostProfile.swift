import Foundation

public struct SSHHostProfile: Codable, Sendable, Hashable {
    public var id: SSHHostID
    public var label: String
    public var destination: String
    public var port: Int?
    public var identityFile: String?
    public var password: String?
    public var options: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: SSHHostID = SSHHostID(),
        label: String,
        destination: String,
        port: Int? = nil,
        identityFile: String? = nil,
        password: String? = nil,
        options: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
        self.password = password
        self.options = options
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum SSHCommandBuilder {
    public static func sshArguments(for profile: SSHHostProfile, batchMode: Bool = false) -> [String] {
        var args: [String] = [
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        if batchMode { args += ["-o", "BatchMode=yes"] }
        if let port = profile.port { args += ["-p", String(port)] }
        if let identity = profile.identityFile, !identity.isEmpty { args += ["-i", identity] }
        for option in profile.options where !option.isEmpty {
            args += ["-o", option]
        }
        args.append(profile.destination)
        return args
    }

    public static func scpUploadArguments(profile: SSHHostProfile, localPath: String, remotePath: String) -> [String] {
        scpBaseArguments(profile: profile) + [localPath, "\(profile.destination):\(remotePath)"]
    }

    public static func scpDownloadArguments(profile: SSHHostProfile, remotePath: String, localPath: String) -> [String] {
        scpBaseArguments(profile: profile) + ["\(profile.destination):\(remotePath)", localPath]
    }

    private static func scpBaseArguments(profile: SSHHostProfile) -> [String] {
        var args = [
            "-o", "ConnectTimeout=6",
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        if let port = profile.port { args += ["-P", String(port)] }
        if let identity = profile.identityFile, !identity.isEmpty { args += ["-i", identity] }
        for option in profile.options where !option.isEmpty {
            args += ["-o", option]
        }
        return args
    }
}
