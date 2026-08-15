import AgentRuntime
import CryptoKit
import Darwin
import Foundation
import XCTest
import CoreModel
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
        let nominal = try XCTUnwrap(cases.first { $0.id == "reported-disposable-workspace-answer" })
        XCTAssertTrue(nominal.humanBaseline.hasPrefix("A disposable local workspace improves software testing"))
        XCTAssertFalse(nominal.humanBaseline.contains("Explain in one short"))
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
            frames: one.frames, humanBaseline: one.humanBaseline + " changed")
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
        XCTAssertEqual(report.schemaVersion, 4)
        XCTAssertEqual(report.codec, "rcw1-v1")
        XCTAssertEqual(report.corpusSHA256, frozenResponseCorpusSHA256)
        XCTAssertEqual(report.runnerSourceSHA256, try responseRunnerSourceSHA256())
        XCTAssertEqual(report.counterSourceSHA256, counter.sourceSHA256)
        XCTAssertFalse(report.methodology.providerReportedTokens)
        XCTAssertFalse(report.methodology.providerBound)
        XCTAssertTrue(report.methodology.abiCountedOncePerRow)
        XCTAssertEqual(report.rows.count, 10)
        XCTAssertTrue(report.rows.allSatisfy { $0.cavemanSHA256.count == 64 })
        let csvLines = report.csv.split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(csvLines.count, 12, "header + 10 all-row records + one totals record")
        XCTAssertEqual(csvLines.filter { $0.hasPrefix("row,") }.count, 10)
        XCTAssertEqual(csvLines.filter { $0.hasPrefix("row,") }.map {
            String($0.split(separator: ",")[1])
        }, report.rows.map(\.id))
        XCTAssertTrue(csvLines.last?.hasPrefix("totals,") == true)
        XCTAssertEqual(csvLines.first?.split(separator: ",").count,
                       csvLines.last?.split(separator: ",", omittingEmptySubsequences: false).count)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: responseJSONData(report)) as? [String: Any])
        XCTAssertEqual(json["schema_version"] as? Int, 4)
        XCTAssertEqual((json["rows"] as? [[String: Any]])?.count, 10)
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
            provenance: provenance)
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
        provenance: CavemanBenchmarkProvenance = benchmarkPinnedCavemanProvenance
    ) throws -> ResponseBenchmarkReport {
        try ResponseBenchmarkHarness.build(
            corpusData: corpusData, measurements: measurements,
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
              humanBaseline: outcome)
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

private let frozenResponseCorpusSHA256 = "35b3722d6a58e593a2770a6d727e5796fbd7e80c9f8aa90f013ed7c691537029"
private let frozenResponseCorpusIDs = [
    "short-ok", "reported-disposable-workspace-answer", "multi-record-all-kinds",
    "progressive-multiframe", "exact-code-path", "portuguese-natural", "japanese-natural",
    "arabic-natural", "repeated-evidence-template", "opaque-incompressible",
]
private let exactTokenDiagnostic = TokenCounterDiagnostic(
    name: "response-unit", version: "1", encoding: "fixture-exact",
    measurementKind: "exact-local-tokenizer")

private struct ResponseEfficiencyCase: Decodable {
    let id, category, language: String
    let frames: [ResponseLogicalFrame]
    let humanBaseline: String
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
        case humanBaseline = "human_baseline" }
}
private struct ResponseLogicalFrame: Decodable {
    let sequence: Int; let records: [ResponseLogicalRecord] }
private struct ResponseLogicalRecord: Decodable {
    let kind: RCWireRecordKind; let value: String }
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
        remoteCodeHead: String, runnerSourceSHA256: String,
        cavemanProvenance: CavemanBenchmarkProvenance,
        counter: BenchmarkTokenCounter) throws -> ResponseBenchmarkReport {
        let corpusSHA256 = sha256Hex(corpusData)
        guard corpusSHA256 == frozenResponseCorpusSHA256 else {
            throw benchmarkError("report requires the frozen response corpus bytes")
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
        return .init(
            schemaVersion: 4, codec: "rcw1-v1", corpusSHA256: corpusSHA256,
            remoteCodeHead: remoteCodeHead, runnerSourceSHA256: runnerSourceSHA256,
            counterSourceSHA256: counterSourceSHA256,
            tokenCounter: counter.diagnostic, methodology: .init(),
            cavemanProvenance: cavemanProvenance, rows: evaluated.rows, totals: evaluated.totals)
    }
    static func evaluateRowsForUnitTest(corpus: [ResponseEfficiencyCase],
        measurements: [ResponseBenchmarkMeasurement], counter: BenchmarkTokenCounter
    ) throws -> (rows: [ResponseBenchmarkRow], totals: ResponseBenchmarkTotals) {
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
                                                 abiTokens: abiTokens, count: stableCount) }
        return (rows, ResponseBenchmarkTotals(rows: rows))
    }
    private static func evaluate(item: ResponseEfficiencyCase,
        measurement: ResponseBenchmarkMeasurement, abiTokens: Int,
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
            decision: decision, humanTokens: human, candidateFrameTokens: frame,
            candidateVsHumanPPM: ratioPPM(frame, human), abiTokens: abiTokens,
            candidateEffectiveTokens: effective,
            effectiveDeliveredTokens: decision == .rcw1 ? effective : human, cavemanTokens: caveman,
            cavemanRecoveryHandlePresent: measurement.caveman.handleBehavior == .changedWithVerifiedHandle,
            disqualificationReasons: reasons,
            claimedSavedTokensVsHuman: decision == .rcw1 ? human - effective : 0,
            claimedSavedTokensVsCaveman: decision == .rcw1 ? caveman - effective : 0)
    }
}

