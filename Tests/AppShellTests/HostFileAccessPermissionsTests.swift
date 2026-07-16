import XCTest
import Foundation
import AppKit
@testable import AppShell
import Persistence

/// Host Files and Folders TCC helpers.
///
/// WHY: macOS does not allow silent grant-all for network volumes / Desktop /
/// Documents / Downloads. These tests lock the pure contract: purpose strings,
/// probe path resolution, onboarding handled-state (all three alert buttons),
/// and ad-hoc identity warnings — so a packaging or UX regression cannot
/// reintroduce a launch nag loop or false “re-request” claims.
final class HostFileAccessPermissionsTests: XCTestCase {

    func test_infoPlistKeysCoverAllFilesAndFoldersServices() {
        let keys = Set(HostFileAccessPrivacyStrings.infoPlistKeys.keys)
        let expected: Set<String> = [
            "NSNetworkVolumesUsageDescription",
            "NSRemovableVolumesUsageDescription",
            "NSDesktopFolderUsageDescription",
            "NSDocumentsFolderUsageDescription",
            "NSDownloadsFolderUsageDescription",
        ]
        XCTAssertEqual(keys, expected, "package-app Info.plist must ship every Files and Folders purpose string")
        for (key, value) in HostFileAccessPrivacyStrings.infoPlistKeys {
            XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(key) purpose string must be non-empty")
            XCTAssertTrue(value.contains("RemoteCode"),
                          "\(key) should name RemoteCode so the system dialog is attributable")
        }
    }

    func test_systemSettingsURLsAreValid() {
        XCTAssertEqual(HostFileAccessSystemSettings.filesAndFoldersURL.scheme, "x-apple.systempreferences")
        XCTAssertEqual(HostFileAccessSystemSettings.fullDiskAccessURL.scheme, "x-apple.systempreferences")
        XCTAssertTrue(HostFileAccessSystemSettings.filesAndFoldersURL.absoluteString.contains("Privacy_FilesAndFolders"))
        XCTAssertTrue(HostFileAccessSystemSettings.fullDiskAccessURL.absoluteString.contains("Privacy_AllFiles"))
    }

    func test_copyDoesNotClaimReRequestReopensDeniedPrompt() {
        XCTAssertTrue(HostFileAccessCopy.settingsExplanation.contains("Don’t Allow")
                      || HostFileAccessCopy.settingsExplanation.contains("Don't Allow")
                      || HostFileAccessCopy.settingsExplanation.contains("System Settings"))
        XCTAssertEqual(HostFileAccessCopy.requestAccessButton, "Check folder access")
        XCTAssertFalse(HostFileAccessCopy.settingsExplanation.lowercased().contains("re-request access"))
    }

