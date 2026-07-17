import XCTest
@testable import AppShell

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
        XCTAssertEqual(approval.detail, "Remote Code · Codex")
        XCTAssertEqual(secretQuestion.title, "Secret input requested")
        XCTAssertEqual(secretQuestion.detail, "Remote Code · Codex")
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
}
