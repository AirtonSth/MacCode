import AgentRuntime
import DistillCore
import Foundation
import XCTest

final class DistillLiveModelTests: XCTestCase {
    func test_approvedMLXModelDownloadsValidatesLoadsAndGenerates() async throws {
        guard ProcessInfo.processInfo.environment["REMOTE_CODE_TOKEN_SAVER_LIVE_MODEL_TEST"] == "1" else {
            throw XCTSkip("Set REMOTE_CODE_TOKEN_SAVER_LIVE_MODEL_TEST=1 to download and load the approved MLX model.")
        }

        let supportDirectory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["REMOTE_CODE_TOKEN_SAVER_LIVE_MODEL_DIR"]
                ?? "/tmp/RemoteCodeTokenSaverLiveModel",
            isDirectory: true
        )
        let installer = TokenSaverModelInstaller(appSupportDirectory: supportDirectory)
        let downloader = TokenSaverModelDownloader(installer: installer)

        let progress = LiveModelProgressReporter()
        let manifest = try await downloader.downloadApprovedModel { state in
            progress.report(state)
        }
        XCTAssertEqual(manifest.modelID, TokenSaverModelManifest.approvedModelID)
        XCTAssertEqual(manifest.modelURL, TokenSaverModelManifest.approvedModelURL)
        XCTAssertEqual(manifest.runtime, TokenSaverModelManifest.approvedRuntime)
        let modelFile = try XCTUnwrap(manifest.files.first { $0.relativePath.hasSuffix("/model.safetensors") })
        XCTAssertGreaterThan(modelFile.sizeBytes, 1_000_000_000)
        XCTAssertEqual(installer.validateInstalledModel().state, .installed)

        let runtime = try await MLXDistillRuntime(modelDirectory: installer.modelStorageDirectory(revision: manifest.revision))
        let scheduler = DistillScheduler(runtime: runtime, maxConcurrentRequests: 2)
        let response = try await scheduler.submit(DistillRequest(
            mode: .longText,
            input: """
            RemoteCode Token Saver compresses long agent output locally on macOS.
            It must preserve exact commands, errors, paths, and pass criteria.
            """,
            maxOutputCharacters: 600
        ))

        XCTAssertFalse(response.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(response.output.localizedCaseInsensitiveContains("<think>"))
        XCTAssertFalse(response.output.contains("S=state"))
        XCTAssertLessThanOrEqual(response.output.count, 600)
        XCTAssertTrue(
            response.output.localizedCaseInsensitiveContains("RemoteCode")
                || response.output.localizedCaseInsensitiveContains("Token Saver")
                || response.output.localizedCaseInsensitiveContains("macOS"),
            "Expected output to compress the input facts, got: \(response.output)"
        )
        XCTAssertTrue(
            response.output.contains("S")
                || response.output.contains("D")
                || response.output.contains("P"),
            "Expected /distill-style output, got: \(response.output)"
        )
        print("TokenSaverLiveModel output=\(response.output)")
    }
}

private final class LiveModelProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastBucket = -1
    private var lastStatus = ""

    func report(_ state: TokenSaverModelDownloadState) {
        lock.lock()
        defer { lock.unlock() }

        let bucket = Int(state.downloadedBytes / 100_000_000)
        guard state.statusText != lastStatus
            || bucket > lastBucket
            || state.phase == .ready
            || state.phase == .failed else {
            return
        }

        lastBucket = max(lastBucket, bucket)
        lastStatus = state.statusText
        print(
            "TokenSaverLiveModel progress phase=\(state.phase.rawValue) downloaded=\(state.downloadedBytes) expected=\(state.expectedBytes ?? -1) status=\(state.statusText)"
        )
    }
}
