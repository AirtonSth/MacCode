import CryptoKit
import Foundation
import Persistence
import XCTest
@testable import DistillCore

final class TokenSaverTechniqueBenchmarkTests: XCTestCase {
    private static let expectedFixtureSHA256 = "183f33c9d25fc5ac7d07631dd99f9e03bb141464ce22d0816a03107763cb3143"

    func test_lockedFixturePinsTechniquesCatalogCountsAndEvidencePositions() throws {
        let (fixture, data) = try loadFixture()

        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.corpusID, "token-saver-techniques-v1")
        XCTAssertEqual(sha256(data), Self.expectedFixtureSHA256, "technique corpus changed without a protocol revision")
        XCTAssertEqual(fixture.techniqueA.expectedCatalog.total, 188)
        XCTAssertEqual(fixture.techniqueA.expectedCatalog.baselineExposed, 169)
        XCTAssertEqual(fixture.techniqueA.expectedCatalog.enabled, 168)
        XCTAssertEqual(fixture.techniqueA.expectedCatalog.forbidden, 19)
        XCTAssertEqual(fixture.techniqueA.expectedCatalog.disabled, 1)
        XCTAssertEqual(fixture.techniqueA.expectedCatalog.hotHints, 8)
        XCTAssertEqual(LibrarianCatalog.all.count, fixture.techniqueA.expectedCatalog.total)
        XCTAssertEqual(LibrarianCatalog.forbiddenIDs.count, fixture.techniqueA.expectedCatalog.forbidden)
        XCTAssertEqual(LibrarianCatalog.disabledOnNineB.count, fixture.techniqueA.expectedCatalog.disabled)
        XCTAssertEqual(LibrarianCatalog.implementedIDs.count, fixture.techniqueA.expectedCatalog.enabled)
        XCTAssertEqual(LibrarianCatalog.hotHintIDs.count, fixture.techniqueA.expectedCatalog.hotHints)

