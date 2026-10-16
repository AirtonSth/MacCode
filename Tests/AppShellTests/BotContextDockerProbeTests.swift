import XCTest
import CoreModel
import Persistence
@testable import AppShell

final class BotContextDockerProbeTests: XCTestCase {
    func test_liveContextualRuntimesSeparateFilesAndHomes() throws {
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 for the real contextual runtime probe")
        }
        let docker = BotComputerDockerCLI()
        _ = try docker.info()
        guard try docker.imageExists(tag: BotComputerGuestSpec.imageTag),
              try docker.imageLabel(tag: BotComputerGuestSpec.imageTag, key: BotComputerGuestSpec.recipeLabelKey) == BotComputerGuestSpec.recipeRevision else {
            XCTFail("The matching existing guest image is required; this probe never builds a shared image.")
            return
        }
        let originalImage = try docker.imageID(tag: BotComputerGuestSpec.imageTag)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-docker-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let pathA = root.appendingPathComponent("workspace-a", isDirectory: true)
        let pathB = root.appendingPathComponent("workspace-b", isDirectory: true)
        for path in [pathA, pathB] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let markerA = pathA.appendingPathComponent("marker.txt")
        let markerB = pathB.appendingPathComponent("marker.txt")
        try Data("A".utf8).write(to: markerA)
        try Data("B".utf8).write(to: markerB)
        let workspaceA = Workspace.empty(name: "Probe A", cwd: pathA.path)
        let workspaceB = Workspace.empty(name: "Probe B", cwd: pathB.path)
        let botID = BotID()
        let bindingA = BotContextBinding(hostID: "context-probe", botID: botID, context: .workspace(workspaceA.id), state: .active, policyRevision: 1, actions: [.read, .send, .files])
        let bindingB = BotContextBinding(hostID: "context-probe", botID: botID, context: .workspace(workspaceB.id), state: .active, policyRevision: 1, actions: [.read, .send, .files])
        let identityA = try BotContextRuntimeIdentity(binding: bindingA)
        let identityB = try BotContextRuntimeIdentity(binding: bindingB)
        let nameA = BotComputerGuestSpec.containerName(botID: identityA.storageBotID)
        let nameB = BotComputerGuestSpec.containerName(botID: identityB.storageBotID)
        let service = BotComputerGuestService(appSupport: support, docker: docker, recipeContext: nil, observeAttempts: 60, observeDelay: 0.5)
        print("Task-owned context runtimes: \(nameA), \(nameB); support: \(support.path)")
        defer {
            var clean = true
            for identity in [identityA, identityB] {
                do {
                    try service.wipe(identity: identity)
                    if try docker.containerExists(name: BotComputerGuestSpec.containerName(botID: identity.storageBotID)) {
                        clean = false
                        XCTFail("Task-owned runtime remains after cleanup")
                    }
                } catch { clean = false; XCTFail("Task-owned runtime cleanup failed: \(error)") }
            }
            if clean {
                do { try FileManager.default.removeItem(at: root) }
                catch { XCTFail("Task-owned fixture cleanup failed: \(error)") }
            }
        }
        func provision(_ binding: BotContextBinding, _ workspace: Workspace) throws -> (BotComputerGuestReady, Double) {
            let started = DispatchTime.now().uptimeNanoseconds
            let ready = try service.provision(contextBinding: binding, workspace: workspace, registeredWorkspaces: [workspaceA.cwd, workspaceB.cwd])
            return (ready, Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        let (readyA, coldA) = try provision(bindingA, workspaceA)
        let (readyB, coldB) = try provision(bindingB, workspaceB)
        XCTAssertNotEqual(readyA.containerID, readyB.containerID)
        let observedA = try docker.inspect(name: nameA)
        let observedB = try docker.inspect(name: nameB)
        XCTAssertNotEqual(observedA.homeSource, observedB.homeSource)
        XCTAssertTrue(Set(observedA.networkNames).isDisjoint(with: observedB.networkNames))
        let homeMarker = BotComputerGuestSpec.guestUserHome + "/context-probe-marker"
        let verify = "test \"$(cat \"$1\")\" = \"$2\" && test ! -e \"$3\" && printf %s \"$2\" > \"$4\" && cat \"$4\""
        XCTAssertEqual(String(decoding: try docker.exec(name: nameA, command: ["sh", "-c", verify, "probe", markerA.path, "A", markerB.path, homeMarker]), as: UTF8.self), "A")
        XCTAssertEqual(String(decoding: try docker.exec(name: nameB, command: ["sh", "-c", verify, "probe", markerB.path, "B", markerA.path, homeMarker]), as: UTF8.self), "B")
        for (name, expected) in [(nameA, "A"), (nameB, "B")] {
            XCTAssertEqual(String(decoding: try docker.exec(name: name, command: ["cat", homeMarker]), as: UTF8.self), expected)
            _ = try docker.exec(name: name, command: ["sh", "-c", "test ! -e \"$1/.distill/accounts\" && test ! -e \"$1/.distill/claude-auth.json\" && test ! -e \"$1/.distill/codex-auth.json\" && test ! -e \"$1/.distill/auth.json\"", "probe", BotComputerGuestSpec.guestUserHome])
        }
        var warmMilliseconds: [Double] = []
        for _ in 0..<5 {
            let (ready, elapsed) = try provision(bindingA, workspaceA)
            XCTAssertEqual(ready.containerID, readyA.containerID)
            warmMilliseconds.append(elapsed)
        }
        print("Context runtime cold milliseconds: A=\(coldA), B=\(coldB); warm A milliseconds: \(warmMilliseconds)")
        print(String(decoding: try docker.run(["stats", "--no-stream", "--format", "{{json .}}", nameA, nameB]), as: UTF8.self))
        XCTAssertEqual(try docker.imageID(tag: BotComputerGuestSpec.imageTag), originalImage)
        XCTAssertEqual(readyA.pngMagic, "89504e47")
        XCTAssertEqual(readyB.pngMagic, "89504e47")
        if let directory = ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_CAPTURE_DIR"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try readyA.capturedPNG.write(to: output.appendingPathComponent("context-runtime-a.png"))
            try readyB.capturedPNG.write(to: output.appendingPathComponent("context-runtime-b.png"))
        }
    }
}
