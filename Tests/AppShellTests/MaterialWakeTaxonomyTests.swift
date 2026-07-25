import XCTest
@testable import AppShell

final class MaterialWakeTaxonomyTests: XCTestCase {
    func testPhaseACriticalLifecycleClassifications() {
        XCTAssertEqual(MaterialWakeTaxonomy.classification(forEventKind: "agent.run.started"), .criticalAlertAndSilent)
        XCTAssertEqual(MaterialWakeTaxonomy.classification(forEventKind: "agent.run.completed"), .criticalAlertAndSilent)
        XCTAssertEqual(MaterialWakeTaxonomy.classification(forEventKind: "agent.run.failed"), .criticalAlertAndSilent)
        XCTAssertEqual(MaterialWakeTaxonomy.classification(forEventKind: "agent.run.cancelled"), .silent)
        XCTAssertEqual(MaterialWakeTaxonomy.classification(forEventKind: "agent.attention"), .criticalAlertAndSilent)
        XCTAssertEqual(MaterialWakeTaxonomy.classification(forEventKind: "host.boot_epoch"), .silentForce)
        XCTAssertEqual(MaterialWakeTaxonomy.classification(forEventKind: "device.revoke"), .criticalAlert)
    }

    func testStreamOnlyNeverPush() {
        XCTAssertEqual(MaterialWakeTaxonomy.classification(forEventKind: "surface.output"), .streamOnly)
        XCTAssertEqual(MaterialWakeTaxonomy.classification(forEventKind: "agent.item.delta"), .streamOnly)
        XCTAssertEqual(MaterialWakeTaxonomy.classification(forEventKind: "heartbeat"), .streamOnly)
        XCTAssertFalse(MaterialWakeTaxonomy.phaseAAllowsSilent(.streamOnly))
    }

    func testUnknownDefaultsStreamOnly() {
        XCTAssertEqual(MaterialWakeTaxonomy.classification(forEventKind: "totally.unknown.event"), .streamOnly)
    }

    func testSilentCatchUpV1PayloadPrivacyAndParse() {
        let payload = SilentCatchUpV1(
            catchUp: true,
            watermark: "42",
            sinceSeq: "100",
            bootEpoch: "7",
            reason: "run_completed"
        )
        let data = payload.asPushData()
        XCTAssertEqual(data["rc2_catch_up"], "1")
        XCTAssertEqual(data["rc2_schema"], SilentCatchUpV1.schemaVersion)
        XCTAssertEqual(data["rc2_wm"], "42")
        XCTAssertEqual(data["rc2_since_seq"], "100")
        XCTAssertEqual(data["rc2_boot_epoch"], "7")
        XCTAssertEqual(data["rc2_reason"], "run_completed")
        // Must not accept free-form agent text as watermark.
        let scrubbed = SilentCatchUpV1(watermark: "agent said hello", reason: "x; DROP TABLE")
        XCTAssertNil(scrubbed.watermark)
        XCTAssertEqual(scrubbed.reason, "x__drop_table")

        let parsed = SilentCatchUpV1.parse([
            "rc2_catch_up": "1",
            "rc2_wm": "9",
            "unknown_future": "x",
        ])
        XCTAssertEqual(parsed?.watermark, "9")
        XCTAssertTrue(parsed?.catchUp == true)
    }

    func testPhaseAAllowsSilentMatrix() {
        XCTAssertTrue(MaterialWakeTaxonomy.phaseAAllowsSilent(.criticalAlertAndSilent))
        XCTAssertTrue(MaterialWakeTaxonomy.phaseAAllowsSilent(.silent))
        XCTAssertTrue(MaterialWakeTaxonomy.phaseAAllowsSilent(.silentForce))
        XCTAssertFalse(MaterialWakeTaxonomy.phaseAAllowsSilent(.criticalAlert))
        XCTAssertFalse(MaterialWakeTaxonomy.phaseAAllowsSilent(.silentOrAlert))
        XCTAssertTrue(MaterialWakeTaxonomy.shouldForceSilent(.silentForce))
    }
}
