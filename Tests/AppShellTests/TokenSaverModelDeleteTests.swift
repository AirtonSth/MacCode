import XCTest
import Foundation
import AppKit
import CoreModel
import Persistence
@testable import AppShell

/// WHY these tests exist (Rule 8):
/// "Delete model" is the only destructive action on the Token Saver card, and
/// its result feeds `installedTokenSaverModelBytes()`, which paints the reclaim
/// size on that row. When the removal failed the old path still wrote 0 bytes
/// into that cache, so the UI claimed the model was gone while the directory sat
/// on disk: the reclaim size vanished and the next enable re-downloaded ~3.8 GB.
/// These specs pin the honest contract: report the failure and keep the cache
/// describing what is really on disk.
@MainActor
final class TokenSaverModelDeleteTests: XCTestCase {

    private func makeAppSupportFixture(prefix: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RC2TokenSaverDelete-\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func seedModelDirectory(in root: URL) throws -> URL {
        let modelDir = SidebarRootView.tokenSaverDistillDirectory(appSupportDirectory: root)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let blob = Data(repeating: 0x41, count: 4096)
        try blob.write(to: modelDir.appendingPathComponent("model.bin"))
        return modelDir
    }

    private func restoreWritable(_ root: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    /// Locks the model directory itself (not its parent): a recursive removal
    /// then fails on the first unlink with the contents still in place, which is
    /// the case where a zeroed cache is provably a lie.
    private func lockModelDirectory(_ modelDir: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: modelDir.path)
    }

    private func makeViewModel(appSupport: URL) throws -> SidebarViewModel {
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return SidebarViewModel(context: ctx, router: router)
    }

    func test_removeInstalledTokenSaverModel_recordsZeroOnceTheDirectoryIsGone() throws {
        let root = try makeAppSupportFixture(prefix: "ok")
        defer {
            restoreWritable(root)
            try? FileManager.default.removeItem(at: root)
        }
        let modelDir = try seedModelDirectory(in: root)
        let vm = try makeViewModel(appSupport: root)
        XCTAssertGreaterThan(vm.installedTokenSaverModelBytes(), 0, "fixture must start with a sized model dir")

        let error = vm.removeInstalledTokenSaverModel(at: modelDir)

        XCTAssertNil(error, "a removal that takes the directory out must not report an error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDir.path))
        XCTAssertEqual(
            vm.installedTokenSaverModelBytes(),
            0,
            "the delete row must report 0 bytes once the model is really gone"
        )
    }

    func test_removeInstalledTokenSaverModel_reportsFailureAndKeepsTheCachedSize() throws {
        let root = try makeAppSupportFixture(prefix: "locked")
        defer {
            restoreWritable(root)
            try? FileManager.default.removeItem(at: root)
        }
        let modelDir = try seedModelDirectory(in: root)
        let vm = try makeViewModel(appSupport: root)
        let onDisk = vm.installedTokenSaverModelBytes()
        XCTAssertGreaterThan(onDisk, 0, "fixture must start with a sized model dir")

        // 0o500 on the model dir makes the recursive unlink fail while the
        // 4096 bytes stay on disk.
        try lockModelDirectory(modelDir)
        defer { restoreWritable(modelDir) }

        let error = vm.removeInstalledTokenSaverModel(at: modelDir)

        XCTAssertNotNil(error, "a removal that leaves the directory on disk must report the failure")
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelDir.path))
        XCTAssertEqual(
            SidebarRootView.modelDirSize(at: modelDir),
            onDisk,
            "fixture must leave the model contents in place, otherwise the cache check below is vacuous"
        )
        XCTAssertEqual(
            vm.installedTokenSaverModelBytes(),
            onDisk,
            "a failed delete must not cache 0 bytes for a directory that still has content"
        )
    }

    func test_removeInstalledTokenSaverModel_missingDirectory_isNotAFailure() throws {
        let root = try makeAppSupportFixture(prefix: "missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = try makeViewModel(appSupport: root)
        let absent = SidebarRootView.tokenSaverDistillDirectory(appSupportDirectory: root)

        let error = vm.removeInstalledTokenSaverModel(at: absent)

        XCTAssertNil(error, "an already-deleted model dir must not raise an error")
        XCTAssertEqual(
            vm.installedTokenSaverModelBytes(),
            0,
            "nothing on disk still means 0 bytes installed"
        )
    }
}
