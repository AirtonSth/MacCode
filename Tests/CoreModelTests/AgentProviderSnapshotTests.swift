import XCTest
@testable import CoreModel

final class AgentProviderSnapshotTests: XCTestCase {
    func test_grokSnapshotUsesNegotiatedInteractionModesWhenProvided() {
        let capabilities = AgentProviderCapabilities(
            supportsAttachments: true,
            supportedAttachmentKinds: [.file],
            supportsApprovals: true,
            supportsStreaming: true,
            supportsPlanReview: true
        )
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .grok,
            models: [AgentModelDescriptor(id: "grok-live", label: "Grok Live", provider: .grok)],
            binaryPath: "/tmp/grok",
            interactionModesOverride: [.default, .plan],
            permissionModesOverride: [.supervised],
            capabilitiesOverride: capabilities
        )

        XCTAssertEqual(snapshot.interactionModes, [.default, .plan])
        XCTAssertEqual(snapshot.effectivePermissionModes, [.supervised])
        XCTAssertEqual(snapshot.effectiveCapabilities, capabilities)
        XCTAssertTrue(snapshot.slashCommands.contains("/plan"))
    }

    func test_grokSnapshotDefaultsExposeFullAccessWithoutDiscoveryOverride() {
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .grok,
            models: [AgentModelDescriptor(id: "grok-4.5", label: "Grok 4.5", provider: .grok)],
            binaryPath: "/tmp/grok"
        )

        XCTAssertEqual(snapshot.effectivePermissionModes, AgentPermissionMode.allCases,
                       "pre-discovery Grok snapshots must keep Full access selectable")
        XCTAssertTrue(snapshot.effectivePermissionModes.contains(.fullAccess))
    }

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

    func test_providerCapabilitiesDecodeMissingNewFlagsFailClosed() throws {
        let json = #"{"supportsAttachments":true,"supportedAttachmentKinds":["file"],"supportedAttachmentMediaTypes":["text/plain"],"supportsApprovals":true,"supportsUserInput":false,"supportsStreaming":true,"supportsFork":false,"supportsRollback":false}"#.data(using: .utf8)!

        let capabilities = try JSONDecoder().decode(AgentProviderCapabilities.self, from: json)

        XCTAssertTrue(capabilities.supportsAttachments)
        XCTAssertFalse(capabilities.supportsPlanReview,
                       "older cached provider snapshots must not gain Plan review capability during decode")
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
        XCTAssertTrue(snapshot.slashCommands.contains("/goal"),
                      "Grok must advertise /goal so composer autocomplete and $goal work on every provider")
    }

    func test_everyProviderDefaultSlashCatalogIncludesGoal() {
        let models: [AgentProvider: [AgentModelDescriptor]] = [
            .codex: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            .claude: [AgentModelDescriptor(id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6", provider: .claude)],
            .grok: [AgentModelDescriptor(id: "grok-4.5", label: "Grok 4.5", provider: .grok)]
        ]
        for provider in AgentProvider.allCases {
            let snapshot = AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: models[provider] ?? [],
                binaryPath: "/usr/local/bin/\(provider.rawValue)"
            )
            XCTAssertTrue(snapshot.slashCommands.contains("/goal"),
                          "\(provider.rawValue) snapshot defaults must include /goal for cross-provider composer parity")
        }
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

    func test_legacyProviderSnapshotDefaultsToNoUnprovenInteractiveCapabilities() throws {
        let json = """
        {"id":"legacy-grok","provider":"grok","driverKind":"grok_cli","displayName":"Grok",
         "accentColor":"#1DA1F2","continuationGroup":"xai-grok","interactionModes":["default","plan"],
         "enabled":true,"installed":true,"status":"available","environmentKeys":[],
         "models":[],"slashCommands":["/plan","/fork"],"skills":[]}
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(AgentProviderSnapshot.self, from: json)

        XCTAssertEqual(snapshot.effectiveCapabilities, .conservative,
                       "older snapshots must fail closed instead of exposing attachments, approvals, questions, fork, rollback, or plan review without proof")
    }

    func test_factoryPublishesProviderSpecificCapabilityTruth() {
        let codex = AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: "/usr/local/bin/codex"
        )
        let claude = AgentProviderSnapshotFactory.snapshot(
            provider: .claude,
            models: [AgentModelDescriptor(id: "claude-opus-4-7", label: "Claude", provider: .claude)],
            binaryPath: "/usr/local/bin/claude"
        )
        let grok = AgentProviderSnapshotFactory.snapshot(
            provider: .grok,
            models: [AgentModelDescriptor(id: "grok-4.5", label: "Grok", provider: .grok)],
            binaryPath: "/usr/local/bin/grok"
        )

        XCTAssertTrue(codex.effectiveCapabilities.supportsAttachments)
        XCTAssertTrue(codex.effectiveCapabilities.supportsApprovals)
        XCTAssertTrue(codex.effectiveCapabilities.supportsUserInput)
        XCTAssertTrue(codex.effectiveCapabilities.supportsStreaming)
        XCTAssertFalse(codex.effectiveCapabilities.supportsFork,
                       "Codex thread/fork has no provider idempotency key, so crash-safe local/provider commit cannot be promised")
        XCTAssertFalse(codex.slashCommands.contains("/fork"),
                       "an unsafe provider fork must not remain advertised as a callable slash command")
        XCTAssertTrue(codex.effectiveCapabilities.supportsRollback)
        XCTAssertFalse(codex.effectiveCapabilities.supportedAttachmentMediaTypes.isEmpty)

        XCTAssertTrue(claude.effectiveCapabilities.supportsAttachments)
        XCTAssertTrue(claude.effectiveCapabilities.supportsApprovals)
        XCTAssertTrue(claude.effectiveCapabilities.supportsUserInput)
        XCTAssertFalse(claude.effectiveCapabilities.supportsFork,
                       "the current Claude bridge must not promise native fork before a provider contract proves it")
        XCTAssertEqual(
            Set(claude.effectiveCapabilities.supportedAttachmentMediaTypes),
            Set(["image/jpeg", "image/png", "image/gif", "image/webp"]),
            "Claude attachment gating must match the SDK bridge formats exactly"
        )

        XCTAssertEqual(grok.effectiveCapabilities, .conservative,
                       "a failed or absent Grok ACP discovery must fail closed instead of inventing capabilities")
        XCTAssertFalse(grok.interactionModes.contains(.plan),
                       "Grok Plan must stay hidden until plan review and continuation are implemented")
        XCTAssertFalse(grok.slashCommands.contains("/fork"),
                       "Grok fork must stay hidden until the provider creates a real forked session")
    }

    func test_claudeSnapshotPublishesExplicitDegradedTextOnlyContract() {
        let degraded = AgentProviderCapabilities(
            supportsAttachments: false,
            supportedAttachmentKinds: [],
            supportedAttachmentMediaTypes: [],
            supportsApprovals: false,
            supportsUserInput: false,
            supportsStreaming: true,
            supportsFork: false,
            supportsRollback: false,
            supportsPlanReview: false
        )

        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .claude,
            models: [AgentModelDescriptor(id: "sonnet", label: "Sonnet", provider: .claude)],
            binaryPath: "/usr/local/bin/claude",
            advisory: "Degraded text-only fallback: Claude Agent SDK is disabled.",
            interactionModesOverride: [.default],
            permissionModesOverride: [.supervised],
            capabilitiesOverride: degraded
        )

        XCTAssertEqual(snapshot.status, .warning,
                       "a text-only fallback must never look equivalent to the full Claude Agent SDK runtime")
        XCTAssertEqual(snapshot.interactionModes, [.default])
        XCTAssertEqual(snapshot.permissionModes, [.supervised])
        XCTAssertEqual(snapshot.effectiveCapabilities, degraded)
        XCTAssertFalse(snapshot.slashCommands.contains("/plan"),
                       "the degraded text-only fallback must not advertise a plan workflow that depends on agent tools")
        XCTAssertEqual(snapshot.statusDetail, "Degraded text-only fallback: Claude Agent SDK is disabled.")
    }
}
