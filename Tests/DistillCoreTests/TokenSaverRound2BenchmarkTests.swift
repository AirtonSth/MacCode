import CryptoKit
import Foundation
import Persistence
import XCTest
@testable import DistillCore

final class TokenSaverRound2BenchmarkTests: XCTestCase {
    private static let fixtureSHA256 = "2f7f815fa8efa3891809c1b66cbcc1b495c016d848401cf78d628cd836c00749"
    private static let techniqueID = "librarian-success-fallback-question-elision-v1"
    private static let slashTechniqueID = "librarian-envelope-unescaped-slashes-v1"
    private static let catalogTestDiffSHA256 = "adcd7491dc68ec0cf3654b3321e3964f1dcb0e4289b3aa195fc9b6ed51ad14f3"

    func test_fixtureFreezesTwentyFourAdversarialShippingCases() throws {
        let (fixture, bytes) = try loadFixture()
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.techniqueID, Self.techniqueID)
        XCTAssertEqual(fixture.counter, "anthropic-v1-shipping-episode")
        XCTAssertEqual(fixture.cases.count, 24)
        XCTAssertEqual(Set(fixture.cases.map(\.id)).count, 24)
        XCTAssertEqual(sha256(bytes), Self.fixtureSHA256)

        for item in fixture.cases {
            XCTAssertFalse(item.question.isEmpty, item.id)
            XCTAssertTrue(item.source.contains(item.span), "\(item.id) span is not verbatim")
            for literal in item.requiredLiterals {
                XCTAssertTrue(
                    item.answer.contains(literal) || item.span.contains(literal) || item.source.contains(literal),
                    "\(item.id) lost required literal \(literal)"
                )
            }
            for forbidden in item.forbiddenLiterals {
                XCTAssertFalse(item.answer.contains(forbidden), "\(item.id) delivered forbidden claim \(forbidden)")
            }
        }
    }

    func test_successfulLibrarianEnvelopeShipsThroughActualMCPFraming() async throws {
        let item = try loadFixture().fixture.cases[0]
        let recovery = try RecoveryContext.temporary(cases: [item])
        defer { recovery.removeTemporaryFiles() }
        let episode = try await shippingEpisode(item, recovery: recovery)
        XCTAssertEqual(episode.envelope.status, .ok)
        XCTAssertEqual(episode.envelope.op, "ask_handle")
        XCTAssertEqual(episode.envelope.answer, .object(["text": .string(item.answer)]))
        XCTAssertEqual(episode.envelope.evidence.count, 1)
        XCTAssertEqual(episode.envelope.evidence[0].span, item.span)
        XCTAssertEqual(episode.envelope.fallback.recommended, "retrieve")
        XCTAssertEqual(episode.envelope.evidence[0].handle, episode.envelope.fallback.handle)
        XCTAssertTrue(episode.readbackExact)
        XCTAssertEqual(episode.mcpResult["isError"] as? Bool, false)
        XCTAssertEqual(try envelopeText(from: episode.mcpResult), episode.envelopeJSON)
        XCTAssertEqual(try envelopeText(from: episode.retrieveResult), item.source)
        XCTAssertTrue(episode.durableReadbackExact)
    }

    func test_adversarialVerifierAllowsOnlyQuestionElision() async throws {
        let item = try loadFixture().fixture.cases[8]
        let recovery = try RecoveryContext.temporary(cases: [item])
        defer { recovery.removeTemporaryFiles() }
        let episode = try await shippingEpisode(item, recovery: recovery)
        var baselineObject = try jsonObject(Data(episode.envelopeJSON.utf8))
        var baselineFallback = try requireDictionary(baselineObject["fallback"])
        baselineFallback["question"] = item.question
        baselineObject["fallback"] = baselineFallback
        let baseline = String(decoding: try canonicalJSON(baselineObject), as: UTF8.self)
        var candidate = baselineObject
        var fallback = try requireDictionary(candidate["fallback"])
        fallback.removeValue(forKey: "question")
        candidate["fallback"] = fallback
        let validCandidate = String(decoding: try canonicalJSON(candidate), as: UTF8.self)
        XCTAssertTrue(try differsOnlyBySuccessfulFallbackQuestion(baseline: baseline, candidate: validCandidate))

        let mutations: [(inout [String: Any]) -> Void] = [
            { object in object["status"] = "low_confidence" },
            { object in object["confidence"] = 0.2 },
            { object in object["op"] = "other_op" },
            { object in
                var answer = object["answer"] as? [String: Any] ?? [:]
                answer["text"] = "fabricated answer"
                object["answer"] = answer
            },
            { object in
                var evidence = object["evidence"] as? [[String: Any]] ?? []
                evidence[0]["span"] = "fabricated span"
                object["evidence"] = evidence
            },
            { object in
                var changed = object["fallback"] as? [String: Any] ?? [:]
                changed["handle"] = "rcv1.fabricated"
                object["fallback"] = changed
            },
            { object in object["unexpected"] = true },
        ]
        for mutate in mutations {
            var adulterated = candidate
            mutate(&adulterated)
            let text = String(decoding: try canonicalJSON(adulterated), as: UTF8.self)
            XCTAssertFalse(try differsOnlyBySuccessfulFallbackQuestion(baseline: baseline, candidate: text))
        }

        var retained = candidate
        var retainedFallback = try requireDictionary(retained["fallback"])
        retainedFallback["question"] = "different question"
        retained["fallback"] = retainedFallback
        XCTAssertFalse(try differsOnlyBySuccessfulFallbackQuestion(
            baseline: baseline,
            candidate: String(decoding: try canonicalJSON(retained), as: UTF8.self)
        ))
    }

    func test_rawShippingComparisonRejectsAnyOtherByteChange() throws {
        let question = "why / why?"
        let baselineEnvelope = try canonicalJSON([
            "fallback": ["handle": "rcv1.example", "question": question, "recommended": "retrieve"],
            "status": "ok",
        ])
        let candidateEnvelope = try canonicalJSON([
            "fallback": ["handle": "rcv1.example", "recommended": "retrieve"],
            "status": "ok",
        ])
        let baseline = try canonicalJSON(["other": "a/b", "text": String(decoding: baselineEnvelope, as: UTF8.self)])
        let candidate = try canonicalJSON(["other": "a/b", "text": String(decoding: candidateEnvelope, as: UTF8.self)])
        XCTAssertTrue(try differsOnlyByLiteralQuestionBytes(baseline: baseline, candidate: candidate, question: question))

        let candidateText = String(decoding: candidate, as: UTF8.self)
        let orderedPrefix = #"{"other":"a/b","text":"#
        let reordered = candidateText.hasPrefix(orderedPrefix)
            ? #"{"text":"# + String(candidateText.dropFirst(orderedPrefix.count).dropLast()) + #", "other":"a/b"}"#
            : candidateText
        let mutations = [
            Data((candidateText + "\n").utf8),
            Data(candidateText.replacingOccurrences(of: #""other":"a/b""#, with: #""other": "a/b""#).utf8),
            Data(candidateText.replacingOccurrences(of: "a/b", with: #"a\/b"#).utf8),
            Data(reordered.utf8),
        ]
        for mutation in mutations {
            XCTAssertFalse(try differsOnlyByLiteralQuestionBytes(baseline: baseline, candidate: mutation, question: question))
        }
    }

    func test_slashVerifierRejectsSourceAndRawByteTampering() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("round2-slash-raw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let baselineSource = root.appendingPathComponent("Envelope-baseline.swift")
        let candidateSource = root.appendingPathComponent("Envelope-candidate.swift")
        try Data("let e = JSONEncoder()\n        e.outputFormatting = [.sortedKeys]\nreturn e\n".utf8)
            .write(to: baselineSource)
        try Data("let e = JSONEncoder()\n        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]\nreturn e\n".utf8)
            .write(to: candidateSource)
        XCTAssertEqual(
            try runSlashBenchmark(["verify-slash-product-files", baselineSource.path, candidateSource.path]).status,
            0
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidateSource.path)
        XCTAssertNotEqual(
            try runSlashBenchmark(["verify-slash-product-files", baselineSource.path, candidateSource.path]).status,
            0,
            "an executable-bit source change must be rejected"
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: candidateSource.path)
        try Data("let e = JSONEncoder()\n        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]\nreturn e\n".utf8)
            .write(to: candidateSource, options: .atomic)
        XCTAssertNotEqual(
            try runSlashBenchmark(["verify-slash-product-files", baselineSource.path, candidateSource.path]).status,
            0,
            "an adulterated product transformation must be rejected"
        )

        let baselineEnvelope = #"{"answer":{"text":"Sources\/App.swift"},"fallback":{"handle":"rcv1.test","recommended":"retrieve"},"status":"ok"}"#
        let candidateEnvelope = #"{"answer":{"text":"Sources/App.swift"},"fallback":{"handle":"rcv1.test","recommended":"retrieve"},"status":"ok"}"#
        func providerBody(_ envelope: String) throws -> Data {
            try canonicalJSON([
                "foreign": "https://example.test/a/b",
                "messages": [["content": [[
                    "type": "tool_result",
                    "content": [["type": "text", "text": envelope]],
                ]]]],
            ])
        }
        func emittedBody(_ envelope: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 2,
                "result": ["isError": false, "content": [["type": "text", "text": envelope]]],
            ], options: [.sortedKeys])
        }
        let baselineBody = root.appendingPathComponent("provider-baseline.json")
        let candidateBody = root.appendingPathComponent("provider-candidate.json")
        try providerBody(baselineEnvelope).write(to: baselineBody)
        try providerBody(candidateEnvelope).write(to: candidateBody)
        XCTAssertEqual(
            try runSlashBenchmark(["verify-slash-bytes", "provider", baselineBody.path, candidateBody.path]).status,
            0
        )
        let baselineEmitted = root.appendingPathComponent("emitted-baseline.bin")
        let candidateEmitted = root.appendingPathComponent("emitted-candidate.bin")
        try emittedBody(baselineEnvelope).write(to: baselineEmitted)
        try emittedBody(candidateEnvelope).write(to: candidateEmitted)
        XCTAssertEqual(
            try runSlashBenchmark(["verify-slash-bytes", "emitted", baselineEmitted.path, candidateEmitted.path]).status,
            0
        )

        let sourceMutation = candidateEnvelope.replacingOccurrences(of: "Sources/App.swift", with: "Sources/Other.swift")
        try providerBody(sourceMutation).write(to: candidateBody, options: .atomic)
        XCTAssertNotEqual(
            try runSlashBenchmark(["verify-slash-bytes", "provider", baselineBody.path, candidateBody.path]).status,
            0,
            "semantic source drift must not be hidden by slash normalization"
        )
        try providerBody(baselineEnvelope).write(to: candidateBody, options: .atomic)
        XCTAssertNotEqual(
            try runSlashBenchmark(["verify-slash-bytes", "provider", baselineBody.path, candidateBody.path]).status,
            0,
            "retaining the escaped envelope bytes must not count as the candidate"
        )
        let foreignMutation = String(decoding: try providerBody(candidateEnvelope), as: UTF8.self)
            .replacingOccurrences(of: "https://example.test/a/b", with: #"https:\/\/example.test\/a\/b"#)
        try Data(foreignMutation.utf8).write(to: candidateBody, options: .atomic)
        XCTAssertNotEqual(
            try runSlashBenchmark(["verify-slash-bytes", "provider", baselineBody.path, candidateBody.path]).status,
            0,
            "foreign outer JSON slashes must remain byte-exact"
        )

        let s4Baseline = root.appendingPathComponent("s4-baseline.bin")
        let s4Candidate = root.appendingPathComponent("s4-candidate.bin")
        try Data("unchanged fail-open".utf8).write(to: s4Baseline)
        try Data("changed fail-open".utf8).write(to: s4Candidate)
        XCTAssertNotEqual(
            try runSlashBenchmark(["verify-slash-zero-bytes", s4Baseline.path, s4Candidate.path]).status,
            0,
            "S4 byte drift must be rejected"
        )
    }

    func test_slashVerifierRejectsNegativeAndZeroAggregateTokenSavings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("round2-slash-deltas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let baselineURL = root.appendingPathComponent("baseline.json")
        let candidateURL = root.appendingPathComponent("candidate.json")
        let scenarios = ["S0", "S2", "S4", "S6"]
        func report(_ tokens: [String: Int]) throws -> Data {
            try canonicalJSON(["cases": [[
                "id": "R2Q-001",
                "scenarios": scenarios.map { ["id": $0, "input_tokens": tokens[$0]!] },
            ]]])
        }
        let baseline = Dictionary(uniqueKeysWithValues: scenarios.map { ($0, 100) })
        try report(baseline).write(to: baselineURL)
        try report(["S0": 99, "S2": 99, "S4": 100, "S6": 99]).write(to: candidateURL)
        let valid = try runSlashBenchmark(["verify-slash-deltas", baselineURL.path, candidateURL.path])
        XCTAssertEqual(
            valid.status,
            0,
            valid.stderr
        )

        try report(["S0": 101, "S2": 99, "S4": 100, "S6": 99]).write(to: candidateURL, options: .atomic)
        XCTAssertNotEqual(
            try runSlashBenchmark(["verify-slash-deltas", baselineURL.path, candidateURL.path]).status,
            0,
            "a negative per-case token delta must be rejected"
        )
        try report(baseline).write(to: candidateURL, options: .atomic)
        XCTAssertNotEqual(
            try runSlashBenchmark(["verify-slash-deltas", baselineURL.path, candidateURL.path]).status,
            0,
            "zero aggregate savings must be rejected for S0/S2/S6"
        )
        try report(["S0": 99, "S2": 99, "S4": 99, "S6": 99]).write(to: candidateURL, options: .atomic)
        XCTAssertNotEqual(
            try runSlashBenchmark(["verify-slash-deltas", baselineURL.path, candidateURL.path]).status,
            0,
            "S4 token drift must be rejected"
        )
    }

    func test_slashReportMetadataRejectsQuestionElisionLabels() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("round2-slash-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reportURL = root.appendingPathComponent("report.json")
        let slashReasons = [
            ["id": "S1", "reason": "slash unescaping applies only to serialized successful envelopes; no catalog lookup is required"],
            ["id": "S3", "reason": "slash escaping does not change generation, parsing, or retry behavior"],
            ["id": "S5", "reason": "S1 and S3 are source-bound not applicable for this slash-unescaping technique"],
        ]
        let oldReasons = [
            ["id": "S1", "reason": "ask_handle is a hot declared tool; no catalog lookup is required"],
            ["id": "S3", "reason": "field elision does not change generation, parsing, or retry behavior"],
            ["id": "S5", "reason": "S1 and S3 are source-bound not applicable for this field-only technique"],
        ]
        XCTAssertEqual(
            CaptureProfile.envelopeSlashes.applicableExpectedDelta,
            "nonnegative_per_case_positive_aggregate"
        )
        XCTAssertEqual(CaptureProfile.envelopeSlashes.s4ExpectedDelta, "not_applicable_zero")
        XCTAssertEqual(CaptureProfile.envelopeSlashes.notApplicableMetadata, slashReasons)
        func report(expected: [String: String], reasons: [[String: String]]) throws -> Data {
            try canonicalJSON([
                "technique_id": Self.slashTechniqueID,
                "cases": [[
                    "scenarios": ["S0", "S2", "S4", "S6"].map {
                        ["id": $0, "expected_delta": expected[$0]!]
                    },
                    "not_applicable": reasons,
                ]],
            ])
        }
        let slashExpected = [
            "S0": "nonnegative_per_case_positive_aggregate",
            "S2": "nonnegative_per_case_positive_aggregate",
            "S4": "not_applicable_zero",
            "S6": "nonnegative_per_case_positive_aggregate",
        ]
        try report(expected: slashExpected, reasons: slashReasons).write(to: reportURL)
        let valid = try runSlashBenchmark(["verify-report-metadata", reportURL.path])
        XCTAssertEqual(valid.status, 0, valid.stderr)

        var oldExpected = slashExpected
        oldExpected["S0"] = "positive"
        try report(expected: oldExpected, reasons: slashReasons).write(to: reportURL, options: .atomic)
        XCTAssertNotEqual(
            try runSlashBenchmark(["verify-report-metadata", reportURL.path]).status,
            0,
            "the old positive label is false for slash cases whose measured delta is zero"
        )

        try report(expected: slashExpected, reasons: oldReasons).write(to: reportURL, options: .atomic)
        XCTAssertNotEqual(
            try runSlashBenchmark(["verify-report-metadata", reportURL.path]).status,
            0,
            "question-field elision reasons must not describe slash escaping"
        )
    }

    func test_questionElisionReportMetadataPreservesExistingContract() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("round2-question-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reportURL = root.appendingPathComponent("report.json")
        let expected = ["S0": "positive", "S2": "positive", "S4": "zero", "S6": "positive"]
        let reasons = [
            ["id": "S1", "reason": "ask_handle is a hot declared tool; no catalog lookup is required"],
            ["id": "S3", "reason": "field elision does not change generation, parsing, or retry behavior"],
            ["id": "S5", "reason": "S1 and S3 are source-bound not applicable for this field-only technique"],
        ]
        XCTAssertEqual(CaptureProfile.questionElision.applicableExpectedDelta, "positive")
        XCTAssertEqual(CaptureProfile.questionElision.s4ExpectedDelta, "zero")
        XCTAssertEqual(CaptureProfile.questionElision.notApplicableMetadata, reasons)
        let report = try canonicalJSON([
            "technique_id": Self.techniqueID,
            "cases": [[
                "scenarios": ["S0", "S2", "S4", "S6"].map {
                    ["id": $0, "expected_delta": expected[$0]!]
                },
                "not_applicable": reasons,
            ]],
        ])
        try report.write(to: reportURL)

        let result = try runBenchmark(["verify-report-metadata", reportURL.path])
        XCTAssertEqual(result.status, 0, result.stderr)
    }

    func test_verifierHashesRawEmbeddedEnvelopeTextWithoutReserializing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("round2-envelope-hash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let envelope = #"{"fallback":{"question":"Was it in Sources\/App.swift?"},"status":"ok"}"#
        let body = try canonicalJSON([
            "messages": [[
                "content": [[
                    "type": "tool_result",
                    "content": [["type": "text", "text": envelope]],
                ]],
            ]],
        ])
        let bodyURL = root.appendingPathComponent("body.json")
        try body.write(to: bodyURL)

        let result = try runBenchmark([
            "verify-envelope-hash", bodyURL.path, sha256(Data(envelope.utf8)),
        ])
        XCTAssertEqual(
            result.status,
            0,
            "the verifier must hash the exact MCP text bytes; JSON reserialization changes escaped slashes: \(result.stderr)"
        )

        let normalized = try canonicalJSON(jsonObject(Data(envelope.utf8)))
        XCTAssertNotEqual(sha256(normalized), sha256(Data(envelope.utf8)))
        let normalizedResult = try runBenchmark([
            "verify-envelope-hash", bodyURL.path, sha256(normalized),
        ])
        XCTAssertNotEqual(normalizedResult.status, 0, "a normalized envelope hash must be rejected")
    }

    func test_modelCatalogPairIgnoresOnlyPerRequestCreatedTimestamp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("round2-model-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let baselineURL = root.appendingPathComponent("baseline.json")
        let candidateURL = root.appendingPathComponent("candidate.json")
        let first: [String: Any] = [
            "created": 100, "id": "selected", "max_model_len": 40960,
            "object": "model", "owned_by": "omlx",
        ]
        let second: [String: Any] = [
            "created": 100, "id": "other", "max_model_len": NSNull(),
            "object": "model", "owned_by": "omlx",
        ]
        let baseline: [String: Any] = ["data": [first, second], "object": "list"]
        try canonicalJSON(baseline).write(to: baselineURL)

        var candidateFirst = first
        candidateFirst["created"] = 200
        var candidateSecond = second
        candidateSecond["created"] = 200
        let validCandidate: [String: Any] = ["data": [candidateFirst, candidateSecond], "object": "list"]
        try canonicalJSON(validCandidate).write(to: candidateURL)
        let valid = try runBenchmark([
            "verify-model-catalog-pair", baselineURL.path, candidateURL.path,
        ])
        XCTAssertEqual(valid.status, 0, "created is generated per request and is not model identity: \(valid.stderr)")

        var changedID = candidateFirst
        changedID["id"] = "changed"
        var changedOwner = candidateFirst
        changedOwner["owned_by"] = "other"
        var changedLength = candidateFirst
        changedLength["max_model_len"] = 8192
        var changedObject = candidateFirst
        changedObject["object"] = "not-model"
        var malformedCreated = candidateFirst
        malformedCreated["created"] = "200"
        var extraItemField = candidateFirst
        extraItemField["extra"] = true
        var missingCreated = candidateFirst
        missingCreated.removeValue(forKey: "created")
        var extraRoot = validCandidate
        extraRoot["extra"] = true
        var missingRoot = validCandidate
        missingRoot.removeValue(forKey: "object")

        let rejected: [[String: Any]] = [
            ["data": [changedID, candidateSecond], "object": "list"],
            ["data": [changedOwner, candidateSecond], "object": "list"],
            ["data": [changedLength, candidateSecond], "object": "list"],
            ["data": [changedObject, candidateSecond], "object": "list"],
            ["data": [malformedCreated, candidateSecond], "object": "list"],
            ["data": [extraItemField, candidateSecond], "object": "list"],
            ["data": [missingCreated, candidateSecond], "object": "list"],
            ["data": [candidateSecond, candidateFirst], "object": "list"],
            ["data": [candidateFirst], "object": "list"],
            ["data": [candidateFirst, candidateFirst], "object": "list"],
            extraRoot,
            missingRoot,
        ]
        for (index, mutation) in rejected.enumerated() {
            try canonicalJSON(mutation).write(to: candidateURL, options: .atomic)
            let result = try runBenchmark([
                "verify-model-catalog-pair", baselineURL.path, candidateURL.path,
            ])
            XCTAssertNotEqual(result.status, 0, "mutation \(index) must not be hidden as timestamp drift")
        }

        var concatenated = try canonicalJSON(validCandidate)
        concatenated.append(0x0A)
        concatenated.append(try canonicalJSON(validCandidate))
        try concatenated.write(to: candidateURL, options: .atomic)
        let multipleDocuments = try runBenchmark([
            "verify-model-catalog-pair", baselineURL.path, candidateURL.path,
        ])
        XCTAssertNotEqual(multipleDocuments.status, 0, "a response must contain exactly one JSON document")
    }

    func test_candidateSourceBoundaryAllowsOnlyTheExactLineTransformation() {
        let removed = #"            fallback: LibrarianFallback(recommended: "retrieve", handle: resolved.handle, question: request.question)"#
        let added = #"            fallback: LibrarianFallback(recommended: "retrieve", handle: resolved.handle)"#
        XCTAssertTrue(isExactTechniqueSourceChange(removed: [removed], added: [added]))
        XCTAssertFalse(isExactTechniqueSourceChange(removed: [removed, "extra"], added: [added]))
        XCTAssertFalse(isExactTechniqueSourceChange(removed: [removed], added: [" " + added]))
        XCTAssertFalse(isExactTechniqueSourceChange(
            removed: [removed],
            added: [#"            fallback: LibrarianFallback(recommended: "retrieve", handle: resolved.handle, question: nil)"#]
        ))

        let catalogTest = "    func test_askHandle_successEnvelopeDoesNotRepeatToolQuestion() async throws {"
        XCTAssertTrue(hasRequiredCatalogRegression(
            removed: [],
            added: [catalogTest],
            diffSHA256: Self.catalogTestDiffSHA256
        ))
        XCTAssertFalse(hasRequiredCatalogRegression(
            removed: ["old assertion"],
            added: [catalogTest],
            diffSHA256: Self.catalogTestDiffSHA256
        ))
        XCTAssertFalse(hasRequiredCatalogRegression(
            removed: [],
            added: [catalogTest],
            diffSHA256: String(repeating: "0", count: 64)
        ))
    }

    func test_sourceCaptureStateRejectsDirtyOrChangedCheckout() throws {
        let clean = SourceCaptureState(
            gitSHA: String(repeating: "a", count: 40),
            treeSHA: String(repeating: "b", count: 40),
            statusPorcelain: ""
        )
        XCTAssertNoThrow(try requireStableSourceCapture(initial: clean, final: clean, expectedGitSHA: clean.gitSHA))
        XCTAssertThrowsError(try requireStableSourceCapture(
            initial: clean,
            final: SourceCaptureState(gitSHA: clean.gitSHA, treeSHA: clean.treeSHA, statusPorcelain: " M file"),
            expectedGitSHA: clean.gitSHA
        ))
        XCTAssertThrowsError(try requireStableSourceCapture(
            initial: clean,
            final: SourceCaptureState(gitSHA: String(repeating: "c", count: 40), treeSHA: clean.treeSHA, statusPorcelain: ""),
            expectedGitSHA: clean.gitSHA
        ))
    }

    func test_captureBindsCompiledTestBundleInsteadOfXCTestLauncher() throws {
        let captured = try captureExecutableURL()
        let bundleExecutable = try XCTUnwrap(
            Bundle(for: TokenSaverRound2BenchmarkTests.self).executableURL
        ).standardizedFileURL

        XCTAssertEqual(
            captured,
            bundleExecutable,
            "source provenance must hash the built tests, not the stable Xcode xctest launcher"
        )
        XCTAssertEqual(captured.lastPathComponent, "RemoteCodePackageTests")
    }

    func test_allTwentyFourS2RetrievesAreSuccessfulAndByteExact() async throws {
        let cases = try loadFixture().fixture.cases
        let recovery = try RecoveryContext.temporary(cases: cases)
        defer { recovery.removeTemporaryFiles() }
        for item in cases {
            let episode = try await shippingEpisode(item, recovery: recovery)
            XCTAssertEqual(episode.retrieveResult["isError"] as? Bool, false, item.id)
            XCTAssertEqual((episode.retrieveResult["content"] as? [[String: Any]])?.count, 1, item.id)
            XCTAssertEqual(Data(try envelopeText(from: episode.retrieveResult).utf8), Data(item.source.utf8), item.id)
        }
    }

    func test_modelBindingEnumeratesRegularAndSafeHFSymlinkLeaves() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("round2-model-\(UUID().uuidString)", isDirectory: true)
        let modelsRoot = temporary.appendingPathComponent("models--org--repo", isDirectory: true)
        let root = modelsRoot
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(String(repeating: "a", count: 40), isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("weights"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelsRoot.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for (path, text) in [
            ("config.json", "{}"), ("tokenizer.json", "{}"),
            ("tokenizer_config.json", "{}"), ("vocab.json", "{}"),
            ("merges.txt", "a b"), ("README.md", "bound too"),
        ] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try Data("weights".utf8).write(to: modelsRoot.appendingPathComponent("blobs/model-weight"))
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("weights/model.safetensors").path,
            withDestinationPath: "../../../blobs/model-weight"
        )
        let bound = try modelBinding(root)
        XCTAssertEqual(Set(bound.files.compactMap { $0["path"] as? String }), [
            "README.md", "config.json", "merges.txt", "tokenizer.json",
            "tokenizer_config.json", "vocab.json", "weights/model.safetensors",
        ])
        let weight = try XCTUnwrap(bound.files.first { $0["path"] as? String == "weights/model.safetensors" })
        XCTAssertEqual(weight["kind"] as? String, "symlink")
        XCTAssertEqual(weight["link_target"] as? String, "../../../blobs/model-weight")
        XCTAssertEqual(weight["sha256"] as? String, sha256(Data("weights".utf8)))

        let outside = temporary.appendingPathComponent("outside.safetensors")
        try Data("outside".utf8).write(to: outside)
        let link = root.appendingPathComponent("weights/outside.safetensors")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../../../outside.safetensors")
        XCTAssertThrowsError(try modelBinding(root))
        try FileManager.default.removeItem(at: link)

        let directoryLink = root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(atPath: directoryLink.path, withDestinationPath: "../../blobs")
        XCTAssertThrowsError(try modelBinding(root))
        try FileManager.default.removeItem(at: directoryLink)

        let rootLink = temporary.appendingPathComponent("snapshot-link")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: root)
        XCTAssertThrowsError(try modelBinding(rootLink))
    }

    func test_modelStatusRequiresOneLoadedSelectedModelAtServedPath() throws {
        let modelPath = "/tmp/models--org--repo/snapshots/\(String(repeating: "a", count: 40))"
        let valid = try canonicalJSON(["models": [
            ["id": "selected", "loaded": true, "model_path": modelPath],
            ["id": "other", "loaded": false, "model_path": "/tmp/other"],
        ]])
        let selected = try selectedModelStatus(in: valid, selectedID: "selected")
        XCTAssertEqual(selected.modelPath, modelPath)

        let duplicate = try canonicalJSON(["models": [
            ["id": "selected", "loaded": true, "model_path": modelPath],
            ["id": "selected", "loaded": true, "model_path": modelPath],
        ]])
        XCTAssertThrowsError(try selectedModelStatus(in: duplicate, selectedID: "selected"))
        let unloaded = try canonicalJSON(["models": [["id": "selected", "loaded": false, "model_path": modelPath]]])
        XCTAssertThrowsError(try selectedModelStatus(in: unloaded, selectedID: "selected"))
    }

    func test_manifestIncludesNestedManifestAndRejectsAnySymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("round2-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("payload".utf8).write(to: root.appendingPathComponent("payload.bin"))
        try Data("nested".utf8).write(to: root.appendingPathComponent("nested/manifest.json"))
        try writeManifest(in: root)
        let manifest = try jsonObject(Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let paths = Set((manifest["files"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String })
        XCTAssertEqual(paths, ["nested/manifest.json", "payload.bin"])

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("payload-link"),
            withDestinationURL: root.appendingPathComponent("payload.bin")
        )
        XCTAssertThrowsError(try writeManifest(in: root))
    }

    func test_captureConfigurationRejectsNonemptyShortAuthorization() {
        let environment = [
            "RC_TOKEN_SAVER_ROUND2_ARM": "baseline",
            "RC_TOKEN_SAVER_ROUND2_EXPECTED_GIT_SHA": String(repeating: "a", count: 40),
            "RC_TOKEN_SAVER_ROUND2_OUTPUT_DIR": "/tmp/round2-output",
            "RC_TOKEN_SAVER_ROUND2_BASE_URL": "http://127.0.0.1:8000/v1",
            "RC_TOKEN_SAVER_ROUND2_MODEL": "model",
            "RC_TOKEN_SAVER_ROUND2_MODEL_SNAPSHOT": "/tmp/Models/repo/\(String(repeating: "b", count: 40))",
            "RC_TOKEN_SAVER_ROUND2_AUTH_TOKEN": "short",
        ]
        XCTAssertThrowsError(try CaptureConfiguration(environment))
    }

    func test_captureArmRejectsMissingOutputParentBeforeMaterializingSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("round2-output-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("baseline", isDirectory: true)
        let result = try runBenchmark([
            "capture-arm", "baseline", String(repeating: "a", count: 40), output.path,
        ])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("arm output parent does not exist"), result.stderr)
        XCTAssertFalse(result.stderr.contains("missing RC_TOKEN_SAVER_ROUND2_BASE_URL"), result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path))
    }

    func test_captureArmAcceptsExistingOutputParentBeforeTheNextGate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("round2-output-positive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("baseline", isDirectory: true)
        let head = try git(["rev-parse", "HEAD"], repositoryURL()).trimmed
        let result = try runBenchmark(["capture-arm", "baseline", head, output.path])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(result.stderr.contains("arm output parent"), result.stderr)
        XCTAssertTrue(
            result.stderr.contains("capture requires a detached temporary worktree")
                || result.stderr.contains("missing RC_TOKEN_SAVER_ROUND2_BASE_URL"),
            result.stderr
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func test_captureArmRejectsFailedGitStatusInspection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("round2-status-probe-\(UUID().uuidString)", isDirectory: true)
        let fakeBin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let expectedSHA = String(repeating: "a", count: 40)
        let fakeGit = fakeBin.appendingPathComponent("git")
        let script = """
        #!/bin/sh
        case "$*" in
          *" symbolic-ref -q HEAD") exit 1 ;;
          *" rev-parse HEAD^{tree}") printf '%s\\n' '\(String(repeating: "b", count: 40))'; exit 0 ;;
          *" rev-parse HEAD") printf '%s\\n' '\(expectedSHA)'; exit 0 ;;
          *" status --porcelain"*) exit 42 ;;
        esac
        exec /usr/bin/git "$@"
        """
        try Data(script.utf8).write(to: fakeGit)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGit.path)
        let output = root.appendingPathComponent("baseline", isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = fakeBin.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        let result = try runBenchmark(
            ["capture-arm", "baseline", expectedSHA, output.path],
            environment: environment
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("failed to inspect capture arm status"), result.stderr)
        XCTAssertFalse(result.stderr.contains("missing RC_TOKEN_SAVER_ROUND2_BASE_URL"), result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    /// Manual and fail-closed. The shell coordinator sets this only after proving
    /// the checkout is clean and HEAD equals the arm SHA.
    func test_captureArmAgainstOMLX() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RC_TOKEN_SAVER_ROUND2_CAPTURE"] == "1" else {
            throw XCTSkip("Use scripts/token-saver-round2-benchmark.sh capture-arm.")
        }
        let configuration = try CaptureConfiguration(environment)
        let (fixture, fixtureData) = try loadFixture()
        guard sha256(fixtureData) == Self.fixtureSHA256 else {
            throw Round2Error.invalid("fixture hash changed")
        }

        let repository = repositoryURL()
        let initialSourceState = try sourceCaptureState(repository: repository)
        try requireStableSourceCapture(
            initial: initialSourceState,
            final: initialSourceState,
            expectedGitSHA: configuration.expectedGitSHA
        )
        let head = initialSourceState.gitSHA
        let tree = initialSourceState.treeSHA
        let sourceBindings = try sourceBindings(
            repository: repository,
            gitSHA: head,
            profile: configuration.profile
        )

        let output = configuration.outputDirectory
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let recovery = try RecoveryContext(
            outputDirectory: output,
            seedDirectory: configuration.recoverySeedDirectory,
            arm: configuration.arm,
            cases: fixture.cases
        )

        let modelsResponse = try await request(
            configuration.baseURL.appendingPathComponent("models"),
            method: "GET",
            body: nil,
            token: configuration.authToken
        )
        let modelIDs = try modelIDs(in: modelsResponse)
        guard modelIDs.filter({ $0 == configuration.model }).count == 1 else {
            throw Round2Error.invalid("/v1/models must contain the selected model exactly once")
        }
        let modelsStatusURL = configuration.baseURL
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("status")
        let modelsStatusBeforeResponse = try await request(
            modelsStatusURL,
            method: "GET",
            body: nil,
            token: configuration.authToken
        )
        let selectedStatusBefore = try selectedModelStatus(
            in: modelsStatusBeforeResponse,
            selectedID: configuration.model
        )
        let configuredSnapshotValues = try configuration.modelSnapshot.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard configuredSnapshotValues.isSymbolicLink != true else {
            throw Round2Error.invalid("configured snapshot root must not be a symlink")
        }
        let configuredSnapshotPath = try canonicalDirectoryPath(configuration.modelSnapshot)
        let servedSnapshotURL = URL(fileURLWithPath: selectedStatusBefore.modelPath, isDirectory: true)
        let servedSnapshotPath = try canonicalDirectoryPath(servedSnapshotURL)
        guard configuredSnapshotPath == servedSnapshotPath else {
            throw Round2Error.invalid("configured snapshot is not the selected model_path served by oMLX")
        }
        let modelBinding = try modelBinding(servedSnapshotURL)
        let openAPIURL = configuration.baseURL.deletingLastPathComponent().appendingPathComponent("openapi.json")
        let openAPIResponse = try await request(openAPIURL, method: "GET", body: nil, token: configuration.authToken)
        let serverVersion = try openAPIVersion(openAPIResponse)

        try modelsResponse.write(to: output.appendingPathComponent("models-response.json"), options: .atomic)
        try modelsStatusBeforeResponse.write(
            to: output.appendingPathComponent("models-status-before.json"),
            options: .atomic
        )
        try openAPIResponse.write(to: output.appendingPathComponent("server-openapi.json"), options: .atomic)

        var caseReports: [[String: Any]] = []
        for item in fixture.cases {
            let warm = try await shippingEpisode(item, recovery: recovery)
            try recovery.confirmDelivery(for: item)
            var shippingSamples: [Double] = []
            var episode = warm
            for _ in 0..<5 {
                let started = DispatchTime.now().uptimeNanoseconds
                let measured = try await shippingEpisode(item, recovery: recovery)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                guard measured.emitted == warm.emitted,
                      measured.retrieveEmitted == warm.retrieveEmitted,
                      measured.failOpenEmitted == warm.failOpenEmitted else {
                    throw Round2Error.invalid("\(item.id) shipping output was not byte-stable")
                }
                shippingSamples.append(elapsed)
                episode = measured
            }

            let emittedDirectory = output
                .appendingPathComponent("emitted/\(item.id)", isDirectory: true)
            try FileManager.default.createDirectory(at: emittedDirectory, withIntermediateDirectories: true)

            let s0 = try providerBody(
                model: configuration.model,
                system: fixture.system,
                item: item,
                tools: episode.providerTools,
                mcpResult: episode.mcpResult,
                carryForward: false
            )
            let s6 = try providerBody(
                model: configuration.model,
                system: fixture.system,
                item: item,
                tools: episode.providerTools,
                mcpResult: episode.mcpResult,
                carryForward: true
            )
            let s2 = try forcedRetrieveBody(
                model: configuration.model,
                system: fixture.system,
                item: item,
                episode: episode
            )
            let s4 = try providerBody(
                model: configuration.model,
                system: fixture.system,
                item: item,
                tools: episode.providerTools,
                mcpResult: episode.failOpenResult,
                carryForward: false
            )
            let s2Emitted = episode.emitted + Data("\n".utf8) + episode.retrieveEmitted
            let scenarios: [(id: String, turn: String, body: [String: Any], emitted: Data, expected: String)] = [
                ("S0", "turn-1", s0, episode.emitted, configuration.profile.applicableExpectedDelta),
                ("S2", "turn-1", s2, s2Emitted, configuration.profile.applicableExpectedDelta),
                ("S4", "turn-1", s4, episode.failOpenEmitted, configuration.profile.s4ExpectedDelta),
                ("S6", "turn-2", s6, episode.emitted, configuration.profile.applicableExpectedDelta),
            ]
            var scenarioReports: [[String: Any]] = []
            for scenario in scenarios {
                let envelopeDirectory = output
                    .appendingPathComponent("envelopes/\(item.id)/\(scenario.id)", isDirectory: true)
                let tokenizerDirectory = output
                    .appendingPathComponent("tokenizer-responses/\(item.id)/\(scenario.id)", isDirectory: true)
                try FileManager.default.createDirectory(at: envelopeDirectory, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: tokenizerDirectory, withIntermediateDirectories: true)
                let bodyData = try canonicalJSON(scenario.body)
                try bodyData.write(to: envelopeDirectory.appendingPathComponent("\(scenario.turn).json"), options: .atomic)
                try scenario.emitted.write(to: emittedDirectory.appendingPathComponent("\(scenario.id).bin"), options: .atomic)
                let count = try await countTwice(bodyData, configuration: configuration)
                try count.first.write(to: tokenizerDirectory.appendingPathComponent("\(scenario.turn).json"), options: .atomic)
                try count.replay.write(to: tokenizerDirectory.appendingPathComponent("\(scenario.turn)-replay.json"), options: .atomic)
                scenarioReports.append([
                    "id": scenario.id,
                    "turn": scenario.turn,
                    "body_sha256": sha256(bodyData),
                    "emitted_sha256": sha256(scenario.emitted),
                    "input_tokens": count.tokens,
                    "expected_delta": scenario.expected,
                    "count_replay_verified": true,
                ])
            }

            let hasQuestion = episode.envelope.fallback.question != nil
            let questionContractPassed = configuration.profile == .envelopeSlashes
                ? !hasQuestion
                : (configuration.arm == "baseline" && episode.envelope.fallback.question == item.question)
                    || (configuration.arm == "candidate" && !hasQuestion)
            guard questionContractPassed else {
                throw Round2Error.invalid("\(item.id) arm does not match fallback.question contract")
            }
            guard episode.readbackExact,
                  episode.retrieveResult["isError"] as? Bool == false,
                  (try envelopeText(from: episode.retrieveResult)) == item.source,
                  episode.envelope.status == .ok,
                  episode.envelope.op == "ask_handle",
                  episode.envelope.answer == .object(["text": .string(item.answer)]),
                  episode.envelope.evidence.first?.span == item.span,
                  episode.envelope.evidence.first?.handle == episode.envelope.fallback.handle,
                  episode.envelope.fallback.recommended == "retrieve",
                  item.requiredLiterals.allSatisfy({ item.answer.contains($0) || item.source.contains($0) }),
                  item.forbiddenLiterals.allSatisfy({ !item.answer.contains($0) && !episode.envelopeJSON.contains($0) }) else {
                throw Round2Error.invalid("\(item.id) quality oracle failed")
            }

            caseReports.append([
                "id": item.id,
                "question_sha256": sha256(Data(item.question.utf8)),
                "envelope_sha256": sha256(Data(episode.envelopeJSON.utf8)),
                "emitted_sha256": sha256(episode.emitted),
                "scenarios": scenarioReports,
                "not_applicable": configuration.profile.notApplicableMetadata,
                "shipping_latency_ms": shippingSamples,
                "quality_passed": true,
                "fallback_question_present": hasQuestion,
                "durable_readback_exact": true,
                "delivery_confirmed": true,
                "recovery_mode": "token_saver_scoped_persistence",
            ])
        }

        let modelsStatusAfterResponse = try await request(
            modelsStatusURL,
            method: "GET",
            body: nil,
            token: configuration.authToken
        )
        let selectedStatusAfter = try selectedModelStatus(
            in: modelsStatusAfterResponse,
            selectedID: configuration.model
        )
        guard selectedStatusAfter.modelPath == selectedStatusBefore.modelPath,
              try canonicalDirectoryPath(URL(fileURLWithPath: selectedStatusAfter.modelPath, isDirectory: true)) == servedSnapshotPath else {
            throw Round2Error.invalid("selected oMLX model binding changed during counting")
        }
        let modelBindingAfter = try self.modelBinding(servedSnapshotURL)
        guard modelBindingAfter.path == modelBinding.path,
              modelBindingAfter.revision == modelBinding.revision,
              modelBindingAfter.manifestSHA256 == modelBinding.manifestSHA256,
              try canonicalJSON(modelBindingAfter.files) == canonicalJSON(modelBinding.files) else {
            throw Round2Error.invalid("served model snapshot contents changed during counting")
        }
        try modelsStatusAfterResponse.write(
            to: output.appendingPathComponent("models-status-after.json"),
            options: .atomic
        )

        try recovery.persistCapabilities()
        let executableURL = try captureExecutableURL()
        let executableData = try Data(contentsOf: executableURL, options: .mappedIfSafe)
        let finalSourceState = try sourceCaptureState(repository: repository)
        try requireStableSourceCapture(
            initial: initialSourceState,
            final: finalSourceState,
            expectedGitSHA: configuration.expectedGitSHA
        )
        let report: [String: Any] = [
            "schema_version": 1,
            "technique_id": configuration.profile == .envelopeSlashes
                ? Self.slashTechniqueID
                : Self.techniqueID,
            "arm": configuration.arm,
            "counter": fixture.counter,
            "token_count_source": "omlx:/v1/messages/count_tokens",
            "source": [
                "git_sha": head,
                "tree_sha": tree,
                "dirty": false,
                "capture_checks": [
                    "initial": initialSourceState.reportObject,
                    "pre_report": finalSourceState.reportObject,
                ],
                "bindings": sourceBindings,
                "executable_sha256": sha256(executableData),
            ],
            "fixture": ["path": fixturePath(relativeTo: repository), "sha256": Self.fixtureSHA256, "case_count": 24],
            "model": [
                "id": configuration.model,
                "server": "oMLX",
                "server_version": serverVersion,
                "served_model_path": selectedStatusBefore.modelPath,
                "snapshot_path": modelBinding.path,
                "revision": modelBinding.revision,
                "files": modelBinding.files,
                "manifest_sha256": modelBinding.manifestSHA256,
                "models_response_sha256": sha256(modelsResponse),
                "models_status_before_sha256": sha256(modelsStatusBeforeResponse),
                "models_status_after_sha256": sha256(modelsStatusAfterResponse),
                "openapi_response_sha256": sha256(openAPIResponse),
            ],
            "cases": caseReports,
            "aggregate": [
                "case_count": caseReports.count,
                "quality_passed_cases": caseReports.filter { $0["quality_passed"] as? Bool == true }.count,
                "measured_scenarios": ["S0", "S2", "S4", "S6"],
                "not_applicable_scenarios": ["S1", "S3", "S5"],
            ],
            "auth_persisted": false,
        ]
        let reportData = try canonicalJSON(report, pretty: true)
        if let token = configuration.authToken, token.count >= 8,
           String(decoding: reportData, as: UTF8.self).contains(token) {
            throw Round2Error.invalid("authorization material reached report")
        }
        try reportData.write(to: output.appendingPathComponent("report.json"), options: .atomic)
        try writeManifest(in: output)
    }
}

private extension TokenSaverRound2BenchmarkTests {
    struct ScriptedGenerate: LibrarianGenerating {
        let answer: String
        let span: String

        func generate(_ call: LibrarianGenerateCall) async -> String? {
            guard call.user.contains(span) else { return nil }
            let data = try? JSONSerialization.data(withJSONObject: ["answer": answer, "span": span], options: [.sortedKeys, .withoutEscapingSlashes])
            return data.map { String(decoding: $0, as: UTF8.self) }
        }
    }

    struct ShippingEpisode {
        let emitted: Data
        let mcpResult: [String: Any]
        let retrieveEmitted: Data
        let retrieveResult: [String: Any]
        let failOpenEmitted: Data
        let failOpenResult: [String: Any]
        let envelope: LibrarianEnvelope
        let envelopeJSON: String
        let providerTools: [[String: Any]]
        let durableReadbackExact: Bool

        var providerTool: [String: Any] { providerTools[0] }
        var readbackExact: Bool { durableReadbackExact }
    }

    func shippingEpisode(_ item: Round2Case, recovery: RecoveryContext) async throws -> ShippingEpisode {
        let capability = try recovery.capability(for: item)
        let persistentOriginal = try recovery.retrieve(capability: capability)
        guard persistentOriginal == Data(item.source.utf8) else {
            throw Round2Error.invalid("\(item.id) persistent recovery readback failed")
        }
        let dispatcher = LibrarianDispatcher(generate: ScriptedGenerate(answer: item.answer, span: item.span))
        _ = dispatcher.store.put(item.source, handle: capability)
        let server = ManagedRetrieveMCP(
            retrieve: { handle in
                guard let data = try? recovery.retrieve(capability: handle) else { return nil }
                return String(data: data, encoding: .utf8)
            },
            ask: { call in
                let result = await dispatcher.dispatch(LibrarianRequest(
                    id: call.op,
                    input: call.input,
                    question: call.question,
                    handle: call.handle,
                    provider: "round2-benchmark",
                    threadID: item.id,
                    admitted: true,
                    retrieveAvailable: true,
                    verifiedRecoveryHandle: call.handle
                ))
                return ManagedRetrieveMCP.OpAnswer(
                    status: result.status.rawValue,
                    text: result.text,
                    envelope: result.envelope?.jsonString(),
                    savedTokens: result.analytics.savedTokens,
                    mode: result.analytics.mode
                )
            },
            scopedRecoveryAvailable: true,
            distillAdmission: { true }
        )
        let optionalList = await server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let list = try XCTUnwrap(optionalList)
        let listObject = try jsonObject(Data(list.utf8))
        let listed = try requireDictionary(listObject["result"])["tools"] as? [[String: Any]]
        let askTool = try XCTUnwrap(listed?.first { $0["name"] as? String == "rc_ask" })
        let retrieveTool = try XCTUnwrap(listed?.first { $0["name"] as? String == "rc_retrieve" })
        let providerTools: [[String: Any]] = [askTool, retrieveTool].map {
            ["name": $0["name"] as Any, "description": $0["description"] as Any, "input_schema": $0["inputSchema"] as Any]
        }
        let call: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": "rc_ask",
                "arguments": ["op": "ask_handle", "question": item.question, "handle": capability],
            ],
        ]
        let callLine = String(decoding: try canonicalJSON(call), as: UTF8.self)
        let optionalResponseLine = await server.handle(callLine)
        let responseLine = try XCTUnwrap(optionalResponseLine)
        let emitted = Data(responseLine.utf8)
        let response = try jsonObject(emitted)
        let mcpResult = try requireDictionary(response["result"])
        let envelopeJSON = try envelopeText(from: mcpResult)
        let envelope = try JSONDecoder().decode(LibrarianEnvelope.self, from: Data(envelopeJSON.utf8))
        let handle = try XCTUnwrap(envelope.fallback.handle)
        guard handle == capability else { throw Round2Error.invalid("\(item.id) envelope changed persistent capability") }

        let retrieveCall: [String: Any] = [
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "rc_retrieve", "arguments": ["handle": capability]],
        ]
        let retrieveLine = String(decoding: try canonicalJSON(retrieveCall), as: UTF8.self)
        let optionalRetrieveResponse = await server.handle(retrieveLine)
        let retrieveResponse = try XCTUnwrap(optionalRetrieveResponse)
        let retrieveEmitted = Data(retrieveResponse.utf8)
        let retrieveResult = try requireDictionary(try jsonObject(retrieveEmitted)["result"])

        let unavailable = LibrarianDispatcher(store: dispatcher.store)
        let unavailableServer = ManagedRetrieveMCP(
            retrieve: { handle in
                guard let data = try? recovery.retrieve(capability: handle) else { return nil }
                return String(data: data, encoding: .utf8)
            },
            ask: { call in
                let result = await unavailable.dispatch(LibrarianRequest(
                    id: call.op, input: call.input, question: call.question, handle: call.handle,
                    provider: "round2-benchmark", threadID: item.id,
                    admitted: true, retrieveAvailable: true, verifiedRecoveryHandle: call.handle
                ))
                return ManagedRetrieveMCP.OpAnswer(
                    status: result.status.rawValue,
                    text: result.text,
                    envelope: result.envelope?.jsonString(),
                    savedTokens: result.analytics.savedTokens,
                    mode: result.analytics.mode
                )
            },
            scopedRecoveryAvailable: true,
            distillAdmission: { true }
        )
        let optionalFailOpenResponse = await unavailableServer.handle(callLine)
        let failOpenResponse = try XCTUnwrap(optionalFailOpenResponse)
        let failOpenEmitted = Data(failOpenResponse.utf8)
        let failOpenResult = try requireDictionary(try jsonObject(failOpenEmitted)["result"])
        return ShippingEpisode(
            emitted: emitted,
            mcpResult: mcpResult,
            retrieveEmitted: retrieveEmitted,
            retrieveResult: retrieveResult,
            failOpenEmitted: failOpenEmitted,
            failOpenResult: failOpenResult,
            envelope: envelope,
            envelopeJSON: envelopeJSON,
            providerTools: providerTools,
            durableReadbackExact: try recovery.reconstructAndRetrieve(capability: handle) == Data(item.source.utf8)
        )
    }

    func providerBody(
        model: String,
        system: String,
        item: Round2Case,
        tools: [[String: Any]],
        mcpResult: [String: Any],
        carryForward: Bool
    ) throws -> [String: Any] {
        let shippedEnvelope = try jsonObject(Data(envelopeText(from: mcpResult).utf8))
        let fallback = try requireDictionary(shippedEnvelope["fallback"])
        guard let handle = fallback["handle"] as? String else {
            throw Round2Error.invalid("provider body omitted recovery handle")
        }
        var messages: [[String: Any]] = [
            ["role": "user", "content": item.question],
            ["role": "assistant", "content": [[
                "type": "tool_use", "id": "toolu_\(item.id)", "name": "rc_ask",
                "input": ["op": "ask_handle", "handle": handle, "question": item.question],
            ]]],
            ["role": "user", "content": [[
                "type": "tool_result", "tool_use_id": "toolu_\(item.id)",
                "content": mcpResult["content"] as Any,
                "is_error": mcpResult["isError"] as Any,
            ]]],
        ]
        if carryForward {
            messages.append(["role": "assistant", "content": item.answer])
            messages.append(["role": "user", "content": item.nextUser])
        }
        return ["model": model, "system": system, "messages": messages, "tools": tools]
    }

    func forcedRetrieveBody(
        model: String,
        system: String,
        item: Round2Case,
        episode: ShippingEpisode
    ) throws -> [String: Any] {
        var body = try providerBody(
            model: model,
            system: system,
            item: item,
            tools: episode.providerTools,
            mcpResult: episode.mcpResult,
            carryForward: false
        )
        var messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let handle = try XCTUnwrap(episode.envelope.fallback.handle)
        messages.append(["role": "assistant", "content": [[
            "type": "tool_use", "id": "toolu_retrieve_\(item.id)", "name": "rc_retrieve",
            "input": ["handle": handle],
        ]]])
        messages.append(["role": "user", "content": [[
            "type": "tool_result", "tool_use_id": "toolu_retrieve_\(item.id)",
            "content": episode.retrieveResult["content"] as Any,
            "is_error": episode.retrieveResult["isError"] as Any,
        ]]])
        body["messages"] = messages
        return body
    }

    func countTwice(_ body: Data, configuration: CaptureConfiguration) async throws -> (first: Data, replay: Data, tokens: Int) {
        let url = configuration.baseURL.appendingPathComponent("messages/count_tokens")
        let first = try await request(url, method: "POST", body: body, token: configuration.authToken)
        let replay = try await request(url, method: "POST", body: body, token: configuration.authToken)
        let firstTokens = try tokenCount(first)
        guard firstTokens == (try tokenCount(replay)) else {
            throw Round2Error.invalid("count_tokens replay changed input_tokens")
        }
        return (first, replay, firstTokens)
    }

    func request(_ url: URL, method: String, body: Data?, token: String?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Round2Error.invalid("HTTP request failed: \(url.path)")
        }
        return data
    }

    func tokenCount(_ data: Data) throws -> Int {
        let object = try jsonObject(data)
        guard let value = object["input_tokens"] as? Int else {
            throw Round2Error.invalid("count_tokens response omitted input_tokens")
        }
        return value
    }

    func modelIDs(in data: Data) throws -> [String] {
        let object = try jsonObject(data)
        guard let models = object["data"] as? [[String: Any]] else {
            throw Round2Error.invalid("invalid /v1/models response")
        }
        return models.compactMap { $0["id"] as? String }
    }

    func selectedModelStatus(in data: Data, selectedID: String) throws -> ServedModelStatus {
        let object = try jsonObject(data)
        guard let models = object["models"] as? [[String: Any]] else {
            throw Round2Error.invalid("invalid /v1/models/status response")
        }
        let selected = models.filter { $0["id"] as? String == selectedID }
        guard selected.count == 1,
              selected[0]["loaded"] as? Bool == true,
              let modelPath = selected[0]["model_path"] as? String,
              !modelPath.isEmpty else {
            throw Round2Error.invalid("/v1/models/status must contain one loaded selected model with model_path")
        }
        return ServedModelStatus(id: selectedID, modelPath: modelPath)
    }

    func canonicalDirectoryPath(_ url: URL) throws -> String {
        guard let canonicalPath = try url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath,
              FileManager.default.fileExists(atPath: canonicalPath) else {
            throw Round2Error.invalid("model path does not resolve to an existing directory")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Round2Error.invalid("model path does not resolve to a directory")
        }
        return canonicalPath
    }

    func openAPIVersion(_ data: Data) throws -> String {
        let object = try jsonObject(data)
        guard let info = object["info"] as? [String: Any],
              let version = info["version"] as? String, !version.isEmpty else {
            throw Round2Error.invalid("oMLX version unavailable")
        }
        return version
    }

    func modelBinding(_ snapshotURL: URL) throws -> (path: String, revision: String, files: [[String: Any]], manifestSHA256: String) {
        let originalValues = try snapshotURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard originalValues.isSymbolicLink != true else {
            throw Round2Error.invalid("model snapshot path must not be a symlink")
        }
        guard let canonicalPath = try snapshotURL.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath else {
            throw Round2Error.invalid("model snapshot has no canonical path")
        }
        let canonical = URL(fileURLWithPath: canonicalPath, isDirectory: true)
        let revision = (canonicalPath as NSString).lastPathComponent
        guard revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw Round2Error.invalid("model snapshot must end in a 40-hex revision")
        }
        let snapshotsPath = (canonicalPath as NSString).deletingLastPathComponent
        let modelsRootPath = (snapshotsPath as NSString).deletingLastPathComponent
        guard (snapshotsPath as NSString).lastPathComponent == "snapshots",
              (modelsRootPath as NSString).lastPathComponent.hasPrefix("models--") else {
            throw Round2Error.invalid("model snapshot must be inside a Hugging Face models--repo/snapshots root")
        }
        let required = ["config.json", "tokenizer.json", "tokenizer_config.json"]
        for name in required where !FileManager.default.fileExists(atPath: canonical.appendingPathComponent(name).path) {
            throw Round2Error.invalid("model snapshot omitted \(name)")
        }
        let enumerator = FileManager.default.enumerator(
            at: canonical,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        var files: [[String: Any]] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let relative = String(url.path.dropFirst(canonicalPath.count + 1))
            if values.isSymbolicLink == true {
                let linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                let resolvedTargetURL = url.resolvingSymlinksInPath()
                guard let targetCanonicalPath = try resolvedTargetURL.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath else {
                    throw Round2Error.invalid("model snapshot contains a broken symlink: \(relative)")
                }
                let targetURL = URL(fileURLWithPath: targetCanonicalPath)
                let targetValues = try targetURL.resourceValues(forKeys: [.isRegularFileKey])
                guard targetValues.isRegularFile == true,
                      targetCanonicalPath.hasPrefix(modelsRootPath + "/") else {
                    enumerator?.skipDescendants()
                    throw Round2Error.invalid("model symlink must resolve to a file inside its models--repo root: \(relative)")
                }
                let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
                files.append([
                    "path": relative,
                    "kind": "symlink",
                    "link_target": linkTarget,
                    "bytes": bytes.count,
                    "sha256": sha256(bytes),
                ])
                continue
            }
            guard values.isRegularFile == true else { continue }
            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            files.append([
                "path": relative,
                "kind": "regular",
                "link_target": NSNull(),
                "bytes": bytes.count,
                "sha256": sha256(bytes),
            ])
        }
        files.sort { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
        guard files.contains(where: { ($0["path"] as? String)?.hasSuffix(".safetensors") == true }) else {
            throw Round2Error.invalid("model snapshot omitted weight files")
        }
        return (canonicalPath, revision, files, sha256(try canonicalJSON(files)))
    }

    func sourceBindings(
        repository: URL,
        gitSHA: String,
        profile: CaptureProfile = .questionElision
    ) throws -> [[String: Any]] {
        var paths = [
            "Sources/DistillCore/Librarian/LibrarianHandlers.swift",
            "Sources/DistillCore/Librarian/LibrarianEnvelope.swift",
            "Sources/DistillCore/ManagedRetrieveMCP.swift",
            "Tests/DistillCoreTests/TokenSaverRound2BenchmarkTests.swift",
            "Tests/Fixtures/TokenSaverLocalLLMRound2/envelope-question.json",
            "scripts/token-saver-round2-benchmark.sh",
            "docs/benchmarks/token-saver-local-llm/round-2/PROTOCOL.md",
        ]
        if profile == .envelopeSlashes {
            paths.append("scripts/token-saver-round2-slash-benchmark.sh")
            paths.append("docs/benchmarks/token-saver-local-llm/round-2/envelope-slashes/PROTOCOL.md")
        }
        return try paths.map { path in
            let blob = try git(["rev-parse", "\(gitSHA):\(path)"], repository).trimmed
            let bytes = try gitData(["show", "\(gitSHA):\(path)"], repository)
            return ["path": path, "blob_sha1": blob, "sha256": sha256(bytes), "bytes": bytes.count]
        }
    }

    func sourceCaptureState(repository: URL) throws -> SourceCaptureState {
        SourceCaptureState(
            gitSHA: try git(["rev-parse", "HEAD"], repository).trimmed,
            treeSHA: try git(["rev-parse", "HEAD^{tree}"], repository).trimmed,
            statusPorcelain: try git(["status", "--porcelain=v1", "--untracked-files=all"], repository)
                .trimmingCharacters(in: .newlines)
        )
    }

    func requireStableSourceCapture(
        initial: SourceCaptureState,
        final: SourceCaptureState,
        expectedGitSHA: String
    ) throws {
        guard initial.gitSHA == expectedGitSHA,
              initial.statusPorcelain.isEmpty,
              final.statusPorcelain.isEmpty,
              final == initial else {
            throw Round2Error.invalid("capture source HEAD/tree/status changed or was dirty")
        }
    }

    func writeManifest(in root: URL) throws {
        guard let canonicalPath = try root.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath else {
            throw Round2Error.invalid("artifact root has no canonical path")
        }
        let canonicalRoot = URL(fileURLWithPath: canonicalPath, isDirectory: true)
        let enumerator = FileManager.default.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        var files: [[String: Any]] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                enumerator?.skipDescendants()
                throw Round2Error.invalid("artifact contains symlink: \(url.path)")
            }
            guard values.isRegularFile == true else { continue }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let relative = String(url.path.dropFirst(canonicalPath.count + 1))
            guard relative != "manifest.json" else { continue }
            files.append(["path": relative, "bytes": data.count, "sha256": sha256(data)])
        }
        files.sort { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
        let manifest: [String: Any] = ["schema_version": 1, "manifest_excludes_self": true, "files": files]
        try canonicalJSON(manifest, pretty: true).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
    }

    func loadFixture() throws -> (fixture: Round2Fixture, bytes: Data) {
        let url = repositoryURL().appendingPathComponent("Tests/Fixtures/TokenSaverLocalLLMRound2/envelope-question.json")
        let data = try Data(contentsOf: url)
        return (try JSONDecoder().decode(Round2Fixture.self, from: data), data)
    }

    func fixturePath(relativeTo repository: URL) -> String {
        "Tests/Fixtures/TokenSaverLocalLLMRound2/envelope-question.json"
    }

    func repositoryURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func captureExecutableURL() throws -> URL {
        guard let executable = Bundle(for: TokenSaverRound2BenchmarkTests.self).executableURL else {
            throw Round2Error.invalid("compiled XCTest bundle has no executable")
        }
        return executable.standardizedFileURL
    }

    func envelopeText(from result: [String: Any]) throws -> String {
        guard let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw Round2Error.invalid("MCP result omitted text content")
        }
        return text
    }

    func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Round2Error.invalid("expected JSON object")
        }
        return object
    }

    func differsOnlyBySuccessfulFallbackQuestion(baseline: String, candidate: String) throws -> Bool {
        var baselineObject = try jsonObject(Data(baseline.utf8))
        let candidateObject = try jsonObject(Data(candidate.utf8))
        guard baselineObject["status"] as? String == "ok",
              candidateObject["status"] as? String == "ok",
              var baselineFallback = baselineObject["fallback"] as? [String: Any],
              let candidateFallback = candidateObject["fallback"] as? [String: Any],
              baselineFallback["question"] is String,
              candidateFallback["question"] == nil else {
            return false
        }
        baselineFallback.removeValue(forKey: "question")
        baselineObject["fallback"] = baselineFallback
        return try canonicalJSON(baselineObject) == canonicalJSON(candidateObject)
    }

    func differsOnlyByLiteralQuestionBytes(baseline: Data, candidate: Data, question: String) throws -> Bool {
        let questionArray = String(decoding: try canonicalJSON([question]), as: UTF8.self)
        let questionJSON = String(questionArray.dropFirst().dropLast())
        let innerFragment = ",\"question\":\(questionJSON)"
        let fragmentArray = String(decoding: try canonicalJSON([innerFragment]), as: UTF8.self)
        let escapedFragment = String(fragmentArray.dropFirst(2).dropLast(2))
        let baselineText = String(decoding: baseline, as: UTF8.self)
        let pieces = baselineText.components(separatedBy: escapedFragment)
        guard pieces.count == 2 else { return false }
        return Data(pieces.joined().utf8) == candidate
    }

    func isExactTechniqueSourceChange(removed: [String], added: [String]) -> Bool {
        removed == [#"            fallback: LibrarianFallback(recommended: "retrieve", handle: resolved.handle, question: request.question)"#]
            && added == [#"            fallback: LibrarianFallback(recommended: "retrieve", handle: resolved.handle)"#]
    }

    func hasRequiredCatalogRegression(removed: [String], added: [String], diffSHA256: String) -> Bool {
        removed.isEmpty && added.filter {
            $0 == "    func test_askHandle_successEnvelopeDoesNotRepeatToolQuestion() async throws {"
        }.count == 1 && diffSHA256 == Self.catalogTestDiffSHA256
    }

    func requireDictionary(_ value: Any?) throws -> [String: Any] {
        guard let dictionary = value as? [String: Any] else {
            throw Round2Error.invalid("expected JSON dictionary")
        }
        return dictionary
    }

    func canonicalJSON(_ object: Any, pretty: Bool = false) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func git(_ arguments: [String], _ repository: URL) throws -> String {
        String(decoding: try gitData(arguments, repository), as: UTF8.self)
    }

    func runBenchmark(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (status: Int32, stderr: String) {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = repositoryURL().appendingPathComponent("scripts/token-saver-round2-benchmark.sh")
        process.arguments = arguments
        process.currentDirectoryURL = repositoryURL()
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, error)
    }

    func runSlashBenchmark(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (status: Int32, stderr: String) {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = repositoryURL().appendingPathComponent("scripts/token-saver-round2-slash-benchmark.sh")
        process.arguments = arguments
        process.currentDirectoryURL = repositoryURL()
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, error)
    }

    func gitData(_ arguments: [String], _ repository: URL) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Round2Error.invalid("git \(arguments.joined(separator: " ")) failed") }
        return data
    }
}

