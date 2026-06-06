import Foundation

public struct SSHHostProfile: Codable, Sendable, Hashable {
    public var id: SSHHostID
    public var label: String
    public var destination: String
    public var port: Int?
    public var identityFile: String?
    public var password: String?
    public var hasSavedPassword: Bool
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
        hasSavedPassword: Bool = false,
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
        self.hasSavedPassword = hasSavedPassword || (password?.isEmpty == false)
        self.options = options
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case destination
        case port
        case identityFile
        case password
        case hasSavedPassword
        case options
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(SSHHostID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        destination = try c.decode(String.self, forKey: .destination)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile)
        password = try c.decodeIfPresent(String.self, forKey: .password)
        hasSavedPassword = (try c.decodeIfPresent(Bool.self, forKey: .hasSavedPassword)) ?? true
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(destination, forKey: .destination)
        try c.encodeIfPresent(port, forKey: .port)
        try c.encodeIfPresent(identityFile, forKey: .identityFile)
        try c.encodeIfPresent(password, forKey: .password)
        try c.encode(hasSavedPassword, forKey: .hasSavedPassword)
        try c.encode(options, forKey: .options)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
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