private struct ResponseBenchmarkReport: Encodable {
    let schemaVersion: Int; let codec, corpusSHA256, remoteCodeHead: String
    let runnerSourceSHA256, counterSourceSHA256: String
    let tokenCounter: TokenCounterDiagnostic; let methodology: ResponseBenchmarkMethodology
    let cavemanProvenance: CavemanBenchmarkProvenance
    let rows: [ResponseBenchmarkRow]; let totals: ResponseBenchmarkTotals
    var csv: String {
        let header = [
            "record_type", "id", "decision", "human_sha256", "candidate_frame_sha256", "caveman_sha256",
            "human_tokens", "candidate_frame_tokens", "candidate_vs_human_ppm", "abi_tokens",
            "candidate_effective_tokens", "effective_delivered_tokens", "caveman_tokens",
            "claimed_saved_tokens_vs_human", "claimed_saved_tokens_vs_caveman",
            "caveman_recovery_handle_present", "disqualification_reasons", "row_count",
            "qualified_rows", "disqualified_rows", "failure_counts",
        ]
        let body = rows.map { row in
            [
                "row", row.id, row.decision.rawValue, row.humanSHA256, row.candidateFrameSHA256,
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
            "totals", "", "", "", "", "", String(totals.humanTokens), String(totals.candidateFrameTokens),
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
    let qualificationRule = "complete frame <=45% Human; frame + one ABI < Human and pinned Caveman"
}
private struct ResponseBenchmarkRow: Encodable {
    let id, humanSHA256, candidateFrameSHA256, cavemanSHA256: String
    let decision: ResponseBenchmarkDecision; let humanTokens, candidateFrameTokens: Int
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
        let diagnosticData = try Self.invoke(executable: executable, argument: "--diagnostic", input: Data())
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
                input: Data(text.utf8)
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

    private static func invoke(executable: String, argument: String, input: Data) throws -> Data {
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [argument]
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
            try buildRow(
                item: item,
                measured: measuredByID[item.id]!,
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

    private static func buildRow(
        item: EfficiencyCase,
        measured: MeasuredBenchmarkRow,
        abiTokens: Int,
        counter: BenchmarkTokenCounter
    ) throws -> BenchmarkReportRow {
        let humanTokens = try counter.count(item.effectiveHuman)
        guard !measured.cavemanOutput.isEmpty else {
            throw benchmarkError("\(item.id) is missing measured Caveman output")
        }
        let cavemanTokens = try counter.count(measured.cavemanOutput)
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
            let protectedSemantics = RCWireProtocol.preservesProtectedSemantics(
                original: item.effectiveHuman,
                wire: measured.deliveredPayload
            )
            let exactAtoms = item.requiredExact.allSatisfy(candidateValues.contains)
            guard protectedSemantics && exactAtoms else {
                throw benchmarkError("\(item.id) RCW1 decision failed literal_gate")
            }
            let requestMeaning = RCWireProtocol.preservesRequestMeaning(
                original: item.effectiveHuman,
                wire: measured.deliveredPayload
            )
            guard requestMeaning else {
                throw benchmarkError("\(item.id) RCW1 decision failed semantic_gate")
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
            guard measured.recoveryHandle == nil else {
                throw benchmarkError("\(item.id) human_fail_open must not carry a recovery handle")
            }
            guard measured.deliveredPayload == item.effectiveHuman else {
                throw benchmarkError("\(item.id) human_fail_open must deliver byte-identical Human")
            }
            if reason == .belowFloor,
               TokenEstimator.estimate(item.effectiveHuman) >= 80 {
                throw benchmarkError("\(item.id) below_floor reason does not match the production floor")
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
