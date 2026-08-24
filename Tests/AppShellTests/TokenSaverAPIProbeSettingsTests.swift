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
        vm.setTokenSaverAPIModel("m")
        vm.tokenSaverAPIProbe = { _, _, _ in
            .ok(model: "m", host: "127.0.0.1", preview: "pong")
        }
        vm.testTokenSaverAPI()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.tokenSaverAPIProbeStatus, .ok("Reached m at 127.0.0.1"))
        vm.setTokenSaverAPIBaseURL("http://127.0.0.1:9000/v1")
        XCTAssertEqual(vm.tokenSaverAPIProbeStatus, .idle, "stale success must not survive a URL edit")
    }

    func test_freshProfileCanConfigureAndProbeAPIBeforeEnablingTokenSaver() async throws {
        // WHY: a new user cannot enable an API target safely unless source,
        // endpoint, model, token and probe are available while the feature is off.
        let vm = try makeViewModel()
        XCTAssertFalse(vm.appSettings.tokenSaverEnabled)
        vm.setTokenSaverModelSource(.openaiCompat)
        vm.setTokenSaverAPIBaseURL("https://api.example.com/v1")
        vm.setTokenSaverAPIModel("remote-distill")
        vm.setTokenSaverAPIToken("secret")
        vm.tokenSaverAPIProbe = { base, model, token in
            XCTAssertEqual(base, "https://api.example.com/v1")
            XCTAssertEqual(model, "remote-distill")
            XCTAssertEqual(token, "secret")
            return .ok(model: model, host: "api.example.com", preview: "pong")
        }

        XCTAssertTrue(vm.canTestTokenSaverAPI)
        vm.testTokenSaverAPI()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.tokenSaverAPIProbeStatus, .ok("Reached remote-distill at api.example.com"))
        XCTAssertFalse(vm.appSettings.tokenSaverEnabled)
    }

    func test_blankAPIModelShowsActionableRecoveryWithoutRunningProbe() throws {
        let vm = try makeViewModel()
        vm.setTokenSaverModelSource(.openaiCompat)
        vm.setTokenSaverAPIBaseURL("https://api.example.com/v1")
        vm.setTokenSaverAPIModel("   ")
        var probed = false
        vm.tokenSaverAPIProbe = { _, _, _ in
            probed = true
            return .ok(model: "unexpected", host: "api.example.com", preview: "pong")
        }

        XCTAssertFalse(vm.canTestTokenSaverAPI)
        vm.testTokenSaverAPI()
        XCTAssertFalse(probed)
        XCTAssertEqual(
            vm.tokenSaverAPIProbeStatus,
            .failed("Enter the API model id used by your OpenAI-compatible server")
        )
    }

    func test_apiModeCopyDoesNotClaimLocalMLXOrLocalModel() {
        let copies = [
            TokenSaverSettingsCopy.overview(source: .openaiCompat),
            TokenSaverSettingsCopy.sourceDescription(source: .openaiCompat),
            TokenSaverSettingsCopy.trainingDescription(source: .openaiCompat),
            TokenSaverSettingsCopy.apiProbeHint,
        ]
        for copy in copies {
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("local MLX"), copy)
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("local model"), copy)
        }
    }

    func test_apiProbeProgressCopyDistinguishesLoopbackFromRemoteHTTPS() {
        XCTAssertEqual(
            TokenSaverSettingsCopy.apiProbeProgress(baseURL: "http://127.0.0.1:8000/v1"),
            "Waiting for the local API…"
        )
        XCTAssertEqual(
            TokenSaverSettingsCopy.apiProbeProgress(baseURL: "https://api.example.com/v1"),
            "Waiting for the API…"
        )
    }

    func test_disableConfirmationCopyDependsOnGenerateSource() {
        let local = SidebarViewModel.tokenSaverDisableInformativeText(source: .distillE4B)
        let api = SidebarViewModel.tokenSaverDisableInformativeText(source: .openaiCompat)

        XCTAssertTrue(local.localizedCaseInsensitiveContains("stops the local model"), local)
        XCTAssertFalse(api.localizedCaseInsensitiveContains("local model"), api)
        XCTAssertTrue(api.localizedCaseInsensitiveContains("stops API-backed compression"), api)
    }

    func test_apiConfigurationControlsAreNotDisabledWithTokenSaverOff() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/AppShell/SettingsWindow.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "settingRow(\"Distill model\")"))
        let end = try XCTUnwrap(source.range(of: "settingRow(\"Save training datasets\")", range: start.upperBound..<source.endIndex))
        let configurationControls = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(
            configurationControls.contains(".disabled(!vm.appSettings.tokenSaverEnabled)"),
            "source, URL, model, token and probe must remain editable/testable before enable"
        )
    }
}
