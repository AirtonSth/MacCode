import CoreModel
import CryptoKit
import Foundation
import Persistence
import XCTest
@testable import DistillCore

final class TokenSaverExactDedupeBenchmarkTests: XCTestCase {
    private static let expectedFixtureSHA256 = "566d7d8c8299dea022a68fadd7118c92f24bec1d51d1a2c03528f11302c57df4"

    func test_lockedFixtureProvesExactOnlyControlsAndBaselineRoutingMisses() throws {
        let loaded = try loadFixture()
        let expanded = expandedFixture(loaded.fixture)
        let request = distillRequest(loaded.fixture, input: expanded.input)
        let dedupe = DistillBlockDeduper.dedupeExact(
            expanded.input,
            minBlockBytes: loaded.fixture.minBlockBytes
        )
        let candidate = try XCTUnwrap(ExactBlockDedupeTransform.commandOutput(for: request))

        XCTAssertEqual(loaded.fixture.schemaVersion, 1)
        XCTAssertEqual(loaded.fixture.corpusID, "token-saver-exact-dedupe-v1")
        XCTAssertEqual(sha256(loaded.data), Self.expectedFixtureSHA256)
        XCTAssertGreaterThanOrEqual(expanded.exactBlock.utf8.count, loaded.fixture.minBlockBytes)
        XCTAssertGreaterThanOrEqual(expanded.passBlock.utf8.count, loaded.fixture.minBlockBytes)
        XCTAssertGreaterThanOrEqual(expanded.failBlock.utf8.count, loaded.fixture.minBlockBytes)
        XCTAssertLessThan(expanded.nonEmptyLineCount, 24, "the baseline must not enter BERT")
        XCTAssertNil(MLXDistillRuntime.deterministicCommandOutput(for: request), "the neutral question must miss intent extraction")
        XCTAssertNil(LocalDistillRuntime.structuredCommandOutput(for: request))
        XCTAssertNil(
            DistillContentRouter().route(
                expanded.input,
                options: DistillRouterOptions(allowElementDropping: false, query: request.question)
            ),
            "the current lossless router must miss so the baseline really reaches oMLX"
        )

        XCTAssertEqual(dedupe.output, candidate)
        XCTAssertEqual(dedupe.dedupedBlocks, 1)
        XCTAssertEqual(dedupe.nearDedupedBlocks, 0)
        XCTAssertEqual(occurrences(of: expanded.exactBlock, in: candidate), 1, "the first exact block stays inline")
        XCTAssertEqual(occurrences(of: loaded.fixture.expectedPointer, in: candidate), 1)
        XCTAssertEqual(occurrences(of: expanded.passBlock, in: candidate), 1, "PASS control must stay byte-exact")
        XCTAssertEqual(occurrences(of: expanded.failBlock, in: candidate), 1, "FAIL control must stay byte-exact")
        XCTAssertTrue(ordered([
            loaded.fixture.header,
            expanded.exactBlock,
            expanded.passBlock,
            loaded.fixture.expectedPointer,
            expanded.failBlock,
            loaded.fixture.tail,
        ], in: candidate))
        XCTAssertEqual(
            candidate.replacingOccurrences(of: loaded.fixture.expectedPointer, with: expanded.exactBlock),
            expanded.input,
            "the retained block plus pointer must reconstruct the exact mixed input"
        )
        XCTAssertLessThan(candidate.utf8.count, expanded.input.utf8.count)
        XCTAssertLessThanOrEqual(candidate.count, loaded.fixture.maxOutputCharacters)
    }

