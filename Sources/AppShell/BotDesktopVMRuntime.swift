import Foundation
import CoreModel
import Persistence
#if canImport(Virtualization)
import Virtualization
#endif

public protocol BotDesktopVirtualizationProbe: Sendable {
    var isSupported: Bool { get }
}

public struct SystemBotDesktopVirtualizationProbe: BotDesktopVirtualizationProbe {
    public init() {}

    public var isSupported: Bool {
        #if canImport(Virtualization)
        VZVirtualMachine.isSupported
        #else
        false
        #endif
    }
}

public struct BotDesktopVMRuntime {
    private let store: BotDesktopVMStore
    private let probe: any BotDesktopVirtualizationProbe
    private let fileManager: FileManager

    public init(
        store: BotDesktopVMStore,
        probe: any BotDesktopVirtualizationProbe = SystemBotDesktopVirtualizationProbe(),
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.probe = probe
        self.fileManager = fileManager
    }

    public func identity(botID: BotID) throws -> BotDesktopVMIdentity? {
        try store.identity(botID: botID)
    }

    @discardableResult
    public func start(botID: BotID, now: Date = Date()) throws -> BotDesktopVMIdentity {
        var identity = try store.ensure(botID: botID, now: now)
        identity.virtualizationSupported = probe.isSupported
        identity.updatedAt = now
        if !identity.virtualizationSupported {
            identity.state = .stopped
            identity.lastError = BotDesktopVMIdentity.virtualizationUnsupportedCode
        } else if !hasGuestImage(at: identity.bundlePath) {
            identity.state = .stopped
            identity.lastError = BotDesktopVMIdentity.noGuestImageCode
        } else {
            identity.state = .stopped
            identity.lastError = BotDesktopVMIdentity.bootNotShippedCode
        }
        try store.save(identity)
        return identity
    }

    @discardableResult
    public func stop(botID: BotID, now: Date = Date()) throws -> BotDesktopVMIdentity {
        var identity = try store.ensure(botID: botID, now: now)
        identity.state = .stopped
        identity.virtualizationSupported = probe.isSupported
        identity.updatedAt = now
        try store.save(identity)
        return identity
    }

    private func hasGuestImage(at bundlePath: String) -> Bool {
        let bundle = URL(fileURLWithPath: bundlePath, isDirectory: true)
        let names = ["Disk.img", "Restore.ipsw", "guest.img"]
        return names.contains { fileManager.fileExists(atPath: bundle.appendingPathComponent($0).path) }
    }
}
