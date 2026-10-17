import XCTest
import AgentRuntime
import CoreModel
import Persistence
import SocketServer
@testable import AppShell

/// Credential-free A/B probe: two contextual runtimes of one bot, each seeded with
/// unique file, cookie, temp, environment and process-memory markers, must never
/// observe the other's markers. Uses the existing guest image; never builds or pulls.
@MainActor
final class BotContextABMarkerDockerTests: XCTestCase {
    func test_liveTwoContextsShareNoFilesCookiesMemoryOrEnvironment() async throws {
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 for the A/B marker Docker probe")
        }
        let docker = BotComputerDockerCLI()
        _ = try docker.info()
        guard try docker.imageExists(tag: BotComputerGuestSpec.imageTag),
              try docker.imageLabel(tag: BotComputerGuestSpec.imageTag, key: BotComputerGuestSpec.recipeLabelKey) == BotComputerGuestSpec.recipeRevision else {
            throw XCTSkip("matching existing guest image unavailable; probe never builds or pulls")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ab-marker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var cleanupConfirmed = true
        defer { if cleanupConfirmed { try? FileManager.default.removeItem(at: root) } }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let ctx = try AppContext(channel: .debug, dbPathOverride: root.appendingPathComponent("probe.sqlite").path, appSupportOverride: support.path, privateAccountAPI: SilentWakeRecordingAPI(), performLaunchRunReconciliation: true, contextualSecretStore: InMemoryBotSecretStore())
        ctx.router = AppCommandRouter(context: ctx)
        let router = try XCTUnwrap(ctx.router)
        let host = ctx.liveActivityHostIdentity.serverId
        let paths = ["workspace-a", "workspace-b"].map { root.appendingPathComponent($0, isDirectory: true) }
        for path in paths { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let workspaces = try paths.enumerated().map { try router.createWorkspace(name: "AB \($0.offset)", cwd: $0.element.path) }
        let bot = try ctx.botStore.create(name: "AB", title: "AB", description: "", handle: "ab-\(UUID().uuidString.prefix(8))", soul: "", provider: .distill, model: "test")
        let bindings = try workspaces.map { try ctx.botStore.grantContext(hostID: host, botID: bot.id, context: .workspace($0.id), actions: [.read, .send, .configure, .files], expectedRevision: 0) }
        let identities = try bindings.map { try BotContextRuntimeIdentity(binding: $0) }
        let service = BotComputerGuestService(appSupport: support, docker: docker, recipeContext: nil)
        let names = identities.map { BotComputerGuestSpec.containerName(botID: $0.storageBotID) }
        defer {
            for identity in identities {
                do {
                    try service.wipe(identity: identity)
                    let container = BotComputerGuestSpec.containerName(botID: identity.storageBotID)
                    let network = BotComputerGuestSpec.networkName(botID: identity.storageBotID)
                    let containerExists = try docker.containerExists(name: container)
                    let networkExists = try docker.networkExists(name: network)
                    cleanupConfirmed = cleanupConfirmed && !containerExists && !networkExists
                    XCTAssertFalse(containerExists)
                    XCTAssertFalse(networkExists)
                } catch { cleanupConfirmed = false; XCTFail("Owned runtime cleanup failed: \(error)") }
            }
        }
        for index in bindings.indices {
            _ = try service.provision(contextBinding: bindings[index], workspace: workspaces[index], registeredWorkspaces: Set(paths.map(\.path)))
        }
        let markers = (0..<2).map { _ in (file: UUID().uuidString, cookie: UUID().uuidString, tmp: UUID().uuidString, env: UUID().uuidString, memory: UUID().uuidString) }
        let home = BotComputerGuestSpec.guestUserHome
        let seed = "mkdir -p \"$1/.config/chromium/Default\" && printf %s \"$2\" > \"$1/ab-file\" && printf %s \"$3\" > \"$1/.config/chromium/Default/Cookies\" && printf %s \"$4\" > /tmp/ab-tmp"
        for index in names.indices {
            let m = markers[index]
            _ = try docker.exec(name: names[index], command: ["sh", "-c", seed, "probe", home, m.file, m.cookie, m.tmp], user: BotComputerGuestSpec.agentUser)
            // Long-lived process whose argv and environment carry the memory/env markers.
            _ = try docker.exec(name: names[index], command: ["sh", "-c", "sleep 120", m.memory], user: BotComputerGuestSpec.agentUser, detach: true, workdir: nil, environment: ["AB_ENV_MARKER": m.env])
        }
        for index in names.indices {
            let own = markers[index]
            let peer = markers[1 - index]
            let readOwn = "cat \"$1/ab-file\" \"$1/.config/chromium/Default/Cookies\" /tmp/ab-tmp"
            XCTAssertEqual(String(decoding: try docker.exec(name: names[index], command: ["sh", "-c", readOwn, "probe", home], user: BotComputerGuestSpec.agentUser), as: UTF8.self), own.file + own.cookie + own.tmp, "Each context must see its own markers")
            let snapshot = "cat \"$1/ab-file\" \"$1/.config/chromium/Default/Cookies\" /tmp/ab-tmp; for p in /proc/[0-9]*; do cat \"$p/cmdline\" \"$p/environ\" 2>/dev/null | tr '\\0' '\\n'; done; ls -R \"$1\" /tmp 2>/dev/null"
            let visible = String(decoding: try docker.exec(name: names[index], command: ["sh", "-c", snapshot, "probe", home], user: BotComputerGuestSpec.agentUser), as: UTF8.self)
            XCTAssertTrue(visible.contains(own.memory), "Control: own process argv must be observable")
            XCTAssertTrue(visible.contains(own.env), "Control: own process environment must be observable")
            for (label, value) in [("file", peer.file), ("cookie", peer.cookie), ("tmp", peer.tmp), ("env", peer.env), ("memory", peer.memory)] {
                XCTAssertFalse(visible.contains(value), "Context \(index) observed the peer's \(label) marker")
            }
            let otherWorkspace = paths[1 - index].path
            _ = try docker.exec(name: names[index], command: ["sh", "-c", "test ! -e \"$1\"", "probe", otherWorkspace], user: BotComputerGuestSpec.agentUser)
        }
        let a = try docker.inspect(name: names[0]), b = try docker.inspect(name: names[1])
        XCTAssertNotEqual(a.homeSource, b.homeSource)
        XCTAssertTrue(Set(a.networkNames).isDisjoint(with: Set(b.networkNames)))
        for index in identities.indices {
            let hostHome = BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: identities[index].storageBotID)
            let peerValues = [markers[1 - index].file, markers[1 - index].cookie]
            let files = FileManager.default.enumerator(at: hostHome, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            for url in files where !url.hasDirectoryPath {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                for value in peerValues { XCTAssertFalse(text.contains(value), "Peer marker leaked into \(url.lastPathComponent)") }
            }
        }
    }
}
