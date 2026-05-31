import Foundation
import IOKit.ps

public enum ExternalPowerState: Equatable {
    case externalPower
    case battery
    case unknown
}

public protocol ExternalPowerMonitoring: AnyObject {
    var currentPowerState: ExternalPowerState { get }
    var onPowerStateChanged: (@MainActor (ExternalPowerState) -> Void)? { get set }
    func start()
    func stop()
}

public final class MacOSExternalPowerMonitor: ExternalPowerMonitoring {
    private var runLoopSource: CFRunLoopSource?
    private var started = false
    public var onPowerStateChanged: (@MainActor (ExternalPowerState) -> Void)?

    public var currentPowerState: ExternalPowerState {
        Self.readCurrentPowerState()
    }

    public init() {}

    public func start() {
        guard !started else { return }
        guard let unmanagedSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<MacOSExternalPowerMonitor>
                .fromOpaque(context)
                .takeUnretainedValue()
            monitor.publishCurrentPowerState()
        }, Unmanaged.passUnretained(self).toOpaque()) else {
            return
        }
        let source = unmanagedSource.takeRetainedValue()
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        started = true
    }

    public func stop() {
        guard let source = runLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = nil
        started = false
    }

    private func publishCurrentPowerState() {
        let state = currentPowerState
        Task { @MainActor [onPowerStateChanged] in
            onPowerStateChanged?(state)
        }
    }

    private static func readCurrentPowerState() -> ExternalPowerState {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return .unknown
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as NSDictionary?,
                let powerSourceState = description[kIOPSPowerSourceStateKey] as? String else {
                continue
            }
            if powerSourceState == kIOPSACPowerValue {
                return .externalPower
            }
            if powerSourceState == kIOPSBatteryPowerValue {
                return .battery
            }
        }
        return .unknown
    }

    deinit {
        stop()
    }
}