private struct ServedModelStatus: Equatable {
    let id: String
    let modelPath: String
}

private struct SourceCaptureState: Equatable {
    let gitSHA: String
    let treeSHA: String
    let statusPorcelain: String

    var reportObject: [String: Any] {
        ["git_sha": gitSHA, "tree_sha": treeSHA, "status_porcelain": statusPorcelain]
    }
}

private struct CaptureConfiguration {
    let profile: CaptureProfile
    let arm: String
    let expectedGitSHA: String
    let outputDirectory: URL
    let baseURL: URL
    let model: String
    let modelSnapshot: URL
    let recoverySeedDirectory: URL?
    let authToken: String?

    init(_ environment: [String: String]) throws {
        let profileValue = environment["RC_TOKEN_SAVER_ROUND2_PROFILE"] ?? CaptureProfile.questionElision.rawValue
        guard let profile = CaptureProfile(rawValue: profileValue) else {
            throw Round2Error.invalid("unknown Round-2 capture profile")
        }
        self.profile = profile
        arm = try Self.required(environment["RC_TOKEN_SAVER_ROUND2_ARM"], "RC_TOKEN_SAVER_ROUND2_ARM")
        guard arm == "baseline" || arm == "candidate" else { throw Round2Error.invalid("arm must be baseline or candidate") }
        expectedGitSHA = try Self.required(environment["RC_TOKEN_SAVER_ROUND2_EXPECTED_GIT_SHA"], "RC_TOKEN_SAVER_ROUND2_EXPECTED_GIT_SHA")
        guard expectedGitSHA.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else { throw Round2Error.invalid("expected SHA must be 40 hex") }
        outputDirectory = URL(fileURLWithPath: try Self.required(environment["RC_TOKEN_SAVER_ROUND2_OUTPUT_DIR"], "RC_TOKEN_SAVER_ROUND2_OUTPUT_DIR"), isDirectory: true)
        let base = try Self.required(environment["RC_TOKEN_SAVER_ROUND2_BASE_URL"], "RC_TOKEN_SAVER_ROUND2_BASE_URL")
        guard let parsed = URL(string: base), parsed.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(parsed.host), parsed.path.hasSuffix("/v1") else {
            throw Round2Error.invalid("base URL must be loopback HTTP ending in /v1")
        }
        baseURL = parsed
        model = try Self.required(environment["RC_TOKEN_SAVER_ROUND2_MODEL"], "RC_TOKEN_SAVER_ROUND2_MODEL")
        modelSnapshot = URL(fileURLWithPath: try Self.required(environment["RC_TOKEN_SAVER_ROUND2_MODEL_SNAPSHOT"], "RC_TOKEN_SAVER_ROUND2_MODEL_SNAPSHOT"), isDirectory: true)
        recoverySeedDirectory = environment["RC_TOKEN_SAVER_ROUND2_RECOVERY_SEED_DIR"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        }
        if arm == "candidate", recoverySeedDirectory == nil {
            throw Round2Error.invalid("candidate capture requires the baseline recovery seed directory")
        }
        authToken = environment["RC_TOKEN_SAVER_ROUND2_AUTH_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
        if let authToken, authToken.count < 8 {
            throw Round2Error.invalid("nonempty auth token must contain at least 8 characters for exact artifact scanning")
        }
    }

    private static func required(_ value: String?, _ name: String) throws -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Round2Error.invalid("missing \(name)") }
        return value
    }
}

