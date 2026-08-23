import CryptoKit
import Foundation
import XCTest
@testable import DistillCore

final class TokenSaverLocalLLMBenchmarkTests: XCTestCase {
    private static let expectedCorpusSHA256 = "e520d7c4f4149684b3dafa14c796a6965ed7dc8073ae2bbd7e09e347fc6d4646"

    func test_lockedCorpusHasValidSchemaHashIDsAndActionQualityContracts() throws {
        let (corpus, data) = try loadCorpus()

        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertEqual(corpus.corpusID, "token-saver-local-llm-v1")
        XCTAssertEqual(sha256(data), Self.expectedCorpusSHA256, "corpus changed without an explicit protocol revision")
        XCTAssertGreaterThanOrEqual(corpus.cases.count, 24)
        XCTAssertEqual(Set(corpus.cases.map(\.id)).count, corpus.cases.count, "case IDs must be unique")
        XCTAssertGreaterThanOrEqual(Set(corpus.cases.map(\.cohort)).count, 12, "corpus must stay diverse")

        let idPattern = try NSRegularExpression(pattern: #"^TSLLM-[0-9]{3}$"#)
        for item in corpus.cases {
            let idRange = NSRange(item.id.startIndex..<item.id.endIndex, in: item.id)
            XCTAssertNotNil(idPattern.firstMatch(in: item.id, range: idRange), item.id)
            XCTAssertFalse(item.cohort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.id)
            XCTAssertFalse(item.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.id)
            XCTAssertFalse(item.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.id)
            XCTAssertFalse(item.nextAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.id)
            XCTAssertFalse(item.requiredLiterals.isEmpty, "\(item.id) has no action-quality pins")
            XCTAssertEqual(Set(item.requiredLiterals).count, item.requiredLiterals.count, "\(item.id) repeats a quality pin")
            for literal in item.requiredLiterals {
                XCTAssertFalse(literal.isEmpty, "\(item.id) has an empty quality pin")
                XCTAssertTrue(item.input.contains(literal), "\(item.id) pins a fact absent from its source: \(literal)")
            }
        }
    }

    func test_qualityGateRequiresDirectFactsOrVerifiedLibrarianStoreReadback() throws {
        let item = try XCTUnwrap(loadCorpus().corpus.cases.first)
        let direct = quality(
            for: item,
            output: item.requiredLiterals.joined(separator: "\n"),
            handleMarker: nil,
            recoveryReadbackVerified: false
        )
        XCTAssertTrue(direct.nextActionReady)
        XCTAssertTrue(direct.qualityPassed)

        let missing = quality(for: item, output: "FAIL", handleMarker: nil, recoveryReadbackVerified: false)
        XCTAssertFalse(missing.nextActionReady)
        XCTAssertFalse(missing.qualityPassed)

        let marker = "[[rc:\(LibrarianHandleStore.makeHandle(item.input))]]"
        let fabricated = quality(for: item, output: "FAIL", handleMarker: marker, recoveryReadbackVerified: false)
        XCTAssertFalse(fabricated.nextActionReady)
        XCTAssertFalse(fabricated.qualityPassed, "marker text without byte-exact readback is not recovery proof")

        let store = LibrarianHandleStore()
        let storedHandle = store.put(item.input)
        let storedMarker = "[[rc:\(storedHandle)]]"
        let readbackVerified = store.get(storedHandle) == item.input
        let recoverable = quality(
            for: item,
            output: "FAIL",
            handleMarker: storedMarker,
            recoveryReadbackVerified: readbackVerified
        )
        XCTAssertFalse(recoverable.nextActionReady)
        XCTAssertTrue(recoverable.qualityPassed, "Librarian store put/get proves byte-exact benchmark recovery")
        XCTAssertEqual(storedMarker, marker)
        XCTAssertEqual(marker.count, 36, "benchmark overhead uses Librarian's deterministic 24-hex handle format")
    }

    func test_reportSchemaRoundTripKeepsExactCounterAndEnvelopeFields() throws {
        let report = BenchmarkReport.fixture(corpusSHA256: Self.expectedCorpusSHA256)
        let data = try reportData(report)
        let decoded = try JSONDecoder.benchmark.decode(BenchmarkReport.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.tokenCountSource, "omlx:/v1/messages/count_tokens")
        XCTAssertEqual(decoded.source.gitHead, String(repeating: "a", count: 40))
        XCTAssertEqual(decoded.corpus.sha256, Self.expectedCorpusSHA256)
        XCTAssertEqual(decoded.cases.first?.finalEnvelope, "signal\n[[rc:rcv1.0123456789abcdef01234567]]")
        XCTAssertEqual(decoded.cases.first?.handleOverheadTokens, 7)
        XCTAssertEqual(decoded.cases.first?.recoveryReadbackVerified, true)
        XCTAssertEqual(decoded.aggregate.netTokensSaved, 73)
    }

    /// Manual, env-gated capture. It deliberately instantiates the shipped runtime instead
    /// of duplicating its prompt, deterministic-first routing, cleanup, or fail-open gates.
    func test_liveCaptureAgainstOMLXWithExactTokenizer() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RC_TOKEN_SAVER_LOCAL_LLM_BENCHMARK"] == "1" else {
            throw XCTSkip("Set RC_TOKEN_SAVER_LOCAL_LLM_BENCHMARK=1 to capture a live oMLX report.")
        }

