import Foundation
import CoreModel
import Persistence
#if canImport(Virtualization)
import Virtualization
#endif

public struct BotDesktopVMBootAttempt: Equatable, Sendable {
    public var didStart: Bool
    public var isStarting: Bool
    public var isInstalling: Bool
    public var invalidRestoreImage: Bool
    public var failure: String?

    public init(
        didStart: Bool,
        isStarting: Bool = false,
        isInstalling: Bool = false,
        invalidRestoreImage: Bool = false,
        failure: String? = nil
    ) {
        self.didStart = didStart
        self.isStarting = isStarting
        self.isInstalling = isInstalling
        self.invalidRestoreImage = invalidRestoreImage
        self.failure = failure
    }
}

public protocol BotDesktopVirtualizationProbe: AnyObject {
    var isSupported: Bool { get }
    func boot(diskImage: URL) -> BotDesktopVMBootAttempt
    func install(restoreImage: URL) -> BotDesktopVMBootAttempt
    func halt()
}

public final class SystemBotDesktopVirtualizationProbe: BotDesktopVirtualizationProbe {
    #if canImport(Virtualization)
    private let vzQueue = DispatchQueue(label: "io.remotecode.bot-desktop-vm")
    private var machine: VZVirtualMachine?
    private var installer: VZMacOSInstaller?
    private var lastInstallError: String?
    private var installFinished = false
    private var machineUsesVZQueue = false
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
            // EFI firmware is a real guest start path for Disk.img.
            // Restore.ipsw uses VZMacOSInstaller instead. No network device.
            let bootLoader = VZEFIBootLoader()
            bootLoader.variableStore = try efiVariableStore(nextTo: diskImage)
            config.bootLoader = bootLoader
            try config.validate()
            machineUsesVZQueue = false
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
            machine = vm
            if vm.state == .running {
                return BotDesktopVMBootAttempt(didStart: true)
            }
            if vm.state == .starting {
                return BotDesktopVMBootAttempt(didStart: false, isStarting: true)
            }
            machine = nil
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

    public func install(restoreImage: URL) -> BotDesktopVMBootAttempt {
        #if canImport(Virtualization)
        if let current = syncOnVZ({ self.currentInstallAttempt() }).flatMap({ $0 }) {
            return current
        }
        if syncOnVZ({ self.isInstalled(nextTo: restoreImage) }) == true {
            return syncOnVZ {
                self.haltOnQueue()
                return self.bootInstalledMacOS(nextTo: restoreImage)
            } ?? BotDesktopVMBootAttempt(didStart: false, failure: "Timed out starting the guest.")
        }

        // Load off the VM queue. VZMacOSRestoreImage callbacks must not
        // land on a queue we are blocking with a semaphore.
        let loaded = loadRestoreImage(restoreImage)
        if let failure = loaded.failure {
            return BotDesktopVMBootAttempt(
                didStart: false,
                invalidRestoreImage: true,
                failure: failure
            )
        }
        guard let image = loaded.image else {
            return BotDesktopVMBootAttempt(
                didStart: false,
                invalidRestoreImage: true,
                failure: "Restore image did not load."
            )
        }
        guard let requirements = image.mostFeaturefulSupportedConfiguration else {
            return BotDesktopVMBootAttempt(
                didStart: false,
                invalidRestoreImage: true,
                failure: "This Mac cannot run the restore image."
            )
        }

        return syncOnVZ {
            self.startInstallerOnQueue(restoreImage: restoreImage, requirements: requirements)
        } ?? BotDesktopVMBootAttempt(didStart: false, failure: "Timed out starting the restore.")
        #else
        return BotDesktopVMBootAttempt(didStart: false, failure: "Virtualization is not available.")
        #endif
    }

