import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ScreenCaptureKit

/// Exact host identity. A PID without a window ID is deliberately not enough
/// for a mutating operation: one process can own several independent windows.
public struct ComputerUseNativeHostTarget: Sendable, Equatable, Hashable {
    public let pid: Int32
    public let windowID: UInt32

    public init(pid: Int32, windowID: UInt32) {
        self.pid = pid
        self.windowID = windowID
    }
}

public typealias ComputerUseHostTarget = ComputerUseNativeHostTarget

public struct ComputerUseNativeWindow: Sendable, Equatable {
    public let target: ComputerUseNativeHostTarget
    public let title: String
    public let bundleIdentifier: String?
    public let isOnScreen: Bool
    public let isMinimized: Bool
    public let bounds: CGRect

    public init(
        target: ComputerUseNativeHostTarget,
        title: String = "",
        bundleIdentifier: String? = nil,
        isOnScreen: Bool = true,
        isMinimized: Bool = false,
        bounds: CGRect = .zero
    ) {
        self.target = target
        self.title = title
        self.bundleIdentifier = bundleIdentifier
        self.isOnScreen = isOnScreen
        self.isMinimized = isMinimized
        self.bounds = bounds
    }
}

public struct ComputerUseNativeCapture: Sendable, Equatable {
    public let data: String
    public let mimeType: String

    public init(data: String, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

public enum ComputerUseNativeCaptureResult: Sendable, Equatable {
    case success(ComputerUseNativeCapture)
    case quartzFallback(ComputerUseNativeCapture)
    case unavailable(String)
}

public enum ComputerUseNativeUserActivity: String, Sendable, Equatable {
    case none
    case human
    case synthetic
}

public struct ComputerUseNativeActivityEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case keyboard
        case mouse
    }

    public let kind: Kind
    public let pid: Int32
    public let windowID: UInt32?
    public let timestampNanoseconds: UInt64
    public let isSynthetic: Bool

    public init(
        kind: Kind,
        pid: Int32,
        windowID: UInt32? = nil,
        timestampNanoseconds: UInt64,
        isSynthetic: Bool = false
    ) {
        self.kind = kind
        self.pid = pid
        self.windowID = windowID
        self.timestampNanoseconds = timestampNanoseconds
        self.isSynthetic = isSynthetic
    }
}

/// Target-scoped physical activity. Keyboard events belong to the frontmost
/// PID; mouse events belong to the exact window under the pointer. Events
/// tagged by RemoteCode's synthetic input path are intentionally ignored.
public final class ComputerUseNativeActivityMonitor: @unchecked Sendable {
    public static let quietWindowNanoseconds: UInt64 = 2_000_000_000
    public static let syntheticEventUserData: Int64 = 0x5243_4355
    static let maximumTrackedActivityEntries = 512

    private let lock = NSLock()
    private let quietWindowNanoseconds: UInt64
    private let now: @Sendable () -> UInt64
    private var keyboardActivity: [Int32: UInt64] = [:]
    private var mouseActivity: [ComputerUseNativeHostTarget: UInt64] = [:]
    private var activityOverflowedUntil: UInt64?
    private var lastPrunedAt: UInt64?

    public init(
        quietWindowNanoseconds: UInt64 = ComputerUseNativeActivityMonitor.quietWindowNanoseconds,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.quietWindowNanoseconds = quietWindowNanoseconds
        self.now = now
    }

    public func record(_ event: ComputerUseNativeActivityEvent) {
        guard !event.isSynthetic else { return }
        lock.lock()
        defer { lock.unlock() }
        pruneExpired(at: event.timestampNanoseconds)
        if let activityOverflowedUntil,
           event.timestampNanoseconds <= activityOverflowedUntil {
            return
        }
        switch event.kind {
        case .keyboard:
            keyboardActivity[event.pid] = event.timestampNanoseconds
        case .mouse:
            guard let windowID = event.windowID else { return }
            mouseActivity[.init(pid: event.pid, windowID: windowID)] = event.timestampNanoseconds
        }
        guard keyboardActivity.count + mouseActivity.count > Self.maximumTrackedActivityEntries else {
            return
        }
        keyboardActivity.removeAll()
        mouseActivity.removeAll()
        let (quietEnd, overflow) = event.timestampNanoseconds.addingReportingOverflow(quietWindowNanoseconds)
        activityOverflowedUntil = overflow ? UInt64.max : quietEnd
    }

    public func activity(for target: ComputerUseNativeHostTarget) -> ComputerUseNativeUserActivity {
        let current = now()
        lock.lock()
        defer { lock.unlock() }
        pruneExpired(at: current)
        if let activityOverflowedUntil,
           current <= activityOverflowedUntil {
            // We cannot retain every recent target without making this map an
            // unbounded memory sink. Unknown activity is conservative here:
            // mutation callers fail closed while the quiet window drains.
            return .human
        }
        if let timestamp = keyboardActivity[target.pid], isRecent(timestamp, at: current) {
            return .human
        }
        if let timestamp = mouseActivity[target], isRecent(timestamp, at: current) {
            return .human
        }
        return .none
    }

    public func reset() {
        lock.lock()
        keyboardActivity.removeAll()
        mouseActivity.removeAll()
        activityOverflowedUntil = nil
        lastPrunedAt = nil
        lock.unlock()
    }

    private func pruneExpired(at current: UInt64) {
        if let lastPrunedAt,
           current >= lastPrunedAt,
           current - lastPrunedAt < quietWindowNanoseconds {
            return
        }
        keyboardActivity = keyboardActivity.filter { isRecent($0.value, at: current) }
        mouseActivity = mouseActivity.filter { isRecent($0.value, at: current) }
        self.lastPrunedAt = current
        if let activityOverflowedUntil,
           current > activityOverflowedUntil {
            self.activityOverflowedUntil = nil
        }
    }

    private func isRecent(_ timestamp: UInt64, at current: UInt64) -> Bool {
        current >= timestamp && current - timestamp <= quietWindowNanoseconds
    }
}

public struct ComputerUseNativeHostObservation: Sendable, Equatable {
    public let target: ComputerUseNativeHostTarget
    public let stateToken: String
    public let captureMode: String
    public let capabilities: [String]
    public let userActivity: ComputerUseNativeUserActivity
    public let accessibilityPermission: Bool
    public let screenCapturePermission: Bool
    public let isMinimized: Bool
    public let isOnScreen: Bool

    public init(
        target: ComputerUseNativeHostTarget,
        stateToken: String,
        captureMode: String,
        capabilities: [String],
        userActivity: ComputerUseNativeUserActivity,
        accessibilityPermission: Bool,
        screenCapturePermission: Bool,
        isMinimized: Bool,
        isOnScreen: Bool
    ) {
        self.target = target
        self.stateToken = stateToken
        self.captureMode = captureMode
        self.capabilities = capabilities
        self.userActivity = userActivity
        self.accessibilityPermission = accessibilityPermission
        self.screenCapturePermission = screenCapturePermission
        self.isMinimized = isMinimized
        self.isOnScreen = isOnScreen
    }
}