        let baseURL = try requiredLocalBaseURL(environment["RC_TOKEN_SAVER_BENCHMARK_BASE_URL"])
        let model = try required(environment["RC_TOKEN_SAVER_BENCHMARK_MODEL"], name: "RC_TOKEN_SAVER_BENCHMARK_MODEL")
        let revision = try required(environment["RC_TOKEN_SAVER_BENCHMARK_MODEL_REVISION"], name: "RC_TOKEN_SAVER_BENCHMARK_MODEL_REVISION")
        let sourceGitHead = try requiredGitHead(environment["RC_TOKEN_SAVER_BENCHMARK_SOURCE_GIT_HEAD"])
        let captureKind = try required(environment["RC_TOKEN_SAVER_BENCHMARK_CAPTURE_KIND"], name: "RC_TOKEN_SAVER_BENCHMARK_CAPTURE_KIND")
        guard ["baseline", "candidate", "final"].contains(captureKind) else {
            throw BenchmarkError.invalidConfiguration("RC_TOKEN_SAVER_BENCHMARK_CAPTURE_KIND must be baseline, candidate, or final")
        }
        let outputPath = try required(environment["RC_TOKEN_SAVER_BENCHMARK_OUTPUT"], name: "RC_TOKEN_SAVER_BENCHMARK_OUTPUT")
        let token = environment["RC_TOKEN_SAVER_BENCHMARK_AUTH_TOKEN"] ?? ""
        let runs = try boundedInteger(environment["RC_TOKEN_SAVER_BENCHMARK_RUNS"], defaultValue: 3, range: 1...9, name: "RC_TOKEN_SAVER_BENCHMARK_RUNS")
        let warmups = try boundedInteger(environment["RC_TOKEN_SAVER_BENCHMARK_WARMUPS"], defaultValue: 1, range: 1...5, name: "RC_TOKEN_SAVER_BENCHMARK_WARMUPS")
        let maxOutputCharacters = try boundedInteger(environment["RC_TOKEN_SAVER_BENCHMARK_MAX_OUTPUT_CHARACTERS"], defaultValue: 900, range: 128...8_000, name: "RC_TOKEN_SAVER_BENCHMARK_MAX_OUTPUT_CHARACTERS")
        let timeout = TimeInterval(try boundedInteger(environment["RC_TOKEN_SAVER_BENCHMARK_TIMEOUT_SECONDS"], defaultValue: 30, range: 5...120, name: "RC_TOKEN_SAVER_BENCHMARK_TIMEOUT_SECONDS"))

