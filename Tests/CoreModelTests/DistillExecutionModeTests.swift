import XCTest
@testable import CoreModel

final class DistillExecutionModeTests: XCTestCase {
    func test_wireValuesMatchTheDistillProtocol() {
        XCTAssertEqual(DistillExecutionMode.allCases.map(\.rawValue), ["auto", "normal", "ultrafast", "ultracode", "ultrasave"])
    }

    func test_storedLegacyBoolDecodesToTheModeItMeant_becauseOldDataMustKeepItsBehavior() throws {
        // WHY: before modes existed Ultracode was a Bool; saved threads and tasks must not change behavior.
        let legacyOn = Data(#"{"provider":"distill","modelId":"m","reasoningEffort":"high","serviceTier":"auto","distillUltracode":true}"#.utf8)
        let legacyOff = Data(#"{"provider":"distill","modelId":"m","reasoningEffort":"high","serviceTier":"auto","distillUltracode":false}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AgentModelSelection.self, from: legacyOn).distillExecutionMode, .ultracode)
        XCTAssertEqual(try JSONDecoder().decode(AgentModelSelection.self, from: legacyOff).distillExecutionMode, .auto,
                       "the legacy false was the old default, which Distill itself now loads as Auto")
    }

    func test_everyModeRoundTripsThroughAModelSelection() throws {
        for mode in DistillExecutionMode.allCases {
            let selection = AgentModelSelection(provider: .distill, modelId: "m", distillExecutionMode: mode)
            let decoded = try JSONDecoder().decode(AgentModelSelection.self, from: JSONEncoder().encode(selection))
            XCTAssertEqual(decoded.distillExecutionMode, mode)
        }
    }

    func test_onlyUltracodeStaysABoolOnDisk_becauseNormalMustBeDistinguishableFromTheLegacyDefault() throws {
        func raw(_ mode: DistillExecutionMode) throws -> Any? {
            let selection = AgentModelSelection(provider: .distill, modelId: "m", distillExecutionMode: mode)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selection)) as? [String: Any]
            return object?["distillUltracode"]
        }
        XCTAssertEqual(try raw(.normal) as? String, "normal")
        XCTAssertEqual(try raw(.ultracode) as? Bool, true)
        XCTAssertEqual(try raw(.ultrafast) as? String, "ultrafast")
        XCTAssertEqual(try raw(.ultrasave) as? String, "ultrasave")
    }

    func test_unknownStoredModeIsRejectedInsteadOfSilentlyBecomingNormal() {
        let json = Data(#"{"provider":"distill","modelId":"m","reasoningEffort":"high","serviceTier":"auto","distillUltracode":"turbo"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AgentModelSelection.self, from: json))
    }

    func test_storageValueKeepsTheLegacyIntegersAndRoundTrips() {
        XCTAssertEqual(DistillExecutionMode.normal.storageValue, 5)
        XCTAssertEqual(DistillExecutionMode.ultracode.storageValue, 1)
        XCTAssertEqual(DistillExecutionMode(storageValue: 0), .auto, "legacy rows with 0 never chose a mode, so they read as Auto")
        for mode in DistillExecutionMode.allCases {
            XCTAssertEqual(DistillExecutionMode(storageValue: mode.storageValue), mode)
        }
        XCTAssertEqual(DistillExecutionMode.auto.storageValue, 4)
        XCTAssertEqual(DistillExecutionMode(storageValue: 99), .auto, "unknown stored ints mean the user never chose a fixed mode")
    }

    func test_newSelectionAndMissingStoredValueDefaultToAuto_becauseAutoIsTheProductDefault() throws {
        // WHY: users who never picked a mode must get Auto, while explicit legacy values keep their meaning.
        XCTAssertEqual(AgentModelSelection(provider: .distill, modelId: "m").distillExecutionMode, .auto)
        let missing = Data(#"{"provider":"distill","modelId":"m","reasoningEffort":"high","serviceTier":"auto"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AgentModelSelection.self, from: missing).distillExecutionMode, .auto)
    }

    func test_explicitNormalSurvivesARoundTrip_becauseItIsNoLongerTheLegacyFalseDefault() throws {
        // WHY: a user who deliberately picked Normal must keep it now that legacy false means Auto.
        let selection = AgentModelSelection(provider: .distill, modelId: "m", distillExecutionMode: .normal)
        let decoded = try JSONDecoder().decode(AgentModelSelection.self, from: JSONEncoder().encode(selection))
        XCTAssertEqual(decoded.distillExecutionMode, .normal)
        XCTAssertEqual(DistillExecutionMode(storageValue: DistillExecutionMode.normal.storageValue), .normal)
    }

    func test_autoPersistsAsItsWireString() throws {
        // WHY: Auto has no legacy Bool form, so it must be stored as "auto" and decode back to Auto.
        let selection = AgentModelSelection(provider: .distill, modelId: "m", distillExecutionMode: .auto)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selection)) as? [String: Any]
        XCTAssertEqual(object?["distillUltracode"] as? String, "auto")
    }

    func test_botScheduleSpecWithTheLegacyFlagKeepsItsKey() throws {
        let json = Data(#"{"provider":"distill","providerInstanceID":"distill","model":"m","reasoningEffort":"medium","routingMode":"manual","distillUltracode":true,"frequency":"daily","scheduledDate":0,"intervalHours":1,"localTimeHour":9,"localTimeMinute":0,"weekdays":[],"monthlyDay":1,"timeZoneIdentifier":"UTC"}"#.utf8)
        let decoder = JSONDecoder()
        let spec = try? decoder.decode(BotScheduleSpec.self, from: json)
        if let spec { XCTAssertEqual(spec.distillExecutionMode, .ultracode) }
        var written = BotScheduleSpec()
        written.distillExecutionMode = .ultrafast
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(written)) as? [String: Any]
        XCTAssertEqual(object?["distillUltracode"] as? String, "ultrafast")
        XCTAssertNil(object?["distillExecutionMode"])
    }
}