    func test_shippingEnvelopeDebitsRealScopedCapabilityAndAuthenticatedReceipt() throws {
        let fixture = try loadFixture().fixture
        let expanded = expandedFixture(fixture)
        let request = distillRequest(fixture, input: expanded.input)
        let candidate = try XCTUnwrap(ExactBlockDedupeTransform.commandOutput(for: request))
        let recovery = try prepareRecovery(for: expanded.input)
        let delivery = try shippingDelivery(
            output: candidate,
            original: expanded.input,
            capability: recovery.capability
        )

        XCTAssertTrue(recovery.readBackVerified)
        XCTAssertTrue(isProductionCapability(recovery.capability))
        XCTAssertTrue(delivery.admitted, "the real CLI byte gate must admit this fixture")
        XCTAssertTrue(delivery.receiptVerified)
        XCTAssertTrue(delivery.providerText.contains("[[rc:\(recovery.capability)]]"))
        XCTAssertTrue(DistillAppliedReceipt.containsMarker(delivery.providerText))
        XCTAssertLessThan(delivery.providerBytes, expanded.input.utf8.count)
    }

    /// Manual, env-gated incremental A/B against the pinned oMLX runtime.
    /// The raw->pointer count is diagnostic only; the accept/reject decision compares
    /// the current local-LLM baseline delivery against EncoderFirstRuntime with D.
    func test_liveIncrementalCaptureAgainstOMLX() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RC_TOKEN_SAVER_EXACT_DEDUPE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set RC_TOKEN_SAVER_EXACT_DEDUPE_BENCHMARK=1 for the live D capture.")
        }

        let fixtureLoad = try loadFixture()
        let fixture = fixtureLoad.fixture
        let expanded = expandedFixture(fixture)
        let request = distillRequest(fixture, input: expanded.input)
        let configuration = try LiveConfiguration(
            environment: environment,
            repository: repositoryURL()
        )
        try verifySourceComparison(configuration)

        let local = OpenAICompatibleDistillRuntime(
            baseURL: configuration.baseURL,
            model: configuration.model,
            token: configuration.token,
            timeout: configuration.timeout
        )
        guard await local.rawGenerate(system: "Reply only READY.", user: "ready", maxTokens: 8) != nil else {
            throw ExactDedupeBenchmarkError.transport("oMLX warmup failed")
        }

        let baselineStart = Date()
        let baseline = try await local.distillStaged(request)
        let baselineLatencyMS = elapsedMilliseconds(since: baselineStart)
        let candidateStart = Date()
        let candidate = try await EncoderFirstRuntime(wrapping: local, encoderLane: nil).distillStaged(request)
        let candidateLatencyMS = elapsedMilliseconds(since: candidateStart)
        let expectedCandidate = try required(
            ExactBlockDedupeTransform.commandOutput(for: request),
            message: "fixture did not activate exact dedupe"
        )

        let recovery = try prepareRecovery(for: expanded.input)
        let baselineDelivery = try shippingDelivery(
            output: baseline.output,
            original: expanded.input,
            capability: recovery.capability
        )
        let candidateDelivery = try shippingDelivery(
            output: candidate.output,
            original: expanded.input,
            capability: recovery.capability
        )

        let rawGross = try await measureProviderInput(
            content: expanded.input,
            fixture: fixture,
            configuration: configuration
        )
        let pointerGross = try await measureProviderInput(
            content: expectedCandidate,
            fixture: fixture,
            configuration: configuration
        )
        let baselineProvider = try await measureProviderInput(
            content: baselineDelivery.providerText,
            fixture: fixture,
            configuration: configuration
        )
        let candidateProvider = try await measureProviderInput(
            content: candidateDelivery.providerText,
            fixture: fixture,
            configuration: configuration
        )
        let serverVersion = try await fetchServerVersion(configuration)

        let structuralQuality = candidate.output == expectedCandidate
            && expectedCandidate.replacingOccurrences(of: fixture.expectedPointer, with: expanded.exactBlock) == expanded.input
            && occurrences(of: expanded.passBlock, in: expectedCandidate) == 1
            && occurrences(of: expanded.failBlock, in: expectedCandidate) == 1
        let qualityPassed = baseline.stage == .llmMLX
            && candidate.stage == .deterministic
            && structuralQuality
            && recovery.readBackVerified
            && baselineDelivery.receiptVerified
            && candidateDelivery.receiptVerified
            && candidateDelivery.admitted
        let incrementalSaved = baselineProvider.inputTokens - candidateProvider.inputTokens
        let accepted = qualityPassed && incrementalSaved > 0

        let artifact: [String: Any] = [
            "schema_version": 1,
            "suite_id": "token-saver-exact-dedupe-v1",
            "technique": "D",
            "captured_at": ISO8601DateFormatter().string(from: Date()),
            "token_count_source": "omlx:/v1/messages/count_tokens",
            "claim_scope": "exact input tokens for canonical Anthropic-shaped requests; not provider billing",
            "source": [
                "git_head": configuration.candidateSHA,
                "tree_sha": configuration.candidateTreeSHA,
                "dirty": false,
            ],
            "comparison": [
                "baseline_git_sha": configuration.baselineSHA,
                "candidate_git_sha": configuration.candidateSHA,
                "baseline_variant": "OpenAICompatibleDistillRuntime; fixture-proven equivalent pre-D path",
                "candidate_variant": "EncoderFirstRuntime with exact-block dedupe",
            ],
            "fixture": [
                "id": fixture.corpusID,
                "sha256": sha256(fixtureLoad.data),
                "input_bytes": expanded.input.utf8.count,
                "non_empty_lines": expanded.nonEmptyLineCount,
                "exact_block_bytes": expanded.exactBlock.utf8.count,
            ],
            "model": [
                "id": configuration.model,
                "revision": configuration.revision,
                "server": "oMLX",
                "server_version": serverVersion,
            ],
            "runtime": [
                "baseline_route_stage": baseline.stage?.rawValue ?? "unreported",
                "candidate_route_stage": candidate.stage?.rawValue ?? "unreported",
                "baseline_latency_ms": baselineLatencyMS,
                "candidate_latency_ms": candidateLatencyMS,
                "baseline_output_sha256": sha256(baseline.output),
                "candidate_output_sha256": sha256(candidate.output),
            ],
            "recovery": [
                "capability_format": "rcv1.<22-base64url>",
                "capability_sha256": sha256(recovery.capability),
                "same_capability_both_arms": true,
                "scoped_readback_verified": recovery.readBackVerified,
            ],
            "delivery": [
                "baseline_cli_byte_gate_admitted": baselineDelivery.admitted,
                "candidate_cli_byte_gate_admitted": candidateDelivery.admitted,
                "baseline_provider_bytes": baselineDelivery.providerBytes,
                "candidate_provider_bytes": candidateDelivery.providerBytes,
                "baseline_receipt_verified": baselineDelivery.receiptVerified,
                "candidate_receipt_verified": candidateDelivery.receiptVerified,
                "receipt_marker_bytes": DistillAppliedReceipt.maximumV2MarkerByteCount,
            ],
            "gross_transform_diagnostic": [
                "accounting": "raw provider input versus pointer only; excludes recovery and is not the acceptance claim",
                "raw": rawGross.jsonObject,
                "pointer": pointerGross.jsonObject,
                "tokens_saved": rawGross.inputTokens - pointerGross.inputTokens,
            ],
            "incremental_provider_facing": [
                "accounting": "shipping baseline versus shipping candidate; both include the same scoped handle and authenticated receipt when admitted",
                "baseline": baselineProvider.jsonObject,
                "candidate": candidateProvider.jsonObject,
                "baseline_tokens": baselineProvider.inputTokens,
                "candidate_tokens": candidateProvider.inputTokens,
                "net_tokens_saved": incrementalSaved,
                "percent_saved": baselineProvider.inputTokens > 0
                    ? (Double(incrementalSaved) / Double(baselineProvider.inputTokens)) * 100
                    : 0,
            ],
            "quality": [
                "baseline_reached_real_local_llm": baseline.stage == .llmMLX,
                "candidate_resolved_deterministically": candidate.stage == .deterministic,
                "first_block_inline": occurrences(of: expanded.exactBlock, in: expectedCandidate) == 1,
                "pointer_order_preserved": ordered([
                    fixture.header,
                    expanded.exactBlock,
                    expanded.passBlock,
                    fixture.expectedPointer,
                    expanded.failBlock,
                    fixture.tail,
                ], in: expectedCandidate),
                "pass_fail_near_blocks_untouched": occurrences(of: expanded.passBlock, in: expectedCandidate) == 1
                    && occurrences(of: expanded.failBlock, in: expectedCandidate) == 1,
                "exact_reconstruction": structuralQuality,
                "baseline_success_regression": false,
                "quality_passed": qualityPassed,
            ],
            "decision": accepted ? "accepted" : "rejected",
            "decision_reason": accepted
                ? "positive incremental provider-context savings after real local-LLM baseline and full wire overhead"
                : (qualityPassed
                    ? "rejected because the current local-LLM shipping baseline is not larger than the exact-dedupe shipping candidate"
                    : "rejected because one or more routing, recovery, receipt, or exactness gates failed"),
        ]

        let encoded = try canonicalData(artifact, prettyPrinted: true)
        if !configuration.token.isEmpty,
           String(decoding: encoded, as: UTF8.self).contains(configuration.token) {
            throw ExactDedupeBenchmarkError.invalidArtifact("auth token appeared in artifact")
        }
        let outputURL = URL(fileURLWithPath: configuration.outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoded.write(to: outputURL, options: .atomic)
    }
}

