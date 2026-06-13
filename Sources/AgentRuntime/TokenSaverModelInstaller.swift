import CryptoKit
import Foundation

public enum TokenSaverModelInstallState: String, Codable, Sendable, Equatable {
    case missing
    case incomplete
    case installed
}

public enum TokenSaverModelDownloadPhase: String, Codable, Sendable, Equatable {
    case idle
    case preparing
    case downloading
    case paused
    case verifying
    case ready
    case failed
}

public struct TokenSaverModelDownloadState: Codable, Sendable, Equatable {
    public let phase: TokenSaverModelDownloadPhase
    public let downloadedBytes: Int64
    public let expectedBytes: Int64?
    public let statusText: String
    public let errorMessage: String?

    public init(
        phase: TokenSaverModelDownloadPhase,
        downloadedBytes: Int64 = 0,
        expectedBytes: Int64? = nil,
        statusText: String,
        errorMessage: String? = nil
    ) {
        self.phase = phase
        self.downloadedBytes = max(0, downloadedBytes)
        self.expectedBytes = expectedBytes.map { max(0, $0) }
        self.statusText = statusText
        self.errorMessage = errorMessage
    }

    public var fractionCompleted: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        let fraction = Double(downloadedBytes) / Double(expectedBytes)
        guard fraction.isFinite else { return nil }
        return min(max(fraction, 0), 1)
    }

    public static let idle = TokenSaverModelDownloadState(phase: .idle, statusText: "Not started")
    public static let ready = TokenSaverModelDownloadState(phase: .ready, statusText: "Ready")

    public static func required(reason: String?) -> TokenSaverModelDownloadState {
        TokenSaverModelDownloadState(
            phase: .preparing,
            statusText: "Preparing model download",
            errorMessage: reason
        )
    }
}

public struct TokenSaverModelFile: Codable, Sendable, Equatable {
    public let relativePath: String
    public let sha256: String
    public let sizeBytes: Int64

    public init(relativePath: String, sha256: String, sizeBytes: Int64) {
        self.relativePath = relativePath
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }
}

public struct TokenSaverModelManifest: Codable, Sendable, Equatable {
    public static let approvedModelID = "samuelfaj/distill-1.7B-4bit-MLX"
    public static let approvedModelURL = "https://huggingface.co/samuelfaj/distill-1.7B-4bit-MLX"
    public static let approvedRuntime = "mlx"

    public let modelID: String
    public let modelURL: String
    public let revision: String
    public let runtime: String
    public let files: [TokenSaverModelFile]

    public init(
        modelID: String = Self.approvedModelID,
        modelURL: String = Self.approvedModelURL,
        revision: String,
        runtime: String = Self.approvedRuntime,
        files: [TokenSaverModelFile]
    ) {
        self.modelID = modelID
        self.modelURL = modelURL
        self.revision = revision
        self.runtime = runtime
        self.files = files
    }

    public var isApprovedModel: Bool {
        modelID == Self.approvedModelID && modelURL == Self.approvedModelURL && runtime == Self.approvedRuntime
    }

    public static var approvedModelAPIPayloadURL: URL {
        URL(string: "https://huggingface.co/api/models/\(approvedModelID)")!
    }
}

public struct TokenSaverModelValidation: Sendable, Equatable {
    public let state: TokenSaverModelInstallState
    public let reason: String?

    public init(state: TokenSaverModelInstallState, reason: String?) {
        self.state = state
        self.reason = reason
    }

    public static let installed = TokenSaverModelValidation(state: .installed, reason: nil)
}

// Per-file record written to the validation cache after a successful full SHA-256 verify.
// Invariant: a cache hit (size AND mtime both match) guarantees the file content was
// SHA-256-verified at the time of the last write. Any change to size OR mtime invalidates
// the cache entry and forces a full re-hash.
// Accepted gap: a tampered file whose attacker also preserves the exact byte-count AND
// filesystem mtime will pass the fast-path. The manifest SHA-256 remains the authority and
// is applied on every launch whenever size or mtime drifts.
public struct ModelValidationCacheEntry: Codable, Sendable, Equatable {
    public let relativePath: String
    public let expectedSHA256: String
    public let sizeBytes: Int64
    public let modificationDate: Date

    public init(relativePath: String, expectedSHA256: String, sizeBytes: Int64, modificationDate: Date) {
        self.relativePath = relativePath
        self.expectedSHA256 = expectedSHA256
        self.sizeBytes = sizeBytes
        self.modificationDate = modificationDate
    }
}

