import XCTest
@testable import DistillCore

final class TokenSaverTrainingDatasetTests: XCTestCase {
    func test_acceptedGenerateWritesChatMLSFTAndDedups() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rc-sft-\(UUID().uuidString)", isDirectory: true)
        let writer = TokenSaverTrainingDatasetWriter(root: dir)
        let request = DistillRequest(mode: .commandOutput, input: "ERROR payment failed at Sources/Billing.swift:12\nretry ignored\n")
        writer.record(
            request: request,
            output: "payment failed at Sources/Billing.swift:12",
            stage: .llmMLX,
            modelID: "samuelfaj/distill-1.7B-4bit-MLX",
            source: "distill17b"
        )
        writer.record(
            request: request,
            output: "payment failed at Sources/Billing.swift:12",
            stage: .llmMLX,
            modelID: "samuelfaj/distill-1.7B-4bit-MLX",
            source: "distill17b"
        )
        let sft = dir.appendingPathComponent("sft/commandOutput.jsonl")
        let text = try String(contentsOf: sft, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline)
        XCTAssertEqual(lines.count, 1)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        let messages = try XCTUnwrap(obj["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user", "assistant"])
        XCTAssertEqual(messages[2]["content"], "payment failed at Sources/Billing.swift:12")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("rejected").path))
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("manifest.json"))) as? [String: Any]
        let counts = manifest?["counts"] as? [String: Int]
        XCTAssertEqual(counts?["sft"], 1)
    }

    func test_failOpenWritesRejectedNotSFT() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rc-sft-\(UUID().uuidString)", isDirectory: true)
        let writer = TokenSaverTrainingDatasetWriter(root: dir)
        let request = DistillRequest(mode: .longText, input: "ERROR payment failed\n")
        writer.record(
            request: request,
            output: request.input,
            stage: .llmMLX,
            modelID: "m",
            source: "openaiCompat"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sft").path))
        let rejectedDir = dir.appendingPathComponent("rejected", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: rejectedDir.path)
        XCTAssertEqual(files.count, 1)
    }

    func test_offPathDoesNotExistUntilRecord() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rc-sft-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func test_secretValuesAreRedacted() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rc-sft-\(UUID().uuidString)", isDirectory: true)
        let writer = TokenSaverTrainingDatasetWriter(root: dir)
        let request = DistillRequest(
            mode: .commandOutput,
            input: "api_key=sk_live_abcdefghijklmnopqrstuvwxyz\nERROR payment failed\n"
        )
        writer.record(
            request: request,
            output: "payment failed",
            stage: .llmMLX,
            modelID: "m",
            source: "local"
        )
        let text = try String(contentsOf: dir.appendingPathComponent("sft/commandOutput.jsonl"), encoding: .utf8)
        XCTAssertFalse(text.contains("sk_live_abcdefghijklmnopqrstuvwxyz"))
        XCTAssertTrue(text.contains("<redacted>") || text.contains("=<redacted>"))
    }

    func test_trainingRecordingRuntimeRecordsLeafGenerateWithoutHTTP() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rc-sft-\(UUID().uuidString)", isDirectory: true)
        let writer = TokenSaverTrainingDatasetWriter(root: dir)
        let inner = OpenAICompatibleDistillRuntime(
            baseURL: URL(string: "http://127.0.0.1:9/v1")!,
            model: "chosen-local"
        ) { _, _, _, _ in
            "payment failed at Sources/Billing.swift:12"
        }
        let runtime = TrainingRecordingRuntime(
            wrapping: inner,
            writer: writer,
            modelID: "chosen-local",
            source: "distill17b"
        )
        let request = DistillRequest(
            mode: .naturalLanguage,
            input: "Please briefly explain that payment failed at Sources/Billing.swift:12 after retries."
        )
        _ = try await runtime.distillStaged(request)
        let sft = dir.appendingPathComponent("sft/other.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sft.path), "local LLM generate must write SFT even without HTTP onSuccess")
        let text = try String(contentsOf: sft, encoding: .utf8)
        XCTAssertTrue(text.contains("chosen-local"))
        XCTAssertTrue(text.contains("assistant"))
    }

    func test_trainingRecordingRuntimeRecordsCatalogRawGenerate() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rc-sft-raw-\(UUID().uuidString)", isDirectory: true)
        let writer = TokenSaverTrainingDatasetWriter(root: dir)
        let inner = OpenAICompatibleDistillRuntime(
            baseURL: URL(string: "http://127.0.0.1:9/v1")!,
            model: "chosen-local"
        ) { _, _, _, _ in
            #"{"answer":"payment failed","span":"payment failed"}"#
        }
        let runtime = TrainingRecordingRuntime(
            wrapping: inner,
            writer: writer,
            modelID: "chosen-local",
            source: "distill17b"
        )
        let adapter = LibrarianDistillRuntimeAdapter(runtime: runtime)
        let out = await adapter.generate(LibrarianGenerateCall(
            system: "Extract only.",
            user: "Op: ask_handle\nSource:\nERROR payment failed\n",
            maxTokens: 64
        ))
        XCTAssertNotNil(out)
        let sft = dir.appendingPathComponent("sft/catalogOp.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sft.path), "catalog generate must write SFT even without HTTP onSuccess")
        let text = try String(contentsOf: sft, encoding: .utf8)
        XCTAssertTrue(text.contains("chosen-local"))
        XCTAssertTrue(text.contains("ask_handle"))
        XCTAssertTrue(text.contains("assistant"))
    }

    func test_deterministicStageWritesNothing() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rc-sft-\(UUID().uuidString)", isDirectory: true)
        let writer = TokenSaverTrainingDatasetWriter(root: dir)
        writer.record(
            request: DistillRequest(mode: .commandOutput, input: "{\"a\":1}"),
            output: "a=1",
            stage: .deterministic,
            modelID: "m",
            source: "local"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}
