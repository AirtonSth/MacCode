import XCTest
@testable import AppShell
import AgentRuntime
import Persistence
import CoreModel

/// Tests that verify rebuildCommands() surfaces project.run.* commands when the
/// scriptCache is pre-seeded with discovered scripts.
///
/// WHY (P2 mac-settings-palette.md Fixtures item):
///   The todo asks for a shared palette-context fixture: makeContext() + a
///   workspace whose cwd contains package.json + a pre-seeded scriptCache so
///   rebuildCommands() tests can assert project-script visibility without
///   relying on the async Task.detached discovery path.
///
///   The scriptCache property was private and unreachable from tests. This file
///   documents the seam (now `internal`) and exercises the path from seeded
///   cache to visible palette commands.

@MainActor
final class RebuildCommandsProjectScriptTests: XCTestCase {

    // MARK: - Shared setup helper (palette-context fixture)

    /// Returns (AppContext, AppCommandRouter, CommandPalette, WorkspaceID, cwdPath).
    /// Creates a workspace whose cwd is a temp directory; callers can write
    /// package.json there or pre-seed the scriptCache directly.
    private func makePaletteContext() throws -> (AppContext, AppCommandRouter, CommandPalette, WorkspaceID, String) {
        let dir = NSTemporaryDirectory() + "RC2PaletteCtx-" + UUID().uuidString
        let cwd = NSTemporaryDirectory() + "RC2PaletteCwd-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let ws = try router.createWorkspace(name: "palette-fixture", cwd: cwd)
        let palette = CommandPalette(router: router)
        return (ctx, router, palette, ws.id, cwd)
    }

    // MARK: - T1: project.run.* commands appear after scriptCache is pre-seeded

    /// WHY: cachedScripts() returns [] on a cache miss and fires an async task.
    /// Tests that rely on the async path are non-deterministic. By pre-seeding
    /// scriptCache (now internal) the test asserts the catalog-building path
    /// synchronously, without any timer or expectation.
    func test_rebuildCommands_projectRunCommandsAppear_whenScriptCacheIsPreSeeded() throws {
        let (_, _, palette, _, cwd) = try makePaletteContext()

        let scripts = [
            ProjectScript(name: "build", command: "npm run build", source: "package.json"),
            ProjectScript(name: "test", command: "npm run test", source: "package.json"),
        ]
        palette.scriptCache[cwd] = scripts

        palette.rebuildCommands()

        let allIDs = palette.allCommandIDsForTesting
        XCTAssertTrue(allIDs.contains("project.run.build"),
                      "project.run.build must appear in the catalog after the scriptCache is seeded; a missing entry means the user's npm build script is silently absent from the palette")
        XCTAssertTrue(allIDs.contains("project.run.test"),
                      "project.run.test must appear in the catalog after the scriptCache is seeded; missing npm scripts in the palette were the original motivation for the scriptCache seam")
    }

    // MARK: - T2: project.run.* commands are absent when scriptCache is empty

    /// WHY: documents the inverse contract - no phantom script commands when
    /// the cache is empty (a cache miss must not inject stale commands from a
    /// previous workspace). This would surface as wrong script names appearing
    /// after the user switches workspaces.
    func test_rebuildCommands_noProjectRunCommands_whenScriptCacheIsEmpty() throws {
        let (_, _, palette, _, _) = try makePaletteContext()
        // scriptCache left empty (no pre-seed).
        palette.rebuildCommands()

        let allIDs = palette.allCommandIDsForTesting
        let scriptCmds = allIDs.filter { $0.hasPrefix("project.run.") && $0 != "project.run.more" }
        XCTAssertTrue(scriptCmds.isEmpty,
                      "when the scriptCache is empty no project.run.* commands must appear; stale script commands from a previous workspace would let the user accidentally run a script in the wrong project")
    }

    // MARK: - T3: scriptCache is keyed by cwd - scripts from a different workspace must not bleed in

    /// WHY: the scriptCache is a dict keyed by cwd. rebuildCommands() calls
    /// cachedScripts(cwd: currentWorkspace.cwd). If the key lookup ever used
    /// the wrong cwd the wrong project's scripts could appear.
    func test_rebuildCommands_scriptCache_isScopedByCwd() throws {
        let dir = NSTemporaryDirectory() + "RC2PaletteScope-" + UUID().uuidString
        let cwdA = NSTemporaryDirectory() + "RC2PaletteA-" + UUID().uuidString
        let cwdB = NSTemporaryDirectory() + "RC2PaletteB-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: cwdA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: cwdB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: cwdA)
            try? FileManager.default.removeItem(atPath: cwdB)
        }

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let wsA = try router.createWorkspace(name: "alpha", cwd: cwdA)
        _ = try router.createWorkspace(name: "beta", cwd: cwdB)
        // Select workspace A.
        try router.selectWorkspace(wsA.id)

        let palette = CommandPalette(router: router)
        // Seed scripts only under cwdB.
        palette.scriptCache[cwdB] = [
            ProjectScript(name: "deploy", command: "npm run deploy", source: "package.json")
        ]
        palette.rebuildCommands()

        let allIDs = palette.allCommandIDsForTesting
        XCTAssertFalse(allIDs.contains("project.run.deploy"),
                       "scripts from workspace B must not appear when workspace A is selected; cross-workspace script bleed would let the user accidentally run the wrong project's commands")
    }
}