public final class TokenSaverModelInstaller: @unchecked Sendable {
    public let appSupportDirectory: URL
    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(appSupportDirectory: URL, fileManager: FileManager = .default) {
        self.appSupportDirectory = appSupportDirectory
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public var distillDirectory: URL {
        appSupportDirectory.appendingPathComponent("Distill", isDirectory: true)
    }

    public var manifestURL: URL {
        distillDirectory.appendingPathComponent("DistillModelManifest.json")
    }

    public var validationCacheURL: URL {
        distillDirectory.appendingPathComponent("DistillValidationCache.json")
    }

    public func modelStorageDirectory(revision: String) -> URL {
        distillDirectory
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(Self.safePathComponent(TokenSaverModelManifest.approvedModelID), isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
    }

    public func loadManifest() -> TokenSaverModelManifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? decoder.decode(TokenSaverModelManifest.self, from: data)
    }

    public func writeManifest(_ manifest: TokenSaverModelManifest) throws {
        try fileManager.createDirectory(at: distillDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    // Returns the validation cache keyed by relativePath, or empty dict on missing/corrupt cache.
    func loadValidationCache() -> [String: ModelValidationCacheEntry] {
        guard let data = try? Data(contentsOf: validationCacheURL),
              let entries = try? decoder.decode([ModelValidationCacheEntry].self, from: data) else {
            return [:]
        }
        return Dictionary(entries.map { ($0.relativePath, $0) }, uniquingKeysWith: { $1 })
    }

    // Atomically writes the cache. Silently drops write errors -- the cache is advisory only.
    func writeValidationCache(_ entries: [ModelValidationCacheEntry]) {
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: validationCacheURL, options: .atomic)
    }

    // Pure helper: returns true when a full SHA-256 re-hash is required.
    // Re-hashes when the cache entry is absent or when either size or mtime differs.
    // Returns false only when both size and mtime match the cached record.
    public static func needsRehash(
        cached: (size: Int64, mtime: Date)?,
        current: (size: Int64, mtime: Date)
    ) -> Bool {
        guard let cached else { return true }
        return cached.size != current.size || cached.mtime != current.mtime
    }

    public func validateInstalledModel() -> TokenSaverModelValidation {
        guard let manifest = loadManifest() else {
            return TokenSaverModelValidation(state: .missing, reason: "manifest missing")
        }
        guard manifest.isApprovedModel else {
            return TokenSaverModelValidation(state: .incomplete, reason: "manifest does not reference approved MLX model")
        }
        guard !manifest.files.isEmpty else {
            return TokenSaverModelValidation(state: .incomplete, reason: "manifest has no files")
        }

        var cache = loadValidationCache()
        var cacheUpdated = false

        for file in manifest.files {
            let url = distillDirectory.appendingPathComponent(file.relativePath)
            guard fileManager.fileExists(atPath: url.path) else {
                return TokenSaverModelValidation(state: .incomplete, reason: "missing file \(file.relativePath)")
            }
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  let sizeNum = attrs[.size] as? NSNumber,
                  sizeNum.int64Value == file.sizeBytes else {
                return TokenSaverModelValidation(state: .incomplete, reason: "size mismatch \(file.relativePath)")
            }
            let currentSize = sizeNum.int64Value
            let currentMtime = (attrs[.modificationDate] as? Date) ?? .distantPast

            let entry = cache[file.relativePath]
            let cached: (size: Int64, mtime: Date)? = entry.map { ($0.sizeBytes, $0.modificationDate) }

            if Self.needsRehash(cached: cached, current: (size: currentSize, mtime: currentMtime)) {
                guard (try? Self.sha256Hex(url: url)) == file.sha256.lowercased() else {
                    return TokenSaverModelValidation(state: .incomplete, reason: "checksum mismatch \(file.relativePath)")
                }
                cache[file.relativePath] = ModelValidationCacheEntry(
                    relativePath: file.relativePath,
                    expectedSHA256: file.sha256.lowercased(),
                    sizeBytes: currentSize,
                    modificationDate: currentMtime
                )
                cacheUpdated = true
            }
        }

        if cacheUpdated {
            writeValidationCache(Array(cache.values))
        }

        return .installed
    }

    public static func sha256Hex(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func safePathComponent(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: ":", with: "_")
    }
}

public enum TokenSaverModelDownloadError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidModelResponse
    case noModelFiles
    case invalidDownloadURL(String)
    case httpStatus(Int, String)
    case validationFailed(String?)

    public var description: String {
        switch self {
        case .invalidModelResponse:
            return "invalid Hugging Face model response"
        case .noModelFiles:
            return "Hugging Face model response has no downloadable files"
        case .invalidDownloadURL(let path):
            return "invalid Hugging Face file URL \(path)"
        case .httpStatus(let status, let path):
            return "Hugging Face download failed \(status) for \(path)"
        case .validationFailed(let reason):
            return reason ?? "downloaded model failed validation"
        }
    }
}

public struct TokenSaverRemoteModelFile: Sendable, Equatable {
    public let relativePath: String
    public let downloadURL: URL

