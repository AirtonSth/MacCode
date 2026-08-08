import CryptoKit
import Foundation
import CoreModel

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
    public static let approvedModelID = TokenSaverApprovedModels.defaultModel.id
    public static let approvedModelURL = TokenSaverApprovedModels.defaultModel.url
    public static let approvedRuntime = TokenSaverApprovedModels.defaultModel.runtime

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
        TokenSaverApprovedModels.approved(id: modelID, url: modelURL, runtime: runtime) != nil
    }

    public static var approvedModelAPIPayloadURL: URL {
        TokenSaverApprovedModels.defaultModel.apiPayloadURL
    }

    public static func approvedModelAPIPayloadURL(for model: TokenSaverApprovedModel) -> URL {
        model.apiPayloadURL
    }
}

public struct TokenSaverRequiredModelInstallManifest: Codable, Sendable, Equatable {
    public let modelID: String
    public let modelURL: String
    public let revision: String
    public let runtime: String
    public let role: String
    public let files: [TokenSaverModelFile]

    public init(
        modelID: String,
        modelURL: String,
        revision: String,
        runtime: String,
        role: String,
        files: [TokenSaverModelFile]
    ) {
        self.modelID = modelID
        self.modelURL = modelURL
        self.revision = revision
        self.runtime = runtime
        self.role = role
        self.files = files
    }

    public init(model: TokenSaverRequiredModel, files: [TokenSaverModelFile]) {
        self.init(
            modelID: model.id,
            modelURL: model.url,
            revision: model.revision,
            runtime: model.runtime,
            role: model.role,
            files: files
        )
    }

    public func matches(_ required: TokenSaverRequiredModel) -> Bool {
        modelID == required.id &&
            modelURL == required.url &&
            revision == required.revision &&
            runtime == required.runtime &&
            role == required.role
    }
}

public struct TokenSaverRequiredModelsInstallManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let models: [TokenSaverRequiredModelInstallManifest]

    public init(schemaVersion: Int = 1, models: [TokenSaverRequiredModelInstallManifest]) {
        self.schemaVersion = schemaVersion
        self.models = models
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
    public let approvedModel: TokenSaverApprovedModel
    public let requiredAuxiliaryModels: [TokenSaverRequiredModel]
    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(
        appSupportDirectory: URL,
        fileManager: FileManager = .default,
        approvedModel: TokenSaverApprovedModel = TokenSaverApprovedModels.selected(),
        requiredAuxiliaryModels: [TokenSaverRequiredModel] = TokenSaverRequiredModels.activationBundle
    ) {
        self.appSupportDirectory = appSupportDirectory
        self.approvedModel = approvedModel
        self.requiredAuxiliaryModels = requiredAuxiliaryModels
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public var distillDirectory: URL {
        appSupportDirectory.appendingPathComponent("Distill", isDirectory: true)
    }

    public var manifestURL: URL {
        distillDirectory.appendingPathComponent("DistillModelManifest.json")
    }

    public var encoderManifestURL: URL {
        distillDirectory.appendingPathComponent("DistillEncoderManifest.json")
    }

    public var validationCacheURL: URL {
        distillDirectory.appendingPathComponent("DistillValidationCache.json")
    }

    public func modelStorageDirectory(revision: String) -> URL {
        modelStorageDirectory(modelID: approvedModel.id, revision: revision)
    }

    public func modelStorageDirectory(modelID: String, revision: String) -> URL {
        distillDirectory
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(Self.safePathComponent(modelID), isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
    }

    /// True when a model's weights are already on disk (some revision dir holds a `*.safetensors`
    /// plus `config.json`), independent of which model the ACTIVE manifest references. Lets startup
    /// ACTIVATE an already-downloaded preferred model without ever starting a multi-GB download
    /// (that stays toggle/UI-driven). Defaults to the memory-selected model (e.g. E4B on ≥16 GB).
    public func modelArtifactsPresent(model: TokenSaverApprovedModel = TokenSaverApprovedModels.selected()) -> Bool {
        let base = distillDirectory
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(Self.safePathComponent(model.id), isDirectory: true)
        guard let revisions = try? fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return false
        }
        return revisions.contains { revisionDir in
            let files = (try? fileManager.contentsOfDirectory(atPath: revisionDir.path)) ?? []
            return files.contains { $0.hasSuffix(".safetensors") } && files.contains("config.json")
        }
    }

    public func encoderStorageDirectory(modelID: String, revision: String) -> URL {
        distillDirectory
            .appendingPathComponent("Encoders", isDirectory: true)
            .appendingPathComponent(Self.safePathComponent(modelID), isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
    }

    public func loadManifest() -> TokenSaverModelManifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? decoder.decode(TokenSaverModelManifest.self, from: data)
    }

    public func loadEncoderManifest() -> TokenSaverRequiredModelsInstallManifest? {
        guard let data = try? Data(contentsOf: encoderManifestURL) else { return nil }
        return try? decoder.decode(TokenSaverRequiredModelsInstallManifest.self, from: data)
    }

    public func writeManifest(_ manifest: TokenSaverModelManifest) throws {
        try fileManager.createDirectory(at: distillDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    public func writeEncoderManifest(_ manifest: TokenSaverRequiredModelsInstallManifest) throws {
        try fileManager.createDirectory(at: distillDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(manifest)
        try data.write(to: encoderManifestURL, options: .atomic)
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

    public func validateInstalledModel(requireSelectedModel: Bool = false) -> TokenSaverModelValidation {
        guard let manifest = loadManifest() else {
            return TokenSaverModelValidation(state: .missing, reason: "manifest missing")
        }
        guard manifest.isApprovedModel else {
            return TokenSaverModelValidation(state: .incomplete, reason: "manifest does not reference approved MLX model")
        }
        if requireSelectedModel, manifest.modelID != approvedModel.id {
            return TokenSaverModelValidation(
                state: .missing,
                reason: "selected model \(approvedModel.id) not installed; installed \(manifest.modelID)"
            )
        }
        guard !manifest.files.isEmpty else {
            return TokenSaverModelValidation(state: .incomplete, reason: "manifest has no files")
        }

        return validateFiles(manifest.files, emptyReason: "manifest has no files")
    }

    public func validateInstalledTokenSaverModels(requireSelectedModel: Bool = false) -> TokenSaverModelValidation {
        let llmValidation = validateInstalledModel(requireSelectedModel: requireSelectedModel)
        guard llmValidation.state == .installed else { return llmValidation }
        return validateInstalledEncoderModels()
    }

    public func validateInstalledEncoderModels() -> TokenSaverModelValidation {
        guard !requiredAuxiliaryModels.isEmpty else { return .installed }
        guard let manifest = loadEncoderManifest() else {
            return TokenSaverModelValidation(state: .missing, reason: "encoder manifest missing")
        }
        guard manifest.schemaVersion == 1 else {
            return TokenSaverModelValidation(state: .incomplete, reason: "unsupported encoder manifest schema")
        }

        let installedByID = Dictionary(manifest.models.map { ($0.modelID, $0) }, uniquingKeysWith: { $1 })
        var files: [TokenSaverModelFile] = []
        for required in requiredAuxiliaryModels {
            guard let installed = installedByID[required.id] else {
                return TokenSaverModelValidation(state: .missing, reason: "required encoder model \(required.id) missing")
            }
            guard installed.matches(required) else {
                return TokenSaverModelValidation(state: .incomplete, reason: "required encoder model \(required.id) metadata mismatch")
            }
            guard !installed.files.isEmpty else {
                return TokenSaverModelValidation(state: .incomplete, reason: "required encoder model \(required.id) has no files")
            }
            files.append(contentsOf: installed.files)
        }

        return validateFiles(files, emptyReason: "encoder manifest has no files")
    }

    private func validateFiles(
        _ files: [TokenSaverModelFile],
        emptyReason: String
    ) -> TokenSaverModelValidation {
        guard !files.isEmpty else {
            return TokenSaverModelValidation(state: .incomplete, reason: emptyReason)
        }

        var cache = loadValidationCache()
        var cacheUpdated = false

        for file in files {
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

    /// PERF: nibble table instead of per-byte `String(format:)` so multi-MB/GB
    /// model file verify finalizes without 32 formatter calls; CryptoKit-identical
    /// lowercase hex for install validation caches.
    private static let hexNibbleAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hexNibbleAlphabet[Int(byte >> 4)])
            out.append(hexNibbleAlphabet[Int(byte & 0x0f)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
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

        return hexDigest(hasher.finalize())
    }

    public static func safePathComponent(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: ":", with: "_")
    }

    // MARK: - Aggregate download UX seams

    /// Parses the Hugging Face `?blobs=true` JSON response and sums all blob
    /// sizes. Returns nil when the data cannot be decoded as a valid blob list.
    ///
    /// The `?blobs=true` query parameter asks the HF API to return the actual
    /// blob object for each sibling instead of just the filename, giving us
    /// the precise file size before starting any download.
    ///
    /// Expected JSON shape (array at top level or nested under `siblings`):
    ///   [{"rfilename":"config.json","size":1234}, ...]
    /// or the full model response with `siblings` having a `size` field when
    /// `?blobs=true` is appended.
    ///
    /// WHY static nonisolated: callers live on arbitrary actors; the parse is
    /// pure computation with no I/O, so it can run anywhere.
    public static func totalSizeFromBlobs(_ data: Data) -> Int64? {
        // HF ?blobs=true response: array of objects with "size" (Int64) fields.
        // We accept both top-level arrays and the `siblings` key of a model object.
        struct BlobEntry: Decodable {
            let size: Int64?
        }
        struct ModelWithSiblings: Decodable {
            let siblings: [BlobEntry]
        }

        let decoder = JSONDecoder()

        // Try top-level array first.
        if let entries = try? decoder.decode([BlobEntry].self, from: data) {
            let total = entries.compactMap(\.size).reduce(0, +)
            return total > 0 ? total : nil
        }
        // Try `siblings` key (full model object with ?blobs=true).
        if let model = try? decoder.decode(ModelWithSiblings.self, from: data) {
            let total = model.siblings.compactMap(\.size).reduce(0, +)
            return total > 0 ? total : nil
        }
        return nil
    }

    /// URL to query with `?blobs=true` to pre-fetch aggregate file sizes before
    /// the download begins. Adding the query parameter makes HF embed blob size
    /// in each sibling entry, eliminating per-file HEAD requests.
    public static var approvedModelBlobsURL: URL {
        URL(string: "\(TokenSaverModelManifest.approvedModelAPIPayloadURL.absoluteString)?blobs=true")!
    }

    /// Pure predicate: true when `free` bytes is at least `required + margin`.
    ///
    /// WHY a static seam: the disk-space check must be testable without real
    /// FileManager I/O. The margin absorbs the partial-download scratch space and
    /// the post-download manifest + cache writes.
    ///
    /// The margin is 200 MB — the same constant used in SidebarViewModel for the
    /// pre-download confirm dialog, kept in sync here so both paths agree.
    public static let diskSpaceMarginBytes: Int64 = 200_000_000

    public static func hasSufficientDiskSpace(required: Int64, free: Int64) -> Bool {
        free >= required + diskSpaceMarginBytes
    }

    /// Pure function: bytes-per-second from a (bytesDelta, secondsDelta) sample.
    ///
    /// Returns 0 when `secondsDelta` is not strictly positive to avoid division
    /// by zero or negative speed from clock skew. NaN/inf cannot be returned.
    ///
    /// WHY separate from the caller: the SidebarViewModel speed-sample path and
    /// any future background download coordinator must both agree on this guard;
    /// a shared static seam prevents each caller from re-implementing the guard
    /// differently (one guard vs three divergent guards).
    public static func downloadSpeed(bytesDelta: Int64, secondsDelta: Double) -> Double {
        guard secondsDelta > 0, bytesDelta >= 0 else { return 0 }
        let speed = Double(bytesDelta) / secondsDelta
        return speed.isFinite ? speed : 0
    }

    /// Pure function: seconds remaining given bytes left and current speed.
    ///
    /// Returns nil when `speed` is not strictly positive (no estimate possible)
    /// or when `remaining` is non-positive (already done). Never returns negative
    /// or non-finite values.
    ///
    /// WHY separate: ETA computation appears in the aggregate-progress callback
    /// and in formatting helpers; a shared static seam means a single test suite
    /// covers every caller.
    public static func eta(remaining: Int64, speed: Double) -> Int? {
        guard speed > 0, remaining > 0 else { return remaining <= 0 ? 0 : nil }
        let seconds = Double(remaining) / speed
        guard seconds.isFinite else { return nil }
        return Int(seconds.rounded())
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

public enum TokenSaverHuggingFaceAuth {
    public static func authorizationHeader(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for key in ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACE_TOKEN"] {
            guard let token = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else {
                continue
            }
            return "Bearer \(token)"
        }
        return nil
    }
}

public final class TokenSaverModelDownloader: @unchecked Sendable {
    private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let relativePath: String
        private let resumeOffset: Int64
        private let stagingDirectory: URL
        private let fileManager: FileManager
        private let progress: TokenSaverModelDownloadProgress?
        private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
        private var task: URLSessionDownloadTask?
        private var result: Result<(URL, URLResponse), Error>?

        init(
            relativePath: String,
            resumeOffset: Int64,
            stagingDirectory: URL,
            fileManager: FileManager,
            progress: TokenSaverModelDownloadProgress?
        ) {
            self.relativePath = relativePath
            self.resumeOffset = resumeOffset
            self.stagingDirectory = stagingDirectory
            self.fileManager = fileManager
            self.progress = progress
        }

        func start(task: URLSessionDownloadTask, continuation: CheckedContinuation<(URL, URLResponse), Error>) {
            lock.lock()
            self.task = task
            self.continuation = continuation
            lock.unlock()
            task.resume()
        }

        func cancel() {
            lock.lock()
            let task = self.task
            self.task = nil
            lock.unlock()
            task?.cancel()
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard let progress else { return }
            progress(TokenSaverModelDownloader.currentFileDownloadProgressState(
                relativePath: relativePath,
                resumeOffset: resumeOffset,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite
            ))
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            let stagedURL = stagingDirectory
                .appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: false)
            do {
                try? fileManager.removeItem(at: stagedURL)
                try fileManager.moveItem(at: location, to: stagedURL)
                guard let response = downloadTask.response else {
                    throw URLError(.badServerResponse)
                }
                setResult(.success((stagedURL, response)))
            } catch {
                setResult(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                complete(.failure(error))
                return
            }
            lock.lock()
            let result = self.result
            lock.unlock()
            complete(result ?? .failure(URLError(.badServerResponse)))
        }

        private func setResult(_ result: Result<(URL, URLResponse), Error>) {
            lock.lock()
            self.result = result
            lock.unlock()
        }

        private func complete(_ result: Result<(URL, URLResponse), Error>) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            self.task = nil
            lock.unlock()

            guard let continuation else { return }
            switch result {
            case .success(let value):
                continuation.resume(returning: value)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private struct HuggingFaceModelResponse: Decodable {
        struct Sibling: Decodable {
            let rfilename: String
        }

        let id: String
        let sha: String
        let siblings: [Sibling]
    }

    private struct RemoteModelSource: Sendable {
        enum ArtifactKind: Sendable, Equatable {
            case llm
            case auxiliary
        }

        let id: String
        let url: String
        let apiPayloadURL: URL
        let expectedRevision: String?
        let artifactKind: ArtifactKind
    }

    private let installer: TokenSaverModelInstaller
    private let session: URLSession
    private let fileManager: FileManager
    private let authorizationHeader: String?
    private let decoder = JSONDecoder()

    public init(
        installer: TokenSaverModelInstaller,
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        authorizationHeader: String? = TokenSaverHuggingFaceAuth.authorizationHeader()
    ) {
        self.installer = installer
        self.session = session
        self.fileManager = fileManager
        let trimmedAuthorization = authorizationHeader?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.authorizationHeader = trimmedAuthorization.isEmpty ? nil : trimmedAuthorization
    }

    public func downloadApprovedModel(
        progress: TokenSaverModelDownloadProgress? = nil
    ) async throws -> TokenSaverModelManifest {
        try await downloadApprovedModel(progress: progress, emitReady: true)
    }

    public func downloadRequiredModels(
        progress: TokenSaverModelDownloadProgress? = nil
    ) async throws -> TokenSaverModelManifest {
        let manifest = try await downloadApprovedModel(progress: progress, emitReady: false)
        _ = try await downloadRequiredEncoderModels(progress: progress)
        let validation = installer.validateInstalledTokenSaverModels(requireSelectedModel: true)
        guard validation.state == .installed else {
            throw TokenSaverModelDownloadError.validationFailed(validation.reason)
        }
        progress?(.ready)
        return manifest
    }

    public func downloadRequiredEncoderModels(
        progress: TokenSaverModelDownloadProgress? = nil
    ) async throws -> TokenSaverRequiredModelsInstallManifest {
        guard !installer.requiredAuxiliaryModels.isEmpty else {
            let manifest = TokenSaverRequiredModelsInstallManifest(models: [])
            try installer.writeEncoderManifest(manifest)
            return manifest
        }

        var installedModels: [TokenSaverRequiredModelInstallManifest] = []
        for (modelIndex, model) in installer.requiredAuxiliaryModels.enumerated() {
            guard model.hasImmutableRevision else {
                throw TokenSaverModelDownloadError.invalidModelResponse
            }
            progress?(TokenSaverModelDownloadState(
                phase: .preparing,
                statusText: "Fetching \(model.id) manifest (\(modelIndex + 1)/\(installer.requiredAuxiliaryModels.count))"
            ))
            let snapshot = try await fetchRequiredModelSnapshot(model)
            guard !snapshot.files.isEmpty else { throw TokenSaverModelDownloadError.noModelFiles }

            var manifestFiles: [TokenSaverModelFile] = []
            for (fileIndex, file) in snapshot.files.enumerated() {
                try Task.checkCancellation()
                progress?(TokenSaverModelDownloadState(
                    phase: .downloading,
                    statusText: "Downloading \(model.id)/\(file.relativePath) (\(fileIndex + 1)/\(snapshot.files.count))"
                ))
                let localFile = try await downloadFile(
                    file,
                    modelID: model.id,
                    revision: snapshot.revision,
                    storageRoot: "Encoders",
                    progress: progress
                )
                manifestFiles.append(localFile)
            }
            installedModels.append(TokenSaverRequiredModelInstallManifest(model: model, files: manifestFiles))
        }

        progress?(TokenSaverModelDownloadState(
            phase: .verifying,
            statusText: "Verifying downloaded encoder models"
        ))
        let manifest = TokenSaverRequiredModelsInstallManifest(models: installedModels)
        try installer.writeEncoderManifest(manifest)
        let validation = installer.validateInstalledEncoderModels()
        guard validation.state == .installed else {
            throw TokenSaverModelDownloadError.validationFailed(validation.reason)
        }
        return manifest
    }

    private func downloadApprovedModel(
        progress: TokenSaverModelDownloadProgress?,
        emitReady: Bool
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
                modelID: installer.approvedModel.id,
                revision: snapshot.revision,
                storageRoot: "Models",
                progress: progress
            )
            manifestFiles.append(localFile)
        }

        progress?(TokenSaverModelDownloadState(
            phase: .verifying,
            statusText: "Verifying downloaded model"
        ))
        let manifest = TokenSaverModelManifest(
            modelID: installer.approvedModel.id,
            modelURL: installer.approvedModel.url,
            revision: snapshot.revision,
            runtime: installer.approvedModel.runtime,
            files: manifestFiles
        )
        try installer.writeManifest(manifest)
        let validation = installer.validateInstalledModel()
        guard validation.state == .installed else {
            throw TokenSaverModelDownloadError.validationFailed(validation.reason)
        }
        if emitReady {
            progress?(.ready)
        }
        return manifest
    }

    public func fetchApprovedModelSnapshot() async throws -> TokenSaverRemoteModelSnapshot {
        try await fetchModelSnapshot(RemoteModelSource(
            id: installer.approvedModel.id,
            url: installer.approvedModel.url,
            apiPayloadURL: TokenSaverModelManifest.approvedModelAPIPayloadURL(for: installer.approvedModel),
            expectedRevision: nil,
            artifactKind: .llm
        ))
    }

    public func fetchRequiredModelSnapshot(_ model: TokenSaverRequiredModel) async throws -> TokenSaverRemoteModelSnapshot {
        try await fetchModelSnapshot(RemoteModelSource(
            id: model.id,
            url: model.url,
            apiPayloadURL: model.apiPayloadURL,
            expectedRevision: model.revision,
            artifactKind: .auxiliary
        ))
    }

    private func fetchModelSnapshot(_ source: RemoteModelSource) async throws -> TokenSaverRemoteModelSnapshot {
        let request = authorizedRequest(url: source.apiPayloadURL)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TokenSaverModelDownloadError.httpStatus(http.statusCode, "api/models")
        }
        let decoded = try decoder.decode(HuggingFaceModelResponse.self, from: data)
        guard decoded.id == source.id else {
            throw TokenSaverModelDownloadError.invalidModelResponse
        }
        let revision = source.expectedRevision ?? decoded.sha
        if let expectedRevision = source.expectedRevision, decoded.sha != expectedRevision {
            throw TokenSaverModelDownloadError.invalidModelResponse
        }
        let files = try decoded.siblings
            .map(\.rfilename)
            .filter { Self.shouldDownloadFile($0, artifactKind: source.artifactKind) }
            .sorted()
            .map { path in
                TokenSaverRemoteModelFile(
                    relativePath: path,
                    downloadURL: try Self.downloadURL(modelURL: source.url, revision: revision, relativePath: path)
                )
            }
        return TokenSaverRemoteModelSnapshot(revision: revision, files: files)
    }

    private func downloadFile(
        _ file: TokenSaverRemoteModelFile,
        modelID: String,
        revision: String,
        storageRoot: String,
        progress: TokenSaverModelDownloadProgress?
    ) async throws -> TokenSaverModelFile {
        let relativeStoragePath = Self.localRelativePath(
            storageRoot: storageRoot,
            modelID: modelID,
            revision: revision,
            remotePath: file.relativePath
        )
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
    /// The actual download uses URLSessionDownloadTask, which writes to a
    /// system-managed temp file and reports coarse delegate progress. This
    /// constant documents the historical 1 MB flush boundary used only when
    /// appending a resumed partial response.
    static let downloadChunkSize: Int = 1024 * 1024

    static func currentFileDownloadProgressState(
        relativePath: String,
        resumeOffset: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) -> TokenSaverModelDownloadState {
        let downloaded = resumeOffset + max(0, totalBytesWritten)
        let expected = totalBytesExpectedToWrite > 0
            ? resumeOffset + totalBytesExpectedToWrite
            : nil
        return TokenSaverModelDownloadState(
            phase: .downloading,
            downloadedBytes: downloaded,
            expectedBytes: expected,
            statusText: "Downloading \(relativePath)"
        )
    }

    func downloadBody(
        file: TokenSaverRemoteModelFile,
        partial: URL,
        progress: TokenSaverModelDownloadProgress?
    ) async throws {
        var resumeOffset = fileSize(at: partial)
        while true {
            try Task.checkCancellation()
            var request = authorizedRequest(url: file.downloadURL)
            if resumeOffset > 0 {
                request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
            }
            // Use a download task instead of bytes(for:) to avoid per-byte async
            // iteration overhead. A delegate reports live current-file bytes
            // while URLSession still writes to a temp file.
            let (tempURL, response) = try await downloadTempFile(
                request: request,
                file: file,
                resumeOffset: resumeOffset,
                stagingDirectory: partial.deletingLastPathComponent(),
                progress: progress
            )
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

    private func downloadTempFile(
        request: URLRequest,
        file: TokenSaverRemoteModelFile,
        resumeOffset: Int64,
        stagingDirectory: URL,
        progress: TokenSaverModelDownloadProgress?
    ) async throws -> (URL, URLResponse) {
        let delegate = DownloadSessionDelegate(
            relativePath: file.relativePath,
            resumeOffset: resumeOffset,
            stagingDirectory: stagingDirectory,
            fileManager: fileManager,
            progress: progress
        )
        let progressSession = URLSession(
            configuration: session.configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { progressSession.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URLResponse), Error>) in
                let task = progressSession.downloadTask(with: request)
                delegate.start(task: task, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
            progressSession.invalidateAndCancel()
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

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func shouldDownloadFile(_ path: String, artifactKind: RemoteModelSource.ArtifactKind) -> Bool {
        guard !path.hasPrefix(".") else { return false }
        guard artifactKind == .auxiliary else { return true }

        let lower = path.lowercased()
        let name = URL(fileURLWithPath: lower).lastPathComponent
        if lower.hasPrefix("onnx/") {
            return false
        }
        if ["pytorch_model.bin", "tf_model.h5", "flax_model.msgpack", "rust_model.ot"].contains(name) {
            return false
        }
        return lower.hasSuffix(".safetensors") ||
            lower.hasSuffix(".json") ||
            lower.hasSuffix(".txt") ||
            lower.hasSuffix(".model")
    }

    private static func downloadURL(modelURL: String, revision: String, relativePath: String) throws -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "#?")
        guard let encodedPath = relativePath.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "\(modelURL)/resolve/\(revision)/\(encodedPath)") else {
            throw TokenSaverModelDownloadError.invalidDownloadURL(relativePath)
        }
        return url
    }

    private static func localRelativePath(
        storageRoot: String,
        modelID: String,
        revision: String,
        remotePath: String
    ) -> String {
        [
            storageRoot,
            TokenSaverModelInstaller.safePathComponent(modelID),
            revision,
            remotePath
        ].joined(separator: "/")
    }
}
