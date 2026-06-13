import XCTest
@testable import AgentRuntime

/// Pure unit tests for the TokenSaverModelDownloader download-path seam.
///
/// These tests do not perform real network I/O. They verify the pure constants
/// and structural invariants that guard against regressions to per-byte async
/// iteration (the original catastrophic path on a ~1 GB model file).
final class TokenSaverDownloadChunkSeamTests: XCTestCase {

    // MARK: - downloadChunkSize: minimum I/O unit guard

    func test_downloadChunkSizeIsAtLeastOneMegabyte() {
        // WHY: per-byte async iteration on URLSession.AsyncBytes burned an entire
        // core and was orders of magnitude slower than kernel-managed I/O for a
        // ~1 GB model file. The minimum acceptable chunk size is 1 MB; regressing
        // below this guard recreates the per-byte-overhead catastrophe.
        XCTAssertGreaterThanOrEqual(
            TokenSaverModelDownloader.downloadChunkSize,
            1024 * 1024,
            "downloadChunkSize must be >= 1 MB to prevent per-byte iteration regression"
        )
    }

    func test_downloadChunkSizeIsNotExcessivelyLarge() {
        // WHY: chunk sizes larger than 64 MB offer no throughput benefit and waste
        // memory for the append path (a full chunk is held in RAM during the
        // FileHandle write loop). Cap at 64 MB to keep the seam from drifting.
        XCTAssertLessThanOrEqual(
            TokenSaverModelDownloader.downloadChunkSize,
            64 * 1024 * 1024,
            "downloadChunkSize must be <= 64 MB; larger values waste RAM without benefit"
        )
    }

    // MARK: - downloadBody: full response replaces partial

    func test_fullResponseReplacesExistingPartialFile() async throws {
        // WHY: a 200 (not 206) response means the server ignored our Range header;
        // the new body is the COMPLETE file and must overwrite any stale partial,
        // not append to it (which would corrupt the model weights).
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ChunkSeam-full-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let installer = TokenSaverModelInstaller(appSupportDirectory: appSupport)

        let file = TokenSaverRemoteModelFile(
            relativePath: "weights.bin",
            downloadURL: URL(string: "https://example.invalid/weights.bin")!
        )
        let revision = "rev-test"
        let storedPath = installer.distillDirectory
            .appendingPathComponent("Models/samuelfaj__distill-1.7B-4bit-MLX")
            .appendingPathComponent(revision)
            .appendingPathComponent("weights.bin")
        try FileManager.default.createDirectory(
            at: storedPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Write a stale partial so the downloader will attempt a range resume.
        let partial = storedPath.appendingPathExtension("partial")
        try Data("stale".utf8).write(to: partial)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FullResponseProtocolStub.self]
        let session = URLSession(configuration: config)

        let downloader = TokenSaverModelDownloader(installer: installer, session: session)
        // invoking the internal helper via the full download path (single file)
        try await downloader.downloadBody(
            file: file,
            partial: partial,
            progress: nil
        )

        let written = try String(contentsOf: partial)
        XCTAssertEqual(
            written, "fresh",
            "a 200 full-response must replace the stale partial, not append to it"
        )
    }

    // MARK: - downloadBody: progress callback fires for downloaded file

    func test_progressCallbackFiresWithDownloadingPhaseOnSuccess() async throws {
        // WHY: the UI download progress indicator depends on the .downloading
        // phase callback being emitted at least once per file so users see
        // activity; a download that completes silently produces a frozen progress bar.
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ChunkSeam-progress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let installer = TokenSaverModelInstaller(appSupportDirectory: appSupport)

        let file = TokenSaverRemoteModelFile(
            relativePath: "config.json",
            downloadURL: URL(string: "https://example.invalid/config.json")!
        )
        let partial = installer.distillDirectory
            .appendingPathComponent("config.json.partial")
        try FileManager.default.createDirectory(
            at: installer.distillDirectory,
            withIntermediateDirectories: true
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FullResponseProtocolStub.self]
        let session = URLSession(configuration: config)

        let downloader = TokenSaverModelDownloader(installer: installer, session: session)
        var phases: [TokenSaverModelDownloadPhase] = []
        try await downloader.downloadBody(file: file, partial: partial) { state in
            phases.append(state.phase)
        }

        XCTAssertTrue(
            phases.contains(.downloading),
            "progress callback must fire with .downloading phase after a successful chunked download"
        )
    }
}

// MARK: - Stubs

/// Returns a 200 response with body "fresh" for any request.
private final class FullResponseProtocolStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Data("fresh".utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(body.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
