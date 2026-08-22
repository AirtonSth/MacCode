import CryptoKit
import Foundation

/// ChatML JSONL writer for Distill generate (SFT + rejected split).
public final class TokenSaverTrainingDatasetWriter: @unchecked Sendable {
    public static let schemaVersion = 1
    public static let maxFileBytes = 64 * 1_024 * 1_024

    private let root: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var seen = Set<String>()

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    public static func defaultRoot(appSupportDirectory: URL) -> URL {
        appSupportDirectory
            .appendingPathComponent("TokenSaver", isDirectory: true)
            .appendingPathComponent("training", isDirectory: true)
    }

    public func record(
        request: DistillRequest,
        output: String,
        stage: TokenSaverRouteStage?,
        modelID: String,
        source: String
    ) {
        guard stage == .llmMLX else { return }
        let assistant = datasetAssistant(output)
        let failOpen = output == request.input || assistant == nil
        if failOpen {
            appendRejected(
                request: request,
                modelID: modelID,
                source: source,
                reason: assistant == nil ? "think_only" : "fail_open"
            )
        } else if let assistant {
            appendSFT(request: request, assistant: assistant, modelID: modelID, source: source)
        }
    }

    /// Catalog / raw chat generate: always write SFT or rejected, independent of HTTP.
    public func recordRaw(
        system: String,
        user: String,
        assistant: String?,
        modelID: String,
        source: String
    ) {
        guard let stripped = datasetAssistant(assistant ?? "") else {
            appendRawRejected(
                system: system,
                user: user,
                modelID: modelID,
                source: source,
                reason: assistant == nil ? "generate_nil" : "think_only"
            )
            return
        }
        appendRawSFT(system: system, user: user, assistant: stripped, modelID: modelID, source: source)
    }

    private func appendSFT(
        request: DistillRequest,
        assistant: String,
        modelID: String,
        source: String
    ) {
        let sha = sha256(request.input)
        let dedup = "\(request.mode.rawValue)|\(sha)"
        lock.lock()
        if seen.contains(dedup) {
            lock.unlock()
            return
        }
        seen.insert(dedup)
        lock.unlock()

        let record: [String: Any] = [
            "messages": [
                ["role": "system", "content": sanitize(DistillPrompt.systemInstructions(for: request.mode))],
                ["role": "user", "content": sanitize(DistillPrompt.userPrompt(for: request))],
                ["role": "assistant", "content": sanitize(assistant)],
            ],
            "metadata": [
                "mode": request.mode.rawValue,
                "model": modelID,
                "source": source,
                "input_sha256": sha,
                "created_at": Self.isoNow(),
            ],
        ]
        appendJSONL(record, to: sftURL(for: request.mode), split: "sft")
    }

    private func appendRejected(
        request: DistillRequest,
        modelID: String,
        source: String,
        reason: String
    ) {
        let day = Self.dayStamp(Date())
        let record: [String: Any] = [
            "messages": [
                ["role": "system", "content": sanitize(DistillPrompt.systemInstructions(for: request.mode))],
                ["role": "user", "content": sanitize(DistillPrompt.userPrompt(for: request))],
            ],
            "metadata": [
                "mode": request.mode.rawValue,
                "model": modelID,
                "source": source,
                "reason": reason,
                "input_sha256": sha256(request.input),
                "created_at": Self.isoNow(),
            ],
        ]
        appendJSONL(record, to: root.appendingPathComponent("rejected", isDirectory: true).appendingPathComponent("\(day).jsonl"), split: "rejected")
    }

    private func appendRawSFT(
        system: String,
        user: String,
        assistant: String,
        modelID: String,
        source: String
    ) {
        let sha = sha256(system + "\n" + user)
        let dedup = "catalogOp|\(sha)"
        lock.lock()
        if seen.contains(dedup) {
            lock.unlock()
            return
        }
        seen.insert(dedup)
        lock.unlock()
        let record: [String: Any] = [
            "messages": [
                ["role": "system", "content": sanitize(system)],
                ["role": "user", "content": sanitize(user)],
                ["role": "assistant", "content": sanitize(assistant)],
            ],
            "metadata": [
                "mode": "catalogOp",
                "model": modelID,
                "source": source,
                "input_sha256": sha,
                "created_at": Self.isoNow(),
            ],
        ]
        appendJSONL(
            record,
            to: root.appendingPathComponent("sft", isDirectory: true).appendingPathComponent("catalogOp.jsonl"),
            split: "sft"
        )
    }