        let (corpus, corpusData) = try loadCorpus()
        let corpusHash = sha256(corpusData)
        guard corpusHash == Self.expectedCorpusSHA256 else {
            throw BenchmarkError.invalidCorpus("live capture refused an unlocked corpus: \(corpusHash)")
        }

        let runtime = OpenAICompatibleDistillRuntime(
            baseURL: baseURL,
            model: model,
            token: token,
            timeout: timeout
        )
        for _ in 0..<warmups {
            guard await runtime.rawGenerate(system: "Reply with one word: ready", user: "ready", maxTokens: 8) != nil else {
                throw BenchmarkError.transport("oMLX warmup failed; verify local URL, model, revision, and auth token")
            }
        }

        let serverVersion = await fetchServerVersion(baseURL: baseURL) ?? "unreported"
        let recoveryStore = LibrarianHandleStore()
        var caseReports: [BenchmarkCaseReport] = []
        caseReports.reserveCapacity(corpus.cases.count)

        for item in corpus.cases {
            var outputs: [String] = []
            var routes: [String] = []
            var latencies: [Int] = []
            for _ in 0..<runs {
                let request = DistillRequest(
                    mode: .commandOutput,
                    input: item.input,
                    question: item.question,
                    provider: "benchmark",
                    recordSavings: false,
                    maxOutputCharacters: maxOutputCharacters,
                    reversibleStoreMinBytes: 1
                )
                let startedAt = Date()
                let staged = try await runtime.distillStaged(request)
                latencies.append(max(0, Int((Date().timeIntervalSince(startedAt) * 1_000).rounded())))
                outputs.append(staged.output)
                routes.append(staged.stage?.rawValue ?? "unknown")
            }

            let output = try required(outputs.first, name: "captured output for \(item.id)")
            let route = try required(routes.first, name: "captured route for \(item.id)")
            let handle: String? = output == item.input ? nil : recoveryStore.put(item.input)
            let handleMarker = handle.map { "[[rc:\($0)]]" }
            let recoveryReadbackVerified = handle.map { recoveryStore.get($0) == item.input } ?? false
            let finalEnvelope = makeFinalEnvelope(output: output, handleMarker: handleMarker)
            let inputTokens = try await countTokens(item.input, baseURL: baseURL, model: model, token: token, timeout: timeout)
            let outputTokensBeforeHandle = try await countTokens(output, baseURL: baseURL, model: model, token: token, timeout: timeout)
            let finalOutputTokens = try await countTokens(finalEnvelope, baseURL: baseURL, model: model, token: token, timeout: timeout)
            let qualityResult = quality(
                for: item,
                output: output,
                handleMarker: handleMarker,
                recoveryReadbackVerified: recoveryReadbackVerified
            )

            caseReports.append(BenchmarkCaseReport(
                id: item.id,
                cohort: item.cohort,
                route: route,
                routeStable: Set(routes).count == 1,
                measuredRuns: runs,
                latencyMilliseconds: latencies,
                medianLatencyMilliseconds: percentile(latencies, percentile: 0.50),
                inputTokens: inputTokens,
                outputTokensBeforeHandle: outputTokensBeforeHandle,
                finalOutputTokens: finalOutputTokens,
                handleOverheadTokens: max(0, finalOutputTokens - outputTokensBeforeHandle),
                netTokensSaved: inputTokens - finalOutputTokens,
                outputChanged: output != item.input,
                outputStable: Set(outputs.map(sha256)).count == 1,
                outputSHA256: sha256(output),
                output: output,
                handleMarker: handleMarker,
                recoveryReadbackVerified: recoveryReadbackVerified,
                finalEnvelope: finalEnvelope,
                missingRequiredLiterals: qualityResult.missingRequiredLiterals,
                nextActionReady: qualityResult.nextActionReady,
                qualityPassed: qualityResult.qualityPassed
            ))
        }

