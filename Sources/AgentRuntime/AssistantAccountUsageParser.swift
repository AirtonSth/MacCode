import Foundation
import CoreModel

public enum AssistantAccountUsageParser {
    // PERF: Claude/Grok account-usage refresh recompiled many NSRegularExpressions
    // via String.range/replacingOccurrences(.regularExpression) and built
    // ISO8601DateFormatter per parse. Compile/format once; matching is thread-safe,
    // formatters are serialized under a short lock.
    private static let oscSequenceRegex = try! NSRegularExpression(
        pattern: "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)"
    )
    private static let csiSequenceRegex = try! NSRegularExpression(
        pattern: "\u{001B}\\[[0-?]*[ -/]*[@-~]"
    )
    private static let controlCharRegex = try! NSRegularExpression(
        pattern: "[\u{0000}-\u{0008}\u{000B}\u{000C}\u{000E}-\u{001F}\u{007F}]"
    )
    private static let multiHorizontalSpaceRegex = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)
    private static let whitespaceCollapseRegex = try! NSRegularExpression(pattern: #"\s+"#)

    // WHY full-match + first-number (not capture group 1): patterns use
    // greedy [^\n\r%] runs that leave only the last digit in group 1;
    // original String.range path extracted the first number in the match.
    private static let numberCaptureRegex = try! NSRegularExpression(pattern: #"[0-9]+(?:\.[0-9]+)?"#)

    private static let claudeScreenWeeklyRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(
            pattern: #"(?is)Current\s*week\s*\(\s*all\s*models\s*\).*?([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#
        ),
        try! NSRegularExpression(
            pattern: #"(?is)Weekly\s*limits?.*?all\s*models.*?([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#
        ),
        try! NSRegularExpression(
            pattern: #"(?is)(?:weekly|subscription|usage)[^\n\r%]{0,120}([0-9]+(?:\.[0-9]+)?)\s*%\s*(?:used|utilized)"#
        ),
    ]
    private static let claudeScreenCompactWeeklyRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(
            pattern: #"(?is)Currentweek\(allmodels\).*?([0-9]+(?:\.[0-9]+)?)%used"#
        ),
        try! NSRegularExpression(
            pattern: #"(?is)Weeklylimits?.*?allmodels.*?([0-9]+(?:\.[0-9]+)?)%used"#
        ),
    ]
    private static let claudeScreenSessionRegex = try! NSRegularExpression(
        pattern: #"(?is)Current\s*session.*?([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#
    )
    private static let claudeScreenCompactSessionRegex = try! NSRegularExpression(
        pattern: #"(?is)Curre(?:n)?tsession.*?([0-9]+(?:\.[0-9]+)?)%used"#
    )
    private static let claudeLooseWeeklyRegexes: [NSRegularExpression] = [
        // Modern one-line: "Current week (all models): 54% used · resets ..."
        try! NSRegularExpression(
            pattern: #"(?i)current\s*week\s*\(\s*all\s*models\s*\)[^\n\r%]{0,40}([0-9]+(?:\.[0-9]+)?)\s*%\s*(?:used|utilized)"#
        ),
        try! NSRegularExpression(
            pattern: #"(?i)(?:weekly|subscription|usage)[^\n\r%]{0,80}([0-9]+(?:\.[0-9]+)?)\s*%\s*(?:used|utilized)"#
        ),
        try! NSRegularExpression(
            pattern: #"(?i)([0-9]+(?:\.[0-9]+)?)\s*%\s*(?:used|utilized)[^\n\r]{0,80}(?:weekly|subscription|usage|week)"#
        ),
        try! NSRegularExpression(
            pattern: #"(?i)(?:weekly|subscription|usage)[^\n\r%]{0,80}([0-9]+(?:\.[0-9]+)?)\s*%\s*(?:remaining|left)"#
        ),
    ]
    private static let claudeLooseSessionRegex = try! NSRegularExpression(
        pattern: #"(?i)current\s*session[^\n\r%]{0,40}([0-9]+(?:\.[0-9]+)?)\s*%\s*(?:used|utilized)"#
    )

    private static let iso8601Lock = NSLock()
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso8601WholeSecond: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func codex(from payload: [String: Any]) -> AssistantAccountUsage? {
        let rateLimitsByLimitId = payload["rateLimitsByLimitId"] as? [String: Any]
            ?? payload["rate_limits_by_limit_id"] as? [String: Any]
        let rateLimits = rateLimitsByLimitId?["codex"] as? [String: Any]
            ?? payload["rateLimits"] as? [String: Any]
            ?? payload["rate_limits"] as? [String: Any]
            ?? payload
        let snapshot = weeklySnapshot(from: rateLimits)
        guard let usedPercent = double(snapshot["usedPercent"]) ?? double(snapshot["used_percent"]) else {
            return nil
        }
        return AssistantAccountUsage(
            provider: .codex,
            weeklyUsedPercent: usedPercent,
            weeklyWindowDurationMinutes: windowMinutes(from: snapshot),
            weeklyResetsAtMs: resetMilliseconds(from: snapshot["resetsAt"] ?? snapshot["resets_at"]),
            currentSessionUsedPercent: currentSessionUsedPercent(from: rateLimits),
            currentSessionResetsAtMs: currentSessionResetsAtMilliseconds(from: rateLimits)
        )
    }

    public static func claude(from payload: [String: Any]) -> AssistantAccountUsage? {
        let info = payload["rate_limit_info"] as? [String: Any]
            ?? payload["rateLimitInfo"] as? [String: Any]
            ?? payload["rateLimits"] as? [String: Any]
            ?? payload
        // Claude Code 2.1.258+ stream-json `rate_limit_event` ships utilization under
        // `unifiedWindows.{five_hour,seven_day}` (0–1 or 0–100). Prefer that shape so
        // live turns update the account usage rings; fall back to legacy primary.usedPercent.
        if let unified = claudeUnifiedWindowsUsage(from: info, payload: payload) {
            return unified
        }
        let snapshot = info["primary"] as? [String: Any]
            ?? info["weekly"] as? [String: Any]
            ?? info["allModels"] as? [String: Any]
            ?? info["all_models"] as? [String: Any]
            ?? info
        guard let usedPercent = double(snapshot["usedPercent"]) ?? double(snapshot["used_percent"]) else {
            return nil
        }
        return AssistantAccountUsage(
            provider: .claude,
            weeklyUsedPercent: usedPercent,
            weeklyWindowDurationMinutes: int(snapshot["windowDurationMins"]) ?? int(snapshot["window_duration_mins"]),
            weeklyResetsAtMs: resetMilliseconds(from: snapshot["resetsAt"] ?? snapshot["resets_at"] ?? payload["reset_at"] ?? payload["resetAt"]),
            currentSessionUsedPercent: currentSessionUsedPercent(from: info),
            currentSessionResetsAtMs: currentSessionResetsAtMilliseconds(from: info)
        )
    }

    /// Maps Claude Code stream-json `rate_limit_info.unifiedWindows` onto account usage.
    /// Weekly = `seven_day` (all-models week); session = `five_hour`.
    private static func claudeUnifiedWindowsUsage(
        from info: [String: Any],
        payload: [String: Any]
    ) -> AssistantAccountUsage? {
        let windows = info["unifiedWindows"] as? [String: Any]
            ?? info["unified_windows"] as? [String: Any]
        guard let windows else { return nil }
        let week = windows["seven_day"] as? [String: Any]
            ?? windows["sevenDay"] as? [String: Any]
        guard let weeklyUsed = utilizationPercent(week?["utilization"]) else { return nil }
        let session = windows["five_hour"] as? [String: Any]
            ?? windows["fiveHour"] as? [String: Any]
        return AssistantAccountUsage(
            provider: .claude,
            weeklyUsedPercent: weeklyUsed,
            weeklyWindowDurationMinutes: 10_080,
            weeklyResetsAtMs: resetMilliseconds(
                from: week?["resetsAt"] ?? week?["resets_at"]
                    ?? info["resetsAt"] ?? info["resets_at"]
                    ?? payload["reset_at"] ?? payload["resetAt"]
            ),
            currentSessionUsedPercent: utilizationPercent(session?["utilization"]),
            currentSessionResetsAtMs: resetMilliseconds(
                from: session?["resetsAt"] ?? session?["resets_at"]
            )
        )
    }

    public static func claudeUsageText(_ text: String) -> AssistantAccountUsage? {
        // Prefer the structured screen parser first: modern Claude Code headless
        // `/usage` prints one-line "Current week (all models): 54% used" which the
        // legacy weekly|subscription patterns miss, leaving Claude stuck at 0%.
        // NEVER recurse into claudeUsageScreen → claudeUsageText: empty/partial
        // probes would stack-overflow the detached refresh task.
        if let fromScreen = claudeUsageScreen(text) {
            return fromScreen
        }
        return claudeUsageLoosePatterns(text)
    }

    /// Non-recursive pattern pass used by both headless and screen parsers.
    /// WHY separate: `claudeUsageScreen` used to fall back into `claudeUsageText`,
    /// and after screen was preferred from text that became infinite recursion
    /// (signal 10 crash on empty / partial / remaining-only strings).
    private static func claudeUsageLoosePatterns(_ text: String) -> AssistantAccountUsage? {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        for regex in claudeLooseWeeklyRegexes {
            guard let match = regex.firstMatch(in: text, options: [], range: fullRange) else { continue }
            let matched = nsText.substring(with: match.range)
            let matchedNS = matched as NSString
            let matchedRange = NSRange(location: 0, length: matchedNS.length)
            guard let numberMatch = numberCaptureRegex.firstMatch(
                in: matched,
                options: [],
                range: matchedRange
            ),
            let percent = Double(matchedNS.substring(with: numberMatch.range)) else { continue }
            let isRemaining = matched.range(of: "remaining", options: .caseInsensitive) != nil
                || matched.range(of: "left", options: .caseInsensitive) != nil
            let used = isRemaining ? max(0, 100 - percent) : percent
            // Also pick up session % when the modern one-liner is present.
            let session = firstPercent(in: text, regexes: [claudeLooseSessionRegex])
            return AssistantAccountUsage(
                provider: .claude,
                weeklyUsedPercent: used,
                weeklyWindowDurationMinutes: 10_080,
                currentSessionUsedPercent: session
            )
        }
        return nil
    }

    /// Parses Grok shell billing log lines (`billing: fetched credits config`).
    ///
    /// Observed shape in `~/.grok/logs/unified.jsonl`:
    /// ```json
    /// {"msg":"billing: fetched credits config","ctx":{"config":{
    ///   "creditUsagePercent":29.0,
    ///   "billingPeriodEnd":"2026-07-15T20:46:41.975270+00:00",
    ///   "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",...}
    /// }}}
    /// ```
    public static func grokBillingLogLine(_ line: String) -> AssistantAccountUsage? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return grokBillingJSON(obj)
    }

    public static func grokBillingJSON(_ obj: [String: Any]) -> AssistantAccountUsage? {
        let msg = (obj["msg"] as? String) ?? (obj["message"] as? String) ?? ""
        let ctx = obj["ctx"] as? [String: Any] ?? obj["context"] as? [String: Any] ?? obj
        let config = ctx["config"] as? [String: Any] ?? obj["config"] as? [String: Any]
        guard let config else { return nil }
        // Prefer billing log lines; also accept the live CLI credits-API payload
        // (`GET …/v1/billing?format=credits`) which is a bare `{config:{…}}`.
        let looksLikeBilling = msg.contains("billing") || msg.contains("credits")
            || config["creditUsagePercent"] != nil || config["credit_usage_percent"] != nil
            || config["productUsage"] != nil || config["product_usage"] != nil
            || config["monthlyLimit"] != nil || config["monthly_limit"] != nil
            || config["used"] != nil
        guard looksLikeBilling else { return nil }
        guard let percent = grokWeeklyUsedPercent(from: config) else { return nil }
        let resetsAtMs = parseISO8601Milliseconds(grokPeriodEnd(from: config))
        return AssistantAccountUsage(
            provider: .grok,
            weeklyUsedPercent: percent,
            weeklyWindowDurationMinutes: 10_080,
            weeklyResetsAtMs: resetsAtMs
        )
    }

    /// Access token from `~/.grok/auth.json`. The file is a map of
    /// `issuer::principal` objects whose `key` field is the live CLI bearer.
    /// Never logs the token.
    public static func grokAccessToken(fromAuthFile url: URL, now: Date = Date()) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return grokAccessToken(fromAuthObject: obj, now: now)
    }

    public static func grokAccessToken(fromAuthObject obj: [String: Any], now: Date = Date()) -> String? {
        var candidates: [(token: String, expires: Date?)] = []
        func consider(_ record: [String: Any]) {
            let token = string(record["key"])
                ?? string(record["access_token"])
                ?? string(record["accessToken"])
            guard let token, !token.isEmpty else { return }
            let expires = parseISO8601Date(string(record["expires_at"]) ?? string(record["expiresAt"]))
            candidates.append((token, expires))
        }
        consider(obj)
        for value in obj.values {
            if let record = value as? [String: Any] {
                consider(record)
            }
        }
        let live = candidates.filter { candidate in
            guard let expires = candidate.expires else { return true }
            return expires > now
        }
        let pool = live.isEmpty ? candidates : live
        return pool.max { lhs, rhs in
            (lhs.expires ?? .distantPast) < (rhs.expires ?? .distantPast)
        }?.token
    }

    /// Claude Code OAuth usage (`GET /api/oauth/usage`).
    /// `utilization` is either 0–1 (fraction) or 0–100 (percent).
    public static func claudeOAuthUsage(from payload: [String: Any]) -> AssistantAccountUsage? {
        let week = payload["seven_day"] as? [String: Any]
            ?? payload["sevenDay"] as? [String: Any]
        guard let weeklyUsed = utilizationPercent(week?["utilization"]) else { return nil }
        let session = payload["five_hour"] as? [String: Any]
            ?? payload["fiveHour"] as? [String: Any]
        return AssistantAccountUsage(
            provider: .claude,
            weeklyUsedPercent: weeklyUsed,
            weeklyWindowDurationMinutes: 10_080,
            weeklyResetsAtMs: parseISO8601Milliseconds(
                string(week?["resets_at"]) ?? string(week?["resetsAt"])
            ),
            currentSessionUsedPercent: utilizationPercent(session?["utilization"]),
            currentSessionResetsAtMs: parseISO8601Milliseconds(
                string(session?["resets_at"]) ?? string(session?["resetsAt"])
            )
        )
    }

    /// How long Claude Code itself answers `/usage` from `cachedUsageUtilization`
    /// before fetching again (60 s in Claude Code 2.1.x).
    public static let claudeUsageCacheMaxAge: TimeInterval = 60

    /// Claude Code's own cache of `GET /api/oauth/usage`, kept in `~/.claude.json`
    /// as `cachedUsageUtilization` (`fetchedAtMs`, `accountUuid`, `utilization`).
    ///
    /// WHY: on macOS the OAuth token lives in the Keychain, which RemoteCode must
    /// not read, so the usage API is unreachable and the only other source was
    /// launching `claude -p /usage`. Claude Code answers that command from this
    /// cache while it is younger than `maxAge`, so inside that window this is the
    /// value the launch would print. A cache stamped for another account is
    /// ignored, as Claude Code ignores it. Reads no credentials.
    public static func claudeCachedUsage(
        fromConfigFile url: URL,
        maxAge: TimeInterval = claudeUsageCacheMaxAge,
        now: Date = Date()
    ) -> AssistantAccountUsage? {
        // The cache is written with the file, so an older file cannot hold a
        // fresh cache: skip parsing it.
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate,
              now.timeIntervalSince(modified) < maxAge,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = obj["cachedUsageUtilization"] as? [String: Any],
              let fetchedAtMs = double(cache["fetchedAtMs"]),
              let utilization = cache["utilization"] as? [String: Any] else {
            return nil
        }
        let account = (obj["oauthAccount"] as? [String: Any])?["accountUuid"] as? String
        guard cache["accountUuid"] as? String == account else { return nil }
        let age = now.timeIntervalSince1970 - fetchedAtMs / 1000
        guard age >= 0, age < maxAge else { return nil }
        return claudeOAuthUsage(from: utilization)
    }

    public static func claudeAccessToken(fromAuthFile url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return claudeAccessToken(fromAuthObject: obj)
    }

    public static func claudeAccessToken(fromAuthObject obj: [String: Any]) -> String? {
        let oauth = obj["claudeAiOauth"] as? [String: Any]
            ?? obj["claude_ai_oauth"] as? [String: Any]
            ?? obj
        return string(oauth["accessToken"]) ?? string(oauth["access_token"])
    }

    /// ChatGPT Codex `GET …/wham/usage` mapped onto the existing app-server parser.
    public static func codexWhamUsage(from payload: [String: Any]) -> AssistantAccountUsage? {
        let rate = payload["rate_limit"] as? [String: Any]
            ?? payload["rateLimit"] as? [String: Any]
            ?? payload
        func window(_ raw: Any?) -> [String: Any]? {
            guard let object = raw as? [String: Any] else { return nil }
            var mapped: [String: Any] = [:]
            if let used = object["used_percent"] ?? object["usedPercent"] {
                mapped["used_percent"] = used
            } else if let remaining = double(object["remaining_percent"] ?? object["remainingPercent"]) {
                mapped["used_percent"] = max(0, 100 - remaining)
            }
            if let seconds = int(object["limit_window_seconds"] ?? object["limitWindowSeconds"]) {
                mapped["window_minutes"] = seconds / 60
            } else if let minutes = object["window_minutes"] ?? object["windowMinutes"] {
                mapped["window_minutes"] = minutes
            }
            if let reset = object["reset_at"] ?? object["resets_at"] ?? object["resetsAt"] {
                mapped["resets_at"] = reset
            }
            return mapped.isEmpty ? nil : mapped
        }
        var mapped: [String: Any] = [:]
        if let primary = window(rate["primary_window"] ?? rate["primaryWindow"] ?? rate["primary"]) {
            mapped["primary"] = primary
        }
        if let secondary = window(rate["secondary_window"] ?? rate["secondaryWindow"] ?? rate["secondary"]) {
            mapped["secondary"] = secondary
        }
        guard !mapped.isEmpty else { return nil }
        return codex(from: mapped)
    }

    public static func codexAccessToken(fromAuthFile url: URL) -> (token: String, accountID: String?)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return codexAccessToken(fromAuthObject: obj)
    }

    public static func codexAccessToken(fromAuthObject obj: [String: Any]) -> (token: String, accountID: String?)? {
        let tokens = obj["tokens"] as? [String: Any] ?? obj
        guard let token = string(tokens["access_token"]) ?? string(tokens["accessToken"]) else {
            return nil
        }
        let accountID = string(tokens["account_id"]) ?? string(tokens["accountId"])
        return (token, accountID)
    }

    /// Scans a Grok unified log file (newest first within the last `maxBytes`) for
    /// the freshest `billing: fetched credits config` entry.
    ///
    /// WHY maxBytes defaults to 4 MiB: real `unified.jsonl` files routinely put
    /// more than 512 KiB of non-billing traffic between credit snapshots (observed
    /// gaps > 800 KiB). A too-small window returns nil, the partial account-usage
    /// refresh treats Grok as missing, and the rings falsely paint Grok at 0%.
    ///
    /// WHY the scan is remembered: the 60 s account-usage tick lands here every
    /// time the credits API misses, and re-reading and JSON-parsing a 3.4 MB log
    /// that had not changed cost ~70-120 ms of CPU and ~10 MB of churn a minute.
    /// An unchanged log (same file, size and mtime) returns the last answer
    /// without reading; a log that only grew is read from where the last scan
    /// stopped. Either way the answer equals a full scan of the window.
    public static func grokFromBillingLogFile(
        at url: URL,
        maxBytes: Int = 4 * 1024 * 1024
    ) -> AssistantAccountUsage? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
        let key = "\(maxBytes):\(url.path)"
        let previous = grokBillingLogScanLock.withLock { grokBillingLogScans[key] }
            .flatMap { $0.device == info.st_dev && $0.inode == info.st_ino ? $0 : nil }
        if let previous, previous.size == info.st_size,
           previous.modified.tv_sec == info.st_mtimespec.tv_sec,
           previous.modified.tv_nsec == info.st_mtimespec.tv_nsec {
            return previous.usage
        }
        let size = UInt64(max(0, info.st_size))
        let windowStart = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0

        var scan: GrokBillingLogScan?
        if let previous, info.st_size > previous.size,
           windowStart == 0 || previous.scannedThrough > windowStart,
           readGrokBillingLog(handle, at: previous.scannedThrough - UInt64(previous.anchor.count),
                              upTo: previous.anchor.count) == previous.anchor,
           let appended = readGrokBillingLog(handle, at: previous.scannedThrough) {
            // Only appended: lines from `scannedThrough` on are new or were
            // incomplete last time, and every older line is unchanged.
            let newest = newestGrokBillingLine(in: appended, firstLine: 0)
            let keepPrevious = previous.usage != nil
                && (windowStart == 0 || previous.usageLineStart > windowStart)
            if newest != nil || previous.usage == nil || keepPrevious {
                scan = GrokBillingLogScan(
                    info: info,
                    end: previous.scannedThrough + UInt64(appended.count),
                    base: previous.scannedThrough,
                    data: appended,
                    hit: newest,
                    resumed: previous
                )
            }
        }
        if scan == nil {
            guard let data = readGrokBillingLog(handle, at: windowStart) else { return nil }
            // Drop partial first line when we mid-started the file.
            var firstLine = 0
            if windowStart > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
                firstLine = newline - data.startIndex + 1
            }
            scan = GrokBillingLogScan(
                info: info,
                end: windowStart + UInt64(data.count),
                base: windowStart,
                data: data,
                hit: newestGrokBillingLine(in: data, firstLine: firstLine),
                resumed: nil
            )
        }
        guard let scan else { return nil }
        grokBillingLogScanLock.withLock { grokBillingLogScans[key] = scan }
        return scan.usage
    }

    /// What the last scan of one billing log saw.
    private struct GrokBillingLogScan {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modified: timespec
        /// Offset just past the last newline read: an appended log resumes here.
        let scannedThrough: UInt64
        /// Bytes right before `scannedThrough`, compared on resume so a log that
        /// was truncated and regrew is read from scratch.
        let anchor: Data
        let usage: AssistantAccountUsage?
        /// Offset of the line `usage` came from.
        let usageLineStart: UInt64

        init(
            info: stat,
            end: UInt64,
            base: UInt64,
            data: Data,
            hit: (usage: AssistantAccountUsage, lineStart: Int)?,
            resumed: GrokBillingLogScan?
        ) {
            device = info.st_dev
            inode = info.st_ino
            // The bytes actually read: a write after `fstat` is picked up next tick.
            size = off_t(end)
            modified = info.st_mtimespec
            let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")).map { $0 - data.startIndex + 1 }
            scannedThrough = base + UInt64(lastNewline ?? 0)
            let anchorStart = max(0, (lastNewline ?? 0) - 32)
            anchor = lastNewline.map { Data(data[(data.startIndex + anchorStart)..<(data.startIndex + $0)]) }
                ?? resumed?.anchor ?? Data()
            if let hit {
                usage = hit.usage
                usageLineStart = base + UInt64(hit.lineStart)
            } else {
                // No new match: the previous answer stands (the caller checked
                // it is still inside the window).
                usage = resumed?.usage
                usageLineStart = resumed?.usageLineStart ?? 0
            }
        }
    }

    private static let grokBillingLogScanLock = NSLock()
    private static var grokBillingLogScans: [String: GrokBillingLogScan] = [:]
    /// Bytes read from billing logs; lets tests prove an unchanged log is not read.
    static var grokBillingLogBytesReadForTesting: Int {
        grokBillingLogScanLock.withLock { grokBillingLogBytesRead }
    }
    private static var grokBillingLogBytesRead = 0
    private static let grokConfigKey = Array(#""config""#.utf8)

    private static func readGrokBillingLog(_ handle: FileHandle, at offset: UInt64, upTo count: Int? = nil) -> Data? {
        do {
            try handle.seek(toOffset: offset)
            let data = try count.map { try handle.read(upToCount: $0) ?? Data() } ?? handle.readToEnd() ?? Data()
            grokBillingLogScanLock.withLock { grokBillingLogBytesRead += data.count }
            return data
        } catch {
            return nil
        }
    }

    /// Newest line of `data` (from byte `firstLine`) that `grokBillingLogLine`
    /// accepts, with its start. Only lines holding the `"config"` key are parsed:
    /// `grokBillingJSON` returns nil without a `config` object, so no other line
    /// can match, and the live log has none.
    private static func newestGrokBillingLine(
        in data: Data,
        firstLine: Int
    ) -> (usage: AssistantAccountUsage, lineStart: Int)? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (usage: AssistantAccountUsage, lineStart: Int)? in
            guard let base = raw.baseAddress, raw.count > firstLine else { return nil }
            var candidates: [Range<Int>] = []
            var searchFrom = firstLine
            while searchFrom < raw.count,
                  let found = memmem(base + searchFrom, raw.count - searchFrom,
                                     grokConfigKey, grokConfigKey.count) {
                let hit = base.distance(to: UnsafeRawPointer(found))
                var start = hit
                while start > firstLine, raw[start - 1] != UInt8(ascii: "\n") { start -= 1 }
                var end = hit
                while end < raw.count, raw[end] != UInt8(ascii: "\n") { end += 1 }
                candidates.append(start..<end)
                searchFrom = end + 1
            }
            // Newest last in the log — walk reverse.
            for line in candidates.reversed() {
                let text = String(decoding: UnsafeRawBufferPointer(rebasing: raw[line]), as: UTF8.self)
                if let usage = grokBillingLogLine(text) {
                    return (usage, line.lowerBound)
                }
            }
            return nil
        }
    }

    private static func grokWeeklyUsedPercent(from config: [String: Any]) -> Double? {
        if let product = grokBuildProductPercent(from: config) {
            return product
        }
        if let credits = double(config["creditUsagePercent"])
            ?? double(config["credit_usage_percent"])
            ?? double(config["usedPercent"])
            ?? double(config["used_percent"]) {
            return credits
        }
        let used = moneyVal(config["used"])
        let limit = moneyVal(config["monthlyLimit"]) ?? moneyVal(config["monthly_limit"])
        if let used, let limit, limit > 0 {
            return min(100, max(0, (used / limit) * 100))
        }
        return nil
    }

    // PERF: product-name slugify recompiled `[^a-z0-9]` on every product row.
    private static let productSlugRegex = try! NSRegularExpression(pattern: "[^a-z0-9]")

    /// Grok's Usage UI labels the weekly bar "Grok Build". Prefer that product
    /// row when the live credits payload includes `productUsage`.
    private static func grokBuildProductPercent(from config: [String: Any]) -> Double? {
        let rows = config["productUsage"] as? [[String: Any]]
            ?? config["product_usage"] as? [[String: Any]]
            ?? []
        for row in rows {
            let raw = (string(row["product"]) ?? string(row["name"]) ?? "").lowercased()
            let name = replaceAll(productSlugRegex, in: raw, with: "")
            guard name == "grokbuild" || name == "grokcli" else { continue }
            return double(row["usagePercent"]) ?? double(row["usage_percent"])
        }
        return nil
    }

    private static func grokPeriodEnd(from config: [String: Any]) -> String? {
        let period = config["currentPeriod"] as? [String: Any]
            ?? config["current_period"] as? [String: Any]
        let type = (string(period?["type"]) ?? "").uppercased()
        if type.contains("WEEKLY"), let end = string(period?["end"]) {
            return end
        }
        return string(config["billingPeriodEnd"])
            ?? string(config["billing_period_end"])
            ?? string(period?["end"])
    }

    private static func parseISO8601Date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        iso8601Lock.lock()
        let date = iso8601Fractional.date(from: value) ?? iso8601WholeSecond.date(from: value)
        iso8601Lock.unlock()
        return date
    }

    private static func parseISO8601Milliseconds(_ value: String?) -> Int64? {
        parseISO8601Date(value).map { Int64($0.timeIntervalSince1970 * 1000) }
    }

    public static func claudeUsageScreen(_ text: String) -> AssistantAccountUsage? {
        let normalized = terminalPlainText(text)
        let compacted = replaceAll(whitespaceCollapseRegex, in: normalized, with: "")
        guard let weeklyUsed = firstPercent(in: normalized, regexes: claudeScreenWeeklyRegexes)
            ?? firstPercent(in: compacted, regexes: claudeScreenCompactWeeklyRegexes) else {
            // Loose patterns only — never claudeUsageText (would re-enter this path).
            return claudeUsageLoosePatterns(normalized)
        }
        let currentSessionUsed = firstPercent(in: normalized, regexes: [claudeScreenSessionRegex])
            ?? firstPercent(in: compacted, regexes: [claudeScreenCompactSessionRegex])
        return AssistantAccountUsage(
            provider: .claude,
            weeklyUsedPercent: weeklyUsed,
            weeklyWindowDurationMinutes: 10_080,
            currentSessionUsedPercent: currentSessionUsed
        )
    }

    private static func weeklySnapshot(from rateLimits: [String: Any]) -> [String: Any] {
        if let weekly = rateLimits["weekly"] as? [String: Any] {
            return weekly
        }
        let candidates = ["secondary", "primary"].compactMap { rateLimits[$0] as? [String: Any] }
        if let weekly = candidates.first(where: { (windowMinutes(from: $0) ?? 0) >= 10_080 }) {
            return weekly
        }
        if let largest = candidates.max(by: { (windowMinutes(from: $0) ?? 0) < (windowMinutes(from: $1) ?? 0) }) {
            return largest
        }
        return rateLimits
    }

    private static func currentSessionUsedPercent(from rateLimits: [String: Any]) -> Double? {
        let current = rateLimits["currentSession"] as? [String: Any]
            ?? rateLimits["current_session"] as? [String: Any]
            ?? rateLimits["primary"] as? [String: Any]
        guard let window = current,
              (windowMinutes(from: window) ?? 0) < 10_080 else {
            return nil
        }
        return double(window["usedPercent"])
            ?? double(window["used_percent"])
            ?? double(window["usedPercentage"])
            ?? double(window["used_percentage"])
    }

    private static func currentSessionResetsAtMilliseconds(from rateLimits: [String: Any]) -> Int64? {
        let current = rateLimits["currentSession"] as? [String: Any]
            ?? rateLimits["current_session"] as? [String: Any]
            ?? rateLimits["primary"] as? [String: Any]
        guard let window = current,
              (windowMinutes(from: window) ?? 0) < 10_080 else {
            return nil
        }
        return resetMilliseconds(from: window["resetsAt"] ?? window["resets_at"])
    }

    private static func firstPercent(in text: String, regexes: [NSRegularExpression]) -> Double? {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        for regex in regexes {
            guard let match = regex.firstMatch(in: text, options: [], range: fullRange) else { continue }
            let matched = nsText.substring(with: match.range)
            let matchedNS = matched as NSString
            let matchedRange = NSRange(location: 0, length: matchedNS.length)
            guard let numberMatch = numberCaptureRegex.firstMatch(
                in: matched,
                options: [],
                range: matchedRange
            ),
            let percent = Double(matchedNS.substring(with: numberMatch.range)) else { continue }
            return percent
        }
        return nil
    }

    private static func replaceAll(
        _ regex: NSRegularExpression,
        in text: String,
        with template: String
    ) -> String {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static func terminalPlainText(_ text: String) -> String {
        var result = replaceAll(oscSequenceRegex, in: text, with: " ")
        result = replaceAll(csiSequenceRegex, in: result, with: " ")
        result = result.replacingOccurrences(of: "\r", with: "\n")
        result = replaceAll(controlCharRegex, in: result, with: " ")
        result = replaceAll(multiHorizontalSpaceRegex, in: result, with: " ")
        return result
    }

    private static func resetMilliseconds(from value: Any?) -> Int64? {
        if let int = int(value) {
            return int < 10_000_000_000 ? Int64(int) * 1000 : Int64(int)
        }
        guard let string = value as? String else { return nil }
        if let int = Int64(string) {
            return int < 10_000_000_000 ? int * 1000 : int
        }
        iso8601Lock.lock()
        let date = iso8601WholeSecond.date(from: string)
        iso8601Lock.unlock()
        return date.map { Int64($0.timeIntervalSince1970 * 1000) }
    }

    private static func windowMinutes(from snapshot: [String: Any]) -> Int? {
        int(snapshot["windowDurationMins"])
            ?? int(snapshot["window_duration_mins"])
            ?? int(snapshot["windowMinutes"])
            ?? int(snapshot["window_minutes"])
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func moneyVal(_ value: Any?) -> Double? {
        if let object = value as? [String: Any] {
            return double(object["val"]) ?? double(object["value"])
        }
        return double(value)
    }

    /// Claude OAuth / stream-json `utilization` is documented as 0–100 and also
    /// observed as 0–1. Round fractional→percent so IEEE values like 0.58 map to
    /// the same whole percents Claude Code prints in `/usage`.
    private static func utilizationPercent(_ value: Any?) -> Double? {
        guard let raw = double(value) else { return nil }
        if raw > 1 { return min(100, max(0, raw)) }
        return min(100, max(0, (raw * 100).rounded()))
    }
}
