import XCTest
@testable import AppShell
import CoreModel

final class PetAttentionPresentationTests: XCTestCase {
    func test_badgeHidesAtZeroCapsAtNinetyNinePlusAndHonorsSetting() {
        XCTAssertNil(PetAttentionCountFormatter.badgeText(count: 0))
        XCTAssertEqual(PetAttentionCountFormatter.badgeText(count: 1), "1")
        XCTAssertEqual(PetAttentionCountFormatter.badgeText(count: 99), "99")
        XCTAssertEqual(PetAttentionCountFormatter.badgeText(count: 100), "99+")
        XCTAssertEqual(PetAttentionCountFormatter.badgeText(count: 10_000), "99+")
        XCTAssertNil(PetAttentionCountFormatter.badgeText(count: 7, isEnabled: false))
        XCTAssertNil(PetAttentionCountFormatter.badgeText(count: -1))
    }

    func test_activeThreadBadgeHidesAtZeroCapsAtNinetyNinePlusAndIsNotSettingGated() {
        XCTAssertNil(PetActiveThreadCountFormatter.badgeText(count: 0))
        XCTAssertEqual(PetActiveThreadCountFormatter.badgeText(count: 1), "1")
        XCTAssertEqual(PetActiveThreadCountFormatter.badgeText(count: 99), "99")
        XCTAssertEqual(PetActiveThreadCountFormatter.badgeText(count: 100), "99+")
        XCTAssertNil(PetActiveThreadCountFormatter.badgeText(count: -1))
    }

    func test_accessibilityCountUsesZeroSingularAndPluralCopy() {
        XCTAssertEqual(
            PetAttentionCountFormatter.accessibilityValue(count: 0),
            "No items need attention"
        )
        XCTAssertEqual(
            PetAttentionCountFormatter.accessibilityValue(count: 1),
            "1 item needs attention"
        )
        XCTAssertEqual(
            PetAttentionCountFormatter.accessibilityValue(count: 2),
            "2 items need attention"
        )
        XCTAssertEqual(
            PetAttentionCountFormatter.accessibilityValue(count: -4),
            "No items need attention"
        )
        XCTAssertEqual(
            PetActiveThreadCountFormatter.accessibilityValue(count: 0),
            "No active agent threads"
        )
        XCTAssertEqual(
            PetActiveThreadCountFormatter.accessibilityValue(count: 1),
            "1 active agent thread"
        )
        XCTAssertEqual(
            PetActiveThreadCountFormatter.accessibilityValue(count: 3),
            "3 active agent threads"
        )
        XCTAssertEqual(
            PetActiveThreadCountFormatter.combinedAccessibilityValue(activeCount: 2, attentionCount: 1),
            "2 active agent threads. 1 item needs attention"
        )
        XCTAssertEqual(
            PetActiveThreadCountFormatter.combinedAccessibilityValue(activeCount: 0, attentionCount: 1),
            "1 item needs attention"
        )
        XCTAssertEqual(
            PetActiveThreadCountFormatter.combinedAccessibilityValue(activeCount: 2, attentionCount: 0),
            "2 active agent threads"
        )
    }

    func test_sensitiveCallbackContentNeverReachesPetTitleOrDetail() {
        let raw = PetAttentionRawContent(
            title: "Run rm -rf /Users/example/private",
            detail: "Authorization: Bearer top-secret-token"
        )
        let context = PetAttentionContext(workspaceName: "Remote Code", providerName: "Codex")

        let approval = PetAttentionPresentation.safe(
            kind: .approval,
            context: context,
            untrusted: raw
        )
        let secretQuestion = PetAttentionPresentation.safe(
            kind: .question(isSecret: true),
            context: context,
            untrusted: raw
        )

        XCTAssertEqual(approval.title, "Approval required")
        XCTAssertEqual(approval.detail, "Remote Code - Codex")
        XCTAssertEqual(secretQuestion.title, "Secret input requested")
        XCTAssertEqual(secretQuestion.detail, "Remote Code - Codex")
        for output in [approval.title, approval.detail, secretQuestion.title, secretQuestion.detail].compactMap({ $0 }) {
            XCTAssertFalse(output.contains("rm -rf"))
            XCTAssertFalse(output.contains("/Users/"))
            XCTAssertFalse(output.contains("top-secret-token"))
        }
    }