        XCTAssertEqual(Set(fixture.techniqueA.episodes.map(\.kind)), ["hot", "cold"])
        XCTAssertEqual(Set(fixture.techniqueB.episodes.map(\.requiresRetrieve)), [false, true])
        XCTAssertEqual(Set(fixture.techniqueC.cases.map(\.evidencePosition)), ["head", "middle", "tail"])
        for item in fixture.techniqueC.cases {
            let source = expandedSource(item)
            let baseline = validUTF8Prefix(source, byteLimit: fixture.techniqueC.budgetBytes)
            XCTAssertGreaterThan(source.utf8.count, fixture.techniqueC.budgetBytes, item.id)
            XCTAssertEqual(baseline.contains(item.evidence), item.baselineShouldContain, item.id)

            let pack = LibrarianEvidencePack(budgetBytes: fixture.techniqueC.budgetBytes).pack(
                source: source,
                question: item.question
            )
            XCTAssertLessThanOrEqual(pack.renderedByteCount, fixture.techniqueC.budgetBytes, item.id)
            XCTAssertTrue(pack.verbatimSegmentsAreValid(in: source), item.id)
            for literal in item.requiredLiterals {
                XCTAssertTrue(pack.containsExactSpan(literal, in: source), "\(item.id) omitted \(literal)")
            }
        }
    }

    func test_candidateSchemaIsAnthropicShapedAndColdLookupKeepsOnlyEnabledOperations() async throws {
        let fixture = try loadFixture().fixture
        let candidate = try await candidateAnthropicTools()
        let baseline = baselineAnthropicTools()
        let candidateAsk = try XCTUnwrap(candidate.first { $0["name"] as? String == "rc_ask" })
        let candidateSchema = try XCTUnwrap(candidateAsk["input_schema"] as? [String: Any])
        let candidateProperties = try XCTUnwrap(candidateSchema["properties"] as? [String: Any])
        let candidateOp = try XCTUnwrap(candidateProperties["op"] as? [String: Any])

        XCTAssertNil(candidateOp["enum"], "candidate schema must defer the 168-id catalog")
        XCTAssertNotNil(candidate.first { $0["name"] as? String == "rc_catalog" })
        XCTAssertNil(candidate.first?["inputSchema"], "provider exposure must use Anthropic input_schema")

        let baselineAsk = try XCTUnwrap(baseline.first { $0["name"] as? String == "rc_ask" })
        let baselineSchema = try XCTUnwrap(baselineAsk["input_schema"] as? [String: Any])
        let baselineProperties = try XCTUnwrap(baselineSchema["properties"] as? [String: Any])
        let baselineEnum = try XCTUnwrap((baselineProperties["op"] as? [String: Any])?["enum"] as? [String])
        XCTAssertEqual(baselineEnum.count, fixture.techniqueA.expectedCatalog.baselineExposed)
        XCTAssertTrue(LibrarianCatalog.disabledOnNineB.isSubset(of: Set(baselineEnum)))

        let cold = try XCTUnwrap(fixture.techniqueA.episodes.first { $0.kind == "cold" })
        let page = try LibrarianCatalog.page(query: cold.catalogQuery, cursor: nil, limit: 1)
        XCTAssertEqual(page.items.map(\.id), [cold.op])
        XCTAssertFalse(LibrarianCatalog.forbiddenIDs.contains(cold.op))
        XCTAssertFalse(LibrarianCatalog.disabledOnNineB.contains(cold.op))
    }

    func test_duplicateCaptureUsesScopedPersistenceAndShippingFailOpen() async throws {
        let fixture = try loadFixture().fixture
        let episodes = try await makeVerifiedDuplicateEpisodes(fixture.techniqueB)

        XCTAssertEqual(episodes.count, 2)
        XCTAssertTrue(episodes.allSatisfy { isProductionCapabilityMarker($0.marker) })
        XCTAssertTrue(episodes.allSatisfy(\.scopedPrepareReadbackVerified))
        XCTAssertTrue(episodes.allSatisfy(\.failOpenVerified))
        XCTAssertNil(episodes.first { !$0.requiresRetrieve }?.retrieved)
        XCTAssertEqual(episodes.first { $0.requiresRetrieve }?.retrieved, episodes.first { $0.requiresRetrieve }?.original)
        XCTAssertFalse(isProductionCapabilityMarker("[[rc:rcv1.too-short]]"))
    }

    func test_shellVerifierRejectsDirtySourceAndHashMismatchAndFabricatedRecovery() throws {
        let repository = repositoryURL()
        let head = try git(["rev-parse", "HEAD"], repository: repository)
        let tree = try git(["rev-parse", "HEAD^{tree}"], repository: repository)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-saver-technique-verifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let validURL = temporary.appendingPathComponent("valid.json")
        try writeJSONObject(
            fixtureArtifact(head: head, tree: tree, dirty: false, fixtureSHA: Self.expectedFixtureSHA256, readback: true),
            to: validURL
        )
        XCTAssertEqual(try verifierExitCode(validURL, repository: repository), 0)

        let dirtyURL = temporary.appendingPathComponent("dirty.json")
        try writeJSONObject(
            fixtureArtifact(head: head, tree: tree, dirty: true, fixtureSHA: Self.expectedFixtureSHA256, readback: true),
            to: dirtyURL
        )
        XCTAssertNotEqual(try verifierExitCode(dirtyURL, repository: repository), 0)

        let sourceMismatchURL = temporary.appendingPathComponent("source-mismatch.json")
        try writeJSONObject(
            fixtureArtifact(head: String(repeating: "b", count: 40), tree: tree, dirty: false, fixtureSHA: Self.expectedFixtureSHA256, readback: true),
            to: sourceMismatchURL
        )
        XCTAssertNotEqual(try verifierExitCode(sourceMismatchURL, repository: repository), 0)

        let hashMismatchURL = temporary.appendingPathComponent("hash-mismatch.json")
        try writeJSONObject(
            fixtureArtifact(head: head, tree: tree, dirty: false, fixtureSHA: String(repeating: "0", count: 64), readback: true),
            to: hashMismatchURL
        )
        XCTAssertNotEqual(try verifierExitCode(hashMismatchURL, repository: repository), 0)

        let fabricatedURL = temporary.appendingPathComponent("fabricated.json")
        try writeJSONObject(
            fixtureArtifact(head: head, tree: tree, dirty: false, fixtureSHA: Self.expectedFixtureSHA256, readback: false),
            to: fabricatedURL
        )
        XCTAssertNotEqual(try verifierExitCode(fabricatedURL, repository: repository), 0)
    }

    func test_extendedVerifierReconcilesDAndEveryTerminalCandidateArtifact() throws {
        let repository = repositoryURL()
        let benchmarkDirectory = repository.appendingPathComponent("docs/benchmarks/token-saver-local-llm")
        let techniqueDURL = benchmarkDirectory.appendingPathComponent("technique-D.json")
        let terminalURL = benchmarkDirectory.appendingPathComponent("terminal-candidates.json")
        let iterationsURL = benchmarkDirectory.appendingPathComponent("iterations.json")

        XCTAssertEqual(try verifierExitCode(techniqueDURL, repository: repository, command: "verify-d"), 0)
        XCTAssertEqual(try verifierExitCode(terminalURL, repository: repository, command: "verify-terminal-candidates"), 0)
        XCTAssertEqual(try verifierExitCode(iterationsURL, repository: repository, command: "verify-iterations"), 0)
        XCTAssertEqual(
            try verifierExitCode(
                iterationsURL,
                repository: repository,
                command: "verify-iterations",
                scriptName: "token-saver-local-llm-benchmark.sh"
            ),
            0
        )

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-saver-extended-verifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        var dirtyD = try loadJSONObject(techniqueDURL)
        var dirtySource = dirtyD["source"] as! [String: Any]
        dirtySource["dirty"] = true
        dirtyD["source"] = dirtySource
        let dirtyDURL = temporary.appendingPathComponent("dirty-D.json")
        try writeJSONObject(dirtyD, to: dirtyDURL)
        XCTAssertNotEqual(try verifierExitCode(dirtyDURL, repository: repository, command: "verify-d"), 0)

        var inconsistentTerminal = try loadJSONObject(terminalURL)
        var measurements = inconsistentTerminal["measurements"] as! [[String: Any]]
        measurements[0]["input_tokens"] = (measurements[0]["input_tokens"] as! Int) + 1
        inconsistentTerminal["measurements"] = measurements
        let inconsistentTerminalURL = temporary.appendingPathComponent("inconsistent-terminal.json")
        try writeJSONObject(inconsistentTerminal, to: inconsistentTerminalURL)
        XCTAssertNotEqual(
            try verifierExitCode(inconsistentTerminalURL, repository: repository, command: "verify-terminal-candidates"),
            0
        )

        var missingEvidencePath = try loadJSONObject(terminalURL)
        var sourceEvidence = missingEvidencePath["source_evidence"] as! [[String: Any]]
        sourceEvidence[0]["path"] = "Sources/DistillCore/does-not-exist.swift"
        missingEvidencePath["source_evidence"] = sourceEvidence
        let missingEvidencePathURL = temporary.appendingPathComponent("missing-evidence-path.json")
        try writeJSONObject(missingEvidencePath, to: missingEvidencePathURL)
        XCTAssertNotEqual(
            try verifierExitCode(missingEvidencePathURL, repository: repository, command: "verify-terminal-candidates"),
            0
        )

        var fabricatedZeroTerminal = try loadJSONObject(terminalURL)
        var terminalCandidates = fabricatedZeroTerminal["candidates"] as! [[String: Any]]
        let unmeasuredCandidateIndex = try XCTUnwrap(
            terminalCandidates.firstIndex { $0["id"] as? String == "compact_all_text_notices" }
        )
        terminalCandidates[unmeasuredCandidateIndex]["measured_tokens_saved"] = 0
        fabricatedZeroTerminal["candidates"] = terminalCandidates
        let fabricatedZeroTerminalURL = temporary.appendingPathComponent("fabricated-zero-terminal.json")
        try writeJSONObject(fabricatedZeroTerminal, to: fabricatedZeroTerminalURL)
        XCTAssertNotEqual(
            try verifierExitCode(fabricatedZeroTerminalURL, repository: repository, command: "verify-terminal-candidates"),
            0
        )

        var badHashIterations = try loadJSONObject(iterationsURL)
        var badHashRows = badHashIterations["iterations"] as! [[String: Any]]
        badHashRows[0]["artifact_sha256"] = String(repeating: "0", count: 64)
        badHashIterations["iterations"] = badHashRows
        let badHashURL = temporary.appendingPathComponent("bad-hash-iterations.json")
        try writeJSONObject(badHashIterations, to: badHashURL)
        XCTAssertNotEqual(try verifierExitCode(badHashURL, repository: repository, command: "verify-iterations"), 0)
        XCTAssertNotEqual(
            try verifierExitCode(
                badHashURL,
                repository: repository,
                command: "verify-iterations",
                scriptName: "token-saver-local-llm-benchmark.sh"
            ),
            0
        )

        var badDecisionIterations = try loadJSONObject(iterationsURL)
        var badDecisionRows = badDecisionIterations["iterations"] as! [[String: Any]]
        let dIndex = try XCTUnwrap(badDecisionRows.firstIndex { $0["technique"] as? String == "D" })
        badDecisionRows[dIndex]["decision"] = "accepted"
        badDecisionRows[dIndex]["status"] = "accepted"
        badDecisionIterations["iterations"] = badDecisionRows
        let badDecisionURL = temporary.appendingPathComponent("bad-decision-iterations.json")
        try writeJSONObject(badDecisionIterations, to: badDecisionURL)
        XCTAssertNotEqual(try verifierExitCode(badDecisionURL, repository: repository, command: "verify-iterations"), 0)

        var fabricatedZeroIterations = try loadJSONObject(iterationsURL)
        var fabricatedZeroRows = fabricatedZeroIterations["iterations"] as! [[String: Any]]
        let fIndex = try XCTUnwrap(fabricatedZeroRows.firstIndex { $0["id"] as? String == "F-global-text-notices" })
        fabricatedZeroRows[fIndex]["measured_additional_tokens"] = 0
        fabricatedZeroRows[fIndex]["net_tokens_saved"] = 0
        fabricatedZeroIterations["iterations"] = fabricatedZeroRows
        let fabricatedZeroIterationsURL = temporary.appendingPathComponent("fabricated-zero-iterations.json")
        try writeJSONObject(fabricatedZeroIterations, to: fabricatedZeroIterationsURL)
        XCTAssertNotEqual(
            try verifierExitCode(fabricatedZeroIterationsURL, repository: repository, command: "verify-iterations"),
            0
        )
        XCTAssertNotEqual(
            try verifierExitCode(
                fabricatedZeroIterationsURL,
                repository: repository,
                command: "verify-iterations",
                scriptName: "token-saver-local-llm-benchmark.sh"
            ),
            0
        )

        var missingTerminalCandidate = try loadJSONObject(iterationsURL)
        var incompleteRows = missingTerminalCandidate["iterations"] as! [[String: Any]]
        let kIndex = try XCTUnwrap(
            incompleteRows.firstIndex { $0["id"] as? String == "K-reversible-payload-compactor" }
        )
        incompleteRows.remove(at: kIndex)
        missingTerminalCandidate["iterations"] = incompleteRows
        let missingTerminalCandidateURL = temporary.appendingPathComponent("missing-terminal-candidate.json")
        try writeJSONObject(missingTerminalCandidate, to: missingTerminalCandidateURL)
        XCTAssertNotEqual(
            try verifierExitCode(missingTerminalCandidateURL, repository: repository, command: "verify-iterations"),
            0
        )

        var missingEveryTerminalCandidate = try loadJSONObject(iterationsURL)
        var onlyTechniqueRows = missingEveryTerminalCandidate["iterations"] as! [[String: Any]]
        onlyTechniqueRows.removeAll {
            guard let technique = $0["technique"] as? String else { return false }
            return !["A", "B", "C", "D"].contains(technique)
        }
        missingEveryTerminalCandidate["iterations"] = onlyTechniqueRows
        let missingEveryTerminalCandidateURL = temporary.appendingPathComponent("missing-every-terminal-candidate.json")
        try writeJSONObject(missingEveryTerminalCandidate, to: missingEveryTerminalCandidateURL)
        XCTAssertNotEqual(
            try verifierExitCode(
                missingEveryTerminalCandidateURL,
                repository: repository,
                command: "verify-iterations"
            ),
            0
        )

        var duplicateTechniqueA = try loadJSONObject(iterationsURL)
        var duplicateTechniqueRows = duplicateTechniqueA["iterations"] as! [[String: Any]]
        var duplicateA = try XCTUnwrap(duplicateTechniqueRows.first { $0["technique"] as? String == "A" })
        duplicateA["id"] = "A-duplicate"
        duplicateTechniqueRows.append(duplicateA)
        duplicateTechniqueA["iterations"] = duplicateTechniqueRows
        let duplicateTechniqueAURL = temporary.appendingPathComponent("duplicate-technique-A.json")
        try writeJSONObject(duplicateTechniqueA, to: duplicateTechniqueAURL)
        XCTAssertNotEqual(
            try verifierExitCode(duplicateTechniqueAURL, repository: repository, command: "verify-iterations"),
            0
        )
    }

    func test_suiteVerifierRejectsManifestNumbersThatDisagreeWithHashedArtifacts() throws {
        let repository = repositoryURL()
        let suiteURL = repository.appendingPathComponent("docs/benchmarks/token-saver-local-llm/suite.json")
        XCTAssertEqual(try verifierExitCode(suiteURL, repository: repository, command: "verify-suite"), 0)

        var adulteratedSuite = try loadJSONObject(suiteURL)
        var artifacts = adulteratedSuite["artifacts"] as! [[String: Any]]
        let techniqueAIndex = try XCTUnwrap(artifacts.firstIndex { $0["technique"] as? String == "A" })
        artifacts[techniqueAIndex]["net_tokens_saved"] = 1_935
        adulteratedSuite["artifacts"] = artifacts
        adulteratedSuite["aggregate_net_tokens_saved"] = 26_968

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("adulterated-token-saver-suite-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try writeJSONObject(adulteratedSuite, to: temporaryURL)

        XCTAssertNotEqual(try verifierExitCode(temporaryURL, repository: repository, command: "verify-suite"), 0)
    }

    /// Manual, env-gated A/B/C capture. Counts the exact canonical Anthropic request
    /// bodies against oMLX and records hashes, never auth or invented measurements.
    func test_liveCaptureAgainstOMLX() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RC_TOKEN_SAVER_TECHNIQUE_BENCHMARK"] == "1" else {
            throw XCTSkip("Use scripts/token-saver-technique-benchmark.sh capture for live measurement.")
        }

        let fixture = try loadFixture().fixture
        let configuration = try LiveConfiguration(environment: environment)
        let serverVersion = try await fetchServerVersion(configuration.baseURL)
        let artifact: [String: Any]
        switch configuration.technique {
        case "A":
            artifact = try await captureCatalog(fixture.techniqueA, configuration: configuration, serverVersion: serverVersion)
        case "B":
            artifact = try await captureDuplicate(fixture.techniqueB, configuration: configuration, serverVersion: serverVersion)
        case "C":
            artifact = try await captureEvidence(fixture.techniqueC, configuration: configuration, serverVersion: serverVersion)
        default:
            throw TechniqueBenchmarkError.invalidConfiguration("technique must be A, B, or C")
        }

        let encoded = try canonicalData(artifact, prettyPrinted: true)
        // Low-entropy development keys (for example "none") can legitimately equal
        // accounting enum values. No auth field is serialized; exact-value scanning is
        // an additional guard only when the credential has enough entropy to identify it.
        if configuration.token.count >= 12, containsExactString(configuration.token, in: artifact) {
            throw TechniqueBenchmarkError.invalidArtifact("auth token appeared in report")
        }
        let output = URL(fileURLWithPath: configuration.outputPath)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.write(to: output, options: .atomic)
    }
}