    public init(relativePath: String, downloadURL: URL) {
        self.relativePath = relativePath
        self.downloadURL = downloadURL
    }
}

public struct TokenSaverRemoteModelSnapshot: Sendable, Equatable {
    public let revision: String
    public let files: [TokenSaverRemoteModelFile]

    public init(revision: String, files: [TokenSaverRemoteModelFile]) {
        self.revision = revision
        self.files = files
    }
}

public typealias TokenSaverModelDownloadProgress = @Sendable (TokenSaverModelDownloadState) -> Void

public final class TokenSaverModelDownloader: @unchecked Sendable {
    private struct HuggingFaceModelResponse: Decodable {
        struct Sibling: Decodable {
            let rfilename: String
        }

        let id: String
        let sha: String
        let siblings: [Sibling]
    }

    private let installer: TokenSaverModelInstaller
    private let session: URLSession
    private let fileManager: FileManager
    private let decoder = JSONDecoder()

    public init(
        installer: TokenSaverModelInstaller,
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.installer = installer
        self.session = session
        self.fileManager = fileManager
    }

    public func downloadApprovedModel(
        progress: TokenSaverModelDownloadProgress? = nil
    ) async throws -> TokenSaverModelManifest {
        progress?(TokenSaverModelDownloadState(
            phase: .preparing,
            statusText: "Fetching Hugging Face model manifest"
        ))
        let snapshot = try await fetchApprovedModelSnapshot()
        guard !snapshot.files.isEmpty else { throw TokenSaverModelDownloadError.noModelFiles }

        var manifestFiles: [TokenSaverModelFile] = []
        for (index, file) in snapshot.files.enumerated() {
            try Task.checkCancellation()
            progress?(TokenSaverModelDownloadState(
                phase: .downloading,
                statusText: "Downloading \(file.relativePath) (\(index + 1)/\(snapshot.files.count))"
            ))
            let localFile = try await downloadFile(
                file,
                revision: snapshot.revision,
                progress: progress
            )
            manifestFiles.append(localFile)
        }

        progress?(TokenSaverModelDownloadState(
            phase: .verifying,
            statusText: "Verifying downloaded model"
        ))
        let manifest = TokenSaverModelManifest(revision: snapshot.revision, files: manifestFiles)
        try installer.writeManifest(manifest)
        let validation = installer.validateInstalledModel()
        guard validation.state == .installed else {
            throw TokenSaverModelDownloadError.validationFailed(validation.reason)
        }
        progress?(.ready)
        return manifest
    }

    public func fetchApprovedModelSnapshot() async throws -> TokenSaverRemoteModelSnapshot {
        let (data, response) = try await session.data(from: TokenSaverModelManifest.approvedModelAPIPayloadURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TokenSaverModelDownloadError.httpStatus(http.statusCode, "api/models")
        }
        let decoded = try decoder.decode(HuggingFaceModelResponse.self, from: data)
        guard decoded.id == TokenSaverModelManifest.approvedModelID else {
            throw TokenSaverModelDownloadError.invalidModelResponse
        }
        let files = try decoded.siblings
            .map(\.rfilename)
            .filter(Self.shouldDownloadFile)
            .sorted()
            .map { path in
                TokenSaverRemoteModelFile(
                    relativePath: path,
                    downloadURL: try Self.downloadURL(revision: decoded.sha, relativePath: path)
                )
            }
        return TokenSaverRemoteModelSnapshot(revision: decoded.sha, files: files)
    }