        let report = BenchmarkReport(
            schemaVersion: 1,
            captureKind: captureKind,
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            tokenCountSource: "omlx:/v1/messages/count_tokens",
            source: SourceIdentity(gitHead: sourceGitHead),
            model: ModelIdentity(id: model, revision: revision, server: "oMLX", serverVersion: serverVersion),
            corpus: CorpusIdentity(id: corpus.corpusID, sha256: corpusHash, caseCount: corpus.cases.count),
            protocolConfiguration: ProtocolConfiguration(
                warmupRuns: warmups,
                measuredRunsPerCase: runs,
                maxOutputCharacters: maxOutputCharacters,
                finalEnvelope: "runtime output plus one deterministic Librarian rcv1 marker after byte-exact put/get readback"
            ),
            cases: caseReports,
            aggregate: aggregate(caseReports)
        )
        let encoded = try reportData(report)
        if !token.isEmpty, String(decoding: encoded, as: UTF8.self).contains(token) {
            throw BenchmarkError.secretLeak("auth token appeared in encoded report")
        }
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.write(to: outputURL, options: .atomic)

        XCTAssertEqual(report.aggregate.qualityPassedCases, corpus.cases.count)
        XCTAssertEqual(report.aggregate.caseCount, corpus.cases.count)
    }
}

private struct BenchmarkCorpus: Codable {
    let schemaVersion: Int
    let corpusID: String
    let description: String
    let cases: [BenchmarkCorpusCase]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case corpusID = "corpus_id"
        case description, cases
    }
}

private struct BenchmarkCorpusCase: Codable {
    let id: String
    let cohort: String
    let input: String
    let question: String
    let nextAction: String
    let requiredLiterals: [String]

    enum CodingKeys: String, CodingKey {
        case id, cohort, input, question
        case nextAction = "next_action"
        case requiredLiterals = "required_literals"
    }
}

private struct QualityResult {
    let missingRequiredLiterals: [String]
    let nextActionReady: Bool
    let qualityPassed: Bool
}

private struct BenchmarkReport: Codable {
    let schemaVersion: Int
    let captureKind: String
    let capturedAt: String
    let tokenCountSource: String
    let source: SourceIdentity
    let model: ModelIdentity
    let corpus: CorpusIdentity
    let protocolConfiguration: ProtocolConfiguration
    let cases: [BenchmarkCaseReport]
    let aggregate: BenchmarkAggregate

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case captureKind = "capture_kind"
        case capturedAt = "captured_at"
        case tokenCountSource = "token_count_source"
        case source, model, corpus, cases, aggregate
        case protocolConfiguration = "protocol"
    }

    static func fixture(corpusSHA256: String) -> BenchmarkReport {
        BenchmarkReport(
            schemaVersion: 1,
            captureKind: "baseline",
            capturedAt: "2026-08-23T00:00:00Z",
            tokenCountSource: "omlx:/v1/messages/count_tokens",
            source: SourceIdentity(gitHead: String(repeating: "a", count: 40)),
            model: ModelIdentity(id: "model", revision: "revision", server: "oMLX", serverVersion: "test"),
            corpus: CorpusIdentity(id: "token-saver-local-llm-v1", sha256: corpusSHA256, caseCount: 1),
            protocolConfiguration: ProtocolConfiguration(
                warmupRuns: 1,
                measuredRunsPerCase: 3,
                maxOutputCharacters: 900,
                finalEnvelope: "runtime output plus handle"
            ),
            cases: [BenchmarkCaseReport(
                id: "TSLLM-001",
                cohort: "fixture",
                route: "llm_mlx",
                routeStable: true,
                measuredRuns: 3,
                latencyMilliseconds: [10, 11, 12],
                medianLatencyMilliseconds: 11,
                inputTokens: 100,
                outputTokensBeforeHandle: 20,
                finalOutputTokens: 27,
                handleOverheadTokens: 7,
                netTokensSaved: 73,
                outputChanged: true,
                outputStable: true,
                outputSHA256: "fixture",
                output: "signal",
                handleMarker: "[[rc:rcv1.0123456789abcdef01234567]]",
                recoveryReadbackVerified: true,
                finalEnvelope: "signal\n[[rc:rcv1.0123456789abcdef01234567]]",
                missingRequiredLiterals: [],
                nextActionReady: true,
                qualityPassed: true
            )],
            aggregate: BenchmarkAggregate(
                caseCount: 1,
                inputTokens: 100,
                outputTokensBeforeHandle: 20,
                finalOutputTokens: 27,
                handleOverheadTokens: 7,
                netTokensSaved: 73,
                netSavingsPercent: 73,
                nextActionReadyCases: 1,
                qualityPassedCases: 1,
                changedCases: 1,
                recoveryReadbackVerifiedCases: 1,
                stableOutputCases: 1,
                stableRouteCases: 1,
                medianCaseLatencyMilliseconds: 11,
                p95CaseLatencyMilliseconds: 11,
                routeCounts: ["llm_mlx": 1]
            )
        )
    }
}

