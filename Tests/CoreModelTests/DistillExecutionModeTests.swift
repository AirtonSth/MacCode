import XCTest
@testable import CoreModel

final class DistillExecutionModeTests: XCTestCase {
    func test_wireValuesMatchTheDistillProtocol() {
        XCTAssertEqual(DistillExecutionMode.allCases.map(\.rawValue), ["normal", "ultrafast", "ultracode", "ultrasave"])
    }

    func test_storedLegacyBoolDecodesToTheModeItMeant_becauseOldDataMustKeepItsBehavior() throws {
        // WHY: before modes existed Ultracode was a Bool; saved threads and tasks must not change behavior.
        let legacyOn = Data(#"{"provider":"distill","modelId":"m","reasoningEffort":"high","serviceTier":"auto","distillUltracode":true}"#.utf8)
        let legacyOff = Data(#"{"provider":"distill","modelId":"m","reasoningEffort":"high","serviceTier":"auto","distillUltracode":false}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AgentModelSelection.self, from: legacyOn).distillExecutionMode, .ultracode)
        XCTAssertEqual(try JSONDecoder().decode(AgentModelSelection.self, from: legacyOff).distillExecutionMode, .normal)
    }

    func test_everyModeRoundTripsThroughAModelSelection() throws {
        for mode in DistillExecutionMode.allCases {
            let selection = AgentModelSelection(provider: .distill, modelId: "m", distillExecutionMode: mode)
            let decoded = try JSONDecoder().decode(AgentModelSelection.self, from: JSONEncoder().encode(selection))
            XCTAssertEqual(decoded.distillExecutionMode, mode)
        }
    }

    func test_normalAndUltracodeStayBoolsOnDisk_becauseOlderReadersOnlyKnowTheFlag() throws {
        func raw(_ mode: DistillExecutionMode) throws -> Any? {
            let selection = AgentModelSelection(provider: .distill, modelId: "m", distillExecutionMode: mode)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selection)) as? [String: Any]
            return object?["distillUltracode"]
        }
        XCTAssertEqual(try raw(.normal) as? Bool, false)
        XCTAssertEqual(try raw(.ultracode) as? Bool, true)
        XCTAssertEqual(try raw(.ultrafast) as? String, "ultrafast")
        XCTAssertEqual(try raw(.ultrasave) as? String, "ultrasave")
    }

    func test_unknownStoredModeIsRejectedInsteadOfSilentlyBecomingNormal() {
        let json = Data(#"{"provider":"distill","modelId":"m","reasoningEffort":"high","serviceTier":"auto","distillUltracode":"turbo"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AgentModelSelection.self, from: json))
    }

    func test_storageValueKeepsTheLegacyIntegersAndRoundTrips() {
        XCTAssertEqual(DistillExecutionMode.normal.storageValue, 0)
        XCTAssertEqual(DistillExecutionMode.ultracode.storageValue, 1)
        for mode in DistillExecutionMode.allCases {
            XCTAssertEqual(DistillExecutionMode(storageValue: mode.storageValue), mode)
        }
        XCTAssertEqual(DistillExecutionMode(storageValue: 99), .normal)
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
