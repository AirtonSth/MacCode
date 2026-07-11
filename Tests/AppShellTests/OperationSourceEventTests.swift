import AppKit
import XCTest
@testable import AppShell
import CoreModel
@testable import SocketServer
@testable import Surfaces

@MainActor
final class OperationSourceEventTests: XCTestCase {
    private struct NoopSSHPasswordStore: SSHPasswordStoring {
        func save(account: String, password: String) {}
        func load(account: String) -> String? { nil }
        func delete(account: String) {}
    }

    private struct CommandFailure: Error {}

    private enum ProviderUpdateRoute {
        case direct
        case jsonRPC
    }

    private final class TestSSHTransferSurface: NSObject, SSHTransferSurface {
        let descriptor: SurfaceDescriptor
        let view = NSView()
        let sshTransferProfile: SSHHostProfile?
        private(set) var systemOutput = ""

        init(workspace: WorkspaceID) {
            descriptor = SurfaceDescriptor(
                type: .ssh,
                title: "SSH transfer test",
                metadata: ["workspace": workspace.value.uuidString]
            )
            sshTransferProfile = SSHHostProfile(label: "Test", destination: "example.invalid")
        }

        var isBusy: Bool { false }
        func focus() {}
        func unfocus() {}
        func close() {}
        func sendText(_ text: String) {}
        func readText() -> String { systemOutput }
        func snapshot() -> [String: String] { [:] }
        func appendSystemText(_ raw: String) { systemOutput += raw }
    }

    private final class EventCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [EventBus.Event] = []

