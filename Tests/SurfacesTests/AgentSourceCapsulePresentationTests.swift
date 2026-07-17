import XCTest
@testable import Surfaces
import CoreModel

/// WHY: Personal vs work ChatGPT/Claude accounts share the same provider type.
/// The composer capsule is the only always-visible control that shows which
/// account will execute the next turn. These pure rules must stay correct so
/// the UI never invents labels, silently collapses instances, or stays
/// interactive after a thread locks.
final class AgentSourceCapsulePresentationTests: XCTestCase {

    func test_capsuleLabel_prefersDisplayNameOverAccountAndProvider() {
        let snapshot = makeSnapshot(
            id: "codex-work",
            provider: .codex,
            displayName: "Codex Work",
            accountLabel: "work@example.com"
        )
        let label = AgentSourceCapsulePresentation.capsuleLabel(
            selected: snapshot,
            fallbackProvider: .codex,
            fallbackInstanceId: "codex-work",
            snapshots: [snapshot]
        )
        XCTAssertEqual(label, "Codex Work",
                       "configured instance displayName is the user-facing account identity")
    }

    func test_capsuleLabel_fallsBackToAccountLabelWhenDisplayNameEmpty() {
        let snapshot = makeSnapshot(
            id: "claude-personal",
            provider: .claude,
            displayName: "   ",
            accountLabel: "me@personal.dev"
        )
        let label = AgentSourceCapsulePresentation.capsuleLabel(
            selected: snapshot,
            fallbackProvider: .claude,
            fallbackInstanceId: "claude-personal",
            snapshots: [snapshot]
        )
        XCTAssertEqual(label, "me@personal.dev",
                       "accountLabel is the next-best identity when displayName is blank")
    }

    func test_capsuleLabel_disambiguatesIdenticalNamesAcrossProviders() {
        let workCodex = makeSnapshot(id: "codex-work", provider: .codex, displayName: "Work")
        let workClaude = makeSnapshot(id: "claude-work", provider: .claude, displayName: "Work")
        let label = AgentSourceCapsulePresentation.capsuleLabel(
            selected: workClaude,
            fallbackProvider: .claude,
            fallbackInstanceId: "claude-work",
            snapshots: [workCodex, workClaude]
        )
        XCTAssertEqual(label, "Claude · Work",
                       "identical display names on different providers must not collapse into one ambiguous chip")
    }

    func test_capsuleLabel_disambiguatesIdenticalNamesOnSameProviderWithId() {
        let a = makeSnapshot(id: "codex-a", provider: .codex, displayName: "Codex Work")
        let b = makeSnapshot(id: "codex-b", provider: .codex, displayName: "Codex Work")
        let label = AgentSourceCapsulePresentation.capsuleLabel(
            selected: b,
            fallbackProvider: .codex,
            fallbackInstanceId: "codex-b",
            snapshots: [a, b]
        )
        XCTAssertEqual(label, "Codex Work · codex-b",
                       "same-provider clones with identical labels need a stable id disambiguator, not path guessing")
    }

    func test_isInteractive_requiresMultipleUnlockedSources() {
        XCTAssertTrue(
            AgentSourceCapsulePresentation.isInteractive(
                enabledSourceCount: 2,
                providerLocked: false,
                runLocked: false
            ),
            "personal/work switching is only meaningful when more than one source is available"
        )
        XCTAssertFalse(
            AgentSourceCapsulePresentation.isInteractive(
                enabledSourceCount: 1,
                providerLocked: false,
                runLocked: false
            ),
            "a single source must render as provenance, not a fake switcher"
        )
        XCTAssertFalse(
            AgentSourceCapsulePresentation.isInteractive(
                enabledSourceCount: 3,
                providerLocked: true,
                runLocked: false
            ),
            "after the first message the account is fixed for the thread"
        )
        XCTAssertFalse(
            AgentSourceCapsulePresentation.isInteractive(
                enabledSourceCount: 3,
                providerLocked: false,
                runLocked: true
            ),
            "mid-run account switching would desync the displayed source from the active provider process"
        )
    }

    func test_menuEntries_keepSelectedDisabledSnapshotVisible() {
        let personal = makeSnapshot(id: "codex-personal", provider: .codex, displayName: "Codex Personal", enabled: true)
        let work = makeSnapshot(id: "codex-work", provider: .codex, displayName: "Codex Work", enabled: false)
        let entries = AgentSourceCapsulePresentation.menuEntries(
            snapshots: [personal, work],
            selectedSnapshotId: "codex-work",
            selectedProvider: .codex,
            providerDisplayName: { $0.rawValue.capitalized }
        )
        XCTAssertEqual(entries.map(\.id), ["codex-personal", "codex-work"],
                       "a thread bound to a now-disabled instance must still show that account so it is not silently rewritten")
        XCTAssertEqual(entries.first(where: { $0.id == "codex-work" })?.isSelected, true)
        XCTAssertEqual(entries.first(where: { $0.id == "codex-personal" })?.isSelected, false)
    }

    func test_menuEntries_fallBackToProvidersWhenSnapshotsEmpty() {
        let entries = AgentSourceCapsulePresentation.menuEntries(
            snapshots: [],
            selectedSnapshotId: nil,
            selectedProvider: .claude,
            providerDisplayName: { $0.rawValue.capitalized }
        )
        XCTAssertEqual(entries.map(\.id), AgentProvider.allCases.map(\.rawValue),
                       "before snapshots load, the capsule must still offer the built-in provider set")
        XCTAssertEqual(entries.first(where: { $0.id == "claude" })?.isSelected, true)
    }

    private func makeSnapshot(
        id: String,
        provider: AgentProvider,
        displayName: String,
        accountLabel: String? = nil,
        enabled: Bool = true
    ) -> AgentProviderSnapshot {
        AgentProviderSnapshot(
            id: id,
            provider: provider,
            driverKind: {
                switch provider {
                case .codex: return .codexCLI
                case .claude: return .claudeCLI
                case .grok: return .grokCLI
                }
            }(),
            displayName: displayName,
            accentColor: "#2F80ED",
            continuationGroup: provider.rawValue,
            interactionModes: [.default],
            enabled: enabled,
            installed: true,
            status: .available,
            accountLabel: accountLabel,
            models: [],
            slashCommands: []
        )
    }
}
