import XCTest
import SwiftUI
@testable import DesignSystemKit

// Tests for the generic DSSectionHeaderG variant (no AnyView erasure).
// All tests use pure-logic seams (nonisolated static helpers) or type-system
// assertions; no SwiftUI rendering host is needed.
final class DSSectionHeaderGenericTests: XCTestCase {

    // MARK: - displayTitle (pure seam)

    // The header uppercases titles so hierarchy is visually distinct from body text.
    // A lowercase input must produce an uppercase result.
    func testDisplayTitleUppercasesInput() {
        let result = DSSectionHeaderG<EmptyView>.displayTitle(for: "files changed")
        XCTAssertEqual(result, "FILES CHANGED",
            "Section headers must uppercase titles to match design spec")
    }

    // Already-uppercase input must survive the transform unchanged.
    func testDisplayTitleAlreadyUppercaseIsIdempotent() {
        let input = "SETTINGS"
        XCTAssertEqual(DSSectionHeaderG<EmptyView>.displayTitle(for: input), input)
    }

    // Empty title must not crash and must return empty string.
    func testDisplayTitleEmptyInput() {
        XCTAssertEqual(DSSectionHeaderG<EmptyView>.displayTitle(for: ""), "")
    }

    // Mixed-case input (real-world: "Token Saver") must be fully uppercased.
    func testDisplayTitleMixedCase() {
        XCTAssertEqual(DSSectionHeaderG<EmptyView>.displayTitle(for: "Token Saver"), "TOKEN SAVER")
    }

    // MARK: - Generic type parameter (compile-level: no AnyView in concrete type)

    // Verifies that DSSectionHeaderG<Text> compiles with a concrete trailing type,
    // proving SwiftUI identity is preserved (Trailing == Text, not AnyView).
    // If this test builds, the generic contract holds.
    func testGenericTrailingTypeIsConcreteNotAnyView() {
        // DSSectionHeaderG<Text> — Trailing is Text, NOT AnyView.
        let header = DSSectionHeaderG("section") { Text("action") }
        // Mirror the stored trailing type; it must NOT be AnyView.
        let mirror = Mirror(reflecting: header)
        let trailingChild = mirror.children.first(where: { $0.label == "trailing" })
        XCTAssertNotNil(trailingChild, "DSSectionHeaderG must expose a 'trailing' stored property")
        XCTAssertFalse(trailingChild?.value is AnyView,
            "Generic trailing must not be AnyView; AnyView erasure defeats SwiftUI identity")
    }

    // EmptyView convenience init compiles and produces a no-trailing header.
    func testNoTrailingInitProducesEmptyView() {
        let header = DSSectionHeaderG<EmptyView>("No trailing")
        XCTAssertEqual(header.title, "No trailing")
        let mirror = Mirror(reflecting: header)
        let trailingChild = mirror.children.first(where: { $0.label == "trailing" })
        XCTAssertTrue(trailingChild?.value is EmptyView,
            "No-trailing convenience init must store EmptyView, not nil or AnyView")
    }

    // title stored property matches the raw string passed to init (uppercasing is display-time only).
    func testStoredTitleIsRawNotUppercased() {
        let header = DSSectionHeaderG<EmptyView>("raw title")
        XCTAssertEqual(header.title, "raw title",
            "Stored title must be the raw string; uppercasing happens at render time via displayTitle")
    }

    // MARK: - Call-site migration: AnyView erasure eliminated (PERF-DS-001)

    // WHY: DSSectionHeader call sites in SettingsWindow/DiffPanelSurface/SSHSurface were
    // migrated to DSSectionHeaderG to remove AnyView erasure on sidebar/list hot paths.
    // This test verifies the migration invariant: a no-trailing DSSectionHeaderG produces
    // EmptyView (never AnyView), and a @ViewBuilder trailing produces the concrete content
    // type.  If the invariant breaks, SwiftUI structural identity is lost and the diffing
    // perf regression returns silently.

    func testMigratedNoTrailingCallSiteIsNotAnyView() {
        // Matches the migrated SettingsWindow / DiffPanelSurface pattern:
        //   DSSectionHeaderG("Remote Access")  (no trailing)
        let header = DSSectionHeaderG<EmptyView>("Remote Access")
        XCTAssertFalse(header.trailing is AnyView,
            "No-trailing call site must store EmptyView; AnyView erasure defeats SwiftUI identity diffing on sidebar hot path")
        XCTAssertTrue(header.trailing is EmptyView,
            "No-trailing init must store EmptyView so SwiftUI can short-circuit unchanged subtrees")
    }

    func testMigratedViewBuilderTrailingIsConcreteHStack() {
        // Matches the migrated SSHSurface pattern:
        //   DSSectionHeaderG("SSH") { HStack { ... } }
        let header = DSSectionHeaderG("Files") {
            HStack { Text("Refresh") }
        }
        // Trailing must be a concrete HStack<Text>, not AnyView.
        // Compile-time: Trailing == HStack<Text> proves no erasure.
        // Runtime mirror check confirms the stored value is not AnyView.
        let mirror = Mirror(reflecting: header)
        let trailingChild = mirror.children.first(where: { $0.label == "trailing" })
        XCTAssertNotNil(trailingChild,
            "DSSectionHeaderG must expose a 'trailing' stored property for Mirror inspection")
        XCTAssertFalse(trailingChild?.value is AnyView,
            "ViewBuilder trailing call site must store a concrete HStack, not AnyView; " +
            "AnyView erasure here would silently re-introduce the identity regression on the SSH sidebar hot path")
    }
}
