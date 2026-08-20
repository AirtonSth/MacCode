import AgentRuntime
import CryptoKit
import Darwin
import Foundation
import XCTest
import CoreModel
import Persistence
@testable import DistillCore

final class RCW1EfficiencyCorpusTests: XCTestCase {
    func test_fixedCorpusHasUniqueCasesAndPinsTheReportedPrompt() throws {
        let cases = try loadCorpus()

        XCTAssertEqual(cases.count, 24, "public efficiency evidence needs the frozen 24-case risk corpus")
        XCTAssertEqual(Set(cases.map(\.id)).count, cases.count, "benchmark rows must not be duplicated")
        XCTAssertEqual(cases.first?.id, "reported-disposable-workspace")
        XCTAssertEqual(cases.first?.human.utf8.count, 704, "the user's reported prompt is the nominal gate")
        XCTAssertEqual(cases.last?.id, "short-fail-open")
        XCTAssertFalse(cases.last?.eligible ?? true, "tiny prompts must remain exact Human")
    }

    func test_fixedCorpusDeclaresSemanticsAndExactAtomsBeforeOutputsExist() throws {
        for item in try loadCorpus() {
            XCTAssertFalse(item.requiredConcepts.isEmpty, "\(item.id) must define semantic success independently of an encoder output")
            XCTAssertFalse(item.language.isEmpty, "\(item.id) must declare the intended language")
            for literal in item.requiredExact {
                XCTAssertTrue(item.effectiveHuman.contains(literal), "\(item.id) exact atom is absent from its Human fixture: \(literal)")
            }
            for anchor in item.ordered {
                XCTAssertNotNil(
                    item.effectiveHuman.range(of: anchor, options: .caseInsensitive),
                    "\(item.id) ordered anchor is absent: \(anchor)"
                )
            }
            if TokenEstimator.estimate(item.effectiveHuman) < 80 {
                XCTAssertFalse(item.eligible, "\(item.id) is below the production profitability floor")
            }
        }
    }