private enum CaptureProfile: String {
    case questionElision = "question-elision-v1"
    case envelopeSlashes = "envelope-slashes-v1"

    var applicableExpectedDelta: String {
        self == .envelopeSlashes ? "nonnegative_per_case_positive_aggregate" : "positive"
    }

    var s4ExpectedDelta: String {
        self == .envelopeSlashes ? "not_applicable_zero" : "zero"
    }

    var notApplicableMetadata: [[String: String]] {
        if self == .envelopeSlashes {
            return [
                ["id": "S1", "reason": "slash unescaping applies only to serialized successful envelopes; no catalog lookup is required"],
                ["id": "S3", "reason": "slash escaping does not change generation, parsing, or retry behavior"],
                ["id": "S5", "reason": "S1 and S3 are source-bound not applicable for this slash-unescaping technique"],
            ]
        }
        return [
            ["id": "S1", "reason": "ask_handle is a hot declared tool; no catalog lookup is required"],
            ["id": "S3", "reason": "field elision does not change generation, parsing, or retry behavior"],
            ["id": "S5", "reason": "S1 and S3 are source-bound not applicable for this field-only technique"],
        ]
    }
}

private struct Round2Fixture: Decodable {
    let schemaVersion: Int
    let techniqueID: String
    let counter: String
    let system: String
    let cases: [Round2Case]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case techniqueID = "technique_id"
        case counter, system, cases
    }
}

