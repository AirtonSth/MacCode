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

    func info() throws -> String { infoText }
    func imageExists(tag: String) throws -> Bool { images.contains(tag) }
    func build(context: URL, tag: String) throws { images.insert(tag) }
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
    func exec(name: String, command: [String]) throws -> Data { png }
    func remove(name: String) throws { containers[name] = nil }
}

@MainActor
final class BotComputerGuestServiceTests: XCTestCase {
    func test_proveReadyRequiresPNGAndLoopback() throws {
        // WHY: Studio must not enable Docker desktop on a JPEG or a LAN bind.
        let support = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-guest-svc-\(UUID().uuidString)", isDirectory: true)
        let fake = FakeDocker()
        let service = BotComputerGuestService(appSupport: support, docker: fake)
        XCTAssertTrue(service.proveReady())
        XCTAssertEqual(service.lastReady?.screenURL.host, "127.0.0.1")
        fake.png = Data("jpeg".utf8)
        XCTAssertFalse(service.proveReady())
        try? FileManager.default.removeItem(at: support)
    }

    func test_provisionResumesRunningContainer() throws {
        let support = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-guest-prov-\(UUID().uuidString)", isDirectory: true)
        let fake = FakeDocker()
        let service = BotComputerGuestService(appSupport: support, docker: fake)
        let botID = BotID()
        let first = try service.provision(botID: botID)
        XCTAssertFalse(first.resumed)
        let second = try service.provision(botID: botID)
        XCTAssertTrue(second.resumed)
        service.teardown(botID: botID)
        XCTAssertThrowsError(try fake.inspect(name: BotComputerGuestSpec.containerName(botID: botID)))
        try? FileManager.default.removeItem(at: support)
    }
}