    #if canImport(Virtualization)
    private func startInstallerOnQueue(
        restoreImage: URL,
        requirements: VZMacOSConfigurationRequirements
    ) -> BotDesktopVMBootAttempt {
        haltOnQueue()
        lastInstallError = nil
        installFinished = false
        do {
            let disk = try ensureGuestDisk(nextTo: restoreImage)
            let platform = try macPlatform(requirements: requirements, nextTo: restoreImage)
            let config = try macConfiguration(
                requirements: requirements,
                disk: disk,
                platform: platform
            )
            machineUsesVZQueue = true
            let vm = VZVirtualMachine(configuration: config, queue: vzQueue)
            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: restoreImage)
            machine = vm
            self.installer = installer
            installer.install { [weak self] result in
                guard let self else { return }
                if case .failure(let error) = result {
                    self.lastInstallError = error.localizedDescription
                } else {
                    self.installFinished = true
                    self.markInstalled(nextTo: restoreImage)
                }
            }
            return BotDesktopVMBootAttempt(didStart: false, isInstalling: true)
        } catch {
            machine = nil
            installer = nil
            return BotDesktopVMBootAttempt(didStart: false, failure: error.localizedDescription)
        }
    }

    private func syncOnVZ<T>(_ work: @escaping () -> T) -> T? {
        let box = ValueBox<T>()
        vzQueue.async {
            box.value = work()
            box.signal()
        }
        _ = box.wait(seconds: 20)
        return box.value
    }

    private func currentInstallAttempt() -> BotDesktopVMBootAttempt? {
        if let lastInstallError {
            machine = nil
            installer = nil
            return BotDesktopVMBootAttempt(didStart: false, failure: lastInstallError)
        }
        if installFinished {
            installer = nil
            if let machine, machine.state == .running {
                return BotDesktopVMBootAttempt(didStart: true)
            }
            return BotDesktopVMBootAttempt(didStart: false, isStarting: true)
        }
        if installer != nil {
            return BotDesktopVMBootAttempt(didStart: false, isInstalling: true)
        }
        return nil
    }

    private func loadRestoreImage(_ url: URL) -> (image: VZMacOSRestoreImage?, failure: String?) {
        let box = RestoreLoadBox()
        VZMacOSRestoreImage.load(from: url) { result in
            switch result {
            case .success(let image):
                box.image = image
            case .failure(let error):
                box.error = error
            }
            box.signal()
        }
        _ = box.wait(seconds: 20)
        if let error = box.error {
            return (nil, error.localizedDescription)
        }
        if let image = box.image {
            return (image, nil)
        }
        return (nil, "Timed out loading the restore image.")
    }

    private func bootInstalledMacOS(nextTo restoreImage: URL) -> BotDesktopVMBootAttempt {
        do {
            let disk = restoreImage.deletingLastPathComponent().appendingPathComponent("Disk.img")
            guard FileManager.default.fileExists(atPath: disk.path) else {
                return BotDesktopVMBootAttempt(
                    didStart: false,
                    failure: "Installed guest disk is missing."
                )
            }
            let platform = try persistedMacPlatform(nextTo: restoreImage)
            let config = VZVirtualMachineConfiguration()
            config.platform = platform
            config.bootLoader = VZMacOSBootLoader()
            config.cpuCount = max(2, min(4, ProcessInfo.processInfo.processorCount))
            config.memorySize = min(
                4 * 1024 * 1024 * 1024,
                max(2 * 1024 * 1024 * 1024, ProcessInfo.processInfo.physicalMemory / 4)
            )
            let attachment = try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false)
            config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
            config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
            config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
            applyMacIO(to: config)
            try config.validate()
            machineUsesVZQueue = true
            let vm = VZVirtualMachine(configuration: config, queue: vzQueue)
            machine = vm
            vm.start { [weak self] result in
                if case .failure(let error) = result {
                    self?.lastInstallError = error.localizedDescription
                }
            }
            if vm.state == .running {
                return BotDesktopVMBootAttempt(didStart: true)
            }
            return BotDesktopVMBootAttempt(didStart: false, isStarting: true)
        } catch {
            machine = nil
            return BotDesktopVMBootAttempt(didStart: false, failure: error.localizedDescription)
        }
    }

    private func macConfiguration(
        requirements: VZMacOSConfigurationRequirements,
        disk: URL,
        platform: VZMacPlatformConfiguration
    ) throws -> VZVirtualMachineConfiguration {
        let attachment = try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false)
        let config = VZVirtualMachineConfiguration()
        config.platform = platform
        config.bootLoader = VZMacOSBootLoader()
        let cpus = max(requirements.minimumSupportedCPUCount, 2)
        config.cpuCount = min(cpus, max(1, ProcessInfo.processInfo.processorCount))
        let wanted = max(requirements.minimumSupportedMemorySize, 4 * 1024 * 1024 * 1024)
        let cap = max(requirements.minimumSupportedMemorySize, ProcessInfo.processInfo.physicalMemory / 2)
        config.memorySize = min(wanted, cap)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        applyMacIO(to: config)
        try config.validate()
        return config
    }

    private func applyMacIO(to config: VZVirtualMachineConfiguration) {
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(widthInPixels: 1280, heightInPixels: 800, pixelsPerInch: 80)
        ]
        config.graphicsDevices = [graphics]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    private func macPlatform(
        requirements: VZMacOSConfigurationRequirements,
        nextTo restoreImage: URL
    ) throws -> VZMacPlatformConfiguration {
        let dir = restoreImage.deletingLastPathComponent()
        let auxURL = dir.appendingPathComponent("macos-aux.bin")
        let machineURL = dir.appendingPathComponent("macos-machine-id.bin")
        let hardwareURL = dir.appendingPathComponent("macos-hardware-model.bin")

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = requirements.hardwareModel
        try requirements.hardwareModel.dataRepresentation.write(to: hardwareURL, options: .atomic)

        if let data = try? Data(contentsOf: machineURL),
           let identifier = VZMacMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = identifier
        } else {
            let identifier = VZMacMachineIdentifier()
            try identifier.dataRepresentation.write(to: machineURL, options: .atomic)
            platform.machineIdentifier = identifier
        }

        if FileManager.default.fileExists(atPath: auxURL.path) {
            platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: auxURL)
        } else {
            platform.auxiliaryStorage = try VZMacAuxiliaryStorage(
                creatingStorageAt: auxURL,
                hardwareModel: requirements.hardwareModel,
                options: []
            )
        }
        return platform
    }

    private func persistedMacPlatform(nextTo restoreImage: URL) throws -> VZMacPlatformConfiguration {
        let dir = restoreImage.deletingLastPathComponent()
        let auxURL = dir.appendingPathComponent("macos-aux.bin")
        let machineURL = dir.appendingPathComponent("macos-machine-id.bin")
        let hardwareURL = dir.appendingPathComponent("macos-hardware-model.bin")
        guard
            let hardwareData = try? Data(contentsOf: hardwareURL),
            let hardware = VZMacHardwareModel(dataRepresentation: hardwareData),
            hardware.isSupported
        else {
            throw NSError(
                domain: "BotDesktopVM",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Persisted macOS hardware model is missing."]
            )
        }
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardware
        if let data = try? Data(contentsOf: machineURL),
           let identifier = VZMacMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = identifier
        } else {
            platform.machineIdentifier = VZMacMachineIdentifier()
        }
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: auxURL)
        return platform
    }

    private func ensureGuestDisk(nextTo restoreImage: URL) throws -> URL {
        let url = restoreImage.deletingLastPathComponent().appendingPathComponent("Disk.img")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 64 * 1024 * 1024 * 1024)
        try handle.close()
        return url
    }

    private func installedMarker(nextTo restoreImage: URL) -> URL {
        restoreImage.deletingLastPathComponent().appendingPathComponent("guest-installed")
    }

    private func isInstalled(nextTo restoreImage: URL) -> Bool {
        FileManager.default.fileExists(atPath: installedMarker(nextTo: restoreImage).path)
    }

    private func markInstalled(nextTo restoreImage: URL) {
        FileManager.default.createFile(
            atPath: installedMarker(nextTo: restoreImage).path,
            contents: Data()
        )
    }

    private func efiVariableStore(nextTo diskImage: URL) throws -> VZEFIVariableStore {
        let url = diskImage.deletingLastPathComponent().appendingPathComponent("efi-nvram.bin")
        if FileManager.default.fileExists(atPath: url.path) {
            return VZEFIVariableStore(url: url)
        }
        return try VZEFIVariableStore(creatingVariableStoreAt: url)
    }

    private func haltOnQueue() {
        installer = nil
        lastInstallError = nil
        installFinished = false
        machineUsesVZQueue = false
        guard let machine else { return }
        let stopping = machine
        self.machine = nil
        if stopping.canStop {
            stopping.stop { _ in }
        }
    }
    #endif

    public func halt() {
        #if canImport(Virtualization)
        if machineUsesVZQueue || installer != nil {
            let box = StartBox()
            vzQueue.async {
                self.haltOnQueue()
                box.signal()
            }
            _ = box.wait(seconds: 6)
            return
        }
        haltOnQueue()
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

#if canImport(Virtualization)
private final class RestoreLoadBox: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    var image: VZMacOSRestoreImage?
    var error: Error?

    func signal() { semaphore.signal() }

    func wait(seconds: TimeInterval) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + seconds)
    }
}