    func test_probeTargetResolvesHomeFolders() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        XCTAssertEqual(
            HostFileAccessProbeTarget.desktop.resolveURL(home: home)?.path,
            "/Users/example/Desktop"
        )
        XCTAssertEqual(
            HostFileAccessProbeTarget.documents.resolveURL(home: home)?.path,
            "/Users/example/Documents"
        )
        XCTAssertEqual(
            HostFileAccessProbeTarget.downloads.resolveURL(home: home)?.path,
            "/Users/example/Downloads"
        )
    }

    func test_probeReportsReadableDeniedAndMissing() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let readable = HostFileAccessProber.probe(
            .desktop,
            home: home,
            contentsOfDirectory: { _ in [URL(fileURLWithPath: "/Users/example/Desktop/a")] }
        )
        XCTAssertEqual(readable.outcome, .readable)

        let denied = HostFileAccessProber.probe(
            .documents,
            home: home,
            contentsOfDirectory: { _ in
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM), userInfo: nil)
            }
        )
        XCTAssertEqual(denied.outcome, .denied)

        let missing = HostFileAccessProber.probe(
            .downloads,
            home: home,
            contentsOfDirectory: { _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: nil)
            }
        )
        XCTAssertEqual(missing.outcome, .missing)
    }

    func test_probeStandardTargetsSkipsVolumesWhenNoneMounted() {
        // Inject empty volume root resolution via a fileManager that reports no children.
        final class EmptyVolumesFM: FileManager, @unchecked Sendable {
            override func contentsOfDirectory(
                at url: URL,
                includingPropertiesForKeys keys: [URLResourceKey]?,
                options mask: FileManager.DirectoryEnumerationOptions = []
            ) throws -> [URL] {
                if url.path == "/Volumes" { return [] }
                return []
            }
        }
        let results = HostFileAccessProber.probeStandardTargets(
            includeVolumes: true,
            home: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            volumesRoot: URL(fileURLWithPath: "/Volumes", isDirectory: true),
            fileManager: EmptyVolumesFM(),
            contentsOfDirectory: { _ in [] }
        )
        XCTAssertEqual(results.map(\.target), [.desktop, .documents, .downloads],
                       "Without a mounted child, volume probe must be skipped so we never claim networkVolumes:readable for /Volumes alone")
    }

    func test_onboardingShouldPresentOnlyWhenUnhandled() {
        XCTAssertTrue(HostFileAccessOnboarding.shouldPresent(handled: false))
        XCTAssertFalse(HostFileAccessOnboarding.shouldPresent(handled: true))
    }

    func test_handleAlertResponseMarksHandledForAllThreeButtons() throws {
        for response in [
            NSApplication.ModalResponse.alertFirstButtonReturn,
            .alertSecondButtonReturn,
            .alertThirdButtonReturn,
        ] {
            var handled = false
            var openedSettings = false
            var checked = false
            try HostFileAccessOnboarding.handleAlertResponse(
                response,
                markHandled: { handled = true },
                openSystemSettings: { openedSettings = true },
                checkFolderAccess: { checked = true }
            )
            XCTAssertTrue(handled, "response \(response.rawValue) must persist handled to avoid launch nag loop")
            switch response {
            case .alertFirstButtonReturn:
                XCTAssertTrue(checked)
                XCTAssertFalse(openedSettings)
            case .alertSecondButtonReturn:
                XCTAssertTrue(openedSettings)
                XCTAssertFalse(checked)
            default:
                XCTAssertFalse(checked)
                XCTAssertFalse(openedSettings)
            }
        }
    }

    func test_handleAlertResponsePersistsBeforeSideEffects() throws {
        var order: [String] = []
        try HostFileAccessOnboarding.handleAlertResponse(
            .alertSecondButtonReturn,
            markHandled: { order.append("handled") },
            openSystemSettings: { order.append("settings") },
            checkFolderAccess: { order.append("check") }
        )
        XCTAssertEqual(order, ["handled", "settings"],
                       "Persist before opening System Settings so a crash mid-open does not re-nag")
    }

    @MainActor
    func test_onboardingPersistenceRoundTrip() throws {
        let dir = NSTemporaryDirectory() + "RC2HostFileAccess-\(UUID().uuidString)"
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let repo = SettingsRepository(db: ctx.db)
        XCTAssertFalse(HostFileAccessOnboarding.isHandled(repo: repo))
        try HostFileAccessOnboarding.markHandled(repo: repo)
        XCTAssertTrue(HostFileAccessOnboarding.isHandled(repo: repo))
    }

    @MainActor
    func test_legacyOnboardingKeyCountsAsHandled() throws {
        let dir = NSTemporaryDirectory() + "RC2HostFileAccessLegacy-\(UUID().uuidString)"
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let repo = SettingsRepository(db: ctx.db)
        try repo.set(HostFileAccessOnboarding.legacySettingsKey, "1")
        XCTAssertTrue(HostFileAccessOnboarding.isHandled(repo: repo),
                      "Users who already dismissed the first-version sheet must not be nagged again")
    }

    func test_adHocIdentityExposesWarning() {
        let adHoc = HostCodeSignatureIdentity(isAdHoc: true, teamIdentifier: nil, identifier: "io.remotecode.desktop")
        XCTAssertNotNil(adHoc.adHocWarning)
        XCTAssertTrue(adHoc.adHocWarning?.contains("ad-hoc") == true)

        let stable = HostCodeSignatureIdentity(isAdHoc: false, teamIdentifier: "TEAMID", identifier: "io.remotecode.desktop")
        XCTAssertNil(stable.adHocWarning)
    }

    func test_codeSignatureReaderTreatsMissingInfoAsAdHoc() {
        let identity = HostCodeSignatureReader.current(copyInfo: { nil })
        XCTAssertTrue(identity.isAdHoc)
    }

    @MainActor
    func test_settingsViewModelRequestHostFileAccessMarksOnboardingHandled() throws {
        let dir = NSTemporaryDirectory() + "RC2HostFileAccessVM-\(UUID().uuidString)"
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let vm = SettingsViewModel(context: ctx)
        vm.hostFileAccessProbeRunner = {
            [HostFileAccessProbeResult(target: .desktop, outcome: .readable, path: "/Users/example/Desktop")]
        }
        XCTAssertFalse(vm.hostFileAccessOnboardingCompleted)
        vm.requestHostFileAccess()
        XCTAssertTrue(vm.hostFileAccessOnboardingCompleted)
        XCTAssertEqual(vm.hostFileAccessProbeResults.count, 1)
        XCTAssertTrue(HostFileAccessOnboarding.isHandled(repo: vm.settingsRepo))
    }
}