    private func downloadFile(
        _ file: TokenSaverRemoteModelFile,
        revision: String,
        progress: TokenSaverModelDownloadProgress?
    ) async throws -> TokenSaverModelFile {
        let relativeStoragePath = Self.localRelativePath(revision: revision, remotePath: file.relativePath)
        let destination = installer.distillDirectory.appendingPathComponent(relativeStoragePath)
        if fileManager.fileExists(atPath: destination.path) {
            return try manifestFile(relativePath: relativeStoragePath, url: destination)
        }

        let partial = destination.appendingPathExtension("partial")
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await downloadBody(file: file, partial: partial, progress: progress)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: partial, to: destination)
        return try manifestFile(relativePath: relativeStoragePath, url: destination)
    }

    /// Minimum I/O unit for the download path. Exposed as a pure seam so tests
    /// can assert that no future regression reintroduces per-byte reads.
    /// The actual download uses URLSession.download(for:) which writes to a
    /// system-managed temp file in a single kernel operation, so this constant
    /// is not used at runtime — it documents the historical 1 MB flush boundary
    /// and enforces >= 1 MB as the minimum acceptable chunk size.
    static let downloadChunkSize: Int = 1024 * 1024

    func downloadBody(
        file: TokenSaverRemoteModelFile,
        partial: URL,
        progress: TokenSaverModelDownloadProgress?
    ) async throws {
        var resumeOffset = fileSize(at: partial)
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: file.downloadURL)
            if resumeOffset > 0 {
                request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
            }
            // Use download(for:) instead of bytes(for:) to avoid per-byte async
            // iteration overhead. URLSession writes the response body to a
            // temp file via a single kernel-managed transfer, eliminating the
            // O(n) async yields that dominated throughput on a ~1 GB model file.
            let (tempURL, response) = try await session.download(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 200
            guard (200..<300).contains(status) else {
                try? fileManager.removeItem(at: tempURL)
                throw TokenSaverModelDownloadError.httpStatus(status, file.relativePath)
            }
            if resumeOffset > 0 && status == 200 {
                // Server ignored our Range header; restart from zero.
                try? fileManager.removeItem(at: partial)
                try? fileManager.removeItem(at: tempURL)
                resumeOffset = 0
                continue
            }

            let append = resumeOffset > 0 && status == 206
            let contentLength = response.expectedContentLength
            let expectedBytes = contentLength > 0 ? resumeOffset + contentLength : nil
            let downloadedLength = fileSize(at: tempURL)

            if append {
                // Append the range response to the existing partial file.
                if !fileManager.fileExists(atPath: partial.path) {
                    fileManager.createFile(atPath: partial.path, contents: nil)
                }
                let destHandle = try FileHandle(forWritingTo: partial)
                defer { try? destHandle.close() }
                try destHandle.seekToEnd()
                let srcHandle = try FileHandle(forReadingFrom: tempURL)
                defer { try? srcHandle.close() }
                try srcHandle.seek(toOffset: 0)
                while true {
                    guard let chunk = try srcHandle.read(upToCount: TokenSaverModelDownloader.downloadChunkSize),
                          !chunk.isEmpty else { break }
                    try destHandle.write(contentsOf: chunk)
                }
                try? fileManager.removeItem(at: tempURL)
            } else {
                // Full response: move the temp file into place.
                try? fileManager.removeItem(at: partial)
                try fileManager.moveItem(at: tempURL, to: partial)
            }

            let downloaded = resumeOffset + downloadedLength
            progress?(TokenSaverModelDownloadState(
                phase: .downloading,
                downloadedBytes: downloaded,
                expectedBytes: expectedBytes,
                statusText: "Downloaded \(file.relativePath)"
            ))
            return
        }
    }

    private func manifestFile(relativePath: String, url: URL) throws -> TokenSaverModelFile {
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let checksum = try TokenSaverModelInstaller.sha256Hex(url: url)
        return TokenSaverModelFile(relativePath: relativePath, sha256: checksum, sizeBytes: size)
    }

    private func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return max(0, size.int64Value)
    }

    private static func shouldDownloadFile(_ path: String) -> Bool {
        !path.hasPrefix(".")
    }

    private static func downloadURL(revision: String, relativePath: String) throws -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "#?")
        guard let encodedPath = relativePath.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "\(TokenSaverModelManifest.approvedModelURL)/resolve/\(revision)/\(encodedPath)") else {
            throw TokenSaverModelDownloadError.invalidDownloadURL(relativePath)
        }
        return url
    }

    private static func localRelativePath(revision: String, remotePath: String) -> String {
        [
            "Models",
            TokenSaverModelInstaller.safePathComponent(TokenSaverModelManifest.approvedModelID),
            revision,
            remotePath
        ].joined(separator: "/")
    }
}