private struct SourceIdentity: Codable {
    let gitHead: String

    enum CodingKeys: String, CodingKey {
        case gitHead = "git_head"
    }
}

private struct ModelIdentity: Codable {
    let id: String
    let revision: String
    let server: String
    let serverVersion: String

    enum CodingKeys: String, CodingKey {
        case id, revision, server
        case serverVersion = "server_version"
    }
}

private struct CorpusIdentity: Codable {
    let id: String
    let sha256: String
    let caseCount: Int

    enum CodingKeys: String, CodingKey {
        case id, sha256
        case caseCount = "case_count"
    }
}

private struct ProtocolConfiguration: Codable {
    let warmupRuns: Int
    let measuredRunsPerCase: Int
    let maxOutputCharacters: Int
    let finalEnvelope: String

    enum CodingKeys: String, CodingKey {
        case warmupRuns = "warmup_runs"
        case measuredRunsPerCase = "measured_runs_per_case"
        case maxOutputCharacters = "max_output_characters"
        case finalEnvelope = "final_envelope"
    }
}

private struct BenchmarkCaseReport: Codable {
    let id: String
    let cohort: String
    let route: String
    let routeStable: Bool
    let measuredRuns: Int
    let latencyMilliseconds: [Int]
    let medianLatencyMilliseconds: Int
    let inputTokens: Int
    let outputTokensBeforeHandle: Int
    let finalOutputTokens: Int
    let handleOverheadTokens: Int
    let netTokensSaved: Int
    let outputChanged: Bool
    let outputStable: Bool
    let outputSHA256: String
    let output: String
    let handleMarker: String?
    let recoveryReadbackVerified: Bool
    let finalEnvelope: String
    let missingRequiredLiterals: [String]
    let nextActionReady: Bool
    let qualityPassed: Bool

    enum CodingKeys: String, CodingKey {
        case id, cohort, route, output
        case routeStable = "route_stable"
        case measuredRuns = "measured_runs"
        case latencyMilliseconds = "latency_ms"
        case medianLatencyMilliseconds = "median_latency_ms"
        case inputTokens = "input_tokens"
        case outputTokensBeforeHandle = "output_tokens_before_handle"
        case finalOutputTokens = "final_output_tokens"
        case handleOverheadTokens = "handle_overhead_tokens"
        case netTokensSaved = "net_tokens_saved"
        case outputChanged = "output_changed"
        case outputStable = "output_stable"
        case outputSHA256 = "output_sha256"
        case handleMarker = "handle_marker"
        case recoveryReadbackVerified = "recovery_readback_verified"
        case finalEnvelope = "final_envelope"
        case missingRequiredLiterals = "missing_required_literals"
        case nextActionReady = "next_action_ready"
        case qualityPassed = "quality_passed"
    }
}

