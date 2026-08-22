import Foundation
import CryptoKit

/// Typed allowlist for capacity/diagnostics export (plan-optimize-swift S1 / T-003).
///
/// Only exact (section, key) pairs from `allowedKeys` may be exported. Values are
/// validated per key domain. Correlation IDs are salted session-local. Explicit export is 0600.

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

public enum DiagnosticsExportError: Error, Equatable, LocalizedError {
    case exceedsSizeCap(Int)
    case unknownKey(String)
    case invalidValue(String)
    case duplicateKey(String)

    public var errorDescription: String? {
        switch self {
        case .exceedsSizeCap(let n):
            return "Diagnostics export exceeds size cap (\(n) bytes)"
        case .unknownKey(let k):
            return "Diagnostics export key not on allowlist: \(k)"
        case .invalidValue(let v):
            return "Diagnostics export value rejected: \(v)"
        case .duplicateKey(let k):
            return "Diagnostics export duplicate key: \(k)"
        }
    }
}

public enum DiagnosticsExportAllowlist {
    public static let maxExportBytes = 512 * 1024
    public static let defaultRetentionHours = 72
    public static let maxValueLength = 64

    public static let allowedKeys: [DiagnosticsExportSection: Set<String>] = [
        .capacityManifest: ["schema_version", "manifest_id", "warmed_sample_count"],
        .capacityMetrics: [
            "app_rss_kb", "provider_tree_rss_kb", "sidecar_rss_kb",
            "accept_to_prepare_ms_p95", "prepare_to_spawn_ms_p95",
            "event_to_visible_paint_ms_p95", "stop_dispatch_ms_p95",
            "dag_longest_no_progress_ms", "ownership_coverage_fraction",
            "batcher_pending_bytes", "batcher_pending_count",
            "lock_wait_ms_p95", "main_actor_stall_ms_max",
            "metric_variance_max",
        ],
        .pressureState: ["level", "epoch", "frozen_accounting", "action_count"],
        .managedRSSTrend: [
            "total_managed_rss_kb", "slope_kb_per_minute", "high_water_managed_rss_kb",
            "sample_complete",
        ],
        .hangWatchdog: ["gap_kind", "hang_likely_count"],
        .ownershipCoverage: ["coverage_fraction", "live_row_count"],
        .transportQueueDepths: [
            "batcher_pending_bytes", "batcher_pending_count", "outbound_queue_bytes",
        ],
        .hardwareTier: ["tier_name", "physically_executed", "physical_memory_bytes"],
        .unavailableManifest: ["section_name", "reason"],
    ]

    public static func isAllowed(section: DiagnosticsExportSection, key: String) -> Bool {
        allowedKeys[section]?.contains(key) == true
    }

    public static func isAllowedValue(
        _ value: String,
        section: DiagnosticsExportSection,
        key: String
    ) -> Bool {
        if value.isEmpty || value.count > maxValueLength { return false }
        if value.contains("[[rc:") { return false }
        if value.contains("/") || value.contains("\\") { return false }
        if value.contains("@") { return false }
        let lower = value.lowercased()
        if lower.contains("bearer") || lower.contains("sk-") { return false }

        switch (section, key) {
        case (.pressureState, "level"):
            return ["normal", "warning", "critical", "unknown"].contains(value)
        case (.pressureState, "frozen_accounting"),
             (.managedRSSTrend, "sample_complete"),
             (.hardwareTier, "physically_executed"):
            return value == "true" || value == "false" || value == "0" || value == "1"
        case (.pressureState, "epoch"),
             (.pressureState, "action_count"),
             (.managedRSSTrend, "total_managed_rss_kb"),
             (.managedRSSTrend, "high_water_managed_rss_kb"),
             (.transportQueueDepths, _),
             (.ownershipCoverage, "live_row_count"),
             (.hangWatchdog, "hang_likely_count"),
             (.capacityManifest, "warmed_sample_count"),
             (.hardwareTier, "physical_memory_bytes"),
             (.capacityMetrics, "app_rss_kb"),
             (.capacityMetrics, "provider_tree_rss_kb"),
             (.capacityMetrics, "sidecar_rss_kb"),
             (.capacityMetrics, "batcher_pending_bytes"),
             (.capacityMetrics, "batcher_pending_count"):
            guard let n = Double(value), n.isFinite, n >= 0, floor(n) == n else { return false }
            return true
        case (.capacityMetrics, "ownership_coverage_fraction"),
             (.ownershipCoverage, "coverage_fraction"):
            guard let n = Double(value), n.isFinite, n >= 0, n <= 1 else { return false }
            return true
        case (.managedRSSTrend, "slope_kb_per_minute"):
            // Signed slope (falling RSS is negative).
            guard let n = Double(value), n.isFinite else { return false }
            return true
        case (.capacityMetrics, "metric_variance_max"):
            guard let n = Double(value), n.isFinite, n >= 0, n <= 1 else { return false }
            return true
        case (.capacityMetrics, _):
            // Latency and other capacity metrics: finite non-negative
            guard let n = Double(value), n.isFinite, n >= 0 else { return false }
            return true
        case (.hangWatchdog, "gap_kind"):
            return ["hangLikely", "suspendedOrSleep", "normal"].contains(value)
        default:
            let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            return value.unicodeScalars.allSatisfy { allowedScalars.contains($0) }
        }
    }