private extension TokenSaverExactDedupeBenchmarkTests {
    func loadFixture() throws -> (fixture: ExactDedupeFixture, data: Data) {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = tests.appendingPathComponent("Fixtures/TokenSaverLocalLLM/exact-dedupe-corpus.json")
        let data = try Data(contentsOf: url)
        return (try JSONDecoder().decode(ExactDedupeFixture.self, from: data), data)
    }

    func expandedFixture(_ fixture: ExactDedupeFixture) -> ExpandedExactDedupeFixture {
        let exactBlock = Array(repeating: fixture.exactUnit, count: fixture.exactRepetitions)
            .joined(separator: " ")
        let controlTail = Array(repeating: fixture.controlUnit, count: fixture.controlRepetitions)
            .joined(separator: " ")
        let passBlock = "\(fixture.passPrefix) \(controlTail)"
        let failBlock = "\(fixture.failPrefix) \(controlTail)"
        let input = [fixture.header, exactBlock, passBlock, exactBlock, failBlock, fixture.tail]
            .joined(separator: "\n\n")
        return ExpandedExactDedupeFixture(
            input: input,
            exactBlock: exactBlock,
            passBlock: passBlock,
            failBlock: failBlock,
            nonEmptyLineCount: input.split(whereSeparator: \.isNewline).count
        )
    }

