import Foundation

public struct ProjectScript: Codable, Sendable, Equatable {
    public let name: String
    public let command: String
    /// Where it was discovered: "package.json" | "Makefile" | "Package.swift".
    public let source: String

    public init(name: String, command: String, source: String) {
        self.name = name; self.command = command; self.source = source
    }
}

/// Discovers runnable project scripts and opens the workspace in an editor.
/// Pure discovery (no process spawn) so it is unit-testable; running a
/// script is the caller's job (spawn a terminal surface). t3code's
/// ProjectScriptsControl / open-in-editor parity (RC2-069).
public enum ProjectScripts {
    public enum OpenError: LocalizedError, Sendable {
        case failed(cwd: String)

        public var errorDescription: String? {
            switch self {
            case .failed(let cwd):
                "Unable to open workspace in an editor or Finder: \(cwd)"
            }
        }
    }

    public static func discover(in cwd: String) -> [ProjectScript] {
        var out: [ProjectScript] = []

        // package.json "scripts" → `npm run <name>`
        if let data = FileManager.default.contents(atPath: cwd + "/package.json"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = obj["scripts"] as? [String: String] {
            for (k, _) in scripts.sorted(by: { $0.key < $1.key }) {
                out.append(ProjectScript(name: k, command: "npm run \(k)", source: "package.json"))
            }
        }

        // Makefile phony-ish targets → `make <target>`
        if let data = try? Data(contentsOf: URL(fileURLWithPath: cwd + "/Makefile"), options: .mappedIfSafe), let mk = String(data: data, encoding: .utf8) {
            for raw in mk.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = String(raw)
                guard !line.hasPrefix("\t"), !line.hasPrefix("."), !line.hasPrefix("#"),
                      let colon = line.firstIndex(of: ":") else { continue }
                let target = String(line[line.startIndex..<colon])
                    .trimmingCharacters(in: .whitespaces)
                guard !target.isEmpty,
                      target.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }),
                      !out.contains(where: { $0.name == target }) else { continue }
                out.append(ProjectScript(name: target, command: "make \(target)", source: "Makefile"))
            }
        }

        // SwiftPM package → the canonical two.
        if FileManager.default.fileExists(atPath: cwd + "/Package.swift") {
            out.append(ProjectScript(name: "build", command: "swift build", source: "Package.swift"))
            out.append(ProjectScript(name: "test", command: "swift test", source: "Package.swift"))
        }
        return out
    }

    /// Open `cwd` in the first available GUI editor, else reveal in Finder.
    /// Returns the app that handled it (or "Finder").
    @discardableResult
    public static func openInEditor(cwd: String, preferred: [String] = ["Cursor", "Visual Studio Code", "Zed", "Xcode"]) throws -> String {
        func runOpen(_ arguments: [String]) -> Int32? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = arguments
            let sink = Pipe()
            p.standardOutput = sink
            p.standardError = sink
            do {
                try p.run()
                p.waitUntilExit()
                return p.terminationStatus
            } catch {
                return nil
            }
        }

        for app in preferred {
            if runOpen(["-a", app, cwd]) == 0 { return app }
        }
        if runOpen([cwd]) == 0 { return "Finder" }
        throw OpenError.failed(cwd: cwd)
    }
}