/// Native host implementation for the RemoteCode-owned computer-use MCP.
///
/// The hooks are intentionally small: production uses AppKit, Quartz,
/// Accessibility, and ScreenCaptureKit-adjacent permission checks, while unit
/// tests can prove every fail-closed branch without posting an input event.
public final class ComputerUseNativeHostBackend: ComputerUseToolBackend, @unchecked Sendable {
    public struct Hooks: @unchecked Sendable {
        public var listWindows: @Sendable (String?) -> [ComputerUseNativeWindow]
        public var userActivity: @Sendable (ComputerUseNativeHostTarget) -> ComputerUseNativeUserActivity
        public var activityMonitorAvailable: @Sendable () -> Bool
        public var accessibilityPermission: @Sendable () -> Bool
        public var axTargetAvailable: @Sendable (ComputerUseNativeHostTarget) -> Bool
        public var screenCapturePermission: @Sendable () -> Bool
        public var capture: @Sendable (ComputerUseNativeHostTarget) async -> ComputerUseNativeCaptureResult
        public var uiTree: @Sendable (ComputerUseNativeHostTarget) -> String?
        public var semanticAction: @Sendable (ComputerUseNativeHostTarget, String, String) -> Bool
        public var leftClick: @Sendable (ComputerUseNativeHostTarget, [Double]) -> Bool
        public var typeText: @Sendable (ComputerUseNativeHostTarget, String) -> Bool
        public var pixelAction: @Sendable (ComputerUseNativeHostTarget, String, [Double]) -> Bool
        public var activate: @Sendable (ComputerUseNativeHostTarget) -> Void

        public init(
            listWindows: @escaping @Sendable (String?) -> [ComputerUseNativeWindow] = {
                NativePlatform.listWindows(bundleID: $0)
            },
            userActivity: @escaping @Sendable (ComputerUseNativeHostTarget) -> ComputerUseNativeUserActivity = {
                NativePlatform.userActivity(target: $0)
            },
            activityMonitorAvailable: @escaping @Sendable () -> Bool = {
                NativePlatform.activityMonitoringAvailable()
            },
            accessibilityPermission: @escaping @Sendable () -> Bool = {
                NativePlatform.accessibilityPermission()
            },
            axTargetAvailable: @escaping @Sendable (ComputerUseNativeHostTarget) -> Bool = {
                NativePlatform.axTargetAvailable(target: $0)
            },
            screenCapturePermission: @escaping @Sendable () -> Bool = {
                NativePlatform.screenCapturePermission()
            },
            capture: @escaping @Sendable (ComputerUseNativeHostTarget) async -> ComputerUseNativeCaptureResult = {
                await NativePlatform.capture(target: $0)
            },
            uiTree: @escaping @Sendable (ComputerUseNativeHostTarget) -> String? = {
                NativePlatform.uiTree(target: $0)
            },
            semanticAction: @escaping @Sendable (ComputerUseNativeHostTarget, String, String) -> Bool = {
                NativePlatform.semanticAction(target: $0, role: $1, label: $2)
            },
            leftClick: @escaping @Sendable (ComputerUseNativeHostTarget, [Double]) -> Bool = {
                NativePlatform.leftClick(target: $0, coordinate: $1)
            },
            typeText: @escaping @Sendable (ComputerUseNativeHostTarget, String) -> Bool = {
                NativePlatform.typeText(target: $0, text: $1)
            },
            pixelAction: @escaping @Sendable (ComputerUseNativeHostTarget, String, [Double]) -> Bool = {
                NativePlatform.pixelAction(target: $0, name: $1, coordinate: $2)
            },
            activate: @escaping @Sendable (ComputerUseNativeHostTarget) -> Void = { _ in }
        ) {
            self.listWindows = listWindows
            self.userActivity = userActivity
            self.activityMonitorAvailable = activityMonitorAvailable
            self.accessibilityPermission = accessibilityPermission
            self.axTargetAvailable = axTargetAvailable
            self.screenCapturePermission = screenCapturePermission
            self.capture = capture
            self.uiTree = uiTree
            self.semanticAction = semanticAction
            self.leftClick = leftClick
            self.typeText = typeText
            self.pixelAction = pixelAction
            self.activate = activate
        }
    }

    private enum Failure: String {
        case invalid_target
        case target_not_found
        case missing_state_token
        case stale_state_token
        case human_activity
        case activity_monitor_unavailable
        case permission_required
        case pixel_target_not_renderable
        case focus_required
        case activation_forbidden
        case semantic_action_failed
        case capture_unavailable
        case capture_too_large
        case ui_tree_unavailable
        case invalid_region
    }

    private enum TokenKind: String {
        case semantic
        case pixel
        case geometry
    }

    private struct PixelScope: Equatable {
        let fullImageSize: [Int]
        let region: [Int]?

        var outputImageSize: [Int] {
            guard let region, region.count == 4 else { return fullImageSize }
            return [region[2], region[3]]
        }
    }

    private struct PixelTokenEnvelope: Codable, Equatable {
        let version: Int
        let targetPID: Int32
        let targetWindowID: UInt32
        let windowBounds: [Double]
        let accessibilityPermission: Bool
        let screenCapturePermission: Bool
        let fullImageSize: [Int]
        let region: [Int]?
        let pixelsDigest: String

        var scope: PixelScope {
            PixelScope(
                fullImageSize: fullImageSize,
                region: region
            )
        }
    }

    private let hooks: Hooks

    // A native screenshot is retained as decoded pixels, PNG bytes, base64,
    // and then once more in the MCP JSON envelope. Rejecting before base64
    // keeps the wire shape unchanged while bounding the peak allocation.
    static let maximumCapturePixelDimension = 8_192
    static let maximumCapturePixelCount = 24_000_000
    static let maximumCaptureEncodedBytes = 8 * 1_024 * 1_024
    static let maximumCaptureBase64Characters =
        ((maximumCaptureEncodedBytes + 2) / 3) * 4

    public init(hooks: Hooks = Hooks()) {
        self.hooks = hooks
    }

    public func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult {
        if name == "list_windows" {
            let bundleID = arguments["bundle_id"] as? String
                ?? arguments["target_app"] as? String
            let windows = hooks.listWindows(bundleID)
            return ComputerUseToolResult(text: encodeWindows(windows))
        }

        guard let target = Self.target(from: arguments) else {
            return failure(.invalid_target, "target_pid and target_window_id are required")
        }
        guard let window = resolve(target: target, arguments: arguments) else {
            return failure(.target_not_found, "the exact PID/window target is not present")
        }

        switch name {
        case "screenshot", "zoom":
            let requestedRegion: CGRect?
            if name == "zoom" {
                guard let region = Self.pixelRegion(arguments["region"]) else {
                    let observation = await makeObservation(
                        window: window,
                        kind: .pixel,
                        content: "<invalid-region>"
                    )
                    return failure(.invalid_region, encodeObservation(observation))
                }
                requestedRegion = region
            } else {
                requestedRegion = nil
            }

            var capture: ComputerUseNativeCapture?
            let captureFailure: String?
            if hooks.screenCapturePermission(), window.isOnScreen, !window.isMinimized {
                switch await hooks.capture(target) {
                case .success(let image), .quartzFallback(let image):
                    if Self.captureDataExceedsBudget(image) {
                        capture = nil
                        captureFailure = "capture_too_large"
                    } else {
                        capture = image
                        captureFailure = nil
                    }
                case .unavailable(let reason):
                    capture = nil
                    captureFailure = reason
                }
            } else {
                capture = nil
                captureFailure = nil
            }
            var pixelScope: PixelScope?
            if let captured = capture,
               let fullImageSize = Self.imageSize(capture: captured) {
                if let requestedRegion {
                    guard let cropped = Self.crop(capture: captured, region: requestedRegion) else {
                        let observation = await makeObservation(
                            window: window,
                            kind: .pixel,
                            content: "<invalid-region>"
                        )
                        return failure(.invalid_region, encodeObservation(observation))
                    }
                    capture = cropped
                    pixelScope = PixelScope(
                        fullImageSize: fullImageSize,
                        region: [
                            Int(requestedRegion.origin.x), Int(requestedRegion.origin.y),
                            Int(requestedRegion.width), Int(requestedRegion.height),
                        ]
                    )
                } else {
                    pixelScope = PixelScope(
                        fullImageSize: fullImageSize,
                        region: nil
                    )
                }
            } else if capture != nil {
                let observation = await makeObservation(
                    window: window,
                    kind: .pixel,
                    content: requestedRegion == nil ? "<pixels-unavailable>" : "<invalid-region>"
                )
                return failure(
                    requestedRegion == nil ? .capture_unavailable : .invalid_region,
                    encodeObservation(observation)
                )
            }
            let observation = await makeObservation(
                window: window,
                kind: .pixel,
                content: capture?.data ?? "<pixels-unavailable>",
                pixelScope: pixelScope
            )
            return captureResult(
                observation: observation,
                image: capture,
                failureReason: captureFailure
            )
        case "doctor":
            let observation = await makeObservation(window: window, kind: .semantic)
            return ComputerUseToolResult(text: encodeObservation(observation))
        case "get_ui_tree":
            let tree = hooks.uiTree(target)
            let observation = await makeObservation(window: window, kind: .semantic, content: tree)
            guard observation.accessibilityPermission,
                  let tree else {
                return failure(.ui_tree_unavailable, encodeObservation(observation))
            }
            return ComputerUseToolResult(text: encodeObservation(observation) + "\nui_tree: \(tree)")
        case "cursor_position":
            let observation = await makeObservation(window: window, kind: .geometry)
            return ComputerUseToolResult(text: encodeObservation(observation) + "\n"
                + "cursor_position: \(Self.cursorPosition())")
        case "left_click", "right_click", "mouse_move", "scroll", "type", "key", "click_element", "open_application":
            let kind: TokenKind = ["type", "click_element"].contains(name) ? .semantic : .pixel
            let observation = await makeObservation(window: window, kind: kind)
            return await mutate(
                name: name,
                target: target,
                window: window,
                observation: observation,
                tokenKind: kind,
                arguments: arguments
            )
        default:
            return failure(.invalid_target, "unsupported native computer-use operation: \(name)")
        }
    }

