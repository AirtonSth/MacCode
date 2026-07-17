import Foundation
import Darwin

/// macOS account identity used to execute a provider process (`sudo -u`-style).
/// Distinct from provider-instance selection (CODEX_HOME / personal-vs-work CLI configs).
public struct AgentRunAsUser: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// OpenDirectory GeneratedUID (stable across UID renumbering when possible).
    public var generatedUID: String
    /// Account short name (e.g. `samuelfajreldines`).
    public var shortName: String
    /// Numeric POSIX uid snapshot for display and spawn; re-resolved at launch.
    public var uid: uid_t
    /// Primary gid snapshot.
    public var gid: gid_t
    /// Home directory path for the account.
    public var homePath: String
    /// Optional full name for UI (e.g. "Samuel Fajreldines").
    public var fullName: String?

    public var id: String { generatedUID.isEmpty ? "uid:\(uid)" : generatedUID }

    public init(
        generatedUID: String,
        shortName: String,
        uid: uid_t,
        gid: gid_t,
        homePath: String,
        fullName: String? = nil
    ) {
        self.generatedUID = generatedUID
        self.shortName = shortName
        self.uid = uid
        self.gid = gid
        self.homePath = homePath
        self.fullName = fullName
    }

    private enum CodingKeys: String, CodingKey {
        case generatedUID, generated_uid
        case shortName, short_name
        case uid, gid
        case homePath, home_path
        case fullName, full_name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedUID = (try? c.decode(String.self, forKey: .generatedUID))
            ?? (try? c.decode(String.self, forKey: .generated_uid))
            ?? ""
        shortName = (try? c.decode(String.self, forKey: .shortName))
            ?? (try? c.decode(String.self, forKey: .short_name))
            ?? ""
        uid = (try? c.decode(UInt32.self, forKey: .uid)) ?? 0
        gid = (try? c.decode(UInt32.self, forKey: .gid)) ?? 0
        homePath = (try? c.decode(String.self, forKey: .homePath))
            ?? (try? c.decode(String.self, forKey: .home_path))
            ?? ""
        fullName = (try? c.decode(String.self, forKey: .fullName))
            ?? (try? c.decode(String.self, forKey: .full_name))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(generatedUID, forKey: .generatedUID)
        try c.encode(generatedUID, forKey: .generated_uid)
        try c.encode(shortName, forKey: .shortName)
        try c.encode(shortName, forKey: .short_name)
        try c.encode(UInt32(uid), forKey: .uid)
        try c.encode(UInt32(gid), forKey: .gid)
        try c.encode(homePath, forKey: .homePath)
        try c.encode(homePath, forKey: .home_path)
        try c.encodeIfPresent(fullName, forKey: .fullName)
        try c.encodeIfPresent(fullName, forKey: .full_name)
    }

    public var displayName: String {
        let full = fullName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !full.isEmpty { return full }
        return shortName
    }

    public var isCurrentAccount: Bool {
        uid == getuid()
    }

    public static func current() -> AgentRunAsUser {
        let uid = getuid()
        let gid = getgid()
        let short = NSUserName()
        let full = NSFullUserName()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return AgentRunAsUser(
            generatedUID: "current-\(uid)",
            shortName: short,
            uid: uid,
            gid: gid,
            homePath: home,
            fullName: full.isEmpty ? nil : full
        )
    }
}

/// Pure eligibility rules for which local accounts may appear in the run-as selector.
public enum AgentRunAsUserEligibility {
    /// Interactive human accounts only. Rejects root, system daemons, and nologin shells.
    public static func isEligible(
        shortName: String,
        uid: uid_t,
        shell: String?,
        homePath: String?,
        isHidden: Bool
    ) -> Bool {
        if isHidden { return false }
        if uid < 501 { return false }
        if uid == 0 { return false }
        let name = shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.hasPrefix("_") { return false }
        if name == "root" || name == "nobody" { return false }
        let shellPath = (shell ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if shellPath.isEmpty { return false }
        let bannedShells = ["/usr/bin/false", "/bin/false", "/usr/sbin/nologin", "/sbin/nologin"]
        if bannedShells.contains(shellPath) { return false }
        let home = (homePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if home.isEmpty { return false }
        // Prefer standard user homes for MVP.
        if !home.hasPrefix("/Users/") { return false }
        return true
    }
}