private extension TokenSaverTechniqueBenchmarkTests {
    func captureCatalog(
        _ fixture: TechniqueAFixture,
        configuration: LiveConfiguration,
        serverVersion: String
    ) async throws -> [String: Any] {
        let baselineTools = baselineAnthropicTools()
        let candidateTools = try await candidateAnthropicTools()
        var results: [[String: Any]] = []

        for episode in fixture.episodes {
            let user = episode.question
            let baselineBody = anthropicBody(
                model: configuration.model,
                system: fixture.system,
                messages: [["role": "user", "content": user]],
                tools: baselineTools
            )
            let candidateBody = anthropicBody(
                model: configuration.model,
                system: fixture.system,
                messages: [["role": "user", "content": user]],
                tools: candidateTools
            )
            var surfaces = [
                try await measure(
                    name: "baseline_tools_exposure",
                    surface: "anthropic.system+messages+baseline_tools",
                    body: baselineBody,
                    accountTo: "baseline",
                    debit: "none",
                    configuration: configuration
                ),
                try await measure(
                    name: "candidate_tools_exposure",
                    surface: "anthropic.system+messages+candidate_tools",
                    body: candidateBody,
                    accountTo: "candidate",
                    debit: "none",
                    configuration: configuration
                ),
            ]

            var operationReachable = LibrarianCatalog.implementedIDs.contains(episode.op)
            if episode.kind == "cold" {
                let page = try LibrarianCatalog.page(query: episode.catalogQuery, cursor: nil, limit: 1)
                operationReachable = page.items.map(\.id) == [episode.op]
                let pageData = try canonicalData(page)
                let pageText = String(decoding: pageData, as: UTF8.self)
                let lookupBody = anthropicBody(
                    model: configuration.model,
                    system: fixture.system,
                    messages: [
                        ["role": "user", "content": user],
                        ["role": "assistant", "content": [[
                            "type": "tool_use",
                            "id": "toolu_catalog_1",
                            "name": "rc_catalog",
                            "input": ["query": episode.catalogQuery, "limit": 1],
                        ]]],
                        ["role": "user", "content": [[
                            "type": "tool_result",
                            "tool_use_id": "toolu_catalog_1",
                            "content": pageText,
                        ]]],
                    ],
                    tools: candidateTools
                )
                surfaces.append(try await measure(
                    name: "candidate_catalog_lookup",
                    surface: "anthropic.catalog_tool_use+tool_result+candidate_tools",
                    body: lookupBody,
                    accountTo: "candidate",
                    debit: "lookup",
                    configuration: configuration
                ))
            }

            let quality: [String: Any] = [
                "catalog_total": fixture.expectedCatalog.total,
                "catalog_enabled": LibrarianCatalog.implementedIDs.count,
                "catalog_forbidden": LibrarianCatalog.forbiddenIDs.count,
                "catalog_disabled": LibrarianCatalog.disabledOnNineB.count,
                "forbidden_hidden": LibrarianCatalog.forbiddenIDs.isDisjoint(with: Set(LibrarianCatalog.implementedIDs)),
                "disabled_hidden": LibrarianCatalog.disabledOnNineB.isDisjoint(with: Set(LibrarianCatalog.implementedIDs)),
                "operation_reachable": operationReachable,
            ]
            results.append(caseObject(id: episode.id, surfaces: surfaces, quality: quality, qualityPassed: operationReachable))
        }
        return artifact(technique: "A", cases: results, configuration: configuration, serverVersion: serverVersion)
    }

