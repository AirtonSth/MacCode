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
            override func contentsOfDirectory(atPath path: String) throws -> [String] {
                if path == "/Volumes" { return [] }
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

    func test_probeStandardTargetsDefaultsExcludeVolumes() {
        // WHY: default includeVolumes must be false so onboarding Continue / Settings
        // "Check folder access" never force the Network Volumes system dialog.
        let results = HostFileAccessProber.probeStandardTargets(
            home: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            contentsOfDirectory: { _ in [] }
        )
        XCTAssertFalse(results.map(\.target).contains(.networkVolumes))
        XCTAssertEqual(results.map(\.target), [.desktop, .documents, .downloads])
    }

    func test_networkClassPathMatching() {
        let mounts = ["/Users/example/OrbStack", "/Volumes/Share"]
        XCTAssertTrue(HostVolumeMountTable.isNetworkClassPath("/Users/example/OrbStack", mounts: mounts))
        XCTAssertTrue(HostVolumeMountTable.isNetworkClassPath("/Users/example/OrbStack/vm", mounts: mounts))
        XCTAssertFalse(HostVolumeMountTable.isNetworkClassPath("/Users/example/dev", mounts: mounts))
        XCTAssertFalse(HostVolumeMountTable.isNetworkClassPath("/Users/example/OrbStackBackup", mounts: mounts))
    }

    func test_safeDirectoryListingSkipsStatOnNetworkMountChildren() throws {
        // WHY: Prefetching resource keys on ~/OrbStack is what triggers the
        // Network Volumes TCC dialog when home is listed.
        final class RecordingFM: FileManager, @unchecked Sendable {
            var statted: [String] = []
            override func contentsOfDirectory(atPath path: String) throws -> [String] {
                XCTAssertEqual(path, "/Users/example")
                return ["dev", "OrbStack", "Documents"]
            }
            override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
                statted.append(path)
                if path.hasSuffix("OrbStack") {
                    XCTFail("must not stat network mount child \(path)")
                }
                isDirectory?.pointee = true
                return true
            }
            override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
                statted.append("attrs:\(path)")
                return [.type: FileAttributeType.typeDirectory]
            }
        }
        let fm = RecordingFM()
        let entries = try HostSafeDirectoryListing.list(
            path: "/Users/example",
            fileManager: fm,
            networkMounts: ["/Users/example/OrbStack"]
        )
        XCTAssertEqual(Set(entries.map(\.name)), Set(["dev", "OrbStack", "Documents"]))
        let orb = entries.first { $0.name == "OrbStack" }
        XCTAssertEqual(orb?.isNetworkVolume, true)
        XCTAssertEqual(orb?.isDirectory, true)
        XCTAssertFalse(fm.statted.contains { $0.contains("OrbStack") })
    }

    func test_nonLocalMountPathsUsesInjectedMountTable() {
        let paths = HostVolumeMountTable.nonLocalMountPaths {
            [
                (on: "/", type: "apfs", isLocal: true),
                (on: "/Users/example/OrbStack", type: "nfs", isLocal: false),
                (on: "/System/Volumes/Data/home", type: "autofs", isLocal: false),
            ]
        }
        XCTAssertEqual(Set(paths), Set([
            "/Users/example/OrbStack",
            "/System/Volumes/Data/home",
        ]))
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