    public static func filter(_ fields: [DiagnosticsExportField]) -> [DiagnosticsExportField] {
        fields.filter {
            isAllowed(section: $0.section, key: $0.key)
                && isAllowedValue($0.value, section: $0.section, key: $0.key)
        }
    }

    public static func validate(_ fields: [DiagnosticsExportField]) throws {
        var seen = Set<String>()
        for field in fields {
            let composite = "\(field.section.rawValue).\(field.key)"
            guard isAllowed(section: field.section, key: field.key) else {
                throw DiagnosticsExportError.unknownKey(composite)
            }
            guard isAllowedValue(field.value, section: field.section, key: field.key) else {
                throw DiagnosticsExportError.invalidValue(field.value)
            }
            if seen.contains(composite) {
                throw DiagnosticsExportError.duplicateKey(composite)
            }
            seen.insert(composite)
        }
    }

    private static let hexAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    public static func correlationID(sessionSalt: Data, eventSeed: String) -> String {
        var hasher = SHA256()
        hasher.update(data: sessionSalt)
        hasher.update(data: Data(eventSeed.utf8))
        let digest = hasher.finalize()
        // PERF: nibble table avoids String(format:) per byte; same lowercase hex.
        var out: [UInt8] = []
        out.reserveCapacity(16)
        for b in digest.prefix(8) {
            out.append(Self.hexAlphabet[Int(b >> 4)])
            out.append(Self.hexAlphabet[Int(b & 0x0F)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    // PERF: ISO8601DateFormatter init is expensive. Share one for export.
    private static let exportISOFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let exportISOFormatterLock = NSLock()

    public static func buildExportDocument(
        fields: [DiagnosticsExportField],
        unavailableSections: [DiagnosticsExportSection],
        sessionSalt: Data,
        now: Date = Date()
    ) throws -> Data {
        try validate(fields)
        let allowed = filter(fields)
        var sections: [String: [String: String]] = [:]
        for field in allowed {
            var bucket = sections[field.section.rawValue] ?? [:]
            bucket[field.key] = field.value
            sections[field.section.rawValue] = bucket
        }
        exportISOFormatterLock.lock()
        let exportedAt = exportISOFormatter.string(from: now)
        exportISOFormatterLock.unlock()
        let object: [String: Any] = [
            "schema_version": "1.0.0",
            "exported_at": exportedAt,
            "correlation_prefix": correlationID(sessionSalt: sessionSalt, eventSeed: "export"),
            "sections": sections,
            "unavailable_sections": unavailableSections.map(\.rawValue).sorted(),
            "retention_hours": defaultRetentionHours,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        if data.count > maxExportBytes {
            throw DiagnosticsExportError.exceedsSizeCap(data.count)
        }
        return data
    }

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

    public static func secretCanaryPayload() -> [DiagnosticsExportField] {
        [
            DiagnosticsExportField(section: .capacityMetrics, key: "app_rss_kb", value: "12345"),
            DiagnosticsExportField(section: .capacityMetrics, key: "prompt_text", value: "IGNORE"),
            DiagnosticsExportField(section: .capacityMetrics, key: "api_token", value: "sk-secret"),
            DiagnosticsExportField(section: .capacityMetrics, key: "cwd_path", value: "/Users/secret"),
            DiagnosticsExportField(section: .capacityMetrics, key: "tool_handle", value: "[[rc:abc]]"),
            DiagnosticsExportField(section: .capacityMetrics, key: "raw_error", value: "boom"),
            DiagnosticsExportField(section: .pressureState, key: "level", value: "warning"),
            DiagnosticsExportField(section: .pressureState, key: "level", value: "bearer-xyz"),
        ]
    }
}
