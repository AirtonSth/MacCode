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
        let persistedFiles = SurfaceDescriptor(type: .files, title: "Persisted Files")
        try context.apply(.addSurface(
            workspaceOne.id,
            paneID: nil,
            descriptor: persistedFiles
        ))
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

        let first = try await router.readConnectionSnapshotState()
        let second = try await router.readConnectionSnapshotState()
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

    func test_realRouterSnapshot_returnsEmptyStateAfterContextDeallocation() async throws {
        var context: AppContext? = try makeContext()
        let router = AppCommandRouter(context: try XCTUnwrap(context))
        context?.router = router
        context = nil

        let state = try await router.readConnectionSnapshotState()
        XCTAssertEqual(
            state,
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

    func test_realRouterSnapshot_propagatesRepositoryReadFailure() async throws {
        let (context, router) = try make()
        _ = try router.createWorkspace(name: "Broken", cwd: NSTemporaryDirectory())
        try context.db.execute("DROP TABLE agent_threads;")

        do {
            _ = try await router.readConnectionSnapshotState()
            XCTFail("expected repository read failure to propagate")
        } catch {
            // Gateway surface SQLite errors; do not swallow into empty snapshot.
        }
    }

    func test_realRouterSnapshot_threadListRunsOffMainActorAndKeepsMainResponsive() async throws {
        // WHY: Dispatcher/AppCommandRouter are @MainActor; the connection-snapshot
        // AgentThread SQLite list/decode must hop to AgentThreadListGateway so a
        // slow list cannot monopolize the main run loop / HTTP acceptance.
        let (context, router) = try make()
        _ = try router.createWorkspace(name: "Gateway", cwd: NSTemporaryDirectory())
        _ = try router.createAgentThread(
            workspace: try XCTUnwrap(context.state.window.selectedWorkspaceID),
            title: "Off-main thread",
            provider: .codex,
            model: "gpt-5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )

        AgentThreadListGateway.resetExecutionProbesForTesting()
        AgentThreadListGateway.queryDelayNanosecondsForTesting = 40_000_000
        defer { AgentThreadListGateway.resetExecutionProbesForTesting() }

        var heartbeats = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                heartbeats += 1
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        let state = try await router.readConnectionSnapshotState()
        heartbeat.cancel()
        _ = await heartbeat.result

        XCTAssertFalse(state.agentThreads.isEmpty)
        XCTAssertEqual(AgentThreadListGateway.queryCallCountForTesting, 1)
        XCTAssertEqual(AgentThreadListGateway.queryOnMainActorCountForTesting, 0)
        XCTAssertEqual(AgentThreadListGateway.queryOffMainActorCountForTesting, 1)
        XCTAssertGreaterThan(
            heartbeats,
            3,
            "MainActor run loop must keep pumping while snapshot thread list is delayed"
        )
    }

    func test_realRouterSnapshot_threadListCancellationDoesNotLeaveContinuationHanging() async throws {
        // WHY: a timed-out HTTP snapshot must release its caller immediately;
        // the queued SQLite read may finish later, but it must not resume a
        // cancelled continuation or strand the dispatcher single-flight.
        let (context, router) = try make()
        _ = try router.createWorkspace(name: "Cancelled gateway", cwd: NSTemporaryDirectory())
        AgentThreadListGateway.resetExecutionProbesForTesting()
        AgentThreadListGateway.queryDelayNanosecondsForTesting = 500_000_000
        defer { AgentThreadListGateway.resetExecutionProbesForTesting() }

        let task = Task {
            try await context.agentThreadListGateway.list()
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled gateway read must not return a successful list")
        } catch is CancellationError {
            // Expected: cancellation resumes the continuation immediately.
        }
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
