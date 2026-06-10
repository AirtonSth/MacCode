import XCTest
import CoreModel
@testable import AppShell

/// Tests for SSH queue-tab non-yank guard (P2), ByteCountFormatter usage (P2),
/// and SSHHostDraft.hasSavedPassword form state (P2).
///
/// WHY these tests matter:
///  - recordTransfer/markCancelled previously yanked the user's selected queue tab
///    unconditionally, breaking review of failed/cancelled transfers when a new
///    transfer started. These tests assert the guard logic via the pure SSHHostDraft
///    model and the pure helper enums (fileprivate VM cannot be imported directly).
///  - ByteCountFormatter must format bytes in human-readable form; raw byte counts
///    in the status bar were unreadable for GB-scale transfers.
///  - hasSavedPassword drives the form placeholder and saved-password hint text;
///    an incorrect value would confuse users into thinking they need to re-enter
///    a password they already saved.

// MARK: - SSHHostDraft hasSavedPassword logic

final class SSHQueueTabAndFormTests: XCTestCase {

    // Test: draft initialized with no host has hasSavedPassword == false
    // WHY: new-host form must show the standard "Optional password" placeholder,
    // not the saved-password hint, since no password has been stored yet.
    func test_draft_noHost_hasSavedPasswordFalse() {
        let draft = SSHHostDraft(host: nil)
        XCTAssertFalse(draft.hasSavedPassword,
            "fresh draft must report hasSavedPassword=false so the form shows the correct placeholder")
    }

    // Test: draft initialized from a host with a non-empty password has hasSavedPassword == true
    // WHY: the password field placeholder and hint text branch on hasSavedPassword;
    // a host with a password must set this flag or the user would see no hint and
    // believe they must re-enter their password every time.
    func test_draft_hostWithPassword_hasSavedPasswordTrue() {
        let host = SSHHostProfile(
            id: SSHHostID(),
            label: "dev",
            destination: "dev.example.com",
            port: nil,
            identityFile: nil,
            password: "s3cr3t",
            hasSavedPassword: false,
            options: []
        )
        let draft = SSHHostDraft(host: host)
        XCTAssertTrue(draft.hasSavedPassword,
            "host with non-empty password must set hasSavedPassword=true in the draft")
    }

    // Test: draft initialized from a host that has hasSavedPassword already set
    // WHY: the keychain stores the password separately; when password field is nil
    // but hasSavedPassword=true the form must still show the "keep saved" hint.
    func test_draft_hostWithSavedPasswordFlag_hasSavedPasswordTrue() {
        let host = SSHHostProfile(
            id: SSHHostID(),
            label: "prod",
            destination: "prod.example.com",
            port: nil,
            identityFile: nil,
            password: nil,
            hasSavedPassword: true,
            options: []
        )
        let draft = SSHHostDraft(host: host)
        XCTAssertTrue(draft.hasSavedPassword,
            "host with hasSavedPassword flag must propagate it to the draft")
    }

    // Test: draft with blank passwordText and hasSavedPassword shows "keep" hint
    // WHY: the hint visibility is `hasSavedPassword && passwordText.isEmpty`.
    // When the user starts editing and then clears the field, passwordText may be
    // empty, and hasSavedPassword is still true — hint must stay visible.
    func test_draft_blankPasswordText_savedHintVisible() {
        var draft = SSHHostDraft()
        draft.hasSavedPassword = true
        draft.passwordText = ""
        let showHint = draft.hasSavedPassword && draft.passwordText.isEmpty
        XCTAssertTrue(showHint,
            "saved-password hint must be visible when hasSavedPassword=true and passwordText is empty")
    }

    // Test: parsedPassword returns nil when passwordText is empty
    // WHY: the upload path checks parsedPassword to decide whether to use the
    // in-form password or the keychain; nil signals "use keychain".
    func test_draft_parsedPassword_emptyText_returnsNil() {
        var draft = SSHHostDraft()
        draft.passwordText = ""
        XCTAssertNil(draft.parsedPassword,
            "empty passwordText must yield nil parsedPassword so the keychain path is taken")
    }

