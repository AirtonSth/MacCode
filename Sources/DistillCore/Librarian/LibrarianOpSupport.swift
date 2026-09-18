import Foundation

/// Result of a host process invocation performed by the librarian ops.
public struct LibrarianProcessResult: Sendable, Equatable {
    public let launched: Bool
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public init(
        launched: Bool,
        exitCode: Int32 = 0,
        stdout: String = "",
        stderr: String = "",
        timedOut: Bool = false
    ) {
        self.launched = launched
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public static let notLaunched = LibrarianProcessResult(launched: false)
}

public struct LibrarianProcessInvocation: Sendable {
    public var executable: String
    public var arguments: [String]
    public var cwd: String?
    public var timeout: TimeInterval
    public var environment: [String: String]?

    public init(
        executable: String,
        arguments: [String] = [],
        cwd: String? = nil,
        timeout: TimeInterval = 20,
        environment: [String: String]? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.timeout = timeout
        self.environment = environment
    }
}

/// Host authorization state for capabilities that need a TCC grant (microphone,
/// screen capture). `notDetermined` is a real state, not a failure.
public enum LibrarianAuthorizationState: String, Sendable, Equatable {
    case authorized
    case denied
    case notDetermined = "not_determined"
    case unavailable
}

/// All host I/O the workspace / navigation / media ops touch. Every field is a
/// closure so tests can drive the real ops against a temp workspace and the
/// sidecar can use the real filesystem, processes and permissions.
public struct LibrarianHostIO: Sendable {
    public var readText: @Sendable (_ path: String, _ maxBytes: Int) -> String?
    public var writeText: @Sendable (_ path: String, _ text: String) -> Bool
    public var fileExists: @Sendable (_ path: String) -> Bool
    public var isDirectory: @Sendable (_ path: String) -> Bool
    public var listFiles: @Sendable (_ root: String, _ limit: Int) -> [String]
    public var runProcess: @Sendable (LibrarianProcessInvocation) -> LibrarianProcessResult
    public var resolveTool: @Sendable (_ name: String) -> String?
    public var now: @Sendable () -> Date
    public var home: @Sendable () -> String
    public var authorization: @Sendable (_ capability: String) -> LibrarianAuthorizationState

    public init(
        readText: @escaping @Sendable (String, Int) -> String?,
        writeText: @escaping @Sendable (String, String) -> Bool,
        fileExists: @escaping @Sendable (String) -> Bool,
        isDirectory: @escaping @Sendable (String) -> Bool,
        listFiles: @escaping @Sendable (String, Int) -> [String],
        runProcess: @escaping @Sendable (LibrarianProcessInvocation) -> LibrarianProcessResult,
        resolveTool: @escaping @Sendable (String) -> String?,
        now: @escaping @Sendable () -> Date,
        home: @escaping @Sendable () -> String,
        authorization: @escaping @Sendable (String) -> LibrarianAuthorizationState
    ) {
        self.readText = readText
        self.writeText = writeText
        self.fileExists = fileExists
        self.isDirectory = isDirectory
        self.listFiles = listFiles
        self.runProcess = runProcess
        self.resolveTool = resolveTool
        self.now = now
        self.home = home
        self.authorization = authorization
    }

    public static let live = LibrarianHostIO(
        readText: { path, maxBytes in
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: max(1, maxBytes))) ?? Data()
            return String(data: data, encoding: .utf8)
        },
        writeText: { path, text in
            (try? Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
        },
        fileExists: { FileManager.default.fileExists(atPath: $0) },
        isDirectory: { path in
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return exists && isDir.boolValue
        },
        listFiles: { root, limit in
            LibrarianWorkspaceFiles.collect(root: root, limit: limit)
        },
        runProcess: { invocation in
            LibrarianProcessRunner.run(invocation)
        },
        resolveTool: { name in
            LibrarianToolResolver.resolve(name)
        },
        now: { Date() },
        home: { FileManager.default.homeDirectoryForCurrentUser.path },
        authorization: { capability in
            LibrarianHostPermissions.authorization(for: capability)
        }
    )
}

/// Deterministic executable resolution for the host tools the ops may run.
/// Only absolute tool paths and the standard system/user bin directories are
/// searched; the managed provider-proxy bin is never used.
public enum LibrarianToolResolver {
    public static func resolve(
        _ name: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileManager: FileManager = .default
    ) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        var candidates = [
            "/opt/homebrew/bin/\(trimmed)",
            "/usr/local/bin/\(trimmed)",
            "/usr/bin/\(trimmed)",
            "/bin/\(trimmed)",
            "\(home)/.local/bin/\(trimmed)",
            "\(home)/.grok/bin/\(trimmed)",
            "\(home)/.remote-code/bin/\(trimmed)"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/\(trimmed)" }
        }
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }
}

/// Runs one process with a hard deadline. stdout/stderr are bounded.
public enum LibrarianProcessRunner {
    public static let maxOutputBytes = 4 * 1024 * 1024

    public static func run(_ invocation: LibrarianProcessInvocation) -> LibrarianProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        if let cwd = invocation.cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let environment = invocation.environment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment { merged[key] = value }
            process.environment = merged
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .notLaunched
        }
        let deadline = Date().addingTimeInterval(max(0.1, invocation.timeout))
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                break
            }
            usleep(20_000)
        }
        if timedOut {
            // Give SIGTERM one grace window, then SIGKILL so a wedged tool cannot
            // hold a librarian call open forever.
            let killDeadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < killDeadline { usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            while process.isRunning { usleep(20_000) }
        } else {
            process.waitUntilExit()
        }
        let out = readBounded(outPipe)
        let err = readBounded(errPipe)
        return LibrarianProcessResult(
            launched: true,
            exitCode: process.terminationStatus,
            stdout: out,
            stderr: err,
            timedOut: timedOut
        )
    }

    private static func readBounded(_ pipe: Pipe) -> String {
        let data = (try? pipe.fileHandleForReading.read(upToCount: maxOutputBytes)) ?? Data()
        return String(data: data ?? Data(), encoding: .utf8) ?? ""
    }
}

