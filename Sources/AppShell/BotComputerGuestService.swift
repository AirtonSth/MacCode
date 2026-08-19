import Foundation
import CoreModel
import Persistence

public struct BotComputerGuestReady: Equatable, Sendable {
    public var screenURL: URL
    public var pngHash: String
    public var pngMagic: String
    public var resumed: Bool
}

public final class BotComputerGuestService: @unchecked Sendable {
    public static let pngMagicHex = "89504e47"

    private let appSupport: URL
    private let docker: any BotComputerDockerClienting
    private let recipeContext: URL?
    private let observeAttempts: Int
    private let observeDelay: TimeInterval
    private let sleep: @Sendable (TimeInterval) -> Void
    public private(set) var lastReady: BotComputerGuestReady?
    public private(set) var lastReason: String = "Guest is proving the screen…"
    public var recipeContextURL: URL? { recipeContext }

    public init(
        appSupport: URL,
        docker: any BotComputerDockerClienting,
        recipeContext: URL? = nil,
        observeAttempts: Int = 60,
        observeDelay: TimeInterval = 0.5,
        sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.appSupport = appSupport
        self.docker = docker
        self.recipeContext = recipeContext
        self.observeAttempts = max(1, observeAttempts)
        self.observeDelay = max(0, observeDelay)
        self.sleep = sleep
    }

    public func proveReady() -> Bool {
        var probeName: String?
        var probeBotID: BotID?
        defer {
            if let probeName {
                try? docker.remove(name: probeName)
            }
            if let probeBotID {
                try? BotGuestHome.wipe(appSupport: appSupport, botID: probeBotID)
            }
        }
        do {
            _ = try docker.info()
            if try docker.imageExists(tag: BotComputerGuestSpec.imageTag) == false {
                guard let recipeContext else {
                    lastReady = nil
                    lastReason = "Docker image missing"
                    return false
                }
                try docker.build(context: recipeContext, tag: BotComputerGuestSpec.imageTag)
            }
            let name = "remotecode-probe-\(UUID().uuidString.lowercased())"
            probeName = name
            let botID = BotID()
            probeBotID = botID
            let home = try BotGuestHome.ensure(appSupport: appSupport, botID: botID)
            var options = try BotComputerGuestSpec.containerCreateOptions(
                botID: botID,
                guestHome: home.path,
                appSupport: appSupport
            )
            options.name = name
            _ = try docker.create(options: options)
            try docker.start(name: name)
            let png = try waitForPNG(name: name)
            let hash = try BotComputerGuestObserve.validatePNG(png)
            let inspect = try docker.inspect(name: name)
            let url = try BotComputerGuestSpec.screenURL(hostPort: inspect.hostPort, token: hash)
            try BotComputerGuestSpec.validateScreenURL(url)
            lastReady = BotComputerGuestReady(
                screenURL: url,
                pngHash: hash,
                pngMagic: Self.pngMagic(png),
                resumed: false
            )
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
            let png = try waitForPNG(name: name)
            let hash = try BotComputerGuestObserve.validatePNG(png)
            let url = try BotComputerGuestSpec.screenURL(hostPort: existing.hostPort, token: hash)
            try BotComputerGuestSpec.validateScreenURL(url)
            let ready = BotComputerGuestReady(
                screenURL: url,
                pngHash: hash,
                pngMagic: Self.pngMagic(png),
                resumed: true
            )
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
        let png = try waitForPNG(name: name)
        let hash = try BotComputerGuestObserve.validatePNG(png)
        let url = try BotComputerGuestSpec.screenURL(hostPort: inspect.hostPort, token: hash)
        try BotComputerGuestSpec.validateScreenURL(url)
        let ready = BotComputerGuestReady(
            screenURL: url,
            pngHash: hash,
            pngMagic: Self.pngMagic(png),
            resumed: false
        )
        lastReady = ready
        return ready
    }

    private func waitForPNG(name: String) throws -> Data {
        var lastError: Error = BotComputerGuestError.observeFailed
        for attempt in 0..<observeAttempts {
            do {
                let png = try docker.exec(name: name, command: ["import", "-window", "root", "png:-"])
                _ = try BotComputerGuestObserve.validatePNG(png)
                return png
            } catch {
                lastError = error
                if attempt + 1 < observeAttempts {
                    sleep(observeDelay)
                }
            }
        }
        throw lastError
    }

    public static func pngMagic(_ data: Data) -> String {
        data.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    public func teardown(botID: BotID) {
        try? docker.remove(name: BotComputerGuestSpec.containerName(botID: botID))
        try? BotGuestHome.wipe(appSupport: appSupport, botID: botID)
    }
}
