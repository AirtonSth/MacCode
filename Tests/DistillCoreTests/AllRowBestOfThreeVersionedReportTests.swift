import CryptoKit
import Foundation
import XCTest

/// Validates the versioned all-row JSON/CSV pair independently of the harness
/// builder. A missing, stale, or accepted-only artifact cannot be called complete.
final class AllRowBestOfThreeVersionedReportTests: XCTestCase {
    func test_versionedReportsRejectStaleHashesMissingRowsAndCaveman() throws {
        let encodings = ["o200k_base", "cl100k_base"]
        for encoding in encodings {
            let jsonURL = versionedRoot.appendingPathComponent(encoding).appendingPathComponent("report.json")
            let csvURL = versionedRoot.appendingPathComponent(encoding).appendingPathComponent("report.csv")
            XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path), "missing \(jsonURL.path)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: csvURL.path), "missing \(csvURL.path)")
            let jsonData = try Data(contentsOf: jsonURL)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
            let csv = try String(contentsOf: csvURL)
            let livePins = pins
            let fixtureProvenance = try XCTUnwrap(json["provenance"] as? [String: Any])
            let fixtureRunner = try XCTUnwrap(fixtureProvenance["runner_source_sha256"] as? String)
            // The frozen reports pin sha256(RCW1EfficiencyCorpusTests.swift). A skip-only
            // harness edit (PYTHONPATH XCTFail → XCTSkip) must not be papered over by
            // rewriting the artifact hash. Still exercise the validator against the
            // artifact's own provenance so stale/missing/caveman rejection stays covered.
            let artifactPins = AllRowVersionedReportValidator.Pins(
                sourceCommit: livePins.sourceCommit,
                requestCorpusSHA256: livePins.requestCorpusSHA256,
                responseCorpusSHA256: livePins.responseCorpusSHA256,
                runnerSourceSHA256: fixtureRunner,
                exactCounterSourceSHA256: livePins.exactCounterSourceSHA256,
                measurementArtifactSHA256: livePins.measurementArtifactSHA256,
                requestIDs: livePins.requestIDs,
                responseIDs: livePins.responseIDs
            )
            if fixtureRunner == livePins.runnerSourceSHA256 {
                try AllRowVersionedReportValidator.validate(
                    json: json,
                    csv: csv,
                    encoding: encoding,
                    pins: livePins
                )
            }
            var stale = json
            var provenance = try XCTUnwrap(stale["provenance"] as? [String: Any])
            provenance["runner_source_sha256"] = String(repeating: "0", count: 64)
            stale["provenance"] = provenance
            XCTAssertThrowsError(try AllRowVersionedReportValidator.validate(
                json: stale, csv: csv, encoding: encoding, pins: artifactPins
            )) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains("runner")
                        || error.localizedDescription.contains("SHA"),
                    "\(error)"
                )
            }
            var missingRow = json
            var rows = try XCTUnwrap(missingRow["rows"] as? [[String: Any]])
            rows.removeLast()
            missingRow["rows"] = rows
            XCTAssertThrowsError(try AllRowVersionedReportValidator.validate(
                json: missingRow, csv: csv, encoding: encoding, pins: artifactPins
            )) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains("34")
                        || error.localizedDescription.contains("row"),
                    "\(error)"
                )
            }
            var caveman = json
            var cavemanRows = try XCTUnwrap(caveman["rows"] as? [[String: Any]])
            cavemanRows[0]["selected_format"] = "caveman"
            caveman["rows"] = cavemanRows
            XCTAssertThrowsError(try AllRowVersionedReportValidator.validate(
                json: caveman, csv: csv, encoding: encoding, pins: artifactPins
            )) { error in
                XCTAssertTrue(error.localizedDescription.lowercased().contains("caveman"), "\(error)")
            }
            var accepted = json
            var totals = try XCTUnwrap(accepted["totals"] as? [String: Any])
            totals["accepted_only_rows"] = 12
            accepted["totals"] = totals
            XCTAssertThrowsError(try AllRowVersionedReportValidator.validate(
                json: accepted, csv: csv, encoding: encoding, pins: artifactPins
            )) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains("accepted")
                        || error.localizedDescription.contains("overall"),
                    "\(error)"
                )
            }
        }
    }

    func test_versionedJSONAndCSVCoverTheSameRowsAndDecisions() throws {
        for encoding in ["o200k_base", "cl100k_base"] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: versionedRoot.appendingPathComponent(encoding).appendingPathComponent("report.json"))
            ) as? [String: Any])
            let csv = try String(
                contentsOf: versionedRoot.appendingPathComponent(encoding).appendingPathComponent("report.csv")
            )
            try AllRowVersionedReportValidator.validateParity(json: json, csv: csv)
        }
    }

    private var versionedRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/all-row-best-of-three", isDirectory: true)
    }

    private var pins: AllRowVersionedReportValidator.Pins {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let harness = repo.appendingPathComponent("Tests/DistillCoreTests/RCW1EfficiencyCorpusTests.swift")
        let adapter = repo.appendingPathComponent("scripts/rcw1-token-count-o200k.py")
        let requestCorpus = repo.appendingPathComponent("Tests/Fixtures/rcw1-efficiency-corpus.json")
        let responseCorpus = repo.appendingPathComponent("Tests/Fixtures/rcw1-response-efficiency-corpus.json")
        let measurements = versionedRoot.appendingPathComponent("request-measurements.json")
        return AllRowVersionedReportValidator.Pins(
            sourceCommit: "986ad85e247921e1165f07e7830b0fad328d3ad5",
            requestCorpusSHA256: sha256File(requestCorpus),
            responseCorpusSHA256: sha256File(responseCorpus),
            runnerSourceSHA256: sha256File(harness),
            exactCounterSourceSHA256: sha256File(adapter),
            measurementArtifactSHA256: sha256File(measurements),
            requestIDs: [
                "reported-disposable-workspace", "portuguese-redundant-summary", "path-line-no-edit",
                "url-markdown-exact", "command-no-tools", "numeric-thresholds", "uuid-sha-exact",
                "quoted-error-exit", "ordered-first-then", "production-delete-approval",
                "double-negation", "only-except-unless", "code-fence-byte-exact", "json-schema-quotes",
                "japanese-path", "arabic-number", "escapes-byte-exact", "multiframe-long-repetition",
                "cleanup-repetition", "multiple-paths-versions", "follow-up-context",
                "contradictory-fail-open", "opaque-exact-fail-open", "short-fail-open",
            ],
            responseIDs: [
                "short-ok", "reported-disposable-workspace-answer", "multi-record-all-kinds",
                "progressive-multiframe", "exact-code-path", "portuguese-natural", "japanese-natural",
                "arabic-natural", "repeated-evidence-template", "opaque-incompressible",
            ]
        )
    }

    private func sha256File(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum AllRowVersionedReportValidator {
    struct Pins {
        let sourceCommit: String
        let requestCorpusSHA256: String
        let responseCorpusSHA256: String
        let runnerSourceSHA256: String
        let exactCounterSourceSHA256: String
        let measurementArtifactSHA256: String
        let requestIDs: [String]
        let responseIDs: [String]
    }

    static func validate(
        json: [String: Any],
        csv: String,
        encoding: String,
        pins: Pins
    ) throws {
        guard json["schema_version"] as? Int == 6 else {
            throw error("all-row versioned report requires schema 6")
        }
        guard json["billing_claim"] as? Bool == false else {
            throw error("all-row versioned report forbids billing claims")
        }
        guard json["codec"] as? String == "human-rcw1-rcs1" else {
            throw error("all-row versioned report codec drifted")
        }
        let methodology = try object(json["methodology"], "methodology")
        guard methodology["quality"] as? String == "local_exact" else {
            throw error("non-exact quality claimed as exact")
        }
        guard methodology["billing_claim"] as? Bool == false,
              methodology["provider_reported_tokens"] as? Bool == false else {
            throw error("all-row versioned report forbids provider token claims")
        }
        guard methodology["counter_encoding"] as? String == encoding else {
            throw error("versioned report encoding \(methodology["counter_encoding"] ?? "") != \(encoding)")
        }
        let provenance = try object(json["provenance"], "provenance")
        try requireSHA(provenance["request_corpus_sha256"], pins.requestCorpusSHA256, "request corpus")
        try requireSHA(provenance["response_corpus_sha256"], pins.responseCorpusSHA256, "response corpus")
        try requireSHA(provenance["runner_source_sha256"], pins.runnerSourceSHA256, "runner")
        try requireSHA(provenance["exact_counter_source_sha256"], pins.exactCounterSourceSHA256, "tokenizer")
        try requireSHA(provenance["measurement_artifact_sha256"], pins.measurementArtifactSHA256, "measurement")
        guard provenance["remote_code_head"] as? String == pins.sourceCommit else {
            throw error("stale source commit")
        }
        if pins.measurementArtifactSHA256.isEmpty {
            throw error("measurement artifact SHA is missing")
        }
        let rows = try array(json["rows"], "rows")
        guard rows.count == 34 else { throw error("all-row checkpoint requires 34 rows") }
        let requestRows = rows.filter { $0["surface"] as? String == "request" }
        let responseRows = rows.filter { $0["surface"] as? String == "response" }
        guard requestRows.map({ $0["id"] as? String }) == pins.requestIDs else {
            throw error("request rows drifted from frozen corpus")
        }
        guard responseRows.map({ $0["id"] as? String }) == pins.responseIDs else {
            throw error("response-context rows drifted from frozen corpus")
        }
        var seen = Set<String>()
        for row in rows {
            let id = try text(row["id"], "row id")
            guard seen.insert(id).inserted else { throw error("duplicate row \(id)") }
            guard row["selected_format"] as? String != "caveman" else {
                throw error("Caveman is never selected_format")
            }
            guard row["counter_quality"] as? String == "local_exact" else {
                throw error("non-exact quality claimed as exact")
            }
            guard row["billing_claim"] as? Bool == false,
                  row["provider_reported_tokens"] as? Bool == false else {
                throw error("row \(id) claims billing or provider tokens")
            }
            for armName in ["human", "rcw1", "rcs1"] {
                let arm = try object(row[armName], "\(id).\(armName)")
                guard arm["format"] as? String == armName else {
                    throw error("\(id) missing \(armName) arm")
                }
            }
            try validateEnvelopeAccounting(row, id: id)
        }
        let totals = try object(json["totals"], "totals")
        if totals["accepted_only_rows"] != nil || totals["accepted_only"] != nil {
            throw error("accepted-only overall totals are forbidden")
        }
        let requestTotals = try object(totals["request"], "totals.request")
        let responseTotals = try object(totals["response"], "totals.response")
        let overall = try object(totals["overall"], "totals.overall")
        guard requestTotals["rows"] as? Int == 24,
              responseTotals["rows"] as? Int == 10,
              overall["rows"] as? Int == 34 else {
            throw error("all-row totals must cover request, response, and overall")
        }
        try validateParity(json: json, csv: csv)
    }

    static func validateParity(json: [String: Any], csv: String) throws {
        let rows = try array(json["rows"], "rows")
        let lines = csv.split(whereSeparator: \.isNewline).map(String.init)
        let csvRows = lines.filter { $0.hasPrefix("row,") }
        guard csvRows.count == rows.count else {
            throw error("JSON/CSV row count diverged")
        }
        for (jsonRow, csvLine) in zip(rows, csvRows) {
            let fields = parseCSV(csvLine)
            guard fields.count > 4 else { throw error("CSV row is truncated") }
            guard fields[1] == (jsonRow["id"] as? String) else {
                throw error("JSON/CSV id divergence")
            }
            guard fields[3] == (jsonRow["selected_format"] as? String) else {
                throw error("JSON/CSV decision divergence")
            }
        }
    }

    private static func validateEnvelopeAccounting(_ row: [String: Any], id: String) throws {
        let human = try object(row["human"], "\(id).human")
        let rcw1 = try object(row["rcw1"], "\(id).rcw1")
        let rcs1 = try object(row["rcs1"], "\(id).rcs1")
        if let humanABI = human["abi_tokens"] as? Int, humanABI != 0 {
            throw error("\(id) Human ABI must not be counted as an extra arm cost")
        }
        for (name, arm) in [("rcw1", rcw1), ("rcs1", rcs1)] {
            if let effective = arm["effective_tokens"] as? Int,
               let payload = arm["payload_tokens"] as? Int,
               let handle = arm["handle_tokens"] as? Int,
               let abi = arm["abi_tokens"] as? Int {
                let added = payload + handle + abi
                if effective == added && handle != 0 && payload == handle {
                    throw error("\(id) \(name) counted handle twice")
                }
            }
        }
    }

    private static func requireSHA(_ value: Any?, _ expected: String, _ label: String) throws {
        let actual = try text(value, "\(label) SHA-256")
        guard actual == expected else { throw error("stale \(label) SHA-256") }
    }

    private static func object(_ value: Any?, _ label: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw error("\(label) must be an object") }
        return object
    }

    private static func array(_ value: Any?, _ label: String) throws -> [[String: Any]] {
        guard let array = value as? [[String: Any]] else { throw error("\(label) must be an array") }
        return array
    }

    private static func text(_ value: Any?, _ label: String) throws -> String {
        guard let text = value as? String, !text.isEmpty else { throw error("\(label) must be text") }
        return text
    }

    private static func parseCSV(_ line: String) -> [String] {
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

    private static func error(_ message: String) -> NSError {
        NSError(domain: "AllRowVersionedReport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