    private func appendRawRejected(
        system: String,
        user: String,
        modelID: String,
        source: String,
        reason: String
    ) {
        let day = Self.dayStamp(Date())
        let record: [String: Any] = [
            "messages": [
                ["role": "system", "content": sanitize(system)],
                ["role": "user", "content": sanitize(user)],
            ],
            "metadata": [
                "mode": "catalogOp",
                "model": modelID,
                "source": source,
                "reason": reason,
                "input_sha256": sha256(system + "\n" + user),
                "created_at": Self.isoNow(),
            ],
        ]
        appendJSONL(
            record,
            to: root.appendingPathComponent("rejected", isDirectory: true).appendingPathComponent("\(day).jsonl"),
            split: "rejected"
        )
    }

    private func sftURL(for mode: DistillMode) -> URL {
        let name: String
        switch mode {
        case .commandOutput: name = "commandOutput.jsonl"
        case .longText: name = "longText.jsonl"
        case .watchSummary: name = "watchSummary.jsonl"
        case .wireEncode: name = "wireEncode.jsonl"
        default: name = "other.jsonl"
        }
        return root.appendingPathComponent("sft", isDirectory: true).appendingPathComponent(name)
    }

    private func appendJSONL(_ record: [String: Any], to url: URL, split: String) {
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record),
              var line = String(data: data, encoding: .utf8) else {
            return
        }
        line.append("\n")
        guard let payload = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var target = url
            if fileManager.fileExists(atPath: target.path),
               let attrs = try? fileManager.attributesOfItem(atPath: target.path),
               let size = attrs[.size] as? NSNumber,
               size.intValue + payload.count > Self.maxFileBytes {
                let stem = url.deletingPathExtension().lastPathComponent
                target = url.deletingLastPathComponent().appendingPathComponent("\(stem)-2.jsonl")
            }
            if !fileManager.fileExists(atPath: target.path) {
                fileManager.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(payload)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            updateManifestLocked(split: split, file: target)
        } catch {
            return
        }
    }

    private func updateManifestLocked(split: String, file: URL) {
        let manifestURL = root.appendingPathComponent("manifest.json")
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: manifestURL, options: .mappedIfSafe),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = parsed
        }
        obj["schema_version"] = Self.schemaVersion
        obj["last_write"] = Self.isoNow()
        var counts = obj["counts"] as? [String: Int] ?? [:]
        counts[split, default: 0] += 1
        obj["counts"] = counts
        obj["last_file"] = file.lastPathComponent
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        let tmp = manifestURL.appendingPathExtension("tmp")
        try? data.write(to: tmp, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try? fileManager.replaceItem(at: manifestURL, withItemAt: tmp, backupItemName: nil, options: [], resultingItemURL: nil)
    }

    private static let hexAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    private func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        // PERF: nibble table avoids 32 String(format:) calls per hash; same lowercase hex.
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for b in digest {
            out.append(Self.hexAlphabet[Int(b >> 4)])
            out.append(Self.hexAlphabet[Int(b & 0x0F)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    /// Strict: unclosed think / leftover traces are not SFT material.
    private func datasetAssistant(_ text: String) -> String? {
        guard let stripped = LibrarianThinkStrip.strip(text) else { return nil }
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sanitize(_ text: String) -> String {
        redact(LibrarianThinkStrip.stripLenient(text))
    }

    // PERF: NSRegularExpression recompilation is expensive. Share precompiled regexes.
    private static let liveRegex = try! NSRegularExpression(pattern: #"sk_live_[A-Za-z0-9]+"#)
    private static let keyedRegex = try! NSRegularExpression(pattern: #"(?i)(api[_-]?key|password|secret|token|bearer)\s*[:=]\s*\S+"#)

    private func redact(_ text: String) -> String {
        var s = text
        s = Self.liveRegex.stringByReplacingMatches(in: s, options: [], range: NSRange(s.startIndex..., in: s), withTemplate: "<redacted>")
        s = Self.keyedRegex.stringByReplacingMatches(in: s, options: [], range: NSRange(s.startIndex..., in: s), withTemplate: "$1=<redacted>")
        return s
    }

    // PERF: DateFormatter ICU init is expensive. Share one for yyyy-MM-dd behind lock.
    private static let dayStampLock = NSLock()
    private static let dayStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let isoLock = NSLock()
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func isoNow() -> String {
        isoLock.lock()
        let s = isoFormatter.string(from: Date())
        isoLock.unlock()
        return s
    }

    private static func dayStamp(_ date: Date) -> String {
        dayStampLock.lock()
        let s = dayStampFormatter.string(from: date)
        dayStampLock.unlock()
        return s
    }
}