    func captureDuplicate(
        _ fixture: TechniqueBFixture,
        configuration: LiveConfiguration,
        serverVersion: String
    ) async throws -> [String: Any] {
        let tools: [[String: Any]] = [[
            "name": "rc_retrieve",
            "description": "Retrieve a scoped byte-exact original.",
            "input_schema": [
                "type": "object",
                "properties": ["handle": ["type": "string"]],
                "required": ["handle"],
            ],
        ]]
        let system = "Treat an rcv1 marker as recoverable only after byte-exact rc_retrieve readback."
        let episodes = try await makeVerifiedDuplicateEpisodes(fixture)
        var results: [[String: Any]] = []
        var sensitivityResults: [[String: Any]] = []

        for episode in episodes {
            let accountBaseline = episode.requiresRetrieve ? "none" : "baseline"
            let accountCandidate = episode.requiresRetrieve ? "none" : "candidate"
            let baselineMessages = duplicateMessages(question: episode.question, first: episode.original, second: episode.duplicate)
            let candidateMessages = duplicateMessages(question: episode.question, first: episode.original, second: episode.notice)
            var surfaces = [
                try await measure(
                    name: "baseline_repeated_transcript",
                    surface: "anthropic.duplicate_transcript.full_second_output",
                    body: anthropicBody(model: configuration.model, system: system, messages: baselineMessages, tools: tools),
                    accountTo: accountBaseline,
                    debit: "none",
                    scenarioSide: episode.requiresRetrieve ? "baseline" : nil,
                    configuration: configuration
                ),
                try await measure(
                    name: "candidate_handle_transcript",
                    surface: "anthropic.duplicate_transcript.production_notice",
                    body: anthropicBody(model: configuration.model, system: system, messages: candidateMessages, tools: tools),
                    accountTo: accountCandidate,
                    debit: "none",
                    scenarioSide: episode.requiresRetrieve ? "candidate" : nil,
                    configuration: configuration
                ),
            ]

            if episode.requiresRetrieve {
                let retrieveMessages = candidateMessages + [
                    ["role": "assistant", "content": [[
                        "type": "tool_use",
                        "id": "toolu_retrieve_1",
                        "name": "rc_retrieve",
                        "input": ["handle": String(episode.marker.dropFirst(5).dropLast(2))],
                    ]]],
                    ["role": "user", "content": [[
                        "type": "tool_result",
                        "tool_use_id": "toolu_retrieve_1",
                        "content": episode.retrieved!,
                    ]]],
                ]
                surfaces.append(try await measure(
                    name: "candidate_retrieve_readback",
                    surface: "anthropic.rc_retrieve_tool_use+byte_exact_tool_result",
                    body: anthropicBody(model: configuration.model, system: system, messages: retrieveMessages, tools: tools),
                    accountTo: "none",
                    debit: "retrieve",
                    scenarioSide: "candidate",
                    configuration: configuration
                ))
            }

            let quality: [String: Any] = [
                "requires_retrieve": episode.requiresRetrieve,
                "marker_wire_format_valid": isProductionCapabilityMarker(episode.marker),
                "marker_in_production_notice": episode.notice.contains(episode.marker),
                "source_duplicate_equal": episode.original == episode.duplicate,
                "scoped_prepare_readback_verified": episode.scopedPrepareReadbackVerified,
                "retrieve_exact_readback_verified": episode.retrieveExactReadbackVerified,
                "fail_open_verified": episode.failOpenVerified,
                "capture_mode": "shipping_persistence_in_memory",
            ]
            if episode.requiresRetrieve {
                sensitivityResults.append(sensitivityCaseObject(
                    id: episode.id,
                    surfaces: surfaces,
                    quality: quality,
                    qualityPassed: true
                ))
            } else {
                results.append(caseObject(id: episode.id, surfaces: surfaces, quality: quality, qualityPassed: true))
            }
        }
        var report = artifact(technique: "B", cases: results, configuration: configuration, serverVersion: serverVersion)
        report["sensitivity_cases"] = sensitivityResults
        var aggregate = report["aggregate"] as! [String: Any]
        aggregate["sensitivity_case_count"] = sensitivityResults.count
        aggregate["sensitivity_retrieve_debit_tokens"] = sensitivityResults.reduce(0) {
            $0 + ($1["retrieve_debit_tokens"] as? Int ?? 0)
        }
        report["aggregate"] = aggregate
        return report
    }