private struct BenchmarkAggregate: Codable {
    let caseCount: Int
    let inputTokens: Int
    let outputTokensBeforeHandle: Int
    let finalOutputTokens: Int
    let handleOverheadTokens: Int
    let netTokensSaved: Int
    let netSavingsPercent: Double
    let nextActionReadyCases: Int
    let qualityPassedCases: Int
    let changedCases: Int
    let recoveryReadbackVerifiedCases: Int
    let stableOutputCases: Int
    let stableRouteCases: Int
    let medianCaseLatencyMilliseconds: Int
    let p95CaseLatencyMilliseconds: Int
    let routeCounts: [String: Int]

    enum CodingKeys: String, CodingKey {
        case caseCount = "case_count"
        case inputTokens = "input_tokens"
        case outputTokensBeforeHandle = "output_tokens_before_handle"
        case finalOutputTokens = "final_output_tokens"
        case handleOverheadTokens = "handle_overhead_tokens"
        case netTokensSaved = "net_tokens_saved"
        case netSavingsPercent = "net_savings_percent"
        case nextActionReadyCases = "next_action_ready_cases"
        case qualityPassedCases = "quality_passed_cases"
        case changedCases = "changed_cases"
        case recoveryReadbackVerifiedCases = "recovery_readback_verified_cases"
        case stableOutputCases = "stable_output_cases"
        case stableRouteCases = "stable_route_cases"
        case medianCaseLatencyMilliseconds = "median_case_latency_ms"
        case p95CaseLatencyMilliseconds = "p95_case_latency_ms"
        case routeCounts = "route_counts"
    }
}

private struct TokenCountResponse: Decodable {
    let inputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
    }
}

private enum BenchmarkError: LocalizedError {
    case invalidConfiguration(String)
    case invalidCorpus(String)
    case transport(String)
    case secretLeak(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .invalidCorpus(let message), .transport(let message), .secretLeak(let message):
            return message
        }
    }
}

private extension TokenSaverLocalLLMBenchmarkTests {
    func loadCorpus() throws -> (corpus: BenchmarkCorpus, data: Data) {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = testsDirectory.appendingPathComponent("Fixtures/TokenSaverLocalLLM/corpus.json")
        let data = try Data(contentsOf: url)
        return (try JSONDecoder.benchmark.decode(BenchmarkCorpus.self, from: data), data)
    }

    func quality(
        for item: BenchmarkCorpusCase,
        output: String,
        handleMarker: String?,
        recoveryReadbackVerified: Bool
    ) -> QualityResult {
        let missing = item.requiredLiterals.filter { !output.contains($0) }
        let ready = missing.isEmpty
        let recoverable = recoveryReadbackVerified && (handleMarker.map(isLibrarianHandleMarker) ?? false)
        return QualityResult(
            missingRequiredLiterals: missing,
            nextActionReady: ready,
            qualityPassed: ready || recoverable
        )
    }

