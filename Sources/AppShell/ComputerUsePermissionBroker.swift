import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// macOS attributes Screen Recording / Accessibility to the TCC *responsible*
/// app — for the computer-use MCP that is this app, not the helper binary the
/// provider spawns. The app never asked for either permission, so RemoteCode
/// only appeared in System Settings when the owner added it by hand, and a
/// hand-added entry can belong to an older build's code identity while the
/// current one silently fails. Requesting from the app process registers the
/// current identity and shows the standard system prompt.
public enum ComputerUsePermissionBroker {
    public struct Snapshot: Equatable, Sendable {
        public let screenCapture: Bool
        public let accessibility: Bool
        public var allGranted: Bool { screenCapture && accessibility }
    }

    public struct Requesters {
        public var preflightScreenCapture: () -> Bool
        public var requestScreenCapture: () -> Bool
        public var accessibilityTrusted: () -> Bool
        public var requestAccessibility: () -> Bool

        public static let live = Requesters(
            preflightScreenCapture: { CGPreflightScreenCaptureAccess() },
            requestScreenCapture: { CGRequestScreenCaptureAccess() },
            accessibilityTrusted: { AXIsProcessTrusted() },
            requestAccessibility: {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                return AXIsProcessTrustedWithOptions(options)
            }
        )
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestedThisProcess = false

    public static func snapshot(using requesters: Requesters = .live) -> Snapshot {
        Snapshot(
            screenCapture: requesters.preflightScreenCapture(),
            accessibility: requesters.accessibilityTrusted()
        )
    }

    /// Request whatever is missing, at most once per process (the system
    /// prompt must not re-appear on every admitted run). Returns the state
    /// after the request; a fresh grant still needs a NEW helper process.
    @discardableResult
    public static func requestOnceIfMissing(using requesters: Requesters = .live) -> Snapshot {
        let before = snapshot(using: requesters)
        guard !before.allGranted else { return before }
        lock.lock()
        let alreadyRequested = requestedThisProcess
        requestedThisProcess = true
        lock.unlock()
        guard !alreadyRequested else { return before }
        if !before.screenCapture { _ = requesters.requestScreenCapture() }
        if !before.accessibility { _ = requesters.requestAccessibility() }
        let after = snapshot(using: requesters)
        NSLog(
            "RemoteCode computer-use permissions: screen_capture=%@ accessibility=%@ (requested from the app process)",
            after.screenCapture ? "true" : "false",
            after.accessibility ? "true" : "false"
        )
        return after
    }

    static func resetForTesting() {
        lock.lock(); requestedThisProcess = false; lock.unlock()
    }
}
