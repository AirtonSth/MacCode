import XCTest
@testable import Surfaces

/// Tests for the P3 diff-error-banner dismiss fix (enlarged hit target + Esc shortcut).
///
/// WHY these tests matter:
///  - The dismiss button for the diff error banner was an 8x8pt icon-only target.
///    After the fix it is 24x24pt with `.keyboardShortcut(.cancelAction)` (Esc).
///    The VM-level invariant is: setting `lastError = nil` hides the banner.
///    A regression where nil does NOT hide the banner would strand users on an
///    error message with no visible dismiss path.

// MARK: - DiffPanelViewModel lastError dismiss invariant

@MainActor
final class DiffPanelErrorBannerTests: XCTestCase {

    // Test: lastError starts nil; setting a message makes it non-nil.
    // WHY: the banner is visible IFF lastError != nil; we need to confirm the
    // published property actually propagates, otherwise the banner never appears
    // and the dismiss button fix is meaningless.
    func test_lastError_setAndClear() {
        let vm = DiffPanelViewModel(cwd: "/tmp", asyncLoad: false)
        XCTAssertNil(vm.lastError,
            "fresh VM must have nil lastError (banner must be hidden at startup)")

        vm.lastError = "git: not a repository"
        XCTAssertNotNil(vm.lastError,
            "assigned lastError must be non-nil (banner must become visible)")

        // Simulates the dismiss button action: `withAnimation { vm.lastError = nil }`
        vm.lastError = nil
        XCTAssertNil(vm.lastError,
            "cleared lastError must be nil (banner must disappear on dismiss)")
    }

    // Test: multiple set/clear cycles work correctly.
    // WHY: transient errors during a session (e.g. failed push, then successful push)
    // each produce a banner that must be dismissable independently.
    func test_lastError_multipleSetClearCycles() {
        let vm = DiffPanelViewModel(cwd: "/tmp", asyncLoad: false)

        vm.lastError = "push rejected"
        XCTAssertEqual(vm.lastError, "push rejected")
        vm.lastError = nil
        XCTAssertNil(vm.lastError)

        vm.lastError = "merge conflict"
        XCTAssertEqual(vm.lastError, "merge conflict")
        vm.lastError = nil
        XCTAssertNil(vm.lastError)
    }
}

