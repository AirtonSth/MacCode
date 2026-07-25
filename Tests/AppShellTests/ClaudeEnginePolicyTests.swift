import XCTest
@testable import AppShell

/// Tests for ClaudeEnginePolicy.resolve(setting:envOverride:).
///
/// Business rule: the `.claude` provider must default to the dependency-minimal
/// CLI engine so a machine WITHOUT a modern Node/npm toolchain still runs Claude
/// (the exact failure a Node 12 / x64 user hit). The SDK bridge is opt-in only.
/// A dev/admin env override outranks the persisted setting.
final class ClaudeEnginePolicyTests: XCTestCase {

    // MARK: - Default is CLI (the whole point of the change)

    func test_default_noSettingNoEnv_isCLI() {
        XCTAssertEqual(ClaudeEnginePolicy.resolve(setting: nil, envOverride: nil), .cli,
                       "A fresh machine must default to CLI — never the Node SDK bridge")
    }

    func test_emptyOrUnknownSetting_isCLI() {
        XCTAssertEqual(ClaudeEnginePolicy.resolve(setting: "", envOverride: nil), .cli)
        XCTAssertEqual(ClaudeEnginePolicy.resolve(setting: "   ", envOverride: nil), .cli)
        XCTAssertEqual(ClaudeEnginePolicy.resolve(setting: "bridge", envOverride: nil), .cli,
                       "An unrecognized persisted value must not silently force the SDK")
    }

    // MARK: - Persisted setting is honored

    func test_settingSDK_selectsSDK() {
        XCTAssertEqual(ClaudeEnginePolicy.resolve(setting: "sdk", envOverride: nil), .sdk)
    }

    func test_settingCLI_selectsCLI() {
        XCTAssertEqual(ClaudeEnginePolicy.resolve(setting: "cli", envOverride: nil), .cli)
    }

    func test_setting_isCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(ClaudeEnginePolicy.resolve(setting: "  SDK ", envOverride: nil), .sdk)
    }

    // MARK: - Env override outranks the setting (dev/admin escape hatch)

    func test_env0_forcesCLI_overSDKSetting() {
        XCTAssertEqual(ClaudeEnginePolicy.resolve(setting: "sdk", envOverride: "0"), .cli,
                       "RC_CLAUDE_AGENT_SDK_ENABLED=0 must force CLI even if the setting says SDK")
    }

    func test_env1_forcesSDK_overCLISettingAndDefault() {
        XCTAssertEqual(ClaudeEnginePolicy.resolve(setting: "cli", envOverride: "1"), .sdk)
        XCTAssertEqual(ClaudeEnginePolicy.resolve(setting: nil, envOverride: "1"), .sdk)
    }

    func test_unrecognizedEnv_fallsThroughToSetting() {
        // A stray value must not force an engine; the setting still decides.
        XCTAssertEqual(ClaudeEnginePolicy.resolve(setting: "sdk", envOverride: "true"), .sdk)
        XCTAssertEqual(ClaudeEnginePolicy.resolve(setting: nil, envOverride: "yes"), .cli)
        XCTAssertEqual(ClaudeEnginePolicy.resolve(setting: nil, envOverride: ""), .cli)
    }

    // MARK: - Enum round-trips (used as the persisted rawValue)

    func test_engineRawValuesArePersistableStable() {
        XCTAssertEqual(ClaudeEngine.cli.rawValue, "cli")
        XCTAssertEqual(ClaudeEngine.sdk.rawValue, "sdk")
        XCTAssertEqual(ClaudeEngine(rawValue: "cli"), .cli)
        XCTAssertEqual(ClaudeEngine(rawValue: "sdk"), .sdk)
    }
}