    func test_everyAttentionKindUsesFixedHumanReadableCopy() {
        let raw = PetAttentionRawContent(
            title: "Private prompt: run rm -rf /Users/private",
            detail: "password=hunter2 Authorization: Bearer secret-token"
        )
        let expected: [(PetAttentionKind, String)] = [
            (.agentOutcome(.completed), "Agent run completed"),
            (.agentOutcome(.failed), "Agent run failed"),
            (.agentOutcome(.interrupted), "Agent run interrupted"),
            (.agentRunning, "Agent run in progress"),
            (.approval, "Approval required"),
            (.question(isSecret: false), "Input requested"),
            (.question(isSecret: true), "Secret input requested"),
            (.fileConflict, "File conflict needs review"),
            (.gitDelivery(.succeeded), "Git delivery completed"),
            (.gitDelivery(.failed), "Git delivery failed"),
            (.projectScript(.succeeded), "Project script completed"),
            (.projectScript(.failed), "Project script failed"),
            (.sshTransfer(.succeeded), "SSH transfer completed"),
            (.sshTransfer(.failed), "SSH transfer failed"),
            (.providerUpdateFailed, "Provider update failed"),
            (.serverListenerFailed, "Remote Code listener needs attention")
        ]

        for (kind, title) in expected {
            let presentation = PetAttentionPresentation.safe(kind: kind, untrusted: raw)
            XCTAssertEqual(
                presentation.title,
                title,
                "Pet rows must describe an outcome without exposing raw operation data."
            )
            XCTAssertNil(presentation.detail)
            for secret in ["Private prompt", "rm -rf", "/Users/private", "hunter2", "secret-token"] {
                XCTAssertFalse(presentation.title.contains(secret))
            }
        }
        XCTAssertEqual(
            PetNotificationCategory.sshUnexpectedDisconnect.presentation,
            PetAttentionPresentation(title: "SSH connection needs attention", detail: nil)
        )
        XCTAssertEqual(
            PetNotificationCategory.serverListenerFailed.presentation,
            PetAttentionPresentation(title: "Remote access needs attention", detail: nil)
        )
        XCTAssertEqual(
            PetNotificationCategory.notificationsDenied.presentation,
            PetAttentionPresentation(
                title: "Notifications are turned off",
                detail: "Open System Settings to re-enable them."
            )
        )
        XCTAssertEqual(
            PetNotificationCategory.agentAttention.presentation,
            PetAttentionPresentation(title: "Agent input requested", detail: nil)
        )
    }

    func test_contextLabelsCollapseWhitespaceCapLengthAndRedactCredentials() {
        XCTAssertEqual(
            PetAttentionRedactor.safeContextLabel("  Workspace\n  Alpha  "),
            "Workspace Alpha"
        )
        XCTAssertEqual(
            PetAttentionRedactor.safeContextLabel(String(repeating: "a", count: 100))?.count,
            PetAttentionRedactor.maximumContextCharacters
        )

        let credentials = [
            ("workspace password=hunter2", "hunter2"),
            ("workspace bearer abc123", "abc123"),
            ("workspace Authorization: Bearer auth-value", "auth-value"),
            ("workspace access_token=token-value", "token-value"),
            ("workspace client_secret=secret-value", "secret-value")
        ]
        for (label, secret) in credentials {
            let redacted = PetAttentionRedactor.safeContextLabel(label)
            XCTAssertNotNil(redacted)
            XCTAssertFalse(redacted?.contains(secret) == true)
            XCTAssertTrue(redacted?.contains("[redacted]") == true)
        }
    }

    func test_emptyContextDoesNotCreateDanglingSeparator() {
        XCTAssertNil(PetAttentionPresentation.safe(kind: .approval).detail)
        XCTAssertEqual(
            PetAttentionPresentation.safe(
                kind: .approval,
                context: PetAttentionContext(workspaceName: "Workspace", providerName: nil)
            ).detail,
            "Workspace"
        )
    }