    func distillRequest(_ fixture: ExactDedupeFixture, input: String) -> DistillRequest {
        DistillRequest(
            mode: .commandOutput,
            input: input,
            question: fixture.distillQuestion,
            provider: "codex",
            maxOutputCharacters: fixture.maxOutputCharacters,
            reversibleStoreMinBytes: 1
        )
    }

    func prepareRecovery(for original: String) throws -> RecoveryProof {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let projectID = "token-saver-exact-dedupe-benchmark"
        try TokenSaverLaneStateRepository(db: db).ensureDefaults(projectID: projectID)
        let scope = TokenSaverPersistentScope(
            workspaceID: "benchmark-workspace",
            projectID: projectID,
            threadID: "benchmark-thread",
            provider: "codex",
            attemptID: "benchmark-attempt"
        )
        let data = Data(original.utf8)
        let prepared = try TokenSaverRuntimeRecoveryWorker(db: db).prepareOriginal(
            data,
            scope: scope,
            operationID: "exact-block-dedupe",
            lane: "deterministic_wrapper",
            disk: TokenSaverRecoveryDiskSnapshot(
                freeBytes: 20 * 1_024 * 1_024 * 1_024,
                totalBytes: 100 * 1_024 * 1_024 * 1_024
            )
        )
        let readBack = try TokenSaverScopedRecoveryStore(db: db).retrieve(
            capability: prepared.capability,
            scope: scope
        )
        return RecoveryProof(
            capability: prepared.capability,
            readBackVerified: prepared.readBackVerified && readBack == data
        )
    }