    func captureEvidence(
        _ fixture: TechniqueCFixture,
        configuration: LiveConfiguration,
        serverVersion: String
    ) async throws -> [String: Any] {
        let runtime = OpenAICompatibleDistillRuntime(
            baseURL: configuration.baseURL,
            model: configuration.model,
            token: configuration.token,
            timeout: configuration.timeout
        )
        guard await runtime.rawGenerate(system: "Reply only READY.", user: "ready", maxTokens: 8) != nil else {
            throw TechniqueBenchmarkError.transport("oMLX warmup failed")
        }
        let providerTools: [[String: Any]] = [[
            "name": "rc_retrieve",
            "description": "Retrieve the scoped byte-exact original only when local evidence is insufficient.",
            "input_schema": [
                "type": "object",
                "properties": ["handle": ["type": "string"]],
                "required": ["handle"],
            ],
        ]]
        var results: [[String: Any]] = []

        for item in fixture.cases {
            let source = expandedSource(item)
            let baselineView = validUTF8Prefix(source, byteLimit: fixture.budgetBytes)
            let pack = LibrarianEvidencePack(budgetBytes: fixture.budgetBytes).pack(source: source, question: item.question)
            let baselineUser = localEvidenceUser(question: item.question, sourceView: baselineView)
            let candidateUser = localEvidenceUser(question: item.question, sourceView: pack.text)

            let baselineStart = Date()
            let baselineOutput = await runtime.rawGenerate(system: fixture.localSystem, user: baselineUser, maxTokens: 64) ?? "UNAVAILABLE"
            let baselineGenerationMS = elapsedMilliseconds(since: baselineStart)
            let candidateStart = Date()
            let candidateOutput = await runtime.rawGenerate(system: fixture.localSystem, user: candidateUser, maxTokens: 64) ?? "UNAVAILABLE"
            let candidateGenerationMS = elapsedMilliseconds(since: candidateStart)
            let baselineSuccess = item.requiredLiterals.allSatisfy { baselineOutput.contains($0) }
            let candidateSuccess = item.requiredLiterals.allSatisfy { candidateOutput.contains($0) }

            // Technique C measures the decision debit with a conspicuously synthetic,
            // wire-shaped handle. Only B is allowed to claim a production capability.
            let handle = "rcv1.AAAAAAAAAAAAAAAAAAAAAA"
            let marker = "[[rc:\(handle)]]"
            var surfaces = [
                try await measure(
                    name: "baseline_local_prompt",
                    surface: "anthropic.full_system+baseline_prefix_user",
                    body: anthropicBody(model: configuration.model, system: fixture.localSystem, messages: [["role": "user", "content": baselineUser]], tools: []),
                    accountTo: "none",
                    debit: "none",
                    generationLatencyMS: baselineGenerationMS,
                    configuration: configuration
                ),
                try await measure(
                    name: "candidate_local_prompt",
                    surface: "anthropic.full_system+ranked_pack_user",
                    body: anthropicBody(model: configuration.model, system: fixture.localSystem, messages: [["role": "user", "content": candidateUser]], tools: []),
                    accountTo: "none",
                    debit: "none",
                    generationLatencyMS: candidateGenerationMS,
                    configuration: configuration
                ),
            ]
            let baselineProviderMessages = providerOutcomeMessages(question: item.question, output: baselineOutput, marker: marker)
            let candidateProviderMessages = providerOutcomeMessages(question: item.question, output: candidateOutput, marker: marker)
            surfaces.append(try await measure(
                name: "baseline_provider_outcome",
                surface: "anthropic.provider_facing_local_outcome+handle",
                body: anthropicBody(model: configuration.model, system: fixture.providerSystem, messages: baselineProviderMessages, tools: providerTools),
                accountTo: "baseline",
                debit: "none",
                configuration: configuration
            ))
            surfaces.append(try await measure(
                name: "candidate_provider_outcome",
                surface: "anthropic.provider_facing_local_outcome+handle",
                body: anthropicBody(model: configuration.model, system: fixture.providerSystem, messages: candidateProviderMessages, tools: providerTools),
                accountTo: "candidate",
                debit: "none",
                configuration: configuration
            ))
            if !baselineSuccess {
                surfaces.append(try await measure(
                    name: "baseline_retrieve_debit",
                    surface: "anthropic.provider_rc_retrieve+byte_exact_original",
                    body: anthropicBody(
                        model: configuration.model,
                        system: fixture.providerSystem,
                        messages: retrieveMessages(from: baselineProviderMessages, handle: handle, original: source, id: "baseline"),
                        tools: providerTools
                    ),
                    accountTo: "baseline",
                    debit: "retrieve",
                    configuration: configuration
                ))
            }
            if !candidateSuccess {
                surfaces.append(try await measure(
                    name: "candidate_retrieve_debit",
                    surface: "anthropic.provider_rc_retrieve+byte_exact_original",
                    body: anthropicBody(
                        model: configuration.model,
                        system: fixture.providerSystem,
                        messages: retrieveMessages(from: candidateProviderMessages, handle: handle, original: source, id: "candidate"),
                        tools: providerTools
                    ),
                    accountTo: "candidate",
                    debit: "retrieve",
                    configuration: configuration
                ))
            }

            let noRegression = !baselineSuccess || candidateSuccess
            let quality: [String: Any] = [
                "source_bytes": source.utf8.count,
                "budget_bytes": fixture.budgetBytes,
                "evidence_position": item.evidencePosition,
                "baseline_expected_to_contain": item.baselineShouldContain,
                "baseline_view_contains_required": item.requiredLiterals.allSatisfy { baselineView.contains($0) },
                "baseline_success": baselineSuccess,
                "candidate_success": candidateSuccess,
                "baseline_success_regression": !noRegression,
                "ranked_pack_verbatim": pack.verbatimSegmentsAreValid(in: source),
                "ranked_pack_contains_required": item.requiredLiterals.allSatisfy { pack.containsExactSpan($0, in: source) },
                "recovery_mode": "in_process_synthetic",
                "production_recovery_claimed": false,
                "synthetic_retrieve_payload_exact": true,
                "baseline_output_sha256": sha256(baselineOutput),
                "candidate_output_sha256": sha256(candidateOutput),
            ]
            results.append(caseObject(
                id: item.id,
                surfaces: surfaces,
                quality: quality,
                qualityPassed: candidateSuccess && noRegression
            ))
        }
        return artifact(technique: "C", cases: results, configuration: configuration, serverVersion: serverVersion)
    }

    func artifact(
        technique: String,
        cases: [[String: Any]],
        configuration: LiveConfiguration,
        serverVersion: String
    ) -> [String: Any] {
        let baseline = cases.reduce(0) { $0 + ($1["baseline_tokens"] as? Int ?? 0) }
        let candidate = cases.reduce(0) { $0 + ($1["candidate_tokens"] as? Int ?? 0) }
        let lookup = cases.reduce(0) { $0 + ($1["lookup_debit_tokens"] as? Int ?? 0) }
        let retrieve = cases.reduce(0) { $0 + ($1["retrieve_debit_tokens"] as? Int ?? 0) }
        let qualityPassed = cases.filter { $0["quality_passed"] as? Bool == true }.count
        let regressions = cases.filter {
            (($0["quality"] as? [String: Any])?["baseline_success_regression"] as? Bool) == true
        }.count
        let caseLatencies = cases.compactMap { $0["p50_latency_ms"] as? Int }
        let accepted = candidate < baseline && qualityPassed == cases.count && regressions == 0
        return [
            "schema_version": 1,
            "suite_id": "token-saver-techniques-v1",
            "technique": technique,
            "captured_at": ISO8601DateFormatter().string(from: Date()),
            "token_count_source": "omlx:/v1/messages/count_tokens",
            "source": [
                "git_head": configuration.captureSHA,
                "tree_sha": configuration.sourceTreeSHA,
                "dirty": configuration.sourceDirty,
            ],
            "comparison": [
                "baseline_git_sha": configuration.baselineSHA,
                "candidate_git_sha": configuration.candidateSHA,
            ],
            "fixture": [
                "id": "token-saver-techniques-v1",
                "sha256": Self.expectedFixtureSHA256,
            ],
            "model": [
                "id": configuration.model,
                "revision": configuration.revision,
                "server": "oMLX",
                "server_version": serverVersion,
            ],
            "cases": cases,
            "aggregate": [
                "case_count": cases.count,
                "baseline_tokens": baseline,
                "candidate_tokens": candidate,
                "lookup_debit_tokens": lookup,
                "retrieve_debit_tokens": retrieve,
                "net_tokens_saved": baseline - candidate,
                "quality_passed_cases": qualityPassed,
                "baseline_success_regressions": regressions,
                "p50_latency_ms": percentile(caseLatencies, 0.50),
                "p95_latency_ms": percentile(caseLatencies, 0.95),
            ],
            "decision": accepted ? "accepted" : "rejected",
            "decision_reason": accepted
                ? "positive exact provider-context savings with every technique quality gate passing"
                : "rejected because exact net savings were not positive or a quality gate regressed",
        ]
    }

    func caseObject(
        id: String,
        surfaces: [MeasuredSurface],
        quality: [String: Any],
        qualityPassed: Bool
    ) -> [String: Any] {
        let baseline = surfaces.filter { $0.accountTo == "baseline" }.reduce(0) { $0 + $1.inputTokens }
        let candidate = surfaces.filter { $0.accountTo == "candidate" }.reduce(0) { $0 + $1.inputTokens }
        let latencies = surfaces.map(\.countLatencyMS)
        return [
            "id": id,
            "surfaces": surfaces.map(\.jsonObject),
            "baseline_tokens": baseline,
            "candidate_tokens": candidate,
            "lookup_debit_tokens": surfaces.filter { $0.debit == "lookup" }.reduce(0) { $0 + $1.inputTokens },
            "retrieve_debit_tokens": surfaces.filter { $0.debit == "retrieve" }.reduce(0) { $0 + $1.inputTokens },
            "net_tokens_saved": baseline - candidate,
            "p50_latency_ms": percentile(latencies, 0.50),
            "p95_latency_ms": percentile(latencies, 0.95),
            "quality_passed": qualityPassed,
            "quality": quality,
        ]
    }