    func test_agentRunDetailJoinsWorkspaceProviderAndThreadTitle() {
        let presentation = PetAttentionPresentation.safe(
            kind: .agentRunning,
            context: PetAttentionContext(
                workspaceName: "star",
                providerName: "Grok",
                threadTitle: "make title for pet notifications"
            )
        )
        XCTAssertEqual(presentation.title, "Agent run in progress")
        XCTAssertEqual(
            presentation.detail,
            "star - Grok - \(AgentThreadTitle.display("make title for pet notifications"))"
        )

        let completed = PetAttentionPresentation.safe(
            kind: .agentOutcome(.completed),
            context: PetAttentionContext(
                workspaceName: "star",
                providerName: "Grok",
                threadTitle: "make title…"
            )
        )
        XCTAssertEqual(completed.title, "Agent run completed")
        XCTAssertEqual(completed.detail, "star - Grok - make title…")

        let providerOnly = PetAttentionPresentation.safe(
            kind: .agentRunning,
            context: PetAttentionContext(providerName: "Grok")
        )
        XCTAssertEqual(providerOnly.detail, "Grok")

        let redacted = PetAttentionPresentation.safe(
            kind: .agentRunning,
            context: PetAttentionContext(
                workspaceName: "star",
                providerName: "Grok",
                threadTitle: "fix auth password=hunter2"
            )
        )
        XCTAssertEqual(redacted.detail, "star - Grok - fix auth password=[redacted]")
        XCTAssertFalse(redacted.detail?.contains("hunter2") == true)

        let placeholderOmitted = PetAttentionPresentation.safe(
            kind: .agentRunning,
            context: PetAttentionContext(
                workspaceName: "star",
                providerName: "Grok",
                threadTitle: AgentThreadTitle.defaultTitle
            )
        )
        XCTAssertEqual(placeholderOmitted.detail, "star - Grok")
    }

    func test_approvalTitlesUseFixedActionLabelsNotRawCommands() {
        let approve = PetAttentionPresentation.safe(
            kind: .approval,
            context: PetAttentionContext(
                workspaceName: "star",
                providerName: "Grok",
                threadTitle: "ship labels",
                actionLabel: PetApprovalActionLabel.label(for: .commandExecution)
            ),
            untrusted: PetAttentionRawContent(
                title: "Run rm -rf /Users/private",
                detail: "password=hunter2"
            )
        )
        XCTAssertEqual(approve.title, "Approve: Run command")
        XCTAssertEqual(approve.detail, "star - Grok - ship labels")
        XCTAssertFalse(approve.title.contains("rm -rf"))
        XCTAssertFalse(approve.detail?.contains("hunter2") == true)

        XCTAssertEqual(PetApprovalActionLabel.label(for: .fileChange), "Edit file")
        XCTAssertEqual(PetApprovalActionLabel.label(for: .applyPatch), "Apply patch")
        XCTAssertEqual(PetApprovalActionLabel.label(for: .fileRead), "Read file")
    }

    func test_elapsedFormatterAndRunningDetailAppendElapsed() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(PetElapsedFormatter.label(from: start, now: start.addingTimeInterval(12)), "12s")
        XCTAssertEqual(PetElapsedFormatter.label(from: start, now: start.addingTimeInterval(125)), "2m")
        XCTAssertEqual(PetElapsedFormatter.label(from: start, now: start.addingTimeInterval(3_700)), "1h 1m")
        XCTAssertNil(PetElapsedFormatter.label(from: start, now: start.addingTimeInterval(-5)))

        let running = PetAttentionPresentation.safe(
            kind: .agentRunning,
            context: PetAttentionContext(
                workspaceName: "star",
                providerName: "Grok",
                threadTitle: "labels",
                elapsedLabel: "2m"
            )
        )
        XCTAssertEqual(running.detail, "star - Grok - labels - 2m")
    }

    func test_popoverGroupsByWorkspaceAlphabeticallyWithOtherLast() {
        let a = PetActiveThreadItem(
            threadID: AgentThreadID(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!),
            workspaceID: nil,
            workspaceName: "zeta",
            providerName: "Grok",
            threadTitle: "z"
        )
        let b = PetActiveThreadItem(
            threadID: AgentThreadID(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!),
            workspaceID: nil,
            workspaceName: "alpha",
            providerName: "Grok",
            threadTitle: "a"
        )
        let c = PetActiveThreadItem(
            threadID: AgentThreadID(UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!),
            workspaceID: nil,
            workspaceName: nil,
            providerName: "Claude",
            threadTitle: "other"
        )
        let groups = PetPopoverGrouping.active([a, b, c])
        XCTAssertEqual(groups.map(\.name), ["alpha", "zeta", "Other"])
        XCTAssertEqual(groups.map { $0.items.map(\.threadID) }, [
            [b.threadID],
            [a.threadID],
            [c.threadID]
        ])
    }
}