    func shippingDelivery(output: String, original: String, capability: String) throws -> ShippingDelivery {
        let separator = output.hasSuffix("\n") ? "" : "\n"
        let payload = Data((output + separator + "[[rc:\(capability)]]\n").utf8)
        let key = Data((0..<32).map(UInt8.init))
        let nonce = Data((0..<16).map { UInt8($0 + 32) })
        guard let marker = DistillAppliedReceipt.makeV2Marker(
            rootRunID: "token-saver-exact-dedupe-benchmark",
            payload: payload,
            key: key,
            nonce: nonce
        ) else {
            throw ExactDedupeBenchmarkError.invalidArtifact("could not create v2 receipt")
        }
        var proposed = payload
        proposed.append(Data((marker + "\n").utf8))
        guard let parsed = DistillAppliedReceipt.parseTrailingV2Marker(in: proposed) else {
            throw ExactDedupeBenchmarkError.invalidArtifact("could not parse v2 receipt")
        }
        let receiptVerified = DistillAppliedReceipt.verify(
            parsed,
            rootRunID: "token-saver-exact-dedupe-benchmark",
            payloadByteCount: payload.count,
            payloadSHA256: Data(SHA256.hash(data: payload)),
            key: key
        )
        let admitted = proposed.count < Data(original.utf8).count
        let providerData = admitted ? proposed : Data(original.utf8)
        return ShippingDelivery(
            providerText: String(decoding: providerData, as: UTF8.self),
            providerBytes: providerData.count,
            admitted: admitted,
            receiptVerified: receiptVerified
        )
    }

    func measureProviderInput(
        content: String,
        fixture: ExactDedupeFixture,
        configuration: LiveConfiguration
    ) async throws -> CountMeasurement {
        let body = anthropicBody(content: content, fixture: fixture, model: configuration.model)
        let data = try canonicalData(body)
        let start = Date()
        let inputTokens = try await countTokens(data, configuration: configuration)
        return CountMeasurement(
            inputTokens: inputTokens,
            canonicalBodyBytes: data.count,
            canonicalBodySHA256: sha256(data),
            countLatencyMS: elapsedMilliseconds(since: start)
        )
    }

    func anthropicBody(content: String, fixture: ExactDedupeFixture, model: String) -> [String: Any] {
        [
            "model": model,
            "system": fixture.providerSystem,
            "messages": [
                ["role": "user", "content": fixture.providerQuestion],
                ["role": "assistant", "content": [[
                    "type": "tool_use",
                    "id": "toolu_exact_dedupe_1",
                    "name": "captured_command",
                    "input": [String: Any](),
                ]]],
                ["role": "user", "content": [[
                    "type": "tool_result",
                    "tool_use_id": "toolu_exact_dedupe_1",
                    "content": content,
                ]]],
            ],
            "tools": [[
                "name": "rc_retrieve",
                "description": "Retrieve the scoped byte-exact original only when exact source bytes are required.",
                "input_schema": [
                    "type": "object",
                    "properties": ["handle": ["type": "string"]],
                    "required": ["handle"],
                ],
            ]],
        ]
    }

