import Foundation
import XCTest
import AgentRuntime
import CoreModel
import Persistence
import SocketServer
@testable import AppShell

private final class BlockingImageDocker: BotComputerDockerClienting, @unchecked Sendable {
    private let docker = BotComputerDockerCLI()
    private let entered: DispatchSemaphore
    private let release: DispatchSemaphore

    init(entered: DispatchSemaphore, release: DispatchSemaphore) {
        self.entered = entered
        self.release = release
    }

    private let blockLock = NSLock()
    private var didBlock = false
    func info() throws -> String { try docker.info() }
    func imageExists(tag: String) throws -> Bool {
        let shouldBlock = blockLock.withLock {
            if didBlock { return false }
            didBlock = true
            return true
        }
        if shouldBlock {
            entered.signal()
            guard release.wait(timeout: .now() + 15) == .success else {
                throw NSError(domain: "BotContextGatewayConcurrencyProbe", code: 1)
            }
        }
        return try docker.imageExists(tag: tag)
    }
    func imageLabel(tag: String, key: String) throws -> String { try docker.imageLabel(tag: tag, key: key) }
    func imageID(tag: String) throws -> String { try docker.imageID(tag: tag) }
    func imageStates(tags: [String]) throws -> [String: BotComputerImageState] { try docker.imageStates(tags: tags) }
    func build(context: URL, tag: String) throws { try docker.build(context: context, tag: tag) }
    func create(options: BotComputerContainerCreateOptions) throws -> String { try docker.create(options: options) }
    func start(name: String) throws { try docker.start(name: name) }
    func stop(name: String) throws { try docker.stop(name: name) }
    func inspect(name: String) throws -> BotComputerContainerInspect { try docker.inspect(name: name) }
    func containerExists(name: String) throws -> Bool { try docker.containerExists(name: name) }
    func exec(name: String, command: [String], user: String?, detach: Bool, workdir: String?, environment: [String: String]) throws -> Data {
        try docker.exec(name: name, command: command, user: user, detach: detach, workdir: workdir, environment: environment)
    }
    func rename(from: String, to: String) throws { try docker.rename(from: from, to: to) }
    func ensureNetwork(name: String) throws { try docker.ensureNetwork(name: name) }
    func removeNetwork(name: String) throws { try docker.removeNetwork(name: name) }
    func networkExists(name: String) throws -> Bool { try docker.networkExists(name: name) }
    func remove(name: String) throws { try docker.remove(name: name) }
    func removeMatching(namePrefix: String) throws { try docker.removeMatching(namePrefix: namePrefix) }
    func top(name: String) throws -> String { try docker.top(name: name) }
}

func assertContextCleanupDoesNotWaitForOtherPreparation(
    preparedA: BotContextGuestResources,
    requestB: AgentRunRequest,
    hostID: String,
    store: BotStore,
    threadRepo: AgentThreadRepository,
    appSupport: URL,
    secretStore: any BotSecretStore
) throws {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let service = BotComputerGuestService(appSupport: appSupport, docker: BlockingImageDocker(entered: entered, release: release), recipeContext: nil)
    let stateLock = NSLock()
    var resultB: Result<BotContextGuestResources, Error>?
    let prepareDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let result = Result {
            try BotContextGuestResources.prepare(request: requestB, hostID: hostID, store: store, threadRepo: threadRepo, service: service, appSupport: appSupport, workspace: nil, registeredWorkspaces: [], secretStore: secretStore)
        }
        stateLock.lock()
        resultB = result
        stateLock.unlock()
        prepareDone.signal()
    }
    guard entered.wait(timeout: .now() + 5) == .success else {
        XCTFail("B preparation did not reach Docker image lookup within 5 seconds")
        return
    }
    let finishDone = DispatchSemaphore(value: 0)
    var finishError: Error?
    DispatchQueue.global().async {
        do { try preparedA.finish() } catch { finishError = error }
        finishDone.signal()
    }
    if finishDone.wait(timeout: .now() + 2) != .success {
        XCTFail("A cleanup waited for B preparation")
    } else if let finishError {
        XCTFail("A cleanup failed: \(finishError)")
    }
    release.signal()
    guard prepareDone.wait(timeout: .now() + 30) == .success else {
        XCTFail("B preparation did not finish within 30 seconds")
        return
    }
    stateLock.lock()
    let result = resultB
    stateLock.unlock()
    switch result {
    case .success(let preparedB):
        do { try preparedB.finish() } catch { XCTFail("B cleanup failed: \(error)") }
    case .failure(let error):
        XCTFail("B preparation failed: \(error)")
    case .none:
        XCTFail("B preparation returned no result")
    }
}
