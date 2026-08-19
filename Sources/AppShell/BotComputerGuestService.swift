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
            try? docker.removeMatching(namePrefix: "remotecode-probe-")
            try ensureCurrentImage()
            let name = "remotecode-probe-\(UUID().uuidString.lowercased())"
            probeName = name
            let botID = BotID()
            probeBotID = botID
            let home = try BotGuestHome.ensure(appSupport: appSupport, botID: botID)
            try? docker.ensureNetwork(name: BotComputerGuestSpec.networkName(botID: botID))
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
            if lastReason == "Guest is proving the screen…" {
                lastReason = String(describing: error)
            }
            return false
        }
    }

    public func provision(botID: BotID) throws -> BotComputerGuestReady {
        let home = try BotGuestHome.ensure(appSupport: appSupport, botID: botID)
        try seedRecipe(botID: botID)
        try ensureCurrentImage()
        let name = BotComputerGuestSpec.containerName(botID: botID)
        try docker.ensureNetwork(name: BotComputerGuestSpec.networkName(botID: botID))
        let image = try resolvedImage(botID: botID)
        if let existing = try? docker.inspect(name: name) {
            if imageMatches(existing, tag: image) {
                if existing.running == false {
                    try docker.start(name: name)
                }
                return try readyState(name: name, resumed: true)
            }
            try? docker.remove(name: name)
        }
        let options = try BotComputerGuestSpec.containerCreateOptions(
            botID: botID,
            guestHome: home.path,
            appSupport: appSupport,
            image: image
        )
        _ = try docker.create(options: options)
        try docker.start(name: name)
        return try readyState(name: name, resumed: false)
    }

    public func stop(botID: BotID) throws {
        try docker.stop(name: BotComputerGuestSpec.containerName(botID: botID))
    }

    public func exec(botID: BotID, command: String) throws -> Data {
        let trimmed = try BotComputerGuestSpec.assertExecCommand(command)
        _ = try provision(botID: botID)
        let name = BotComputerGuestSpec.containerName(botID: botID)
        let user = BotComputerGuestSpec.execUsesRoot(trimmed) ? "0" : nil
        let data = try docker.exec(
            name: name,
            command: ["bash", "-lc", trimmed],
            user: user,
            detach: false
        )
        if data.count <= 32_768 { return data }
        return data.prefix(32_768)
    }

    public func openTerminal(botID: BotID) throws {
        _ = try provision(botID: botID)
        let name = BotComputerGuestSpec.containerName(botID: botID)
        _ = try docker.exec(
            name: name,
            command: BotComputerGuestSpec.terminalCommand(),
            user: nil,
            detach: true
        )
    }

    public func rebuild(botID: BotID) throws -> BotComputerGuestReady {
        try seedRecipe(botID: botID)
        let recipe = BotComputerGuestSpec.recipeURL(appSupport: appSupport, botID: botID)
        let tag = BotComputerGuestSpec.botImageTag(botID: botID)
        try docker.build(context: recipe, tag: tag)
        let home = try BotGuestHome.ensure(appSupport: appSupport, botID: botID)
        try docker.ensureNetwork(name: BotComputerGuestSpec.networkName(botID: botID))
        let canonical = BotComputerGuestSpec.containerName(botID: botID)
        let next = BotComputerGuestSpec.nextContainerName(botID: botID)
        try? docker.remove(name: next)
        let options = try BotComputerGuestSpec.containerCreateOptions(
            botID: botID,
            guestHome: home.path,
            appSupport: appSupport,
            image: tag,
            name: next
        )
        _ = try docker.create(options: options)
        do {
            try docker.start(name: next)
            _ = try readyState(name: next, resumed: false)
            try? docker.stop(name: canonical)
            try? docker.remove(name: canonical)
            try docker.rename(from: next, to: canonical)
            let renamed = try readyState(name: canonical, resumed: false)
            lastReady = renamed
            return renamed
        } catch {
            try? docker.remove(name: next)
            throw error
        }
    }

    public func apply(_ action: BotComputerPendingAction) throws -> [String: Any] {
        guard let uuid = UUID(uuidString: action.botID) else {
            throw BotComputerError.invalid("Invalid bot id.")
        }
        let botID = BotID(uuid)
        switch action.kind {
        case BotComputerCatalog.observe:
            let shot = try observe(botID: botID)
            return [
                "png_magic": shot.magic,
                "png_hash": shot.hash,
                "png_base64": shot.png.base64EncodedString(),
                "host": "127.0.0.1",
                "image": BotComputerGuestSpec.imageTag,
            ]
        case BotComputerCatalog.act:
            try act(botID: botID, steps: action.steps)
            return ["ok": true, "steps": action.steps.count]
        case BotComputerCatalog.exec:
            let output = try exec(botID: botID, command: action.command)
            return [
                "ok": true,
                "output": String(data: output, encoding: .utf8) ?? "",
            ]
        case BotComputerCatalog.rebuild:
            let ready = try rebuild(botID: botID)
            return [
                "ok": true,
                "host": ready.screenURL.host ?? "127.0.0.1",
                "image": BotComputerGuestSpec.botImageTag(botID: botID),
            ]
        default:
            throw BotComputerError.invalid("unknown tool: \(action.kind)")
        }
    }

    private func waitForPNG(name: String) throws -> Data {
        var lastError: Error = BotComputerGuestError.observeFailed
        for attempt in 0..<observeAttempts {
            do {
                let png = try docker.exec(
                    name: name,
                    command: ["env", "DISPLAY=:1", "import", "-window", "root", "png:-"],
                    user: nil,
                    detach: false
                )
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

    private func readyState(name: String, resumed: Bool) throws -> BotComputerGuestReady {
        let png = try waitForPNG(name: name)
        let hash = try BotComputerGuestObserve.validatePNG(png)
        let inspect = try docker.inspect(name: name)
        let url = try BotComputerGuestSpec.screenURL(hostPort: inspect.hostPort, token: hash)
        try BotComputerGuestSpec.validateScreenURL(url)
        let ready = BotComputerGuestReady(
            screenURL: url,
            pngHash: hash,
            pngMagic: Self.pngMagic(png),
            resumed: resumed
        )
        lastReady = ready
        lastReason = ""
        return ready
    }

    private func resolvedImage(botID: BotID) throws -> String {
        let tag = BotComputerGuestSpec.botImageTag(botID: botID)
        if try docker.imageExists(tag: tag) { return tag }
        return BotComputerGuestSpec.imageTag
    }

    private func ensureCurrentImage() throws {
        let tag = BotComputerGuestSpec.imageTag
        let label = (try? docker.imageLabel(tag: tag, key: BotComputerGuestSpec.recipeLabelKey)) ?? ""
        if try docker.imageExists(tag: tag), label == BotComputerGuestSpec.recipeRevision {
            return
        }
        guard let recipeContext else {
            if try docker.imageExists(tag: tag) { return }
            lastReason = "Docker image missing"
            throw BotComputerGuestError.dockerUnavailable
        }
        try docker.build(context: recipeContext, tag: tag)
    }

    private func imageMatches(_ existing: BotComputerContainerInspect, tag: String) -> Bool {
        let want = (try? docker.imageID(tag: tag)) ?? ""
        if want.isEmpty { return true }
        return existing.imageID == want
            || existing.imageID.hasSuffix(want)
            || want.hasSuffix(existing.imageID)
    }

    private func seedRecipe(botID: BotID) throws {
        let dest = BotComputerGuestSpec.recipeURL(appSupport: appSupport, botID: botID)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        guard let recipeContext else { return }
        let names = ["Dockerfile", "start.sh", "embed.html", "launch-browser.sh"]
        for name in names {
            let target = dest.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target.path) { continue }
            let source = recipeContext.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: target)
            }
        }
    }

    public static func pngMagic(_ data: Data) -> String {
        data.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    public func observe(botID: BotID) throws -> (png: Data, hash: String, magic: String) {
        _ = try provision(botID: botID)
        let name = BotComputerGuestSpec.containerName(botID: botID)
        let png = try waitForPNG(name: name)
        let hash = try BotComputerGuestObserve.validatePNG(png)
        return (png, hash, Self.pngMagic(png))
    }

    public func act(botID: BotID, steps: [BotComputerActStep]) throws {
        try BotComputerGuestObserve.assertActStepCount(steps.count)
        _ = try provision(botID: botID)
        let name = BotComputerGuestSpec.containerName(botID: botID)
        for step in steps {
            _ = try docker.exec(
                name: name,
                command: try step.execCommand(),
                user: nil,
                detach: false
            )
        }
    }

    public func teardown(botID: BotID) {
        try? docker.remove(name: BotComputerGuestSpec.containerName(botID: botID))
        try? BotGuestHome.wipe(appSupport: appSupport, botID: botID)
    }
}
