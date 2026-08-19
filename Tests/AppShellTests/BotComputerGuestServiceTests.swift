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
    var builds: [URL] = []
    var execCalls = 0
    var execFailuresRemaining = 0

    func info() throws -> String { infoText }
    func imageExists(tag: String) throws -> Bool { images.contains(tag) }
    func build(context: URL, tag: String) throws {
        builds.append(context)
        images.insert(tag)
    }
    func create(options: BotComputerContainerCreateOptions) throws -> String {
        created.append(options.name)
        containers[options.name] = BotComputerContainerInspect(running: false, imageID: "img", hostPort: 49152)
        return options.name
    }
    func start(name: String) throws {
        containers[name] = BotComputerContainerInspect(running: true, imageID: "img", hostPort: 49152)
    }
    func inspect(name: String) throws -> BotComputerContainerInspect {
        guard let value = containers[name] else { throw BotComputerGuestError.notReady }
        return value
    }
    func exec(name: String, command: [String]) throws -> Data {
        execCalls += 1
        if execFailuresRemaining > 0 {
            execFailuresRemaining -= 1
            throw BotComputerGuestError.observeFailed
        }
        return png
    }
    func remove(name: String) throws {
        removed.append(name)
        containers[name] = nil
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
    }

    private final class SleepCounter: @unchecked Sendable {
        var count = 0
    }

    private func makeSupport(_ prefix: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }
}
