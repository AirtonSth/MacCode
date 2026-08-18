import Foundation
import CoreModel
import Persistence

public struct BotComputerGuestReady: Equatable, Sendable {
    public var screenURL: URL
    public var pngHash: String
    public var resumed: Bool
}

public final class BotComputerGuestService: @unchecked Sendable {
    private let appSupport: URL
    private let docker: any BotComputerDockerClienting
    private let recipeContext: URL?
    public private(set) var lastReady: BotComputerGuestReady?
    public private(set) var lastReason: String = "Guest is proving the screen…"

    public init(
        appSupport: URL,
        docker: any BotComputerDockerClienting,
        recipeContext: URL? = nil
    ) {
        self.appSupport = appSupport
        self.docker = docker
        self.recipeContext = recipeContext
    }

    public func proveReady() -> Bool {
        do {
            _ = try docker.info()
            if try docker.imageExists(tag: BotComputerGuestSpec.imageTag) == false {
                guard let recipeContext else {
                    lastReason = "Docker image missing"
                    return false
                }
                try docker.build(context: recipeContext, tag: BotComputerGuestSpec.imageTag)
            }
            let probeName = "remotecode-probe-\(UUID().uuidString.lowercased())"
            let support = appSupport
            let botID = BotID()
            let home = try BotGuestHome.ensure(appSupport: support, botID: botID)
            let options = try BotComputerGuestSpec.containerCreateOptions(
                botID: botID,
                guestHome: home.path,
                appSupport: support
            )
            var probe = options
            probe.name = probeName
            _ = try docker.create(options: probe)
            try docker.start(name: probeName)
            let png = try docker.exec(name: probeName, command: ["import", "-window", "root", "png:-"])
            let hash = try BotComputerGuestObserve.validatePNG(png)
            let inspect = try docker.inspect(name: probeName)
            let url = try BotComputerGuestSpec.screenURL(hostPort: inspect.hostPort, token: hash)
            try BotComputerGuestSpec.validateScreenURL(url)
            try docker.remove(name: probeName)
            lastReady = BotComputerGuestReady(screenURL: url, pngHash: hash, resumed: false)
            lastReason = ""
            return true
        } catch {
            lastReady = nil
            lastReason = String(describing: error)
            return false
        }
    }

    public func provision(botID: BotID) throws -> BotComputerGuestReady {
        let home = try BotGuestHome.ensure(appSupport: appSupport, botID: botID)
        let name = BotComputerGuestSpec.containerName(botID: botID)
        if let existing = try? docker.inspect(name: name), existing.running {
            let png = try docker.exec(name: name, command: ["import", "-window", "root", "png:-"])
            let hash = try BotComputerGuestObserve.validatePNG(png)
            let url = try BotComputerGuestSpec.screenURL(hostPort: existing.hostPort, token: hash)
            try BotComputerGuestSpec.validateScreenURL(url)
            let ready = BotComputerGuestReady(screenURL: url, pngHash: hash, resumed: true)
            lastReady = ready
            return ready
        }
        try? docker.remove(name: name)
        let options = try BotComputerGuestSpec.containerCreateOptions(
            botID: botID,
            guestHome: home.path,
            appSupport: appSupport
        )
        _ = try docker.create(options: options)
        try docker.start(name: name)
        let inspect = try docker.inspect(name: name)
        let png = try docker.exec(name: name, command: ["import", "-window", "root", "png:-"])
        let hash = try BotComputerGuestObserve.validatePNG(png)
        let url = try BotComputerGuestSpec.screenURL(hostPort: inspect.hostPort, token: hash)
        try BotComputerGuestSpec.validateScreenURL(url)
        let ready = BotComputerGuestReady(screenURL: url, pngHash: hash, resumed: false)
        lastReady = ready
        return ready
    }

    public func teardown(botID: BotID) {
        try? docker.remove(name: BotComputerGuestSpec.containerName(botID: botID))
        try? BotGuestHome.wipe(appSupport: appSupport, botID: botID)
    }
}