private struct Round2Case: Decodable, Sendable {
    let id: String
    let cohort: String
    let source: String
    let question: String
    let answer: String
    let span: String
    let nextUser: String
    let requiredLiterals: [String]
    let forbiddenLiterals: [String]

    enum CodingKeys: String, CodingKey {
        case id, cohort, source, question, answer, span
        case nextUser = "next_user"
        case requiredLiterals = "required_literals"
        case forbiddenLiterals = "forbidden_literals"
    }
}

private enum Round2Error: Error {
    case invalid(String)
}

private final class RecoveryContext: @unchecked Sendable {
    private struct Entry: Codable {
        let capability: String
        let idempotencyKey: String
    }

    private let db: SQLiteDB
    private let store: TokenSaverScopedRecoveryStore
    private let worker: TokenSaverRuntimeRecoveryWorker
    private let scope = TokenSaverPersistentScope(
        workspaceID: "round2-workspace",
        projectID: "round2-project",
        threadID: "round2-thread",
        provider: "canonical-anthropic-envelope",
        attemptID: "round2-attempt"
    )
    private let arm: String
    private let recoveryDirectory: URL
    private let liveDirectory: URL
    private var entries: [String: Entry]
    private var temporaryRoot: URL?

    init(outputDirectory: URL, seedDirectory: URL?, arm: String, cases: [Round2Case]) throws {
        self.arm = arm
        recoveryDirectory = outputDirectory.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        liveDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-saver-round2-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: liveDirectory, withIntermediateDirectories: true)
        let databaseURL = liveDirectory.appendingPathComponent("recovery.sqlite")
        if let seedDirectory {
            let seedDB = seedDirectory.appendingPathComponent("recovery/recovery.sqlite")
            let seedEntries = seedDirectory.appendingPathComponent("recovery/capabilities.json")
            guard FileManager.default.fileExists(atPath: seedDB.path), FileManager.default.fileExists(atPath: seedEntries.path) else {
                throw Round2Error.invalid("baseline recovery seed is incomplete")
            }
            try FileManager.default.copyItem(at: seedDB, to: databaseURL)
            entries = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: seedEntries))
        } else {
            entries = [:]
        }
        db = try SQLiteDB(path: databaseURL.path)
        try Schema.migrate(db)
        try TokenSaverLaneStateRepository(db: db).ensureDefaults(projectID: scope.projectID)
        store = TokenSaverScopedRecoveryStore(db: db)
        worker = TokenSaverRuntimeRecoveryWorker(db: db)
        if arm == "candidate", Set(entries.keys) != Set(cases.map(\.id)) {
            throw Round2Error.invalid("candidate recovery seed does not bind all fixture cases")
        }
    }

    static func temporary(cases: [Round2Case]) throws -> RecoveryContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-saver-round2-recovery-\(UUID().uuidString)", isDirectory: true)
        let context = try RecoveryContext(outputDirectory: root, seedDirectory: nil, arm: "baseline", cases: cases)
        context.temporaryRoot = root
        return context
    }

    func capability(for item: Round2Case) throws -> String {
        if let entry = entries[item.id] {
            guard try store.retrieve(capability: entry.capability, scope: scope) == Data(item.source.utf8) else {
                throw Round2Error.invalid("\(item.id) seeded capability readback failed")
            }
            return entry.capability
        }
        guard arm == "baseline" else { throw Round2Error.invalid("candidate attempted to mint a new capability") }
        let prepared = try worker.prepareOriginal(
            Data(item.source.utf8),
            scope: scope,
            operationID: "round2-\(item.id.lowercased())",
            invocationID: "round2-\(item.id.lowercased())",
            lane: "deterministic_wrapper",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            disk: TokenSaverRecoveryDiskSnapshot(
                freeBytes: 20 * 1_024 * 1_024 * 1_024,
                totalBytes: 100 * 1_024 * 1_024 * 1_024
            ),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        guard prepared.readBackVerified else { throw Round2Error.invalid("\(item.id) persistence prepare was not verified") }
        entries[item.id] = Entry(capability: prepared.capability, idempotencyKey: prepared.idempotencyKey)
        return prepared.capability
    }

    func retrieve(capability: String) throws -> Data? {
        try store.retrieve(capability: capability, scope: scope)
    }

    func reconstructAndRetrieve(capability: String) throws -> Data? {
        try TokenSaverScopedRecoveryStore(db: db).retrieve(capability: capability, scope: scope)
    }

    func confirmDelivery(for item: Round2Case) throws {
        guard let entry = entries[item.id] else { throw Round2Error.invalid("missing recovery entry") }
        let transitioned = try store.markDelivered(
            capability: entry.capability,
            scope: scope,
            idempotencyKey: entry.idempotencyKey,
            outcome: .acked,
            now: Date(timeIntervalSince1970: 1_800_000_001)
        )
        let stillRetrievable = try reconstructAndRetrieve(capability: entry.capability) == Data(item.source.utf8)
        guard transitioned || stillRetrievable else {
            throw Round2Error.invalid("\(item.id) delivery confirmation failed")
        }
    }

    func persistCapabilities() throws {
        let url = recoveryDirectory.appendingPathComponent("capabilities.json")
        let data = try JSONEncoder().encode(entries)
        try data.write(to: url, options: .atomic)
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        let snapshot = recoveryDirectory.appendingPathComponent("recovery.sqlite")
        if FileManager.default.fileExists(atPath: snapshot.path) {
            try FileManager.default.removeItem(at: snapshot)
        }
        let escaped = snapshot.path.replacingOccurrences(of: "'", with: "''")
        try db.execute("VACUUM INTO '\(escaped)';")
    }

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: liveDirectory)
        if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
    }

    deinit {
        try? FileManager.default.removeItem(at: liveDirectory)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