    private func resolve(
        target: ComputerUseNativeHostTarget,
        arguments: [String: Any]
    ) -> ComputerUseNativeWindow? {
        let bundleID = arguments["target_app"] as? String
        return hooks.listWindows(bundleID).first { $0.target == target }
    }

    private func makeObservation(
        window: ComputerUseNativeWindow,
        kind: TokenKind,
        content: String? = nil,
        pixelScope: PixelScope? = nil
    ) async -> ComputerUseNativeHostObservation {
        let accessibility = hooks.accessibilityPermission()
        let screenCapture = hooks.screenCapturePermission()
        let renderable = screenCapture && window.isOnScreen && !window.isMinimized
        let semanticAXAvailable = accessibility && hooks.axTargetAvailable(window.target)
        var capabilities = ["observe", "targeted"]
        if renderable { capabilities.append("window_capture") }
        if semanticAXAvailable { capabilities.append("semantic_ax") }
        let activity = hooks.userActivity(window.target)
        let observedContent: String
        var effectivePixelScope = pixelScope
        if kind == .pixel, !renderable {
            effectivePixelScope = nil
        }
        switch kind {
        case .semantic:
            observedContent = content ?? hooks.uiTree(window.target) ?? "<ui-tree-unavailable>"
        case .pixel:
            if let content {
                observedContent = content
            } else if renderable {
                switch await hooks.capture(window.target) {
                case .success(let capture), .quartzFallback(let capture):
                    guard !Self.captureDataExceedsBudget(capture) else {
                        observedContent = "<pixels-unavailable>"
                        effectivePixelScope = nil
                        break
                    }
                    if let fullImageSize = Self.imageSize(capture: capture),
                       let pixelScope {
                        if let region = pixelScope.region,
                           region.count == 4,
                           let cropped = Self.crop(
                               capture: capture,
                               region: CGRect(
                                   x: region[0], y: region[1],
                                   width: region[2], height: region[3]
                               )
                           ) {
                            observedContent = cropped.data
                            effectivePixelScope = PixelScope(
                                fullImageSize: fullImageSize,
                                region: pixelScope.region
                            )
                        } else if pixelScope.region == nil {
                            observedContent = capture.data
                            effectivePixelScope = PixelScope(
                                fullImageSize: fullImageSize,
                                region: nil
                            )
                        } else {
                            observedContent = capture.data
                            effectivePixelScope = nil
                        }
                    } else {
                        observedContent = capture.data
                        effectivePixelScope = nil
                    }
                case .unavailable:
                    observedContent = "<pixels-unavailable>"
                    effectivePixelScope = nil
                }
            } else {
                observedContent = "<pixels-unavailable>"
            }
        case .geometry:
            observedContent = "<geometry-only>"
        }
        let token = stateToken(
            window: window,
            accessibilityPermission: accessibility,
            screenCapturePermission: screenCapture,
            kind: kind,
            content: observedContent,
            pixelScope: effectivePixelScope
        )
        return ComputerUseNativeHostObservation(
            target: window.target,
            stateToken: token,
            captureMode: renderable ? "window" : "unavailable",
            capabilities: capabilities,
            userActivity: activity,
            accessibilityPermission: accessibility,
            screenCapturePermission: screenCapture,
            isMinimized: window.isMinimized,
            isOnScreen: window.isOnScreen
        )
    }

    private func captureResult(
        observation: ComputerUseNativeHostObservation,
        image: ComputerUseNativeCapture?,
        failureReason: String?
    ) -> ComputerUseToolResult {
        guard observation.screenCapturePermission,
              !observation.isMinimized,
              observation.isOnScreen else {
            return failure(.pixel_target_not_renderable, encodeObservation(observation))
        }
        guard let image else {
            if failureReason == Failure.capture_too_large.rawValue {
                return failure(.capture_too_large, encodeObservation(observation))
            }
            let diagnostic = failureReason.map { "\n capture_failure: \($0)" } ?? ""
            return failure(.capture_unavailable, encodeObservation(observation) + diagnostic)
        }
        return ComputerUseToolResult(content: [
            .text(encodeObservation(observation)),
            .image(data: image.data, mimeType: image.mimeType),
        ])
    }