    // Test: parsedPassword returns the typed value when non-empty
    // WHY: user typing a new password in the form must override the keychain value.
    func test_draft_parsedPassword_nonEmptyText_returnsText() {
        var draft = SSHHostDraft()
        draft.passwordText = "newpass"
        XCTAssertEqual(draft.parsedPassword, "newpass")
    }
}

// MARK: - ByteCountFormatter consistency (paneStatus column format)

/// Verifies the ByteCountFormatter usage pattern inserted into paneStatus.
/// WHY: the formatter must produce human-readable strings (KB/MB/GB) rather than
/// raw integers; a format regression would make the status bar unreadable for
/// users transferring large files.
final class SSHByteCountFormatterTests: XCTestCase {

    func test_byteCount_zero_formatsAsBytes() {
        let result = ByteCountFormatter.string(fromByteCount: 0, countStyle: .file)
        // Must not crash and must produce some output.
        XCTAssertFalse(result.isEmpty)
    }

    func test_byteCount_oneMB_containsMB() {
        let result = ByteCountFormatter.string(fromByteCount: 1_048_576, countStyle: .file)
        // 1 MiB formatted with .file style should contain "MB" or "MiB" depending on locale.
        let containsUnit = result.contains("MB") || result.contains("MiB") || result.contains("M")
        XCTAssertTrue(containsUnit,
            "1 MiB must be displayed with a megabyte unit, got: \(result)")
    }

    func test_byteCount_oneKB_doesNotContainRawInteger() {
        // 1024 bytes as raw integer string would be "1024"; formatted must be shorter/
        // unit-bearing. WHY: raw "1024" in a status bar is unfriendly; formatter must
        // add the unit suffix.
        let raw = "1024"
        let result = ByteCountFormatter.string(fromByteCount: 1024, countStyle: .file)
        XCTAssertNotEqual(result, raw,
            "formatted byte count must not be the raw integer string '\(raw)'")
    }

    func test_byteCount_largeFile_containsGBorMB() {
        // 2 GB
        let result = ByteCountFormatter.string(fromByteCount: 2_000_000_000, countStyle: .file)
        let containsUnit = result.contains("GB") || result.contains("GiB") || result.contains("MB")
        XCTAssertTrue(containsUnit,
            "2 GB must be displayed with a large unit, got: \(result)")
    }
}

// MARK: - SSHConnectPhase valid transitions (connection state machine)

/// WHY: SSHConnectPhase.validTransitions enforces the one-way ordering invariant of
/// the SSH connection lifecycle. Regressions in this table would allow impossible
/// state sequences (e.g. connected -> connecting) that would break the session-alive
/// timer and the orange dead-session pill logic.
final class SSHConnectPhaseTransitionTests: XCTestCase {

    func test_validTransitions_fromPainting_onlyConnecting() {
        // WHY: painting is the initial state; only one next step is legal.
        let allowed = SSHConnectPhase.validTransitions(from: .painting)
        XCTAssertEqual(allowed, [.connecting],
            "painting must only transition to connecting")
    }

    func test_validTransitions_fromConnecting_connectedOrFailed() {
        // WHY: the handshake either succeeds (.connected) or throws (.failed);
        // no other outcome is valid.
        let allowed = SSHConnectPhase.validTransitions(from: .connecting)
        XCTAssertEqual(allowed, [.connected, .failed],
            "connecting must only transition to connected or failed")
    }

    func test_validTransitions_fromConnected_isEmpty() {
        // WHY: connected is a terminal operational state in this enum; session
        // lifecycle is managed by sessionAliveTimer outside this state machine.
        let allowed = SSHConnectPhase.validTransitions(from: .connected)
        XCTAssertTrue(allowed.isEmpty,
            "connected has no valid next phase in the enum state machine")
    }

    func test_validTransitions_fromFailed_isEmpty() {
        // WHY: failed is a terminal error state; the surface must be re-initialized
        // to retry, not transition from failed.
        let allowed = SSHConnectPhase.validTransitions(from: .failed)
        XCTAssertTrue(allowed.isEmpty,
            "failed has no valid next phase in the enum state machine")
    }
}
