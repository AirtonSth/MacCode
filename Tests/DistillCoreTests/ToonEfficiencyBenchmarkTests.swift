import XCTest
@testable import DistillCore

/// Measured TokenEstimator A/B: TOON vs pretty vs minify.
/// Official TOON benches show GPT-nano slightly worse on retrieval, so we only
/// adopt when TOON beats compact JSON on the same estimator.
final class ToonEfficiencyBenchmarkTests: XCTestCase {
    struct Row {
        let name: String
        let pretty: Int
        let minify: Int
        let toon: Int?
        let adopted: Bool
        let reason: String
    }

    func test_benchmarkTableAdoptsTabularAndRejectsDeepOrCompact() throws {
        var rows: [Row] = []
        rows.append(measure("employees-uniform", employeesJSON(count: 24, pretty: true)))
        rows.append(measure("weather-forecast", weatherJSON))
        rows.append(measure("deep-config", deepConfigJSON))
        rows.append(measure("compact-object", #"{"id":1,"name":"Ada","role":"admin"}"#))
        rows.append(measure("glab-mr-list", glabMRListJSON(pretty: true)))

        let report = rows.map {
            "\($0.name) pretty=\($0.pretty) minify=\($0.minify) toon=\($0.toon.map(String.init) ?? "na") adopted=\($0.adopted) \($0.reason)"
        }.joined(separator: "\n")
        print("TOON benchmark\n\(report)")

        let employees = try XCTUnwrap(rows.first { $0.name == "employees-uniform" })
        XCTAssertTrue(employees.adopted, "uniform arrays are TOON's sweet spot: \(employees.reason)")
        XCTAssertLessThan(employees.toon ?? .max, employees.minify)

        let weather = try XCTUnwrap(rows.first { $0.name == "weather-forecast" })
        XCTAssertTrue(weather.adopted, "weather fixture must beat minify: \(weather.reason)")

        let deep = try XCTUnwrap(rows.first { $0.name == "deep-config" })
        XCTAssertFalse(deep.adopted, "deep non-tabular must not adopt a worse TOON: \(deep.reason)")

        let compact = try XCTUnwrap(rows.first { $0.name == "compact-object" })
        XCTAssertFalse(compact.adopted, "tiny compact JSON must stay JSON: \(compact.reason)")

        let glab = try XCTUnwrap(rows.first { $0.name == "glab-mr-list" })
        XCTAssertTrue(glab.adopted, "uniform MR list should adopt: \(glab.reason)")
    }

    func test_routerUsesToonForPrettyUniformArrayAndKeepsExtractiveJSON() throws {
        let pretty = employeesJSON(count: 16, pretty: true)
        let routed = try XCTUnwrap(DistillContentRouter().route(pretty, options: .losslessOnly))
        XCTAssertTrue(routed.lossless)
        XCTAssertTrue(routed.output.contains("[16]{"), routed.output)
        XCTAssertFalse(
            routed.output.hasPrefix("{") && routed.output.contains("\"_distill_format\""),
            "router must serve TOON, not the JSON+CSV envelope: \(routed.output.prefix(80))"
        )

        let extractive = DistillRouterOptions(allowElementDropping: false, query: "return json only")
        let jsonKept = try XCTUnwrap(DistillContentRouter().route(pretty, options: extractive))
        XCTAssertTrue(
            jsonKept.output.hasPrefix("{") || jsonKept.output.hasPrefix("["),
            "extractive JSON question must not convert to TOON: \(jsonKept.output.prefix(80))"
        )
    }

    private func measure(_ name: String, _ input: String) -> Row {
        let prettyTok = TokenEstimator.estimate(input)
        let minified = JSONCrusher.minify(input) ?? input
        let minifyTok = TokenEstimator.estimate(minified)
        if let toon = ToonCodec.encodeIfEfficient(input) {
            return Row(
                name: name,
                pretty: prettyTok,
                minify: minifyTok,
                toon: TokenEstimator.estimate(toon),
                adopted: true,
                reason: "adopt"
            )
        }
        let encoded = ToonCodec.encode(input)
        var reason = "not-adopted"
        if input.utf8.count < ToonCodec.minInputBytes {
            reason = "below-min-bytes"
        } else if let encoded {
            let toonTok = TokenEstimator.estimate(encoded)
            if toonTok >= minifyTok { reason = "toon>=minify (\(toonTok)>=\(minifyTok))" }
            else if encoded.utf8.count >= input.utf8.count { reason = "no-byte-shrink" }
            else if let back = ToonCodec.decodeToJSON(encoded), !ToonCodec.jsonModelEqual(input, back) {
                reason = "round-trip-fail"
            }
        } else {
            reason = "encode-nil"
        }
        return Row(name: name, pretty: prettyTok, minify: minifyTok, toon: encoded.map(TokenEstimator.estimate), adopted: false, reason: reason)
    }

    private func employeesJSON(count: Int, pretty: Bool) -> String {
        let rows: [[String: Any]] = (0..<count).map { index in
            [
                "id": index,
                "name": "item-\(index)",
                "role": index % 2 == 0 ? "admin" : "user",
                "active": index % 3 == 0
            ]
        }
        return jsonString(rows, pretty: pretty)
    }

    private var weatherJSON: String {
        """
        {
          "location": {"city": "Berlin", "country": "DE", "units": "metric"},
          "alerts": ["frost", "wind"],
          "forecast": [
            {"day": "Mon", "temp": {"min": -2, "max": 4}, "condition": "snow", "rainChance": 80},
            {"day": "Tue", "temp": {"min": 1, "max": 7}, "condition": "cloudy", "rainChance": 20},
            {"day": "Wed", "temp": {"min": 3, "max": 11}, "condition": "sunny", "rainChance": 5}
          ]
        }
        """
    }

    private var deepConfigJSON: String {
        """
        {
          "server": {
            "http": {
              "tls": {
                "certs": {
                  "primary": { "path": "/etc/ssl/cert.pem", "rotate": false }
                }
              }
            }
          }
        }
        """
    }

    private func glabMRListJSON(pretty: Bool) -> String {
        let rows: [[String: Any]] = (0..<12).map { index in
            [
                "iid": 200 + index,
                "title": "feat: slice-\(index)",
                "state": "opened",
                "source": "feat/slice-\(index)",
                "target": "production"
            ]
        }
        return jsonString(rows, pretty: pretty)
    }

    private func jsonString(_ value: Any, pretty: Bool) -> String {
        let options: JSONSerialization.WritingOptions = pretty
            ? [.prettyPrinted, .sortedKeys]
            : [.sortedKeys]
        let data = try! JSONSerialization.data(withJSONObject: value, options: options)
        return String(data: data, encoding: .utf8)!
    }
}
