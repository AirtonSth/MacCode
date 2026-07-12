import XCTest
@testable import CoreModel

final class AgentProviderSnapshotTests: XCTestCase {
    func test_modelDescriptorDefaultsRemainBackwardCompatible() throws {
        let json = """
        {"id":"gpt-5.5","label":"GPT-5.5","provider":"codex","supportsReasoning":true}
        """.data(using: .utf8)!

        let descriptor = try JSONDecoder().decode(AgentModelDescriptor.self, from: json)

        XCTAssertEqual(descriptor.supportedReasoningEfforts, AgentReasoningEffort.supportedCases,
                       "older provider snapshots must still produce legal reasoning controls when supportsReasoning is true")
        XCTAssertFalse(descriptor.supportsServiceTier)
        XCTAssertFalse(descriptor.supportsCustomModel)
        XCTAssertNil(descriptor.contextWindowTokens)
    }

    func test_providerSnapshotReportsMissingBinaryEvenWhenStaticModelsExist() {
        let models = [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)]

        let snapshot = AgentProviderSnapshotFactory.snapshot(provider: .codex, models: models, binaryPath: "")

        XCTAssertFalse(snapshot.installed,
                       "provider snapshots must not treat static model metadata as proof that the local CLI is installed")
        XCTAssertEqual(snapshot.status, .unavailable)
        XCTAssertEqual(snapshot.statusDetail, "Codex CLI binary is unavailable.")
    }

    func test_providerSnapshotReportsAvailableWhenBinaryAndModelsExist() {
        let models = [AgentModelDescriptor(id: "claude-opus-4-7", label: "Claude Opus 4.7", provider: .claude)]

        let snapshot = AgentProviderSnapshotFactory.snapshot(provider: .claude, models: models, binaryPath: "/usr/local/bin/claude", version: "Claude Code 2.1.0")

        XCTAssertTrue(snapshot.installed)
        XCTAssertEqual(snapshot.version, "Claude Code 2.1.0")
        XCTAssertEqual(snapshot.status, .available)
        XCTAssertNil(snapshot.statusDetail)
    }

    func test_providerSnapshotWarnsWhenAuthProbeSaysUnauthenticated() {
        let models = [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)]

        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: models,
            binaryPath: "/usr/local/bin/codex",
            authenticated: false,
            accountLabel: "work@example.com",
            accountAuthMethod: "oauth"
        )

        XCTAssertEqual(snapshot.authenticated, false)
        XCTAssertEqual(snapshot.accountLabel, "work@example.com")
        XCTAssertEqual(snapshot.accountAuthMethod, "oauth")
        XCTAssertEqual(snapshot.status, .warning)
        XCTAssertEqual(snapshot.statusDetail, "Codex CLI is not authenticated.",
                       "provider cards must warn before a long-running Agent App task fails on provider auth")
    }

    func test_providerSnapshotMergesProbedSlashCommandsWithLocalDefaults() {
        let models = [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)]

        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: models,
            binaryPath: "/usr/local/bin/codex",
            slashCommands: ["/review", "/goal", "bad"]
        )

        XCTAssertTrue(snapshot.slashCommands.contains("/goal"))
        XCTAssertTrue(snapshot.slashCommands.contains("/review"))
        XCTAssertFalse(snapshot.slashCommands.contains("bad"),
                       "provider snapshot command lists must keep only slash commands so composer suggestions never insert invalid provider command text")
        XCTAssertEqual(snapshot.slashCommands.filter { $0 == "/goal" }.count, 1)
    }

    func test_providerSnapshotWarnsWhenProviderUpdateIsAvailable() {
        let models = [AgentModelDescriptor(id: "claude-opus-4-7", label: "Claude Opus 4.7", provider: .claude)]

        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .claude,
            models: models,
            binaryPath: "/usr/local/bin/claude",
            updateState: "update_available",
            advisory: "Update available: Claude Code 2.2.0"
        )

        XCTAssertEqual(snapshot.updateState, "update_available")
        XCTAssertEqual(snapshot.advisory, "Update available: Claude Code 2.2.0")
        XCTAssertEqual(snapshot.status, .warning)
        XCTAssertEqual(snapshot.statusDetail, "Update available: Claude Code 2.2.0",
                       "provider status cards must show stale CLI advisories before long-running agent work starts on an outdated provider")
    }

    func test_grokIsFirstClassProviderInAllCasesAndSnapshot() {
        XCTAssertTrue(AgentProvider.allCases.contains(.grok),
                      "Grok must be selectable on the same Source surface as Codex/Claude")
        XCTAssertEqual(AgentProvider.grok.rawValue, "grok")

        let models = [AgentModelDescriptor(id: "grok-4.5", label: "Grok 4.5", provider: .grok)]
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .grok,
            models: models,
            binaryPath: "/Users/me/.grok/bin/grok",
            version: "grok 0.2.93",
            authenticated: true
        )

        XCTAssertEqual(snapshot.provider, .grok)
        XCTAssertEqual(snapshot.driverKind, .grokCLI)
        XCTAssertEqual(snapshot.displayName, "Grok")
        XCTAssertEqual(snapshot.id, "grok-cli")
        XCTAssertTrue(snapshot.installed)
        XCTAssertEqual(snapshot.status, .available)
        XCTAssertEqual(snapshot.models.first?.provider, .grok)
        XCTAssertFalse(snapshot.slashCommands.isEmpty,
                       "composer slash defaults must exist for Grok like other providers")
    }

    func test_grokWireDecodeDoesNotRemapToCodexOrClaude() throws {
        let json = #"{"id":"grok-4.5","label":"Grok 4.5","provider":"grok","supportsReasoning":true}"#.data(using: .utf8)!
        let descriptor = try JSONDecoder().decode(AgentModelDescriptor.self, from: json)
        XCTAssertEqual(descriptor.provider, .grok)
        XCTAssertNotEqual(descriptor.provider, .codex)
        XCTAssertNotEqual(descriptor.provider, .claude)

        let snapshotJSON = """
        {"id":"grok-cli","provider":"grok","driverKind":"grok_cli","displayName":"Grok",
         "accentColor":"#1DA1F2","continuationGroup":"xai-grok","interactionModes":["default","plan"],
         "enabled":true,"installed":true,"status":"available","environmentKeys":[],
         "models":[],"slashCommands":["/model"],"skills":[]}
        """.data(using: .utf8)!
        let snapshot = try JSONDecoder().decode(AgentProviderSnapshot.self, from: snapshotJSON)
        XCTAssertEqual(snapshot.provider, .grok)
        XCTAssertEqual(snapshot.driverKind, .grokCLI)
    }
}