private final class ValueBox<T>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    var value: T?

    func signal() { semaphore.signal() }

    func wait(seconds: TimeInterval) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + seconds)
    }
}
#endif

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
        } else if let restore = restoreImageURL(at: identity.bundlePath) {
            apply(attempt: probe.install(restoreImage: restore), to: &identity, restore: true)
        } else if let disk = diskImageURL(at: identity.bundlePath) {
            apply(attempt: probe.boot(diskImage: disk), to: &identity, restore: false)
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
        identity.lastError = nil
        identity.lastErrorDetail = nil
        identity.virtualizationSupported = probe.isSupported
        identity.updatedAt = now
        try store.save(identity)
        return identity
    }

    private func apply(
        attempt: BotDesktopVMBootAttempt,
        to identity: inout BotDesktopVMIdentity,
        restore: Bool
    ) {
        if attempt.didStart {
            identity.state = .running
            identity.lastError = nil
        } else if attempt.isInstalling {
            identity.state = .installing
            identity.lastError = nil
        } else if attempt.isStarting {
            identity.state = .starting
            identity.lastError = nil
        } else if attempt.invalidRestoreImage {
            identity.state = .failed
            identity.lastError = BotDesktopVMIdentity.invalidRestoreImageCode
            identity.lastErrorDetail = attempt.failure
        } else {
            identity.state = .failed
            identity.lastError = restore
                ? BotDesktopVMIdentity.installFailedCode
                : BotDesktopVMIdentity.bootFailedCode
            identity.lastErrorDetail = attempt.failure
        }
    }

    private func restoreImageURL(at bundlePath: String) -> URL? {
        let url = URL(fileURLWithPath: bundlePath, isDirectory: true)
            .appendingPathComponent("Restore.ipsw")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func diskImageURL(at bundlePath: String) -> URL? {
        let bundle = URL(fileURLWithPath: bundlePath, isDirectory: true)
        return ["Disk.img", "guest.img"]
            .map { bundle.appendingPathComponent($0) }
            .first { fileManager.fileExists(atPath: $0.path) }
    }
}
