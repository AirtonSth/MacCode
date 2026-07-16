import XCTest
@testable import CoreModel

final class AgentProviderRunPreflightTests: XCTestCase {
    private func snapshot(
        enabled: Bool = true,
        installed: Bool = true,
        authenticated: Bool? = true,
        interactionModes: [AgentInteractionMode] = [.default, .plan],
        permissionModes: [AgentPermissionMode] = AgentPermissionMode.allCases,
        capabilities: AgentProviderCapabilities
    ) -> AgentProviderSnapshot {
        AgentProviderSnapshot(
            id: "provider-test",
            provider: .codex,
            driverKind: .codexCLI,
            displayName: "Provider Test",
            accentColor: "#000000",
            continuationGroup: "test",
            interactionModes: interactionModes,
            permissionModes: permissionModes,
            enabled: enabled,
            installed: installed,
            status: enabled ? (installed ? .available : .unavailable) : .disabled,
            authenticated: authenticated,
            models: [AgentModelDescriptor(id: "model", label: "Model", provider: .codex)],
            slashCommands: [],
            capabilities: capabilities
        )
    }

    private func attachment(kind: AgentAttachmentKind, mimeType: String?) -> AgentAttachment {
        AgentAttachment(
            id: String(repeating: "a", count: 64),
            path: "/managed/blob",
            displayName: "input",
            kind: kind,
            mimeType: mimeType,
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 1
        )
    }

    func test_preflightFailsClosedForMissingDisabledUnavailableAndUnauthenticatedProvider() {
        let capabilities = AgentProviderCapabilities(supportsStreaming: true)
        XCTAssertThrowsError(try AgentProviderRunPreflight.validate(snapshot: nil, interactionMode: .default, permissionMode: .supervised, attachments: []))
        XCTAssertThrowsError(try AgentProviderRunPreflight.validate(snapshot: snapshot(enabled: false, capabilities: capabilities), interactionMode: .default, permissionMode: .supervised, attachments: []))
        XCTAssertThrowsError(try AgentProviderRunPreflight.validate(snapshot: snapshot(installed: false, capabilities: capabilities), interactionMode: .default, permissionMode: .supervised, attachments: []))
        XCTAssertThrowsError(try AgentProviderRunPreflight.validate(snapshot: snapshot(authenticated: false, capabilities: capabilities), interactionMode: .default, permissionMode: .supervised, attachments: []))
    }

    /// WHY: host preflight and the composer must resolve "grok" vs "grok-cli"
    /// and stale instance ids to the live provider row instead of missingSnapshot.
    func test_snapshotSelectionFallsBackToProviderWhenInstanceIdIsStaleOrRawValue() {
        let grok = AgentProviderSnapshotFactory.snapshot(
            provider: .grok,
            models: [AgentModelDescriptor(id: "grok-4.5", label: "Grok 4.5", provider: .grok)],
            binaryPath: "/usr/bin/true",
            id: "grok-cli"
        )
        let codex = AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: "/usr/bin/true",
            id: "codex-cli"
        )
        let snapshots = [codex, grok]

        XCTAssertEqual(
            AgentProviderSnapshotSelection.resolve(snapshots: snapshots, provider: .grok, instanceId: "grok-cli")?.id,
            "grok-cli"
        )
        XCTAssertEqual(
            AgentProviderSnapshotSelection.resolve(snapshots: snapshots, provider: .grok, instanceId: "grok")?.id,
            "grok-cli",
            "raw provider value must fall back to the live grok snapshot id"
        )
        XCTAssertEqual(
            AgentProviderSnapshotSelection.resolve(snapshots: snapshots, provider: .grok, instanceId: "stale-instance")?.id,
            "grok-cli",
            "stale instance ids must not produce missingSnapshot when a same-provider snapshot exists"
        )
        XCTAssertEqual(
            AgentProviderSnapshotSelection.resolve(snapshots: snapshots, provider: .grok, instanceId: "codex-cli")?.id,
            "grok-cli",
            "must never return another provider's instance for a Grok preflight"
        )
        XCTAssertNil(
            AgentProviderSnapshotSelection.resolve(snapshots: [codex], provider: .grok, instanceId: "grok-cli"),
            "must not invent a Grok snapshot from another provider's list"
        )
    }

    func test_preflightRejectsUnsupportedPlanAndPermissionBeforeExecution() {
        let candidate = snapshot(
            interactionModes: [.default],
            permissionModes: [.supervised],
            capabilities: AgentProviderCapabilities(supportsStreaming: true)
        )
        XCTAssertThrowsError(try AgentProviderRunPreflight.validate(snapshot: candidate, interactionMode: .plan, permissionMode: .supervised, attachments: []))
        XCTAssertThrowsError(try AgentProviderRunPreflight.validate(snapshot: candidate, interactionMode: .default, permissionMode: .fullAccess, attachments: []))
    }

    func test_preflightEnforcesAttachmentKindAndExactMIMEMatrix() throws {
        let candidate = snapshot(capabilities: AgentProviderCapabilities(
            supportsAttachments: true,
            supportedAttachmentKinds: [.file, .image],
            supportedAttachmentMediaTypes: ["text/plain", "image/png"]
        ))

        XCTAssertNoThrow(try AgentProviderRunPreflight.validate(snapshot: candidate, interactionMode: .default, permissionMode: .supervised, attachments: [attachment(kind: .file, mimeType: "text/plain")]))
        XCTAssertNoThrow(try AgentProviderRunPreflight.validate(snapshot: candidate, interactionMode: .default, permissionMode: .supervised, attachments: [attachment(kind: .image, mimeType: "image/png")]))
        XCTAssertThrowsError(try AgentProviderRunPreflight.validate(snapshot: candidate, interactionMode: .default, permissionMode: .supervised, attachments: [attachment(kind: .image, mimeType: "image/svg+xml")]))
        XCTAssertThrowsError(try AgentProviderRunPreflight.validate(snapshot: candidate, interactionMode: .default, permissionMode: .supervised, attachments: [attachment(kind: .file, mimeType: nil)]))

        let imageOnly = snapshot(capabilities: AgentProviderCapabilities(
            supportsAttachments: true,
            supportedAttachmentKinds: [.image],
            supportedAttachmentMediaTypes: ["image/png"]
        ))
        XCTAssertThrowsError(try AgentProviderRunPreflight.validate(snapshot: imageOnly, interactionMode: .default, permissionMode: .supervised, attachments: [attachment(kind: .file, mimeType: "text/plain")]))
    }

    func test_preflightUsesExplicitFileWildcardWithoutWeakeningImageMIME() throws {
        let candidate = snapshot(capabilities: AgentProviderCapabilities(
            supportsAttachments: true,
            supportedAttachmentKinds: [.file, .image],
            supportedAttachmentMediaTypes: ["*/*", "image/png"]
        ))

        XCTAssertNoThrow(try AgentProviderRunPreflight.validate(snapshot: candidate, interactionMode: .default, permissionMode: .supervised, attachments: [attachment(kind: .file, mimeType: "application/pdf")]))
        XCTAssertThrowsError(try AgentProviderRunPreflight.validate(snapshot: candidate, interactionMode: .default, permissionMode: .supervised, attachments: [attachment(kind: .image, mimeType: "image/jpeg")]))
    }
}