    func sensitivityCaseObject(
        id: String,
        surfaces: [MeasuredSurface],
        quality: [String: Any],
        qualityPassed: Bool
    ) -> [String: Any] {
        let baseline = surfaces.filter { $0.scenarioSide == "baseline" }.reduce(0) { $0 + $1.inputTokens }
        let candidate = surfaces.filter { $0.scenarioSide == "candidate" }.reduce(0) { $0 + $1.inputTokens }
        let latencies = surfaces.map(\.countLatencyMS)
        return [
            "id": id,
            "accounting_mode": "sensitivity_only",
            "surfaces": surfaces.map(\.jsonObject),
            "scenario_baseline_tokens": baseline,
            "scenario_candidate_tokens": candidate,
            "retrieve_debit_tokens": surfaces.filter { $0.debit == "retrieve" }.reduce(0) { $0 + $1.inputTokens },
            "scenario_net_tokens_saved": baseline - candidate,
            "p50_latency_ms": percentile(latencies, 0.50),
            "p95_latency_ms": percentile(latencies, 0.95),
            "quality_passed": qualityPassed,
            "quality": quality,
        ]
    }

    func measure(
        name: String,
        surface: String,
        body: [String: Any],
        accountTo: String,
        debit: String,
        scenarioSide: String? = nil,
        generationLatencyMS: Int? = nil,
        configuration: LiveConfiguration
    ) async throws -> MeasuredSurface {
        let data = try canonicalData(body)
        let started = Date()
        let count = try await countTokens(data, configuration: configuration)
        return MeasuredSurface(
            name: name,
            surface: surface,
            canonicalBodySHA256: sha256(data),
            canonicalBodyBytes: data.count,
            accountTo: accountTo,
            debit: debit,
            scenarioSide: scenarioSide,
            inputTokens: count,
            countLatencyMS: elapsedMilliseconds(since: started),
            generationLatencyMS: generationLatencyMS
        )
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
            throw TechniqueBenchmarkError.transport("oMLX count_tokens returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["input_tokens"] as? Int,
              tokens >= 0 else {
            throw TechniqueBenchmarkError.transport("oMLX count_tokens returned an invalid body")
        }
        return tokens
    }

    func fetchServerVersion(_ baseURL: URL) async throws -> String {
        let url = baseURL.deletingLastPathComponent().appendingPathComponent("openapi.json")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = object["info"] as? [String: Any],
              let version = info["version"] as? String,
              !version.isEmpty else {
            throw TechniqueBenchmarkError.transport("oMLX server version is unavailable")
        }
        return version
    }

    func candidateAnthropicTools() async throws -> [[String: Any]] {
        let server = ManagedRetrieveMCP(retrieve: { _ in nil })
        guard let line = await server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#),
              let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            throw TechniqueBenchmarkError.invalidArtifact("candidate tools/list was invalid")
        }
        return tools.map { tool in
            [
                "name": tool["name"]!,
                "description": tool["description"]!,
                "input_schema": tool["inputSchema"]!,
            ]
        }
    }

