import XCTest
import CoreModel
import Persistence
@testable import AppShell

private final class FakeDocker: BotComputerDockerClienting, @unchecked Sendable {
    var infoText = "ok"
    var images: Set<String> = [BotComputerGuestSpec.imageTag]
    var containers: [String: BotComputerContainerInspect] = [:]
    var png = BotComputerGuestObserve.pngSignature + Data(repeating: 1, count: 16)
    var created: [String] = []
    var removed: [String] = []
    var started: [String] = []
    var stopped: [String] = []
    var builds: [URL] = []
    var execCalls = 0
    var execFailuresRemaining = 0
    var lastExec: (name: String, command: [String], user: String?, detach: Bool)?
    var networks: [String] = []
    var renamed: [(String, String)] = []
    var imageLabels: [String: String] = [
        BotComputerGuestSpec.imageTag: BotComputerGuestSpec.recipeRevision
    ]

    func info() throws -> String { infoText }
    func imageExists(tag: String) throws -> Bool { images.contains(tag) }
    func imageLabel(tag: String, key: String) throws -> String {
        guard key == BotComputerGuestSpec.recipeLabelKey else { return "" }
        return imageLabels[tag] ?? ""
    }
    func imageID(tag: String) throws -> String {
        guard images.contains(tag) else { throw BotComputerGuestError.dockerUnavailable }
        return "img"
    }
    func build(context: URL, tag: String) throws {
        builds.append(context)
        images.insert(tag)
        imageLabels[tag] = BotComputerGuestSpec.recipeRevision
    }
    func create(options: BotComputerContainerCreateOptions) throws -> String {
        created.append(options.name)
        containers[options.name] = BotComputerContainerInspect(running: false, imageID: "img", hostPort: 49152)
        return options.name
    }
    func start(name: String) throws {
        started.append(name)
        containers[name] = BotComputerContainerInspect(running: true, imageID: "img", hostPort: 49152)
    }
    func stop(name: String) throws {
        stopped.append(name)
        if var value = containers[name] {
            value.running = false
            containers[name] = value
        }
    }
    func inspect(name: String) throws -> BotComputerContainerInspect {
        guard let value = containers[name] else { throw BotComputerGuestError.notReady }
        return value
    }
    func exec(name: String, command: [String], user: String?, detach: Bool) throws -> Data {
        execCalls += 1
        lastExec = (name, command, user, detach)
        if execFailuresRemaining > 0 {
            execFailuresRemaining -= 1
            throw BotComputerGuestError.observeFailed
        }
        return png
    }
    func rename(from: String, to: String) throws {
        renamed.append((from, to))
        containers[to] = containers[from]
        containers[from] = nil
    }
    func ensureNetwork(name: String) throws {
        networks.append(name)
    }
    func remove(name: String) throws {
        removed.append(name)
        containers[name] = nil
    }
    func removeMatching(namePrefix: String) throws {
        for name in containers.keys where name.hasPrefix(namePrefix) {
            try remove(name: name)
        }
    }
}