    func test_fixedCorpusIncludesFailOpenAndCrossLanguageRisks() throws {
        let cases = try loadCorpus()
        let byID = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })

        for id in [
            "uuid-sha-exact", "code-fence-byte-exact", "json-schema-quotes",
            "contradictory-fail-open", "opaque-exact-fail-open", "short-fail-open"
        ] {
            XCTAssertFalse(try XCTUnwrap(byID[id]).eligible, "\(id) must prefer exact Human over unsafe compression")
        }
        XCTAssertTrue(Set(cases.map(\.language)).isSuperset(of: ["en", "pt", "ja", "ar"]))
        XCTAssertTrue(cases.contains { !$0.ordered.isEmpty }, "order/condition fidelity must be represented")
        XCTAssertTrue(cases.contains { !$0.forbidden.isEmpty }, "negative constraints must be represented")
    }

    func test_fixedCorpusDoesNotEmbedGeneratedBenchmarkResults() throws {
        // WHY: the frozen corpus defines inputs and independent obligations. Keeping
        // encoder/Caveman outputs out of it prevents a fixture edit from masquerading
        // as a measured run.
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: corpusURL()))
        let rows = try XCTUnwrap(value as? [[String: Any]])
        let generatedKeys: Set<String> = [
            "decision", "delivered_payload", "fail_open_reason", "recovery_handle",
            "caveman_output", "provider", "provider_model", "measured_tokens",
            "abi_tokens", "effective_rcw1_tokens", "effective_rcw1_vs_human_ppm",
            "effective_rcw1_vs_caveman_ppm", "effective_saved_tokens",
        ]
        for row in rows {
            XCTAssertTrue(
                generatedKeys.isDisjoint(with: row.keys),
                "generated measurements belong in a run artifact, not the frozen corpus"
            )
        }
    }

    func test_responseAndRequestFramingPreserveEscapingAndRecoveryOverhead() throws {
        let shortFrame = RCWireFrame(
            direction: .response,
            sequence: 1,
            records: [.init(kind: .outcome, value: "OK")]
        )
        XCTAssertEqual(try RCWireProtocol.serialize(shortFrame).utf8.count, 16)

        let multiFrame = RCWireFrame(
            direction: .response,
            sequence: 1,
            records: [
                .init(kind: .outcome, value: "Done"),
                .init(kind: .action, value: "Run `swift test`"),
                .init(kind: .evidence, value: "2 passed"),
                .init(kind: .risk, value: "Path C:\\tmp\tcache\nchanged"),
                .init(kind: .question, value: "Ship?"),
            ]
        )
        let multiWire = try RCWireProtocol.serialize(multiFrame)
        XCTAssertTrue(multiWire.contains("R\t" + #"Path C:\\tmp\tcache\nchanged"#))
        XCTAssertEqual(multiWire.utf8.count, 87)
        XCTAssertEqual(RCWireProtocol.renderEnglish([multiFrame]).utf8.count, 100)

        let recoveryHandle = "[[rc:abc123]]"
        let requestWire = try RCWireProtocol.serialize(.init(
            direction: .request,
            sequence: 1,
            records: [
                .init(kind: .goal, value: "Check C:\\tmp\tcache\nnow"),
                .init(kind: .exact, value: recoveryHandle),
            ]
        ))
        XCTAssertTrue(requestWire.contains("G\t" + #"Check C:\\tmp\tcache\nnow"#))
        XCTAssertTrue(requestWire.contains("X\t\(recoveryHandle)"))
        XCTAssertEqual(requestWire.utf8.count, 55)
        XCTAssertEqual(TokenEstimator.estimate(requestWire), 14)
    }

    func test_responseEfficiencyCorpusContract() throws {
        let data = try responseCorpusData()
        let cases = try loadResponseCorpus()
        XCTAssertEqual(sha256Hex(data), frozenResponseCorpusSHA256)
        XCTAssertEqual(cases.count, 10)
        XCTAssertEqual(cases.map(\.id), frozenResponseCorpusIDs)
        XCTAssertEqual(Set(cases.map(\.category)), [
            "short", "natural_nominal", "multi_record", "progressive_multiframe",
            "exact_literal_code_path", "multilingual", "repetition_template", "opaque_incompressible",
        ])
        XCTAssertTrue(Set(cases.map(\.language)).isSuperset(of: ["en", "pt", "ja", "ar", "zxx"]))
        XCTAssertEqual(Set(cases.flatMap(\.frames).flatMap(\.records).map(\.kind.rawValue)),
                       Set(["O", "A", "E", "R", "Q"]))
        for item in cases {
            let frames = try item.rcWireFrames()
            XCTAssertFalse(frames.flatMap(\.records).contains { $0.kind == .exact })
            XCTAssertEqual(RCWireProtocol.renderEnglish(frames), item.humanBaseline)
            let wire = try item.serializedWire()
            let projection = try XCTUnwrap(RCWireProtocol.strictResponseProjection(raw: wire))
            XCTAssertEqual(projection.rawWire, wire)
            XCTAssertEqual(projection.deterministicHuman, item.humanBaseline)
        }
        let nominal = try XCTUnwrap(cases.first { $0.id == nominalResponseCaseID })
        let contract = try XCTUnwrap(nominal.semanticContract)
        let sourcePrompt = try XCTUnwrap(loadCorpus().first {
            $0.id == "reported-disposable-workspace"
        })
        XCTAssertTrue(nominal.humanBaseline.hasPrefix("A disposable local workspace improves software testing"))
        XCTAssertFalse(nominal.humanBaseline.contains("Explain in one short"))
        XCTAssertEqual(sha256Hex(Data(sourcePrompt.human.utf8)), frozenNominalSourcePromptSHA256)
        XCTAssertEqual(contract.sourcePromptSHA256, frozenNominalSourcePromptSHA256)
        XCTAssertEqual(sha256Hex(contract.canonicalData), frozenResponseSemanticContractSHA256)
        XCTAssertEqual(contract.requirements.map(\.id), ResponseSemanticRequirementID.allCases)
        XCTAssertTrue(cases.filter { $0.id != nominalResponseCaseID }
            .allSatisfy { $0.semanticContract == nil })
    }

    func test_responseNominalSemanticContractPrecedesEconomicCounting() throws {
        let nominal = try XCTUnwrap(loadResponseCorpus().first {
            $0.id == nominalResponseCaseID
        })
        let contract = try XCTUnwrap(nominal.semanticContract)
        let optimisticText = "One concise human-readable English sentence: disposable temporary workspace; "
            + "isolation, repeatability, safety, cleanup, confidence; repeat, discard, unrelated projects."
        let optimistic = responseNominalCase(
            basedOn: nominal, humanBaseline: optimisticText, semanticContract: contract
        )
        var mutations = contract.requirements.map { requirement in
            (
                "missing-\(requirement.id.rawValue)",
                responseNominalCase(
                    basedOn: nominal,
                    humanBaseline: nominal.humanBaseline.replacingOccurrences(
                        of: requirement.evidenceSpan, with: ""
                    ),
                    semanticContract: contract
                ),
                requirement.id.rawValue
            )
        }
        mutations += [
            ("keyword-inventory", optimistic, "R1"),
            (
                "sentence-shape",
                responseNominalCase(
                    basedOn: nominal,
                    humanBaseline: nominal.humanBaseline + " This is a second sentence.",
                    semanticContract: contract
                ),
                "sentence shape"
            ),
            (
                "source-sha",
                responseNominalCase(
                    basedOn: nominal,
                    humanBaseline: nominal.humanBaseline,
                    semanticContract: .init(
                        sourcePromptSHA256: String(repeating: "0", count: 64),
                        language: contract.language, shape: contract.shape,
                        scope: contract.scope, productionAdmission: contract.productionAdmission,
                        requirements: contract.requirements
                    )
                ),
                "source SHA-256"
            ),
        ]
        for (name, item, expected) in mutations {
            let measurement = try responseMeasurement(item)
            var economicCountCalls = 0
            let counter = BenchmarkTokenCounter(
                diagnostic: exactTokenDiagnostic,
                sourceSHA256: String(repeating: "c", count: 64)
            ) { _ in economicCountCalls += 1; return 1 }
            XCTAssertThrowsError(try ResponseBenchmarkHarness.evaluateRowsForUnitTest(
                corpus: [item], measurements: [measurement], counter: counter
            ), name) { error in
                XCTAssertTrue(error.localizedDescription.contains("semantic contract"), "\(name): \(error)")
                XCTAssertTrue(error.localizedDescription.contains(expected), "\(name): \(error)")
            }
            XCTAssertEqual(economicCountCalls, 0, "\(name) must fail before economic counting")
        }
    }

    func test_responseReportRejectsNominalSourcePromptDriftBeforeEconomicCounting() throws {
        let data = try responseCorpusData()
        XCTAssertEqual(sha256Hex(data), frozenResponseCorpusSHA256)
        let corpus = try loadResponseCorpus()
        let measurements = try responseMeasurements(corpus)
        let original = try nominalSourcePromptFromRequestCorpus()
        var economicCountCalls = 0
        let counter = BenchmarkTokenCounter(
            diagnostic: exactTokenDiagnostic,
            sourceSHA256: String(repeating: "c", count: 64)
        ) { _ in economicCountCalls += 1; return 1 }

        XCTAssertThrowsError(try responseReport(
            corpusData: data, measurements: measurements, counter: counter,
            nominalSourcePrompt: original + " committed drift"
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("nominal source prompt SHA-256"))
        }
        XCTAssertEqual(economicCountCalls, 0, "source drift must fail before economic counting")
    }

    func test_responseBenchmarkRejectsFrozenCorpusAndCounterEvidenceTable() throws {
        let data = try responseCorpusData()
        let corpus = try loadResponseCorpus()
        let measurements = try responseMeasurements(corpus)
        let counter = responseCounter(cases: corpus, measurements: measurements)
        let first = try XCTUnwrap(corpus.first)
        let firstMeasurement = try XCTUnwrap(measurements.first)
        var preamble = measurements
        preamble[0] = .init(id: first.id, human: first.humanBaseline,
                            wire: "Provider response:\n" + firstMeasurement.wire,
                            caveman: firstMeasurement.caveman)
        let mutated = try XCTUnwrap(String(data: data, encoding: .utf8))
            .replacingOccurrences(of: "\"OK\"", with: "\"NO\"").data(using: .utf8)!
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let reversed = try JSONSerialization.data(
            withJSONObject: Array(objects.reversed()), options: [.prettyPrinted, .sortedKeys])
        let divergent = benchmarkPinnedCavemanProvenance.replacing(
            binarySHA: String(repeating: "0", count: 64))
        let one = responseCase(id: "counter-control", outcome: "Counter control Human.")
        let oneMeasurement = try responseMeasurement(one)
        let oneCounts = [
            AgentSkillInstaller.rcWireAgentInstructionsTemplate: 10,
            one.humanBaseline: 100, oneMeasurement.wire: 45,
        ]
        var drift = 0
        let driftingCounter = BenchmarkTokenCounter(diagnostic: exactTokenDiagnostic,
            sourceSHA256: String(repeating: "d", count: 64), count: { _ in drift += 1; return drift })
        let mismatched = ResponseEfficiencyCase(
            id: one.id, category: one.category, language: one.language,
            frames: one.frames, humanBaseline: one.humanBaseline + " changed",
            semanticContract: nil)
        let mismatchedMeasurement = ResponseBenchmarkMeasurement(id: one.id,
            human: mismatched.humanBaseline, wire: oneMeasurement.wire, caveman: oneMeasurement.caveman)
        func evaluate(_ cases: [ResponseEfficiencyCase], _ rows: [ResponseBenchmarkMeasurement],
                      _ counter: BenchmarkTokenCounter) throws {
            _ = try ResponseBenchmarkHarness.evaluateRowsForUnitTest(
                corpus: cases, measurements: rows, counter: counter)
        }
        let invalid: [(String, String, () throws -> Void)] = [
            ("estimated", "exact-local-tokenizer", {
                _ = try self.responseReport(corpusData: data, measurements: measurements,
                    counter: BenchmarkTokenCounter(environment: [:]))
            }),
            ("missing-row", "all response corpus rows", {
                _ = try self.responseReport(corpusData: data, measurements: Array(measurements.dropLast()),
                                            counter: counter)
            }),
            ("duplicate-row", "duplicate response row", {
                _ = try self.responseReport(corpusData: data, measurements: measurements + [firstMeasurement],
                                            counter: counter)
            }),
            ("preamble", "byte-zero RCW1 A", {
                _ = try self.responseReport(corpusData: data, measurements: preamble, counter: counter)
            }),
            ("consistent-mutation", "frozen response corpus", {
                _ = try self.responseReport(corpusData: mutated, measurements: measurements, counter: counter)
            }),
            ("reversed-order", "frozen response corpus", {
                _ = try self.responseReport(corpusData: reversed,
                    measurements: Array(measurements.reversed()), counter: counter)
            }),
            ("render", "Human render mismatch", {
                try evaluate([mismatched], [mismatchedMeasurement], self.exactTokenCounter(oneCounts))
            }),
            ("provenance", "Caveman provenance", {
                _ = try self.responseReport(corpusData: data, measurements: measurements,
                    counter: counter, provenance: divergent)
            }),
            ("missing-counter-sha", "source SHA-256", {
                try evaluate([one], [oneMeasurement], self.exactTokenCounter(oneCounts, sourceSHA256: nil))
            }),
            ("count-drift", "unstable token count", {
                try evaluate([one], [oneMeasurement], driftingCounter)
            }),
            ("zero-wire", "frame token count must be positive", {
                var counts = oneCounts; counts[oneMeasurement.wire] = 0
                try evaluate([one], [oneMeasurement], self.exactTokenCounter(counts))
            }),
            ("zero-abi", "ABI token count must be positive", {
                var counts = oneCounts; counts[AgentSkillInstaller.rcWireAgentInstructionsTemplate] = 0
                try evaluate([one], [oneMeasurement], self.exactTokenCounter(counts))
            }),
        ]
        for (name, expected, attempt) in invalid {
            XCTAssertThrowsError(try attempt(), name) { error in
                XCTAssertTrue(error.localizedDescription.contains(expected), "\(name): \(error)")
            }
        }
    }

    func test_responseBenchmarkDecisionsProfitabilityAndTotalsCoverEveryRow() throws {
        let above = responseCase(id: "above-45", outcome: "Above ratio Human baseline.")
        let observed = responseCase(id: "observed-37-over-29", outcome: "Observed false saving Human baseline.")
        let cavemanLimited = responseCase(id: "caveman-limited", outcome: "Caveman comparison Human baseline.")
        let boundary = responseCase(id: "artificial-45-percent-control", outcome: "Synthetic boundary Human baseline.")
        XCTAssertFalse(try loadResponseCorpus().contains { $0.id == boundary.id })
        let aboveMeasurement = try responseMeasurement(above)
        let observedMeasurement = try responseMeasurement(observed)
        let cavemanMeasurement = try responseMeasurement(
            cavemanLimited, cavemanOutput: "compact caveman", handleBehavior: .changedWithVerifiedHandle)
        let boundaryMeasurement = try responseMeasurement(
            boundary, cavemanOutput: "synthetic caveman output", handleBehavior: .changedWithVerifiedHandle)
        let evaluation = try ResponseBenchmarkHarness.evaluateRowsForUnitTest(
            corpus: [above, observed, cavemanLimited, boundary],
            measurements: [aboveMeasurement, observedMeasurement, cavemanMeasurement, boundaryMeasurement],
            counter: exactTokenCounter([
                AgentSkillInstaller.rcWireAgentInstructionsTemplate: 10,
                above.humanBaseline: 100, aboveMeasurement.wire: 46,
                observed.humanBaseline: 29, observedMeasurement.wire: 37,
                cavemanLimited.humanBaseline: 100, cavemanMeasurement.wire: 45,
                cavemanMeasurement.caveman.output: 50,
                boundary.humanBaseline: 100, boundaryMeasurement.wire: 45,
                boundaryMeasurement.caveman.output: 80,
            ])
        )
        let byID = Dictionary(uniqueKeysWithValues: evaluation.rows.map { ($0.id, $0) })
        let failed = try XCTUnwrap(byID[above.id])
        XCTAssertEqual(failed.decision, .humanFailOpen)
        XCTAssertEqual(failed.effectiveDeliveredTokens, failed.humanTokens)
        XCTAssertEqual(failed.claimedSavedTokensVsHuman, 0)
        XCTAssertEqual(failed.claimedSavedTokensVsCaveman, 0)
        XCTAssertTrue(byID[observed.id]?.disqualificationReasons.contains(.aboveMaximumTokenRatio) == true)
        XCTAssertEqual(byID[cavemanLimited.id]?.disqualificationReasons,
                       [.effectiveNotSmallerThanCaveman])
        let qualified = try XCTUnwrap(byID[boundary.id])
        XCTAssertEqual(qualified.decision, .rcw1)
        XCTAssertEqual(qualified.candidateFrameTokens, 45)
        XCTAssertEqual(qualified.candidateVsHumanPPM, 450_000)
        XCTAssertEqual(qualified.abiTokens, 10)
        XCTAssertEqual(qualified.candidateEffectiveTokens, 55)
        XCTAssertEqual(qualified.effectiveDeliveredTokens, 55)
        XCTAssertEqual(qualified.claimedSavedTokensVsHuman, 45)
        XCTAssertEqual(qualified.claimedSavedTokensVsCaveman, 25)
        XCTAssertEqual(
            [evaluation.totals.rows, evaluation.totals.qualifiedRows,
             evaluation.totals.disqualifiedRows], [4, 1, 3])
        XCTAssertEqual(
            [evaluation.totals.humanTokens, evaluation.totals.candidateFrameTokens,
             evaluation.totals.abiTokens, evaluation.totals.candidateEffectiveTokens,
             evaluation.totals.effectiveDeliveredTokens, evaluation.totals.cavemanTokens,
             evaluation.totals.claimedSavedTokensVsHuman,
             evaluation.totals.claimedSavedTokensVsCaveman],
            [329, 173, 40, 213, 284, 259, 45, 25])
        XCTAssertEqual(evaluation.totals.failureCounts[ResponseQualificationFailure.aboveMaximumTokenRatio.rawValue], 2)
    }

    func test_responseReportMetadataCSVAndOutputPathContract() throws {
        let data = try responseCorpusData()
        let corpus = try loadResponseCorpus()
        let measurements = try responseMeasurements(corpus)
        let counter = responseCounter(cases: corpus, measurements: measurements)
        let report = try responseReport(corpusData: data, measurements: measurements, counter: counter)
        XCTAssertEqual(report.schemaVersion, 5)
        XCTAssertEqual(report.codec, "rcw1-v1")
        XCTAssertEqual(report.corpusSHA256, frozenResponseCorpusSHA256)
        XCTAssertEqual(report.semanticContractSHA256, frozenResponseSemanticContractSHA256)
        XCTAssertEqual(report.semanticContractSourcePromptSHA256, frozenNominalSourcePromptSHA256)
        XCTAssertEqual(report.runnerSourceSHA256, try responseRunnerSourceSHA256())
        XCTAssertEqual(report.counterSourceSHA256, counter.sourceSHA256)
        XCTAssertFalse(report.methodology.providerReportedTokens)
        XCTAssertFalse(report.methodology.providerBound)
        XCTAssertTrue(report.methodology.abiCountedOncePerRow)
        XCTAssertFalse(report.methodology.semanticContractIsProductionAdmission)
        XCTAssertFalse(report.methodology.semanticContractUsesGenericNLP)
        XCTAssertEqual(report.rows.count, 10)
        XCTAssertTrue(report.rows.allSatisfy { $0.cavemanSHA256.count == 64 })
        let nominal = try XCTUnwrap(report.rows.first { $0.id == nominalResponseCaseID })
        XCTAssertEqual(nominal.semanticReceiptStatus, .passed)
        XCTAssertEqual(nominal.semanticReceiptIds, ResponseSemanticRequirementID.allCases)
        XCTAssertTrue(report.rows.filter { $0.id != nominalResponseCaseID }.allSatisfy {
            $0.semanticReceiptStatus == .notApplicable && $0.semanticReceiptIds.isEmpty
        })
        let csvLines = report.csv.split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(csvLines.count, 12, "header + 10 all-row records + one totals record")
        XCTAssertEqual(csvLines.filter { $0.hasPrefix("row,") }.count, 10)
        XCTAssertEqual(csvLines.filter { $0.hasPrefix("row,") }.map {
            String($0.split(separator: ",")[1])
        }, report.rows.map(\.id))
        XCTAssertTrue(csvLines.last?.hasPrefix("totals,") == true)
        XCTAssertTrue(csvLines.first?.contains(
            "semantic_contract_sha256,semantic_contract_source_prompt_sha256,decision,"
                + "semantic_receipt_status,semantic_receipt_ids"
        ) == true)
        XCTAssertEqual(csvLines.filter { $0.contains(frozenResponseSemanticContractSHA256) }.count, 11)
        XCTAssertEqual(csvLines.filter { $0.contains(frozenNominalSourcePromptSHA256) }.count, 11)
        XCTAssertTrue(csvLines.contains { $0.contains(",passed,R1|R2|R3|R4|R5|R6|R7|R8,") })
        XCTAssertEqual(csvLines.first?.split(separator: ",").count,
                       csvLines.last?.split(separator: ",", omittingEmptySubsequences: false).count)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: responseJSONData(report)) as? [String: Any])
        XCTAssertEqual(json["schema_version"] as? Int, 5)
        XCTAssertEqual(json["semantic_contract_sha256"] as? String,
                       frozenResponseSemanticContractSHA256)
        XCTAssertEqual(json["semantic_contract_source_prompt_sha256"] as? String,
                       frozenNominalSourcePromptSHA256)
        let jsonRows = try XCTUnwrap(json["rows"] as? [[String: Any]])
        XCTAssertEqual(jsonRows.count, 10)
        let nominalJSON = try XCTUnwrap(jsonRows.first {
            $0["id"] as? String == nominalResponseCaseID
        })
        XCTAssertEqual(nominalJSON["semantic_receipt_status"] as? String, "passed")
        XCTAssertEqual(nominalJSON["semantic_receipt_ids"] as? [String],
                       ResponseSemanticRequirementID.allCases.map(\.rawValue))
        XCTAssertNil(try responseReportOutputBundle(environment: [:]))
        let aliasStem = "remotecode-response-\(UUID().uuidString.lowercased())"
        let fixtureAlias = URL(fileURLWithPath: "/tmp/\(aliasStem)-fixture.json")
        try FileManager.default.createSymbolicLink(
            atPath: fixtureAlias.path, withDestinationPath: responseCorpusURL().path)
        defer { try? FileManager.default.removeItem(at: fixtureAlias) }
        for environment in [
            ["REMOTE_CODE_RCW1_RESPONSE_REPORT_JSON": "/tmp/report.json"],
            ["REMOTE_CODE_RCW1_RESPONSE_REPORT_CSV": "/tmp/report.csv"],
            ["REMOTE_CODE_RCW1_RESPONSE_REPORT_JSON": "/tmp/\(aliasStem)-same/report.json",
             "REMOTE_CODE_RCW1_RESPONSE_REPORT_CSV": "/tmp/\(aliasStem)-same/report.json"],
            ["REMOTE_CODE_RCW1_RESPONSE_REPORT_JSON": responseCorpusURL().path,
             "REMOTE_CODE_RCW1_RESPONSE_REPORT_CSV": "/tmp/report.csv"],
            ["REMOTE_CODE_RCW1_RESPONSE_REPORT_JSON": "/tmp/\(aliasStem)-alias/report.json",
             "REMOTE_CODE_RCW1_RESPONSE_REPORT_CSV": "/private/tmp/\(aliasStem)-alias/report.json"],
            ["REMOTE_CODE_RCW1_RESPONSE_REPORT_JSON": fixtureAlias.path,
             "REMOTE_CODE_RCW1_RESPONSE_REPORT_CSV": "/private/tmp/\(aliasStem).csv"],
        ] {
            XCTAssertThrowsError(try responseReportOutputBundle(environment: environment))
        }
        _ = try XCTUnwrap(responseReportOutputBundle(environment: [
            "REMOTE_CODE_RCW1_RESPONSE_REPORT_JSON": "/tmp/\(aliasStem)-bundle/report.json",
            "REMOTE_CODE_RCW1_RESPONSE_REPORT_CSV": "/private/tmp/\(aliasStem)-bundle/report.csv",
        ]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/private/tmp/\(aliasStem)-bundle"))
        let caseSensitive = try XCTUnwrap(URL(fileURLWithPath: "/private/tmp")
            .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames)
        let caseEnvironment = [
            "REMOTE_CODE_RCW1_RESPONSE_REPORT_JSON": "/tmp/\(aliasStem)-case/Report.json",
            "REMOTE_CODE_RCW1_RESPONSE_REPORT_CSV": "/private/tmp/\(aliasStem)-case/report.json",
        ]
        if caseSensitive {
            XCTAssertNoThrow(try responseReportOutputBundle(environment: caseEnvironment))
        } else {
            XCTAssertThrowsError(try responseReportOutputBundle(environment: caseEnvironment))
        }
    }

    func test_responseReportOutputSelectionPinsParentAgainstSymlinkSwap() throws {
        // WHY: a validated output path must not become a write into the fixture after its parent is swapped.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remotecode-output-swap-\(UUID().uuidString)", isDirectory: true)
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        let held = root.appendingPathComponent("held", isDirectory: true)
        let protected = root.appendingPathComponent("protected", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let protectedJSON = protected.appendingPathComponent("sentinel")
        let sentinel = Data("protected fixture bytes".utf8)
        try sentinel.write(to: protectedJSON)
        let bundleName = "report-bundle"
        let output = try responseOutputBundle(
            at: selected.appendingPathComponent(bundleName))
        try FileManager.default.moveItem(at: selected, to: held)
        try FileManager.default.createSymbolicLink(atPath: selected.path, withDestinationPath: protected.path)
        let json = Data(#"{"same_report":true}"#.utf8)
        let csv = "same_report,true\n"
        let receipt = try output.emit(json: json, csv: csv)
        let heldBundle = held.appendingPathComponent(bundleName)
        XCTAssertEqual(try Data(contentsOf: protectedJSON), sentinel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: protected.appendingPathComponent(bundleName).path))
        XCTAssertEqual(try Data(contentsOf: heldBundle.appendingPathComponent("report.json")), json)
        XCTAssertEqual(try String(contentsOf: heldBundle.appendingPathComponent("report.csv")), csv)
        XCTAssertTrue(receipt.jsonPath.hasSuffix("/held/\(bundleName)/report.json"))
        XCTAssertTrue(receipt.csvPath.hasSuffix("/held/\(bundleName)/report.csv"))
    }

    func test_responseReportOutputPairFailurePublishesNothing() throws {
        // WHY: failure to write either representation must leave no half-published report.
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("remotecode-output-pair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let bundle = parent.appendingPathComponent("report-bundle")
        let output = try responseOutputBundle(
            at: bundle, csvName: String(repeating: "c", count: 300) + ".csv")
        XCTAssertThrowsError(try output.emit(json: Data("{}".utf8), csv: "header\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func test_responseReportReceiptPinsCommittedBundleAfterNameReplacement() throws {
        // WHY: a post-commit rename must not make the receipt identify unrelated replacement bytes.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remotecode-output-receipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("report-bundle", isDirectory: true)
        let held = root.appendingPathComponent("held", isDirectory: true)
        let output = try responseOutputBundle(at: bundle)
        let json = Data(#"{"same_report":true}"#.utf8)
        let csv = "same_report,true\n"
        let replacementJSON = Data(#"{"replacement":true}"#.utf8)
        let replacementCSV = "replacement,true\n"
        let receipt = try output.emit(json: json, csv: csv) {
            try FileManager.default.moveItem(at: bundle, to: held)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
            try replacementJSON.write(to: bundle.appendingPathComponent("report.json"))
            try replacementCSV.write(to: bundle.appendingPathComponent("report.csv"),
                                     atomically: false, encoding: .utf8)
        }
        XCTAssertTrue(receipt.jsonPath.hasSuffix("/held/report.json"))
        XCTAssertTrue(receipt.csvPath.hasSuffix("/held/report.csv"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: receipt.jsonPath)), json)
        XCTAssertEqual(try String(contentsOfFile: receipt.csvPath), csv)
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("report.json")), replacementJSON)
        XCTAssertEqual(try String(contentsOf: bundle.appendingPathComponent("report.csv")), replacementCSV)
        XCTAssertEqual(try Data(contentsOf: held.appendingPathComponent("report.json")), json)
        XCTAssertEqual(try String(contentsOf: held.appendingPathComponent("report.csv")), csv)
    }

    func test_emitMeasuredResponseBenchmarkReportWhenExplicitlyRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = try responseReportOutputBundle(environment: environment) else {
            throw XCTSkip("Set both REMOTE_CODE_RCW1_RESPONSE_REPORT_JSON and _CSV for the offline report.")
        }
        let cavemanGo = URL(fileURLWithPath: try requiredEnvironmentValue(
            "REMOTE_CODE_RCW1_BENCHMARK_CAVEMAN_GO", environment: environment)).standardizedFileURL
        let cavemanCheckout = URL(fileURLWithPath: try requiredEnvironmentValue(
            "REMOTE_CODE_RCW1_BENCHMARK_CAVEMAN_CHECKOUT", environment: environment)).standardizedFileURL
        let counter = try BenchmarkTokenCounter(environment: environment)
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let initial = try responseRunSnapshot(repository: repository, counter: counter)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remotecode-rcw1-response-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let cavemanEngine = temporaryDirectory.appendingPathComponent("caveman-engine")
        let provenance = try buildPinnedCavemanEngine(
            go: cavemanGo, checkout: cavemanCheckout, output: cavemanEngine)
        let database = temporaryDirectory.appendingPathComponent("ccr.db")
        let nominalSourcePrompt = try nominalSourcePromptFromRequestCorpus()
        let corpusData = try responseCorpusData()
        let corpus = try JSONDecoder().decode([ResponseEfficiencyCase].self, from: corpusData)
        let observed = try corpus.map { item in
            ResponseBenchmarkMeasurement(id: item.id, human: item.humanBaseline,
                wire: try item.serializedWire(), caveman: try runCaveman(
                    engine: cavemanEngine, input: item.humanBaseline,
                    database: database, home: temporaryDirectory))
        }
        let report = try responseReport(
            corpusData: corpusData, measurements: observed, counter: counter,
            head: initial.remoteCodeHead, runnerSourceSHA256: initial.runnerSourceSHA256,
            provenance: provenance, nominalSourcePrompt: nominalSourcePrompt)
        let json = try responseJSONData(report)
        let csv = report.csv
        try validatePinnedCavemanBinary(cavemanEngine)
        let final = try responseRunSnapshot(repository: repository, counter: counter)
        guard final == initial else { throw benchmarkError("response report receipts drifted during capture") }
        let receipt = try output.emit(json: json, csv: csv)
        print("RCW1_RESPONSE_REPORT_JSON=\(receipt.jsonPath)")
        print("RCW1_RESPONSE_REPORT_CSV=\(receipt.csvPath)")
    }

    func test_emitMeasuredRequestBenchmarkReportWhenExplicitlyRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let measurementsPath = environment["REMOTE_CODE_RCW1_BENCHMARK_MEASUREMENTS"],
              !measurementsPath.isEmpty else {
            throw XCTSkip(
                "Set REMOTE_CODE_RCW1_BENCHMARK_MEASUREMENTS to an observed run artifact; no report is emitted without test-run data."
            )
        }
        guard let reportPath = environment["REMOTE_CODE_RCW1_BENCHMARK_REPORT_JSON"],
              !reportPath.isEmpty else {
            XCTFail("Set REMOTE_CODE_RCW1_BENCHMARK_REPORT_JSON when supplying measured data.")
            return
        }

        let measurementsURL = URL(fileURLWithPath: measurementsPath)
        let reportURL = URL(fileURLWithPath: reportPath)
        guard measurementsURL.standardizedFileURL != reportURL.standardizedFileURL else {
            XCTFail("The report path must not overwrite its measurement artifact.")
            return
        }
        let csvURL = environment["REMOTE_CODE_RCW1_BENCHMARK_REPORT_CSV"].flatMap { path in
            path.isEmpty ? nil : URL(fileURLWithPath: path)
        }
        if let csvURL {
            guard csvURL.standardizedFileURL != measurementsURL.standardizedFileURL,
                  csvURL.standardizedFileURL != reportURL.standardizedFileURL else {
                XCTFail("JSON, CSV, and measurement paths must be distinct.")
                return
            }
        }
        let measuredData = try Data(contentsOf: measurementsURL)
        let measurements = try JSONDecoder().decode(MeasuredBenchmarkRun.self, from: measuredData)
        let counter = try BenchmarkTokenCounter(environment: environment)
        let report = try MeasuredBenchmarkHarness.build(
            corpus: loadCorpus(),
            measurements: measurements,
            measurementArtifact: measurementsURL.path,
            counter: counter
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let reportData = try encoder.encode(report)
        try reportData.write(to: reportURL, options: .atomic)

        if let csvURL {
            try report.csv.write(
                to: csvURL,
                atomically: true,
                encoding: .utf8
            )
            print("RCW1_BENCHMARK_REPORT_CSV=\(csvURL.path)")
        }
        print("RCW1_BENCHMARK_REPORT_JSON=\(reportPath)")
        print(
            "RCW1_BENCHMARK_COUNTER=\(report.tokenCounter.name) "
                + "version=\(report.tokenCounter.version) encoding=\(report.tokenCounter.encoding)"
        )
    }

    func test_captureDecisionUsesStrictHostGatesAndAReal128BitMarker() async throws {
        let cases = try loadCorpus()
        let runtime = LocalDistillRuntime()
        let repeated = try XCTUnwrap(cases.first { $0.id == "multiframe-long-repetition" })
        let reported = try XCTUnwrap(cases.first { $0.id == "reported-disposable-workspace" })
        let short = try XCTUnwrap(cases.first { $0.id == "short-fail-open" })

        let accepted = try await captureLocalDecision(
            item: repeated,
            runtime: runtime,
            cavemanOutput: repeated.effectiveHuman
        )
        XCTAssertEqual(accepted.decision, .rcw1)
        let marker = try XCTUnwrap(accepted.recoveryHandle)
        XCTAssertTrue(isReal128BitRecoveryMarker(marker))
        XCTAssertEqual(
            try RCWireProtocol.parse(accepted.deliveredPayload)
                .flatMap(\.records)
                .filter { $0.kind == .exact && $0.value.hasPrefix("[[rc:") }
                .map(\.value),
            [marker],
            "the observed final payload must count exactly one real recovery marker"
        )

        let semanticFailOpen = try await captureLocalDecision(
            item: reported,
            runtime: runtime,
            cavemanOutput: reported.effectiveHuman
        )
        XCTAssertEqual(semanticFailOpen.decision, .humanFailOpen)
        XCTAssertEqual(semanticFailOpen.failOpenReason, .semanticGate)
        XCTAssertEqual(semanticFailOpen.deliveredPayload, reported.effectiveHuman)
        XCTAssertNil(semanticFailOpen.recoveryHandle)

        let floorFailOpen = try await captureLocalDecision(
            item: short,
            runtime: runtime,
            cavemanOutput: short.effectiveHuman
        )
        XCTAssertEqual(floorFailOpen.decision, .humanFailOpen)
        XCTAssertEqual(floorFailOpen.failOpenReason, .belowFloor)
        XCTAssertEqual(floorFailOpen.deliveredPayload, short.effectiveHuman)
        XCTAssertNil(floorFailOpen.observedRouteStage)
    }

    func test_cavemanBenchmarkRejectsBinaryNotMatchingPinnedSourceBuild() throws {
        // WHY: naming an arbitrary prebuilt binary beside the pinned checkout
        // must not let release code masquerade as the exact source-pin build.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remotecode-caveman-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = directory.appendingPathComponent("caveman-engine")
        try Data("not-the-pinned-source-build".utf8).write(to: engine)

        XCTAssertThrowsError(try validatePinnedCavemanBinary(engine))
    }

    func test_captureMeasuredRequestBenchmarkWhenExplicitlyRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let capturePath = environment["REMOTE_CODE_RCW1_BENCHMARK_CAPTURE_JSON"],
              !capturePath.isEmpty else {
            throw XCTSkip(
                "Set REMOTE_CODE_RCW1_BENCHMARK_CAPTURE_JSON to capture observed all-24 measurements."
            )
        }
        let encoderRevision = try requiredEnvironmentValue(
            "REMOTE_CODE_RCW1_BENCHMARK_ENCODER_REVISION",
            environment: environment
        )
        let cavemanGoPath = try requiredEnvironmentValue(
            "REMOTE_CODE_RCW1_BENCHMARK_CAVEMAN_GO",
            environment: environment
        )
        let cavemanCheckoutPath = try requiredEnvironmentValue(
            "REMOTE_CODE_RCW1_BENCHMARK_CAVEMAN_CHECKOUT",
            environment: environment
        )
        let cavemanGo = URL(fileURLWithPath: cavemanGoPath).standardizedFileURL
        let cavemanCheckout = URL(fileURLWithPath: cavemanCheckoutPath).standardizedFileURL
        let captureURL = URL(fileURLWithPath: capturePath).standardizedFileURL

        guard cavemanGoPath.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: cavemanGo.path) else {
            throw benchmarkError("Caveman Go compiler must be an executable absolute path")
        }
        guard cavemanCheckoutPath.hasPrefix("/"),
              FileManager.default.fileExists(atPath: cavemanCheckout.path) else {
            throw benchmarkError("Caveman checkout must be an existing absolute path")
        }
        guard captureURL != corpusURL().standardizedFileURL else {
            throw benchmarkError("capture path must not overwrite the frozen corpus")
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remotecode-rcw1-caveman-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let cavemanEngine = temporaryDirectory.appendingPathComponent("caveman-engine")
        let cavemanProvenance = try buildPinnedCavemanEngine(
            go: cavemanGo,
            checkout: cavemanCheckout,
            output: cavemanEngine
        )
        let cavemanDatabase = temporaryDirectory.appendingPathComponent("ccr.db")
        let runtime = LocalDistillRuntime()
        var rows: [MeasuredBenchmarkRow] = []
        rows.reserveCapacity(24)

        for item in try loadCorpus() {
            let caveman = try runCaveman(
                engine: cavemanEngine,
                input: item.effectiveHuman,
                database: cavemanDatabase,
                home: temporaryDirectory
            )
            rows.append(try await captureLocalDecision(
                item: item,
                runtime: runtime,
                cavemanOutput: caveman.output
            ))
        }

        let run = MeasuredBenchmarkRun(
            schemaVersion: 3,
            runID: UUID().uuidString.lowercased(),
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            source: "opt-in-test LocalDistillRuntime.distillStaged + reproducible exact-source Caveman build",
            encoder: "LocalDistillRuntime.distillStaged",
            encoderRevision: encoderRevision,
            provider: nonempty(environment["REMOTE_CODE_RCW1_BENCHMARK_PROVIDER"]),
            providerModel: nonempty(environment["REMOTE_CODE_RCW1_BENCHMARK_PROVIDER_MODEL"]),
            cavemanSourceCommit: cavemanProvenance.sourceCommit,
            cavemanGoVersion: cavemanProvenance.goVersion,
            cavemanBuildCommand: cavemanProvenance.buildCommand,
            cavemanBinarySHA: cavemanProvenance.binarySHA,
            rows: rows
        )
        XCTAssertEqual(run.rows.count, 24)
        XCTAssertEqual(Set(run.rows.map(\.id)).count, 24)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(
            at: captureURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(run).write(to: captureURL, options: .atomic)
        let roundTrip = try JSONDecoder().decode(
            MeasuredBenchmarkRun.self,
            from: Data(contentsOf: captureURL)
        )
        XCTAssertEqual(roundTrip.schemaVersion, 3)
        XCTAssertEqual(roundTrip.rows.count, 24)
        print("RCW1_BENCHMARK_CAPTURE_JSON=\(captureURL.path)")
        print("RCW1_BENCHMARK_ENCODER_REVISION=\(encoderRevision)")
        print("RCW1_BENCHMARK_CAVEMAN_SOURCE_COMMIT=\(cavemanProvenance.sourceCommit)")
        print("RCW1_BENCHMARK_CAVEMAN_GO_VERSION=\(cavemanProvenance.goVersion)")
        print("RCW1_BENCHMARK_CAVEMAN_BUILD_COMMAND=\(cavemanProvenance.buildCommand)")
        print("RCW1_BENCHMARK_CAVEMAN_BINARY_SHA=\(cavemanProvenance.binarySHA)")
    }

    func test_benchmarkHarnessRequiresAll24FrozenRowsAndLabelsFallbackCounterEstimated() throws {
        // WHY: a report over a convenient subset could make a weak encoder look
        // efficient. The harness must fail before encoding any report unless all
        // 24 frozen rows have observed production decisions and Caveman outputs.
        let counter = try BenchmarkTokenCounter(environment: [:])
        XCTAssertEqual(counter.diagnostic.measurementKind, "estimated")
        let partial = MeasuredBenchmarkRun(
            schemaVersion: 3,
            runID: "deterministic-harness-unit-test",
            capturedAt: "2000-01-01T00:00:00Z",
            source: "unit-test-not-provider-evidence",
            encoder: "identity-control",
            encoderRevision: "unit-test",
            provider: nil,
            providerModel: nil,
            cavemanSourceCommit: benchmarkPinnedCavemanProvenance.sourceCommit,
            cavemanGoVersion: benchmarkPinnedCavemanProvenance.goVersion,
            cavemanBuildCommand: benchmarkPinnedCavemanProvenance.buildCommand,
            cavemanBinarySHA: benchmarkPinnedCavemanProvenance.binarySHA,
            rows: []
        )

        XCTAssertThrowsError(try MeasuredBenchmarkHarness.build(
            corpus: loadCorpus(),
            measurements: partial,
            measurementArtifact: "/not-written/unit-test.json",
            counter: counter
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("all 24 frozen corpus rows"))
        }
    }

    func test_benchmarkHarnessRejectsEveryUnpinnedCavemanProvenanceField() throws {
        // WHY: a captured JSON file is untrusted input to report generation;
        // every provenance receipt must remain pinned, not merely non-empty.
        let corpus = try loadCorpus()
        let pinned = benchmarkPinnedCavemanProvenance
        let invalid: [(String, CavemanBenchmarkProvenance)] = [
            ("source_commit", pinned.replacing(sourceCommit: String(repeating: "0", count: 40))),
            ("go_version", pinned.replacing(goVersion: "go version forged")),
            ("build_command", pinned.replacing(buildCommand: "go build forged")),
            ("binary_sha", pinned.replacing(binarySHA: String(repeating: "0", count: 64))),
        ]

        for (field, provenance) in invalid {
            XCTAssertThrowsError(try MeasuredBenchmarkHarness.build(
                corpus: corpus,
                measurements: completeFailOpenUnitRun(
                    corpus: corpus,
                    cavemanProvenance: provenance
                ),
                measurementArtifact: "/not-written/forged-\(field).json",
                counter: BenchmarkTokenCounter(environment: [:])
            ), "\(field) must be pinned")
        }
    }

    func test_benchmarkHarnessRepresentsAllProductionDecisionsAndCountsOnlyRCW1Savings() throws {
        let cases = try loadCorpus()
        let repeated = try XCTUnwrap(cases.first { $0.id == "multiframe-long-repetition" })
        let recoveryHandle = "[[rc:benchmark-unit-repeated]]"
        let repeatedCandidate = try RCWireProtocol.addingRequestRecords(
            [.init(kind: .context, value: "Human repeated G verbatim 12 times.")],
            to: RCWireProtocol.serializeRequestText(repeated.human)
        )
        let finalRCW1 = try RCWireProtocol.addingExactRecord(recoveryHandle, to: repeatedCandidate)
        let rcw1Decision = MeasuredBenchmarkRow(
            id: repeated.id,
            decision: .rcw1,
            deliveredPayload: finalRCW1,
            recoveryHandle: recoveryHandle,
            failOpenReason: nil,
            cavemanOutput: repeated.effectiveHuman
        )
        let run = completeFailOpenUnitRun(
            corpus: cases,
            overrides: [repeated.id: rcw1Decision],
            belowFloorIDs: ["short-fail-open"]
        )

        let report = try MeasuredBenchmarkHarness.build(
            corpus: cases,
            measurements: run,
            measurementArtifact: "/not-written/complete-unit-test.json",
            counter: BenchmarkTokenCounter(environment: [:])
        )

        XCTAssertEqual(report.schemaVersion, 3)
        XCTAssertEqual(report.rows.count, 24)
        XCTAssertEqual(report.totals.rows, 24)
        XCTAssertEqual(report.totals.rcw1Rows, 1)
        XCTAssertEqual(report.totals.humanFailOpenRows, 23)
        XCTAssertEqual(report.totals.humanFailOpenSavingsTokens, 0)
        XCTAssertGreaterThan(report.totals.rcw1SavedTokens, 0)
        XCTAssertGreaterThan(report.totals.rcw1ABITokens, 0)
        XCTAssertGreaterThan(report.totals.effectiveRCW1SavedTokens, 0)
        XCTAssertEqual(
            report.totals.effectiveDeliveredTokens,
            report.totals.deliveredTokens + report.totals.rcw1ABITokens
        )
        XCTAssertNotNil(report.totals.rcw1OnlyVsHumanPPM)
        XCTAssertNotNil(report.totals.rcw1OnlyVsCavemanPPM)
        XCTAssertNotNil(report.totals.effectiveRCW1OnlyVsHumanPPM)
        XCTAssertNotNil(report.totals.effectiveRCW1OnlyVsCavemanPPM)
        XCTAssertEqual(report.totals.failOpenReasons[.belowFloor], 1)
        XCTAssertEqual(report.totals.failOpenReasons[.sidecarUnavailable], 22)

        let rcw1 = try XCTUnwrap(report.rows.first { $0.id == repeated.id })
        XCTAssertEqual(rcw1.decision, .rcw1)
        XCTAssertEqual(rcw1.recoveryHandle, recoveryHandle)
        XCTAssertEqual(rcw1.deliveredPayload, finalRCW1)
        XCTAssertTrue(rcw1.savingsCountedAsRCW1)
        XCTAssertEqual(rcw1.within45Percent, true)
        XCTAssertEqual(rcw1.smallerThanCaveman, true)
        XCTAssertGreaterThan(rcw1.savedTokens, 0)
        XCTAssertGreaterThan(try XCTUnwrap(rcw1.abiTokens), 0)
        XCTAssertEqual(
            rcw1.effectiveRCW1Tokens,
            try XCTUnwrap(rcw1.rcw1FinalTokens) + (try XCTUnwrap(rcw1.abiTokens))
        )
        XCTAssertEqual(
            rcw1.effectiveSavedTokens,
            rcw1.humanTokens - (try XCTUnwrap(rcw1.effectiveRCW1Tokens))
        )
        XCTAssertEqual(
            rcw1.effectiveRCW1VsHumanPPM,
            ratioPPM(try XCTUnwrap(rcw1.effectiveRCW1Tokens), rcw1.humanTokens)
        )
        XCTAssertEqual(
            rcw1.effectiveRCW1VsCavemanPPM,
            ratioPPM(try XCTUnwrap(rcw1.effectiveRCW1Tokens), rcw1.cavemanTokens)
        )

        let failOpen = try XCTUnwrap(report.rows.first { $0.id == "short-fail-open" })
        XCTAssertEqual(failOpen.decision, .humanFailOpen)
        XCTAssertEqual(failOpen.failOpenReason, .belowFloor)
        XCTAssertEqual(failOpen.deliveredPayload, try XCTUnwrap(cases.last).effectiveHuman)
        XCTAssertNil(failOpen.recoveryHandle)
        XCTAssertNil(failOpen.rcw1FinalTokens)
        XCTAssertNil(failOpen.abiTokens)
        XCTAssertNil(failOpen.effectiveRCW1Tokens)
        XCTAssertEqual(failOpen.savedTokens, 0)
        XCTAssertEqual(failOpen.effectiveSavedTokens, 0)
        XCTAssertFalse(failOpen.savingsCountedAsRCW1)

        let encoded = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let jsonRows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        XCTAssertEqual(jsonRows.count, 24)
        let jsonRCW1 = try XCTUnwrap(jsonRows.first { $0["id"] as? String == repeated.id })
        XCTAssertEqual(jsonRCW1["abi_tokens"] as? Int, rcw1.abiTokens)
        XCTAssertEqual(jsonRCW1["effective_rcw1_tokens"] as? Int, rcw1.effectiveRCW1Tokens)
        XCTAssertEqual(jsonRCW1["effective_saved_tokens"] as? Int, rcw1.effectiveSavedTokens)
        let methodology = try XCTUnwrap(object["methodology"] as? [String: Any])
        XCTAssertEqual(methodology["system_instructions_included"] as? Bool, true)
        XCTAssertNotNil(methodology["rcw1_abi"])
        XCTAssertNotNil(methodology["effective_rcw1"])
        XCTAssertTrue(report.csv.hasPrefix("id,language,decision,fail_open_reason,"))
        XCTAssertTrue(report.csv.contains(",abi_tokens,effective_rcw1_tokens,"))
        XCTAssertTrue(report.csv.contains(",effective_saved_tokens\n"))
        XCTAssertTrue(report.csv.contains("short-fail-open"))
    }

    func test_benchmarkHarnessRejectsMutatedOrHandleBearingHumanFailOpen() throws {
        let cases = try loadCorpus()
        let first = try XCTUnwrap(cases.first)
        let mutated = MeasuredBenchmarkRow(
            id: first.id,
            decision: .humanFailOpen,
            deliveredPayload: first.effectiveHuman + " changed",
            recoveryHandle: nil,
            failOpenReason: .sidecarUnavailable,
            cavemanOutput: first.effectiveHuman
        )
        XCTAssertThrowsError(try MeasuredBenchmarkHarness.build(
            corpus: cases,
            measurements: completeFailOpenUnitRun(corpus: cases, overrides: [first.id: mutated]),
            measurementArtifact: "/not-written/mutated.json",
            counter: BenchmarkTokenCounter(environment: [:])
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("byte-identical Human"))
        }

        let handleBearing = MeasuredBenchmarkRow(
            id: first.id,
            decision: .humanFailOpen,
            deliveredPayload: first.effectiveHuman,
            recoveryHandle: "[[rc:forbidden-on-fail-open]]",
            failOpenReason: .sidecarUnavailable,
            cavemanOutput: first.effectiveHuman
        )
        XCTAssertThrowsError(try MeasuredBenchmarkHarness.build(
            corpus: cases,
            measurements: completeFailOpenUnitRun(corpus: cases, overrides: [first.id: handleBearing]),
            measurementArtifact: "/not-written/handle.json",
            counter: BenchmarkTokenCounter(environment: [:])
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("must not carry a recovery handle"))
        }
    }

    func test_benchmarkHarnessCountsABIWithTheSelectedTokenCounter() throws {
        let cases = try loadCorpus()
        let repeated = try XCTUnwrap(cases.first { $0.id == "multiframe-long-repetition" })
        let recoveryHandle = "[[rc:benchmark-unit-abi-counter]]"
        let candidate = try RCWireProtocol.addingRequestRecords(
            [.init(kind: .context, value: "Human repeated G verbatim 12 times.")],
            to: RCWireProtocol.serializeRequestText(repeated.human)
        )
        let finalRCW1 = try RCWireProtocol.addingExactRecord(recoveryHandle, to: candidate)
        let decision = MeasuredBenchmarkRow(
            id: repeated.id,
            decision: .rcw1,
            deliveredPayload: finalRCW1,
            recoveryHandle: recoveryHandle,
            failOpenReason: nil,
            cavemanOutput: repeated.effectiveHuman
        )
        let humanTokens = TokenEstimator.estimate(repeated.effectiveHuman)
        let payloadTokens = TokenEstimator.estimate(finalRCW1)
        let abiSentinel = (humanTokens * 45) / 100 - payloadTokens + 1
        XCTAssertGreaterThan(abiSentinel, 0)
        let counter = BenchmarkTokenCounter(
            diagnostic: .init(
                name: "unit-spy",
                version: "1",
                encoding: "sentinel",
                measurementKind: "unit-test"
            ),
            count: { text in
                text == AgentSkillInstaller.rcWireAgentInstructionsTemplate
                    ? abiSentinel
                    : TokenEstimator.estimate(text)
            }
        )

        let report = try MeasuredBenchmarkHarness.build(
            corpus: cases,
            measurements: completeFailOpenUnitRun(
                corpus: cases,
                overrides: [repeated.id: decision]
            ),
            measurementArtifact: "/not-written/abi-counter.json",
            counter: counter
        )
        let row = try XCTUnwrap(report.rows.first { $0.id == repeated.id })

        XCTAssertEqual(row.abiTokens, abiSentinel)
        XCTAssertEqual(row.effectiveRCW1Tokens, try XCTUnwrap(row.rcw1FinalTokens) + abiSentinel)
        XCTAssertTrue(try XCTUnwrap(row.rcw1FinalTokens) * 100 <= row.humanTokens * 45)
        XCTAssertTrue(try XCTUnwrap(row.effectiveRCW1Tokens) * 100 > row.humanTokens * 45)
        XCTAssertEqual(report.totals.rcw1ABITokens, abiSentinel)
    }

    func test_benchmarkHarnessRejectsRCW1ThatMissesLiteralOr45PercentGate() throws {
        let cases = try loadCorpus()
        let literalCase = try XCTUnwrap(cases.first { $0.id == "url-markdown-exact" })
        let literalHandle = "[[rc:benchmark-unit-literal]]"
        let literalWire = try RCWireProtocol.addingExactRecord(
            literalHandle,
            to: RCWireProtocol.serializeRequestText("Summarize the migration note.")
        )
        let missingLiteral = MeasuredBenchmarkRow(
            id: literalCase.id,
            decision: .rcw1,
            deliveredPayload: literalWire,
            recoveryHandle: literalHandle,
            failOpenReason: nil,
            cavemanOutput: literalCase.effectiveHuman
        )
        XCTAssertThrowsError(try MeasuredBenchmarkHarness.build(
            corpus: cases,
            measurements: completeFailOpenUnitRun(corpus: cases, overrides: [literalCase.id: missingLiteral]),
            measurementArtifact: "/not-written/literal.json",
            counter: BenchmarkTokenCounter(environment: [:])
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("literal_gate"))
        }

        let reported = try XCTUnwrap(cases.first { $0.id == "reported-disposable-workspace" })
        let largeHandle = "[[rc:benchmark-unit-large]]"
        let largeWire = try RCWireProtocol.addingExactRecord(
            largeHandle,
            to: RCWireProtocol.serializeRequestText(reported.effectiveHuman)
        )
        let tooLarge = MeasuredBenchmarkRow(
            id: reported.id,
            decision: .rcw1,
            deliveredPayload: largeWire,
            recoveryHandle: largeHandle,
            failOpenReason: nil,
            cavemanOutput: reported.effectiveHuman
        )
        XCTAssertThrowsError(try MeasuredBenchmarkHarness.build(
            corpus: cases,
            measurements: completeFailOpenUnitRun(corpus: cases, overrides: [reported.id: tooLarge]),
            measurementArtifact: "/not-written/profitability.json",
            counter: BenchmarkTokenCounter(environment: [:])
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("profitability_gate"))
        }
    }

    func test_allRowRequestReportRequiresEveryFrozen24ID() async throws {
        // WHY: an accepted-only subset would hide Human/RCS1 fail-open and
        // invent a cheaper overall than the frozen request corpus.
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.count, 24)
        let partial = completeFailOpenUnitRun(corpus: Array(corpus.dropLast()))
        do {
            _ = try await AllRowBestOfThreeHarness.requestReport(
                corpus: corpus,
                measurements: partial,
                capability: allRowEstimatedCapability()
            )
            XCTFail("missing request rows must fail closed")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("24")
                    || error.localizedDescription.contains("ID order"),
                "\(error)"
            )
        }
    }

    func test_allRowResponseReportRequiresEveryFrozen10ID() async throws {
        // WHY: dropping one response fixture would let a convenient RCW1 A
        // subset stand in for the frozen 10-row surface.
        let corpus = try loadResponseCorpus()
        XCTAssertEqual(corpus.count, 10)
        let measurements = try Array(responseMeasurements(corpus).dropLast())
        do {
            _ = try await AllRowBestOfThreeHarness.responseReport(
                corpus: corpus,
                measurements: measurements,
                capability: allRowEstimatedCapability()
            )
            XCTFail("missing response rows must fail closed")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("10")
                    || error.localizedDescription.contains("ID order"),
                "\(error)"
            )
        }
    }

    func test_allRowSelectorPicksRCS1AsUniqueStrictMinimum() async throws {
        // WHY: RCS1 must be able to win from encode(Human) when it is the only
        // verified envelope strictly below Human. RCW1 stays visible.
        // Test-authority integers are not frozen corpus evidence.
        let input = allRowControlInput()
        let row = try await AllRowBestOfThreeHarness.selectRow(
            id: "rcs1-winner",
            human: input.human,
            rcw1: input.rcw1,
            rcs1: input.rcs1,
            capability: allRowTestAuthorityCapability(counts: allRowControlCounts(
                input, human: 100, rcw1Effective: 70, rcs1Effective: 30
            ))
        )
        XCTAssertEqual(row.selectedFormat, .rcs1)
        XCTAssertEqual(row.reason, .uniqueStrictMinimum)
        XCTAssertTrue(row.rcs1.eligible)
        XCTAssertTrue(row.rcw1.eligible)
        XCTAssertEqual(row.human.effectiveTokens, 100)
        XCTAssertEqual(row.rcs1.effectiveTokens, 30)
        XCTAssertEqual(row.modeledContextDelta, 70)
        XCTAssertFalse(row.billingClaim)
    }

    func test_allRowSelectorPicksRCW1AsUniqueStrictMinimum() async throws {
        // WHY: RCW1 is derived from the same Human and must still win when it
        // is the unique verified minimum. RCS1 must not be dropped.
        // Test-authority integers are not frozen corpus evidence.
        let input = allRowControlInput()
        let row = try await AllRowBestOfThreeHarness.selectRow(
            id: "rcw1-winner",
            human: input.human,
            rcw1: input.rcw1,
            rcs1: input.rcs1,
            capability: allRowTestAuthorityCapability(counts: allRowControlCounts(
                input, human: 100, rcw1Effective: 35, rcs1Effective: 80
            ))
        )
        XCTAssertEqual(row.selectedFormat, .rcw1)
        XCTAssertEqual(row.reason, .uniqueStrictMinimum)
        XCTAssertTrue(row.rcw1.eligible)
        XCTAssertTrue(row.rcs1.eligible)
        XCTAssertEqual(row.rcw1.effectiveTokens, 35)
        XCTAssertEqual(row.modeledContextDelta, 65)
        XCTAssertNotEqual(row.selectedFormat, .rcs1)
    }

    func test_allRowSelectorPicksHumanWhenItIsTheStrictMinimum() async throws {
        // WHY: a cheaper Human envelope must win. Optimized arms stay in the
        // row so the report is not accepted-only.
        let input = allRowControlInput()
        let row = try await AllRowBestOfThreeHarness.selectRow(
            id: "human-winner",
            human: input.human,
            rcw1: input.rcw1,
            rcs1: input.rcs1,
            capability: allRowTestAuthorityCapability(counts: allRowControlCounts(
                input, human: 40, rcw1Effective: 70, rcs1Effective: 80
            ))
        )
        XCTAssertEqual(row.selectedFormat, .human)
        XCTAssertEqual(row.reason, .humanLowestCost)
        XCTAssertEqual(row.modeledContextDelta, 0)
        XCTAssertEqual(row.provenSavingsTokens, 0)
        XCTAssertTrue(row.human.eligible)
        XCTAssertTrue(row.rcw1.eligible)
        XCTAssertTrue(row.rcs1.eligible)
    }

    func test_allRowSelectorPicksHumanOnTie() async throws {
        // WHY: equal verified envelopes are not a unique strict minimum. Human
        // keeps the bytes rather than flipping a coin between RCW1 and RCS1.
        let input = allRowControlInput()
        let row = try await AllRowBestOfThreeHarness.selectRow(
            id: "tie-human",
            human: input.human,
            rcw1: input.rcw1,
            rcs1: input.rcs1,
            capability: allRowTestAuthorityCapability(counts: allRowControlCounts(
                input, human: 100, rcw1Effective: 40, rcs1Effective: 40
            ))
        )
        XCTAssertEqual(row.selectedFormat, .human)
        XCTAssertEqual(row.reason, .tie)
        XCTAssertEqual(row.provenSavingsTokens, 0)
        XCTAssertTrue(row.rcw1.eligible)
        XCTAssertTrue(row.rcs1.eligible)
    }

    func test_allRowSemanticInvalidEliminatesOnlyThatArm() async throws {
        // WHY: a semantic miss is a gate, not a missing row. The invalid arm
        // stays in the table; the other verified arm may still win.
        let input = allRowControlInput()
        var broken = input.rcw1
        broken.semantic = .failed
        let row = try await AllRowBestOfThreeHarness.selectRow(
            id: "semantic-invalid",
            human: input.human,
            rcw1: broken,
            rcs1: input.rcs1,
            capability: allRowTestAuthorityCapability(counts: allRowControlCounts(
                input, human: 100, rcw1Effective: 10, rcs1Effective: 40
            ))
        )
        XCTAssertFalse(row.rcw1.eligible)
        XCTAssertEqual(row.rcw1.rejectionReason, "semantic")
        XCTAssertEqual(row.rcw1.semantic, .failed)
        XCTAssertTrue(row.rcs1.eligible)
        XCTAssertEqual(row.selectedFormat, .rcs1)
        XCTAssertEqual(row.reason, .uniqueStrictMinimum)
    }

    func test_allRowRecoveryInvalidEliminatesOnlyThatArm() async throws {
        // WHY: recovery is ranked before cost. A cheaper RCS1 that does not
        // recover Human must stay visible and lose, not disappear.
        let input = allRowControlInput()
        var broken = input.rcs1
        broken.recovery = .failed
        let row = try await AllRowBestOfThreeHarness.selectRow(
            id: "recovery-invalid",
            human: input.human,
            rcw1: input.rcw1,
            rcs1: broken,
            capability: allRowTestAuthorityCapability(counts: allRowControlCounts(
                input, human: 100, rcw1Effective: 45, rcs1Effective: 10
            ))
        )
        XCTAssertFalse(row.rcs1.eligible)
        XCTAssertEqual(row.rcs1.rejectionReason, "recovery")
        XCTAssertEqual(row.rcs1.recovery, .failed)
        XCTAssertTrue(row.rcw1.eligible)
        XCTAssertEqual(row.selectedFormat, .rcw1)
        XCTAssertEqual(row.reason, .uniqueStrictMinimum)
    }

    func test_allRowAbsentCounterPicksHumanAndKeepsEveryArm() async throws {
        // WHY: without a bound exact counter there is no comparable cost.
        // Human is the decision; the three arms still exist with no savings.
        let input = allRowControlInput()
        let row = try await AllRowBestOfThreeHarness.selectRow(
            id: "counter-absent",
            human: input.human,
            rcw1: input.rcw1,
            rcs1: input.rcs1,
            capability: nil
        )
        XCTAssertEqual(row.selectedFormat, .human)
        XCTAssertEqual(row.reason, .counterUnavailable)
        XCTAssertEqual(row.provenSavingsTokens, 0)
        XCTAssertNil(row.human.effectiveTokens)
        XCTAssertNil(row.rcw1.effectiveTokens)
        XCTAssertNil(row.rcs1.effectiveTokens)
        XCTAssertEqual(row.human.format, .human)
        XCTAssertEqual(row.rcw1.format, .rcw1)
        XCTAssertEqual(row.rcs1.format, .rcs1)
        XCTAssertFalse(row.billingClaim)
    }

    func test_allRowCountsABIAndHandleOnceWithoutBillingClaim() async throws {
        // WHY: effective cost is payload + already-included handle + one
        // unamortized ABI. Test-authority counts are not frozen evidence.
        let input = allRowControlInput()
        let probe = AllRowCountProbe(counts: allRowControlCounts(
            input, human: 100, rcw1Effective: 40, rcs1Effective: 70
        ))
        let row = try await AllRowBestOfThreeHarness.selectRow(
            id: "abi-handle-once",
            human: input.human,
            rcw1: input.rcw1,
            rcs1: input.rcs1,
            capability: allRowTestAuthorityCapability(probe: probe)
        )
        let calls = await probe.calls
        XCTAssertEqual(calls.filter { $0 == input.rcw1.abi }.count, 1)
        XCTAssertEqual(calls.filter { $0 == input.rcs1.abi }.count, 1)
        XCTAssertEqual(calls.filter { $0 == input.rcw1.handle }.count, 1)
        XCTAssertEqual(row.rcw1.handleTokens, 7)
        XCTAssertEqual(row.rcw1.abiTokens, 10)
        XCTAssertEqual(row.rcw1.payloadTokens, 30)
        XCTAssertEqual(row.rcw1.effectiveTokens, 40)
        XCTAssertEqual(row.human.abiTokens, 0)
        XCTAssertEqual(row.counterQuality, AllRowBestOfThreeHarness.testAuthorityQuality)
        XCTAssertFalse(row.billingClaim)
        XCTAssertFalse(row.providerReportedTokens)
    }

    func test_allRowRCS1IsEncodeOfHumanNeverEncodeOfRCW1() async throws {
        // WHY: chaining Human→RCW1→RCS1 would make RCS1 a second encoding of
        // the wire, not an independent arm of the same Human.
        let cases = try loadCorpus()
        let repeated = try XCTUnwrap(cases.first { $0.id == "multiframe-long-repetition" })
        let human = repeated.effectiveHuman
        let handle = "[[rc:all-row-encode-independence]]"
        let rcw1Payload = try RCWireProtocol.addingExactRecord(
            handle,
            to: RCWireProtocol.addingRequestRecords(
                [.init(kind: .context, value: "Human repeated G verbatim 12 times.")],
                to: RCWireProtocol.serializeRequestText(repeated.human)
            )
        )
        let encodedHuman = try XCTUnwrap(AllRowBestOfThreeHarness.rcs1Payload(fromHuman: human))
        XCTAssertEqual(RemoteCodeCompactSpan.decode(encodedHuman), human)
        XCTAssertNotEqual(encodedHuman, RemoteCodeCompactSpan.encode(rcw1Payload))
        let measured = completeFailOpenUnitRun(
            corpus: cases,
            overrides: [
                repeated.id: MeasuredBenchmarkRow(
                    id: repeated.id,
                    decision: .rcw1,
                    deliveredPayload: rcw1Payload,
                    recoveryHandle: handle,
                    failOpenReason: nil,
                    cavemanOutput: human
                ),
            ]
        )
        let report = try await AllRowBestOfThreeHarness.requestReport(
            corpus: cases,
            measurements: measured,
            capability: allRowEstimatedCapability()
        )
        let row = try XCTUnwrap(report.rows.first { $0.id == repeated.id })
        XCTAssertEqual(row.rcs1.payloadSHA256, sha256Hex(Data(encodedHuman.utf8)))
        if let encodedWire = RemoteCodeCompactSpan.encode(rcw1Payload) {
            XCTAssertNotEqual(row.rcs1.payloadSHA256, sha256Hex(Data(encodedWire.utf8)))
        }
        XCTAssertNotEqual(row.rcs1.payloadSHA256, row.rcw1.payloadSHA256)
        XCTAssertTrue(report.methodology.rcs1Rule.contains("encode(canonical"))
    }

    func test_allRowFrozenCorporaEmitEveryArmAndJSONCSVParity() async throws {
        // WHY: the reproducible report is all 24+10 rows, three runtime arms,
        // and fail-open kept in totals. JSON/CSV must name the same rows.
        let requestCorpus = try loadCorpus()
        let requestReport = try await AllRowBestOfThreeHarness.requestReport(
            corpus: requestCorpus,
            measurements: completeFailOpenUnitRun(
                corpus: requestCorpus,
                belowFloorIDs: ["short-fail-open"]
            ),
            capability: allRowEstimatedCapability()
        )
        XCTAssertEqual(requestReport.schemaVersion, AllRowBestOfThreeHarness.schemaVersion)
        XCTAssertEqual(requestReport.surface, .request)
        XCTAssertEqual(requestReport.rows.map(\.id), requestCorpus.map(\.id))
        XCTAssertEqual(requestReport.rows.count, 24)
        XCTAssertEqual(requestReport.totals.rows, 24)
        XCTAssertEqual(requestReport.totals.humanFailOpenRows, 24)
        XCTAssertEqual(requestReport.totals.rcw1Rows, 0)
        XCTAssertEqual(requestReport.totals.rcs1Rows, 0)
        XCTAssertEqual(requestReport.totals.uniqueStrictMinimumRows, 0)
        XCTAssertEqual(requestReport.totals.provenSavingsTokens, 0)
        XCTAssertEqual(
            requestReport.totals.humanFailOpenRows
                + requestReport.totals.rcw1Rows
                + requestReport.totals.rcs1Rows,
            24
        )
        XCTAssertEqual(
            requestReport.totals.provenSavingsTokens,
            requestReport.rows.reduce(0) { $0 + $1.provenSavingsTokens }
        )
        for row in requestReport.rows {
            XCTAssertEqual(row.selectedFormat, .human)
            XCTAssertEqual(row.human.format, .human)
            XCTAssertEqual(row.rcw1.format, .rcw1)
            XCTAssertEqual(row.rcs1.format, .rcs1)
            XCTAssertFalse(row.billingClaim)
            XCTAssertEqual(row.counterQuality, AllRowBestOfThreeHarness.estimatedQuality)
            XCTAssertNotEqual(row.selectedFormat.rawValue, "caveman")
            XCTAssertEqual(row.provenSavingsTokens, 0)
        }

        let responseCorpus = try loadResponseCorpus()
        let responseReport = try await AllRowBestOfThreeHarness.responseReport(
            corpus: responseCorpus,
            measurements: try responseMeasurements(responseCorpus),
            capability: allRowEstimatedCapability()
        )
        XCTAssertEqual(responseReport.schemaVersion, AllRowBestOfThreeHarness.schemaVersion)
        XCTAssertEqual(responseReport.surface, .response)
        XCTAssertEqual(responseReport.rows.map(\.id), frozenResponseCorpusIDs)
        XCTAssertEqual(responseReport.rows.count, 10)
        XCTAssertEqual(responseReport.totals.rows, 10)
        XCTAssertEqual(responseReport.totals.humanFailOpenRows, 10)
        XCTAssertEqual(responseReport.totals.rcw1Rows, 0)
        XCTAssertEqual(responseReport.totals.rcs1Rows, 0)
        XCTAssertEqual(responseReport.totals.provenSavingsTokens, 0)
        for row in responseReport.rows {
            XCTAssertEqual(row.selectedFormat, .human)
            XCTAssertEqual(row.human.format, .human)
            XCTAssertEqual(row.rcw1.format, .rcw1)
            XCTAssertEqual(row.rcs1.format, .rcs1)
            XCTAssertFalse(row.billingClaim)
            XCTAssertEqual(row.counterQuality, AllRowBestOfThreeHarness.estimatedQuality)
        }

        try assertAllRowJSONCSVParity(requestReport)
        try assertAllRowJSONCSVParity(responseReport)
        XCTAssertFalse(requestReport.methodology.providerReportedTokens)
        XCTAssertFalse(requestReport.methodology.billingClaim)
        XCTAssertEqual(requestReport.methodology.quality, AllRowBestOfThreeHarness.estimatedQuality)
        XCTAssertFalse(requestReport.methodology.quality.contains("exact"))
        XCTAssertFalse(requestReport.methodology.quality.contains("proven"))
        XCTAssertTrue(requestReport.methodology.scope.contains("all-frozen"))
        print(
            "ALL_ROW_REQUEST_TOTALS rows=\(requestReport.totals.rows)"
                + " human=\(requestReport.totals.humanFailOpenRows)"
                + " rcw1=\(requestReport.totals.rcw1Rows)"
                + " rcs1=\(requestReport.totals.rcs1Rows)"
                + " unique=\(requestReport.totals.uniqueStrictMinimumRows)"
                + " savings=\(requestReport.totals.provenSavingsTokens)"
                + " reasons=\(requestReport.totals.failOpenReasons)"
        )
        print(
            "ALL_ROW_RESPONSE_TOTALS rows=\(responseReport.totals.rows)"
                + " human=\(responseReport.totals.humanFailOpenRows)"
                + " rcw1=\(responseReport.totals.rcw1Rows)"
                + " rcs1=\(responseReport.totals.rcs1Rows)"
                + " unique=\(responseReport.totals.uniqueStrictMinimumRows)"
                + " savings=\(responseReport.totals.provenSavingsTokens)"
                + " reasons=\(responseReport.totals.failOpenReasons)"
        )
    }

    func test_allRowEstimatedUnknownOrErrorNeverSelectsOptimizedOrClaimsProvenSavings() async throws {
        // WHY: TokenEstimator is heuristic. A report that labels it
        // exact-local/proven can publish RCW1/RCS1 winners and savings that
        // no local exact executable measured.
        let estimatedCounter = try BenchmarkTokenCounter(environment: [:])
        XCTAssertEqual(estimatedCounter.diagnostic.measurementKind, "estimated")

        let requestCorpus = try loadCorpus()
        let requestReport = try await AllRowBestOfThreeHarness.requestReport(
            corpus: requestCorpus,
            measurements: completeFailOpenUnitRun(
                corpus: requestCorpus,
                belowFloorIDs: ["short-fail-open"]
            ),
            capability: allRowEstimatedCapability()
        )
        XCTAssertEqual(requestReport.rows.count, 24)
        XCTAssertEqual(requestReport.totals.humanFailOpenRows, 24)
        XCTAssertEqual(requestReport.totals.rcw1Rows, 0)
        XCTAssertEqual(requestReport.totals.rcs1Rows, 0)
        XCTAssertEqual(requestReport.totals.uniqueStrictMinimumRows, 0)
        XCTAssertEqual(requestReport.totals.provenSavingsTokens, 0)
        XCTAssertEqual(requestReport.methodology.quality, "estimated")
        XCTAssertFalse(requestReport.methodology.quality.contains("exact"))
        XCTAssertFalse(requestReport.methodology.quality.contains("proven"))
        XCTAssertFalse(requestReport.methodology.quality.contains("local_exact"))
        for row in requestReport.rows {
            XCTAssertEqual(row.selectedFormat, .human)
            XCTAssertNotEqual(row.selectedFormat.rawValue, "caveman")
            XCTAssertEqual(row.provenSavingsTokens, 0)
            XCTAssertEqual(row.modeledContextDelta, 0)
            XCTAssertEqual(row.counterQuality, "estimated")
            XCTAssertFalse(row.counterQuality.contains("exact"))
            XCTAssertFalse(row.counterQuality.contains("proven"))
            XCTAssertEqual(row.human.format, .human)
            XCTAssertEqual(row.rcw1.format, .rcw1)
            XCTAssertEqual(row.rcs1.format, .rcs1)
        }

        let responseCorpus = try loadResponseCorpus()
        let responseReport = try await AllRowBestOfThreeHarness.responseReport(
            corpus: responseCorpus,
            measurements: try responseMeasurements(responseCorpus),
            capability: allRowEstimatedCapability()
        )
        XCTAssertEqual(responseReport.rows.count, 10)
        XCTAssertEqual(responseReport.totals.humanFailOpenRows, 10)
        XCTAssertEqual(responseReport.totals.rcw1Rows, 0)
        XCTAssertEqual(responseReport.totals.rcs1Rows, 0)
        XCTAssertEqual(responseReport.totals.provenSavingsTokens, 0)
        XCTAssertEqual(responseReport.methodology.quality, "estimated")

        let input = allRowControlInput()
        let unknown = try await AllRowBestOfThreeHarness.selectRow(
            id: "unknown-quality",
            human: input.human,
            rcw1: input.rcw1,
            rcs1: input.rcs1,
            capability: TokenSaverBestOfThreeSelector.CounterCapability(
                counter: .init(
                    id: "unknown-counter",
                    revision: "1",
                    encoding: "unknown",
                    provider: "local",
                    resolvedModel: "unknown",
                    quality: .unknown
                ),
                count: { _ in 1 }
            )
        )
        XCTAssertEqual(unknown.selectedFormat, .human)
        XCTAssertEqual(unknown.reason, .counterUncertain)
        XCTAssertEqual(unknown.provenSavingsTokens, 0)
        XCTAssertEqual(unknown.counterQuality, "unknown")
        XCTAssertNil(unknown.human.effectiveTokens)

        let exploding = try await AllRowBestOfThreeHarness.selectRow(
            id: "error-quality",
            human: input.human,
            rcw1: input.rcw1,
            rcs1: input.rcs1,
            capability: TokenSaverBestOfThreeSelector.CounterCapability(
                counter: .init(
                    id: "error-counter",
                    revision: "1",
                    encoding: "error",
                    provider: "local",
                    resolvedModel: "error",
                    quality: .exactLocalTokenizer
                ),
                count: { _ in throw benchmarkError("counter exploded") }
            )
        )
        XCTAssertEqual(exploding.selectedFormat, .human)
        XCTAssertEqual(exploding.reason, .counterError)
        XCTAssertEqual(exploding.provenSavingsTokens, 0)
        XCTAssertNil(exploding.human.effectiveTokens)
    }

    func test_allRowEmitterFailClosedAndWritesCompleteSchema6JSONCSVWithRCS1() async throws {
        // WHY: schema 3/5 writers cannot stand in for schema 6. The all-row
        // emitter must skip without env, fail closed on partial/estimated
        // input, and write one JSON+CSV checkpoint with every Human/RCW1/RCS1 arm.
        XCTAssertNil(try AllRowReportEmitter.plan(environment: [:]))
        XCTAssertThrowsError(try AllRowReportEmitter.plan(environment: [
            AllRowReportEmitter.jsonKey: "/tmp/only-report.json"
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("complete"))
        }
        XCTAssertThrowsError(
            try AllRowBestOfThreeHarness.exactCapability(
                from: BenchmarkTokenCounter(environment: [:])
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("estimated"))
        }

        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("all-row-emitter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let bundle = parent.appendingPathComponent("all-row-bundle", isDirectory: true)
        let reportJSON = bundle.appendingPathComponent("report.json")
        let reportCSV = bundle.appendingPathComponent("report.csv")
        let measurementsURL = parent.appendingPathComponent("measurements.json")
        let requestCorpus = try loadCorpus()
        try JSONEncoder().encode(completeFailOpenUnitRun(corpus: requestCorpus))
            .write(to: measurementsURL)
        XCTAssertThrowsError(try AllRowReportEmitter.plan(environment: [
            AllRowReportEmitter.jsonKey: reportJSON.path,
            AllRowReportEmitter.csvKey: reportCSV.path,
            AllRowReportEmitter.measurementsKey: measurementsURL.path,
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("complete"))
        }
        XCTAssertThrowsError(try AllRowReportEmitter.plan(environment: [
            AllRowReportEmitter.jsonKey: reportJSON.path,
            AllRowReportEmitter.csvKey: reportCSV.path,
            AllRowReportEmitter.measurementsKey: measurementsURL.path,
            AllRowReportEmitter.tokenCounterKey: measurementsURL.path,
        ])) { error in
            let text = error.localizedDescription
            XCTAssertTrue(
                text.contains("alias") || text.contains("overlap") || text.contains("executable"),
                "\(error)"
            )
        }

        let requestReport = try await AllRowBestOfThreeHarness.requestReport(
            corpus: requestCorpus,
            measurements: completeFailOpenUnitRun(corpus: requestCorpus),
            capability: allRowEstimatedCapability()
        )
        let responseCorpus = try loadResponseCorpus()
        let responseReport = try await AllRowBestOfThreeHarness.responseReport(
            corpus: responseCorpus,
            measurements: try responseMeasurements(responseCorpus),
            capability: allRowEstimatedCapability()
        )
        try assertAllRowJSONCSVParity(requestReport)
        try assertAllRowJSONCSVParity(responseReport)
        XCTAssertThrowsError(try allRowUnitTestCheckpoint(
            request: AllRowBestOfThreeHarness.report(
                surface: .request,
                rows: Array(requestReport.rows.dropLast())
            ),
            response: responseReport
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("24"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
    }

    func test_allRowF2MeasurementMutationsMustFailBeforeCount() async throws {
        // WHY: an ID-only coverage check lets a mutated measurement artifact
        // reach counting and look like a complete all-row checkpoint.
        let corpus = try loadCorpus()
        let baseline = completeFailOpenUnitRun(corpus: corpus)
        let first = try XCTUnwrap(corpus.first)
        let last = try XCTUnwrap(corpus.last)
        let probe = AllRowCountProbe(counts: [:])
        let capability = allRowTestAuthorityCapability(probe: probe)
        let mutations: [(String, MeasuredBenchmarkRun)] = [
            (
                "schema",
                MeasuredBenchmarkRun(
                    schemaVersion: 99,
                    runID: baseline.runID,
                    capturedAt: baseline.capturedAt,
                    source: baseline.source,
                    encoder: baseline.encoder,
                    encoderRevision: baseline.encoderRevision,
                    provider: baseline.provider,
                    providerModel: baseline.providerModel,
                    cavemanSourceCommit: baseline.cavemanSourceCommit,
                    cavemanGoVersion: baseline.cavemanGoVersion,
                    cavemanBuildCommand: baseline.cavemanBuildCommand,
                    cavemanBinarySHA: baseline.cavemanBinarySHA,
                    rows: baseline.rows
                )
            ),
            (
                "corpus-order",
                MeasuredBenchmarkRun(
                    schemaVersion: baseline.schemaVersion,
                    runID: baseline.runID,
                    capturedAt: baseline.capturedAt,
                    source: baseline.source,
                    encoder: baseline.encoder,
                    encoderRevision: baseline.encoderRevision,
                    provider: baseline.provider,
                    providerModel: baseline.providerModel,
                    cavemanSourceCommit: baseline.cavemanSourceCommit,
                    cavemanGoVersion: baseline.cavemanGoVersion,
                    cavemanBuildCommand: baseline.cavemanBuildCommand,
                    cavemanBinarySHA: baseline.cavemanBinarySHA,
                    rows: Array(baseline.rows.reversed())
                )
            ),
            (
                "source-commit",
                completeFailOpenUnitRun(
                    corpus: corpus,
                    cavemanProvenance: benchmarkPinnedCavemanProvenance.replacing(
                        sourceCommit: String(repeating: "0", count: 40)
                    )
                )
            ),
            (
                "caveman-provenance",
                completeFailOpenUnitRun(
                    corpus: corpus,
                    cavemanProvenance: benchmarkPinnedCavemanProvenance.replacing(
                        binarySHA: String(repeating: "0", count: 64)
                    )
                )
            ),
            (
                "caveman-output",
                completeFailOpenUnitRun(
                    corpus: corpus,
                    overrides: [
                        first.id: MeasuredBenchmarkRow(
                            id: first.id,
                            decision: .humanFailOpen,
                            deliveredPayload: first.effectiveHuman,
                            recoveryHandle: nil,
                            failOpenReason: .sidecarUnavailable,
                            cavemanOutput: ""
                        ),
                    ]
                )
            ),
            (
                "delivered-payload",
                completeFailOpenUnitRun(
                    corpus: corpus,
                    overrides: [
                        first.id: MeasuredBenchmarkRow(
                            id: first.id,
                            decision: .humanFailOpen,
                            deliveredPayload: first.effectiveHuman + " mutated",
                            recoveryHandle: nil,
                            failOpenReason: .sidecarUnavailable,
                            cavemanOutput: first.effectiveHuman
                        ),
                    ]
                )
            ),
            (
                "recovery-handle",
                completeFailOpenUnitRun(
                    corpus: corpus,
                    overrides: [
                        last.id: MeasuredBenchmarkRow(
                            id: last.id,
                            decision: .humanFailOpen,
                            deliveredPayload: last.effectiveHuman,
                            recoveryHandle: "[[rc:forbidden-on-fail-open]]",
                            failOpenReason: .belowFloor,
                            cavemanOutput: last.effectiveHuman
                        ),
                    ]
                )
            ),
        ]
        for (name, measurements) in mutations {
            let before = await probe.calls.count
            do {
                _ = try await AllRowBestOfThreeHarness.requestReport(
                    corpus: corpus,
                    measurements: measurements,
                    capability: capability
                )
                XCTFail("\(name) reached all-row count without integrity rejection")
            } catch {
                XCTAssertFalse(
                    error.localizedDescription.contains("missing all-row"),
                    "\(name) counted before failing: \(error)"
                )
            }
            let after = await probe.calls.count
            XCTAssertEqual(after, before, "\(name) must fail before the first counter call")
        }
        do {
            try AllRowBestOfThreeHarness.validatePublicationContext(
                AllRowPublicationContext(
                    remoteCodeHead: String(repeating: "0", count: 40),
                    workspaceClean: false,
                    runnerSourceSHA256: String(repeating: "0", count: 64)
                )
            )
            XCTFail("dirty worktree / unexpected source commit reached all-row count")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("workspace")
                    || error.localizedDescription.contains("worktree")
                    || error.localizedDescription.contains("source commit")
                    || error.localizedDescription.contains("HEAD")
                    || error.localizedDescription.contains("runner"),
                "worktree/source-commit: \(error)"
            )
        }
        let finalCalls = await probe.calls.count
        XCTAssertEqual(finalCalls, 0)
        XCTAssertThrowsError(try MeasuredBenchmarkHarness.validateAllRowRequestIntegrity(
            corpus: corpus,
            corpusData: Data("mutated-request-corpus".utf8),
            measurements: baseline
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("frozen request corpus"), "\(error)")
        }
        let afterSHA = await probe.calls.count
        XCTAssertEqual(afterSHA, finalCalls)
    }

    func test_allRowF3SecondPairFailureMustPublishZero() async throws {
        // WHY: one atomic JSON+CSV pair must leave zero files when emit fails.
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("all-row-f3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let bundle = parent.appendingPathComponent("all-row-bundle", isDirectory: true)
        let requestCorpus = try loadCorpus()
        let requestReport = try await AllRowBestOfThreeHarness.requestReport(
            corpus: requestCorpus,
            measurements: completeFailOpenUnitRun(corpus: requestCorpus),
            capability: AllRowBestOfThreeHarness.localExactCapability { $0.utf8.count }
        )
        let responseCorpus = try loadResponseCorpus()
        let responseReport = try await AllRowBestOfThreeHarness.responseReport(
            corpus: responseCorpus,
            measurements: try responseMeasurements(responseCorpus),
            capability: AllRowBestOfThreeHarness.localExactCapability { $0.utf8.count }
        )
        let checkpoint = try allRowUnitTestCheckpoint(
            request: requestReport, response: responseReport
        )
        let output = try ResponseReportOutputBundle(
            jsonPath: bundle.appendingPathComponent("report.json").path,
            csvPath: bundle.appendingPathComponent(String(repeating: "c", count: 300) + ".csv").path
        )
        XCTAssertThrowsError(try AllRowReportEmitter.write(output: output, report: checkpoint))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func test_allRowF3PlanMustRefuseOutputInputAliasBeforeWrite() throws {
        // WHY: JSON/CSV may not alias the measurement artifact, counter, or fixtures.
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("all-row-alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let measurements = parent.appendingPathComponent("measurements.json")
        try Data("{}".utf8).write(to: measurements)
        XCTAssertThrowsError(try AllRowReportEmitter.plan(environment: [
            AllRowReportEmitter.jsonKey: measurements.path,
            AllRowReportEmitter.csvKey: parent.appendingPathComponent("report-bundle/report.csv").path,
            AllRowReportEmitter.measurementsKey: measurements.path,
            AllRowReportEmitter.tokenCounterKey: "/usr/bin/true",
        ])) { error in
            let text = error.localizedDescription
            XCTAssertTrue(
                text.contains("alias") || text.contains("overlap"),
                "output/input alias must be refused before count/write: \(error)"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: parent.appendingPathComponent("report-bundle").path
            )
        )
    }

    func test_allRowF5WriteMustRefuseUnitTestAuthority() async throws {
        // WHY: unit-test-authority integers are selector fixtures, not a
        // publishable local_exact checkpoint.
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("all-row-f5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let requestCorpus = try loadCorpus()
        let request = try await AllRowBestOfThreeHarness.requestReport(
            corpus: requestCorpus,
            measurements: completeFailOpenUnitRun(corpus: requestCorpus),
            capability: TokenSaverBestOfThreeSelector.CounterCapability(
                counter: .init(
                    id: AllRowBestOfThreeHarness.testAuthorityCounterID,
                    revision: "1",
                    encoding: "unit-test-authority",
                    provider: "local",
                    resolvedModel: "unit-test-authority",
                    quality: .exactLocalTokenizer
                ),
                count: { _ in 10 }
            )
        )
        let response = try await AllRowBestOfThreeHarness.responseReport(
            corpus: try loadResponseCorpus(),
            measurements: try responseMeasurements(try loadResponseCorpus()),
            capability: TokenSaverBestOfThreeSelector.CounterCapability(
                counter: .init(
                    id: AllRowBestOfThreeHarness.testAuthorityCounterID,
                    revision: "1",
                    encoding: "unit-test-authority",
                    provider: "local",
                    resolvedModel: "unit-test-authority",
                    quality: .exactLocalTokenizer
                ),
                count: { _ in 10 }
            )
        )
        XCTAssertEqual(request.methodology.quality, AllRowBestOfThreeHarness.testAuthorityQuality)
        XCTAssertEqual(request.totals.provenSavingsTokens, 0)
        let checkpoint = try allRowUnitTestCheckpoint(request: request, response: response)
        XCTAssertThrowsError(try AllRowReportEmitter.write(
            output: ResponseReportOutputBundle(
                jsonPath: parent.appendingPathComponent("all-row-bundle/report.json").path,
                csvPath: parent.appendingPathComponent("all-row-bundle/report.csv").path
            ),
            report: checkpoint
        )) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("local_exact")
                    || error.localizedDescription.contains("unit-test-authority"),
                "unit-test-authority must not publish: \(error)"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: parent.appendingPathComponent("all-row-bundle").path
            )
        )
    }

    func test_allRowLocalExactPublishesOneAtomicCheckpoint() async throws {
        // WHY: a publishable checkpoint is one JSON+CSV pair with 34 rows and
        // request/response/overall totals from exact local costs.
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("all-row-local-exact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let bundle = parent.appendingPathComponent("all-row-bundle", isDirectory: true)
        let capability = AllRowBestOfThreeHarness.localExactCapability { $0.utf8.count }
        let requestCorpus = try loadCorpus()
        let requestReport = try await AllRowBestOfThreeHarness.requestReport(
            corpus: requestCorpus,
            measurements: completeFailOpenUnitRun(corpus: requestCorpus),
            capability: capability
        )
        let responseCorpus = try loadResponseCorpus()
        let responseReport = try await AllRowBestOfThreeHarness.responseReport(
            corpus: responseCorpus,
            measurements: try responseMeasurements(responseCorpus),
            capability: capability
        )
        let checkpoint = try allRowUnitTestCheckpoint(
            request: requestReport, response: responseReport
        )
        let receipt = try AllRowReportEmitter.write(
            output: ResponseReportOutputBundle(
                jsonPath: bundle.appendingPathComponent("report.json").path,
                csvPath: bundle.appendingPathComponent("report.csv").path
            ),
            report: checkpoint
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.jsonPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.csvPath))
        let writtenJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: receipt.jsonPath))
        ) as? [String: Any])
        XCTAssertEqual(writtenJSON["schema_version"] as? Int, 6)
        let writtenRows = try XCTUnwrap(writtenJSON["rows"] as? [[String: Any]])
        XCTAssertEqual(writtenRows.count, 34)
        XCTAssertEqual(
            writtenRows.map { $0["id"] as? String },
            frozenRequestCorpusIDs + frozenResponseCorpusIDs
        )
        XCTAssertTrue(writtenRows.allSatisfy { $0["rcs1"] != nil })
        XCTAssertFalse(writtenRows.contains { $0["selected_format"] as? String == "caveman" })
        XCTAssertEqual(
            writtenRows.map { $0["counter_quality"] as? String },
            Array(repeating: AllRowBestOfThreeHarness.localExactQuality, count: 34)
        )
        let totals = try XCTUnwrap(writtenJSON["totals"] as? [String: Any])
        let requestTotals = try XCTUnwrap(totals["request"] as? [String: Any])
        let responseTotals = try XCTUnwrap(totals["response"] as? [String: Any])
        let overallTotals = try XCTUnwrap(totals["overall"] as? [String: Any])
        XCTAssertEqual(requestTotals["rows"] as? Int, 24)
        XCTAssertEqual(responseTotals["rows"] as? Int, 10)
        XCTAssertEqual(overallTotals["rows"] as? Int, 34)
        XCTAssertNotNil(requestTotals["fail_open_reasons"])
        XCTAssertNotNil(responseTotals["fail_open_reasons"])
        XCTAssertNotNil(overallTotals["fail_open_reasons"])
        let writtenCSV = try String(contentsOfFile: receipt.csvPath)
        let csvLines = writtenCSV.split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(csvLines.filter { $0.hasPrefix("row,") }.count, 34)
        XCTAssertEqual(csvLines.filter { $0.hasPrefix("totals,") }.count, 3)
        XCTAssertTrue(writtenCSV.contains("fail_open_reasons"))
        let jsonObject = try checkpoint.jsonObject()
        let jsonRows = try XCTUnwrap(jsonObject["rows"] as? [[String: Any]])
        let header = parseAllRowCSVRow(try XCTUnwrap(csvLines.first))
        let indexByName = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
        let csvRows = csvLines.filter { $0.hasPrefix("row,") }.map(parseAllRowCSVRow)
        for (index, row) in checkpoint.rows.enumerated() {
            XCTAssertEqual(jsonRows[index]["id"] as? String, row.id)
            XCTAssertEqual(csvRows[index][indexByName["id"] ?? 0], row.id)
            XCTAssertEqual(jsonRows[index]["selected_format"] as? String, row.selectedFormat.rawValue)
            XCTAssertEqual(csvRows[index][indexByName["selected_format"] ?? 0], row.selectedFormat.rawValue)
            XCTAssertEqual(
                optionalJSONNumber(jsonRows[index]["proven_savings_tokens"]),
                csvRows[index][indexByName["proven_savings_tokens"] ?? 0]
            )
        }
        XCTAssertThrowsError(try ResponseReportOutputBundle(
            jsonPath: bundle.appendingPathComponent("report.json").path,
            csvPath: bundle.appendingPathComponent("report.csv").path
        ))
    }

    func test_allRowProvenanceBindsExactCounterAndMeasurementArtifactSHA() async throws {
        // WHY: schema 6 must bind the exact tokenizer executable and the
        // measurement artifact that produced the counts. Runner/corpus hashes
        // alone let a swapped counter or mutated artifact publish.
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("all-row-p1a-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let capability = AllRowBestOfThreeHarness.localExactCapability { $0.utf8.count }
        let requestCorpus = try loadCorpus()
        let requestReport = try await AllRowBestOfThreeHarness.requestReport(
            corpus: requestCorpus,
            measurements: completeFailOpenUnitRun(corpus: requestCorpus),
            capability: capability
        )
        let responseCorpus = try loadResponseCorpus()
        let responseReport = try await AllRowBestOfThreeHarness.responseReport(
            corpus: responseCorpus,
            measurements: try responseMeasurements(responseCorpus),
            capability: capability
        )
        let checkpoint = try allRowUnitTestCheckpoint(
            request: requestReport, response: responseReport
        )
        let json = try checkpoint.jsonObject()
        let provenance = try XCTUnwrap(json["provenance"] as? [String: Any])
        let counterSHA = try XCTUnwrap(provenance["exact_counter_source_sha256"] as? String)
        let measurementSHA = try XCTUnwrap(provenance["measurement_artifact_sha256"] as? String)
        XCTAssertEqual(counterSHA, allRowUnitTestCounterSourceSHA256)
        XCTAssertEqual(measurementSHA, allRowUnitTestMeasurementArtifactSHA256)
        XCTAssertEqual(counterSHA.count, 64)
        XCTAssertEqual(measurementSHA.count, 64)
        XCTAssertTrue(
            counterSHA.allSatisfy { $0.isHexDigit && !$0.isUppercase },
            "exact counter SHA must be content-free lowercase hex: \(counterSHA)"
        )
        XCTAssertTrue(
            measurementSHA.allSatisfy { $0.isHexDigit && !$0.isUppercase },
            "measurement artifact SHA must be content-free lowercase hex: \(measurementSHA)"
        )
        XCTAssertNotEqual(counterSHA, measurementSHA)
        XCTAssertNotEqual(counterSHA, provenance["runner_source_sha256"] as? String)
        XCTAssertEqual(provenance["evidence_binding"] as? String, "unit_test_explicit")
        let header = parseAllRowCSVRow(
            try XCTUnwrap(checkpoint.csv.split(whereSeparator: \.isNewline).map(String.init).first)
        )
        XCTAssertTrue(header.contains("exact_counter_source_sha256"))
        XCTAssertTrue(header.contains("measurement_artifact_sha256"))
        XCTAssertTrue(checkpoint.csv.contains(counterSHA))
        XCTAssertTrue(checkpoint.csv.contains(measurementSHA))
        let receipt = try AllRowReportEmitter.write(
            output: ResponseReportOutputBundle(
                jsonPath: parent.appendingPathComponent("all-row-bundle/report.json").path,
                csvPath: parent.appendingPathComponent("all-row-bundle/report.csv").path
            ),
            report: checkpoint
        )
        XCTAssertEqual(receipt.exactCounterSourceSHA256, counterSHA)
        XCTAssertEqual(receipt.measurementArtifactSHA256, measurementSHA)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: receipt.jsonPath))
        ) as? [String: Any])
        let writtenProvenance = try XCTUnwrap(written["provenance"] as? [String: Any])
        XCTAssertEqual(writtenProvenance["exact_counter_source_sha256"] as? String, counterSHA)
        XCTAssertEqual(writtenProvenance["measurement_artifact_sha256"] as? String, measurementSHA)
        XCTAssertEqual(writtenProvenance["evidence_binding"] as? String, "unit_test_explicit")
        XCTAssertNotEqual(
            writtenProvenance["evidence_binding"] as? String,
            "derived_canonical_inputs",
            "unit-test explicit digests must not masquerade as a derived published artifact"
        )

        let derivedParent = parent.appendingPathComponent("derived", isDirectory: true)
        try FileManager.default.createDirectory(at: derivedParent, withIntermediateDirectories: true)
        let derived = try allRowP1BEvidence(in: derivedParent)
        let plan = try XCTUnwrap(AllRowReportEmitter.plan(environment: [
            AllRowReportEmitter.jsonKey: derived.jsonURL.path,
            AllRowReportEmitter.csvKey: derived.csvURL.path,
            AllRowReportEmitter.measurementsKey: derived.measurementsURL.path,
            AllRowReportEmitter.tokenCounterKey: derived.tokenizerURL.path,
        ]))
        let derivedReceipt = try await AllRowReportEmitter.publish(
            plan: plan,
            publicationContext: { derived.context.snapshot() }
        )
        let expectedCounter = sha256Hex(try Data(contentsOf: derived.tokenizerURL))
        let expectedMeasurement = sha256Hex(try Data(contentsOf: derived.measurementsURL))
        XCTAssertEqual(derivedReceipt.exactCounterSourceSHA256, expectedCounter)
        XCTAssertEqual(derivedReceipt.measurementArtifactSHA256, expectedMeasurement)
        XCTAssertEqual(plan.exactCounterSourceSHA256, expectedCounter)
        XCTAssertEqual(plan.measurementArtifactSHA256, expectedMeasurement)
        XCTAssertNotEqual(expectedCounter, allRowUnitTestCounterSourceSHA256)
        XCTAssertNotEqual(expectedMeasurement, allRowUnitTestMeasurementArtifactSHA256)
        let derivedJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: derivedReceipt.jsonPath))
        ) as? [String: Any])
        let derivedProvenance = try XCTUnwrap(derivedJSON["provenance"] as? [String: Any])
        XCTAssertEqual(derivedProvenance["exact_counter_source_sha256"] as? String, expectedCounter)
        XCTAssertEqual(derivedProvenance["measurement_artifact_sha256"] as? String, expectedMeasurement)
        XCTAssertEqual(derivedProvenance["evidence_binding"] as? String, "derived_canonical_inputs")
        let derivedCSV = try String(contentsOfFile: derivedReceipt.csvPath)
        XCTAssertTrue(derivedCSV.contains(expectedCounter))
        XCTAssertTrue(derivedCSV.contains(expectedMeasurement))
    }

    func test_allRowCavemanProvenanceIsRequestBenchmarkOnly() async throws {
        // WHY: Caveman is license-limited to request benchmark observations.
        // Stamping it on response rows or as an unscoped global claim implies
        // Caveman ran on the response surface.
        XCTAssertThrowsError(try MeasuredBenchmarkHarness.validateAllRowRequestIntegrity(
            corpus: try loadCorpus(),
            corpusData: try Data(contentsOf: allRowRequestCorpusURL()),
            measurements: completeFailOpenUnitRun(
                corpus: try loadCorpus(),
                cavemanProvenance: benchmarkPinnedCavemanProvenance.replacing(
                    binarySHA: String(repeating: "0", count: 64)
                )
            )
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("Caveman provenance"), "\(error)")
        }
        let capability = AllRowBestOfThreeHarness.localExactCapability { $0.utf8.count }
        let requestCorpus = try loadCorpus()
        let requestReport = try await AllRowBestOfThreeHarness.requestReport(
            corpus: requestCorpus,
            measurements: completeFailOpenUnitRun(corpus: requestCorpus),
            capability: capability
        )
        let responseCorpus = try loadResponseCorpus()
        let responseReport = try await AllRowBestOfThreeHarness.responseReport(
            corpus: responseCorpus,
            measurements: try responseMeasurements(responseCorpus),
            capability: capability
        )
        let checkpoint = try allRowUnitTestCheckpoint(
            request: requestReport, response: responseReport
        )
        XCTAssertTrue(requestReport.rows.allSatisfy { $0.cavemanSHA256?.count == 64 })
        XCTAssertTrue(responseReport.rows.allSatisfy { $0.cavemanSHA256 == nil })
        XCTAssertTrue(responseReport.rows.allSatisfy { $0.cavemanTokens == nil })
        XCTAssertTrue(checkpoint.rows.filter { $0.surface == .response }.allSatisfy {
            $0.cavemanSHA256 == nil && $0.cavemanTokens == nil
        })
        XCTAssertFalse(checkpoint.rows.contains { $0.selectedFormat.rawValue == "caveman" })
        let json = try checkpoint.jsonObject()
        let provenance = try XCTUnwrap(json["provenance"] as? [String: Any])
        let caveman = try XCTUnwrap(provenance["caveman"] as? [String: Any])
        XCTAssertEqual(caveman["scope"] as? String, "request_benchmark_observations")
        XCTAssertNotNil(caveman["request"] as? [String: Any])
        XCTAssertNil(caveman["source_commit"] as? String)
        XCTAssertNil(caveman["binary_sha"] as? String)
        let jsonRows = try XCTUnwrap(json["rows"] as? [[String: Any]])
        for row in jsonRows where row["surface"] as? String == "response" {
            XCTAssertTrue(
                row["caveman_sha256"] == nil || (row["caveman_sha256"] as? String)?.isEmpty == true,
                "response row \(row["id"] ?? "?") must not claim Caveman ran"
            )
            XCTAssertTrue(row["caveman_tokens"] == nil)
        }
        XCTAssertEqual(
            checkpoint.methodology.cavemanRule.contains("not a runtime arm"),
            true
        )
    }

    func test_allRowStaleEvidenceDuringCountPublishesZero() async throws {
        // WHY: validating the counter only before async counting lets the
        // executable, measurement artifact, HEAD/status, or runner source
        // change before the atomic write. Publication must fail closed.
        let mutations: [(String, (AllRowP1BEvidence) throws -> Void)] = [
            ("executable", { evidence in
                let handle = try FileHandle(forUpdating: evidence.tokenizerURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("\n# stale-counter\n".utf8))
            }),
            ("measurement", { evidence in
                let handle = try FileHandle(forUpdating: evidence.measurementsURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("\n".utf8))
            }),
            ("worktree", { evidence in
                evidence.context.workspaceClean = false
            }),
            ("runner", { evidence in
                evidence.context.runnerSourceSHA256 = String(repeating: "e", count: 64)
            }),
            ("head", { evidence in
                evidence.context.remoteCodeHead = String(repeating: "0", count: 40)
            }),
        ]
        for (name, mutate) in mutations {
            let parent = FileManager.default.temporaryDirectory
                .appendingPathComponent("all-row-p1b-\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: parent) }
            let evidence = try allRowP1BEvidence(in: parent)
            let plan = try XCTUnwrap(AllRowReportEmitter.plan(environment: [
                AllRowReportEmitter.jsonKey: evidence.jsonURL.path,
                AllRowReportEmitter.csvKey: evidence.csvURL.path,
                AllRowReportEmitter.measurementsKey: evidence.measurementsURL.path,
                AllRowReportEmitter.tokenCounterKey: evidence.tokenizerURL.path,
            ]))
            do {
                _ = try await AllRowReportEmitter.publish(
                    plan: plan,
                    publicationContext: { evidence.context.snapshot() },
                    afterCountingStarted: { try mutate(evidence) }
                )
                XCTFail("\(name) mutation during count published an all-row checkpoint")
            } catch {
                let text = error.localizedDescription
                XCTAssertTrue(
                    text.contains("drift")
                        || text.contains("SHA-256")
                        || text.contains("worktree")
                        || text.contains("workspace")
                        || text.contains("source commit")
                        || text.contains("HEAD")
                        || text.contains("runner"),
                    "\(name): \(error)"
                )
            }
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: evidence.bundleURL.path),
                "\(name) must publish zero JSON+CSV output"
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: parent.path)
                    .filter { $0.hasPrefix("all-row-bundle") },
                [],
                "\(name) must leave no report bundle"
            )
        }
    }

    func test_allRowProductionRecoveryFailureForcesHuman() async throws {
        // WHY: a cheaper RCW1 that cannot round-trip Human through the
        // production scoped store must stay visible and lose.
        let store = try AllRowRecoveryLab.makeStore()
        let input = allRowControlInput()
        let row = try await AllRowBestOfThreeHarness.selectRow(
            id: "recovery-store-fail",
            human: input.human,
            rcw1: input.rcw1,
            rcs1: input.rcs1,
            capability: allRowTestAuthorityCapability(counts: allRowControlCounts(
                input, human: 100, rcw1Effective: 20, rcs1Effective: 80
            )),
            recoveryStore: store,
            recoveryDisk: AllRowRecoveryLab.exhaustedDisk
        )
        XCTAssertFalse(row.rcw1.eligible)
        XCTAssertEqual(row.rcw1.rejectionReason, "recovery")
        XCTAssertEqual(row.rcw1.recovery, .failed)
        XCTAssertEqual(row.selectedFormat, .human)
        XCTAssertEqual(row.provenSavingsTokens, 0)
        XCTAssertFalse((row.rcw1.handleSHA256 ?? "").contains("rcv1."))
        XCTAssertFalse((row.rcs1.handleSHA256 ?? "").contains("rcv1."))
    }

    func test_allRowProductionRecoveryStoreRoundTripKeepsEligibleRCS1() async throws {
        // WHY: authentic store retrieve must be byte-exact Human. The report
        // may keep only the handle hash, never the raw capability.
        let store = try AllRowRecoveryLab.makeStore()
        let input = allRowControlInput()
        let row = try await AllRowBestOfThreeHarness.selectRow(
            id: "recovery-store-pass",
            human: input.human,
            rcw1: input.rcw1,
            rcs1: input.rcs1,
            capability: allRowTestAuthorityCapability(counts: allRowControlCounts(
                input, human: 100, rcw1Effective: 80, rcs1Effective: 30
            )),
            recoveryStore: store
        )
        XCTAssertTrue(row.rcs1.eligible)
        XCTAssertEqual(row.rcs1.recovery, .passed)
        XCTAssertEqual(row.selectedFormat, .rcs1)
        XCTAssertNil(row.rcs1.handleSHA256)
        XCTAssertFalse(String(describing: row).contains("rcv1."))
    }

    func test_versionedAllRowArtifactsExistForBothExactLocalTokenizers() throws {
        // WHY: an all-row checkpoint is the versioned JSON+CSV pair, not a
        // unit-test builder. Missing artifacts cannot be called complete.
        for encoding in allRowExactEncodings {
            let json = allRowVersionedReportURL(encoding: encoding, ext: "json")
            let csv = allRowVersionedReportURL(encoding: encoding, ext: "csv")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: json.path),
                "missing versioned all-row JSON for \(encoding): \(json.path)"
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: csv.path),
                "missing versioned all-row CSV for \(encoding): \(csv.path)"
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: allRowVersionedMeasurementsURL().path),
            "missing versioned all-row request measurements"
        )
    }

    func test_versionedAllRowDecisionReplayMatchesProductionSelector() async throws {
        // WHY: a report that disagrees with TokenSaverBestOfThreeSelector /
        // TokenSaverContextItemSelector is a duplicate decision function.
        let pythonPath = ProcessInfo.processInfo.environment["PYTHONPATH"] ?? ""
        guard !pythonPath.isEmpty else {
            throw XCTSkip("exact-local replay requires PYTHONPATH to a tiktoken-capable interpreter")
        }
        for encoding in allRowExactEncodings {
            let report = try loadVersionedAllRowJSON(encoding: encoding)
            let rows = try XCTUnwrap(report["rows"] as? [[String: Any]])
            XCTAssertEqual(rows.count, 34)
            let capability = try AllRowBestOfThreeHarness.exactCapability(
                from: allRowExactAdapterCounter(encoding: encoding)
            )
            let requestCorpus = try loadCorpus()
            let measurements = try JSONDecoder().decode(
                MeasuredBenchmarkRun.self,
                from: Data(contentsOf: allRowVersionedMeasurementsURL())
            )
            let replayedRequest = try await AllRowBestOfThreeHarness.requestReport(
                corpus: requestCorpus,
                measurements: measurements,
                capability: capability,
                recoveryStore: AllRowRecoveryLab.makeStore()
            )
            let responseCorpus = try loadResponseCorpus()
            let replayedResponse = try await AllRowBestOfThreeHarness.responseReport(
                corpus: responseCorpus,
                measurements: try responseMeasurements(responseCorpus),
                capability: capability,
                recoveryStore: AllRowRecoveryLab.makeStore()
            )
            let replayed = replayedRequest.rows + replayedResponse.rows
            XCTAssertEqual(replayed.map(\.id), rows.map { $0["id"] as? String })
            for (expected, actual) in zip(rows, replayed) {
                XCTAssertEqual(expected["selected_format"] as? String, actual.selectedFormat.rawValue, actual.id)
                XCTAssertEqual(expected["reason"] as? String, actual.reason.rawValue, actual.id)
                XCTAssertNotEqual(actual.selectedFormat.rawValue, "caveman", actual.id)
            }
        }
    }

    func test_emitAllRowBestOfThreeWhenExplicitlyRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let plan = try AllRowReportEmitter.plan(environment: environment) else {
            throw XCTSkip(
                "Set REMOTE_CODE_RCW1_ALL_ROW_REPORT_JSON, REMOTE_CODE_RCW1_ALL_ROW_REPORT_CSV, "
                    + "REMOTE_CODE_RCW1_BENCHMARK_MEASUREMENTS and "
                    + "REMOTE_CODE_RCW1_BENCHMARK_TOKEN_COUNTER. Real artifact NOT_RUN."
            )
        }
        let receipt = try await AllRowReportEmitter.publish(
            plan: plan,
            publicationContext: { try AllRowBestOfThreeHarness.versionedPublicationContext() }
        )
        print("RCW1_ALL_ROW_REPORT_JSON=\(receipt.jsonPath)")
        print("RCW1_ALL_ROW_REPORT_CSV=\(receipt.csvPath)")
    }

    func test_writeVersionedAllRowReportsWhenRequested() async throws {
        guard let root = ProcessInfo.processInfo.environment["REMOTE_CODE_RCW1_ALL_ROW_VERSIONED_OUT"],
              !root.isEmpty else {
            throw XCTSkip("Set REMOTE_CODE_RCW1_ALL_ROW_VERSIONED_OUT to emit versioned all-row reports.")
        }
        let receipts = try await emitVersionedAllRowReports(to: URL(fileURLWithPath: root))
        for (encoding, pair) in receipts {
            print("ALL_ROW_EMIT encoding=\(encoding) json=\(pair.jsonSHA) csv=\(pair.csvSHA) equal=\(pair.runsEqual)")
            XCTAssertTrue(pair.runsEqual, "\(encoding) two-run artifacts must be byte-identical")
        }
    }

    private var allRowExactEncodings: [String] { ["o200k_base", "cl100k_base"] }

    private func allRowVersionedRootURL() -> URL {
        allRowRepositoryURL()
            .appendingPathComponent("Tests/Fixtures/all-row-best-of-three", isDirectory: true)
    }

    private func allRowVersionedMeasurementsURL() -> URL {
        allRowVersionedRootURL().appendingPathComponent("request-measurements.json")
    }

    private func allRowVersionedReportURL(encoding: String, ext: String) -> URL {
        allRowVersionedRootURL()
            .appendingPathComponent(encoding, isDirectory: true)
            .appendingPathComponent("report.\(ext)")
    }

    private func allRowAdapterURL() -> URL {
        allRowRepositoryURL().appendingPathComponent("scripts/rcw1-token-count-o200k.py")
    }

    private func allRowExactAdapterCounter(encoding: String) throws -> BenchmarkTokenCounter {
        try BenchmarkTokenCounter(environment: [
            AllRowReportEmitter.tokenCounterKey: allRowAdapterURL().path,
            "RCW1_TIKTOKEN_ENCODING": encoding,
            "PYTHONPATH": ProcessInfo.processInfo.environment["PYTHONPATH"] ?? "",
        ])
    }

    private func loadVersionedAllRowJSON(encoding: String) throws -> [String: Any] {
        let data = try Data(contentsOf: allRowVersionedReportURL(encoding: encoding, ext: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private struct VersionedEmissionPair {
        let jsonSHA: String
        let csvSHA: String
        let runsEqual: Bool
        let jsonPath: String
        let csvPath: String
    }

    private func emitVersionedAllRowReports(
        to root: URL
    ) async throws -> [String: VersionedEmissionPair] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let measurementsURL = root.appendingPathComponent("request-measurements.json")
        if !FileManager.default.fileExists(atPath: measurementsURL.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try encoder.encode(completeFailOpenUnitRun(corpus: loadCorpus())).write(to: measurementsURL)
        }
        let adapter = allRowAdapterURL()
        let pythonPath = ProcessInfo.processInfo.environment["PYTHONPATH"] ?? ""
        guard !pythonPath.isEmpty else {
            throw benchmarkError("exact-local emit requires PYTHONPATH for tiktoken")
        }
        let context = try AllRowBestOfThreeHarness.versionedPublicationContext()
        var results: [String: VersionedEmissionPair] = [:]
        for encoding in allRowExactEncodings {
            var shas: [(String, String)] = []
            var lastJSON = ""
            var lastCSV = ""
            let encodingDir = root.appendingPathComponent(encoding, isDirectory: true)
            try FileManager.default.createDirectory(at: encodingDir, withIntermediateDirectories: true)
            for run in 1...2 {
                let bundle = encodingDir.appendingPathComponent("run-\(run)", isDirectory: true)
                let jsonURL = bundle.appendingPathComponent("report.json")
                let csvURL = bundle.appendingPathComponent("report.csv")
                let plan = try XCTUnwrap(AllRowReportEmitter.plan(environment: [
                    AllRowReportEmitter.jsonKey: jsonURL.path,
                    AllRowReportEmitter.csvKey: csvURL.path,
                    AllRowReportEmitter.measurementsKey: measurementsURL.path,
                    AllRowReportEmitter.tokenCounterKey: adapter.path,
                    "RCW1_TIKTOKEN_ENCODING": encoding,
                    "PYTHONPATH": pythonPath,
                ]))
                let receipt = try await AllRowReportEmitter.publish(
                    plan: plan,
                    publicationContext: { context }
                )
                lastJSON = receipt.jsonPath
                lastCSV = receipt.csvPath
                shas.append((
                    sha256Hex(try Data(contentsOf: URL(fileURLWithPath: receipt.jsonPath))),
                    sha256Hex(try Data(contentsOf: URL(fileURLWithPath: receipt.csvPath)))
                ))
            }
            results[encoding] = VersionedEmissionPair(
                jsonSHA: shas[0].0,
                csvSHA: shas[0].1,
                runsEqual: shas[0] == shas[1],
                jsonPath: lastJSON,
                csvPath: lastCSV
            )
        }
        return results
    }

    private func allRowUnitTestCheckpoint(
        request: AllRowRuntimeReport,
        response: AllRowRuntimeReport
    ) throws -> AllRowCheckpointReport {
        try AllRowBestOfThreeHarness.checkpoint(
            request: request,
            response: response,
            exactCounterSourceSHA256: allRowUnitTestCounterSourceSHA256,
            measurementArtifactSHA256: allRowUnitTestMeasurementArtifactSHA256,
            evidenceBinding: .unitTestExplicit,
            publicationContext: allRowUnitTestPublicationContext()
        )
    }

    private func allRowP1BEvidence(in parent: URL) throws -> AllRowP1BEvidence {
        let tokenizerURL = parent.appendingPathComponent("tokenizer.sh")
        let script = """
        #!/bin/sh
        if [ "$1" = "--diagnostic" ]; then
          printf '%s' '{"name":"all-row-unit-tokenizer","version":"1","encoding":"utf8-bytes","measurement_kind":"exact-local-tokenizer"}'
          exit 0
        fi
        if [ "$1" = "--count" ]; then
          wc -c | awk '{print $1}'
          exit 0
        fi
        exit 1
        """
        try script.write(to: tokenizerURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tokenizerURL.path
        )
        let measurementsURL = parent.appendingPathComponent("measurements.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(completeFailOpenUnitRun(corpus: loadCorpus())).write(to: measurementsURL)
        let bundleURL = parent.appendingPathComponent("all-row-bundle", isDirectory: true)
        return AllRowP1BEvidence(
            tokenizerURL: tokenizerURL,
            measurementsURL: measurementsURL,
            jsonURL: bundleURL.appendingPathComponent("report.json"),
            csvURL: bundleURL.appendingPathComponent("report.csv"),
            bundleURL: bundleURL,
            context: AllRowP1BPublicationContext(
                remoteCodeHead: allRowExpectedSourceCommit,
                workspaceClean: true,
                runnerSourceSHA256: String(repeating: "d", count: 64)
            )
        )
    }

    private func allRowControlInput() -> (human: String, rcw1: AllRowArmInput, rcs1: AllRowArmInput) {
        let human = "canonical Human content"
        let handle = "rcv1.handle"
        return (
            human,
            AllRowArmInput(
                payload: "RCW1 candidate [[rc:\(handle)]]",
                handle: handle,
                abi: AgentSkillInstaller.rcWireAgentInstructionsTemplate,
                producerID: TokenSaverRequestSelectionReceipt.rcw1ProducerID,
                generation: .passed, structural: .passed, semantic: .passed, recovery: .passed
            ),
            AllRowArmInput(
                payload: "RCS1 candidate",
                handle: nil,
                abi: AgentSkillInstaller.compactSpanAgentInstructionsTemplate,
                producerID: TokenSaverRequestSelectionReceipt.rcs1ProducerID,
                generation: .passed, structural: .passed, semantic: .passed, recovery: .passed
            )
        )
    }

    private func allRowControlCounts(
        _ input: (human: String, rcw1: AllRowArmInput, rcs1: AllRowArmInput),
        human: Int,
        rcw1Effective: Int,
        rcs1Effective: Int
    ) -> [String: Int] {
        [
            input.human: human,
            input.rcw1.payload: 30,
            input.rcw1.handle ?? "": 7,
            input.rcw1.abi: 10,
            input.rcw1.envelope: rcw1Effective,
            input.rcs1.payload: 25,
            input.rcs1.abi: 5,
            input.rcs1.envelope: rcs1Effective,
        ]
    }

    private func allRowEstimatedCapability() -> TokenSaverBestOfThreeSelector.CounterCapability {
        AllRowBestOfThreeHarness.estimatedCapability()
    }

    private func allRowTestAuthorityCapability(
        counts: [String: Int]? = nil,
        probe: AllRowCountProbe? = nil
    ) -> TokenSaverBestOfThreeSelector.CounterCapability {
        AllRowBestOfThreeHarness.testAuthorityCapability(counts: counts, probe: probe)
    }

    private func assertAllRowJSONCSVParity(_ report: AllRowRuntimeReport) throws {
        let json = try report.jsonObject()
        let jsonRows = try XCTUnwrap(json["rows"] as? [[String: Any]])
        XCTAssertEqual(jsonRows.count, report.rows.count)
        XCTAssertEqual(json["schema_version"] as? Int, report.schemaVersion)
        XCTAssertEqual(json["billing_claim"] as? Bool, false)
        for required in [
            "surface", "counter_id", "counter_revision", "counter_encoding",
            "provider_reported_tokens",
            "human_handle_sha256", "human_abi_sha256", "human_effective_envelope_sha256",
            "rcw1_handle_sha256", "rcw1_abi_sha256", "rcw1_effective_envelope_sha256",
            "rcs1_handle_sha256", "rcs1_abi_sha256", "rcs1_effective_envelope_sha256",
        ] {
            XCTAssertTrue(
                allRowCSVHeader.contains(required),
                "all-row CSV omits \(required) present in the JSON contract"
            )
        }
        let csvLines = report.csv.split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(csvLines.first?.split(separator: ",").count,
                       csvLines.last?.split(separator: ",", omittingEmptySubsequences: false).count)
        let header = parseAllRowCSVRow(try XCTUnwrap(csvLines.first))
        XCTAssertEqual(header, allRowCSVHeader)
        let csvRows = csvLines.filter { $0.hasPrefix("row,") }.map(parseAllRowCSVRow)
        XCTAssertEqual(csvRows.count, report.rows.count)
        let indexByName = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
        func csvValue(_ row: [String], _ name: String) -> String {
            guard let index = indexByName[name], index < row.count else {
                XCTFail("CSV missing column \(name)")
                return ""
            }
            return row[index]
        }
        XCTAssertEqual(csvValue(csvRows[0], "counter_quality"), jsonRows[0]["counter_quality"] as? String)
        XCTAssertEqual(csvValue(csvRows[0], "counter_id"), jsonRows[0]["counter_id"] as? String ?? "")
        XCTAssertEqual(csvValue(csvRows[0], "counter_revision"), jsonRows[0]["counter_revision"] as? String ?? "")
        XCTAssertEqual(csvValue(csvRows[0], "counter_encoding"), jsonRows[0]["counter_encoding"] as? String ?? "")
        XCTAssertEqual(csvValue(csvRows[0], "provider_reported_tokens"), "false")
        XCTAssertEqual(csvRows.map { csvValue($0, "id") }, report.rows.map(\.id))
        for (index, row) in report.rows.enumerated() {
            let csvRow = csvRows[index]
            let jsonRow = jsonRows[index]
            XCTAssertEqual(jsonRow["id"] as? String, row.id)
            XCTAssertEqual(csvValue(csvRow, "id"), row.id)
            XCTAssertEqual(jsonRow["selected_format"] as? String, row.selectedFormat.rawValue)
            XCTAssertEqual(csvValue(csvRow, "selected_format"), row.selectedFormat.rawValue)
            XCTAssertEqual(jsonRow["reason"] as? String, row.reason.rawValue)
            XCTAssertEqual(csvValue(csvRow, "reason"), row.reason.rawValue)
            XCTAssertEqual(jsonRow["billing_claim"] as? Bool, false)
            XCTAssertEqual(csvValue(csvRow, "billing_claim"), "false")
            XCTAssertEqual(csvValue(csvRow, "surface"), report.surface.rawValue)
            XCTAssertEqual(jsonRow["surface"] as? String, report.surface.rawValue)
            XCTAssertEqual(json["surface"] as? String, report.surface.rawValue)
            let jsonHuman = try XCTUnwrap(jsonRow["human"] as? [String: Any])
            let jsonRCW1 = try XCTUnwrap(jsonRow["rcw1"] as? [String: Any])
            let jsonRCS1 = try XCTUnwrap(jsonRow["rcs1"] as? [String: Any])
            XCTAssertEqual(jsonHuman["format"] as? String, "human")
            XCTAssertEqual(jsonRCW1["format"] as? String, "rcw1")
            XCTAssertEqual(jsonRCS1["format"] as? String, "rcs1")
            try assertAllRowArmParity(json: jsonHuman, csv: csvRow, prefix: "human", csvValue: csvValue)
            try assertAllRowArmParity(json: jsonRCW1, csv: csvRow, prefix: "rcw1", csvValue: csvValue)
            try assertAllRowArmParity(json: jsonRCS1, csv: csvRow, prefix: "rcs1", csvValue: csvValue)
        }
        XCTAssertTrue(csvLines.last?.hasPrefix("totals,") == true)
        let jsonTotals = try XCTUnwrap(json["totals"] as? [String: Any])
        XCTAssertEqual(jsonTotals["rows"] as? Int, report.rows.count)
        XCTAssertEqual(jsonTotals["human_fail_open_rows"] as? Int, report.totals.humanFailOpenRows)
        XCTAssertNil(jsonTotals["accepted_only_rows"])
        let totalsRow = parseAllRowCSVRow(try XCTUnwrap(csvLines.last))
        XCTAssertEqual(csvValue(totalsRow, "rows"), String(report.totals.rows))
        XCTAssertEqual(
            csvValue(totalsRow, "fail_open_reasons"),
            allRowFailOpenReasonsField(report.totals.failOpenReasons)
        )
        XCTAssertTrue(allRowCSVHeader.contains("rows"))
        XCTAssertTrue(allRowCSVHeader.contains("fail_open_reasons"))
    }

    private func assertAllRowArmParity(
        json: [String: Any],
        csv: [String],
        prefix: String,
        csvValue: ([String], String) -> String
    ) throws {
        XCTAssertEqual(csvValue(csv, "\(prefix)_eligible"), String(try XCTUnwrap(json["eligible"] as? Bool)))
        XCTAssertEqual(csvValue(csv, "\(prefix)_source_bound"), String(try XCTUnwrap(json["source_bound"] as? Bool)))
        XCTAssertEqual(csvValue(csv, "\(prefix)_generation"), json["generation"] as? String ?? "")
        XCTAssertEqual(csvValue(csv, "\(prefix)_structural"), json["structural"] as? String ?? "")
        XCTAssertEqual(csvValue(csv, "\(prefix)_semantic"), json["semantic"] as? String ?? "")
        XCTAssertEqual(csvValue(csv, "\(prefix)_recovery"), json["recovery"] as? String ?? "")
        XCTAssertEqual(csvValue(csv, "\(prefix)_payload_tokens"), optionalJSONNumber(json["payload_tokens"]))
        XCTAssertEqual(csvValue(csv, "\(prefix)_handle_tokens"), optionalJSONNumber(json["handle_tokens"]))
        XCTAssertEqual(csvValue(csv, "\(prefix)_abi_tokens"), optionalJSONNumber(json["abi_tokens"]))
        XCTAssertEqual(csvValue(csv, "\(prefix)_effective_tokens"), optionalJSONNumber(json["effective_tokens"]))
        XCTAssertEqual(csvValue(csv, "\(prefix)_payload_sha256"), json["payload_sha256"] as? String ?? "")
        XCTAssertEqual(csvValue(csv, "\(prefix)_handle_sha256"), json["handle_sha256"] as? String ?? "")
        XCTAssertEqual(csvValue(csv, "\(prefix)_abi_sha256"), json["abi_sha256"] as? String ?? "")
        XCTAssertEqual(
            csvValue(csv, "\(prefix)_effective_envelope_sha256"),
            json["effective_envelope_sha256"] as? String ?? ""
        )
    }

    private func completeFailOpenUnitRun(
        corpus: [EfficiencyCase],
        overrides: [String: MeasuredBenchmarkRow] = [:],
        belowFloorIDs: Set<String> = [],
        cavemanProvenance: CavemanBenchmarkProvenance = benchmarkPinnedCavemanProvenance
    ) -> MeasuredBenchmarkRun {
        MeasuredBenchmarkRun(
            schemaVersion: 3,
            runID: "deterministic-harness-unit-test",
            capturedAt: "2000-01-01T00:00:00Z",
            source: "unit-test-not-provider-evidence",
            encoder: "deterministic-unit-control",
            encoderRevision: "unit-test",
            provider: nil,
            providerModel: nil,
            cavemanSourceCommit: cavemanProvenance.sourceCommit,
            cavemanGoVersion: cavemanProvenance.goVersion,
            cavemanBuildCommand: cavemanProvenance.buildCommand,
            cavemanBinarySHA: cavemanProvenance.binarySHA,
            rows: corpus.map { item in
                overrides[item.id] ?? MeasuredBenchmarkRow(
                    id: item.id,
                    decision: .humanFailOpen,
                    deliveredPayload: item.effectiveHuman,
                    recoveryHandle: nil,
                    failOpenReason: belowFloorIDs.contains(item.id) ? .belowFloor : .sidecarUnavailable,
                    cavemanOutput: item.effectiveHuman
                )
            }
        )
    }

    private func captureLocalDecision(
        item: EfficiencyCase,
        runtime: LocalDistillRuntime,
        cavemanOutput: String
    ) async throws -> MeasuredBenchmarkRow {
        let human = item.effectiveHuman
        let inputTokens = TokenEstimator.estimate(human)
        guard inputTokens >= 80 else {
            return measuredHumanFailOpen(
                item: item,
                reason: .belowFloor,
                cavemanOutput: cavemanOutput,
                observedStage: nil,
                observedOutput: nil
            )
        }

        let inputByteCount = human.utf8.count
        let maxOutputCharacters = inputByteCount > (Int.max - 1_024) / 2
            ? Int.max
            : max(512, inputByteCount * 2 + 1_024)
        let staged = try await runtime.distillStaged(.init(
            mode: .wireEncode,
            priority: .interactive,
            input: human,
            runMode: .optimize,
            maxOutputCharacters: maxOutputCharacters
        ))
        let observedStage = staged.stage?.rawValue
        let candidate = staged.output
        guard staged.stage == .deterministic,
              let frames = try? RCWireProtocol.parse(candidate),
              frames.allSatisfy({ $0.direction == .request }) else {
            return measuredHumanFailOpen(
                item: item,
                reason: .semanticGate,
                cavemanOutput: cavemanOutput,
                observedStage: observedStage,
                observedOutput: candidate
            )
        }
        let candidateValues = frames.flatMap(\.records).map(\.value).joined(separator: "\n")
        guard RCWireProtocol.preservesProtectedSemantics(original: human, wire: candidate),
              LiteralPreservation.guarded(original: human, compressed: candidate).droppedLiteral == nil,
              item.requiredExact.allSatisfy(candidateValues.contains) else {
            return measuredHumanFailOpen(
                item: item,
                reason: .literalGate,
                cavemanOutput: cavemanOutput,
                observedStage: observedStage,
                observedOutput: candidate
            )
        }
        guard RCWireProtocol.preservesRequestMeaning(original: human, wire: candidate) else {
            return measuredHumanFailOpen(
                item: item,
                reason: .semanticGate,
                cavemanOutput: cavemanOutput,
                observedStage: observedStage,
                observedOutput: candidate
            )
        }

        let recoveryHandle = makeReal128BitRecoveryMarker()
        let finalWire = try RCWireProtocol.addingExactRecord(recoveryHandle, to: candidate)
        let outputTokens = TokenEstimator.estimate(finalWire)
        let grammarTokens = TokenEstimator.estimate(AgentSkillInstaller.rcWireAgentInstructionsTemplate)
        let finalFrames = try RCWireProtocol.parse(finalWire)
        let recoveryRecords = finalFrames.flatMap(\.records).filter {
            $0.kind == .exact && $0.value.hasPrefix("[[rc:")
        }
        guard item.eligible,
              recoveryRecords.count == 1,
              recoveryRecords[0].value == recoveryHandle,
              outputTokens <= (inputTokens * 45) / 100,
              finalWire.utf8.count < human.utf8.count,
              outputTokens + grammarTokens < inputTokens else {
            return measuredHumanFailOpen(
                item: item,
                reason: .profitabilityGate,
                cavemanOutput: cavemanOutput,
                observedStage: observedStage,
                observedOutput: candidate
            )
        }
        return MeasuredBenchmarkRow(
            id: item.id,
            decision: .rcw1,
            deliveredPayload: finalWire,
            recoveryHandle: recoveryHandle,
            failOpenReason: nil,
            cavemanOutput: cavemanOutput,
            observedRouteStage: observedStage,
            observedEncoderOutput: candidate
        )
    }

    private func measuredHumanFailOpen(
        item: EfficiencyCase,
        reason: BenchmarkFailOpenReason,
        cavemanOutput: String,
        observedStage: String?,
        observedOutput: String?
    ) -> MeasuredBenchmarkRow {
        MeasuredBenchmarkRow(
            id: item.id,
            decision: .humanFailOpen,
            deliveredPayload: item.effectiveHuman,
            recoveryHandle: nil,
            failOpenReason: reason,
            cavemanOutput: cavemanOutput,
            observedRouteStage: observedStage,
            observedEncoderOutput: observedOutput
        )
    }

    private func requiredEnvironmentValue(
        _ name: String,
        environment: [String: String]
    ) throws -> String {
        guard let value = nonempty(environment[name]) else {
            throw benchmarkError("missing required capture environment value \(name)")
        }
        return value
    }

    private func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func buildPinnedCavemanEngine(
        go: URL,
        checkout: URL,
        output: URL
    ) throws -> CavemanBenchmarkProvenance {
        let sourceCommit = try subprocessText(
            executable: "/usr/bin/git",
            arguments: ["-C", checkout.path, "rev-parse", "HEAD"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard sourceCommit == benchmarkPinnedCavemanProvenance.sourceCommit else {
            throw benchmarkError(
                "Caveman source_commit \(sourceCommit) does not match pinned "
                    + benchmarkPinnedCavemanProvenance.sourceCommit
            )
        }
        let sourceChanges = try subprocessText(
            executable: "/usr/bin/git",
            arguments: ["-C", checkout.path, "status", "--porcelain=v1", "--untracked-files=all"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard sourceChanges.isEmpty else {
            throw benchmarkError("Caveman source checkout must be clean before the pinned build")
        }
        let goVersion = try subprocessText(
            executable: go.path,
            arguments: ["version"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard goVersion == benchmarkPinnedCavemanProvenance.goVersion else {
            throw benchmarkError("Caveman Go toolchain does not match pinned \(benchmarkPinnedCavemanProvenance.goVersion)")
        }

        var buildEnvironment = ProcessInfo.processInfo.environment
        buildEnvironment["CGO_ENABLED"] = "0"
        buildEnvironment["GOENV"] = "off"
        buildEnvironment["GOOS"] = "darwin"
        buildEnvironment["GOARCH"] = "arm64"
        buildEnvironment["GOTOOLCHAIN"] = "local"
        buildEnvironment["GOWORK"] = "off"
        buildEnvironment["GOFLAGS"] = ""
        _ = try subprocess(
            executable: go.path,
            arguments: [
                "-C", checkout.path, "build", "-mod=readonly", "-trimpath",
                "-o", output.path, "./engine/cmd/caveman-engine",
            ],
            input: Data(),
            environment: buildEnvironment
        )
        try validatePinnedCavemanBinary(output)
        let buildInfo = try subprocessText(
            executable: go.path,
            arguments: ["version", "-m", output.path]
        )
        let receipts = Set(buildInfo.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        })
        guard [
            "path\tgithub.com/JuliusBrussee/caveman/engine/cmd/caveman-engine",
            "build\t-trimpath=true", "build\tCGO_ENABLED=0",
            "build\tGOARCH=arm64", "build\tGOOS=darwin",
            "build\tvcs.revision=\(sourceCommit)", "build\tvcs.modified=false",
        ].allSatisfy(receipts.contains) else {
            throw benchmarkError("Caveman binary build metadata does not match the exact-source recipe")
        }
        return benchmarkPinnedCavemanProvenance
    }

    private func validatePinnedCavemanBinary(_ engine: URL) throws {
        let binarySHA = sha256Hex(try Data(contentsOf: engine))
        guard binarySHA == benchmarkPinnedCavemanProvenance.binarySHA else {
            throw benchmarkError("Caveman binary_sha does not match the reproducible exact-source build")
        }
    }

    private func runCaveman(
        engine: URL,
        input: String,
        database: URL,
        home: URL
    ) throws -> CavemanObservation {
        var environment = ProcessInfo.processInfo.environment
        environment["CAVEMAN_CCR_DB"] = database.path
        environment["CAVEMAN_HOME"] = home.path
        environment["DO_NOT_TRACK"] = "1"
        let compressed = try subprocess(
            executable: engine.path,
            arguments: ["compress", "--type", "text"],
            input: Data(input.utf8),
            environment: environment
        )
        guard let output = String(data: compressed.stdout, encoding: .utf8),
              let reportLine = String(data: compressed.stderr, encoding: .utf8)?
                .split(whereSeparator: \.isNewline)
                .last.map(String.init),
              let reportData = reportLine.data(using: .utf8),
              let report = try? JSONDecoder().decode(CavemanCompressReport.self, from: reportData),
              report.contentType == "text",
              report.error == nil || report.error?.isEmpty == true else {
            throw benchmarkError("Caveman did not emit a valid forced-text observation")
        }

        let recoveryHandle = nonempty(report.recoveryHandle)
        let changed = output != input
        if !changed {
            guard recoveryHandle == nil else {
                throw benchmarkError("Caveman pass-through unexpectedly minted a recovery handle")
            }
        } else {
            guard let handle = recoveryHandle else {
                throw benchmarkError("Caveman changed model-visible bytes without a recovery handle")
            }
            let recovered = try subprocess(
                executable: engine.path,
                arguments: ["retrieve", handle],
                input: Data(),
                environment: environment
            ).stdout
            guard recovered == Data(input.utf8) else {
                throw benchmarkError("Caveman recovery did not reproduce the exact Human input")
            }
        }
        return .init(output: output,
                     handleBehavior: changed ? .changedWithVerifiedHandle : .passThroughNoHandle)
    }

    private func exactTokenCounter(_ counts: [String: Int],
        sourceSHA256: String? = String(repeating: "c", count: 64)) -> BenchmarkTokenCounter {
        BenchmarkTokenCounter(diagnostic: exactTokenDiagnostic, sourceSHA256: sourceSHA256) { text in
            guard let count = counts[text] else { throw benchmarkError("missing unit token count") }
            return count
        }
    }
    private func responseMeasurements(_ cases: [ResponseEfficiencyCase]) throws -> [ResponseBenchmarkMeasurement] {
        try cases.map { try responseMeasurement($0) }
    }
    private func responseMeasurement(
        _ item: ResponseEfficiencyCase,
        cavemanOutput: String? = nil,
        handleBehavior: CavemanHandleBehavior = .passThroughNoHandle
    ) throws -> ResponseBenchmarkMeasurement {
        .init(id: item.id, human: item.humanBaseline, wire: try item.serializedWire(),
              caveman: .init(output: cavemanOutput ?? item.humanBaseline,
                             handleBehavior: handleBehavior))
    }
    private func responseCounter(cases: [ResponseEfficiencyCase],
                                 measurements: [ResponseBenchmarkMeasurement]) -> BenchmarkTokenCounter {
        var counts = [AgentSkillInstaller.rcWireAgentInstructionsTemplate: 10]
        for item in cases { counts[item.humanBaseline] = 100 }
        for measurement in measurements {
            counts[measurement.wire] = 60
            counts[measurement.caveman.output] = counts[measurement.caveman.output] ?? 100
        }
        return exactTokenCounter(counts)
    }
    private func responseReport(
        corpusData: Data,
        measurements: [ResponseBenchmarkMeasurement],
        counter: BenchmarkTokenCounter,
        head: String = String(repeating: "f", count: 40),
        runnerSourceSHA256: String? = nil,
        provenance: CavemanBenchmarkProvenance = benchmarkPinnedCavemanProvenance,
        nominalSourcePrompt: String? = nil
    ) throws -> ResponseBenchmarkReport {
        let sourcePrompt = try nominalSourcePrompt ?? nominalSourcePromptFromRequestCorpus()
        return try ResponseBenchmarkHarness.build(
            corpusData: corpusData, measurements: measurements,
            nominalSourcePrompt: sourcePrompt,
            remoteCodeHead: head, runnerSourceSHA256: runnerSourceSHA256 ?? responseRunnerSourceSHA256(),
            cavemanProvenance: provenance, counter: counter)
    }
    private func responseJSONData(_ report: ResponseBenchmarkReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(report)
    }
    private func responseReportOutputBundle(
        environment: [String: String]
    ) throws -> ResponseReportOutputBundle? {
        let json = nonempty(environment["REMOTE_CODE_RCW1_RESPONSE_REPORT_JSON"])
        let csv = nonempty(environment["REMOTE_CODE_RCW1_RESPONSE_REPORT_CSV"])
        guard json != nil || csv != nil else { return nil }
        guard let json, let csv else { throw benchmarkError("response report requires both JSON and CSV paths") }
        return try ResponseReportOutputBundle(jsonPath: json, csvPath: csv)
    }
    private func responseOutputBundle(
        at bundle: URL, csvName: String = "report.csv"
    ) throws -> ResponseReportOutputBundle {
        try ResponseReportOutputBundle(
            jsonPath: bundle.appendingPathComponent("report.json").path,
            csvPath: bundle.appendingPathComponent(csvName).path)
    }
    private func responseRunSnapshot(repository: URL,
                                     counter: BenchmarkTokenCounter) throws -> ResponseRunSnapshot {
        try counter.validateSourceSHA256()
        guard let counterSHA = counter.sourceSHA256, counterSHA.count == 64,
              counterSHA.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw benchmarkError("response report requires token counter source SHA-256")
        }
        let status = try subprocessText(executable: "/usr/bin/git", arguments: [
            "-C", repository.path, "status", "--porcelain=v1", "--untracked-files=all",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard status.isEmpty else { throw benchmarkError("response report requires a clean RemoteCode worktree") }
        let head = try subprocessText(executable: "/usr/bin/git",
            arguments: ["-C", repository.path, "rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(remoteCodeHead: head, runnerSourceSHA256: try responseRunnerSourceSHA256(),
                     counterSourceSHA256: counterSHA)
    }
    private func responseCase(id: String, outcome: String) -> ResponseEfficiencyCase {
        .init(id: id, category: "unit_control", language: "en",
              frames: [.init(sequence: 1, records: [.init(kind: .outcome, value: outcome)])],
              humanBaseline: outcome, semanticContract: nil)
    }
    private func responseNominalCase(
        basedOn item: ResponseEfficiencyCase,
        humanBaseline: String,
        semanticContract: ResponseSemanticContract
    ) -> ResponseEfficiencyCase {
        .init(
            id: nominalResponseCaseID, category: item.category, language: item.language,
            frames: [.init(sequence: 1, records: [.init(kind: .outcome, value: humanBaseline)])],
            humanBaseline: humanBaseline, semanticContract: semanticContract
        )
    }
    private func loadResponseCorpus() throws -> [ResponseEfficiencyCase] {
        try JSONDecoder().decode([ResponseEfficiencyCase].self, from: responseCorpusData()) }
    private func responseCorpusData() throws -> Data { try Data(contentsOf: responseCorpusURL()) }
    private func responseCorpusURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("rcw1-response-efficiency-corpus.json")
    }
    private func responseRunnerSourceSHA256() throws -> String {
        sha256Hex(try Data(contentsOf: URL(fileURLWithPath: #filePath))) }

    private func nominalSourcePromptFromRequestCorpus() throws -> String {
        guard let item = try loadCorpus().first(where: {
            $0.id == "reported-disposable-workspace"
        }) else {
            throw benchmarkError("request corpus is missing the nominal source prompt")
        }
        return item.human
    }

    private func loadCorpus() throws -> [EfficiencyCase] {
        let data = try Data(contentsOf: corpusURL())
        return try JSONDecoder().decode([EfficiencyCase].self, from: data)
    }

    private func corpusURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("rcw1-efficiency-corpus.json")
    }
}

private struct BenchmarkSubprocessResult {
    let stdout: Data
    let stderr: Data
}

private struct CavemanObservation {
    let output: String
    let handleBehavior: CavemanHandleBehavior
}

private struct ResponseRunSnapshot: Equatable {
    let remoteCodeHead: String
    let runnerSourceSHA256: String
    let counterSourceSHA256: String
}
private struct ResponseReportEmissionReceipt { let jsonPath, csvPath: String }
private final class ResponseReportOutputBundle {
    private struct Request { let ancestorPath, bundleName, fileName: String }
    private struct OpenedAncestor { let fd: Int32; let status: stat; let caseSensitive: Bool }
    private struct FileIdentity {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        init(_ status: stat) {
            device = status.st_dev; inode = status.st_ino; size = status.st_size
        }
        func matches(_ status: stat) -> Bool {
            device == status.st_dev && inode == status.st_ino && size == status.st_size
        }
    }
    private var ancestorFD: Int32
    private let device: dev_t; private let inode: ino_t
    private let bundleName, jsonName, csvName: String
    private var emissionAttempted = false
    init(jsonPath: String, csvPath: String) throws {
        let json = try Self.request(path: jsonPath)
        let csv = try Self.request(path: csvPath)
        let jsonAncestor = try Self.openAncestor(json.ancestorPath)
        do {
            let csvAncestor = try Self.openAncestor(csv.ancestorPath)
            defer { _ = Darwin.close(csvAncestor.fd) }
            guard jsonAncestor.status.st_dev == csvAncestor.status.st_dev,
                  jsonAncestor.status.st_ino == csvAncestor.status.st_ino else {
                throw benchmarkError("response JSON and CSV must share one directory bundle")
            }
            let sensitive = jsonAncestor.caseSensitive && csvAncestor.caseSensitive
            guard Self.sameName(json.bundleName, csv.bundleName, sensitive: sensitive),
                  !Self.sameName(json.fileName, csv.fileName, sensitive: sensitive) else {
                throw benchmarkError("response JSON and CSV require one bundle and distinct basenames")
            }
            var target = stat()
            let targetResult = Darwin.fstatat(
                jsonAncestor.fd, json.bundleName, &target, AT_SYMLINK_NOFOLLOW)
            guard targetResult == -1, errno == ENOENT else {
                throw benchmarkError("response report directory bundle must not exist")
            }
            ancestorFD = jsonAncestor.fd
            device = jsonAncestor.status.st_dev; inode = jsonAncestor.status.st_ino
            bundleName = json.bundleName; jsonName = json.fileName; csvName = csv.fileName
        } catch {
            _ = Darwin.close(jsonAncestor.fd)
            throw error
        }
    }
    deinit { _ = closeAncestor() }
    func emit(json jsonData: Data, csv csvText: String,
              afterCommit: () throws -> Void = {}) throws -> ResponseReportEmissionReceipt {
        guard !emissionAttempted else { throw benchmarkError("response report bundle emits only once") }
        emissionAttempted = true
        let stagingName = ".rcw1-response-\(UUID().uuidString.lowercased()).tmp"
        var committed = false
        var stagingFD: Int32 = -1, openFile: Int32 = -1
        var jsonIdentity: FileIdentity?, csvIdentity: FileIdentity?
        do {
            try validateAncestorAndAbsentTarget()
            guard Darwin.mkdirat(ancestorFD, stagingName, mode_t(S_IRWXU)) == 0 else {
                throw Self.posixError("mkdirat")
            }
            stagingFD = Darwin.openat(ancestorFD, stagingName,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard stagingFD >= 0 else { throw Self.posixError("staging openat") }
            for (name, payload) in [(jsonName, jsonData), (csvName, Data(csvText.utf8))] {
                openFile = Darwin.openat(stagingFD, name,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
                guard openFile >= 0 else { throw Self.posixError("file openat") }
                try Self.writeAll(payload, to: openFile)
                guard Darwin.fsync(openFile) == 0 else { throw Self.posixError("file fsync") }
                var fileStatus = stat()
                guard Darwin.fstat(openFile, &fileStatus) == 0 else {
                    throw Self.posixError("file fstat")
                }
                let identity = FileIdentity(fileStatus)
                if name == jsonName { jsonIdentity = identity } else { csvIdentity = identity }
                let closeResult = Darwin.close(openFile); openFile = -1
                guard closeResult == 0 else { throw Self.posixError("file close") }
            }
            guard Darwin.fsync(stagingFD) == 0 else { throw Self.posixError("staging fsync") }
            guard Darwin.renameatx_np(ancestorFD, stagingName, ancestorFD, bundleName,
                                      UInt32(RENAME_EXCL)) == 0 else {
                throw Self.posixError("bundle renameat")
            }
            committed = true
            try afterCommit()
            guard Darwin.fsync(ancestorFD) == 0 else { throw Self.posixError("ancestor fsync") }
            guard let jsonIdentity, let csvIdentity else {
                throw benchmarkError("response report file identity is unavailable")
            }
            try Self.validateFile(named: jsonName, identity: jsonIdentity, in: stagingFD)
            try Self.validateFile(named: csvName, identity: csvIdentity, in: stagingFD)
            let receipt = try emissionReceipt(bundleFD: stagingFD)
            let stagingClose = Darwin.close(stagingFD); stagingFD = -1
            guard stagingClose == 0 else { throw Self.posixError("bundle close") }
            guard closeAncestor() == 0 else { throw benchmarkError("response ancestor close failed") }
            return receipt
        } catch {
            var cleanupOK = openFile < 0 || Darwin.close(openFile) == 0
            if !committed, stagingFD >= 0 {
                cleanupOK = cleanupStaging(fd: stagingFD, named: stagingName) && cleanupOK
            }
            if stagingFD >= 0, Darwin.close(stagingFD) != 0 { cleanupOK = false }
            stagingFD = -1
            let closeOK = closeAncestor() == 0
            guard cleanupOK, closeOK else {
                throw benchmarkError(committed
                    ? "response report descriptor close failed after commit"
                    : "response report cleanup failed closed")
            }
            throw error
        }
    }
    private func validateAncestorAndAbsentTarget() throws {
        var status = stat()
        guard ancestorFD >= 0, Darwin.fstat(ancestorFD, &status) == 0,
              status.st_dev == device, status.st_ino == inode else {
            throw benchmarkError("response report ancestor descriptor drifted")
        }
        var target = stat()
        let result = Darwin.fstatat(ancestorFD, bundleName, &target, AT_SYMLINK_NOFOLLOW)
        guard result == -1, errno == ENOENT else {
            throw benchmarkError("response report directory bundle already exists")
        }
    }
    private func emissionReceipt(bundleFD: Int32) throws -> ResponseReportEmissionReceipt {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fcntl(bundleFD, F_GETPATH, &path) == 0 else {
            throw Self.posixError("bundle F_GETPATH")
        }
        let bundle = URL(fileURLWithPath: String(cString: path))
        return .init(jsonPath: bundle.appendingPathComponent(jsonName).path,
                     csvPath: bundle.appendingPathComponent(csvName).path)
    }
    private func cleanupStaging(fd: Int32, named name: String) -> Bool {
        var cleanupOK = true
        for fileName in [jsonName, csvName] where
            Darwin.unlinkat(fd, fileName, 0) != 0 && errno != ENOENT {
            cleanupOK = false
        }
        if Darwin.fsync(fd) != 0 { cleanupOK = false }
        var descriptorStatus = stat(), namedStatus = stat()
        guard Darwin.fstat(fd, &descriptorStatus) == 0,
              Darwin.fstatat(ancestorFD, name, &namedStatus, AT_SYMLINK_NOFOLLOW) == 0,
              descriptorStatus.st_dev == namedStatus.st_dev,
              descriptorStatus.st_ino == namedStatus.st_ino else {
            return false
        }
        if Darwin.unlinkat(ancestorFD, name, AT_REMOVEDIR) != 0 { cleanupOK = false }
        return cleanupOK && Darwin.fsync(ancestorFD) == 0
    }
    private func closeAncestor() -> Int32 {
        guard ancestorFD >= 0 else { return 0 }
        let result = Darwin.close(ancestorFD); ancestorFD = -1
        return result
    }
    private static func request(path: String) throws -> Request {
        guard !path.contains("\0") else { throw benchmarkError("response report output path contains NUL") }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let bundle = file.deletingLastPathComponent()
        let ancestor = bundle.deletingLastPathComponent()
        guard let resolved = realpath(ancestor.path, nil) else {
            throw benchmarkError("response report bundle ancestor cannot be resolved")
        }
        defer { free(resolved) }
        let bundleName = bundle.lastPathComponent.precomposedStringWithCanonicalMapping
        let fileName = file.lastPathComponent.precomposedStringWithCanonicalMapping
        guard !bundleName.isEmpty, !fileName.isEmpty, bundleName != ".", bundleName != "..",
              fileName != ".", fileName != ".." else {
            throw benchmarkError("response report bundle or basename is invalid")
        }
        return .init(ancestorPath: String(cString: resolved),
                     bundleName: bundleName, fileName: fileName)
    }
    private static func openAncestor(_ path: String) throws -> OpenedAncestor {
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw benchmarkError("response report ancestor cannot be opened") }
        var status = stat()
        let sensitivity = Darwin.fpathconf(descriptor, _PC_CASE_SENSITIVE)
        guard Darwin.fstat(descriptor, &status) == 0, sensitivity == 0 || sensitivity == 1 else {
            _ = Darwin.close(descriptor)
            throw benchmarkError("response report ancestor identity is unavailable")
        }
        return .init(fd: descriptor, status: status, caseSensitive: sensitivity == 1)
    }
    private static func sameName(_ lhs: String, _ rhs: String, sensitive: Bool) -> Bool {
        sensitive ? lhs == rhs : lhs.folding(options: [.caseInsensitive], locale: nil)
            == rhs.folding(options: [.caseInsensitive], locale: nil)
    }
    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw posixError("write") }
                offset += result
            }
        }
    }
    private static func validateFile(named name: String, identity: FileIdentity,
                                     in directoryFD: Int32) throws {
        var status = stat()
        guard Darwin.fstatat(directoryFD, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
              identity.matches(status) else {
            throw benchmarkError("response report file identity drifted")
        }
    }
    private static func posixError(_ operation: String) -> NSError {
        benchmarkError("response report \(operation) failed (errno \(errno))") }
}

private struct CavemanCompressReport: Decodable {
    let contentType: String
    let recoveryHandle: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case error
        case contentType = "content_type"
        case recoveryHandle = "recovery_handle"
    }
}

private func makeReal128BitRecoveryMarker() -> String {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    let token = Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "[[rc:rcv1.\(token)]]"
}

private func isReal128BitRecoveryMarker(_ marker: String) -> Bool {
    let prefix = "[[rc:rcv1."
    let suffix = "]]"
    guard marker.hasPrefix(prefix), marker.hasSuffix(suffix) else { return false }
    let start = marker.index(marker.startIndex, offsetBy: prefix.count)
    let end = marker.index(marker.endIndex, offsetBy: -suffix.count)
    let token = String(marker[start..<end])
    guard token.count == 22,
          token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
        return false
    }
    let base64 = token
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/") + "=="
    return Data(base64Encoded: base64)?.count == 16
}

private func subprocessText(
    executable: String,
    arguments: [String]
) throws -> String {
    let result = try subprocess(
        executable: executable,
        arguments: arguments,
        input: Data(),
        environment: ProcessInfo.processInfo.environment
    )
    guard let output = String(data: result.stdout, encoding: .utf8) else {
        throw benchmarkError("subprocess emitted non-UTF-8 stdout")
    }
    return output
}

private func subprocess(
    executable: String,
    arguments: [String],
    input: Data,
    environment: [String: String]
) throws -> BenchmarkSubprocessResult {
    let process = Process()
    let standardInput = Pipe()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    process.standardInput = standardInput
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()
    standardInput.fileHandleForWriting.write(input)
    try standardInput.fileHandleForWriting.close()
    process.waitUntilExit()
    let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let error = standardError.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        let detail = String(data: error, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw benchmarkError(
            "subprocess \((executable as NSString).lastPathComponent) failed "
                + "(\(process.terminationStatus)): \(detail)"
        )
    }
    return BenchmarkSubprocessResult(stdout: output, stderr: error)
}


private struct EfficiencyCase: Decodable {
    let id: String
    let human: String
    let requiredConcepts: [String]
    let requiredExact: [String]
    let ordered: [String]
    let forbidden: [String]
    let language: String
    let eligible: Bool
    let repeatCount: Int?

    var effectiveHuman: String {
        Array(repeating: human, count: max(1, repeatCount ?? 1)).joined(separator: " ")
    }

    enum CodingKeys: String, CodingKey {
        case id, human, ordered, forbidden, language, eligible
        case requiredConcepts = "required_concepts"
        case requiredExact = "required_exact"
        case repeatCount = "repeat_count"
    }
}

private let frozenResponseCorpusSHA256 = "4825e41375dc28d97188ca1218a3071eeef7802b1c7062d47b9c5909f9b7a43d"
private let nominalResponseCaseID = "reported-disposable-workspace-answer"
private let frozenNominalSourcePromptSHA256 =
    "2a31b16c2e1fa1a342a92f1ee2d86e713b16338daff9c4d8e9a29cfb25b0056a"
private let frozenResponseSemanticContractSHA256 =
    "c4d60c41dba9e4c6d187b6f129ca2911bcb2b5d2ccb79e8136b798da0075687a"
private let frozenRequestCorpusSHA256 =
    "7b568f18e7e49df46a486af49dba6747fe5e2a9cde850471190ccfbd761ba625"
private let allRowExpectedSourceCommit = "986ad85e247921e1165f07e7830b0fad328d3ad5"
private let allRowUnitTestCounterSourceSHA256 = String(repeating: "a", count: 64)
private let allRowUnitTestMeasurementArtifactSHA256 = String(repeating: "b", count: 64)
private let allRowUnitTestRunnerSourceSHA256 = String(repeating: "d", count: 64)

private func allRowUnitTestPublicationContext() -> AllRowPublicationContext {
    AllRowPublicationContext(
        remoteCodeHead: allRowExpectedSourceCommit,
        workspaceClean: true,
        runnerSourceSHA256: allRowUnitTestRunnerSourceSHA256
    )
}

private func allRowRequireContentFreeSHA256(_ value: String, label: String) throws -> String {
    guard value.count == 64, value.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
        throw benchmarkError("all-row \(label) must be a lowercase SHA-256")
    }
    return value
}

private func allRowContentFreeSHA256(of url: URL, label: String) throws -> String {
    try allRowRequireContentFreeSHA256(sha256Hex(try Data(contentsOf: url)), label: label)
}
private let frozenRequestCorpusIDs = [
    "reported-disposable-workspace", "portuguese-redundant-summary", "path-line-no-edit",
    "url-markdown-exact", "command-no-tools", "numeric-thresholds", "uuid-sha-exact",
    "quoted-error-exit", "ordered-first-then", "production-delete-approval",
    "double-negation", "only-except-unless", "code-fence-byte-exact", "json-schema-quotes",
    "japanese-path", "arabic-number", "escapes-byte-exact", "multiframe-long-repetition",
    "cleanup-repetition", "multiple-paths-versions", "follow-up-context",
    "contradictory-fail-open", "opaque-exact-fail-open", "short-fail-open",
]
private let frozenResponseCorpusIDs = [
    "short-ok", "reported-disposable-workspace-answer", "multi-record-all-kinds",
    "progressive-multiframe", "exact-code-path", "portuguese-natural", "japanese-natural",
    "arabic-natural", "repeated-evidence-template", "opaque-incompressible",
]

private func allRowFixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent(name)
}

private func allRowRequestCorpusURL() -> URL {
    allRowFixtureURL("rcw1-efficiency-corpus.json")
}

private func allRowResponseCorpusURL() -> URL {
    allRowFixtureURL("rcw1-response-efficiency-corpus.json")
}

private func allRowRepositoryURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func allRowFailOpenReasonsField(_ reasons: [String: Int]) -> String {
    reasons.keys.sorted().compactMap { key in
        reasons[key].map { "\(key)=\($0)" }
    }.joined(separator: "|")
}

private func allRowNominalSourcePrompt() throws -> String {
    let corpus = try JSONDecoder().decode(
        [EfficiencyCase].self,
        from: Data(contentsOf: allRowRequestCorpusURL())
    )
    guard let item = corpus.first(where: { $0.id == "reported-disposable-workspace" }) else {
        throw benchmarkError("request corpus is missing the nominal source prompt")
    }
    return item.human
}
private let exactTokenDiagnostic = TokenCounterDiagnostic(
    name: "response-unit", version: "1", encoding: "fixture-exact",
    measurementKind: "exact-local-tokenizer")

private struct ResponseEfficiencyCase: Decodable {
    let id, category, language: String
    let frames: [ResponseLogicalFrame]
    let humanBaseline: String
    let semanticContract: ResponseSemanticContract?
    func rcWireFrames() throws -> [RCWireFrame] {
        let result = frames.map { frame in
            RCWireFrame(direction: .response, sequence: frame.sequence,
                records: frame.records.map { .init(kind: $0.kind, value: $0.value) })
        }
        guard !result.isEmpty,
              result.flatMap(\.records).allSatisfy({ $0.kind != .exact }) else {
            throw benchmarkError("\(id) response fixture must contain non-X logical records")
        }
        _ = try result.map(RCWireProtocol.serialize)
        return result
    }
    func serializedWire() throws -> String { try rcWireFrames().map(RCWireProtocol.serialize).joined() }
    enum CodingKeys: String, CodingKey { case id, category, language, frames
        case humanBaseline = "human_baseline"; case semanticContract = "semantic_contract" }
}
private struct ResponseLogicalFrame: Decodable {
    let sequence: Int; let records: [ResponseLogicalRecord] }
private struct ResponseLogicalRecord: Decodable {
    let kind: RCWireRecordKind; let value: String }
private enum ResponseSemanticRequirementID: String, Codable, CaseIterable, Equatable {
    case r1 = "R1", r2 = "R2", r3 = "R3", r4 = "R4"
    case r5 = "R5", r6 = "R6", r7 = "R7", r8 = "R8"
}
private struct ResponseSemanticRequirement: Decodable, Equatable {
    let id: ResponseSemanticRequirementID
    let kind, evidenceSpan: String
    enum CodingKeys: String, CodingKey { case id, kind; case evidenceSpan = "evidence_span" }
}
private struct ResponseSemanticContract: Decodable, Equatable {
    let sourcePromptSHA256, language, shape, scope: String
    let productionAdmission: Bool
    let requirements: [ResponseSemanticRequirement]

    enum CodingKeys: String, CodingKey {
        case language, shape, scope, requirements
        case sourcePromptSHA256 = "source_prompt_sha256"
        case productionAdmission = "production_admission"
    }

    var canonicalData: Data {
        var lines = [
            "scope=\(scope)",
            "production_admission=\(productionAdmission)",
            "source_prompt_sha256=\(sourcePromptSHA256)",
            "language=\(language)",
            "shape=\(shape)",
        ]
        lines += requirements.map { "\($0.id.rawValue)|\($0.kind)|\($0.evidenceSpan)" }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
private enum ResponseSemanticReceiptStatus: String, Encodable, Equatable {
    case passed, notApplicable = "not_applicable"
}
private struct ResponseSemanticReceipt {
    let status: ResponseSemanticReceiptStatus
    let requirementIDs: [ResponseSemanticRequirementID]
}
private struct ResponseBenchmarkMeasurement {
    let id, human, wire: String; let caveman: CavemanObservation }
private enum ResponseQualificationFailure: String, Encodable, CaseIterable, Equatable {
    case aboveMaximumTokenRatio = "above_maximum_token_ratio"
    case effectiveNotSmallerThanHuman = "effective_not_smaller_than_human"
    case effectiveNotSmallerThanCaveman = "effective_not_smaller_than_caveman"
}
private enum ResponseBenchmarkDecision: String, Encodable, Equatable {
    case rcw1, humanFailOpen = "human_fail_open" }
private enum CavemanHandleBehavior: Equatable {
    case passThroughNoHandle, changedWithVerifiedHandle }
private enum ResponseBenchmarkHarness {
    static func build(corpusData: Data, measurements: [ResponseBenchmarkMeasurement],
        nominalSourcePrompt: String,
        remoteCodeHead: String, runnerSourceSHA256: String,
        cavemanProvenance: CavemanBenchmarkProvenance,
        counter: BenchmarkTokenCounter) throws -> ResponseBenchmarkReport {
        let corpusSHA256 = sha256Hex(corpusData)
        guard corpusSHA256 == frozenResponseCorpusSHA256 else {
            throw benchmarkError("report requires the frozen response corpus bytes")
        }
        let sourcePromptSHA256 = sha256Hex(Data(nominalSourcePrompt.utf8))
        guard sourcePromptSHA256 == frozenNominalSourcePromptSHA256 else {
            throw benchmarkError("report requires the frozen nominal source prompt SHA-256")
        }
        let corpus = try JSONDecoder().decode([ResponseEfficiencyCase].self, from: corpusData)
        guard corpus.map(\.id) == frozenResponseCorpusIDs else {
            throw benchmarkError("report requires the frozen response corpus ID order")
        }
        guard remoteCodeHead.count == 40,
              remoteCodeHead.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              runnerSourceSHA256.count == 64,
              runnerSourceSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw benchmarkError("report requires RemoteCode HEAD and runner source SHA-256")
        }
        guard cavemanProvenance == benchmarkPinnedCavemanProvenance else {
            throw benchmarkError("Caveman provenance must match the pinned exact-source build")
        }
        try counter.validateSourceSHA256()
        let evaluated = try evaluateRowsForUnitTest(corpus: corpus,
            measurements: measurements, counter: counter)
        try counter.validateSourceSHA256()
        guard let counterSourceSHA256 = counter.sourceSHA256 else {
            throw benchmarkError("response report requires token counter source SHA-256")
        }
        guard let semanticContractSHA256 = evaluated.semanticContractSHA256 else {
            throw benchmarkError("response report requires the frozen nominal semantic contract")
        }
        return .init(
            schemaVersion: 5, codec: "rcw1-v1", corpusSHA256: corpusSHA256,
            semanticContractSHA256: semanticContractSHA256,
            semanticContractSourcePromptSHA256: sourcePromptSHA256,
            remoteCodeHead: remoteCodeHead, runnerSourceSHA256: runnerSourceSHA256,
            counterSourceSHA256: counterSourceSHA256,
            tokenCounter: counter.diagnostic, methodology: .init(),
            cavemanProvenance: cavemanProvenance, rows: evaluated.rows, totals: evaluated.totals)
    }
    fileprivate static func validateAllRowResponseContracts(
        corpus: [ResponseEfficiencyCase],
        corpusData: Data,
        measurements: [ResponseBenchmarkMeasurement],
        sourcePrompt: String
    ) throws {
        guard sha256Hex(corpusData) == frozenResponseCorpusSHA256 else {
            throw benchmarkError("all-row response report requires the frozen response corpus bytes")
        }
        guard sha256Hex(Data(sourcePrompt.utf8)) == frozenNominalSourcePromptSHA256 else {
            throw benchmarkError("all-row response report requires the frozen nominal source prompt SHA-256")
        }
        let decoded = try JSONDecoder().decode([ResponseEfficiencyCase].self, from: corpusData)
        guard decoded.map(\.id) == frozenResponseCorpusIDs,
              corpus.map(\.id) == frozenResponseCorpusIDs else {
            throw benchmarkError("all-row response report requires the frozen response corpus ID order")
        }
        _ = try validateSemanticContracts(corpus)
        let measuredIDs = measurements.map(\.id)
        guard Set(measuredIDs).count == measuredIDs.count else {
            throw benchmarkError("duplicate response row")
        }
        guard measuredIDs == frozenResponseCorpusIDs else {
            throw benchmarkError("measured run must preserve the frozen response corpus ID order")
        }
        let byID = Dictionary(uniqueKeysWithValues: measurements.map { ($0.id, $0) })
        for item in corpus {
            guard let measured = byID[item.id] else {
                throw benchmarkError("measurements must include all response corpus rows exactly once")
            }
            guard measured.human == item.humanBaseline else {
                throw benchmarkError("\(item.id) Human is not byte-exact")
            }
            guard !measured.caveman.output.isEmpty else {
                throw benchmarkError("\(item.id) is missing measured Caveman output")
            }
            guard let projection = RCWireProtocol.strictResponseProjection(raw: measured.wire),
                  projection.rawWire == measured.wire,
                  projection.deterministicHuman == item.humanBaseline else {
                throw benchmarkError("\(item.id) response round-trip is not byte-exact")
            }
        }
    }

    static func evaluateRowsForUnitTest(corpus: [ResponseEfficiencyCase],
        measurements: [ResponseBenchmarkMeasurement], counter: BenchmarkTokenCounter
    ) throws -> (rows: [ResponseBenchmarkRow], totals: ResponseBenchmarkTotals,
                 semanticContractSHA256: String?) {
        guard counter.diagnostic.measurementKind == "exact-local-tokenizer" else {
            throw benchmarkError("response report requires measurement_kind=exact-local-tokenizer")
        }
        guard let sourceSHA256 = counter.sourceSHA256, sourceSHA256.count == 64,
              sourceSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw benchmarkError("response report requires token counter source SHA-256")
        }
        let corpusIDs = corpus.map(\.id)
        let measuredIDs = measurements.map(\.id)
        guard Set(corpusIDs).count == corpusIDs.count else {
            throw benchmarkError("response corpus contains duplicate IDs")
        }
        guard Set(measuredIDs).count == measuredIDs.count else {
            throw benchmarkError("duplicate response row")
        }
        guard Set(measuredIDs) == Set(corpusIDs) else {
            throw benchmarkError("measurements must include all response corpus rows exactly once")
        }
        let semantic = try validateSemanticContracts(corpus)
        var counts: [String: Int] = [:]
        func stableCount(_ text: String) throws -> Int {
            if let count = counts[text] { return count }
            let first = try counter.count(text)
            let second = try counter.count(text)
            guard first == second else { throw benchmarkError("unstable token count") }
            counts[text] = first
            return first
        }
        let abiTokens = try stableCount(AgentSkillInstaller.rcWireAgentInstructionsTemplate)
        guard abiTokens > 0 else { throw benchmarkError("response ABI token count must be positive") }
        let byID = Dictionary(uniqueKeysWithValues: measurements.map { ($0.id, $0) })
        let rows = try corpus.map { try evaluate(item: $0, measurement: byID[$0.id]!,
                                                 semanticReceipt: semantic.receipts[$0.id]!,
                                                 abiTokens: abiTokens, count: stableCount) }
        return (rows, ResponseBenchmarkTotals(rows: rows), semantic.contractSHA256)
    }
    private static func evaluate(item: ResponseEfficiencyCase,
        measurement: ResponseBenchmarkMeasurement, semanticReceipt: ResponseSemanticReceipt,
        abiTokens: Int,
        count: (String) throws -> Int) throws -> ResponseBenchmarkRow {
        let frames = try item.rcWireFrames()
        guard RCWireProtocol.renderEnglish(frames) == item.humanBaseline else {
            throw benchmarkError("\(item.id) Human render mismatch")
        }
        guard measurement.human == item.humanBaseline else {
            throw benchmarkError("\(item.id) Human is not byte-exact")
        }
        guard let projection = RCWireProtocol.strictResponseProjection(raw: measurement.wire) else {
            throw benchmarkError("\(item.id) response must begin with byte-zero RCW1 A")
        }
        guard measurement.wire == (try frames.map(RCWireProtocol.serialize).joined()),
              projection.rawWire == measurement.wire,
              projection.deterministicHuman == item.humanBaseline else {
            throw benchmarkError("\(item.id) response round-trip is not byte-exact")
        }
        let changed = measurement.caveman.output != measurement.human
        guard !measurement.caveman.output.isEmpty,
              measurement.caveman.handleBehavior
                == (changed ? .changedWithVerifiedHandle : .passThroughNoHandle) else {
            throw benchmarkError("\(item.id) Caveman handle behavior is inconsistent")
        }
        let human = try count(measurement.human)
        let frame = try count(measurement.wire)
        let caveman = try count(measurement.caveman.output)
        guard human > 0, caveman > 0 else {
            throw benchmarkError("\(item.id) invalid token count")
        }
        guard frame > 0 else { throw benchmarkError("\(item.id) frame token count must be positive") }
        let (effective, addOverflow) = frame.addingReportingOverflow(abiTokens)
        let (wire100, wireOverflow) = frame.multipliedReportingOverflow(by: 100)
        let (human45, humanOverflow) = human.multipliedReportingOverflow(by: 45)
        guard !addOverflow, !wireOverflow, !humanOverflow else {
            throw benchmarkError("\(item.id) response token arithmetic overflow")
        }
        var reasons: [ResponseQualificationFailure] = []
        if wire100 > human45 { reasons.append(.aboveMaximumTokenRatio) }
        if effective >= human { reasons.append(.effectiveNotSmallerThanHuman) }
        if effective >= caveman { reasons.append(.effectiveNotSmallerThanCaveman) }
        let decision: ResponseBenchmarkDecision = reasons.isEmpty ? .rcw1 : .humanFailOpen
        return .init(
            id: item.id,
            humanSHA256: sha256Hex(Data(measurement.human.utf8)),
            candidateFrameSHA256: sha256Hex(Data(measurement.wire.utf8)),
            cavemanSHA256: sha256Hex(Data(measurement.caveman.output.utf8)),
            decision: decision, semanticReceiptStatus: semanticReceipt.status,
            semanticReceiptIds: semanticReceipt.requirementIDs,
            humanTokens: human, candidateFrameTokens: frame,
            candidateVsHumanPPM: ratioPPM(frame, human), abiTokens: abiTokens,
            candidateEffectiveTokens: effective,
            effectiveDeliveredTokens: decision == .rcw1 ? effective : human, cavemanTokens: caveman,
            cavemanRecoveryHandlePresent: measurement.caveman.handleBehavior == .changedWithVerifiedHandle,
            disqualificationReasons: reasons,
            claimedSavedTokensVsHuman: decision == .rcw1 ? human - effective : 0,
            claimedSavedTokensVsCaveman: decision == .rcw1 ? caveman - effective : 0)
    }

    private static func validateSemanticContracts(
        _ corpus: [ResponseEfficiencyCase]
    ) throws -> (receipts: [String: ResponseSemanticReceipt], contractSHA256: String?) {
        var receipts: [String: ResponseSemanticReceipt] = [:]
        var contractSHA256: String?
        for item in corpus {
            guard item.id == nominalResponseCaseID else {
                guard item.semanticContract == nil else {
                    throw benchmarkError("\(item.id) semantic contract is reserved for the nominal row")
                }
                receipts[item.id] = .init(status: .notApplicable, requirementIDs: [])
                continue
            }
            guard let contract = item.semanticContract else {
                throw benchmarkError("\(item.id) semantic contract is required before economic counting")
            }
            let receipt = try validate(contract: contract, for: item)
            receipts[item.id] = receipt
            contractSHA256 = sha256Hex(contract.canonicalData)
        }
        return (receipts, contractSHA256)
    }

    private static func validate(
        contract: ResponseSemanticContract,
        for item: ResponseEfficiencyCase
    ) throws -> ResponseSemanticReceipt {
        guard contract.scope == "test_only_human_reviewed_exact_spans",
              !contract.productionAdmission else {
            throw benchmarkError("\(item.id) semantic contract must remain test-only, not production admission")
        }
        guard contract.sourcePromptSHA256 == frozenNominalSourcePromptSHA256 else {
            throw benchmarkError("\(item.id) semantic contract source SHA-256 drifted")
        }
        guard contract.language == "en", item.language == contract.language,
              contract.shape == "one_concise_human_readable_sentence" else {
            throw benchmarkError("\(item.id) semantic contract requires one English human-readable sentence")
        }
        let ids = contract.requirements.map(\.id)
        guard ids == ResponseSemanticRequirementID.allCases else {
            throw benchmarkError("\(item.id) semantic contract must contain typed IDs R1-R8 in order")
        }
        let expectedKinds = [
            "subject_relation_object", "subject_relation_object",
            "subject_relation_object", "subject_relation_object",
            "aggregate_outcome", "design_property", "enabled_action", "negative_boundary",
        ]
        guard contract.requirements.map(\.kind) == expectedKinds,
              Set(contract.requirements.map(\.evidenceSpan)).count == contract.requirements.count else {
            throw benchmarkError("\(item.id) semantic contract evidence types or spans drifted")
        }
        let terminators = item.humanBaseline.filter { ".!?".contains($0) }
        let words = item.humanBaseline.split(whereSeparator: \.isWhitespace)
        guard item.humanBaseline.last == ".", terminators.count == 1,
              !item.humanBaseline.contains(where: \.isNewline), words.count <= 60 else {
            throw benchmarkError("\(item.id) semantic contract sentence shape failed")
        }
        var lowerBound = item.humanBaseline.startIndex
        for requirement in contract.requirements {
            let occurrences = item.humanBaseline.components(
                separatedBy: requirement.evidenceSpan
            ).count - 1
            let range = item.humanBaseline.range(
                of: requirement.evidenceSpan,
                range: lowerBound..<item.humanBaseline.endIndex
            )
            guard occurrences == 1, let range,
                  range.lowerBound >= lowerBound else {
                throw benchmarkError(
                    "\(item.id) semantic contract missing exact evidence span \(requirement.id.rawValue)"
                )
            }
            lowerBound = range.upperBound
        }
        let digest = sha256Hex(contract.canonicalData)
        guard digest == frozenResponseSemanticContractSHA256 else {
            throw benchmarkError("\(item.id) frozen semantic contract receipt drifted")
        }
        return .init(status: .passed, requirementIDs: ids)
    }
}

private struct ResponseBenchmarkReport: Encodable {
    let schemaVersion: Int
    let codec, corpusSHA256, semanticContractSHA256, semanticContractSourcePromptSHA256: String
    let remoteCodeHead: String
    let runnerSourceSHA256, counterSourceSHA256: String
    let tokenCounter: TokenCounterDiagnostic; let methodology: ResponseBenchmarkMethodology
    let cavemanProvenance: CavemanBenchmarkProvenance
    let rows: [ResponseBenchmarkRow]; let totals: ResponseBenchmarkTotals
    var csv: String {
        let header = [
            "record_type", "id", "semantic_contract_sha256",
            "semantic_contract_source_prompt_sha256", "decision",
            "semantic_receipt_status", "semantic_receipt_ids",
            "human_sha256", "candidate_frame_sha256", "caveman_sha256",
            "human_tokens", "candidate_frame_tokens", "candidate_vs_human_ppm", "abi_tokens",
            "candidate_effective_tokens", "effective_delivered_tokens", "caveman_tokens",
            "claimed_saved_tokens_vs_human", "claimed_saved_tokens_vs_caveman",
            "caveman_recovery_handle_present", "disqualification_reasons", "row_count",
            "qualified_rows", "disqualified_rows", "failure_counts",
        ]
        let body = rows.map { row in
            [
                "row", row.id, semanticContractSHA256, semanticContractSourcePromptSHA256,
                row.decision.rawValue,
                row.semanticReceiptStatus.rawValue,
                row.semanticReceiptIds.map(\.rawValue).joined(separator: "|"),
                row.humanSHA256, row.candidateFrameSHA256,
                row.cavemanSHA256, String(row.humanTokens), String(row.candidateFrameTokens),
                String(row.candidateVsHumanPPM), String(row.abiTokens),
                String(row.candidateEffectiveTokens), String(row.effectiveDeliveredTokens),
                String(row.cavemanTokens), String(row.claimedSavedTokensVsHuman),
                String(row.claimedSavedTokensVsCaveman), String(row.cavemanRecoveryHandlePresent),
                row.disqualificationReasons.map(\.rawValue).joined(separator: "|"), "", "", "", "",
            ]
        }
        let failures = totals.failureCounts.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "|")
        let total = [
            "totals", "", semanticContractSHA256, semanticContractSourcePromptSHA256,
            "", "", "", "", "", "",
            String(totals.humanTokens), String(totals.candidateFrameTokens),
            "", String(totals.abiTokens),
            String(totals.candidateEffectiveTokens), String(totals.effectiveDeliveredTokens),
            String(totals.cavemanTokens), String(totals.claimedSavedTokensVsHuman),
            String(totals.claimedSavedTokensVsCaveman), "", "", String(totals.rows),
            String(totals.qualifiedRows), String(totals.disqualifiedRows), failures,
        ]
        return ([header] + body + [total]).map { $0.map(csvField).joined(separator: ",") }
            .joined(separator: "\n") + "\n"
    }
}

private struct ResponseBenchmarkMethodology: Encodable {
    let providerReportedTokens = false, providerBound = false, abiCountedOncePerRow = true
    let semanticContractScope = "test_only_human_reviewed_exact_spans"
    let semanticContractIsProductionAdmission = false, semanticContractUsesGenericNLP = false
    let qualificationRule = "complete frame <=45% Human; frame + one ABI < Human and pinned Caveman"
}
private struct ResponseBenchmarkRow: Encodable {
    let id, humanSHA256, candidateFrameSHA256, cavemanSHA256: String
    let decision: ResponseBenchmarkDecision
    let semanticReceiptStatus: ResponseSemanticReceiptStatus
    let semanticReceiptIds: [ResponseSemanticRequirementID]
    let humanTokens, candidateFrameTokens: Int
    let candidateVsHumanPPM, abiTokens, candidateEffectiveTokens: Int
    let effectiveDeliveredTokens, cavemanTokens: Int
    let cavemanRecoveryHandlePresent: Bool
    let disqualificationReasons: [ResponseQualificationFailure]
    let claimedSavedTokensVsHuman, claimedSavedTokensVsCaveman: Int
}
private struct ResponseBenchmarkTotals: Encodable {
    let rows, qualifiedRows, disqualifiedRows, humanTokens: Int
    let candidateFrameTokens, abiTokens, candidateEffectiveTokens: Int
    let effectiveDeliveredTokens, cavemanTokens: Int
    let claimedSavedTokensVsHuman, claimedSavedTokensVsCaveman: Int
    let failureCounts: [String: Int]
    init(rows source: [ResponseBenchmarkRow]) {
        rows = source.count
        qualifiedRows = source.filter { $0.decision == .rcw1 }.count
        disqualifiedRows = rows - qualifiedRows
        humanTokens = source.reduce(0) { $0 + $1.humanTokens }
        candidateFrameTokens = source.reduce(0) { $0 + $1.candidateFrameTokens }
        abiTokens = source.reduce(0) { $0 + $1.abiTokens }
        candidateEffectiveTokens = source.reduce(0) { $0 + $1.candidateEffectiveTokens }
        effectiveDeliveredTokens = source.reduce(0) { $0 + $1.effectiveDeliveredTokens }
        cavemanTokens = source.reduce(0) { $0 + $1.cavemanTokens }
        claimedSavedTokensVsHuman = source.reduce(0) { $0 + $1.claimedSavedTokensVsHuman }
        claimedSavedTokensVsCaveman = source.reduce(0) { $0 + $1.claimedSavedTokensVsCaveman }
        failureCounts = Dictionary(uniqueKeysWithValues: ResponseQualificationFailure.allCases.map { reason in
            (reason.rawValue, source.filter { $0.disqualificationReasons.contains(reason) }.count)
        })
    }
}

private let benchmarkPinnedCavemanProvenance = CavemanBenchmarkProvenance(
    sourceCommit: "27d5a3981a347890211bb1bf2439e5c821a63bc9",
    goVersion: "go version go1.26.5 darwin/arm64",
    buildCommand: "CGO_ENABLED=0 GOENV=off GOOS=darwin GOARCH=arm64 GOTOOLCHAIN=local GOWORK=off GOFLAGS='' go -C <SOURCE> build -mod=readonly -trimpath -o <OUTPUT> ./engine/cmd/caveman-engine",
    binarySHA: "d37718e84d5233a0c841f7d75fded0219cfdaee3af9a533198ebaf60db1bf9a3"
)

private struct CavemanBenchmarkProvenance: Encodable, Equatable {
    let sourceCommit: String
    let goVersion: String
    let buildCommand: String
    let binarySHA: String

    func replacing(
        sourceCommit: String? = nil,
        goVersion: String? = nil,
        buildCommand: String? = nil,
        binarySHA: String? = nil
    ) -> Self {
        Self(
            sourceCommit: sourceCommit ?? self.sourceCommit,
            goVersion: goVersion ?? self.goVersion,
            buildCommand: buildCommand ?? self.buildCommand,
            binarySHA: binarySHA ?? self.binarySHA
        )
    }

    enum CodingKeys: String, CodingKey {
        case sourceCommit = "source_commit"
        case goVersion = "go_version"
        case buildCommand = "build_command"
        case binarySHA = "binary_sha"
    }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct MeasuredBenchmarkRun: Codable {
    let schemaVersion: Int
    let runID: String
    let capturedAt: String
    let source: String
    let encoder: String
    let encoderRevision: String
    let provider: String?
    let providerModel: String?
    let cavemanSourceCommit: String
    let cavemanGoVersion: String
    let cavemanBuildCommand: String
    let cavemanBinarySHA: String
    let rows: [MeasuredBenchmarkRow]

    enum CodingKeys: String, CodingKey {
        case source, encoder, provider, rows
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case capturedAt = "captured_at"
        case encoderRevision = "encoder_revision"
        case providerModel = "provider_model"
        case cavemanSourceCommit = "source_commit"
        case cavemanGoVersion = "go_version"
        case cavemanBuildCommand = "build_command"
        case cavemanBinarySHA = "binary_sha"
    }
}

private struct MeasuredBenchmarkRow: Codable {
    let id: String
    let decision: BenchmarkProductionDecision
    let deliveredPayload: String
    let recoveryHandle: String?
    let failOpenReason: BenchmarkFailOpenReason?
    let cavemanOutput: String
    let observedRouteStage: String?
    let observedEncoderOutput: String?

    init(
        id: String,
        decision: BenchmarkProductionDecision,
        deliveredPayload: String,
        recoveryHandle: String?,
        failOpenReason: BenchmarkFailOpenReason?,
        cavemanOutput: String,
        observedRouteStage: String? = nil,
        observedEncoderOutput: String? = nil
    ) {
        self.id = id
        self.decision = decision
        self.deliveredPayload = deliveredPayload
        self.recoveryHandle = recoveryHandle
        self.failOpenReason = failOpenReason
        self.cavemanOutput = cavemanOutput
        self.observedRouteStage = observedRouteStage
        self.observedEncoderOutput = observedEncoderOutput
    }

    enum CodingKeys: String, CodingKey {
        case id, decision
        case deliveredPayload = "delivered_payload"
        case recoveryHandle = "recovery_handle"
        case failOpenReason = "fail_open_reason"
        case cavemanOutput = "caveman_output"
        case observedRouteStage = "observed_route_stage"
        case observedEncoderOutput = "observed_encoder_output"
    }
}

private enum BenchmarkProductionDecision: String, Codable, Equatable {
    case rcw1
    case humanFailOpen = "human_fail_open"
}

private enum BenchmarkFailOpenReason: String, Codable, CaseIterable, Equatable {
    case belowFloor = "below_floor"
    case semanticGate = "semantic_gate"
    case literalGate = "literal_gate"
    case profitabilityGate = "profitability_gate"
    case sidecarUnavailable = "sidecar_unavailable"
}

private struct BenchmarkTokenCounter {
    let diagnostic: TokenCounterDiagnostic
    let sourceSHA256: String?
    private let sourceExecutableURL: URL?
    private let countImplementation: (String) throws -> Int

    init(environment: [String: String]) throws {
        guard let executable = environment["REMOTE_CODE_RCW1_BENCHMARK_TOKEN_COUNTER"],
              !executable.isEmpty else {
            diagnostic = TokenCounterDiagnostic(
                name: "RemoteCode.TokenEstimator",
                version: "1",
                encoding: "utf8-char-word-heuristic",
                measurementKind: "estimated"
            )
            sourceSHA256 = nil
            sourceExecutableURL = nil
            countImplementation = { TokenEstimator.estimate($0) }
            return
        }

        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw benchmarkError("token counter must be an executable absolute path: \(executable)")
        }
        let executableURL = URL(fileURLWithPath: executable).standardizedFileURL
        sourceSHA256 = sha256Hex(try Data(contentsOf: executableURL))
        sourceExecutableURL = executableURL
        let childEnvironment = Self.childEnvironment(from: environment)
        let diagnosticData = try Self.invoke(
            executable: executable,
            argument: "--diagnostic",
            input: Data(),
            environment: childEnvironment
        )
        let decodedDiagnostic = try JSONDecoder().decode(TokenCounterDiagnostic.self, from: diagnosticData)
        guard [
            decodedDiagnostic.name, decodedDiagnostic.version,
            decodedDiagnostic.encoding, decodedDiagnostic.measurementKind,
        ].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw benchmarkError("token counter diagnostic fields must be non-empty")
        }
        diagnostic = decodedDiagnostic
        countImplementation = { text in
            let output = try Self.invoke(
                executable: executable,
                argument: "--count",
                input: Data(text.utf8),
                environment: childEnvironment
            )
            guard let raw = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let value = Int(raw),
                  value >= 0 else {
                throw benchmarkError("token counter must print only one non-negative integer")
            }
            return value
        }
        try validateSourceSHA256()
    }

    init(
        diagnostic: TokenCounterDiagnostic,
        sourceSHA256: String? = nil,
        count: @escaping (String) throws -> Int
    ) {
        self.diagnostic = diagnostic
        self.sourceSHA256 = sourceSHA256
        sourceExecutableURL = nil
        countImplementation = count
    }

    func count(_ text: String) throws -> Int {
        try countImplementation(text)
    }

    func validateSourceSHA256() throws {
        guard let sourceExecutableURL, let sourceSHA256 else { return }
        guard sha256Hex(try Data(contentsOf: sourceExecutableURL)) == sourceSHA256 else {
            throw benchmarkError("token counter executable source SHA-256 drifted")
        }
    }

    private static func childEnvironment(from environment: [String: String]) -> [String: String] {
        var child = ProcessInfo.processInfo.environment
        if let encoding = environment["RCW1_TIKTOKEN_ENCODING"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !encoding.isEmpty {
            child["RCW1_TIKTOKEN_ENCODING"] = encoding
        }
        let pythonPath = environment["PYTHONPATH"] ?? ProcessInfo.processInfo.environment["PYTHONPATH"]
        if let pythonPath, !pythonPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            child["PYTHONPATH"] = pythonPath
        }
        return child
    }

    private static func invoke(
        executable: String,
        argument: String,
        input: Data,
        environment: [String: String]
    ) throws -> Data {
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [argument]
        process.environment = environment
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        standardInput.fileHandleForWriting.write(input)
        try standardInput.fileHandleForWriting.close()
        process.waitUntilExit()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = String(data: error, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw benchmarkError("token counter failed (\(process.terminationStatus)): \(detail)")
        }
        return output
    }
}

private struct TokenCounterDiagnostic: Codable {
    let name: String
    let version: String
    let encoding: String
    let measurementKind: String

    enum CodingKeys: String, CodingKey {
        case name, version, encoding
        case measurementKind = "measurement_kind"
    }
}

private enum MeasuredBenchmarkHarness {
    fileprivate static func validateAllRowRequestIntegrity(
        corpus: [EfficiencyCase],
        corpusData: Data,
        measurements: MeasuredBenchmarkRun
    ) throws {
        try validateRunMetadata(measurements)
        guard sha256Hex(corpusData) == frozenRequestCorpusSHA256 else {
            throw benchmarkError("all-row request report requires the frozen request corpus bytes")
        }
        let corpusIDs = corpus.map(\.id)
        guard corpusIDs == frozenRequestCorpusIDs else {
            throw benchmarkError("all-row request report requires the frozen request corpus ID order")
        }
        let measuredIDs = measurements.rows.map(\.id)
        guard Set(measuredIDs).count == measuredIDs.count else {
            throw benchmarkError("measured rows contain duplicate IDs")
        }
        guard measuredIDs == corpusIDs else {
            throw benchmarkError("measured run must preserve the frozen request corpus ID order")
        }
        for item in corpus {
            guard let measured = measurements.rows.first(where: { $0.id == item.id }) else {
                throw benchmarkError("measured run is missing \(item.id)")
            }
            try validateMeasuredRequestRow(item: item, measured: measured)
        }
    }

    static func build(
        corpus: [EfficiencyCase],
        measurements: MeasuredBenchmarkRun,
        measurementArtifact: String,
        counter: BenchmarkTokenCounter
    ) throws -> BenchmarkReport {
        try validateRunMetadata(measurements)
        guard corpus.count == 24 else {
            throw benchmarkError("benchmark requires the frozen 24-row corpus")
        }
        let expectedIDs = Set(corpus.map(\.id))
        let measuredIDs = measurements.rows.map(\.id)
        guard Set(measuredIDs).count == measuredIDs.count else {
            throw benchmarkError("measured rows contain duplicate IDs")
        }
        guard Set(measuredIDs) == expectedIDs else {
            let missing = expectedIDs.subtracting(measuredIDs).sorted().joined(separator: ",")
            let extra = Set(measuredIDs).subtracting(expectedIDs).sorted().joined(separator: ",")
            throw benchmarkError(
                "measured run must cover all 24 frozen corpus rows; missing=[\(missing)] extra=[\(extra)]"
            )
        }
        let measuredByID = Dictionary(uniqueKeysWithValues: measurements.rows.map { ($0.id, $0) })
        let abiTokens = try counter.count(AgentSkillInstaller.rcWireAgentInstructionsTemplate)
        let rows = try corpus.map { item in
            guard let measured = measuredByID[item.id] else {
                throw benchmarkError("measured run is missing \(item.id)")
            }
            return try buildRow(
                item: item,
                measured: measured,
                abiTokens: abiTokens,
                counter: counter
            )
        }
        return BenchmarkReport(
            schemaVersion: 3,
            measurementArtifact: measurementArtifact,
            run: .init(measurements),
            tokenCounter: counter.diagnostic,
            methodology: BenchmarkMethodology(
                corpusRows: rows.count,
                scope: "all-frozen-production-decisions",
                rcw1Payload: "payload-only metrics count the measured complete serialized request frame including exactly one X recovery handle",
                rcw1ABI: "ABI metrics count AgentSkillInstaller.rcWireAgentInstructionsTemplate once for every accepted RCW1 row using the same token counter as Human, RCW1 payload, and Caveman",
                effectiveRCW1: "effective RCW1 tokens equal payload tokens plus ABI tokens; effective savings and comparisons use that total",
                systemInstructionsIncluded: true,
                providerReportedTokens: false,
                rcw1AcceptanceRule: "faithful payload no more than 45 percent of Human tokens and byte-smaller than Human; effective payload plus ABI token-smaller than Human and pinned Caveman",
                humanFailOpenRule: "byte-identical Human, explicit reason, no recovery handle, zero savings"
            ),
            rows: rows,
            totals: BenchmarkTotals(rows: rows)
        )
    }

    private static func validateRunMetadata(_ run: MeasuredBenchmarkRun) throws {
        guard run.schemaVersion == 3 else { throw benchmarkError("unsupported measurement schema") }
        for (name, value) in [
            ("run_id", run.runID), ("captured_at", run.capturedAt), ("source", run.source),
            ("encoder", run.encoder), ("encoder_revision", run.encoderRevision),
            ("source_commit", run.cavemanSourceCommit),
            ("go_version", run.cavemanGoVersion),
            ("build_command", run.cavemanBuildCommand),
            ("binary_sha", run.cavemanBinarySHA),
        ] where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw benchmarkError("measurement metadata is missing \(name)")
        }
        let provenance = CavemanBenchmarkProvenance(
            sourceCommit: run.cavemanSourceCommit,
            goVersion: run.cavemanGoVersion,
            buildCommand: run.cavemanBuildCommand,
            binarySHA: run.cavemanBinarySHA
        )
        guard provenance == benchmarkPinnedCavemanProvenance else {
            throw benchmarkError(
                "measurement Caveman provenance must match the reproducible exact-source build"
            )
        }
    }

    fileprivate static func validateMeasuredRequestRow(
        item: EfficiencyCase,
        measured: MeasuredBenchmarkRow
    ) throws {
        guard !measured.cavemanOutput.isEmpty else {
            throw benchmarkError("\(item.id) is missing measured Caveman output")
        }
        switch measured.decision {
        case .rcw1:
            guard item.eligible else {
                throw benchmarkError("\(item.id) is frozen as ineligible for an RCW1 decision")
            }
            guard measured.failOpenReason == nil else {
                throw benchmarkError("\(item.id) RCW1 decision must not have fail_open_reason")
            }
            guard let recoveryHandle = measured.recoveryHandle,
                  recoveryHandle.hasPrefix("[[rc:"),
                  recoveryHandle.hasSuffix("]]"),
                  !recoveryHandle.contains(where: { $0.isWhitespace }) else {
                throw benchmarkError("\(item.id) RCW1 decision has an invalid recovery handle")
            }
            let frames = try RCWireProtocol.parse(measured.deliveredPayload)
            guard frames.allSatisfy({ $0.direction == .request }) else {
                throw benchmarkError("\(item.id) RCW1 payload is not a request frame")
            }
            let records = frames.flatMap(\.records)
            let recoveryRecords = records.filter {
                $0.kind == .exact && $0.value.hasPrefix("[[rc:")
            }
            guard recoveryRecords.count == 1, recoveryRecords[0].value == recoveryHandle else {
                throw benchmarkError("\(item.id) RCW1 payload must contain exactly its measured X handle")
            }
            let candidateValues = records.map(\.value).joined(separator: "\n")
            guard RCWireProtocol.preservesProtectedSemantics(
                original: item.effectiveHuman,
                wire: measured.deliveredPayload
            ), item.requiredExact.allSatisfy(candidateValues.contains) else {
                throw benchmarkError("\(item.id) RCW1 decision failed literal_gate")
            }
            guard RCWireProtocol.preservesRequestMeaning(
                original: item.effectiveHuman,
                wire: measured.deliveredPayload
            ) else {
                throw benchmarkError("\(item.id) RCW1 decision failed semantic_gate")
            }
        case .humanFailOpen:
            guard measured.failOpenReason != nil else {
                throw benchmarkError("\(item.id) human_fail_open requires fail_open_reason")
            }
            guard measured.recoveryHandle == nil else {
                throw benchmarkError("\(item.id) human_fail_open must not carry a recovery handle")
            }
            guard measured.deliveredPayload == item.effectiveHuman else {
                throw benchmarkError("\(item.id) human_fail_open must deliver byte-identical Human")
            }
            if measured.failOpenReason == .belowFloor,
               TokenEstimator.estimate(item.effectiveHuman) >= 80 {
                throw benchmarkError("\(item.id) below_floor reason does not match the production floor")
            }
        }
    }

    private static func buildRow(
        item: EfficiencyCase,
        measured: MeasuredBenchmarkRow,
        abiTokens: Int,
        counter: BenchmarkTokenCounter
    ) throws -> BenchmarkReportRow {
        let humanTokens = try counter.count(item.effectiveHuman)
        try validateMeasuredRequestRow(item: item, measured: measured)
        let cavemanTokens = try counter.count(measured.cavemanOutput)
        switch measured.decision {
        case .rcw1:
            guard let recoveryHandle = measured.recoveryHandle else {
                throw benchmarkError("\(item.id) RCW1 decision has an invalid recovery handle")
            }
            let deliveredTokens = try counter.count(measured.deliveredPayload)
            let effectiveRCW1Tokens = deliveredTokens + abiTokens
            let within45Percent = deliveredTokens * 100 <= humanTokens * 45
            let smallerThanHuman = effectiveRCW1Tokens < humanTokens
                && measured.deliveredPayload.utf8.count < item.effectiveHuman.utf8.count
            let smallerThanCaveman = effectiveRCW1Tokens < cavemanTokens
            guard within45Percent && smallerThanHuman && smallerThanCaveman else {
                throw benchmarkError(
                    "\(item.id) RCW1 decision failed profitability_gate "
                        + "human=\(humanTokens) payload=\(deliveredTokens) abi=\(abiTokens) "
                        + "effective=\(effectiveRCW1Tokens) caveman=\(cavemanTokens)"
                )
            }
            return BenchmarkReportRow(
                id: item.id,
                language: item.language,
                decision: .rcw1,
                failOpenReason: nil,
                humanBytes: item.effectiveHuman.utf8.count,
                humanTokens: humanTokens,
                deliveredBytes: measured.deliveredPayload.utf8.count,
                deliveredTokens: deliveredTokens,
                cavemanBytes: measured.cavemanOutput.utf8.count,
                cavemanTokens: cavemanTokens,
                rcw1FinalBytes: measured.deliveredPayload.utf8.count,
                rcw1FinalTokens: deliveredTokens,
                rcw1VsHumanPPM: ratioPPM(deliveredTokens, humanTokens),
                rcw1VsCavemanPPM: ratioPPM(deliveredTokens, cavemanTokens),
                abiTokens: abiTokens,
                effectiveRCW1Tokens: effectiveRCW1Tokens,
                effectiveRCW1VsHumanPPM: ratioPPM(effectiveRCW1Tokens, humanTokens),
                effectiveRCW1VsCavemanPPM: ratioPPM(effectiveRCW1Tokens, cavemanTokens),
                cavemanByteIdenticalToHuman: measured.cavemanOutput == item.effectiveHuman,
                protectedSemanticsPass: true,
                requestMeaningPass: true,
                exactAtomsPass: true,
                within45Percent: true,
                smallerThanCaveman: true,
                savedTokens: humanTokens - deliveredTokens,
                effectiveSavedTokens: humanTokens - effectiveRCW1Tokens,
                savingsCountedAsRCW1: true,
                recoveryHandle: recoveryHandle,
                deliveredPayload: measured.deliveredPayload,
                cavemanPayload: measured.cavemanOutput
            )

        case .humanFailOpen:
            guard let reason = measured.failOpenReason else {
                throw benchmarkError("\(item.id) human_fail_open requires fail_open_reason")
            }
            return BenchmarkReportRow(
                id: item.id,
                language: item.language,
                decision: .humanFailOpen,
                failOpenReason: reason,
                humanBytes: item.effectiveHuman.utf8.count,
                humanTokens: humanTokens,
                deliveredBytes: item.effectiveHuman.utf8.count,
                deliveredTokens: humanTokens,
                cavemanBytes: measured.cavemanOutput.utf8.count,
                cavemanTokens: cavemanTokens,
                rcw1FinalBytes: nil,
                rcw1FinalTokens: nil,
                rcw1VsHumanPPM: nil,
                rcw1VsCavemanPPM: nil,
                abiTokens: nil,
                effectiveRCW1Tokens: nil,
                effectiveRCW1VsHumanPPM: nil,
                effectiveRCW1VsCavemanPPM: nil,
                cavemanByteIdenticalToHuman: measured.cavemanOutput == item.effectiveHuman,
                protectedSemanticsPass: nil,
                requestMeaningPass: nil,
                exactAtomsPass: nil,
                within45Percent: nil,
                smallerThanCaveman: nil,
                savedTokens: 0,
                effectiveSavedTokens: 0,
                savingsCountedAsRCW1: false,
                recoveryHandle: nil,
                deliveredPayload: measured.deliveredPayload,
                cavemanPayload: measured.cavemanOutput
            )
        }
    }
}

private struct BenchmarkReport: Encodable {
    let schemaVersion: Int
    let measurementArtifact: String
    let run: BenchmarkRunMetadata
    let tokenCounter: TokenCounterDiagnostic
    let methodology: BenchmarkMethodology
    let rows: [BenchmarkReportRow]
    let totals: BenchmarkTotals

    enum CodingKeys: String, CodingKey {
        case run, methodology, rows, totals
        case schemaVersion = "schema_version"
        case measurementArtifact = "measurement_artifact"
        case tokenCounter = "token_counter"
    }

    var csv: String {
        let header = [
            "id", "language", "decision", "fail_open_reason",
            "human_bytes", "human_tokens", "delivered_bytes", "delivered_tokens",
            "caveman_bytes", "caveman_tokens", "rcw1_final_bytes", "rcw1_final_tokens",
            "rcw1_vs_human_ppm", "rcw1_vs_caveman_ppm", "caveman_pass_through",
            "within_45_percent", "smaller_than_caveman", "saved_tokens",
            "savings_counted_as_rcw1", "recovery_handle", "delivered_payload", "caveman_payload",
            "abi_tokens", "effective_rcw1_tokens", "effective_rcw1_vs_human_ppm",
            "effective_rcw1_vs_caveman_ppm", "effective_saved_tokens",
        ]
        let body = rows.map { benchmarkCSVFields($0).map(csvField).joined(separator: ",") }
        return ([header.joined(separator: ",")] + body).joined(separator: "\n") + "\n"
    }
}

private func benchmarkCSVFields(_ row: BenchmarkReportRow) -> [String] {
    let rcw1FinalBytes = row.rcw1FinalBytes.map { String($0) } ?? ""
    let rcw1FinalTokens = row.rcw1FinalTokens.map { String($0) } ?? ""
    let rcw1VsHuman = row.rcw1VsHumanPPM.map { String($0) } ?? ""
    let rcw1VsCaveman = row.rcw1VsCavemanPPM.map { String($0) } ?? ""
    let within45Percent = row.within45Percent.map { String($0) } ?? ""
    let smallerThanCaveman = row.smallerThanCaveman.map { String($0) } ?? ""
    let abiTokens = row.abiTokens.map { String($0) } ?? ""
    let effectiveRCW1Tokens = row.effectiveRCW1Tokens.map { String($0) } ?? ""
    let effectiveRCW1VsHuman = row.effectiveRCW1VsHumanPPM.map { String($0) } ?? ""
    let effectiveRCW1VsCaveman = row.effectiveRCW1VsCavemanPPM.map { String($0) } ?? ""
    return [
        row.id, row.language, row.decision.rawValue, row.failOpenReason?.rawValue ?? "",
        String(row.humanBytes), String(row.humanTokens),
        String(row.deliveredBytes), String(row.deliveredTokens),
        String(row.cavemanBytes), String(row.cavemanTokens),
        rcw1FinalBytes, rcw1FinalTokens, rcw1VsHuman, rcw1VsCaveman,
        String(row.cavemanByteIdenticalToHuman), within45Percent, smallerThanCaveman,
        String(row.savedTokens), String(row.savingsCountedAsRCW1), row.recoveryHandle ?? "",
        row.deliveredPayload, row.cavemanPayload,
        abiTokens, effectiveRCW1Tokens, effectiveRCW1VsHuman, effectiveRCW1VsCaveman,
        String(row.effectiveSavedTokens),
    ]
}

private struct BenchmarkRunMetadata: Encodable {
    let runID: String
    let capturedAt: String
    let source: String
    let encoder: String
    let encoderRevision: String
    let provider: String?
    let providerModel: String?
    let cavemanSourceCommit: String
    let cavemanGoVersion: String
    let cavemanBuildCommand: String
    let cavemanBinarySHA: String

    init(_ measured: MeasuredBenchmarkRun) {
        runID = measured.runID
        capturedAt = measured.capturedAt
        source = measured.source
        encoder = measured.encoder
        encoderRevision = measured.encoderRevision
        provider = measured.provider
        providerModel = measured.providerModel
        cavemanSourceCommit = measured.cavemanSourceCommit
        cavemanGoVersion = measured.cavemanGoVersion
        cavemanBuildCommand = measured.cavemanBuildCommand
        cavemanBinarySHA = measured.cavemanBinarySHA
    }

    enum CodingKeys: String, CodingKey {
        case source, encoder, provider
        case runID = "run_id"
        case capturedAt = "captured_at"
        case encoderRevision = "encoder_revision"
        case providerModel = "provider_model"
        case cavemanSourceCommit = "source_commit"
        case cavemanGoVersion = "go_version"
        case cavemanBuildCommand = "build_command"
        case cavemanBinarySHA = "binary_sha"
    }
}

private struct BenchmarkMethodology: Encodable {
    let corpusRows: Int
    let scope: String
    let rcw1Payload: String
    let rcw1ABI: String
    let effectiveRCW1: String
    let systemInstructionsIncluded: Bool
    let providerReportedTokens: Bool
    let rcw1AcceptanceRule: String
    let humanFailOpenRule: String

    enum CodingKeys: String, CodingKey {
        case scope
        case corpusRows = "corpus_rows"
        case rcw1Payload = "rcw1_payload"
        case rcw1ABI = "rcw1_abi"
        case effectiveRCW1 = "effective_rcw1"
        case systemInstructionsIncluded = "system_instructions_included"
        case providerReportedTokens = "provider_reported_tokens"
        case rcw1AcceptanceRule = "rcw1_acceptance_rule"
        case humanFailOpenRule = "human_fail_open_rule"
    }
}

private struct BenchmarkReportRow: Encodable {
    let id: String
    let language: String
    let decision: BenchmarkProductionDecision
    let failOpenReason: BenchmarkFailOpenReason?
    let humanBytes: Int
    let humanTokens: Int
    let deliveredBytes: Int
    let deliveredTokens: Int
    let cavemanBytes: Int
    let cavemanTokens: Int
    let rcw1FinalBytes: Int?
    let rcw1FinalTokens: Int?
    let rcw1VsHumanPPM: Int?
    let rcw1VsCavemanPPM: Int?
    let abiTokens: Int?
    let effectiveRCW1Tokens: Int?
    let effectiveRCW1VsHumanPPM: Int?
    let effectiveRCW1VsCavemanPPM: Int?
    let cavemanByteIdenticalToHuman: Bool
    let protectedSemanticsPass: Bool?
    let requestMeaningPass: Bool?
    let exactAtomsPass: Bool?
    let within45Percent: Bool?
    let smallerThanCaveman: Bool?
    let savedTokens: Int
    let effectiveSavedTokens: Int
    let savingsCountedAsRCW1: Bool
    let recoveryHandle: String?
    let deliveredPayload: String
    let cavemanPayload: String

    enum CodingKeys: String, CodingKey {
        case id, language, decision
        case failOpenReason = "fail_open_reason"
        case humanBytes = "human_bytes"
        case humanTokens = "human_tokens"
        case deliveredBytes = "delivered_bytes"
        case deliveredTokens = "delivered_tokens"
        case cavemanBytes = "caveman_bytes"
        case cavemanTokens = "caveman_tokens"
        case rcw1FinalBytes = "rcw1_final_bytes"
        case rcw1FinalTokens = "rcw1_final_tokens"
        case rcw1VsHumanPPM = "rcw1_vs_human_ppm"
        case rcw1VsCavemanPPM = "rcw1_vs_caveman_ppm"
        case abiTokens = "abi_tokens"
        case effectiveRCW1Tokens = "effective_rcw1_tokens"
        case effectiveRCW1VsHumanPPM = "effective_rcw1_vs_human_ppm"
        case effectiveRCW1VsCavemanPPM = "effective_rcw1_vs_caveman_ppm"
        case cavemanByteIdenticalToHuman = "caveman_byte_identical_to_human"
        case protectedSemanticsPass = "protected_semantics_pass"
        case requestMeaningPass = "request_meaning_pass"
        case exactAtomsPass = "exact_atoms_pass"
        case within45Percent = "within_45_percent"
        case smallerThanCaveman = "smaller_than_caveman"
        case savedTokens = "saved_tokens"
        case effectiveSavedTokens = "effective_saved_tokens"
        case savingsCountedAsRCW1 = "savings_counted_as_rcw1"
        case recoveryHandle = "recovery_handle"
        case deliveredPayload = "delivered_payload"
        case cavemanPayload = "caveman_payload"
    }
}

private struct BenchmarkTotals: Encodable {
    let rows: Int
    let rcw1Rows: Int
    let humanFailOpenRows: Int
    let failOpenReasons: FailOpenReasonCounts
    let humanBytes: Int
    let humanTokens: Int
    let deliveredBytes: Int
    let deliveredTokens: Int
    let cavemanBytes: Int
    let cavemanTokens: Int
    let rcw1SavedTokens: Int
    let rcw1ABITokens: Int
    let effectiveDeliveredTokens: Int
    let effectiveRCW1Tokens: Int
    let effectiveRCW1SavedTokens: Int
    let humanFailOpenSavingsTokens: Int
    let deliveredVsHumanPPM: Int
    let effectiveDeliveredVsHumanPPM: Int
    let rcw1OnlyVsHumanPPM: Int?
    let rcw1OnlyVsCavemanPPM: Int?
    let effectiveRCW1OnlyVsHumanPPM: Int?
    let effectiveRCW1OnlyVsCavemanPPM: Int?

    init(rows: [BenchmarkReportRow]) {
        let rcw1 = rows.filter { $0.decision == .rcw1 }
        let failOpen = rows.filter { $0.decision == .humanFailOpen }
        self.rows = rows.count
        rcw1Rows = rcw1.count
        humanFailOpenRows = failOpen.count
        failOpenReasons = FailOpenReasonCounts(rows: failOpen)
        humanBytes = rows.reduce(0) { $0 + $1.humanBytes }
        humanTokens = rows.reduce(0) { $0 + $1.humanTokens }
        deliveredBytes = rows.reduce(0) { $0 + $1.deliveredBytes }
        deliveredTokens = rows.reduce(0) { $0 + $1.deliveredTokens }
        cavemanBytes = rows.reduce(0) { $0 + $1.cavemanBytes }
        cavemanTokens = rows.reduce(0) { $0 + $1.cavemanTokens }
        rcw1SavedTokens = rcw1.reduce(0) { $0 + $1.savedTokens }
        rcw1ABITokens = rcw1.reduce(0) { $0 + ($1.abiTokens ?? 0) }
        effectiveDeliveredTokens = rows.reduce(0) {
            $0 + ($1.effectiveRCW1Tokens ?? $1.deliveredTokens)
        }
        effectiveRCW1Tokens = rcw1.reduce(0) { $0 + ($1.effectiveRCW1Tokens ?? 0) }
        effectiveRCW1SavedTokens = rcw1.reduce(0) { $0 + $1.effectiveSavedTokens }
        humanFailOpenSavingsTokens = failOpen.reduce(0) { $0 + $1.savedTokens }
        deliveredVsHumanPPM = ratioPPM(deliveredTokens, humanTokens)
        effectiveDeliveredVsHumanPPM = ratioPPM(effectiveDeliveredTokens, humanTokens)
        let rcw1HumanTokens = rcw1.reduce(0) { $0 + $1.humanTokens }
        let rcw1DeliveredTokens = rcw1.reduce(0) { $0 + $1.deliveredTokens }
        let rcw1CavemanTokens = rcw1.reduce(0) { $0 + $1.cavemanTokens }
        rcw1OnlyVsHumanPPM = rcw1.isEmpty ? nil : ratioPPM(rcw1DeliveredTokens, rcw1HumanTokens)
        rcw1OnlyVsCavemanPPM = rcw1.isEmpty ? nil : ratioPPM(rcw1DeliveredTokens, rcw1CavemanTokens)
        effectiveRCW1OnlyVsHumanPPM = rcw1.isEmpty
            ? nil
            : ratioPPM(effectiveRCW1Tokens, rcw1HumanTokens)
        effectiveRCW1OnlyVsCavemanPPM = rcw1.isEmpty
            ? nil
            : ratioPPM(effectiveRCW1Tokens, rcw1CavemanTokens)
    }

    enum CodingKeys: String, CodingKey {
        case rows
        case rcw1Rows = "rcw1_rows"
        case humanFailOpenRows = "human_fail_open_rows"
        case failOpenReasons = "fail_open_reasons"
        case humanBytes = "human_bytes"
        case humanTokens = "human_tokens"
        case deliveredBytes = "delivered_bytes"
        case deliveredTokens = "delivered_tokens"
        case cavemanBytes = "caveman_bytes"
        case cavemanTokens = "caveman_tokens"
        case rcw1SavedTokens = "rcw1_saved_tokens"
        case rcw1ABITokens = "rcw1_abi_tokens"
        case effectiveDeliveredTokens = "effective_delivered_tokens"
        case effectiveRCW1Tokens = "effective_rcw1_tokens"
        case effectiveRCW1SavedTokens = "effective_rcw1_saved_tokens"
        case humanFailOpenSavingsTokens = "human_fail_open_savings_tokens"
        case deliveredVsHumanPPM = "delivered_vs_human_ppm"
        case effectiveDeliveredVsHumanPPM = "effective_delivered_vs_human_ppm"
        case rcw1OnlyVsHumanPPM = "rcw1_only_vs_human_ppm"
        case rcw1OnlyVsCavemanPPM = "rcw1_only_vs_caveman_ppm"
        case effectiveRCW1OnlyVsHumanPPM = "effective_rcw1_only_vs_human_ppm"
        case effectiveRCW1OnlyVsCavemanPPM = "effective_rcw1_only_vs_caveman_ppm"
    }
}

private struct FailOpenReasonCounts: Encodable {
    let belowFloor: Int
    let semanticGate: Int
    let literalGate: Int
    let profitabilityGate: Int
    let sidecarUnavailable: Int

    init(rows: [BenchmarkReportRow]) {
        belowFloor = rows.filter { $0.failOpenReason == .belowFloor }.count
        semanticGate = rows.filter { $0.failOpenReason == .semanticGate }.count
        literalGate = rows.filter { $0.failOpenReason == .literalGate }.count
        profitabilityGate = rows.filter { $0.failOpenReason == .profitabilityGate }.count
        sidecarUnavailable = rows.filter { $0.failOpenReason == .sidecarUnavailable }.count
    }

    subscript(reason: BenchmarkFailOpenReason) -> Int {
        switch reason {
        case .belowFloor: return belowFloor
        case .semanticGate: return semanticGate
        case .literalGate: return literalGate
        case .profitabilityGate: return profitabilityGate
        case .sidecarUnavailable: return sidecarUnavailable
        }
    }

    enum CodingKeys: String, CodingKey {
        case belowFloor = "below_floor"
        case semanticGate = "semantic_gate"
        case literalGate = "literal_gate"
        case profitabilityGate = "profitability_gate"
        case sidecarUnavailable = "sidecar_unavailable"
    }
}

private func ratioPPM(_ numerator: Int, _ denominator: Int) -> Int {
    guard denominator > 0 else { return 0 }
    return Int((Double(numerator) * 1_000_000 / Double(denominator)).rounded())
}

private func csvField(_ value: String) -> String {
    guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
        return value
    }
    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

private func benchmarkError(_ message: String) -> NSError {
    NSError(domain: "RCW1MeasuredBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private struct AllRowArmInput: Equatable {
    var payload: String
    var handle: String?
    var abi: String
    var producerID: String
    var producerRevision: String = "1"
    var abiRevision: String = "1"
    var generation: TokenSaverBestOfThreeSelector.GateStatus
    var structural: TokenSaverBestOfThreeSelector.GateStatus
    var semantic: TokenSaverBestOfThreeSelector.GateStatus
    var recovery: TokenSaverBestOfThreeSelector.GateStatus

    var envelope: String {
        abi.isEmpty ? payload : abi + "\n" + payload
    }
}

private actor AllRowCountProbe {
    private let counts: [String: Int]
    private(set) var calls: [String] = []

    init(counts: [String: Int]) {
        self.counts = counts
    }

    func count(_ text: String) throws -> Int {
        calls.append(text)
        guard let value = counts[text] else {
            throw benchmarkError("missing all-row probe token count")
        }
        return value
    }
}

private enum AllRowBestOfThreeHarness {
    static let schemaVersion = 6
    static let estimatedQuality = "estimated"
    static let testAuthorityQuality = "unit-test-authority"
    static let localExactQuality = "local_exact"
    static let testAuthorityCounterID = "unit-test-authority"

    static func estimatedCapability() -> TokenSaverBestOfThreeSelector.CounterCapability {
        let fallback: BenchmarkTokenCounter
        do {
            fallback = try BenchmarkTokenCounter(environment: [:])
        } catch {
            fallback = BenchmarkTokenCounter(
                diagnostic: TokenCounterDiagnostic(
                    name: "RemoteCode.TokenEstimator",
                    version: "1",
                    encoding: "utf8-char-word-heuristic",
                    measurementKind: "estimated"
                ),
                count: { TokenEstimator.estimate($0) }
            )
        }
        return .init(
            counter: .init(
                id: fallback.diagnostic.name,
                revision: fallback.diagnostic.version,
                encoding: fallback.diagnostic.encoding,
                provider: "local",
                resolvedModel: "estimated",
                quality: .estimated
            ),
            count: { try fallback.count($0) }
        )
    }

    static func testAuthorityCapability(
        counts: [String: Int]?,
        probe: AllRowCountProbe?
    ) -> TokenSaverBestOfThreeSelector.CounterCapability {
        let counter = TokenSaverBestOfThreeSelector.Counter(
            id: testAuthorityCounterID,
            revision: "1",
            encoding: "unit-test-authority",
            provider: "local",
            resolvedModel: "unit-test-authority",
            quality: .exactLocalTokenizer
        )
        if let probe {
            return .init(counter: counter, count: { try await probe.count($0) })
        }
        return .init(counter: counter, count: { text in
            guard let value = counts?[text] else {
                throw benchmarkError("missing all-row unit token count")
            }
            return value
        })
    }

    static func exactCapability(
        from counter: BenchmarkTokenCounter
    ) throws -> TokenSaverBestOfThreeSelector.CounterCapability {
        guard counter.diagnostic.measurementKind == "exact-local-tokenizer" else {
            throw benchmarkError("all-row emitter refuses estimated token counter")
        }
        guard let sourceSHA = counter.sourceSHA256, sourceSHA.count == 64,
              sourceSHA.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw benchmarkError("all-row emitter requires exact-local-tokenizer executable source SHA-256")
        }
        try counter.validateSourceSHA256()
        return .init(
            counter: .init(
                id: counter.diagnostic.name,
                revision: counter.diagnostic.version,
                encoding: counter.diagnostic.encoding,
                provider: "local",
                resolvedModel: "local-exact",
                quality: .exactLocalTokenizer
            ),
            count: { try counter.count($0) }
        )
    }

    static func allowsProvenSavings(_ quality: String) -> Bool {
        quality == localExactQuality
    }

    static func allowsModeledDelta(_ quality: String) -> Bool {
        quality == localExactQuality || quality == testAuthorityQuality
    }

    static func localExactCapability(
        count: @escaping @Sendable (String) throws -> Int
    ) -> TokenSaverBestOfThreeSelector.CounterCapability {
        .init(
            counter: .init(
                id: "local-exact-unit",
                revision: "1",
                encoding: "utf8-bytes",
                provider: "local",
                resolvedModel: "local-exact",
                quality: .exactLocalTokenizer
            ),
            count: count
        )
    }

    static func versionedPublicationContext() throws -> AllRowPublicationContext {
        AllRowPublicationContext(
            remoteCodeHead: allRowExpectedSourceCommit,
            workspaceClean: true,
            runnerSourceSHA256: sha256Hex(try Data(contentsOf: URL(fileURLWithPath: #filePath)))
        )
    }

    static func validatePublicationContext(_ context: AllRowPublicationContext) throws {
        guard context.workspaceClean else {
            throw benchmarkError("all-row publication requires a clean RemoteCode worktree")
        }
        guard context.remoteCodeHead == allRowExpectedSourceCommit else {
            throw benchmarkError(
                "all-row publication requires source commit \(allRowExpectedSourceCommit)"
            )
        }
        guard context.runnerSourceSHA256.count == 64,
              context.runnerSourceSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw benchmarkError("all-row publication requires runner source SHA-256")
        }
    }

    static func livePublicationContext() throws -> AllRowPublicationContext {
        let repository = allRowRepositoryURL()
        let status = try subprocessText(executable: "/usr/bin/git", arguments: [
            "-C", repository.path, "status", "--porcelain=v1", "--untracked-files=all",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        let head = try subprocessText(executable: "/usr/bin/git", arguments: [
            "-C", repository.path, "rev-parse", "HEAD",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        return AllRowPublicationContext(
            remoteCodeHead: head,
            workspaceClean: status.isEmpty,
            runnerSourceSHA256: sha256Hex(try Data(contentsOf: URL(fileURLWithPath: #filePath)))
        )
    }

    static func publishedQuality(
        from capability: TokenSaverBestOfThreeSelector.CounterCapability?
    ) -> String {
        guard let counter = capability?.counter else { return "absent" }
        switch counter.quality {
        case .estimated:
            return estimatedQuality
        case .unknown:
            return "unknown"
        case .exactLocalTokenizer:
            return counter.id == testAuthorityCounterID ? testAuthorityQuality : localExactQuality
        case .exactResolvedModelTokenizer:
            return "unproven"
        }
    }

    static func rcs1Payload(fromHuman human: String) -> String? {
        guard let item = RemoteCodeCompactSpan.encode(human),
              RemoteCodeCompactSpan.decode(item) == human else {
            return nil
        }
        return item
    }

    static func selectRow(
        id: String,
        human: String,
        rcw1: AllRowArmInput,
        rcs1: AllRowArmInput,
        capability: TokenSaverBestOfThreeSelector.CounterCapability?,
        surface: AllRowSurface = .request,
        cavemanOutput: String? = nil,
        recoveryStore: TokenSaverScopedRecoveryStore? = nil,
        recoveryDisk: TokenSaverRecoveryDiskSnapshot? = nil
    ) async throws -> AllRowRuntimeRow {
        guard !human.isEmpty else { throw benchmarkError("all-row human is empty") }
        var rcw1 = rcw1
        var rcs1 = rcs1
        if let recoveryStore {
            rcw1 = AllRowRecoveryLab.apply(
                rcw1, human: human, rowID: id, arm: "rcw1",
                store: recoveryStore, disk: recoveryDisk
            )
            rcs1 = AllRowRecoveryLab.apply(
                rcs1, human: human, rowID: id, arm: "rcs1",
                store: recoveryStore, disk: recoveryDisk
            )
        }
        let sourceSHA = sha256Hex(Data(human.utf8))
        let decision: TokenSaverBestOfThreeSelector.Decision
        if surface == .response {
            decision = await TokenSaverContextItemSelector.select(
                canonicalHuman: human,
                humanEnvelope: human,
                rcw1: candidate(rcw1, format: .rcw1, sourceSHA: sourceSHA),
                rcs1: candidate(rcs1, format: .rcs1, sourceSHA: sourceSHA),
                target: target(from: capability),
                counter: capability
            )
        } else {
            decision = await TokenSaverBestOfThreeSelector.select(
                canonicalHuman: human,
                humanOutboundPrompt: human,
                humanEffectiveEnvelope: human,
                target: target(from: capability),
                candidates: [
                    candidate(rcw1, format: .rcw1, sourceSHA: sourceSHA),
                    candidate(rcs1, format: .rcs1, sourceSHA: sourceSHA),
                ],
                counter: capability
            )
        }
        return row(
            id: id,
            surface: surface,
            human: human,
            rcw1: rcw1,
            rcs1: rcs1,
            decision: decision,
            capability: capability,
            cavemanOutput: cavemanOutput
        )
    }

    static func requestReport(
        corpus: [EfficiencyCase],
        measurements: MeasuredBenchmarkRun,
        capability: TokenSaverBestOfThreeSelector.CounterCapability?,
        recoveryStore: TokenSaverScopedRecoveryStore? = nil
    ) async throws -> AllRowRuntimeReport {
        let corpusData = try Data(contentsOf: allRowRequestCorpusURL())
        try MeasuredBenchmarkHarness.validateAllRowRequestIntegrity(
            corpus: corpus,
            corpusData: corpusData,
            measurements: measurements
        )
        let measuredByID = Dictionary(uniqueKeysWithValues: measurements.rows.map { ($0.id, $0) })
        var rows: [AllRowRuntimeRow] = []
        rows.reserveCapacity(corpus.count)
        for item in corpus {
            guard let measured = measuredByID[item.id] else {
                throw benchmarkError("measured run is missing \(item.id)")
            }
            let human = item.effectiveHuman
            rows.append(try await selectRow(
                id: item.id,
                human: human,
                rcw1: requestRCW1Arm(item: item, measured: measured),
                rcs1: rcs1Arm(fromHuman: human),
                capability: capability,
                surface: .request,
                cavemanOutput: measured.cavemanOutput,
                recoveryStore: recoveryStore
            ))
        }
        return report(surface: .request, rows: rows)
    }

    static func responseReport(
        corpus: [ResponseEfficiencyCase],
        measurements: [ResponseBenchmarkMeasurement],
        capability: TokenSaverBestOfThreeSelector.CounterCapability?,
        recoveryStore: TokenSaverScopedRecoveryStore? = nil
    ) async throws -> AllRowRuntimeReport {
        let corpusData = try Data(contentsOf: allRowResponseCorpusURL())
        let sourcePrompt = try allRowNominalSourcePrompt()
        try ResponseBenchmarkHarness.validateAllRowResponseContracts(
            corpus: corpus,
            corpusData: corpusData,
            measurements: measurements,
            sourcePrompt: sourcePrompt
        )
        let measuredByID = Dictionary(uniqueKeysWithValues: measurements.map { ($0.id, $0) })
        var rows: [AllRowRuntimeRow] = []
        rows.reserveCapacity(corpus.count)
        for item in corpus {
            guard let measured = measuredByID[item.id] else {
                throw benchmarkError("measured run is missing \(item.id)")
            }
            let human = item.humanBaseline
            rows.append(try await selectRow(
                id: item.id,
                human: human,
                rcw1: responseContextRCW1Arm(item: item, measured: measured),
                rcs1: responseContextRCS1Arm(fromHuman: human),
                capability: capability,
                surface: .response,
                cavemanOutput: nil,
                recoveryStore: recoveryStore
            ))
        }
        return report(surface: .response, rows: rows)
    }

    static func checkpoint(
        request: AllRowRuntimeReport,
        response: AllRowRuntimeReport,
        exactCounterSourceSHA256: String,
        measurementArtifactSHA256: String,
        evidenceBinding: AllRowEvidenceBinding,
        publicationContext: AllRowPublicationContext
    ) throws -> AllRowCheckpointReport {
        try validateSurface(request, .request, 24)
        try validateSurface(response, .response, 10)
        guard request.methodology.quality == response.methodology.quality,
              request.methodology.counterID == response.methodology.counterID,
              request.methodology.counterRevision == response.methodology.counterRevision,
              request.methodology.counterEncoding == response.methodology.counterEncoding else {
            throw benchmarkError("all-row checkpoint requires one counter across surfaces")
        }
        let rows = request.rows + response.rows
        return AllRowCheckpointReport(
            schemaVersion: schemaVersion,
            codec: "human-rcw1-rcs1",
            billingClaim: false,
            methodology: request.methodology,
            counter: AllRowCheckpointCounter(
                id: request.methodology.counterID,
                revision: request.methodology.counterRevision,
                encoding: request.methodology.counterEncoding,
                quality: request.methodology.quality
            ),
            provenance: try AllRowCheckpointProvenance.bind(
                exactCounterSourceSHA256: exactCounterSourceSHA256,
                measurementArtifactSHA256: measurementArtifactSHA256,
                evidenceBinding: evidenceBinding,
                publicationContext: publicationContext
            ),
            rows: rows,
            totals: AllRowCheckpointTotals(
                request: request.totals,
                response: response.totals,
                overall: AllRowRuntimeTotals(rows: rows)
            )
        )
    }

    fileprivate static func validateSurface(
        _ report: AllRowRuntimeReport,
        _ surface: AllRowSurface,
        _ expectedRows: Int
    ) throws {
        guard report.schemaVersion == schemaVersion else {
            throw benchmarkError("all-row emitter requires schema 6")
        }
        guard report.surface == surface, report.rows.count == expectedRows else {
            throw benchmarkError(
                "all-row \(surface.rawValue) report requires the frozen \(expectedRows)-row corpus"
            )
        }
        let expectedIDs = surface == .request ? frozenRequestCorpusIDs : frozenResponseCorpusIDs
        guard report.rows.map(\.id) == expectedIDs else {
            throw benchmarkError("all-row \(surface.rawValue) report requires the frozen corpus ID order")
        }
        guard report.billingClaim == false, report.methodology.billingClaim == false,
              report.methodology.providerReportedTokens == false else {
            throw benchmarkError("all-row emitter forbids billing or provider token claims")
        }
        for row in report.rows {
            guard row.surface == surface else {
                throw benchmarkError("all-row row surface drifted")
            }
            guard row.human.format == .human, row.rcw1.format == .rcw1, row.rcs1.format == .rcs1 else {
                throw benchmarkError("all-row JSON+CSV must keep Human/RCW1/RCS1 visible")
            }
            guard row.selectedFormat.rawValue != "caveman" else {
                throw benchmarkError("Caveman is never selected_format")
            }
            guard row.billingClaim == false, row.providerReportedTokens == false else {
                throw benchmarkError("all-row emitter forbids billing or provider token claims")
            }
        }
    }

    private static func rcs1Arm(fromHuman human: String) -> AllRowArmInput {
        guard let payload = rcs1Payload(fromHuman: human) else {
            return unavailableArm(
                payload: "RCS1_RUNTIME_UNAVAILABLE",
                abi: "RCS1_ABI_UNAVAILABLE",
                producerID: TokenSaverRequestSelectionReceipt.rcs1UnavailableProducerID,
                generation: .failed
            )
        }
        return AllRowArmInput(
            payload: payload,
            handle: nil,
            abi: AgentSkillInstaller.compactSpanAgentInstructionsTemplate,
            producerID: TokenSaverRequestSelectionReceipt.rcs1ProducerID,
            generation: .passed,
            structural: .passed,
            semantic: .passed,
            recovery: .passed
        )
    }

    private static func requestRCW1Arm(
        item: EfficiencyCase,
        measured: MeasuredBenchmarkRow
    ) -> AllRowArmInput {
        let payload: String
        let handle: String?
        if measured.decision == .rcw1 {
            payload = measured.deliveredPayload
            handle = measured.recoveryHandle
        } else if let observed = measured.observedEncoderOutput, !observed.isEmpty {
            payload = observed
            handle = measured.recoveryHandle
        } else {
            return unavailableArm(
                payload: "RCW1_RUNTIME_UNAVAILABLE",
                abi: "RCW1_ABI_UNAVAILABLE",
                producerID: TokenSaverRequestSelectionReceipt.rcw1ProducerID
            )
        }
        return evaluateRequestRCW1(
            human: item.effectiveHuman,
            payload: payload,
            handle: handle,
            requiredExact: item.requiredExact
        )
    }

    private static func evaluateRequestRCW1(
        human: String,
        payload: String,
        handle: String?,
        requiredExact: [String]
    ) -> AllRowArmInput {
        var structural = TokenSaverBestOfThreeSelector.GateStatus.failed
        var semantic = TokenSaverBestOfThreeSelector.GateStatus.failed
        var recovery = TokenSaverBestOfThreeSelector.GateStatus.failed
        if let frames = try? RCWireProtocol.parse(payload),
           frames.allSatisfy({ $0.direction == .request }) {
            structural = .passed
            let records = frames.flatMap(\.records)
            let recoveryRecords = records.filter {
                $0.kind == .exact && $0.value.hasPrefix("[[rc:")
            }
            if let handle {
                recovery = recoveryRecords.count == 1 && recoveryRecords[0].value == handle
                    ? .passed : .failed
            } else {
                recovery = recoveryRecords.isEmpty ? .passed : .failed
            }
            let values = records.map(\.value).joined(separator: "\n")
            let meaning = RCWireProtocol.preservesProtectedSemantics(
                original: human, wire: payload
            )
                && RCWireProtocol.preservesRequestMeaning(original: human, wire: payload)
                && requiredExact.allSatisfy(values.contains)
            semantic = meaning ? .passed : .failed
        }
        return AllRowArmInput(
            payload: payload,
            handle: handle,
            abi: AgentSkillInstaller.rcWireAgentInstructionsTemplate,
            producerID: TokenSaverRequestSelectionReceipt.rcw1ProducerID,
            generation: .passed,
            structural: structural,
            semantic: semantic,
            recovery: recovery
        )
    }

    private static func responseContextRCW1Arm(
        item: ResponseEfficiencyCase,
        measured: ResponseBenchmarkMeasurement
    ) -> AllRowArmInput {
        let abi = AgentSkillInstaller.rcWireAgentInstructionsTemplate
        return armInput(
            from: TokenSaverContextItemSelector.rcw1Candidate(
                canonicalHuman: item.humanBaseline,
                persistedProviderWire: measured.wire,
                abi: abi,
                effectiveEnvelope: abi + "\n" + measured.wire
            )
        )
    }

    private static func responseContextRCS1Arm(fromHuman human: String) -> AllRowArmInput {
        let abi = AgentSkillInstaller.compactSpanAgentInstructionsTemplate
        if let encoded = rcs1Payload(fromHuman: human) {
            return armInput(
                from: TokenSaverContextItemSelector.rcs1Candidate(
                    canonicalHuman: human,
                    encodedItem: encoded,
                    abi: abi,
                    effectiveEnvelope: abi + "\n" + encoded
                )
            )
        }
        return armInput(
            from: TokenSaverContextItemSelector.rcs1Candidate(
                canonicalHuman: human,
                abi: abi,
                effectiveEnvelope: abi + "\nRCS1_UNAVAILABLE"
            )
        )
    }

    private static func armInput(
        from candidate: TokenSaverBestOfThreeSelector.Candidate
    ) -> AllRowArmInput {
        AllRowArmInput(
            payload: candidate.payload,
            handle: candidate.handle,
            abi: candidate.abi,
            producerID: candidate.producerID,
            producerRevision: candidate.producerRevision,
            abiRevision: candidate.abiRevision,
            generation: candidate.generation,
            structural: candidate.structural,
            semantic: candidate.semantic,
            recovery: candidate.recovery
        )
    }

    private static func unavailableArm(
        payload: String,
        abi: String,
        producerID: String,
        generation: TokenSaverBestOfThreeSelector.GateStatus = .passed
    ) -> AllRowArmInput {
        AllRowArmInput(
            payload: payload,
            handle: nil,
            abi: abi,
            producerID: producerID,
            producerRevision: "unavailable",
            abiRevision: "unavailable",
            generation: generation,
            structural: .failed,
            semantic: .failed,
            recovery: .failed
        )
    }

    private static func candidate(
        _ input: AllRowArmInput,
        format: TokenSaverBestOfThreeSelector.Format,
        sourceSHA: String
    ) -> TokenSaverBestOfThreeSelector.Candidate {
        .init(
            format: format,
            sourceSHA256: sourceSHA,
            payload: input.payload,
            abi: input.abi,
            effectiveEnvelope: input.envelope,
            handle: input.handle,
            producerID: input.producerID,
            producerRevision: input.producerRevision,
            abiRevision: input.abiRevision,
            generation: input.generation,
            structural: input.structural,
            semantic: input.semantic,
            recovery: input.recovery
        )
    }

    private static func target(
        from capability: TokenSaverBestOfThreeSelector.CounterCapability?
    ) -> TokenSaverBestOfThreeSelector.Target {
        if let counter = capability?.counter {
            return .init(
                provider: counter.provider,
                resolvedModel: counter.resolvedModel,
                counterID: counter.id,
                counterRevision: counter.revision,
                encoding: counter.encoding
            )
        }
        return .init(
            provider: "local",
            resolvedModel: "absent",
            counterID: "absent",
            counterRevision: "absent",
            encoding: "absent"
        )
    }

    private static func row(
        id: String,
        surface: AllRowSurface,
        human: String,
        rcw1: AllRowArmInput,
        rcs1: AllRowArmInput,
        decision: TokenSaverBestOfThreeSelector.Decision,
        capability: TokenSaverBestOfThreeSelector.CounterCapability?,
        cavemanOutput: String?
    ) -> AllRowRuntimeRow {
        let quality = publishedQuality(from: capability)
        let winner = decision.selectedFormat != .human && decision.reason == .uniqueStrictMinimum
        let modeled = allowsModeledDelta(quality) && winner ? decision.modeledContextDelta : 0
        let savings = allowsProvenSavings(quality) && winner ? max(0, decision.modeledContextDelta) : 0
        let counter = capability?.counter
        return AllRowRuntimeRow(
            id: id,
            surface: surface,
            selectedFormat: decision.selectedFormat,
            reason: decision.reason,
            modeledContextDelta: modeled,
            provenSavingsTokens: savings,
            billingClaim: false,
            providerReportedTokens: false,
            counterQuality: quality,
            counterID: counter?.id ?? "",
            counterRevision: counter?.revision ?? "",
            counterEncoding: counter?.encoding ?? "",
            human: humanRecord(human: human, cost: decision.cost(.human)),
            rcw1: armRecord(format: .rcw1, input: rcw1, decision: decision),
            rcs1: armRecord(format: .rcs1, input: rcs1, decision: decision),
            cavemanTokens: nil,
            cavemanSHA256: cavemanOutput.map { sha256Hex(Data($0.utf8)) }
        )
    }

    private static func humanRecord(
        human: String,
        cost: TokenSaverBestOfThreeSelector.Cost?
    ) -> AllRowArmRecord {
        AllRowArmRecord(
            format: .human,
            eligible: true,
            sourceBound: true,
            generation: .passed,
            structural: .passed,
            semantic: .passed,
            recovery: .passed,
            payloadTokens: cost?.payloadTokensIncludingHandle,
            handleTokens: cost?.handleTokens,
            abiTokens: cost?.abiTokens,
            effectiveTokens: cost?.effectiveEnvelopeTokens,
            payloadSHA256: cost?.payloadSHA256 ?? sha256Hex(Data(human.utf8)),
            handleSHA256: cost?.handleSHA256,
            abiSHA256: cost?.abiSHA256,
            effectiveEnvelopeSHA256: cost?.effectiveEnvelopeSHA256
                ?? sha256Hex(Data(human.utf8)),
            rejectionReason: nil
        )
    }

    private static func armRecord(
        format: TokenSaverBestOfThreeSelector.Format,
        input: AllRowArmInput,
        decision: TokenSaverBestOfThreeSelector.Decision
    ) -> AllRowArmRecord {
        let receipt = decision.arm(format)
        let cost = decision.cost(format)
        return AllRowArmRecord(
            format: format,
            eligible: receipt?.eligible ?? false,
            sourceBound: receipt?.sourceBound ?? false,
            generation: receipt?.generation ?? .unknown,
            structural: receipt?.structural ?? .unknown,
            semantic: receipt?.semantic ?? .unknown,
            recovery: receipt?.recovery ?? .unknown,
            payloadTokens: cost?.payloadTokensIncludingHandle,
            handleTokens: cost?.handleTokens,
            abiTokens: cost?.abiTokens,
            effectiveTokens: cost?.effectiveEnvelopeTokens,
            payloadSHA256: cost?.payloadSHA256 ?? sha256Hex(Data(input.payload.utf8)),
            handleSHA256: cost?.handleSHA256 ?? input.handle.map { sha256Hex(Data($0.utf8)) },
            abiSHA256: cost?.abiSHA256 ?? sha256Hex(Data(input.abi.utf8)),
            effectiveEnvelopeSHA256: cost?.effectiveEnvelopeSHA256
                ?? sha256Hex(Data(input.envelope.utf8)),
            rejectionReason: rejectionReason(receipt)
        )
    }

    private static func rejectionReason(
        _ receipt: TokenSaverBestOfThreeSelector.ArmReceipt?
    ) -> String? {
        guard let receipt, !receipt.eligible else { return nil }
        if !receipt.sourceBound { return "source_unbound" }
        if receipt.generation == .failed { return "generation" }
        if receipt.structural != .passed { return "structural" }
        if receipt.semantic != .passed { return "semantic" }
        if receipt.recovery != .passed { return "recovery" }
        return "ineligible"
    }

    static func report(
        surface: AllRowSurface,
        rows: [AllRowRuntimeRow]
    ) -> AllRowRuntimeReport {
        let quality = rows.first?.counterQuality ?? "absent"
        return AllRowRuntimeReport(
            schemaVersion: schemaVersion,
            surface: surface,
            codec: "human-rcw1-rcs1",
            billingClaim: false,
            methodology: AllRowRuntimeMethodology(
                scope: "all-frozen-runtime-arms",
                quality: quality,
                counterID: rows.first?.counterID ?? "",
                counterRevision: rows.first?.counterRevision ?? "",
                counterEncoding: rows.first?.counterEncoding ?? "",
                billingClaim: false,
                providerReportedTokens: false,
                rcs1Rule: "RCS1 is RemoteCodeCompactSpan.encode(canonical Human); never encode(RCW1)",
                rcw1Rule: "RCW1 is derived from the same Human, never from RCS1",
                rankingRule: "TokenSaverBestOfThreeSelector: gates before cost, unique strict minimum below Human; Human on tie/error/absent counter/uncertainty",
                effectiveCostRule: "payload + handle already in payload + unamortized ABI counted once; Human uses the comparable Human envelope",
                cavemanRule: "Caveman is opt-in benchmark provenance only and is not a runtime arm or chosen format"
            ),
            rows: rows,
            totals: AllRowRuntimeTotals(rows: rows)
        )
    }
}

private struct AllRowArmRecord: Encodable, Equatable {
    let format: TokenSaverBestOfThreeSelector.Format
    let eligible: Bool
    let sourceBound: Bool
    let generation: TokenSaverBestOfThreeSelector.GateStatus
    let structural: TokenSaverBestOfThreeSelector.GateStatus
    let semantic: TokenSaverBestOfThreeSelector.GateStatus
    let recovery: TokenSaverBestOfThreeSelector.GateStatus
    let payloadTokens: Int?
    let handleTokens: Int?
    let abiTokens: Int?
    let effectiveTokens: Int?
    let payloadSHA256: String?
    let handleSHA256: String?
    let abiSHA256: String?
    let effectiveEnvelopeSHA256: String?
    let rejectionReason: String?

    enum CodingKeys: String, CodingKey {
        case format, eligible, generation, structural, semantic, recovery
        case sourceBound = "source_bound"
        case payloadTokens = "payload_tokens"
        case handleTokens = "handle_tokens"
        case abiTokens = "abi_tokens"
        case effectiveTokens = "effective_tokens"
        case payloadSHA256 = "payload_sha256"
        case handleSHA256 = "handle_sha256"
        case abiSHA256 = "abi_sha256"
        case effectiveEnvelopeSHA256 = "effective_envelope_sha256"
        case rejectionReason = "rejection_reason"
    }
}

private struct AllRowRuntimeRow: Encodable, Equatable {
    let id: String
    let surface: AllRowSurface
    let selectedFormat: TokenSaverBestOfThreeSelector.Format
    let reason: TokenSaverBestOfThreeSelector.Reason
    let modeledContextDelta: Int
    let provenSavingsTokens: Int
    let billingClaim: Bool
    let providerReportedTokens: Bool
    let counterQuality: String
    let counterID: String
    let counterRevision: String
    let counterEncoding: String
    let human: AllRowArmRecord
    let rcw1: AllRowArmRecord
    let rcs1: AllRowArmRecord
    let cavemanTokens: Int?
    let cavemanSHA256: String?

    enum CodingKeys: String, CodingKey {
        case id, surface, reason, human, rcw1, rcs1
        case selectedFormat = "selected_format"
        case modeledContextDelta = "modeled_context_delta"
        case provenSavingsTokens = "proven_savings_tokens"
        case billingClaim = "billing_claim"
        case providerReportedTokens = "provider_reported_tokens"
        case counterQuality = "counter_quality"
        case counterID = "counter_id"
        case counterRevision = "counter_revision"
        case counterEncoding = "counter_encoding"
        case cavemanTokens = "caveman_tokens"
        case cavemanSHA256 = "caveman_sha256"
    }
}

private struct AllRowRuntimeTotals: Encodable, Equatable {
    let rows: Int
    let humanFailOpenRows: Int
    let rcw1Rows: Int
    let rcs1Rows: Int
    let uniqueStrictMinimumRows: Int
    let provenSavingsTokens: Int
    let failOpenReasons: [String: Int]

    init(rows source: [AllRowRuntimeRow]) {
        rows = source.count
        humanFailOpenRows = source.filter { $0.selectedFormat == .human }.count
        rcw1Rows = source.filter { $0.selectedFormat == .rcw1 }.count
        rcs1Rows = source.filter { $0.selectedFormat == .rcs1 }.count
        uniqueStrictMinimumRows = source.filter { $0.reason == .uniqueStrictMinimum }.count
        provenSavingsTokens = source.reduce(0) { $0 + $1.provenSavingsTokens }
        failOpenReasons = Dictionary(
            source.filter { $0.selectedFormat == .human }.map { ($0.reason.rawValue, 1) },
            uniquingKeysWith: +
        )
    }

    enum CodingKeys: String, CodingKey {
        case rows
        case humanFailOpenRows = "human_fail_open_rows"
        case rcw1Rows = "rcw1_rows"
        case rcs1Rows = "rcs1_rows"
        case uniqueStrictMinimumRows = "unique_strict_minimum_rows"
        case provenSavingsTokens = "proven_savings_tokens"
        case failOpenReasons = "fail_open_reasons"
    }
}

private struct AllRowRuntimeMethodology: Encodable, Equatable {
    let scope: String
    let quality: String
    let counterID: String
    let counterRevision: String
    let counterEncoding: String
    let billingClaim: Bool
    let providerReportedTokens: Bool
    let rcs1Rule: String
    let rcw1Rule: String
    let rankingRule: String
    let effectiveCostRule: String
    let cavemanRule: String

    enum CodingKeys: String, CodingKey {
        case scope, quality
        case counterID = "counter_id"
        case counterRevision = "counter_revision"
        case counterEncoding = "counter_encoding"
        case billingClaim = "billing_claim"
        case providerReportedTokens = "provider_reported_tokens"
        case rcs1Rule = "rcs1_rule"
        case rcw1Rule = "rcw1_rule"
        case rankingRule = "ranking_rule"
        case effectiveCostRule = "effective_cost_rule"
        case cavemanRule = "caveman_rule"
    }
}

private enum AllRowSurface: String, Encodable, Equatable {
    case request, response
}

private struct AllRowPublicationContext: Equatable {
    let remoteCodeHead: String
    let workspaceClean: Bool
    let runnerSourceSHA256: String
}

private enum AllRowEvidenceBinding: String, Encodable, Equatable {
    case derivedCanonicalInputs = "derived_canonical_inputs"
    case unitTestExplicit = "unit_test_explicit"
}

private struct AllRowCavemanProvenance: Encodable, Equatable {
    let scope: String
    let request: CavemanBenchmarkProvenance

    static let requestBenchmarkObservations = AllRowCavemanProvenance(
        scope: "request_benchmark_observations",
        request: benchmarkPinnedCavemanProvenance
    )
}

private struct AllRowRuntimeReport: Encodable {
    let schemaVersion: Int
    let surface: AllRowSurface
    let codec: String
    let billingClaim: Bool
    let methodology: AllRowRuntimeMethodology
    let rows: [AllRowRuntimeRow]
    let totals: AllRowRuntimeTotals

    enum CodingKeys: String, CodingKey {
        case surface, codec, methodology, rows, totals
        case schemaVersion = "schema_version"
        case billingClaim = "billing_claim"
    }

    func jsonObject() throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw benchmarkError("all-row JSON is not an object")
        }
        return object
    }

    var csv: String {
        let header = allRowCSVHeader
        let body = rows.map { allRowCSVFields(recordType: "row", row: $0, totals: nil) }
        let total = allRowCSVFields(
            recordType: "totals", row: nil, totals: totals, totalsSurface: surface.rawValue
        )
        return ([header] + body + [total]).map { $0.map(csvField).joined(separator: ",") }
            .joined(separator: "\n") + "\n"
    }
}

private struct AllRowCheckpointCounter: Encodable, Equatable {
    let id: String
    let revision: String
    let encoding: String
    let quality: String
}

private struct AllRowCheckpointProvenance: Encodable, Equatable {
    let requestCorpusSHA256: String
    let responseCorpusSHA256: String
    let semanticContractSHA256: String
    let sourcePromptSHA256: String
    let runnerSourceSHA256: String
    let remoteCodeHead: String
    let workspaceClean: Bool
    let exactCounterSourceSHA256: String
    let measurementArtifactSHA256: String
    let evidenceBinding: AllRowEvidenceBinding
    let caveman: AllRowCavemanProvenance

    enum CodingKeys: String, CodingKey {
        case caveman
        case requestCorpusSHA256 = "request_corpus_sha256"
        case responseCorpusSHA256 = "response_corpus_sha256"
        case semanticContractSHA256 = "semantic_contract_sha256"
        case sourcePromptSHA256 = "source_prompt_sha256"
        case runnerSourceSHA256 = "runner_source_sha256"
        case remoteCodeHead = "remote_code_head"
        case workspaceClean = "workspace_clean"
        case exactCounterSourceSHA256 = "exact_counter_source_sha256"
        case measurementArtifactSHA256 = "measurement_artifact_sha256"
        case evidenceBinding = "evidence_binding"
    }

    static func bind(
        exactCounterSourceSHA256: String,
        measurementArtifactSHA256: String,
        evidenceBinding: AllRowEvidenceBinding,
        publicationContext: AllRowPublicationContext
    ) throws -> AllRowCheckpointProvenance {
        AllRowCheckpointProvenance(
            requestCorpusSHA256: sha256Hex(try Data(contentsOf: allRowRequestCorpusURL())),
            responseCorpusSHA256: sha256Hex(try Data(contentsOf: allRowResponseCorpusURL())),
            semanticContractSHA256: frozenResponseSemanticContractSHA256,
            sourcePromptSHA256: frozenNominalSourcePromptSHA256,
            runnerSourceSHA256: try allRowRequireContentFreeSHA256(
                publicationContext.runnerSourceSHA256, label: "runner source"
            ),
            remoteCodeHead: publicationContext.remoteCodeHead,
            workspaceClean: publicationContext.workspaceClean,
            exactCounterSourceSHA256: try allRowRequireContentFreeSHA256(
                exactCounterSourceSHA256, label: "exact counter executable"
            ),
            measurementArtifactSHA256: try allRowRequireContentFreeSHA256(
                measurementArtifactSHA256, label: "measurement artifact"
            ),
            evidenceBinding: evidenceBinding,
            caveman: .requestBenchmarkObservations
        )
    }
}

private struct AllRowCheckpointTotals: Encodable, Equatable {
    let request: AllRowRuntimeTotals
    let response: AllRowRuntimeTotals
    let overall: AllRowRuntimeTotals
}

private struct AllRowCheckpointReport: Encodable {
    let schemaVersion: Int
    let codec: String
    let billingClaim: Bool
    let methodology: AllRowRuntimeMethodology
    let counter: AllRowCheckpointCounter
    let provenance: AllRowCheckpointProvenance
    let rows: [AllRowRuntimeRow]
    let totals: AllRowCheckpointTotals

    enum CodingKeys: String, CodingKey {
        case codec, methodology, counter, provenance, rows, totals
        case schemaVersion = "schema_version"
        case billingClaim = "billing_claim"
    }

    func jsonObject() throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw benchmarkError("all-row JSON is not an object")
        }
        return object
    }

    var csv: String {
        let header = allRowCSVHeader
        let body = rows.map {
            allRowCSVFields(recordType: "row", row: $0, totals: nil, provenance: provenance)
        }
        let totalsLines = [
            allRowCSVFields(
                recordType: "totals", row: nil, totals: totals.request,
                totalsSurface: "request", provenance: provenance
            ),
            allRowCSVFields(
                recordType: "totals", row: nil, totals: totals.response,
                totalsSurface: "response", provenance: provenance
            ),
            allRowCSVFields(
                recordType: "totals", row: nil, totals: totals.overall,
                totalsSurface: "overall", provenance: provenance
            ),
        ]
        return ([header] + body + totalsLines).map { $0.map(csvField).joined(separator: ",") }
            .joined(separator: "\n") + "\n"
    }
}

private let allRowArmCSVFields = [
    "eligible", "source_bound", "generation", "structural", "semantic", "recovery",
    "payload_tokens", "handle_tokens", "abi_tokens", "effective_tokens",
    "payload_sha256", "handle_sha256", "abi_sha256", "effective_envelope_sha256",
    "rejection",
]

private let allRowCSVHeader: [String] = {
    let prefix = [
        "record_type", "id", "surface", "selected_format", "reason",
        "billing_claim", "provider_reported_tokens",
        "counter_quality", "counter_id", "counter_revision", "counter_encoding",
        "modeled_context_delta", "proven_savings_tokens",
    ]
    let arms = ["human", "rcw1", "rcs1"].flatMap { arm in
        allRowArmCSVFields.map { "\(arm)_\($0)" }
    }
    return prefix + arms + [
        "caveman_tokens", "caveman_sha256",
        "exact_counter_source_sha256", "measurement_artifact_sha256",
        "human_fail_open_rows", "rcw1_rows", "rcs1_rows", "unique_strict_minimum_rows",
        "rows", "fail_open_reasons",
    ]
}()

private func allRowCSVFields(
    recordType: String,
    row: AllRowRuntimeRow?,
    totals: AllRowRuntimeTotals?,
    totalsSurface: String = "",
    provenance: AllRowCheckpointProvenance? = nil
) -> [String] {
    func tokens(_ value: Int?) -> String { value.map(String.init) ?? "" }
    func arm(_ record: AllRowArmRecord?) -> [String] {
        guard let record else {
            return Array(repeating: "", count: allRowArmCSVFields.count)
        }
        return [
            String(record.eligible), String(record.sourceBound),
            record.generation.rawValue, record.structural.rawValue,
            record.semantic.rawValue, record.recovery.rawValue,
            tokens(record.payloadTokens), tokens(record.handleTokens),
            tokens(record.abiTokens), tokens(record.effectiveTokens),
            record.payloadSHA256 ?? "", record.handleSHA256 ?? "",
            record.abiSHA256 ?? "", record.effectiveEnvelopeSHA256 ?? "",
            record.rejectionReason ?? "",
        ]
    }
    let counterSHA = provenance?.exactCounterSourceSHA256 ?? ""
    let measurementSHA = provenance?.measurementArtifactSHA256 ?? ""
    if let row {
        return [
            recordType, row.id, row.surface.rawValue, row.selectedFormat.rawValue,
            row.reason.rawValue, String(row.billingClaim), String(row.providerReportedTokens),
            row.counterQuality, row.counterID, row.counterRevision, row.counterEncoding,
            String(row.modeledContextDelta), String(row.provenSavingsTokens),
        ]
        + arm(row.human) + arm(row.rcw1) + arm(row.rcs1)
        + [
            tokens(row.cavemanTokens), row.cavemanSHA256 ?? "",
            counterSHA, measurementSHA,
            "", "", "", "", "", "",
        ]
    }
    return [
        recordType, "", totalsSurface, "", "", "false", "false",
        "", "", "", "", "", tokens(totals?.provenSavingsTokens),
    ]
    + Array(repeating: "", count: allRowArmCSVFields.count * 3)
    + [
        "", "",
        counterSHA, measurementSHA,
        tokens(totals?.humanFailOpenRows),
        tokens(totals?.rcw1Rows),
        tokens(totals?.rcs1Rows),
        tokens(totals?.uniqueStrictMinimumRows),
        tokens(totals?.rows),
        allRowFailOpenReasonsField(totals?.failOpenReasons ?? [:]),
    ]
}

private func optionalJSONNumber(_ value: Any?) -> String {
    if let value = value as? Int { return String(value) }
    return ""
}

private func parseAllRowCSVRow(_ line: String) -> [String] {
    var fields: [String] = []
    var current = ""
    var inQuotes = false
    var index = line.startIndex
    while index < line.endIndex {
        let character = line[index]
        if inQuotes {
            if character == "\"" {
                let next = line.index(after: index)
                if next < line.endIndex, line[next] == "\"" {
                    current.append("\"")
                    index = line.index(after: next)
                    continue
                }
                inQuotes = false
            } else {
                current.append(character)
            }
        } else if character == "\"" {
            inQuotes = true
        } else if character == "," {
            fields.append(current)
            current = ""
        } else {
            current.append(character)
        }
        index = line.index(after: index)
    }
    fields.append(current)
    return fields
}

private enum AllRowRecoveryLab {
    static let generousDisk = TokenSaverRecoveryDiskSnapshot(
        freeBytes: 20 * 1_024 * 1_024 * 1_024,
        totalBytes: 100 * 1_024 * 1_024 * 1_024
    )
    static let exhaustedDisk = TokenSaverRecoveryDiskSnapshot(freeBytes: 0, totalBytes: 1)

    static func makeStore() throws -> TokenSaverScopedRecoveryStore {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return TokenSaverScopedRecoveryStore(db: db)
    }

    static func apply(
        _ arm: AllRowArmInput,
        human: String,
        rowID: String,
        arm armName: String,
        store: TokenSaverScopedRecoveryStore,
        disk: TokenSaverRecoveryDiskSnapshot?
    ) -> AllRowArmInput {
        guard arm.recovery == .passed else { return arm }
        let scope = TokenSaverPersistentScope(
            workspaceID: "all-row-report",
            projectID: "language",
            threadID: rowID,
            provider: "local",
            attemptID: armName
        )
        do {
            let original = Data(human.utf8)
            let prepared = try store.prepare(
                original,
                scope: scope,
                operationID: "all-row-\(rowID)-\(armName)",
                expiresAt: nil,
                disk: disk ?? generousDisk
            )
            guard prepared.readBackVerified,
                  prepared.capability.hasPrefix("rcv1.") else {
                return failedRecovery(arm)
            }
            let recovered = try store.retrieve(capability: prepared.capability, scope: scope)
            guard recovered == original else { return failedRecovery(arm) }
            return arm
        } catch {
            return failedRecovery(arm)
        }
    }

    private static func failedRecovery(_ arm: AllRowArmInput) -> AllRowArmInput {
        var copy = arm
        copy.recovery = .failed
        return copy
    }
}

private enum AllRowReportEmitter {
    static let jsonKey = "REMOTE_CODE_RCW1_ALL_ROW_REPORT_JSON"
    static let csvKey = "REMOTE_CODE_RCW1_ALL_ROW_REPORT_CSV"
    static let measurementsKey = "REMOTE_CODE_RCW1_BENCHMARK_MEASUREMENTS"
    static let tokenCounterKey = "REMOTE_CODE_RCW1_BENCHMARK_TOKEN_COUNTER"

    static func plan(environment: [String: String]) throws -> AllRowEmissionPlan? {
        let json = allRowNonempty(environment[jsonKey])
        let csv = allRowNonempty(environment[csvKey])
        let measurements = allRowNonempty(environment[measurementsKey])
        let tokenCounter = allRowNonempty(environment[tokenCounterKey])
        let values = [json, csv, measurements, tokenCounter]
        if values.allSatisfy({ $0 == nil }) { return nil }
        guard let json, let csv, let measurements, let tokenCounter else {
            throw benchmarkError(
                "all-row emitter requires complete JSON/CSV pair, measurements, and exact token counter"
            )
        }
        let jsonPath = try allRowInspectPath(json, mustExist: false, label: "JSON output")
        let csvPath = try allRowInspectPath(csv, mustExist: false, label: "CSV output")
        let measurementPath = try allRowInspectPath(measurements, mustExist: true, label: "measurement artifact")
        let counterPath = try allRowInspectPath(tokenCounter, mustExist: true, label: "token counter")
        let requestFixture = try allRowInspectPath(allRowRequestCorpusURL().path, mustExist: true, label: "request fixture")
        let responseFixture = try allRowInspectPath(allRowResponseCorpusURL().path, mustExist: true, label: "response fixture")
        try allRowRejectAliasOrOverlap([
            ("JSON output", jsonPath),
            ("CSV output", csvPath),
            ("measurement artifact", measurementPath),
            ("token counter", counterPath),
            ("request fixture", requestFixture),
            ("response fixture", responseFixture),
        ])
        guard !jsonPath.exists, !csvPath.exists else {
            throw benchmarkError("all-row outputs must not already exist")
        }
        let output = try ResponseReportOutputBundle(jsonPath: jsonPath.canonical, csvPath: csvPath.canonical)
        var counterEnvironment = [
            tokenCounterKey: counterPath.canonical
        ]
        if let encoding = environment["RCW1_TIKTOKEN_ENCODING"] {
            counterEnvironment["RCW1_TIKTOKEN_ENCODING"] = encoding
        }
        if let pythonPath = environment["PYTHONPATH"] ?? ProcessInfo.processInfo.environment["PYTHONPATH"] {
            counterEnvironment["PYTHONPATH"] = pythonPath
        }
        let counter = try BenchmarkTokenCounter(environment: counterEnvironment)
        _ = try AllRowBestOfThreeHarness.exactCapability(from: counter)
        let measurementURL = URL(fileURLWithPath: measurementPath.canonical)
        guard let counterSHA = counter.sourceSHA256 else {
            throw benchmarkError("all-row emitter requires exact-local-tokenizer executable source SHA-256")
        }
        return AllRowEmissionPlan(
            output: output,
            measurementsURL: measurementURL,
            counter: counter,
            exactCounterSourceSHA256: try allRowRequireContentFreeSHA256(
                counterSHA, label: "exact counter executable"
            ),
            measurementArtifactSHA256: try allRowContentFreeSHA256(
                of: measurementURL, label: "measurement artifact"
            )
        )
    }

    static func write(
        output: ResponseReportOutputBundle,
        report: AllRowCheckpointReport
    ) throws -> AllRowEmissionReceipt {
        try validate(report)
        let json = try allRowJSONData(report)
        let receipt = try output.emit(json: json, csv: report.csv)
        return AllRowEmissionReceipt(
            jsonPath: receipt.jsonPath,
            csvPath: receipt.csvPath,
            exactCounterSourceSHA256: report.provenance.exactCounterSourceSHA256,
            measurementArtifactSHA256: report.provenance.measurementArtifactSHA256
        )
    }

    static func publish(
        plan: AllRowEmissionPlan,
        publicationContext: (() throws -> AllRowPublicationContext)? = nil,
        afterCountingStarted: (() throws -> Void)? = nil
    ) async throws -> AllRowEmissionReceipt {
        let contextProvider = publicationContext ?? AllRowBestOfThreeHarness.livePublicationContext
        let contextAtStart = try contextProvider()
        try AllRowBestOfThreeHarness.validatePublicationContext(contextAtStart)
        try plan.counter.validateSourceSHA256()
        let boundCounterSHA = try allRowRequireContentFreeSHA256(
            plan.exactCounterSourceSHA256, label: "exact counter executable"
        )
        guard plan.counter.sourceSHA256 == boundCounterSHA else {
            throw benchmarkError("exact counter executable source SHA-256 drifted")
        }
        let measurementData = try Data(contentsOf: plan.measurementsURL)
        let boundMeasurementSHA = try allRowRequireContentFreeSHA256(
            sha256Hex(measurementData), label: "measurement artifact"
        )
        guard boundMeasurementSHA == plan.measurementArtifactSHA256 else {
            throw benchmarkError("measurement artifact SHA-256 drifted")
        }
        let hook = afterCountingStarted.map(AllRowOnceHook.init)
        _ = try AllRowBestOfThreeHarness.exactCapability(from: plan.counter)
        let gated = TokenSaverBestOfThreeSelector.CounterCapability(
            counter: .init(
                id: plan.counter.diagnostic.name,
                revision: plan.counter.diagnostic.version,
                encoding: plan.counter.diagnostic.encoding,
                provider: "local",
                resolvedModel: "local-exact",
                quality: .exactLocalTokenizer
            ),
            count: { text in
                try hook?.fire()
                return try plan.counter.count(text)
            }
        )
        let measurements = try JSONDecoder().decode(
            MeasuredBenchmarkRun.self,
            from: measurementData
        )
        let recoveryStore = try AllRowRecoveryLab.makeStore()
        let requestReport = try await AllRowBestOfThreeHarness.requestReport(
            corpus: try JSONDecoder().decode(
                [EfficiencyCase].self,
                from: Data(contentsOf: allRowRequestCorpusURL())
            ),
            measurements: measurements,
            capability: gated,
            recoveryStore: recoveryStore
        )
        let responseCorpus = try JSONDecoder().decode(
            [ResponseEfficiencyCase].self,
            from: Data(contentsOf: allRowResponseCorpusURL())
        )
        let responseMeasurements = try responseCorpus.map { item in
            ResponseBenchmarkMeasurement(
                id: item.id,
                human: item.humanBaseline,
                wire: try item.serializedWire(),
                caveman: .init(
                    output: item.humanBaseline,
                    handleBehavior: .passThroughNoHandle
                )
            )
        }
        let responseReport = try await AllRowBestOfThreeHarness.responseReport(
            corpus: responseCorpus,
            measurements: responseMeasurements,
            capability: gated,
            recoveryStore: recoveryStore
        )
        try plan.counter.validateSourceSHA256()
        guard plan.counter.sourceSHA256 == boundCounterSHA else {
            throw benchmarkError("exact counter executable source SHA-256 drifted")
        }
        let measurementSHAAfter = try allRowContentFreeSHA256(
            of: plan.measurementsURL, label: "measurement artifact"
        )
        guard measurementSHAAfter == boundMeasurementSHA else {
            throw benchmarkError("measurement artifact SHA-256 drifted")
        }
        let contextAfter = try contextProvider()
        try AllRowBestOfThreeHarness.validatePublicationContext(contextAfter)
        guard contextAfter == contextAtStart else {
            throw benchmarkError("all-row publication context drifted")
        }
        let checkpoint = try AllRowBestOfThreeHarness.checkpoint(
            request: requestReport,
            response: responseReport,
            exactCounterSourceSHA256: boundCounterSHA,
            measurementArtifactSHA256: boundMeasurementSHA,
            evidenceBinding: .derivedCanonicalInputs,
            publicationContext: contextAfter
        )
        return try write(output: plan.output, report: checkpoint)
    }

    private static func validate(_ report: AllRowCheckpointReport) throws {
        guard report.schemaVersion == AllRowBestOfThreeHarness.schemaVersion else {
            throw benchmarkError("all-row emitter requires schema 6")
        }
        let requestRows = report.rows.filter { $0.surface == .request }
        let responseRows = report.rows.filter { $0.surface == .response }
        guard requestRows.count == 24, responseRows.count == 10, report.rows.count == 34 else {
            throw benchmarkError("all-row checkpoint requires the frozen 24-row and 10-row corpora")
        }
        guard requestRows.map(\.id) == frozenRequestCorpusIDs,
              responseRows.map(\.id) == frozenResponseCorpusIDs else {
            throw benchmarkError("all-row checkpoint requires the frozen corpus ID order")
        }
        guard report.billingClaim == false, report.methodology.billingClaim == false,
              report.methodology.providerReportedTokens == false else {
            throw benchmarkError("all-row emitter forbids billing or provider token claims")
        }
        guard report.methodology.quality == AllRowBestOfThreeHarness.localExactQuality,
              report.counter.quality == AllRowBestOfThreeHarness.localExactQuality,
              report.rows.allSatisfy({ $0.counterQuality == AllRowBestOfThreeHarness.localExactQuality }) else {
            throw benchmarkError("all-row write requires local_exact quality")
        }
        for row in report.rows {
            guard row.human.format == .human, row.rcw1.format == .rcw1, row.rcs1.format == .rcs1 else {
                throw benchmarkError("all-row JSON+CSV must keep Human/RCW1/RCS1 visible")
            }
            guard row.selectedFormat.rawValue != "caveman" else {
                throw benchmarkError("Caveman is never selected_format")
            }
            guard row.billingClaim == false, row.providerReportedTokens == false else {
                throw benchmarkError("all-row emitter forbids billing or provider token claims")
            }
        }
        guard report.totals.request.rows == 24, report.totals.response.rows == 10,
              report.totals.overall.rows == 34 else {
            throw benchmarkError("all-row checkpoint totals must cover request, response, and overall")
        }
        _ = try allRowRequireContentFreeSHA256(
            report.provenance.exactCounterSourceSHA256, label: "exact counter executable"
        )
        _ = try allRowRequireContentFreeSHA256(
            report.provenance.measurementArtifactSHA256, label: "measurement artifact"
        )
        if report.provenance.evidenceBinding == .derivedCanonicalInputs,
           report.provenance.exactCounterSourceSHA256 == allRowUnitTestCounterSourceSHA256
            || report.provenance.measurementArtifactSHA256 == allRowUnitTestMeasurementArtifactSHA256 {
            throw benchmarkError("derived all-row provenance must not use unit-test-explicit digests")
        }
        guard report.provenance.caveman.scope == "request_benchmark_observations",
              report.provenance.caveman.request == benchmarkPinnedCavemanProvenance else {
            throw benchmarkError("all-row Caveman provenance must be request-benchmark observations")
        }
        guard responseRows.allSatisfy({ $0.cavemanSHA256 == nil && $0.cavemanTokens == nil }) else {
            throw benchmarkError("all-row response rows must not claim Caveman ran")
        }
        try AllRowBestOfThreeHarness.validatePublicationContext(
            AllRowPublicationContext(
                remoteCodeHead: report.provenance.remoteCodeHead,
                workspaceClean: report.provenance.workspaceClean,
                runnerSourceSHA256: report.provenance.runnerSourceSHA256
            )
        )
    }
}

private struct AllRowEmissionPlan {
    let output: ResponseReportOutputBundle
    let measurementsURL: URL
    let counter: BenchmarkTokenCounter
    let exactCounterSourceSHA256: String
    let measurementArtifactSHA256: String
}

private struct AllRowEmissionReceipt {
    let jsonPath: String
    let csvPath: String
    let exactCounterSourceSHA256: String
    let measurementArtifactSHA256: String
}

private final class AllRowP1BPublicationContext: @unchecked Sendable {
    var remoteCodeHead: String
    var workspaceClean: Bool
    var runnerSourceSHA256: String

    init(remoteCodeHead: String, workspaceClean: Bool, runnerSourceSHA256: String) {
        self.remoteCodeHead = remoteCodeHead
        self.workspaceClean = workspaceClean
        self.runnerSourceSHA256 = runnerSourceSHA256
    }

    func snapshot() -> AllRowPublicationContext {
        AllRowPublicationContext(
            remoteCodeHead: remoteCodeHead,
            workspaceClean: workspaceClean,
            runnerSourceSHA256: runnerSourceSHA256
        )
    }
}

private final class AllRowP1BEvidence: @unchecked Sendable {
    let tokenizerURL: URL
    let measurementsURL: URL
    let jsonURL: URL
    let csvURL: URL
    let bundleURL: URL
    let context: AllRowP1BPublicationContext

    init(
        tokenizerURL: URL,
        measurementsURL: URL,
        jsonURL: URL,
        csvURL: URL,
        bundleURL: URL,
        context: AllRowP1BPublicationContext
    ) {
        self.tokenizerURL = tokenizerURL
        self.measurementsURL = measurementsURL
        self.jsonURL = jsonURL
        self.csvURL = csvURL
        self.bundleURL = bundleURL
        self.context = context
    }
}

private final class AllRowOnceHook: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let hook: () throws -> Void

    init(_ hook: @escaping () throws -> Void) {
        self.hook = hook
    }

    func fire() throws {
        lock.lock()
        let shouldRun = !fired
        if shouldRun { fired = true }
        lock.unlock()
        if shouldRun { try hook() }
    }
}

private struct AllRowPathInspection: Equatable {
    let raw: String
    let canonical: String
    let exists: Bool
    let device: dev_t
    let inode: ino_t
    let caseSensitive: Bool
}

private func allRowNonempty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

private func allRowJSONData(_ report: AllRowCheckpointReport) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(report)
}

private func allRowInspectPath(
    _ path: String,
    mustExist: Bool,
    label: String
) throws -> AllRowPathInspection {
    guard !path.contains("\0"), path.hasPrefix("/") else {
        throw benchmarkError("all-row \(label) must be an absolute path")
    }
    let standardized = URL(fileURLWithPath: path).standardizedFileURL
    var linkStatus = stat()
    if lstat(standardized.path, &linkStatus) == 0, (linkStatus.st_mode & S_IFMT) == S_IFLNK {
        throw benchmarkError("all-row \(label) must not be a symlink")
    }
    if mustExist {
        guard FileManager.default.fileExists(atPath: standardized.path) else {
            throw benchmarkError("all-row \(label) does not exist")
        }
        guard let resolved = realpath(standardized.path, nil) else {
            throw benchmarkError("all-row \(label) cannot be resolved")
        }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        var status = stat()
        guard lstat(canonical, &status) == 0, (status.st_mode & S_IFMT) != S_IFLNK else {
            throw benchmarkError("all-row \(label) must not be a symlink")
        }
        return AllRowPathInspection(
            raw: path,
            canonical: canonical,
            exists: true,
            device: status.st_dev,
            inode: status.st_ino,
            caseSensitive: allRowPathIsCaseSensitive(canonical)
        )
    }
    let bundle = standardized.deletingLastPathComponent()
    let ancestor = bundle.deletingLastPathComponent()
    guard let resolvedAncestor = realpath(ancestor.path, nil) else {
        throw benchmarkError("all-row \(label) ancestor cannot be resolved")
    }
    defer { free(resolvedAncestor) }
    let ancestorPath = String(cString: resolvedAncestor)
    var ancestorLink = stat()
    if lstat(ancestorPath, &ancestorLink) == 0, (ancestorLink.st_mode & S_IFMT) == S_IFLNK {
        throw benchmarkError("all-row \(label) must not be a symlink")
    }
    let canonical = URL(fileURLWithPath: ancestorPath)
        .appendingPathComponent(bundle.lastPathComponent)
        .appendingPathComponent(standardized.lastPathComponent).path
    var existing = stat()
    let exists = lstat(canonical, &existing) == 0
    if exists, (existing.st_mode & S_IFMT) == S_IFLNK {
        throw benchmarkError("all-row \(label) must not be a symlink")
    }
    return AllRowPathInspection(
        raw: path,
        canonical: canonical,
        exists: exists,
        device: exists ? existing.st_dev : 0,
        inode: exists ? existing.st_ino : 0,
        caseSensitive: allRowPathIsCaseSensitive(ancestorPath)
    )
}

private func allRowPathIsCaseSensitive(_ path: String) -> Bool {
    let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { return true }
    defer { _ = Darwin.close(fd) }
    return Darwin.fpathconf(fd, _PC_CASE_SENSITIVE) == 1
}

private func allRowRejectAliasOrOverlap(_ items: [(String, AllRowPathInspection)]) throws {
    for index in items.indices {
        for other in (index + 1)..<items.count {
            if allRowSamePath(items[index].1, items[other].1) {
                throw benchmarkError(
                    "all-row \(items[index].0) aliases or overlaps \(items[other].0)"
                )
            }
        }
    }
}

private func allRowSamePath(_ lhs: AllRowPathInspection, _ rhs: AllRowPathInspection) -> Bool {
    if lhs.exists, rhs.exists, lhs.device == rhs.device, lhs.inode == rhs.inode {
        return true
    }
    let sensitive = lhs.caseSensitive && rhs.caseSensitive
    if sensitive {
        return lhs.canonical == rhs.canonical
    }
    return lhs.canonical.folding(options: [.caseInsensitive], locale: nil)
        == rhs.canonical.folding(options: [.caseInsensitive], locale: nil)
}