/// TCC-backed capabilities. The probe never prompts; it reports the real state
/// so an op can say `not_determined` instead of pretending to work.
public enum LibrarianHostPermissions {
    public static func authorization(for capability: String) -> LibrarianAuthorizationState {
        switch capability {
        case "microphone", "speech":
            #if canImport(AVFoundation)
            switch AVCaptureDeviceAuthorizationStatusShim.microphone {
            case .authorized: return .authorized
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .unavailable
            }
            #else
            return .unavailable
            #endif
        case "screen_recording":
            // ScreenCaptureKit has no synchronous preflight without prompting;
            // the host marks this unavailable rather than guessing.
            return .notDetermined
        default:
            return .unavailable
        }
    }
}

#if canImport(AVFoundation)
import AVFoundation

enum AVCaptureDeviceAuthorizationStatusShim {
    static var microphone: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }
}
#endif

/// Workspace file enumeration shared by the index, repo map and analysis ops.
/// Deterministic ordering, bounded count, and a fixed ignore list so a repo the
/// size of RemoteCode cannot turn one op into an unbounded walk.
public enum LibrarianWorkspaceFiles {
    public static let ignoredDirectoryNames: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", "Pods", "DerivedData",
        ".next", ".venv", "venv", "__pycache__", ".cache", "dist", "build",
        ".sandbox-worktrees", ".sandbox-state", "xcuserdata", ".idea", ".vscode"
    ]
    public static let binaryExtensions: Set<String> = [
        "a", "o", "dylib", "so", "dSYM", "png", "jpg", "jpeg", "gif", "webp", "pdf",
        "zip", "gz", "tgz", "bz2", "xz", "7z", "jar", "class", "pyc", "wasm",
        "mp3", "mp4", "mov", "m4a", "wav", "aac", "dmg", "app", "ipa", "xcframework",
        "safetensors", "bin", "pack", "idx", "sqlite", "db", "woff", "woff2", "ttf", "otf"
    ]
    public static let maxFileBytes = 512 * 1024
    public static let defaultLimit = 2_000

    public static func isIgnoredDirectory(_ name: String) -> Bool {
        ignoredDirectoryNames.contains(name) || (name.hasPrefix(".") && name != ".")
    }

    public static func isBinaryPath(_ path: String) -> Bool {
        binaryExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Absolute paths under `root`, relative-sorted for determinism.
    public static func collect(
        root: String,
        limit: Int = defaultLimit,
        fileManager: FileManager = .default
    ) -> [String] {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var relative: [String] = []
        // The enumerator yields symlink-resolved paths (/var -> /private/var on
        // macOS) while callers hold the unresolved root. Compare resolved forms
        // and re-anchor on the caller's root so both read and display work.
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if isIgnoredDirectory(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            let name = url.lastPathComponent
            if isBinaryPath(name) { continue }
            if let size = values?.fileSize, size > maxFileBytes { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(resolvedRoot + "/") else { continue }
            relative.append(String(resolved.dropFirst(resolvedRoot.count + 1)))
            if relative.count >= limit { break }
        }
        let rootPrefix = rootURL.standardizedFileURL.path
        return relative
            .sorted()
            .map { "\(rootPrefix)/\($0)" }
    }
}

/// Bounded, deterministic lexical scoring shared by the workspace index and the
/// repo map when embeddings are unavailable.
public enum LibrarianLexicalRanker {
    public static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber || character == "_" || character == "." || character == "-" {
                current.append(character)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    public static func score(query: String, text: String) -> Double {
        let queryTerms = Array(Set(tokens(query)))
        guard !queryTerms.isEmpty else { return 0 }
        let documentTerms = tokens(text)
        guard !documentTerms.isEmpty else { return 0 }
        var counts: [String: Int] = [:]
        for term in documentTerms { counts[term, default: 0] += 1 }
        var score = 0.0
        for term in queryTerms {
            guard let count = counts[term], count > 0 else { continue }
            let idf = log(1.0 + Double(documentTerms.count) / Double(count))
            score += (Double(count) / Double(documentTerms.count)) * idf
        }
        return score
    }

    public static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for index in a.indices {
            dot += a[index] * b[index]
            na += a[index] * a[index]
            nb += b[index] * b[index]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}

/// Line windows used as chunks by the workspace index.
public struct LibrarianTextChunk: Sendable, Equatable {
    public let path: String
    public let startLine: Int
    public let endLine: Int
    public let text: String

    public init(path: String, startLine: Int, endLine: Int, text: String) {
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.text = text
    }
}

public enum LibrarianChunker {
    public static let defaultWindow = 40
    public static let defaultOverlap = 8
    public static let maxChunksPerFile = 40

    public static func chunks(
        path: String,
        text: String,
        window: Int = defaultWindow,
        overlap: Int = defaultOverlap,
        maxChunks: Int = maxChunksPerFile
    ) -> [LibrarianTextChunk] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return [] }
        let step = max(1, window - overlap)
        var out: [LibrarianTextChunk] = []
        var start = 0
        while start < lines.count && out.count < maxChunks {
            let end = min(lines.count, start + window)
            let body = lines[start..<end].joined(separator: "\n")
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(LibrarianTextChunk(path: path, startLine: start + 1, endLine: end, text: body))
            }
            if end == lines.count { break }
            start += step
        }
        return out
    }
}