@MainActor
final class BotComputerGuestServiceTests: XCTestCase {
    func test_proveReadyRequiresPNGAndLoopback() throws {
        // WHY: Studio must not enable Docker desktop on a JPEG or a LAN bind.
        let support = makeSupport("rc-guest-svc")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 2,
            observeDelay: 0
        )
        XCTAssertTrue(service.proveReady())
        XCTAssertEqual(service.lastReady?.screenURL.host, "127.0.0.1")
        XCTAssertEqual(service.lastReady?.pngMagic, BotComputerGuestService.pngMagicHex)
        fake.png = Data("jpeg".utf8)
        XCTAssertFalse(service.proveReady())
        XCTAssertTrue(fake.created.allSatisfy { name in fake.removed.contains(name) })
    }

    func test_proveReadyBuildsBundledRecipeWhenImageMissing() throws {
        // WHY: Studio must build remotecode/computer:local from the bundled
        // ComputerGuest recipe instead of staying disabled forever.
        let support = makeSupport("rc-guest-build")
        defer { try? FileManager.default.removeItem(at: support) }
        let recipe = try XCTUnwrap(AppShellResourceBundle.computerGuestRecipeURL())
        let fake = FakeDocker()
        fake.images = []
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            recipeContext: recipe,
            observeAttempts: 1,
            observeDelay: 0
        )
        XCTAssertTrue(service.proveReady())
        XCTAssertEqual(fake.builds, [recipe])
        XCTAssertTrue(fake.images.contains(BotComputerGuestSpec.imageTag))
        XCTAssertEqual(service.lastReady?.pngMagic, "89504e47")
        XCTAssertEqual(service.lastReady?.screenURL.host, "127.0.0.1")
    }

    func test_proveReadyFailsClosedWithoutRecipeWhenImageMissing() throws {
        let support = makeSupport("rc-guest-norecipe")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        fake.images = []
        let service = BotComputerGuestService(appSupport: support, docker: fake)
        XCTAssertFalse(service.proveReady())
        XCTAssertEqual(service.lastReason, "Docker image missing")
        XCTAssertTrue(fake.builds.isEmpty)
        XCTAssertTrue(fake.created.isEmpty)
    }

    func test_proveReadyRebuildsImageWhenRecipeRevisionIsStale() throws {
        // WHY: Removing -viewonly from start.sh does nothing if Studio
        // keeps the old remotecode/computer:local image.
        let support = makeSupport("rc-guest-stale")
        defer { try? FileManager.default.removeItem(at: support) }
        let recipe = try XCTUnwrap(AppShellResourceBundle.computerGuestRecipeURL())
        let fake = FakeDocker()
        fake.imageLabels = [:]
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            recipeContext: recipe,
            observeAttempts: 1,
            observeDelay: 0
        )
        XCTAssertTrue(service.proveReady())
        XCTAssertEqual(fake.builds, [recipe])
        XCTAssertEqual(fake.imageLabels[BotComputerGuestSpec.imageTag], BotComputerGuestSpec.recipeRevision)
    }

    func test_provisionRecreatesContainerWhenImageIsStale() throws {
        let support = makeSupport("rc-guest-recreate")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        let botID = BotID()
        let name = BotComputerGuestSpec.containerName(botID: botID)
        fake.containers[name] = BotComputerContainerInspect(
            running: true, imageID: "old-viewonly", hostPort: 49152
        )
        let ready = try service.provision(botID: botID)
        XCTAssertFalse(ready.resumed)
        XCTAssertTrue(fake.removed.contains(name))
        XCTAssertTrue(fake.created.contains(name))
        service.teardown(botID: botID)
    }

    func test_proveReadyRetriesUntilPNGThenRemovesProbe() throws {
        // WHY: Xvfb is not a PNG on the first exec. A single import would
        // flake the Studio radio and leak remotecode-probe-*.
        let support = makeSupport("rc-guest-retry")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        fake.execFailuresRemaining = 2
        let slept = SleepCounter()
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 4,
            observeDelay: 0.01,
            sleep: { _ in slept.count += 1 }
        )
        XCTAssertTrue(service.proveReady())
        XCTAssertEqual(fake.execCalls, 3)
        XCTAssertEqual(slept.count, 2)
        XCTAssertEqual(fake.created.count, 1)
        XCTAssertEqual(fake.removed, fake.created)
        XCTAssertTrue(fake.containers.isEmpty)
        XCTAssertEqual(service.lastReady?.pngMagic, BotComputerGuestService.pngMagicHex)
        XCTAssertEqual(service.lastReady?.screenURL.host, "127.0.0.1")
    }

    func test_proveReadyScavengesLeftoverProbes() throws {
        let support = makeSupport("rc-guest-scavenge")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        fake.containers["remotecode-probe-stale"] = BotComputerContainerInspect(
            running: false, imageID: "img", hostPort: 1
        )
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        XCTAssertTrue(service.proveReady())
        XCTAssertFalse(fake.containers.keys.contains("remotecode-probe-stale"))
        XCTAssertTrue(fake.removed.contains("remotecode-probe-stale"))
    }

    func test_proveReadyRemovesProbeWhenPNGNeverArrives() throws {
        let support = makeSupport("rc-guest-leak")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        fake.execFailuresRemaining = 99
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 3,
            observeDelay: 0
        )
        XCTAssertFalse(service.proveReady())
        XCTAssertEqual(fake.execCalls, 3)
        XCTAssertEqual(fake.removed, fake.created)
        XCTAssertTrue(fake.containers.isEmpty)
        XCTAssertNil(service.lastReady)
    }

    func test_observeAndActDriveTheGuestThroughDockerExec() throws {
        // WHY: dockerDesktop tools must screenshot and click the guest,
        // not this Mac. Fake docker records the exact exec argv.
        let support = makeSupport("rc-guest-act")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        let botID = BotID()
        let shot = try service.observe(botID: botID)
        XCTAssertEqual(shot.magic, BotComputerGuestService.pngMagicHex)
        XCTAssertEqual(shot.png.prefix(4), BotComputerGuestObserve.pngSignature)
        try service.act(botID: botID, steps: [
            BotComputerActStep(action: "click", x: 40, y: 80),
            BotComputerActStep(action: "type", text: "hello"),
        ])
        XCTAssertTrue(fake.execCalls >= 3)
        service.teardown(botID: botID)
    }

    func test_provisionRetriesUntilPNG() throws {
        let support = makeSupport("rc-guest-prov-retry")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        fake.execFailuresRemaining = 1
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 3,
            observeDelay: 0
        )
        let botID = BotID()
        let first = try service.provision(botID: botID)
        XCTAssertFalse(first.resumed)
        XCTAssertEqual(first.pngMagic, BotComputerGuestService.pngMagicHex)
        XCTAssertEqual(fake.execCalls, 2)
        let second = try service.provision(botID: botID)
        XCTAssertTrue(second.resumed)
        service.teardown(botID: botID)
        XCTAssertThrowsError(try fake.inspect(name: BotComputerGuestSpec.containerName(botID: botID)))
    }

    func test_liveProveReady_emitsPNGMagicAndLoopback() throws {
        // WHY: skeptic rejected a custom docker wait script. Studio's
        // shipped proveReady() must itself return PNG 89 50 4E 47 on
        // remotecode/computer:local bound to 127.0.0.1.
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 to run the shipped proveReady capture")
        }
        let docker = BotComputerDockerCLI()
        do {
            _ = try docker.info()
        } catch {
            throw XCTSkip("docker info unavailable: \(error)")
        }
        let support = makeSupport("rc-guest-live")
        defer { try? FileManager.default.removeItem(at: support) }
        let recipe = try XCTUnwrap(
            AppShellResourceBundle.computerGuestRecipeURL(),
            "bundled ComputerGuest recipe must exist so proveReady can build"
        )
        let service = BotComputerGuestService(
            appSupport: support,
            docker: docker,
            recipeContext: recipe,
            observeAttempts: 60,
            observeDelay: 0.5
        )
        let ready = service.proveReady()
        let magic = service.lastReady?.pngMagic ?? ""
        let host = service.lastReady?.screenURL.host ?? ""
        let image = BotComputerGuestSpec.imageTag
        print("PROVE_READY=\(ready ? 1 : 0)")
        print("PNG_MAGIC=\(magic)")
        print("HOST=\(host)")
        print("IMAGE=\(image)")
        print("REASON=\(service.lastReason)")
        XCTAssertTrue(ready, service.lastReason)
        XCTAssertEqual(magic, "89504e47")
        XCTAssertEqual(host, "127.0.0.1")
        XCTAssertEqual(image, "remotecode/computer:local")

        let botID = BotID()
        let shot = try service.observe(botID: botID)
        print("OBSERVE_PNG_MAGIC=\(shot.magic)")
        print("OBSERVE_HOST=127.0.0.1")
        XCTAssertEqual(shot.magic, "89504e47")
        try service.act(botID: botID, steps: [BotComputerActStep(action: "key", key: "Return")])
        print("ACT_OK=1")
        service.teardown(botID: botID)
    }

    func test_provisionStartsStoppedContainerInsteadOfRecreating() throws {
        // WHY: Stop then Send used to rm+create, wiping apt packages and the port.
        let support = makeSupport("rc-guest-restart")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        let botID = BotID()
        _ = try service.provision(botID: botID)
        let name = BotComputerGuestSpec.containerName(botID: botID)
        try service.stop(botID: botID)
        XCTAssertEqual(fake.stopped, [name])
        fake.created.removeAll()
        let ready = try service.provision(botID: botID)
        XCTAssertTrue(ready.resumed)
        XCTAssertTrue(fake.created.isEmpty)
        XCTAssertTrue(fake.started.contains(name))
        XCTAssertFalse(fake.removed.contains(name))
        service.teardown(botID: botID)
    }

    func test_execRunsAptAsRootAndOpenTerminalDetaches() throws {
        let support = makeSupport("rc-guest-exec")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            recipeContext: AppShellResourceBundle.computerGuestRecipeURL(),
            observeAttempts: 1,
            observeDelay: 0
        )
        let botID = BotID()
        _ = try service.exec(botID: botID, command: "apt-get install -y sl")
        XCTAssertEqual(fake.lastExec?.user, "0")
        XCTAssertEqual(Array(fake.lastExec?.command.prefix(2) ?? []), ["bash", "-lc"])
        try service.openTerminal(botID: botID)
        XCTAssertEqual(fake.lastExec?.detach, true)
        XCTAssertEqual(fake.lastExec?.command, BotComputerGuestSpec.terminalCommand())
        let rebuilt = try service.rebuild(botID: botID)
        XCTAssertEqual(rebuilt.screenURL.host, "127.0.0.1")
        XCTAssertTrue(fake.builds.contains(BotComputerGuestSpec.recipeURL(appSupport: support, botID: botID)))
        XCTAssertFalse(fake.renamed.isEmpty)
        service.teardown(botID: botID)
    }

    func test_prepareHomeMigratesCustomizedLegacyRecipeWithoutLosingIt() throws {
        // WHY: existing bots already have an editable computer/Dockerfile. Moving the
        // recipe to the guest-home root must preserve that per-bot customization.
        let support = makeSupport("rc-guest-recipe-migration")
        defer { try? FileManager.default.removeItem(at: support) }
        let botID = BotID()
        let home = BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: botID)
        let legacy = home.appendingPathComponent("computer", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let customized = "FROM debian:bookworm-slim\nRUN echo customized\n"
        try customized.write(
            to: legacy.appendingPathComponent("Dockerfile"),
            atomically: true,
            encoding: .utf8
        )

        let service = BotComputerGuestService(
            appSupport: support,
            docker: FakeDocker(),
            recipeContext: AppShellResourceBundle.computerGuestRecipeURL(),
            observeAttempts: 1,
            observeDelay: 0
        )
        try service.prepareHome(botID: botID)

        XCTAssertEqual(
            try String(contentsOf: home.appendingPathComponent("Dockerfile"), encoding: .utf8),
            customized,
            "migration must keep the bot's edited Dockerfile byte-for-byte"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacy.appendingPathComponent("Dockerfile").path),
            "the active Dockerfile must no longer appear under a misleading computer folder"
        )
        for name in ["start.sh", "embed.html", "launch-browser.sh"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: home.appendingPathComponent(name).path),
                "the root build context must keep every file referenced by Dockerfile"
            )
        }
    }

    private final class SleepCounter: @unchecked Sendable {
        var count = 0
    }

    private func makeSupport(_ prefix: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }
}