    private func mutate(
        name: String,
        target: ComputerUseNativeHostTarget,
        window: ComputerUseNativeWindow,
        observation: ComputerUseNativeHostObservation,
        tokenKind: TokenKind,
        arguments: [String: Any]
    ) async -> ComputerUseToolResult {
        // Check the physical user before any permission or action probe: human
        // activity always wins and cannot be hidden by a stale automation call.
        guard hooks.activityMonitorAvailable() else {
            return failure(.activity_monitor_unavailable, encodeObservation(observation))
        }
        if hooks.userActivity(target) == .human {
            return failure(.human_activity, encodeObservation(observation))
        }
        guard let expected = arguments["expected_state_token"] as? String,
              !expected.isEmpty else {
            return failure(.missing_state_token, encodeObservation(observation))
        }
        let expectedPixelScope: PixelScope?
        if tokenKind == .pixel {
            guard let envelope = Self.decodePixelToken(expected),
                  envelope.targetPID == target.pid,
                  envelope.targetWindowID == target.windowID else {
                return failure(.stale_state_token, encodeObservation(observation))
            }
            expectedPixelScope = envelope.scope
        } else {
            expectedPixelScope = nil
        }
        // Re-read the capability-specific content immediately before the
        // mutation. The observation token is never a substitute for this
        // final race check.
        let freshObservation = await makeObservation(
            window: window,
            kind: tokenKind,
            pixelScope: expectedPixelScope
        )
        guard expected == freshObservation.stateToken else {
            return failure(.stale_state_token, encodeObservation(freshObservation))
        }
        // The content read above can take time (AX traversal or a screenshot).
        // Give a physical user event observed during that window priority too.
        if hooks.userActivity(target) == .human {
            return failure(.human_activity, encodeObservation(freshObservation))
        }

        switch name {
        case "left_click":
            guard let localCoordinate = Self.localCoordinate(arguments["coordinate"]) else {
                return failure(.semantic_action_failed, encodeObservation(freshObservation))
            }
            guard freshObservation.screenCapturePermission,
                  freshObservation.isOnScreen,
                  !freshObservation.isMinimized else {
                return failure(.pixel_target_not_renderable, encodeObservation(freshObservation))
            }
            guard let currentWindow = resolve(target: target, arguments: arguments),
                  currentWindow == window,
                  currentWindow.bounds.width.isFinite,
                  currentWindow.bounds.height.isFinite,
                  currentWindow.bounds.width > 0,
                  currentWindow.bounds.height > 0 else {
                return failure(.stale_state_token, encodeObservation(freshObservation))
            }
            guard let expectedPixelScope,
                  let freshEnvelope = Self.decodePixelToken(freshObservation.stateToken),
                  expectedPixelScope == freshEnvelope.scope,
                  expectedPixelScope.fullImageSize.count == 2,
                  expectedPixelScope.outputImageSize.count == 2,
                  expectedPixelScope.fullImageSize.allSatisfy({ $0 > 0 }),
                  expectedPixelScope.outputImageSize.allSatisfy({ $0 > 0 }),
                  localCoordinate[0] >= 0,
                  localCoordinate[1] >= 0,
                  localCoordinate[0] < Double(expectedPixelScope.outputImageSize[0]),
                  localCoordinate[1] < Double(expectedPixelScope.outputImageSize[1]) else {
                return failure(.semantic_action_failed, encodeObservation(freshObservation))
            }
            let fullPixelCoordinate: [Double]
            if let region = expectedPixelScope.region,
               region.count == 4 {
                fullPixelCoordinate = [
                    Double(region[0]) + localCoordinate[0],
                    Double(region[1]) + localCoordinate[1],
                ]
            } else {
                fullPixelCoordinate = localCoordinate
            }
            let scaleX = Double(expectedPixelScope.fullImageSize[0]) / currentWindow.bounds.width
            let scaleY = Double(expectedPixelScope.fullImageSize[1]) / currentWindow.bounds.height
            guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0,
                  fullPixelCoordinate[0] >= 0,
                  fullPixelCoordinate[1] >= 0,
                  fullPixelCoordinate[0] < Double(expectedPixelScope.fullImageSize[0]),
                  fullPixelCoordinate[1] < Double(expectedPixelScope.fullImageSize[1]) else {
                return failure(.semantic_action_failed, encodeObservation(freshObservation))
            }
            let coordinate = [
                currentWindow.bounds.origin.x + fullPixelCoordinate[0] / scaleX,
                currentWindow.bounds.origin.y + fullPixelCoordinate[1] / scaleY,
            ]
            guard hooks.leftClick(target, coordinate) else {
                return failure(.semantic_action_failed, encodeObservation(freshObservation))
            }
            return ComputerUseToolResult(text: "native left click applied\n\(encodeObservation(freshObservation))")
        case "click_element":
            guard freshObservation.accessibilityPermission,
                  freshObservation.capabilities.contains("semantic_ax") else {
                return failure(.permission_required, encodeObservation(freshObservation))
            }
            let role = arguments["role"] as? String ?? ""
            let label = arguments["label"] as? String ?? ""
            guard !role.isEmpty, !label.isEmpty,
                  hooks.semanticAction(target, role, label) else {
                return failure(.semantic_action_failed, encodeObservation(freshObservation))
            }
            return ComputerUseToolResult(text: "native semantic action applied\n\(encodeObservation(freshObservation))")
        case "open_application":
            // Activation changes the human's active app and is never implicit.
            return failure(.activation_forbidden, encodeObservation(freshObservation))
        case "type":
            let text = arguments["text"] as? String ?? ""
            guard freshObservation.capabilities.contains("semantic_ax"),
                  !text.isEmpty, hooks.typeText(target, text) else {
                return failure(.focus_required, encodeObservation(freshObservation))
            }
            return ComputerUseToolResult(text: "native background typing applied\n\(encodeObservation(freshObservation))")
        case "right_click", "mouse_move", "scroll", "key":
            // These operations traditionally depend on focus or a physical
            // cursor. Native host control cannot steal either from the human.
            return failure(
                name == "key" ? .focus_required : .pixel_target_not_renderable,
                encodeObservation(freshObservation)
            )
        default:
            return failure(.invalid_target, "unsupported native mutation")
        }
    }

    private func failure(_ error: Failure, _ detail: String) -> ComputerUseToolResult {
        ComputerUseToolResult(
            text: "native computer-use error: \(error.rawValue)\n\(detail)",
            isError: true
        )
    }

    private func encodeObservation(_ observation: ComputerUseNativeHostObservation) -> String {
        let object: [String: Any] = [
            "target_pid": Int(observation.target.pid),
            "target_window_id": Int(observation.target.windowID),
            "state_token": observation.stateToken,
            "capture_mode": observation.captureMode,
            "capabilities": observation.capabilities,
            "user_activity": observation.userActivity.rawValue,
            "permissions": [
                "accessibility": observation.accessibilityPermission,
                "screen_capture": observation.screenCapturePermission,
            ],
            "is_minimized": observation.isMinimized,
            "is_on_screen": observation.isOnScreen,
        ]
        return encode(object)
    }

    private func encodeWindows(_ windows: [ComputerUseNativeWindow]) -> String {
        let object = windows.map { window in
            [
                "target_pid": Int(window.target.pid),
                "target_window_id": Int(window.target.windowID),
                "title": window.title,
                "bundle_id": window.bundleIdentifier as Any,
                "is_on_screen": window.isOnScreen,
                "is_minimized": window.isMinimized,
            ] as [String: Any]
        }
        return encode(object)
    }

    private func encode(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let result = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return result
    }

