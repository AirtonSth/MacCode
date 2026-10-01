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
            "a single source must not enable mutation rows (popover still opens to explain)"
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

    func test_isInteractive_runLockedMeansActiveRunOnly() {
        // Regression: treating "current provider cannot run" as runLocked made
        // the Source capsule a dead control — click did nothing and the user
        // could not switch away from an unauthenticated/unavailable account.
        // Call sites pass only selectedThreadRunIsStartingOrRunning here.
        XCTAssertTrue(
            AgentSourceCapsulePresentation.isInteractive(
                enabledSourceCount: 3,
                providerLocked: false,
                runLocked: false
            ),
            "an unauthenticated current provider must not be modeled as runLocked; the menu stays switchable"
        )
    }

    func test_helpTextAndLockNoticeMatchTheAgentAppCopy() {
        // WHY: Desk used to invent "Claude, Codex, or Grok" help while Agent App
        // explained lock / unavailable / single-account. Shared strings.
        XCTAssertEqual(
            AgentSourceCapsulePresentation.helpText(
                canSwitch: true,
                runLocked: false,
                providerLocked: false,
                unavailableReason: nil
            ),
            "Choose the provider or account that runs this thread"
        )
        XCTAssertEqual(
            AgentSourceCapsulePresentation.helpText(
                canSwitch: false,
                runLocked: true,
                providerLocked: false,
                unavailableReason: nil
            ),
            "Account is fixed while a run is active"
        )
        XCTAssertEqual(
            AgentSourceCapsulePresentation.lockNotice(
                runLocked: false,
                providerLocked: true,
                unavailableReason: nil,
                entryCount: 3
            )?.text,
            "Account is fixed after the first message. Start a new thread to use a different account."
        )
        XCTAssertEqual(
            AgentSourceCapsulePresentation.lockNotice(
                runLocked: false,
                providerLocked: false,
                unavailableReason: nil,
                entryCount: 1
            )?.text,
            "Only one account is available"
        )
        let warning = AgentSourceCapsulePresentation.lockNotice(
            runLocked: false,
            providerLocked: false,
            unavailableReason: "Claude is not signed in",
            entryCount: 2
        )
        XCTAssertEqual(warning?.text, "Claude is not signed in")
        XCTAssertEqual(warning?.isWarning, true)
    }

    func test_menuEntries_offerOnlyDistill_becauseLegacyProvidersAreNoLongerSelectable() {
        let codex = makeSnapshot(id: "codex-cli", provider: .codex, displayName: "Codex", enabled: true)
        let distill = makeSnapshot(id: "distill-acp", provider: .distill, displayName: "Distill", enabled: true)
        let entries = AgentSourceCapsulePresentation.menuEntries(
            snapshots: [codex, distill],
            selectedSnapshotId: "codex-cli",
            selectedProvider: .codex,
            providerDisplayName: { $0.rawValue.capitalized }
        )
        XCTAssertEqual(entries.map(\.id), ["distill-acp"])
        XCTAssertFalse(AgentSourceCapsulePresentation.isVisible(entryCount: entries.count),
                       "one Distill instance means no choice, so the capsule is removed")
        XCTAssertTrue(AgentSourceCapsulePresentation.isVisible(entryCount: 2))
    }

    func test_menuEntries_fallBackToDistillWhenSnapshotsEmpty() {
        let entries = AgentSourceCapsulePresentation.menuEntries(
            snapshots: [],
            selectedSnapshotId: nil,
            selectedProvider: .distill,
            providerDisplayName: { $0.rawValue.capitalized }
        )
        XCTAssertEqual(entries.map(\.id), ["distill"])
        XCTAssertEqual(entries.first?.isSelected, true)
    }

    func test_menuEntries_keepSecondDistillInstance_becauseAccountsRemainAChoice() {
        let personal = makeSnapshot(id: "distill-personal", provider: .distill, displayName: "Distill Personal")
        let work = makeSnapshot(id: "distill-work", provider: .distill, displayName: "Distill Work")
        let entries = AgentSourceCapsulePresentation.menuEntries(
            snapshots: [personal, work],
            selectedSnapshotId: "distill-work",
            selectedProvider: .distill,
            providerDisplayName: { $0.rawValue.capitalized }
        )
        XCTAssertEqual(entries.map(\.id), ["distill-personal", "distill-work"])
        XCTAssertEqual(entries.first(where: { $0.id == "distill-work" })?.isSelected, true)
        XCTAssertTrue(AgentSourceCapsulePresentation.isVisible(entryCount: entries.count))
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
                case .distill: return .distillACP
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
