import XCTest
@testable import AppShell
@testable import CoreModel
@testable import SocketServer
@testable import Surfaces
import Persistence

@MainActor
final class ConnectionSnapshotRouterPhase3Tests: XCTestCase {
    private var temporaryDirectories: [String] = []

    override func tearDown() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func test_realRouterSnapshot_groupsAllDomainsAndIsDeterministic() async throws {
        let (context, router) = try make()
        let workspaceOne = try router.createWorkspace(name: "One", cwd: NSTemporaryDirectory())
        let browser = try router.createSurface(
            workspace: workspaceOne.id,
            type: .browser,
            paneID: nil,
            title: "Browser"
        )
        let persistedFiles = try router.createSurface(
            workspace: workspaceOne.id,
            type: .files,
            paneID: nil,
            title: "Persisted Files"
        )
        let fallbackFiles = SurfaceDescriptor(type: .files, title: "Fallback Files")
        try context.apply(.addSurface(
            workspaceOne.id,
            paneID: nil,
            descriptor: fallbackFiles
        ))
        let thread = try router.createAgentThread(
            workspace: workspaceOne.id,
            title: "Snapshot Thread",
            provider: .codex,
            model: "gpt-5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let workspaceTwo = try router.createWorkspace(name: "Two", cwd: NSTemporaryDirectory())

        let persistedUpdate = try router.filesStateUpdate(
            surface: persistedFiles.id,
            patch: ["selected_path": .string("notes.md")],
            baseRevision: nil,
            deviceID: "phase3-test-device"
        )

        let first = try router.readConnectionSnapshotState()
        let second = try router.readConnectionSnapshotState()
        XCTAssertEqual(first, second, "unchanged host state must serialize deterministically")
        XCTAssertNoThrow(try ConnectionTransportFrame.snapshot(ConnectionSnapshotFrame(
            protocolVersion: 3,
            type: "snapshot",
            connectionId: "real-router-connection",
            hostId: "real-router-host",
            bootEpoch: 1,
            sequence: 1,
            snapshotId: "real-router-snapshot",
            generatedAtEpochMs: 1,
            stateVersion: 3,
            state: first.jsonValue(domainRevisions: ConnectionDomainRevisions(
                shell: 1,
                surfaces: 1,
                agentThreads: 1,
                browser: 1,
                files: 1
            ))
        )).encoded(), "real AppCommandRouter output must satisfy the strict wire contract")
        XCTAssertEqual(first.selectedWorkspaceId, workspaceTwo.id.value.uuidString)
        XCTAssertEqual(workspaceIDs(first.workspaces), [
            workspaceOne.id.value.uuidString,
            workspaceTwo.id.value.uuidString,
        ])

        let workspaceOneSurfaces = try XCTUnwrap(
            first.surfaces.first { $0.workspaceId == workspaceOne.id.value.uuidString }
        )
        let surfaceObjects = workspaceOneSurfaces.items.compactMap(\.objectValue)
        XCTAssertTrue(surfaceObjects.contains {
            $0["id"]?.stringValue == browser.id.value.uuidString
                && $0["type"]?.stringValue == "browser"
        })
        XCTAssertTrue(surfaceObjects.contains {
            $0["id"]?.stringValue == persistedFiles.id.value.uuidString
                && $0["type"]?.stringValue == "files"
        })
        XCTAssertTrue(surfaceObjects.contains {
            $0["id"]?.stringValue == fallbackFiles.id.value.uuidString
                && $0["type"]?.stringValue == "files"
        })

        let workspaceOneThreads = try XCTUnwrap(
            first.agentThreads.first { $0.workspaceId == workspaceOne.id.value.uuidString }
        )
        XCTAssertTrue(workspaceOneThreads.items.contains {
            $0.objectValue?["id"]?.stringValue == thread.id.value.uuidString
        })

        let browserState = try XCTUnwrap(
            first.browserStates.first { $0.surfaceId == browser.id.value.uuidString }
        )
        XCTAssertEqual(browserState.workspaceId, workspaceOne.id.value.uuidString)
        XCTAssertEqual(
            browserState.state.objectValue?["url"]?.stringValue,
            try router.browserURL(surface: browser.id),
            "snapshot must read the live BrowserSurface URL"
        )

        let persistedState = try XCTUnwrap(
            first.filesStates.first { $0.surfaceId == persistedFiles.id.value.uuidString }
        )
        XCTAssertEqual(persistedState.state.objectValue?["selected_path"]?.stringValue, "notes.md")
        XCTAssertEqual(persistedState.state, persistedUpdate)
        XCTAssertEqual(
            persistedState.state.objectValue?["updated_by_device"]?.stringValue,
            "phase3-test-device"
        )

        let fallbackState = try XCTUnwrap(
            first.filesStates.first { $0.surfaceId == fallbackFiles.id.value.uuidString }
        )
        XCTAssertEqual(fallbackState.workspaceId, workspaceOne.id.value.uuidString)
        XCTAssertEqual(
            fallbackState.state.objectValue?["surface_id"]?.stringValue,
            fallbackFiles.id.value.uuidString
        )
        XCTAssertEqual(fallbackState.state.objectValue?["revision"]?.intValue, 0)
        XCTAssertEqual(fallbackState.state.objectValue?["selected_path"], .null)
        XCTAssertEqual(first.browserStates.count, 1)
        XCTAssertEqual(first.filesStates.count, 2)
        _ = context
    }

    func test_realRouterSnapshot_returnsEmptyStateAfterContextDeallocation() throws {
        var context: AppContext? = try makeContext()
        let router = AppCommandRouter(context: try XCTUnwrap(context))
        context?.router = router
        context = nil

        XCTAssertEqual(
            try router.readConnectionSnapshotState(),
            ConnectionSnapshotReadState(
                selectedWorkspaceId: nil,
                workspaces: [],
                surfaces: [],
                agentThreads: [],
                browserStates: [],
                filesStates: []
            )
        )
    }

    func test_realRouterSnapshot_propagatesRepositoryReadFailure() throws {
        let (context, router) = try make()
        _ = try router.createWorkspace(name: "Broken", cwd: NSTemporaryDirectory())
        try context.db.execute("DROP TABLE agent_threads;")

        XCTAssertThrowsError(try router.readConnectionSnapshotState())
    }

    private func make() throws -> (AppContext, AppCommandRouter) {
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        return (context, router)
    }

    private func makeContext() throws -> AppContext {
        let directory = NSTemporaryDirectory()
            + "RC2ConnectionSnapshotPhase3-"
            + UUID().uuidString
        temporaryDirectories.append(directory)
        return try AppContext(channel: .debug, appSupportOverride: directory)
    }

    private func workspaceIDs(_ workspaces: [JSONValue]) -> [String] {
        workspaces.compactMap { $0.objectValue?["id"]?.stringValue }
    }
}
