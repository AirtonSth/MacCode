import Foundation

/// Read-only view of the global Worker model in `<home>/config.toml` `[models]`.
/// Used for display when the harness has no per-session Worker method.
public enum DistillModelsConfig {
    public static func read(home: URL) -> (worker: String?, workerEffort: String?) {
        guard let text = try? String(
            contentsOf: home.appendingPathComponent("config.toml"),
            encoding: .utf8
        ) else { return (nil, nil) }
        return parse(text)
    }

    static func parse(_ text: String) -> (worker: String?, workerEffort: String?) {
        var inModels = false
        var worker: String?
        var workerEffort: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                inModels = line.hasPrefix("[models]")
                continue
            }
            guard inModels, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard key == "worker" || key == "worker_effort" else { continue }
            let value = unquoted(String(line[line.index(after: equals)...]))
            if key == "worker" { worker = value } else { workerEffort = value }
        }
        return (worker, workerEffort)
    }

    private static func unquoted(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if let quote = value.first, quote == "\"" || quote == "'" {
            let rest = value.dropFirst()
            guard let close = rest.firstIndex(of: quote) else { return nil }
            value = String(rest[..<close])
        } else if let hash = value.firstIndex(of: "#") {
            value = String(value[..<hash])
        }
        value = value.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