    private func stateToken(
        window: ComputerUseNativeWindow,
        accessibilityPermission: Bool,
        screenCapturePermission: Bool,
        kind: TokenKind,
        content: String,
        pixelScope: PixelScope? = nil
    ) -> String {
        let pid = String(window.target.pid)
        let windowID = String(window.target.windowID)
        let title = window.title
        let bundleID = window.bundleIdentifier ?? ""
        let onScreen = String(window.isOnScreen)
        let minimized = String(window.isMinimized)
        let originX = String(describing: window.bounds.origin.x)
        let originY = String(describing: window.bounds.origin.y)
        let width = String(describing: window.bounds.size.width)
        let height = String(describing: window.bounds.size.height)
        let accessibility = String(accessibilityPermission)
        let screenCapture = String(screenCapturePermission)
        let contentDigest = SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        if kind == .pixel {
            guard let pixelScope else { return "" }
            let bounds: [Double] = [
                Double(window.bounds.origin.x), Double(window.bounds.origin.y),
                Double(window.bounds.width), Double(window.bounds.height),
            ]
            let envelope = PixelTokenEnvelope(
                version: 1,
                targetPID: window.target.pid,
                targetWindowID: window.target.windowID,
                windowBounds: bounds,
                accessibilityPermission: accessibilityPermission,
                screenCapturePermission: screenCapturePermission,
                fullImageSize: pixelScope.fullImageSize,
                region: pixelScope.region,
                pixelsDigest: contentDigest
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(envelope) else {
                return ""
            }
            return "native-pixel-v1:" + data.base64EncodedString()
        }
        let material = [
            pid, windowID, title, bundleID, onScreen, minimized,
            originX, originY, width, height, accessibility, screenCapture,
            kind.rawValue, contentDigest,
        ].joined(separator: "|")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func decodePixelToken(_ token: String) -> PixelTokenEnvelope? {
        let prefix = "native-pixel-v1:"
        guard token.hasPrefix(prefix),
              let data = Data(base64Encoded: String(token.dropFirst(prefix.count))),
              let envelope = try? JSONDecoder().decode(PixelTokenEnvelope.self, from: data),
              envelope.version == 1,
              envelope.targetPID > 0,
              envelope.targetWindowID > 0,
              envelope.windowBounds.count == 4,
              envelope.windowBounds.allSatisfy({ $0.isFinite }),
              envelope.fullImageSize.count == 2,
              envelope.fullImageSize.allSatisfy({ $0 > 0 }),
              !envelope.pixelsDigest.isEmpty else {
            return nil
        }
        if let region = envelope.region {
            guard
                  region.count == 4,
                  region[0] >= 0, region[1] >= 0,
                  region[2] > 0, region[3] > 0,
                  region[2] <= envelope.fullImageSize[0],
                  region[3] <= envelope.fullImageSize[1],
                  region[0] <= envelope.fullImageSize[0] - region[2],
                  region[1] <= envelope.fullImageSize[1] - region[3] else { return nil }
        }
        return envelope
    }

    private static func target(from arguments: [String: Any]) -> ComputerUseNativeHostTarget? {
        guard let pid = exactInt32(arguments["target_pid"]),
              let windowID = exactUInt32(arguments["target_window_id"]),
              pid > 0,
              windowID > 0 else {
            return nil
        }
        return ComputerUseNativeHostTarget(pid: pid, windowID: windowID)
    }

    static func exactInt32(_ value: Any?) -> Int32? {
        guard !isBooleanNumber(value) else { return nil }
        if let value = value as? Int32 { return value }
        if let value = value as? Int { return Int32(exactly: value) }
        if let value = value as? NSNumber {
            guard let integer = Int(exactly: value.doubleValue) else { return nil }
            return Int32(exactly: integer)
        }
        return nil
    }

    static func exactUInt32(_ value: Any?) -> UInt32? {
        guard !isBooleanNumber(value) else { return nil }
        if let value = value as? UInt32 { return value }
        if let value = value as? UInt { return UInt32(exactly: value) }
        if let value = value as? Int { return UInt32(exactly: value) }
        if let value = value as? NSNumber {
            guard let integer = Int(exactly: value.doubleValue) else { return nil }
            return UInt32(exactly: integer)
        }
        return nil
    }

    private static func exactPixelInteger(_ value: Any?) -> Int? {
        guard !isBooleanNumber(value) else { return nil }
        if let value = value as? Int { return value }
        if let value = value as? Int32 { return Int(value) }
        if let value = value as? UInt32 { return Int(value) }
        if let value = value as? NSNumber {
            return Int(exactly: value.doubleValue)
        }
        return nil
    }

    private static func localCoordinate(_ value: Any?) -> [Double]? {
        let values: [Any]
        if let value = value as? [Any] {
            values = value
        } else if let value = value as? [Double] {
            values = value
        } else if let value = value as? [NSNumber] {
            values = value
        } else {
            return nil
        }
        guard values.count == 2 else { return nil }
        let result = values.compactMap { value -> Double? in
            guard !isBooleanNumber(value) else { return nil }
            if let value = value as? Double { return value.isFinite ? value : nil }
            if let value = value as? Int { return Double(value) }
            if let value = value as? NSNumber {
                let number = value.doubleValue
                return number.isFinite ? number : nil
            }
            return nil
        }
        return result.count == 2 ? result : nil
    }

    private static func isBooleanNumber(_ value: Any?) -> Bool {
        if value is Bool { return true }
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
    }

    private static func pixelRegion(_ value: Any?) -> CGRect? {
        let values: [Any]
        if let value = value as? [Any] {
            values = value
        } else if let value = value as? [Double] {
            values = value
        } else if let value = value as? [NSNumber] {
            values = value
        } else {
            return nil
        }
        guard values.count == 4,
              let x = exactPixelInteger(values[0]),
              let y = exactPixelInteger(values[1]),
              let width = exactPixelInteger(values[2]),
              let height = exactPixelInteger(values[3]),
              x >= 0, y >= 0, width > 0, height > 0 else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func crop(
        capture: ComputerUseNativeCapture,
        region: CGRect
    ) -> ComputerUseNativeCapture? {
        guard let data = decodedCaptureData(capture),
              let representation = NSBitmapImageRep(data: data),
              let image = representation.cgImage,
              region.maxX <= CGFloat(image.width),
              region.maxY <= CGFloat(image.height),
              let cropped = image.cropping(to: CGRect(
                  x: region.origin.x,
                  y: region.origin.y,
                  width: region.width,
                  height: region.height
              )),
              let croppedData = NSBitmapImageRep(cgImage: cropped)
                .representation(using: .png, properties: [:]) else {
            return nil
        }
        guard croppedData.count <= maximumCaptureEncodedBytes else { return nil }
        return ComputerUseNativeCapture(
            data: croppedData.base64EncodedString(),
            mimeType: "image/png"
        )
    }

    private static func imageSize(capture: ComputerUseNativeCapture) -> [Int]? {
        guard let data = decodedCaptureData(capture),
              let representation = NSBitmapImageRep(data: data),
              representation.pixelsWide > 0,
              representation.pixelsHigh > 0 else {
            return nil
        }
        return [representation.pixelsWide, representation.pixelsHigh]
    }

    private static func captureDataExceedsBudget(_ capture: ComputerUseNativeCapture) -> Bool {
        guard capture.data.utf8.count <= maximumCaptureBase64Characters,
              let data = Data(base64Encoded: capture.data),
              data.count <= maximumCaptureEncodedBytes else {
            return true
        }
        return encodedImageDimensionsExceedBudget(data)
    }

    private static func decodedCaptureData(_ capture: ComputerUseNativeCapture) -> Data? {
        guard capture.data.utf8.count <= maximumCaptureBase64Characters,
              let data = Data(base64Encoded: capture.data),
              data.count <= maximumCaptureEncodedBytes,
              !encodedImageDimensionsExceedBudget(data) else {
            return nil
        }
        return data
    }

    private static func encodedImageDimensionsExceedBudget(_ data: Data) -> Bool {
        let pngSignature: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        ]
        guard data.count >= 24,
              data.prefix(pngSignature.count).elementsEqual(pngSignature) else {
            return false
        }
        let width = data[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let height = data[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard width > 0, height > 0 else { return true }
        return width > UInt32(maximumCapturePixelDimension)
            || height > UInt32(maximumCapturePixelDimension)
            || UInt64(height) > UInt64(maximumCapturePixelCount) / UInt64(width)
    }

    private static func cursorPosition() -> String {
        let point = NSEvent.mouseLocation
        return "(\(point.x),\(point.y))"
    }

    public enum NativePlatform {
        private enum CaptureImageFailure: Error, CustomStringConvertible {
            case screenshotManager(domain: String, code: Int, description: String)
            case quartzFallback(String)

            var allowsQuartzFallback: Bool {
                switch self {
                case .screenshotManager(let domain, let code, _):
                    return NativePlatform.allowsQuartzFallback(domain: domain, code: code)
                case .quartzFallback:
                    return false
                }
            }

            var description: String {
                switch self {
                case .screenshotManager(_, _, let value):
                    return value
                case .quartzFallback(let value):
                    return value
                }
            }
        }

        static func allowsQuartzFallback(domain: String, code: Int) -> Bool {
            domain == SCStreamErrorDomain && code == -3811
        }

        struct QuartzWindowSnapshot: Equatable {
            let pid: Int32
            let windowID: UInt32
            let isOnScreen: Bool
            let bounds: CGRect

            init(pid: Int32, windowID: UInt32, isOnScreen: Bool, bounds: CGRect) {
                self.pid = pid
                self.windowID = windowID
                self.isOnScreen = isOnScreen
                self.bounds = bounds
            }
        }

        private typealias QuartzWindowImageFunction = @convention(c) (
            CGRect,
            CGWindowListOption,
            CGWindowID,
            CGWindowImageOption
        ) -> CGImage?

        private static let quartzWindowImageFunction: QuartzWindowImageFunction? = {
            guard let symbol = dlsym(
                UnsafeMutableRawPointer(bitPattern: -2),
                "CGWindowListCreateImage"
            ) else {
                return nil
            }
            return unsafeBitCast(symbol, to: QuartzWindowImageFunction.self)
        }()

        public static func listWindows(bundleID: String?) -> [ComputerUseNativeWindow] {
            let infos = CGWindowListCopyWindowInfo(
                [.optionAll, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] ?? []
            return infos.compactMap { info in
                guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                      let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                      pid > 0,
                      number > 0 else {
                    return nil
                }
                let app = NSRunningApplication(processIdentifier: pid)
                if let bundleID, app?.bundleIdentifier != bundleID { return nil }
                let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                    .flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
                let isOnScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
                return ComputerUseNativeWindow(
                    target: .init(pid: pid, windowID: number),
                    title: info[kCGWindowName as String] as? String ?? "",
                    bundleIdentifier: app?.bundleIdentifier,
                    isOnScreen: isOnScreen,
                    isMinimized: !isOnScreen,
                    bounds: bounds
                )
            }
        }

        public static func accessibilityPermission() -> Bool {
            AXIsProcessTrusted()
        }

        public static func axTargetAvailable(target: ComputerUseNativeHostTarget) -> Bool {
            AXIsProcessTrusted() && exactAXWindow(target: target) != nil
        }

        static func quartzTitleUniquelyIdentifiesTarget(
            _ title: String?,
            target: ComputerUseNativeHostTarget,
            windows: [ComputerUseNativeWindow]
        ) -> Bool {
            guard let title, !title.isEmpty else { return false }
            let matches = windows.filter { $0.target.pid == target.pid && $0.title == title }
            return matches.count == 1 && matches[0].target == target
        }

        public static func screenCapturePermission() -> Bool {
            CGPreflightScreenCaptureAccess()
        }

        private static let activityMonitor = ComputerUseNativeActivityMonitor()

        /// A global NSEvent monitor is delivered on AppKit's run loop and can
        /// stop observing while the stdio host is blocked. Keep the native tap
        /// on its own thread/run loop instead. A listen-only tap never changes
        /// the event stream and the source-user-data tag remains fail-closed.
        private final class ActivityTap: @unchecked Sendable {
            private let monitor: ComputerUseNativeActivityMonitor
            private let lock = NSLock()
            private var started = false
            private var available = false
            private var shouldStop = false
            private var runLoop: CFRunLoop?
            private var tap: CFMachPort?
            private var readiness: DispatchGroup?

            init(monitor: ComputerUseNativeActivityMonitor) {
                self.monitor = monitor
            }

            deinit {
                stop()
            }

            func start() -> Bool {
                lock.lock()
                if started {
                    let readiness = self.readiness
                    lock.unlock()
                    readiness?.wait()
                    lock.lock()
                    let result = available
                    lock.unlock()
                    return result
                }
                started = true
                let ready = DispatchGroup()
                ready.enter()
                readiness = ready
                let thread = Thread { [weak self] in
                    self?.run(ready: ready)
                }
                thread.name = "RemoteCode.ComputerUseActivityTap"
                thread.start()
                lock.unlock()
                ready.wait()
                lock.lock()
                let result = available
                lock.unlock()
                return result
            }

            func stop() {
                lock.lock()
                shouldStop = true
                let loop = runLoop
                let currentTap = tap
                tap = nil
                lock.unlock()
                if let loop {
                    CFRunLoopStop(loop)
                }
                if let currentTap {
                    CGEvent.tapEnable(tap: currentTap, enable: false)
                }
            }

            private func run(ready: DispatchGroup) {
                let keyboard = CGEventMask(1 << CGEventType.keyDown.rawValue)
                    | CGEventMask(1 << CGEventType.keyUp.rawValue)
                let mouse = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
                    | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
                    | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
                    | CGEventMask(1 << CGEventType.scrollWheel.rawValue)
                let mask = keyboard | mouse
                let context = Unmanaged.passUnretained(self).toOpaque()
                guard let eventTap = CGEvent.tapCreate(
                    tap: .cgSessionEventTap,
                    place: .headInsertEventTap,
                    options: .listenOnly,
                    eventsOfInterest: mask,
                    callback: Self.eventTapCallback,
                    userInfo: context
                ) else {
                    lock.lock()
                    available = false
                    lock.unlock()
                    ready.leave()
                    return
                }

                let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
                let loop = CFRunLoopGetCurrent()
                lock.lock()
                tap = eventTap
                runLoop = loop
                available = source != nil
                let stopImmediately = shouldStop
                lock.unlock()
                ready.leave()
                guard let source, !stopImmediately else {
                    CGEvent.tapEnable(tap: eventTap, enable: false)
                    return
                }
                CFRunLoopAddSource(loop, source, .commonModes)
                CGEvent.tapEnable(tap: eventTap, enable: true)
                CFRunLoopRun()
                CFRunLoopRemoveSource(loop, source, .commonModes)
                CGEvent.tapEnable(tap: eventTap, enable: false)
                lock.lock()
                tap = nil
                runLoop = nil
                available = false
                lock.unlock()
            }

            private static let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<ActivityTap>.fromOpaque(refcon).takeUnretainedValue()
                tap.record(type: type, event: event)
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    tap.lock.lock()
                    let currentTap = tap.tap
                    tap.lock.unlock()
                    if let currentTap {
                        CGEvent.tapEnable(tap: currentTap, enable: true)
                    }
                }
                return Unmanaged.passUnretained(event)
            }

            private func record(type: CGEventType, event: CGEvent) {
                let synthetic = event.getIntegerValueField(.eventSourceUserData)
                    == ComputerUseNativeActivityMonitor.syntheticEventUserData
                guard !synthetic else { return }
                let timestamp = DispatchTime.now().uptimeNanoseconds
                if type == .keyDown || type == .keyUp {
                    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
                    monitor.record(.init(
                        kind: .keyboard,
                        pid: pid,
                        timestampNanoseconds: timestamp
                    ))
                } else if let target = NativePlatform.windowUnderPointer(event.location) {
                    monitor.record(.init(
                        kind: .mouse,
                        pid: target.pid,
                        windowID: target.windowID,
                        timestampNanoseconds: timestamp
                    ))
                }
            }
        }

        private static let activityTap = ActivityTap(monitor: activityMonitor)

        public static func userActivity(target: ComputerUseNativeHostTarget) -> ComputerUseNativeUserActivity {
            _ = activityTap.start()
            return activityMonitor.activity(for: target)
        }

        public static func activityMonitoringAvailable() -> Bool {
            activityTap.start()
        }

        public static func capture(target: ComputerUseNativeHostTarget) async -> ComputerUseNativeCaptureResult {
            guard let content = await shareableContent() else {
                return .unavailable("shareable_content_unavailable")
            }
            guard let window = content.windows.first(where: {
                $0.windowID == CGWindowID(target.windowID)
                    && $0.owningApplication?.processID == target.pid
            }) else {
                return .unavailable("target_window_unavailable")
            }
            guard window.isOnScreen else {
                return .unavailable("target_window_off_screen")
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scaledWidth = filter.contentRect.width * CGFloat(filter.pointPixelScale)
            let scaledHeight = filter.contentRect.height * CGFloat(filter.pointPixelScale)
            guard scaledWidth.isFinite,
                  scaledHeight.isFinite,
                  scaledWidth > 0,
                  scaledHeight > 0,
                  scaledWidth <= CGFloat(ComputerUseNativeHostBackend.maximumCapturePixelDimension),
                  scaledHeight <= CGFloat(ComputerUseNativeHostBackend.maximumCapturePixelDimension) else {
                return .unavailable("capture_too_large")
            }
            let width = Int(scaledWidth)
            let height = Int(scaledHeight)
            guard width > 0, height > 0 else {
                return .unavailable("target_window_empty_content_rect")
            }
            guard height <= ComputerUseNativeHostBackend.maximumCapturePixelCount / width else {
                return .unavailable("capture_too_large")
            }
            configuration.width = width
            configuration.height = height
            configuration.showsCursor = false
            let imageResult: Result<CGImage, CaptureImageFailure>
            let usedQuartzFallback: Bool
            switch await captureImage(filter: filter, configuration: configuration) {
            case .success(let image):
                imageResult = .success(image)
                usedQuartzFallback = false
            case .failure(let reason) where reason.allowsQuartzFallback:
                imageResult = quartzWindowImage(target: target, after: reason)
                usedQuartzFallback = true
            case .failure(let reason):
                return .unavailable(reason.description)
            }
            switch imageResult {
            case .success(let image):
                guard image.width > 0,
                      image.height > 0,
                      image.width <= ComputerUseNativeHostBackend.maximumCapturePixelDimension,
                      image.height <= ComputerUseNativeHostBackend.maximumCapturePixelDimension,
                      image.height <= ComputerUseNativeHostBackend.maximumCapturePixelCount / image.width else {
                    return .unavailable("capture_too_large")
                }
                let bitmap = NSBitmapImageRep(cgImage: image)
                guard let data = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
                    return .unavailable("png_encoding_failed")
                }
                guard data.count <= ComputerUseNativeHostBackend.maximumCaptureEncodedBytes else {
                    return .unavailable("capture_too_large")
                }
                let capture = ComputerUseNativeCapture(data: data.base64EncodedString(), mimeType: "image/png")
                return usedQuartzFallback ? .quartzFallback(capture) : .success(capture)
            case .failure(let reason):
                return .unavailable(reason.description)
            }
        }

        private static func quartzWindowImage(
            target: ComputerUseNativeHostTarget,
            after screenCaptureFailure: CaptureImageFailure
        ) -> Result<CGImage, CaptureImageFailure> {
            guard let before = quartzWindowSnapshot(target: target) else {
                return .failure(.quartzFallback("window_identity_or_bounds_invalid_before_\(screenCaptureFailure.description)"))
            }
            guard let imageFunction = quartzWindowImageFunction else {
                let reason = quartzFallbackValidationFailure(
                    target: target,
                    before: before,
                    symbolAvailable: false,
                    imageSize: nil,
                    after: nil
                ) ?? "quartz_fallback_symbol_unavailable"
                return .failure(.quartzFallback("\(reason)_after_\(screenCaptureFailure.description)"))
            }
            guard let image = imageFunction(
                .null,
                [.optionIncludingWindow],
                CGWindowID(target.windowID),
                [.boundsIgnoreFraming, .bestResolution]
            ) else {
                let reason = quartzFallbackValidationFailure(
                    target: target,
                    before: before,
                    symbolAvailable: true,
                    imageSize: nil,
                    after: nil
                ) ?? "quartz_fallback_image_unavailable"
                return .failure(.quartzFallback("\(reason)_after_\(screenCaptureFailure.description)"))
            }
            let after = quartzWindowSnapshot(target: target)
            if let reason = quartzFallbackValidationFailure(
                target: target,
                before: before,
                symbolAvailable: true,
                imageSize: .init(width: image.width, height: image.height),
                after: after
            ) {
                return .failure(.quartzFallback("\(reason)_after_\(screenCaptureFailure.description)"))
            }
            return .success(image)
        }

        static func quartzFallbackValidationFailure(
            target: ComputerUseNativeHostTarget,
            before: QuartzWindowSnapshot?,
            symbolAvailable: Bool,
            imageSize: CGSize?,
            after: QuartzWindowSnapshot?
        ) -> String? {
            guard let before,
                  before.pid == target.pid,
                  before.windowID == target.windowID,
                  before.isOnScreen,
                  before.bounds.width > 0,
                  before.bounds.height > 0,
                  before.bounds.origin.x.isFinite,
                  before.bounds.origin.y.isFinite,
                  before.bounds.width.isFinite,
                  before.bounds.height.isFinite else {
                return "window_identity_or_bounds_invalid_before"
            }
            guard symbolAvailable else {
                return "quartz_fallback_symbol_unavailable"
            }
            guard let imageSize,
                  imageSize.width > 0,
                  imageSize.height > 0 else {
                return "quartz_fallback_image_unavailable"
            }
            guard let after, after == before else {
                return "window_identity_or_bounds_drifted_after"
            }
            return nil
        }

        private static func quartzWindowSnapshot(
            target: ComputerUseNativeHostTarget
        ) -> QuartzWindowSnapshot? {
            let windowID = CGWindowID(target.windowID)
            let infos = (CGWindowListCopyWindowInfo(
                [.optionIncludingWindow],
                windowID
            ) as? [[String: Any]]) ?? []
            guard infos.count == 1,
                  let info = infos.first,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  number == target.windowID,
                  pid == target.pid,
                  (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary),
                  bounds.width > 0,
                  bounds.height > 0,
                  bounds.origin.x.isFinite,
                  bounds.origin.y.isFinite,
                  bounds.width.isFinite,
                  bounds.height.isFinite else {
                return nil
            }
            return QuartzWindowSnapshot(
                pid: pid,
                windowID: number,
                isOnScreen: true,
                bounds: bounds
            )
        }

        private static func shareableContent() async -> SCShareableContent? {
            await withCheckedContinuation { continuation in
                SCShareableContent.getExcludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                ) { content, _ in
                    continuation.resume(returning: content)
                }
            }
        }

        private static func captureImage(
            filter: SCContentFilter,
            configuration: SCStreamConfiguration
        ) async -> Result<CGImage, CaptureImageFailure> {
            do {
                return .success(try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                ))
            } catch {
                let nsError = error as NSError
                let reason = String(describing: error)
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(256)
                return .failure(.screenshotManager(
                    domain: nsError.domain,
                    code: nsError.code,
                    description: String(reason)
                ))
            }
        }

        private static func windowUnderPointer(_ point: CGPoint) -> ComputerUseNativeHostTarget? {
            let infos = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] ?? []
            for info in infos {
                let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
                guard layer == 0,
                      let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                      let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                      let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: dictionary),
                      bounds.contains(point) else {
                    continue
                }
                return .init(pid: pid, windowID: windowID)
            }
            return nil
        }

