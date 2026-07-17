import Foundation
import CoreModel
import Darwin

/// Enumerates interactive local macOS users eligible for run-as execution.
public enum MacOSLocalUserCatalog {
    /// Snapshot of accounts the composer may offer. Pure POSIX enumeration keeps
    /// the path free of provider credentials and network directory side effects.
    public static func listEligibleUsers(
        includeCurrentIfMissing: Bool = true
    ) -> [AgentRunAsUser] {
        var users: [AgentRunAsUser] = []
        var seenUIDs = Set<uid_t>()

        setpwent()
        defer { endpwent() }
        while let pw = getpwent() {
            let shortName = String(cString: pw.pointee.pw_name)
            let uid = pw.pointee.pw_uid
            let gid = pw.pointee.pw_gid
            let home = String(cString: pw.pointee.pw_dir)
            let shell = String(cString: pw.pointee.pw_shell)
            let fullName: String? = {
                let gecos = String(cString: pw.pointee.pw_gecos)
                let first = gecos.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? gecos
                let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }()
            let hidden = shortName.hasPrefix("_")
            guard AgentRunAsUserEligibility.isEligible(
                shortName: shortName,
                uid: uid,
                shell: shell,
                homePath: home,
                isHidden: hidden
            ) else { continue }
            guard seenUIDs.insert(uid).inserted else { continue }
            users.append(
                AgentRunAsUser(
                    generatedUID: generatedUID(for: shortName) ?? "uid-\(uid)",
                    shortName: shortName,
                    uid: uid,
                    gid: gid,
                    homePath: home,
                    fullName: fullName
                )
            )
        }

        users.sort {
            if $0.isCurrentAccount != $1.isCurrentAccount {
                return $0.isCurrentAccount && !$1.isCurrentAccount
            }
            return $0.shortName.localizedCaseInsensitiveCompare($1.shortName) == .orderedAscending
        }

        if includeCurrentIfMissing,
           !users.contains(where: { $0.uid == getuid() }) {
            users.insert(AgentRunAsUser.current(), at: 0)
        }
        return users
    }

    public static func resolve(shortName: String) -> AgentRunAsUser? {
        let name = shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard let pw = getpwnam(name) else { return nil }
        let home = String(cString: pw.pointee.pw_dir)
        let shell = String(cString: pw.pointee.pw_shell)
        guard AgentRunAsUserEligibility.isEligible(
            shortName: name,
            uid: pw.pointee.pw_uid,
            shell: shell,
            homePath: home,
            isHidden: name.hasPrefix("_")
        ) else { return nil }
        let fullName: String? = {
            let gecos = String(cString: pw.pointee.pw_gecos)
            let first = gecos.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? gecos
            let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        return AgentRunAsUser(
            generatedUID: generatedUID(for: name) ?? "uid-\(pw.pointee.pw_uid)",
            shortName: name,
            uid: pw.pointee.pw_uid,
            gid: pw.pointee.pw_gid,
            homePath: home,
            fullName: fullName
        )
    }

    public static func resolve(generatedUID: String, shortNameSnapshot: String) -> AgentRunAsUser? {
        if let byName = resolve(shortName: shortNameSnapshot) {
            // Prefer re-resolved account; GeneratedUID mismatch means the account
            // was deleted/recreated under the same short name — still use live record.
            return byName
        }
        // Fall back: scan for matching GeneratedUID when short name changed.
        return listEligibleUsers(includeCurrentIfMissing: false)
            .first { $0.generatedUID == generatedUID }
    }

    private static func generatedUID(for shortName: String) -> String? {
        // Best-effort: dscl is not linked; encode a stable local id from name+uid.
        // OpenDirectory GeneratedUID can be added later without changing the wire field.
        guard let pw = getpwnam(shortName) else { return nil }
        return "local-\(shortName)-\(pw.pointee.pw_uid)"
    }
}