    func baselineAnthropicTools() -> [[String: Any]] {
        let oldImplemented = LibrarianCatalog.all
            .filter { $0.safety != .forbidden }
            .map(\.id)
        return [
            [
                "name": "rc_stats",
                "description": "Return local RemoteCode Token Saver measurement stats with their evidence labels.",
                "input_schema": ["type": "object", "properties": [String: Any]()],
            ],
            [
                "name": "rc_search",
                "description": "Search Token Saver reversible handles by query. Miss is not evidence of absence.",
                "input_schema": [
                    "type": "object",
                    "properties": ["query": ["type": "string"], "topK": ["type": "integer"]],
                    "required": ["query"],
                ],
            ],
            [
                "name": "rc_ask",
                "description": "Run a Token Saver catalog function from 01-catalogo.html on the user's selected Distill model (Settings 1.7B / E4B / OpenAI-compat). op is a catalog id. Host-only ops return unavailable; forbidden ops are refused.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "op": ["type": "string", "enum": oldImplemented],
                        "input": ["type": "string"],
                        "question": ["type": "string"],
                        "handle": ["type": "string"],
                    ],
                    "required": ["op"],
                ],
            ],
        ]
    }

    func anthropicBody(
        model: String,
        system: String,
        messages: [[String: Any]],
        tools: [[String: Any]]
    ) -> [String: Any] {
        var body: [String: Any] = ["model": model, "system": system, "messages": messages]
        if !tools.isEmpty { body["tools"] = tools }
        return body
    }

    func duplicateMessages(question: String, first: String, second: String) -> [[String: Any]] {
        [
            ["role": "user", "content": question],
            ["role": "assistant", "content": [["type": "tool_use", "id": "toolu_output_1", "name": "captured_command", "input": [String: Any]()]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_output_1", "content": first]]],
            ["role": "assistant", "content": [["type": "tool_use", "id": "toolu_output_2", "name": "captured_command", "input": [String: Any]()]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_output_2", "content": second]]],
        ]
    }

    func providerOutcomeMessages(question: String, output: String, marker: String) -> [[String: Any]] {
        [
            ["role": "user", "content": question],
            ["role": "assistant", "content": [["type": "tool_use", "id": "toolu_local_1", "name": "rc_ask", "input": ["question": question]]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_local_1", "content": "\(output)\n\(marker)"]]],
        ]
    }

    func retrieveMessages(from messages: [[String: Any]], handle: String, original: String, id: String) -> [[String: Any]] {
        messages + [
            ["role": "assistant", "content": [["type": "tool_use", "id": "toolu_retrieve_\(id)", "name": "rc_retrieve", "input": ["handle": handle]]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_retrieve_\(id)", "content": original]]],
        ]
    }

    func localEvidenceUser(question: String, sourceView: String) -> String {
        "Question:\n\(question)\n\nSource view (verbatim evidence only):\n\(sourceView)"
    }

    func expandedSource(_ item: TechniqueCCase) -> String {
        var lines = (0..<item.lineCount).map { "\(item.noisePrefix)-\($0)-abcdefghijklmnopqrstuvwxyz-0123456789" }
        lines[item.evidenceLine] = item.evidence
        return lines.joined(separator: "\n")
    }

    func validUTF8Prefix(_ source: String, byteLimit: Int) -> String {
        let bytes = Array(source.utf8.prefix(byteLimit))
        var end = bytes.count
        while end > 0, String(bytes: bytes[..<end], encoding: .utf8) == nil { end -= 1 }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    func makeVerifiedDuplicateEpisodes(_ fixture: TechniqueBFixture) async throws -> [ValidatedDuplicateEpisode] {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let projectID = "token-saver-technique-b"
        try TokenSaverLaneStateRepository(db: db).ensureDefaults(projectID: projectID)
        let scope = TokenSaverPersistentScope(
            workspaceID: "benchmark-workspace",
            projectID: projectID,
            threadID: "benchmark-thread",
            provider: "codex",
            attemptID: "benchmark-attempt"
        )
        let disk = TokenSaverRecoveryDiskSnapshot(
            freeBytes: 20 * 1_024 * 1_024 * 1_024,
            totalBytes: 100 * 1_024 * 1_024 * 1_024
        )
        let recovery = TokenSaverScopedRecoveryStore(db: db)
        let worker = TokenSaverRuntimeRecoveryWorker(db: db)
        var captures: [ValidatedDuplicateEpisode] = []

        for (index, contract) in fixture.episodes.enumerated() {
            let original = String(
                repeating: "shipping wrapper output \(contract.id) byte-identical row\n",
                count: 48 + index
            ) + "final status: PASS\n"
            let data = Data(original.utf8)
            let prepared = try worker.prepareOriginal(
                data,
                scope: scope,
                operationID: "technique-b-\(contract.id.lowercased())",
                lane: "deterministic_wrapper",
                disk: disk
            )
            let readback = try recovery.retrieve(capability: prepared.capability, scope: scope)
            let scopedReadbackVerified = prepared.readBackVerified && readback == data
            guard scopedReadbackVerified, isProductionCapabilityMarker("[[rc:\(prepared.capability)]]") else {
                throw TechniqueBenchmarkError.invalidArtifact("shipping scoped preparation failed: \(contract.id)")
            }

            let dispatcher = LibrarianDispatcher()
            _ = dispatcher.store.put(original, handle: prepared.capability)
            let result = await dispatcher.dispatch(LibrarianRequest(
                id: "duplicate_handle_notice",
                input: original,
                handle: prepared.capability,
                provider: "codex",
                retrieveAvailable: true,
                verifiedRecoveryHandle: prepared.capability
            ))
            let marker = "[[rc:\(prepared.capability)]]"
            guard result.status == .ok, result.text.contains(marker), result.text != original else {
                throw TechniqueBenchmarkError.invalidArtifact("shipping duplicate notice failed: \(contract.id)")
            }

            let unbound = LibrarianDispatcher()
            let failed = await unbound.dispatch(LibrarianRequest(
                id: "duplicate_handle_notice",
                input: original,
                handle: prepared.capability,
                provider: "codex",
                retrieveAvailable: true,
                verifiedRecoveryHandle: prepared.capability
            ))
            let failOpenVerified = failed.text == original && failed.analytics.savedTokens == 0
            guard failOpenVerified else {
                throw TechniqueBenchmarkError.invalidArtifact("shipping duplicate fail-open failed: \(contract.id)")
            }

            let retrieved = contract.requiresRetrieve ? String(data: readback!, encoding: .utf8) : nil
            captures.append(ValidatedDuplicateEpisode(
                id: contract.id,
                question: contract.question,
                requiresRetrieve: contract.requiresRetrieve,
                marker: marker,
                notice: result.text,
                original: original,
                duplicate: original,
                retrieved: retrieved,
                scopedPrepareReadbackVerified: scopedReadbackVerified,
                retrieveExactReadbackVerified: contract.requiresRetrieve ? retrieved == original : false,
                failOpenVerified: failOpenVerified
            ))
        }
        return captures
    }

    func isProductionCapabilityMarker(_ marker: String) -> Bool {
        marker.range(
            of: #"^\[\[rc:rcv1\.[A-Za-z0-9_-]{22}\]\]$"#,
            options: .regularExpression
        ) != nil
    }

    func loadFixture() throws -> (fixture: TechniqueFixture, data: Data) {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = tests.appendingPathComponent("Fixtures/TokenSaverLocalLLM/technique-corpus.json")
        let data = try Data(contentsOf: url)
        return (try JSONDecoder().decode(TechniqueFixture.self, from: data), data)
    }

    func repositoryURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func verifierExitCode(
        _ artifact: URL,
        repository: URL,
        command: String = "verify",
        scriptName: String = "token-saver-technique-benchmark.sh"
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repository.appendingPathComponent("scripts/\(scriptName)").path, command, artifact.path]
        process.currentDirectoryURL = repository
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func loadJSONObject(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func git(_ arguments: [String], repository: URL) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path] + arguments
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TechniqueBenchmarkError.invalidConfiguration("git failed") }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func fixtureArtifact(head: String, tree: String, dirty: Bool, fixtureSHA: String, readback: Bool) -> [String: Any] {
        let surface: [String: Any] = [
            "name": "fixture",
            "surface": "anthropic.fixture",
            "canonical_body_sha256": String(repeating: "1", count: 64),
            "canonical_body_bytes": 100,
            "account_to": "baseline",
            "debit": "none",
            "input_tokens": 100,
            "count_latency_ms": 1,
        ]
        let candidateSurface: [String: Any] = [
            "name": "fixture-candidate",
            "surface": "anthropic.fixture.candidate",
            "canonical_body_sha256": String(repeating: "2", count: 64),
            "canonical_body_bytes": 50,
            "account_to": "candidate",
            "debit": "none",
            "input_tokens": 50,
            "count_latency_ms": 1,
        ]
        let retrieveSurface: [String: Any] = [
            "name": "fixture-retrieve",
            "surface": "anthropic.fixture.retrieve",
            "canonical_body_sha256": String(repeating: "3", count: 64),
            "canonical_body_bytes": 30,
            "account_to": "none",
            "debit": "retrieve",
            "scenario_side": "candidate",
            "input_tokens": 30,
            "count_latency_ms": 1,
        ]
        func quality(requiresRetrieve: Bool, readback: Bool) -> [String: Any] {
            [
                "requires_retrieve": requiresRetrieve,
                "marker_wire_format_valid": true,
                "marker_in_production_notice": true,
                "source_duplicate_equal": true,
                "scoped_prepare_readback_verified": true,
                "retrieve_exact_readback_verified": readback,
                "fail_open_verified": true,
                "capture_mode": "shipping_persistence_in_memory",
            ]
        }
        var sensitivityBaseline = surface
        sensitivityBaseline["account_to"] = "none"
        sensitivityBaseline["scenario_side"] = "baseline"
        var sensitivityCandidate = candidateSurface
        sensitivityCandidate["account_to"] = "none"
        sensitivityCandidate["scenario_side"] = "candidate"
        return [
            "schema_version": 1,
            "suite_id": "token-saver-techniques-v1",
            "technique": "B",
            "captured_at": "2026-08-23T00:00:00Z",
            "token_count_source": "omlx:/v1/messages/count_tokens",
            "source": ["git_head": head, "tree_sha": tree, "dirty": dirty],
            "comparison": ["baseline_git_sha": head, "candidate_git_sha": head],
            "fixture": ["id": "token-saver-techniques-v1", "sha256": fixtureSHA],
            "model": ["id": "fixture-model", "revision": String(repeating: "a", count: 40), "server": "oMLX", "server_version": "fixture-version"],
            "cases": [[
                "id": "B-NO-RETRIEVE",
                "surfaces": [surface, candidateSurface],
                "baseline_tokens": 100,
                "candidate_tokens": 50,
                "lookup_debit_tokens": 0,
                "retrieve_debit_tokens": 0,
                "net_tokens_saved": 50,
                "p50_latency_ms": 1,
                "p95_latency_ms": 1,
                "quality_passed": true,
                "quality": quality(requiresRetrieve: false, readback: false),
            ]],
            "sensitivity_cases": [[
                "id": "B-WITH-RETRIEVE",
                "accounting_mode": "sensitivity_only",
                "surfaces": [sensitivityBaseline, sensitivityCandidate, retrieveSurface],
                "scenario_baseline_tokens": 100,
                "scenario_candidate_tokens": 80,
                "retrieve_debit_tokens": 30,
                "scenario_net_tokens_saved": 20,
                "p50_latency_ms": 1,
                "p95_latency_ms": 1,
                "quality_passed": readback,
                "quality": quality(requiresRetrieve: true, readback: readback),
            ]],
            "aggregate": [
                "case_count": 1,
                "baseline_tokens": 100,
                "candidate_tokens": 50,
                "lookup_debit_tokens": 0,
                "retrieve_debit_tokens": 0,
                "net_tokens_saved": 50,
                "quality_passed_cases": 1,
                "baseline_success_regressions": 0,
                "p50_latency_ms": 1,
                "p95_latency_ms": 1,
                "sensitivity_case_count": 1,
                "sensitivity_retrieve_debit_tokens": 30,
            ],
            "decision": "accepted",
            "decision_reason": "fixture",
        ]
    }

    func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        try canonicalData(object, prettyPrinted: true).write(to: url, options: .atomic)
    }

    func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    func canonicalData(_ object: Any, prettyPrinted: Bool = false) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if prettyPrinted { options.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func sha256(_ value: String) -> String { sha256(Data(value.utf8)) }

    func containsExactString(_ needle: String, in value: Any) -> Bool {
        if let string = value as? String { return string == needle }
        if let array = value as? [Any] { return array.contains { containsExactString(needle, in: $0) } }
        if let dictionary = value as? [String: Any] {
            return dictionary.contains { key, child in key == needle || containsExactString(needle, in: child) }
        }
        return false
    }

    func percentile(_ values: [Int], _ fraction: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))
        return sorted[index]
    }

    func elapsedMilliseconds(since date: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(date) * 1_000).rounded()))
    }

    func required(_ raw: String?, name: String) throws -> String {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw TechniqueBenchmarkError.invalidConfiguration("missing \(name)")
        }
        return value
    }
}

private struct LiveConfiguration {
    let technique: String
    let baseURL: URL
    let model: String
    let revision: String
    let token: String
    let baselineSHA: String
    let candidateSHA: String
    let captureSHA: String
    let sourceTreeSHA: String
    let sourceDirty: Bool
    let outputPath: String
    let timeout: TimeInterval

    init(environment: [String: String]) throws {
        func require(_ name: String) throws -> String {
            guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                throw TechniqueBenchmarkError.invalidConfiguration("missing \(name)")
            }
            return value
        }
        technique = try require("RC_TOKEN_SAVER_TECHNIQUE")
        let rawURL = try require("RC_TOKEN_SAVER_BENCHMARK_BASE_URL")
        guard let parsed = URL(string: rawURL), parsed.scheme == "http",
              ["127.0.0.1", "localhost", "::1"].contains(parsed.host),
              parsed.path.hasSuffix("/v1") else {
            throw TechniqueBenchmarkError.invalidConfiguration("benchmark URL must be loopback HTTP ending in /v1")
        }
        baseURL = parsed
        model = try require("RC_TOKEN_SAVER_BENCHMARK_MODEL")
        revision = try require("RC_TOKEN_SAVER_BENCHMARK_MODEL_REVISION")
        token = environment["RC_TOKEN_SAVER_BENCHMARK_AUTH_TOKEN"] ?? ""
        baselineSHA = try require("RC_TOKEN_SAVER_TECHNIQUE_BASELINE_SHA")
        candidateSHA = try require("RC_TOKEN_SAVER_TECHNIQUE_CANDIDATE_SHA")
        captureSHA = try require("RC_TOKEN_SAVER_TECHNIQUE_SOURCE_GIT_SHA")
        sourceTreeSHA = try require("RC_TOKEN_SAVER_TECHNIQUE_SOURCE_TREE_SHA")
        sourceDirty = environment["RC_TOKEN_SAVER_TECHNIQUE_SOURCE_DIRTY"] == "1"
        outputPath = try require("RC_TOKEN_SAVER_TECHNIQUE_OUTPUT")
        timeout = TimeInterval(Int(environment["RC_TOKEN_SAVER_BENCHMARK_TIMEOUT_SECONDS"] ?? "30") ?? 30)
        let shaPattern = #"^[0-9a-f]{40}$"#
        guard baselineSHA.range(of: shaPattern, options: .regularExpression) != nil,
              candidateSHA.range(of: shaPattern, options: .regularExpression) != nil,
              captureSHA.range(of: shaPattern, options: .regularExpression) != nil,
              sourceTreeSHA.range(of: shaPattern, options: .regularExpression) != nil,
              timeout >= 5, timeout <= 120 else {
            throw TechniqueBenchmarkError.invalidConfiguration("invalid source SHA or timeout")
        }
    }
}

