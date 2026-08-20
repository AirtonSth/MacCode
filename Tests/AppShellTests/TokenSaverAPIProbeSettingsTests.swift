import XCTest
import CoreModel
import DistillCore
import Persistence
@testable import AppShell

@MainActor
final class TokenSaverAPIProbeSettingsTests: XCTestCase {
    private func makeViewModel() throws -> SettingsViewModel {
        let dir = NSTemporaryDirectory() + "RC2TokenSaverAPIProbe-\(UUID().uuidString)"
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        return SettingsViewModel(context: ctx)
    }

    func test_emptyURLFailsBeforeProbeRuns() throws {
        let vm = try makeViewModel()
        vm.appSettings.tokenSaverEnabled = true
        vm.setTokenSaverModelSource(.openaiCompat)
        var probed = false
        vm.tokenSaverAPIProbe = { _, _, _ in
            probed = true
            return .ok(model: "m", host: "127.0.0.1", preview: "pong")
        }
        vm.testTokenSaverAPI()
        XCTAssertFalse(probed)
        XCTAssertEqual(vm.tokenSaverAPIProbeStatus, .failed("Enter a URL like http://127.0.0.1:8000/v1"))
        XCTAssertFalse(vm.canTestTokenSaverAPI)
    }

    func test_successMapsToStatusRowCopy() async throws {
        let vm = try makeViewModel()
        vm.appSettings.tokenSaverEnabled = true
        vm.setTokenSaverModelSource(.openaiCompat)
        vm.setTokenSaverAPIBaseURL("http://127.0.0.1:8000/v1")
        vm.setTokenSaverAPIModel("local-distill")
        vm.tokenSaverAPIProbe = { base, model, _ in
            XCTAssertEqual(base, "http://127.0.0.1:8000/v1")
            XCTAssertEqual(model, "local-distill")
            return .ok(model: model, host: "127.0.0.1", preview: "pong")
        }
        XCTAssertTrue(vm.canTestTokenSaverAPI)
        vm.testTokenSaverAPI()
        XCTAssertEqual(vm.tokenSaverAPIProbeStatus, .testing)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.tokenSaverAPIProbeStatus, .ok("Reached local-distill at 127.0.0.1"))
    }

    func test_changingURLClearsStaleSuccess() async throws {
        let vm = try makeViewModel()
        vm.appSettings.tokenSaverEnabled = true
        vm.setTokenSaverModelSource(.openaiCompat)
        vm.setTokenSaverAPIBaseURL("http://127.0.0.1:8000/v1")
        vm.tokenSaverAPIProbe = { _, _, _ in
            .ok(model: "m", host: "127.0.0.1", preview: "pong")
        }
        vm.testTokenSaverAPI()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.tokenSaverAPIProbeStatus, .ok("Reached m at 127.0.0.1"))
        vm.setTokenSaverAPIBaseURL("http://127.0.0.1:9000/v1")
        XCTAssertEqual(vm.tokenSaverAPIProbeStatus, .idle, "stale success must not survive a URL edit")
    }
}