        func append(_ event: EventBus.Event) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var events: [EventBus.Event] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private func closeAndUnregisterAllSurfaces() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
    }

    override func tearDown() {
        closeAndUnregisterAllSurfaces()
        super.tearDown()
    }

    private func makeRouter(projectDirectory: String) throws -> (AppContext, AppCommandRouter, Workspace) {
        let support = NSTemporaryDirectory() + "RC2OperationEvents-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: support)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Operation events", cwd: projectDirectory)
        return (context, router, workspace)
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 4,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(description)")
    }

    private func makeSSHRouter(
        commandRunner: @escaping @Sendable (String, [String], String?) throws -> (exitCode: Int32, output: String)
    ) throws -> (AppContext, AppCommandRouter, WorkspaceID, TestSSHTransferSurface) {
        let support = NSTemporaryDirectory() + "RC2SSHOperationEvents-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: support)
        let router = AppCommandRouter(
            context: context,
            sshPasswordStore: NoopSSHPasswordStore(),
            sshCommandRunner: commandRunner
        )
        context.router = router
        let workspace = WorkspaceID()
        let surface = TestSSHTransferSurface(workspace: workspace)
        SurfaceRegistry.shared.register(surface)
        return (context, router, workspace, surface)
    }

    func test_directProviderUpdatePublishesOneSanitizedEventForSuccessAndFailure() async throws {
        try await assertProviderUpdateEvent(route: .direct, exitCode: 0)
        try await assertProviderUpdateEvent(route: .direct, exitCode: 23)
    }

    func test_jsonRPCProviderUpdatePublishesOneSanitizedEventForSuccessAndFailure() async throws {
        try await assertProviderUpdateEvent(route: .jsonRPC, exitCode: 0)
        try await assertProviderUpdateEvent(route: .jsonRPC, exitCode: 23)
    }

    private func assertProviderUpdateEvent(route: ProviderUpdateRoute, exitCode: Int32) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ProviderUpdateEvents-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("private-provider-home", isDirectory: true)
        let binary = root.appendingPathComponent("private-provider-binary")
        let privateDetail = "private-provider-detail-\(UUID().uuidString)"
        let privateInstanceID = "private-provider-instance-\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        #!/bin/sh
        if [ "$1" = "update" ]; then
          printf '\(privateDetail)\\n'
          printf '\(privateDetail)\\n' >&2
          exit \(exitCode)
        fi
        exit 99
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let context = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        defer { withExtendedLifetime(context) {} }
        let router = AppCommandRouter(context: context)
        context.router = router
        try context.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "\(privateInstanceID)",
            "provider": "codex",
            "binaryPath": "\(binary.path)",
            "homePath": "\(home.path)",
            "enabled": true,
            "env": {"PROVIDER_PRIVATE_TOKEN": "\(privateDetail)"}
          }
        ]
        """)

        let capture = EventCapture()
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.provider.updated" else { return }
            capture.append(event)
        }
        defer { EventBus.shared.unsubscribe(token) }

        let response: JSONValue
        switch route {
        case .direct:
            response = try await router.updateAgentProvider(
                provider: .codex,
                providerInstanceId: privateInstanceID
            )
        case .jsonRPC:
            let rpcResponse = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(1),
                method: "agent.provider.update",
                params: [
                    "provider": .string("codex"),
                    "provider_instance_id": .string(privateInstanceID)
                ]
            ))
            XCTAssertNil(rpcResponse.error)
            response = try XCTUnwrap(rpcResponse.result)
        }

        let expectedOK = exitCode == 0
        XCTAssertEqual(response.objectValue?["ok"], .bool(expectedOK))
        XCTAssertEqual(response.objectValue?["status"], .number(Double(exitCode)))

        let providerEvents = capture.events
        XCTAssertEqual(
            providerEvents.count,
            1,
            "the operation owner must publish exactly once; JSON-RPC must not duplicate the same provider outcome"
        )
        let payload = try XCTUnwrap(providerEvents.first?.payload.objectValue)
        XCTAssertEqual(Set(payload.keys), Set(["provider", "ok", "status"]))
        XCTAssertEqual(payload["provider"], .string("codex"))
        XCTAssertEqual(payload["ok"], .bool(expectedOK))
        XCTAssertEqual(payload["status"], .number(Double(exitCode)))

        let serializedPayload = String(
            decoding: try JSONEncoder().encode(providerEvents[0].payload),
            as: UTF8.self
        )
        for forbiddenValue in [binary.path, home.path, privateInstanceID, privateDetail] {
            XCTAssertFalse(
                serializedPayload.contains(forbiddenValue),
                "provider outcome events must not expose executable paths, home paths, instance IDs, output, errors, or secrets"
            )
        }
    }

    func test_projectScriptOwnerPublishesCorrelatedSuccessAndFailureExactlyOnce() async throws {
        let projectDirectory = NSTemporaryDirectory() + "RC2ProjectScriptEvents-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: projectDirectory) }
        try """
        pet-ok:
        \t@true
        pet-fail:
        \t@false
        """.write(toFile: projectDirectory + "/Makefile", atomically: true, encoding: .utf8)

        let previousRuntimeSink = SurfaceRuntimeBus.shared.sink
        defer { SurfaceRuntimeBus.shared.sink = previousRuntimeSink }
        let (context, router, workspace) = try makeRouter(projectDirectory: projectDirectory)
        defer { withExtendedLifetime(context) {} }
        let capture = EventCapture()
        let startSeq = EventBus.shared.currentSeq
        let token = EventBus.shared.subscribe(since: startSeq) { event in
            guard event.kind == "project.script_started" || event.kind == "project.script.finished" else { return }
            capture.append(event)
        }
        defer { EventBus.shared.unsubscribe(token) }

        let succeededSurface = try router.projectRunScript(workspace: workspace.id, name: "pet-ok")
        await waitUntil("successful project script terminal outcome") {
            capture.events.contains {
                $0.kind == "project.script.finished"
                    && $0.payload.objectValue?["surface_id"]?.stringValue == succeededSurface.id.value.uuidString
            }
        }
        try assertProjectLifecycle(
            events: capture.events,
            workspace: workspace.id,
            surface: succeededSurface.id,
            name: "pet-ok",
            expectedResult: "success",
            expectedExitCode: 0
        )

        let dispatcher = JSONRPCDispatcher(router: router)
        let failedResponse = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "project.run_script",
            params: [
                "workspace_id": .string(workspace.id.value.uuidString),
                "name": .string("pet-fail")
            ]
        ))
        XCTAssertNil(failedResponse.error)
        let failedSurfaceID = try XCTUnwrap(
            failedResponse.result?.objectValue?["id"]?.objectValue?["value"]?.stringValue
                .flatMap(UUID.init)
                .map(SurfaceID.init)
        )
        await waitUntil("failed project script terminal outcome") {
            capture.events.contains {
                $0.kind == "project.script.finished"
                    && $0.payload.objectValue?["surface_id"]?.stringValue == failedSurfaceID.value.uuidString
            }
        }
        try assertProjectLifecycle(
            events: capture.events,
            workspace: workspace.id,
            surface: failedSurfaceID,
            name: "pet-fail",
            expectedResult: "failure",
            expectedExitCode: nil
        )

        let terminal = try XCTUnwrap(SurfaceRegistry.shared.surface(failedSurfaceID) as? TerminalSurface)
        SurfaceRuntimeBus.shared.emit(failedSurfaceID, terminal.runtimeHealth())
        SurfaceRuntimeBus.shared.emit(failedSurfaceID, terminal.runtimeHealth())
        XCTAssertEqual(
            capture.events.filter {
                $0.kind == "project.script.finished"
                    && $0.payload.objectValue?["surface_id"]?.stringValue == failedSurfaceID.value.uuidString
            }.count,
            1,
            "duplicate terminal-death health must not create duplicate user-visible project outcomes"
        )
    }

    func test_projectScriptOwnerPublishesTcshOutcomesWithExactExitStatus() async throws {
        let projectDirectory = NSTemporaryDirectory() + "RC2ProjectScriptTcsh-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: projectDirectory) }
        try """
        pet-tcsh:
        \t@true
        pet-tcsh-fail:
        \t@false
        """.write(toFile: projectDirectory + "/Makefile", atomically: true, encoding: .utf8)

        let previousShell = ProcessInfo.processInfo.environment["SHELL"]
        setenv("SHELL", "/bin/tcsh", 1)
        defer {
            if let previousShell {
                setenv("SHELL", previousShell, 1)
            } else {
                unsetenv("SHELL")
            }
        }

        let previousRuntimeSink = SurfaceRuntimeBus.shared.sink
        defer { SurfaceRuntimeBus.shared.sink = previousRuntimeSink }
        let (context, router, workspace) = try makeRouter(projectDirectory: projectDirectory)
        defer { withExtendedLifetime(context) {} }
        let capture = EventCapture()
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "project.script_started" || event.kind == "project.script.finished" else { return }
            capture.append(event)
        }
        defer { EventBus.shared.unsubscribe(token) }

        let surface = try router.projectRunScript(workspace: workspace.id, name: "pet-tcsh")
        await waitUntil("tcsh project script terminal outcome") {
            capture.events.contains {
                $0.kind == "project.script.finished"
                    && $0.payload.objectValue?["surface_id"]?.stringValue == surface.id.value.uuidString
            }
        }
        try assertProjectLifecycle(
            events: capture.events,
            workspace: workspace.id,
            surface: surface.id,
            name: "pet-tcsh",
            expectedResult: "success",
            expectedExitCode: 0
        )

        let failedSurface = try router.projectRunScript(workspace: workspace.id, name: "pet-tcsh-fail")
        await waitUntil("tcsh failed project script terminal outcome") {
            capture.events.contains {
                $0.kind == "project.script.finished"
                    && $0.payload.objectValue?["surface_id"]?.stringValue == failedSurface.id.value.uuidString
            }
        }
        try assertProjectLifecycle(
            events: capture.events,
            workspace: workspace.id,
            surface: failedSurface.id,
            name: "pet-tcsh-fail",
            expectedResult: "failure",
            expectedExitCode: 2
        )
    }

    func test_projectScriptTerminalInputIsPortableAcrossTcshAndFish() {
        let input = AppCommandRouter.projectScriptTerminalInput(command: "make pet-check")

        XCTAssertEqual(input, "exec make pet-check\n")
        XCTAssertEqual(input.split(whereSeparator: \.isNewline).count, 1)
        for shellSpecificSyntax in ["$?", "$status", "__remote_code_status", "set "] {
            XCTAssertFalse(
                input.contains(shellSpecificSyntax),
                "tcsh and fish must receive one portable exec command, never POSIX or shell-specific status syntax"
            )
        }
    }

    func test_projectScriptSignalTerminationUsesShellCompatibleExitCode() throws {
        let workspaceID = WorkspaceID()
        let surfaceID = SurfaceID()
        let registry = ProjectScriptRunRegistry(now: { Date(timeIntervalSince1970: 10) })
        registry.register(workspaceID: workspaceID, surfaceID: surfaceID, name: "terminated")

        let outcome = try XCTUnwrap(registry.consumeTerminalDeath(
            surfaceID: surfaceID,
            health: TerminalRuntimeHealth(
                processAlive: false,
                childPID: nil,
                exitStatus: 9,
                terminationSignal: 9,
                ptyOpen: false,
                inputAccepting: false,
                terminalDeadReason: "process_exited",
                lastOutputAt: nil,
                outputPartial: false,
                outputPendingBytes: 0,
                historyWriteFailures: 0,
                rows: 24,
                cols: 80
            )
        ))

        XCTAssertEqual(outcome.exitCode, 137,
            "Signal 9 must become shell-compatible 128 + signal so Pet records a failure, not an ambiguous raw wait status.")
        XCTAssertEqual(outcome.result, "failure")
        XCTAssertNil(registry.consumeTerminalDeath(
            surfaceID: surfaceID,
            health: TerminalRuntimeHealth(
                processAlive: false,
                childPID: nil,
                exitStatus: 9,
                terminationSignal: 9,
                ptyOpen: false,
                inputAccepting: false,
                terminalDeadReason: "process_exited",
                lastOutputAt: nil,
                outputPartial: false,
                outputPendingBytes: 0,
                historyWriteFailures: 0,
                rows: 24,
                cols: 80
            )
        ), "A terminal death may be consumed only once.")
    }

    func test_sshTransferPreservesEventNamesAndAddsSafeCorrelatedOutcomes() throws {
        for item in [
            (exitCode: Int32(0), direction: "upload", terminalKind: "ssh.transfer.completed", result: "success"),
            (exitCode: Int32(23), direction: "download", terminalKind: "ssh.transfer.failed", result: "failure"),
        ] {
            let (context, router, workspace, surface) = try makeSSHRouter { _, _, _ in
                (exitCode: item.exitCode, output: "safe runner output")
            }
            defer { withExtendedLifetime(context) {} }
            let startSeq = EventBus.shared.currentSeq
            let localPath = "/tmp/private-local-secret-\(UUID().uuidString)"
            let remotePath = "/srv/private-remote-secret-\(UUID().uuidString)"

            if item.direction == "upload" {
                _ = try router.sshTransferUpload(surface: surface.descriptor.id, localPath: localPath, remotePath: remotePath)
            } else {
                _ = try router.sshTransferDownload(surface: surface.descriptor.id, remotePath: remotePath, localPath: localPath)
            }

            let events = transferEvents(since: startSeq, surface: surface.descriptor.id)
            try assertSSHTransferLifecycle(
                events: events,
                workspace: workspace,
                surface: surface.descriptor.id,
                direction: item.direction,
                terminalKind: item.terminalKind,
                result: item.result,
                exitCode: item.exitCode
            )
            SurfaceRegistry.shared.unregister(surface.descriptor.id)
        }
    }

    func test_syncAndAsyncSSHTransferThrownErrorsEmitFailedOutcomes() async throws {
        let (syncContext, syncRouter, syncWorkspace, syncSurface) = try makeSSHRouter { _, _, _ in throw CommandFailure() }
        defer { withExtendedLifetime(syncContext) {} }
        let syncStartSeq = EventBus.shared.currentSeq
        XCTAssertThrowsError(
            try syncRouter.sshTransferUpload(
                surface: syncSurface.descriptor.id,
                localPath: "/tmp/private-sync-secret",
                remotePath: "/srv/private-sync-secret"
            )
        )
        try assertSSHTransferLifecycle(
            events: transferEvents(since: syncStartSeq, surface: syncSurface.descriptor.id),
            workspace: syncWorkspace,
            surface: syncSurface.descriptor.id,
            direction: "upload",
            terminalKind: "ssh.transfer.failed",
            result: "failure",
            exitCode: nil
        )
        SurfaceRegistry.shared.unregister(syncSurface.descriptor.id)

        let (asyncContext, asyncRouter, asyncWorkspace, asyncSurface) = try makeSSHRouter { _, _, _ in throw CommandFailure() }
        defer { withExtendedLifetime(asyncContext) {} }
        let asyncStartSeq = EventBus.shared.currentSeq
        do {
            _ = try await asyncRouter.sshTransferDownloadAsync(
                surface: asyncSurface.descriptor.id,
                remotePath: "/srv/private-async-secret",
                localPath: "/tmp/private-async-secret"
            )
            XCTFail("the injected async command error must propagate to the caller")
        } catch is CommandFailure {
            // Expected. The failed lifecycle event is asserted below.
        }
        try assertSSHTransferLifecycle(
            events: transferEvents(since: asyncStartSeq, surface: asyncSurface.descriptor.id),
            workspace: asyncWorkspace,
            surface: asyncSurface.descriptor.id,
            direction: "download",
            terminalKind: "ssh.transfer.failed",
            result: "failure",
            exitCode: nil
        )
        SurfaceRegistry.shared.unregister(asyncSurface.descriptor.id)
    }

    private func transferEvents(since sequence: Int64, surface: SurfaceID) -> [EventBus.Event] {
        EventBus.shared.recentEvents(since: sequence, maxBytes: nil).events.filter {
            $0.kind.hasPrefix("ssh.transfer.")
                && $0.payload.objectValue?["surface_id"]?.stringValue == surface.value.uuidString
        }
    }

    private func assertSSHTransferLifecycle(
        events: [EventBus.Event],
        workspace: WorkspaceID,
        surface: SurfaceID,
        direction: String,
        terminalKind: String,
        result: String,
        exitCode: Int32?
    ) throws {
        XCTAssertEqual(
            events.map(\.kind),
            ["ssh.transfer.started", terminalKind],
            "every transfer must publish one ordered start/outcome pair while preserving iOS-compatible event names"
        )
        let started = try XCTUnwrap(events.first?.payload.objectValue)
        let finished = try XCTUnwrap(events.last?.payload.objectValue)
        XCTAssertEqual(Set(started.keys), ["workspace_id", "surface_id", "transfer_id", "direction"])
        XCTAssertEqual(
            Set(finished.keys),
            ["workspace_id", "surface_id", "transfer_id", "direction", "exit_code", "duration_ms", "result"]
        )
        XCTAssertEqual(started["workspace_id"]?.stringValue, workspace.value.uuidString)
        XCTAssertEqual(finished["workspace_id"]?.stringValue, workspace.value.uuidString)
        XCTAssertEqual(started["surface_id"]?.stringValue, surface.value.uuidString)
        XCTAssertEqual(started["direction"]?.stringValue, direction)
        XCTAssertEqual(finished["direction"]?.stringValue, direction)
        XCTAssertEqual(started["transfer_id"]?.stringValue, finished["transfer_id"]?.stringValue)
        XCTAssertFalse(started["transfer_id"]?.stringValue?.isEmpty ?? true)
        XCTAssertEqual(finished["result"]?.stringValue, result)
        XCTAssertGreaterThanOrEqual(finished["duration_ms"]?.intValue ?? -1, 0)
        if let exitCode {
            XCTAssertEqual(finished["exit_code"]?.intValue, Int(exitCode))
        } else {
            XCTAssertEqual(finished["exit_code"], .null)
        }
    }

    private func assertProjectLifecycle(
        events: [EventBus.Event],
        workspace: WorkspaceID,
        surface: SurfaceID,
        name: String,
        expectedResult: String,
        expectedExitCode: Int?
    ) throws {
        let matching = events.filter {
            $0.payload.objectValue?["surface_id"]?.stringValue == surface.value.uuidString
        }
        XCTAssertEqual(
            matching.map(\.kind),
            ["project.script_started", "project.script.finished"],
            "the operation owner must publish one ordered start/finish pair even when no Dispatcher RPC initiated the script"
        )

        let started = try XCTUnwrap(matching.first?.payload.objectValue)
        XCTAssertEqual(Set(started.keys), ["workspace_id", "surface_id", "name"])
        XCTAssertEqual(started["workspace_id"]?.stringValue, workspace.value.uuidString)
        XCTAssertEqual(started["name"]?.stringValue, name)

        let finished = try XCTUnwrap(matching.last?.payload.objectValue)
        XCTAssertEqual(Set(finished.keys), ["workspace_id", "surface_id", "name", "exit_code", "duration_ms", "result"])
        XCTAssertEqual(finished["workspace_id"]?.stringValue, workspace.value.uuidString)
        XCTAssertEqual(finished["name"]?.stringValue, name)
        XCTAssertEqual(finished["result"]?.stringValue, expectedResult)
        XCTAssertGreaterThanOrEqual(finished["duration_ms"]?.intValue ?? -1, 0)
        if let expectedExitCode {
            XCTAssertEqual(finished["exit_code"]?.intValue, expectedExitCode)
        } else {
            XCTAssertNotEqual(finished["exit_code"]?.intValue, 0)
        }
    }
}