    func countTokens(_ body: Data, configuration: LiveConfiguration) async throws -> Int {
        let url = configuration.baseURL.appendingPathComponent("messages/count_tokens")
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.token.isEmpty {
            request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ExactDedupeBenchmarkError.transport(
                "oMLX count_tokens returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            )
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["input_tokens"] as? Int,
              tokens >= 0 else {
            throw ExactDedupeBenchmarkError.transport("oMLX count_tokens returned an invalid body")
        }
        return tokens
    }

    func fetchServerVersion(_ configuration: LiveConfiguration) async throws -> String {
        let url = configuration.baseURL.deletingLastPathComponent().appendingPathComponent("openapi.json")
        let request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = object["info"] as? [String: Any],
              let version = info["version"] as? String,
              !version.isEmpty else {
            throw ExactDedupeBenchmarkError.transport("oMLX server version is unavailable")
        }
        return version
    }

    func verifySourceComparison(_ configuration: LiveConfiguration) throws {
        let allowed = Set([
            "Sources/DistillCore/Deterministic/ExactBlockDedupeTransform.swift",
            "Sources/DistillCore/DistillBlockDeduper.swift",
            "Sources/DistillCore/EncoderFirstRuntime.swift",
        ])
        let changed = Set(try git(
            ["diff", "--name-only", configuration.baselineSHA, configuration.candidateSHA, "--", "Sources/DistillCore"],
            repository: configuration.repository
        ).split(whereSeparator: \.isNewline).map(String.init))
        guard changed == allowed else {
            throw ExactDedupeBenchmarkError.invalidConfiguration(
                "baseline/candidate DistillCore diff is not isolated to exact dedupe: \(changed.sorted())"
            )
        }
        let baselineEncoder = try git(
            ["show", "\(configuration.baselineSHA):Sources/DistillCore/EncoderFirstRuntime.swift"],
            repository: configuration.repository
        )
        let candidateEncoder = try git(
            ["show", "\(configuration.candidateSHA):Sources/DistillCore/EncoderFirstRuntime.swift"],
            repository: configuration.repository
        )
        guard !baselineEncoder.contains("ExactBlockDedupeTransform"),
              candidateEncoder.contains("ExactBlockDedupeTransform") else {
            throw ExactDedupeBenchmarkError.invalidConfiguration("source SHAs do not bracket technique D")
        }
    }

    func repositoryURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func git(_ arguments: [String], repository: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ExactDedupeBenchmarkError.invalidConfiguration("git failed: \(message)")
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    func ordered(_ needles: [String], in text: String) -> Bool {
        var cursor = text.startIndex
        for needle in needles {
            guard let range = text.range(of: needle, range: cursor..<text.endIndex) else { return false }
            cursor = range.upperBound
        }
        return true
    }

    func isProductionCapability(_ capability: String) -> Bool {
        capability.range(of: #"^rcv1\.[A-Za-z0-9_-]{22}$"#, options: .regularExpression) != nil
    }

    func canonicalData(_ object: Any, prettyPrinted: Bool = false) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if prettyPrinted { options.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func sha256(_ string: String) -> String { sha256(Data(string.utf8)) }

    func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(start) * 1_000).rounded()))
    }

    func required<T>(_ value: T?, message: String) throws -> T {
        guard let value else { throw ExactDedupeBenchmarkError.invalidArtifact(message) }
        return value
    }
}

private struct ExactDedupeFixture: Decodable {
    let schemaVersion: Int
    let corpusID: String
    let minBlockBytes: Int
    let maxOutputCharacters: Int
    let distillQuestion: String
    let providerSystem: String
    let providerQuestion: String
    let header: String
    let exactUnit: String
    let exactRepetitions: Int
    let passPrefix: String
    let failPrefix: String
    let controlUnit: String
    let controlRepetitions: Int
    let tail: String
    let expectedPointer: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case corpusID = "corpus_id"
        case minBlockBytes = "min_block_bytes"
        case maxOutputCharacters = "max_output_characters"
        case distillQuestion = "distill_question"
        case providerSystem = "provider_system"
        case providerQuestion = "provider_question"
        case header
        case exactUnit = "exact_unit"
        case exactRepetitions = "exact_repetitions"
        case passPrefix = "pass_prefix"
        case failPrefix = "fail_prefix"
        case controlUnit = "control_unit"
        case controlRepetitions = "control_repetitions"
        case tail
        case expectedPointer = "expected_pointer"
    }
}