    func isLibrarianHandleMarker(_ marker: String) -> Bool {
        marker.range(of: #"^\[\[rc:rcv1\.[0-9a-f]{24}\]\]$"#, options: .regularExpression) != nil
    }

    func makeFinalEnvelope(output: String, handleMarker: String?) -> String {
        guard let handleMarker else { return output }
        if output.contains(handleMarker) { return output }
        return output + (output.hasSuffix("\n") ? "" : "\n") + handleMarker
    }

    func aggregate(_ cases: [BenchmarkCaseReport]) -> BenchmarkAggregate {
        let input = cases.reduce(0) { $0 + $1.inputTokens }
        let beforeHandle = cases.reduce(0) { $0 + $1.outputTokensBeforeHandle }
        let final = cases.reduce(0) { $0 + $1.finalOutputTokens }
        var routes: [String: Int] = [:]
        for item in cases { routes[item.route, default: 0] += 1 }
        return BenchmarkAggregate(
            caseCount: cases.count,
            inputTokens: input,
            outputTokensBeforeHandle: beforeHandle,
            finalOutputTokens: final,
            handleOverheadTokens: cases.reduce(0) { $0 + $1.handleOverheadTokens },
            netTokensSaved: input - final,
            netSavingsPercent: input == 0 ? 0 : Double(input - final) / Double(input) * 100,
            nextActionReadyCases: cases.filter(\.nextActionReady).count,
            qualityPassedCases: cases.filter(\.qualityPassed).count,
            changedCases: cases.filter(\.outputChanged).count,
            recoveryReadbackVerifiedCases: cases.filter(\.recoveryReadbackVerified).count,
            stableOutputCases: cases.filter(\.outputStable).count,
            stableRouteCases: cases.filter(\.routeStable).count,
            medianCaseLatencyMilliseconds: percentile(cases.map(\.medianLatencyMilliseconds), percentile: 0.50),
            p95CaseLatencyMilliseconds: percentile(cases.map(\.medianLatencyMilliseconds), percentile: 0.95),
            routeCounts: routes
        )
    }

    func countTokens(
        _ text: String,
        baseURL: URL,
        model: String,
        token: String,
        timeout: TimeInterval
    ) async throws -> Int {
        let url = baseURL.appendingPathComponent("messages/count_tokens")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": text]],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BenchmarkError.transport("oMLX token counter returned HTTP \(status)")
        }
        return try JSONDecoder().decode(TokenCountResponse.self, from: data).inputTokens
    }

    func fetchServerVersion(baseURL: URL) async -> String? {
        let root = baseURL.deletingLastPathComponent()
        let url = root.appendingPathComponent("openapi.json")
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = object["info"] as? [String: Any],
              let version = info["version"] as? String,
              !version.isEmpty else {
            return nil
        }
        return version
    }

    func requiredLocalBaseURL(_ rawValue: String?) throws -> URL {
        let value = try required(rawValue, name: "RC_TOKEN_SAVER_BENCHMARK_BASE_URL")
        guard let url = URL(string: value),
              url.scheme == "http",
              ["127.0.0.1", "localhost", "::1"].contains(url.host),
              url.path.hasSuffix("/v1") else {
            throw BenchmarkError.invalidConfiguration("benchmark base URL must be loopback HTTP ending in /v1")
        }
        return url
    }

    func required(_ rawValue: String?, name: String) throws -> String {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw BenchmarkError.invalidConfiguration("missing \(name)")
        }
        return value
    }

    func requiredGitHead(_ rawValue: String?) throws -> String {
        let value = try required(rawValue, name: "RC_TOKEN_SAVER_BENCHMARK_SOURCE_GIT_HEAD")
        guard value.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw BenchmarkError.invalidConfiguration("RC_TOKEN_SAVER_BENCHMARK_SOURCE_GIT_HEAD must be a full lowercase Git SHA")
        }
        return value
    }

    func boundedInteger(_ rawValue: String?, defaultValue: Int, range: ClosedRange<Int>, name: String) throws -> Int {
        guard let rawValue, !rawValue.isEmpty else { return defaultValue }
        guard let value = Int(rawValue), range.contains(value) else {
            throw BenchmarkError.invalidConfiguration("\(name) must be in \(range)")
        }
        return value
    }

    func percentile(_ values: [Int], percentile: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * percentile)) - 1))
        return sorted[index]
    }

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func sha256(_ string: String) -> String {
        sha256(Data(string.utf8))
    }

    func reportData(_ report: BenchmarkReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
}

private extension JSONDecoder {
    static var benchmark: JSONDecoder {
        JSONDecoder()
    }
}
