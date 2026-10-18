import XCTest
@testable import SocketServer

final class ConnectionContractManifestTests: XCTestCase {
    private let requiredIDs: [String] = {
        func series(_ prefix: String, _ count: Int) -> [String] {
            (1...count).map { String(format: "%@-%03d", prefix, $0) }
        }
        return series("CONN", 8)
            + series("OBS", 4)
            + series("REQ", 6)
            + series("BOT", 8)
            + series("MIG", 3)
            + series("SEC", 2)
    }()

    private let requiredFields: [String] = [
        "id", "risk", "criticality", "stage", "injection_seam", "oracle",
        "test_layer", "route_cohort", "clock_owner", "eligible_sample",
        "denominator", "runs", "artifacts", "owner", "validator",
    ]

    func test_riskManifest_parsesWithRequiredFieldsAndUniqueIDs() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/connection-contract-v3/risk-manifest.json")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertFalse(
            (root["version"] as? String ?? "").isEmpty,
            "manifest must be versioned"
        )
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertEqual(
            cases.count,
            requiredIDs.count,
            "Gate 0 manifesto must contain the stable plan-connection IDs"
        )

        var seen = Set<String>()
        for item in cases {
            for field in requiredFields {
                XCTAssertNotNil(item[field], "case \(item["id"] ?? "?") missing \(field)")
                if field == "artifacts" {
                    let artifacts = item[field] as? [Any]
                    XCTAssertNotNil(artifacts, "artifacts must be an array")
                    XCTAssertFalse(artifacts?.isEmpty == true, "artifacts must be non-empty")
                } else if field == "eligible_sample" || field == "runs" {
                    XCTAssertNotNil(item[field] as? Int, "\(field) must be an integer")
                } else {
                    let value = item[field] as? String
                    XCTAssertFalse(
                        value?.isEmpty ?? true,
                        "\(field) must be a non-empty string on \(item["id"] ?? "?")"
                    )
                }
            }
            let id = try XCTUnwrap(item["id"] as? String)
            XCTAssertTrue(seen.insert(id).inserted, "duplicate manifesto id \(id)")
        }
        XCTAssertEqual(seen, Set(requiredIDs), "manifesto IDs must match the Gate 0 set")
    }

    func test_attachmentUploadV3PrepareRoute_isAcceptedByPathParser() {
        let id = "11111111-1111-4111-8111-111111111111"
        XCTAssertEqual(
            DirectHTTPServer.attachmentUploadV3Route(
                path: "/v1/agent/attachment-uploads/v3/\(id)/prepare"
            ),
            .prepare(uploadId: id),
            "P0.8: POST prepare must be a parsed v3 HTTP route"
        )
    }
}
