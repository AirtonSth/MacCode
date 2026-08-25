import Foundation
import CryptoKit
import CoreModel
import Persistence

public struct BotComputerGuestReady: Equatable, Sendable {
    public var screenURL: URL
    public var pngHash: String
    public var pngMagic: String
    public var resumed: Bool
}

public enum BotComputerGuestServiceError: Error, Equatable, Sendable, CustomStringConvertible {
    case screenshotTooLarge(actualBytes: Int, maximumBytes: Int)
    case screenshotResultTooLarge(actualBytes: Int, maximumBytes: Int)

    public var description: String {
        switch self {
        case .screenshotTooLarge(let actualBytes, let maximumBytes):
            return "Guest screenshot is too large: \(actualBytes) bytes (maximum \(maximumBytes))."
        case .screenshotResultTooLarge(let actualBytes, let maximumBytes):
            return "Guest screenshot result is too large: \(actualBytes) bytes (maximum \(maximumBytes))."
        }
    }
}

public final class BotComputerGuestService: @unchecked Sendable {
    public static let pngMagicHex = "89504e47"
    public static let maxScreenshotBytes = 8 * 1_024 * 1_024
    public static let maxScreenshotBase64Bytes = ((maxScreenshotBytes + 2) / 3) * 4
    private static let viewerTokenLock = NSLock()
    private static let legacyUnauthenticatedStartScriptSHA256 =
        "fc19d6b61e02c4ee713dde41886f4dfbae6d8631ce990dbd045f36eced478d8e"

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
            let viewerToken = try viewerToken(botID: botID)
            var options = try BotComputerGuestSpec.containerCreateOptions(
                botID: botID,
                guestHome: home.path,
                appSupport: appSupport,
                viewerToken: viewerToken
            )
            options.name = name
            options.network = nil
            _ = try docker.create(options: options)
            try docker.start(name: name)
            let png = try waitForPNG(name: name)
            let hash = try BotComputerGuestObserve.validatePNG(png)
            let inspect = try docker.inspect(name: name)
            let url = try BotComputerGuestSpec.screenURL(hostPort: inspect.hostPort, token: viewerToken)
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
        let network = try availableNetwork(botID: botID)
        let image = try resolvedImage(botID: botID)
        if let existing = try? docker.inspect(name: name) {
            if imageMatches(existing, tag: image), networkMatches(existing, network: network) {
                if existing.running == false {
                    try docker.start(name: name)
                }
                return try readyState(name: name, botID: botID, resumed: true)
            }
            try? docker.remove(name: name)
        }
        let viewerToken = try viewerToken(botID: botID)
        var options = try BotComputerGuestSpec.containerCreateOptions(
            botID: botID,
            guestHome: home.path,
            appSupport: appSupport,
            viewerToken: viewerToken,
            image: image
        )
        options.network = network
        _ = try docker.create(options: options)
        try docker.start(name: name)
        return try readyState(name: name, botID: botID, resumed: false)
    }

    /// Makes the bot's editable build recipe visible without starting Docker.
    public func prepareHome(botID: BotID) throws {
        _ = try BotGuestHome.ensure(appSupport: appSupport, botID: botID)
        try seedRecipe(botID: botID)
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
        let network = try availableNetwork(botID: botID)
        let canonical = BotComputerGuestSpec.containerName(botID: botID)
        let next = BotComputerGuestSpec.nextContainerName(botID: botID)
        try? docker.remove(name: next)
        let viewerToken = try viewerToken(botID: botID)
        var options = try BotComputerGuestSpec.containerCreateOptions(
            botID: botID,
            guestHome: home.path,
            appSupport: appSupport,
            viewerToken: viewerToken,
            image: tag,
            name: next
        )
        options.network = network
        _ = try docker.create(options: options)
        do {
            try docker.start(name: next)
            _ = try readyState(name: next, botID: botID, resumed: false)
            try? docker.stop(name: canonical)
            try? docker.remove(name: canonical)
            try docker.rename(from: next, to: canonical)
            let renamed = try readyState(name: canonical, botID: botID, resumed: false)
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
            let base64 = shot.png.base64EncodedString()
            guard base64.utf8.count <= Self.maxScreenshotBase64Bytes else {
                throw BotComputerGuestServiceError.screenshotResultTooLarge(
                    actualBytes: base64.utf8.count,
                    maximumBytes: Self.maxScreenshotBase64Bytes
                )
            }
            return [
                "png_magic": shot.magic,
                "png_hash": shot.hash,
                "png_base64": base64,
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
                guard png.count <= Self.maxScreenshotBytes else {
                    throw BotComputerGuestServiceError.screenshotTooLarge(
                        actualBytes: png.count,
                        maximumBytes: Self.maxScreenshotBytes
                    )
                }
                _ = try BotComputerGuestObserve.validatePNG(png)
                return png
            } catch let error as BotComputerGuestServiceError {
                // An oversized frame is deterministic for the current guest
                // state. Retrying it 60 times only repeats the allocation and
                // keeps the Docker worker busy without changing the outcome.
                if case .screenshotTooLarge = error {
                    throw error
                }
                lastError = error
            } catch let error as BotComputerDockerError {
                // The bounded subprocess reader has already terminated this
                // exact-output command; repeating it only recreates the same
                // oversized frame and burns the retry window.
                if error == .outputTooLarge {
                    throw error
                }
                lastError = error
            } catch {
                lastError = error
                if attempt + 1 < observeAttempts {
                    sleep(observeDelay)
                }
            }
        }
        throw lastError
    }

    private func readyState(name: String, botID: BotID, resumed: Bool) throws -> BotComputerGuestReady {
        let png = try waitForPNG(name: name)
        let hash = try BotComputerGuestObserve.validatePNG(png)
        let inspect = try docker.inspect(name: name)
        let url = try BotComputerGuestSpec.screenURL(
            hostPort: inspect.hostPort,
            token: try viewerToken(botID: botID)
        )
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
        if try docker.imageExists(tag: tag),
           try docker.imageLabel(tag: tag, key: BotComputerGuestSpec.recipeLabelKey)
            == BotComputerGuestSpec.recipeRevision {
            return tag
        }
        return BotComputerGuestSpec.imageTag
    }

    private func availableNetwork(botID: BotID) throws -> String {
        let name = BotComputerGuestSpec.networkName(botID: botID)
        try docker.ensureNetwork(name: name)
        return name
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

    private func networkMatches(_ existing: BotComputerContainerInspect, network: String) -> Bool {
        existing.networkNames.isEmpty || existing.networkNames == [network]
    }

    private func seedRecipe(botID: BotID) throws {
        let dest = BotComputerGuestSpec.recipeURL(appSupport: appSupport, botID: botID)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
        let names = ["Dockerfile", "start.sh", "embed.html", "launch-browser.sh"]
        let legacy = dest.appendingPathComponent("computer", isDirectory: true)
        for name in names {
            let target = dest.appendingPathComponent(name)
            if fileManager.fileExists(atPath: target.path) {
                if name == "start.sh", let recipeContext {
                    try refreshLegacyStartScriptIfNeeded(
                        at: target,
                        from: recipeContext.appendingPathComponent(name)
                    )
                }
                continue
            }
            let legacySource = legacy.appendingPathComponent(name)
            if fileManager.fileExists(atPath: legacySource.path) {
                try fileManager.moveItem(at: legacySource, to: target)
                continue
            }
            guard let recipeContext else { continue }
            let source = recipeContext.appendingPathComponent(name)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: target)
            }
        }
        if fileManager.fileExists(atPath: legacy.path),
           (try fileManager.contentsOfDirectory(atPath: legacy.path)).isEmpty {
            try fileManager.removeItem(at: legacy)
        }
    }

    private func viewerToken(botID: BotID) throws -> String {
        Self.viewerTokenLock.lock()
        defer { Self.viewerTokenLock.unlock() }
        let tokenURL = BotComputerGuestSpec.viewerTokenURL(appSupport: appSupport, botID: botID)
        if let data = try? Data(contentsOf: tokenURL, options: .mappedIfSafe), let raw = String(data: data, encoding: .utf8) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.range(of: #"^[a-zA-Z0-9-]{32,128}$"#, options: .regularExpression) != nil {
                return value
            }
        }
        let value = UUID().uuidString.lowercased()
        try Data((value + "\n").utf8).write(to: tokenURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        return value
    }

    // PERF: nibble table avoids String(format:) per byte; same lowercase hex.
    private static let hexAlphabet: [UInt8] = Array("0123456789abcdef".utf8)
    private static func hexString<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(digest.underestimatedCount * 2)
        for b in digest {
            out.append(hexAlphabet[Int(b >> 4)])
            out.append(hexAlphabet[Int(b & 0x0F)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    private func refreshLegacyStartScriptIfNeeded(at target: URL, from source: URL) throws {
        let existing = try Data(contentsOf: target, options: .mappedIfSafe)
        let digest = Self.hexString(SHA256.hash(data: existing))
        guard digest == Self.legacyUnauthenticatedStartScriptSHA256,
              FileManager.default.fileExists(atPath: source.path)
        else { return }
        try Data(contentsOf: source, options: .mappedIfSafe).write(to: target, options: .atomic)
    }

    public static func pngMagic(_ data: Data) -> String {
        Self.hexString(data.prefix(4))
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
        try? removeGuestRuntime(botID: botID)
        try? BotGuestHome.wipe(appSupport: appSupport, botID: botID)
    }

    public func removeGuestRuntime(botID: BotID) throws {
        var firstError: Error?
        do {
            try docker.remove(name: BotComputerGuestSpec.containerName(botID: botID))
        } catch {
            firstError = error
        }
        do {
            try docker.removeNetwork(name: BotComputerGuestSpec.networkName(botID: botID))
        } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }
}
