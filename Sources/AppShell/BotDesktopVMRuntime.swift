import Foundation
import CoreModel
import Persistence
#if canImport(Virtualization)
import Virtualization
#endif

public struct BotDesktopVMBootAttempt: Equatable, Sendable {
    public var didStart: Bool
    public var failure: String?

    public init(didStart: Bool, failure: String? = nil) {
        self.didStart = didStart
        self.failure = failure
    }
}

public protocol BotDesktopVirtualizationProbe: AnyObject {
    var isSupported: Bool { get }
    func boot(diskImage: URL) -> BotDesktopVMBootAttempt
    func halt()
}

public final class SystemBotDesktopVirtualizationProbe: BotDesktopVirtualizationProbe {
    #if canImport(Virtualization)
    private var machine: VZVirtualMachine?
    #endif

    public init() {}

    public var isSupported: Bool {
        #if canImport(Virtualization)
        VZVirtualMachine.isSupported
        #else
        false
        #endif
    }

    public func boot(diskImage: URL) -> BotDesktopVMBootAttempt {
        #if canImport(Virtualization)
        halt()
        do {
            let attachment = try VZDiskImageStorageDeviceAttachment(url: diskImage, readOnly: false)
            let config = VZVirtualMachineConfiguration()
            config.cpuCount = max(1, min(2, ProcessInfo.processInfo.processorCount))
            config.memorySize = 512 * 1024 * 1024
            config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
            config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
            config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
            // EFI firmware is a real guest start path. A macOS IPSW restore
            // image is leftover; do not attach a network device (no isolation claim).
            let bootLoader = VZEFIBootLoader()
            bootLoader.variableStore = try efiVariableStore(nextTo: diskImage)
            config.bootLoader = bootLoader
            try config.validate()
            let vm = VZVirtualMachine(configuration: config)
            let box = StartBox()
            vm.start { result in
                if case .failure(let error) = result {
                    box.error = error
                }
                box.signal()
            }
            _ = box.wait(seconds: 8)
            if let error = box.error {
                return BotDesktopVMBootAttempt(didStart: false, failure: error.localizedDescription)
            }
            if vm.state == .running {
                machine = vm
                return BotDesktopVMBootAttempt(didStart: true)
            }
            return BotDesktopVMBootAttempt(
                didStart: false,
                failure: "Virtual machine did not reach running (state \(vm.state.rawValue))."
            )
        } catch {
            return BotDesktopVMBootAttempt(didStart: false, failure: error.localizedDescription)
        }
        #else
        return BotDesktopVMBootAttempt(didStart: false, failure: "Virtualization is not available.")
        #endif
    }

    private func efiVariableStore(nextTo diskImage: URL) throws -> VZEFIVariableStore {
        let url = diskImage.deletingLastPathComponent().appendingPathComponent("efi-nvram.bin")
        if FileManager.default.fileExists(atPath: url.path) {
            return VZEFIVariableStore(url: url)
        }
        return try VZEFIVariableStore(creatingVariableStoreAt: url)
    }

    public func halt() {
        #if canImport(Virtualization)
        guard let machine else { return }
        if machine.canStop {
            let box = StartBox()
            machine.stop { _ in box.signal() }
            _ = box.wait(seconds: 4)
        }
        self.machine = nil
        #endif
    }
}

private final class StartBox: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    var error: Error?

    func signal() { semaphore.signal() }

    func wait(seconds: TimeInterval) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + seconds)
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
        identity.lastErrorDetail = nil
        if !identity.virtualizationSupported {
            identity.state = .stopped
            identity.lastError = BotDesktopVMIdentity.virtualizationUnsupportedCode
        } else if let disk = guestImageURL(at: identity.bundlePath) {
            let attempt = probe.boot(diskImage: disk)
            if attempt.didStart {
                identity.state = .running
                identity.lastError = nil
            } else {
                identity.state = .failed
                identity.lastError = BotDesktopVMIdentity.bootFailedCode
                identity.lastErrorDetail = attempt.failure
            }
        } else {
            identity.state = .stopped
            identity.lastError = BotDesktopVMIdentity.noGuestImageCode
        }
        try store.save(identity)
        return identity
    }

    @discardableResult
    public func stop(botID: BotID, now: Date = Date()) throws -> BotDesktopVMIdentity {
        probe.halt()
        var identity = try store.ensure(botID: botID, now: now)
        identity.state = .stopped
        identity.virtualizationSupported = probe.isSupported
        identity.updatedAt = now
        try store.save(identity)
        return identity
    }

    private func guestImageURL(at bundlePath: String) -> URL? {
        let bundle = URL(fileURLWithPath: bundlePath, isDirectory: true)
        let names = ["Disk.img", "Restore.ipsw", "guest.img"]
        return names
            .map { bundle.appendingPathComponent($0) }
            .first { fileManager.fileExists(atPath: $0.path) }
    }
}
