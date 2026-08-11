import Foundation
import CryptoKit

/// Typed allowlist for capacity/diagnostics export (plan-optimize-swift S1 / T-003).
///
/// Never includes prompts, tool output, filesystem paths, env, tokens,
/// capabilities, reversible-content handles, or raw upstream errors.
/// Correlation IDs are salted session-local. Explicit export is 0600.

public enum DiagnosticsExportSection: String, Sendable, Codable, Equatable, CaseIterable {
    case capacityManifest
    case capacityMetrics
    case pressureState
    case managedRSSTrend
    case hangWatchdog
    case ownershipCoverage
    case transportQueueDepths
    case hardwareTier
    case unavailableManifest
}

public struct DiagnosticsExportField: Sendable, Equatable {
    public var section: DiagnosticsExportSection
    public var key: String
    public var value: String

    public init(section: DiagnosticsExportSection, key: String, value: String) {
        self.section = section
        self.key = key
        self.value = value
    }
}

public enum DiagnosticsExportAllowlist {
    /// Keys that must never appear in export payload or diagnostic logs under this contract.
    public static let forbiddenKeySubstrings: [String] = [
        "prompt",
        "tool_output",
        "stdout",
        "stderr",
        "path",
        "cwd",
        "env",
        "token",
        "authorization",
        "password",
        "secret",
        "capability",
        "handle",
        "[[rc:",
        "raw_error",
        "api_key",
    ]

    public static let maxExportBytes = 512 * 1024
    public static let defaultRetentionHours = 72

    public static func isAllowedKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        for needle in forbiddenKeySubstrings {
            if lower.contains(needle) { return false }
        }
        return true
    }

    public static func filter(_ fields: [DiagnosticsExportField]) -> [DiagnosticsExportField] {
        fields.filter { isAllowedKey($0.key) && isAllowedValue($0.value) }
    }

    public static func isAllowedValue(_ value: String) -> Bool {
        let lower = value.lowercased()
        if lower.contains("[[rc:") { return false }
        for needle in ["api_key=", "authorization:", "password=", "secret="] {
            if lower.contains(needle) { return false }
        }
        return true
    }

    /// Session-local correlation id: HMAC-like salted hash, not a raw UUID/path.
    public static func correlationID(sessionSalt: Data, eventSeed: String) -> String {
        var hasher = SHA256()
        hasher.update(data: sessionSalt)
        hasher.update(data: Data(eventSeed.utf8))
        let digest = hasher.finalize()
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func buildExportDocument(
        fields: [DiagnosticsExportField],
        unavailableSections: [DiagnosticsExportSection],
        sessionSalt: Data,
        now: Date = Date()
    ) throws -> Data {
        let allowed = filter(fields)
        let object: [String: Any] = [
            "schema_version": "1.0.0",
            "exported_at": ISO8601DateFormatter().string(from: now),
            "correlation_prefix": correlationID(sessionSalt: sessionSalt, eventSeed: "export"),
            "sections": Dictionary(grouping: allowed, by: \.section.rawValue).mapValues { rows in
                Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.value) })
            },
            "unavailable_sections": unavailableSections.map(\.rawValue).sorted(),
            "retention_hours": defaultRetentionHours,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        if data.count > maxExportBytes {
            throw DiagnosticsExportError.exceedsSizeCap(data.count)
        }
        return data
    }

    /// Write export with 0600 permissions under a 0700 parent directory.
    public static func writeExportFile(data: Data, to url: URL) throws {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temp = parent.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temp, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.moveItem(at: temp, to: url)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Secret canary: synthetic secrets must not survive filtering.
    public static func secretCanaryPayload() -> [DiagnosticsExportField] {
        [
            DiagnosticsExportField(section: .capacityMetrics, key: "app_rss_kb", value: "12345"),
            DiagnosticsExportField(section: .capacityMetrics, key: "prompt_text", value: "IGNORE"),
            DiagnosticsExportField(section: .capacityMetrics, key: "api_token", value: "sk-secret"),
            DiagnosticsExportField(section: .capacityMetrics, key: "cwd_path", value: "/Users/secret"),
            DiagnosticsExportField(section: .capacityMetrics, key: "tool_handle", value: "[[rc:abc]]"),
            DiagnosticsExportField(section: .capacityMetrics, key: "raw_error", value: "boom"),
            DiagnosticsExportField(section: .pressureState, key: "level", value: "warning"),
        ]
    }
}

public enum DiagnosticsExportError: Error, Equatable, LocalizedError {
    case exceedsSizeCap(Int)

    public var errorDescription: String? {
        switch self {
        case .exceedsSizeCap(let n):
            return "Diagnostics export exceeds size cap (\(n) bytes)"
        }
    }
}