        public static func semanticAction(
            target: ComputerUseNativeHostTarget,
            role: String,
            label: String
        ) -> Bool {
            guard AXIsProcessTrusted() else { return false }
            guard let window = exactAXWindow(target: target) else {
                return false
            }
            return find(element: window, role: role, label: label)
        }

        public static func uiTree(target: ComputerUseNativeHostTarget) -> String? {
            guard AXIsProcessTrusted(), let window = exactAXWindow(target: target) else { return nil }
            var budget = TreeBudget()
            let tree = serialize(element: window, depth: 0, budget: &budget)
            guard JSONSerialization.isValidJSONObject(tree),
                  let data = try? JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys]),
                  let result = String(data: data, encoding: .utf8) else {
                return nil
            }
            return result
        }

        public static func leftClick(
            target: ComputerUseNativeHostTarget,
            coordinate: [Double]
        ) -> Bool {
            guard AXIsProcessTrusted(), coordinate.count >= 2,
                  let targetBounds = targetBounds(target),
                  let targetWindow = exactAXWindow(target: target),
                  targetBounds.contains(CGPoint(x: coordinate[0], y: coordinate[1])) else {
                return false
            }
            let app = AXUIElementCreateApplication(target.pid)
            var element: AXUIElement?
            guard AXUIElementCopyElementAtPosition(
                app,
                Float(coordinate[0]),
                Float(coordinate[1]),
                &element
            ) == .success,
            let element,
            let ownerWindow = elementAttribute(kAXWindowAttribute as CFString, from: element),
            sameAXWindow(ownerWindow, targetWindow) else {
                return false
            }
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }

        public static func typeText(
            target: ComputerUseNativeHostTarget,
            text: String
        ) -> Bool {
            guard AXIsProcessTrusted(), !text.isEmpty,
                  let targetWindow = exactAXWindow(target: target) else {
                return false
            }
            let app = AXUIElementCreateApplication(target.pid)
            guard let focusedWindow = elementAttribute(kAXFocusedWindowAttribute as CFString, from: app),
                  sameAXWindow(focusedWindow, targetWindow),
                  let focused = elementAttribute(kAXFocusedUIElementAttribute as CFString, from: app) else {
                return false
            }
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(
                focused,
                kAXValueAttribute as CFString,
                &settable
            ) == .success, settable.boolValue else {
                return false
            }
            return AXUIElementSetAttributeValue(
                focused,
                kAXValueAttribute as CFString,
                text as CFString
            ) == .success
        }

        public static func pixelAction(
            target: ComputerUseNativeHostTarget,
            name: String,
            coordinate: [Double]
        ) -> Bool {
            // A Quartz event would move the user's physical pointer or steal
            // focus. The native backend intentionally has no pixel injector.
            _ = target
            _ = name
            _ = coordinate
            return false
        }

        private static func attribute(_ attribute: CFString, from element: AXUIElement) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
            return value
        }

        private static func elementAttribute(_ key: CFString, from element: AXUIElement) -> AXUIElement? {
            guard let value = attribute(key, from: element) else { return nil }
            return axElement(from: value)
        }

        private static func valueAttribute(_ key: CFString, from element: AXUIElement) -> AXValue? {
            guard let value = attribute(key, from: element) else { return nil }
            guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            let pointer = Unmanaged.passUnretained(value).toOpaque()
            return Unmanaged<AXValue>.fromOpaque(pointer).takeUnretainedValue()
        }

        private static func exactAXWindow(target: ComputerUseNativeHostTarget) -> AXUIElement? {
            let quartzWindows = listWindows(bundleID: nil)
            guard let targetQuartzWindow = quartzWindows.first(where: { $0.target == target }) else {
                return nil
            }
            let bounds = targetQuartzWindow.bounds
            let targetTitle: String? = targetQuartzWindow.title
            let app = AXUIElementCreateApplication(target.pid)
            guard let windows = attribute(kAXWindowsAttribute as CFString, from: app)
                    .flatMap(axElements(from:)) else { return nil }
            let frameMatches = windows.filter { matches($0, bounds: bounds) }
            if frameMatches.count == 1 { return frameMatches[0] }

            // Multiple AX windows can report the same frame (for example a
            // sheet and its owner). A frame alone is not an exact identity;
            // use the Quartz title only when it disambiguates exactly one
            // candidate, and otherwise fail closed.
            guard let title = targetTitle, !title.isEmpty else { return nil }
            guard quartzTitleUniquelyIdentifiesTarget(title, target: target, windows: quartzWindows) else {
                return nil
            }
            let titleMatches = frameMatches.filter {
                (attribute(kAXTitleAttribute as CFString, from: $0) as? String) == title
            }
            if titleMatches.count == 1 { return titleMatches[0] }

            // Some macOS 26 targets expose AXWindows but temporarily reject
            // AXPosition/AXSize while the display is asleep. A unique title
            // is still an exact, non-activating identity; ambiguity remains
            // fail-closed rather than selecting the first element.
            guard frameMatches.isEmpty else { return nil }
            let titleOnlyMatches = windows.filter {
                (attribute(kAXTitleAttribute as CFString, from: $0) as? String) == title
            }
            return titleOnlyMatches.count == 1 ? titleOnlyMatches[0] : nil
        }

        static func axElements(from value: CFTypeRef) -> [AXUIElement]? {
            guard CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }
            let array = value as! CFArray
            var elements: [AXUIElement] = []
            elements.reserveCapacity(CFArrayGetCount(array))
            for index in 0..<CFArrayGetCount(array) {
                guard let raw = CFArrayGetValueAtIndex(array, index) else {
                    return nil
                }
                let object = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
                guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
                let element = Unmanaged<AXUIElement>.fromOpaque(raw).takeUnretainedValue()
                elements.append(element)
            }
            return elements
        }

        private static func axElement(from value: CFTypeRef) -> AXUIElement? {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            let pointer = Unmanaged.passUnretained(value).toOpaque()
            return Unmanaged<AXUIElement>.fromOpaque(pointer).takeUnretainedValue()
        }

        private static func sameAXWindow(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
            CFEqual(lhs, rhs)
        }

        private static func targetBounds(_ target: ComputerUseNativeHostTarget) -> CGRect? {
            listWindows(bundleID: nil).first { $0.target == target }?.bounds
        }

        private static func matches(_ element: AXUIElement, bounds: CGRect) -> Bool {
            guard let elementFrame = frame(of: element) else { return false }
            return framesEqual(elementFrame, bounds)
        }

        private static func frame(of element: AXUIElement) -> CGRect? {
            guard let position = valueAttribute(kAXPositionAttribute as CFString, from: element),
                  let size = valueAttribute(kAXSizeAttribute as CFString, from: element) else {
                return nil
            }
            var origin = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(position, .cgPoint, &origin),
                  AXValueGetValue(size, .cgSize, &dimensions) else {
                return nil
            }
            return CGRect(origin: origin, size: dimensions)
        }

        private static func framesEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            abs(lhs.origin.x - rhs.origin.x) < 1
                && abs(lhs.origin.y - rhs.origin.y) < 1
                && abs(lhs.size.width - rhs.size.width) < 1
                && abs(lhs.size.height - rhs.size.height) < 1
        }

        private struct TreeBudget {
            var nodes = 0
        }

        private static func serialize(
            element: AXUIElement,
            depth: Int,
            budget: inout TreeBudget
        ) -> [String: Any] {
            guard depth <= 8, budget.nodes < 200 else { return ["truncated": true] }
            budget.nodes += 1
            var result: [String: Any] = [:]
            if let role = attribute(kAXRoleAttribute as CFString, from: element) as? String { result["role"] = role }
            if let subrole = attribute(kAXSubroleAttribute as CFString, from: element) as? String {
                result["subrole"] = subrole
            }
            if let title = attribute(kAXTitleAttribute as CFString, from: element) as? String, !title.isEmpty {
                result["title"] = title
            }
            if let description = attribute(kAXDescriptionAttribute as CFString, from: element) as? String,
               !description.isEmpty {
                result["description"] = description
            }
            if let identifier = attribute(kAXIdentifierAttribute as CFString, from: element) as? String,
               !identifier.isEmpty {
                result["identifier"] = identifier
            }
            if let value = attribute(kAXValueAttribute as CFString, from: element) as? String, !value.isEmpty {
                result["value"] = String(value.prefix(512))
            }
            if let children = attribute(kAXChildrenAttribute as CFString, from: element)
                    .flatMap(axElements(from:)),
               !children.isEmpty {
                result["children"] = children.map { serialize(element: $0, depth: depth + 1, budget: &budget) }
            }
            return result
        }

        private static func find(element: AXUIElement, role: String, label: String, depth: Int = 0) -> Bool {
            guard depth < 32 else { return false }
            let actualRole = attribute(kAXRoleAttribute as CFString, from: element) as? String
            let title = attribute(kAXTitleAttribute as CFString, from: element) as? String
            let description = attribute(kAXDescriptionAttribute as CFString, from: element) as? String
            if actualRole == role && (title == label || description == label),
               AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                return true
            }
            guard let children = attribute(kAXChildrenAttribute as CFString, from: element)
                    .flatMap(axElements(from:)) else {
                return false
            }
            return children.contains { find(element: $0, role: role, label: label, depth: depth + 1) }
        }
    }
}