private struct ExpandedExactDedupeFixture {
    let input: String
    let exactBlock: String
    let passBlock: String
    let failBlock: String
    let nonEmptyLineCount: Int
}

private struct RecoveryProof {
    let capability: String
    let readBackVerified: Bool
}

private struct ShippingDelivery {
    let providerText: String
    let providerBytes: Int
    let admitted: Bool
    let receiptVerified: Bool
}

private struct CountMeasurement {
    let inputTokens: Int
    let canonicalBodyBytes: Int
    let canonicalBodySHA256: String
    let countLatencyMS: Int

    var jsonObject: [String: Any] {
        [
            "input_tokens": inputTokens,
            "canonical_body_bytes": canonicalBodyBytes,
            "canonical_body_sha256": canonicalBodySHA256,
            "count_latency_ms": countLatencyMS,
        ]
    }
}

private struct LiveConfiguration {
    let repository: URL
    let baseURL: URL
    let model: String
    let revision: String
    let token: String
    let baselineSHA: String
    let candidateSHA: String
    let candidateTreeSHA: String
    let outputPath: String
    let timeout: TimeInterval

    init(environment: [String: String], repository: URL) throws {
        func require(_ name: String) throws -> String {
            guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                throw ExactDedupeBenchmarkError.invalidConfiguration("missing \(name)")
            }
            return value
        }
        func runGit(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repository.path] + arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ExactDedupeBenchmarkError.invalidConfiguration("git source check failed")
            }
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        self.repository = repository
        let rawURL = try require("RC_TOKEN_SAVER_BENCHMARK_BASE_URL")
        guard let url = URL(string: rawURL), url.scheme == "http",
              ["127.0.0.1", "localhost", "::1"].contains(url.host),
              url.path.hasSuffix("/v1") else {
            throw ExactDedupeBenchmarkError.invalidConfiguration("benchmark URL must be loopback HTTP ending in /v1")
        }
        baseURL = url
        model = try require("RC_TOKEN_SAVER_BENCHMARK_MODEL")
        revision = try require("RC_TOKEN_SAVER_BENCHMARK_MODEL_REVISION")
        token = environment["RC_TOKEN_SAVER_BENCHMARK_AUTH_TOKEN"] ?? ""
        baselineSHA = try require("RC_TOKEN_SAVER_EXACT_DEDUPE_BASELINE_SHA")
        candidateSHA = try require("RC_TOKEN_SAVER_EXACT_DEDUPE_CANDIDATE_SHA")
        outputPath = try require("RC_TOKEN_SAVER_EXACT_DEDUPE_OUTPUT")
        timeout = TimeInterval(Int(environment["RC_TOKEN_SAVER_BENCHMARK_TIMEOUT_SECONDS"] ?? "30") ?? 30)

        let shaPattern = #"^[0-9a-f]{40}$"#
        guard baselineSHA.range(of: shaPattern, options: .regularExpression) != nil,
              candidateSHA.range(of: shaPattern, options: .regularExpression) != nil,
              revision.range(of: shaPattern, options: .regularExpression) != nil,
              timeout >= 5, timeout <= 120 else {
            throw ExactDedupeBenchmarkError.invalidConfiguration("invalid source/model SHA or timeout")
        }
        let head = try runGit(["rev-parse", "HEAD"])
        guard head == candidateSHA else {
            throw ExactDedupeBenchmarkError.invalidConfiguration("candidate SHA must equal checked-out HEAD")
        }
        guard try runGit(["status", "--porcelain", "--untracked-files=all"]).isEmpty else {
            throw ExactDedupeBenchmarkError.invalidConfiguration("live capture refuses a dirty worktree")
        }
        _ = try runGit(["cat-file", "-e", "\(baselineSHA)^{commit}"])
        candidateTreeSHA = try runGit(["rev-parse", "\(candidateSHA)^{tree}"])
    }
}

private enum ExactDedupeBenchmarkError: Error {
    case invalidConfiguration(String)
    case invalidArtifact(String)
    case transport(String)
}
