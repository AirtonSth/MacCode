import AgentRuntime
import CoreModel
import DistillCore
import Foundation
import XCTest

final class DistillLiveModelTests: XCTestCase {
    func test_installedRuntimeUsesOnlyStrictDeterministicWireRoute() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["REMOTE_CODE_TOKEN_SAVER_LIVE_WIRE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set REMOTE_CODE_TOKEN_SAVER_LIVE_WIRE_BENCHMARK=1 to run the installed RCW1 encoder benchmark.")
        }
        guard let modelPath = environment["REMOTE_CODE_TOKEN_SAVER_INSTALLED_MODEL_DIR"],
              !modelPath.isEmpty else {
            throw XCTSkip("Set REMOTE_CODE_TOKEN_SAVER_INSTALLED_MODEL_DIR to the installed MLX revision directory.")
        }

        let prompt = [
            "Explain in one short human-readable sentence why a disposable local workspace improves software testing.",
            "Emphasize that isolation keeps experiments separate from valuable work, repeatability makes the same scenario reproducible, safety limits the damage from risky operations, cleanup removes temporary state, and these properties increase confidence in the result.",
            "Do not use tools and do not change files.",
            "The answer should be concise, readable, and intended for a human.",
            "A disposable workspace is temporary by design, so experiments can be repeated and discarded without contaminating unrelated projects.",
            "Summarize these ideas without omitting isolation, repeatability, safety, cleanup, or confidence."
        ].joined(separator: " ")
        XCTAssertEqual(prompt.utf8.count, 704, "fixture must remain byte-identical to the reported prompt")

        let runtime = try await MLXDistillRuntime(
            modelDirectory: URL(fileURLWithPath: modelPath, isDirectory: true)
        )
        let request = DistillRequest(
            mode: .wireEncode,
            priority: .interactive,
            input: prompt,
            runMode: .optimize,
            maxOutputCharacters: 2_432
        )

        // Wire encoding must bypass MLX entirely unless Swift can prove an exact
        // repeated unit. The installed runtime is loaded only to prove that routing
        // does not change when a model happens to be available.
        for trial in 1...7 {
            let result = try await runtime.distillStaged(request)
            XCTAssertEqual(result.stage, .verbatim)
            XCTAssertEqual(
                result.output,
                prompt,
                "trial \(trial) must fail open exactly when the model cannot beat Human faithfully"
            )
            XCTAssertFalse(RCWireProtocol.isWire(result.output))
        }

        let repeatUnit = "Before cleanup, inspect the disposable workspace without tools; keep /tmp/rcw1-test/fixture.txt unchanged; then report only observed evidence."
        let repeatedHuman = Array(repeating: repeatUnit, count: 6).joined(separator: " ")
        let repeatedResult = try await runtime.distillStaged(.init(
            mode: .wireEncode,
            priority: .interactive,
            input: repeatedHuman,
            runMode: .optimize,
            maxOutputCharacters: 2_432
        ))
        XCTAssertEqual(repeatedResult.stage, .deterministic)
        XCTAssertTrue(RCWireProtocol.preservesRequestMeaning(
            original: repeatedHuman,
            wire: repeatedResult.output
        ))
        let frames = try RCWireProtocol.parse(repeatedResult.output)
        XCTAssertEqual(
            frames.flatMap(\.records).first(where: { $0.kind == .context })?.value,
            RCWireProtocol.exactGoalRepetitionContext(count: 6)
        )
        let finalRepeatedWire = try RCWireProtocol.addingExactRecord(
            "[[rc:rcv1.ABCDEFGHIJKLMNOPQRSTUV]]",
            to: repeatedResult.output
        )
        XCTAssertLessThanOrEqual(
            TokenEstimator.estimate(finalRepeatedWire) * 100,
            TokenEstimator.estimate(repeatedHuman) * 45,
            "the marker-inclusive deterministic repeat frame must remain <=45% of Human"
        )
    }

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
        XCTAssertFalse(response.output.localizedCaseInsensitiveContains("RCW1"),
                       "long-text compression must remain plain language, got: \(response.output)")
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