private struct MeasuredSurface {
    let name: String
    let surface: String
    let canonicalBodySHA256: String
    let canonicalBodyBytes: Int
    let accountTo: String
    let debit: String
    let scenarioSide: String?
    let inputTokens: Int
    let countLatencyMS: Int
    let generationLatencyMS: Int?

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "name": name,
            "surface": surface,
            "canonical_body_sha256": canonicalBodySHA256,
            "canonical_body_bytes": canonicalBodyBytes,
            "account_to": accountTo,
            "debit": debit,
            "input_tokens": inputTokens,
            "count_latency_ms": countLatencyMS,
        ]
        if let generationLatencyMS { object["generation_latency_ms"] = generationLatencyMS }
        if let scenarioSide { object["scenario_side"] = scenarioSide }
        return object
    }
}

private struct TechniqueFixture: Decodable {
    let schemaVersion: Int
    let corpusID: String
    let description: String
    let techniqueA: TechniqueAFixture
    let techniqueB: TechniqueBFixture
    let techniqueC: TechniqueCFixture

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case corpusID = "corpus_id"
        case description
        case techniqueA = "technique_a"
        case techniqueB = "technique_b"
        case techniqueC = "technique_c"
    }
}

private struct TechniqueAFixture: Decodable {
    let id: String
    let expectedCatalog: CatalogCounts
    let system: String
    let episodes: [TechniqueAEpisode]

    enum CodingKeys: String, CodingKey {
        case id, system, episodes
        case expectedCatalog = "expected_catalog"
    }
}

private struct CatalogCounts: Decodable {
    let total: Int
    let baselineExposed: Int
    let enabled: Int
    let forbidden: Int
    let disabled: Int
    let hotHints: Int

    enum CodingKeys: String, CodingKey {
        case total, enabled, forbidden, disabled
        case baselineExposed = "baseline_exposed"
        case hotHints = "hot_hints"
    }
}

private struct TechniqueAEpisode: Decodable {
    let id: String
    let kind: String
    let op: String
    let question: String
    let catalogQuery: String

    enum CodingKeys: String, CodingKey {
        case id, kind, op, question
        case catalogQuery = "catalog_query"
    }
}

private struct TechniqueBFixture: Decodable {
    let id: String
    let description: String
    let episodes: [TechniqueBEpisode]
}

private struct TechniqueBEpisode: Decodable {
    let id: String
    let requiresRetrieve: Bool
    let question: String

    enum CodingKeys: String, CodingKey {
        case id, question
        case requiresRetrieve = "requires_retrieve"
    }
}

private struct TechniqueCFixture: Decodable {
    let id: String
    let budgetBytes: Int
    let localSystem: String
    let providerSystem: String
    let cases: [TechniqueCCase]

    enum CodingKeys: String, CodingKey {
        case id, cases
        case budgetBytes = "budget_bytes"
        case localSystem = "local_system"
        case providerSystem = "provider_system"
    }
}

private struct TechniqueCCase: Decodable {
    let id: String
    let evidencePosition: String
    let lineCount: Int
    let evidenceLine: Int
    let noisePrefix: String
    let evidence: String
    let question: String
    let requiredLiterals: [String]
    let baselineShouldContain: Bool

    enum CodingKeys: String, CodingKey {
        case id, evidence, question
        case evidencePosition = "evidence_position"
        case lineCount = "line_count"
        case evidenceLine = "evidence_line"
        case noisePrefix = "noise_prefix"
        case requiredLiterals = "required_literals"
        case baselineShouldContain = "baseline_should_contain"
    }
}

private struct ValidatedDuplicateEpisode {
    let id: String
    let question: String
    let requiresRetrieve: Bool
    let marker: String
    let notice: String
    let original: String
    let duplicate: String
    let retrieved: String?
    let scopedPrepareReadbackVerified: Bool
    let retrieveExactReadbackVerified: Bool
    let failOpenVerified: Bool
}

private enum TechniqueBenchmarkError: LocalizedError {
    case invalidConfiguration(String)
    case invalidArtifact(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let value), .invalidArtifact(let value), .transport(let value): value
        }
    }
}
