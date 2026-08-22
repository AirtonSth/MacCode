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

    private let lock = NSLock()
    private let quietWindowNanoseconds: UInt64
    private let now: @Sendable () -> UInt64
    private var keyboardActivity: [Int32: UInt64] = [:]
    private var mouseActivity: [ComputerUseNativeHostTarget: UInt64] = [:]

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
        switch event.kind {
        case .keyboard:
            keyboardActivity[event.pid] = event.timestampNanoseconds
        case .mouse:
            guard let windowID = event.windowID else { return }
            mouseActivity[.init(pid: event.pid, windowID: windowID)] = event.timestampNanoseconds
        }
    }

    public func activity(for target: ComputerUseNativeHostTarget) -> ComputerUseNativeUserActivity {
        let current = now()
        lock.lock()
        defer { lock.unlock() }
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
        lock.unlock()
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
        public var accessibilityPermission: @Sendable () -> Bool
        public var screenCapturePermission: @Sendable () -> Bool
        public var capture: @Sendable (ComputerUseNativeHostTarget) async -> ComputerUseNativeCapture?
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
            accessibilityPermission: @escaping @Sendable () -> Bool = {
                NativePlatform.accessibilityPermission()
            },
            screenCapturePermission: @escaping @Sendable () -> Bool = {
                NativePlatform.screenCapturePermission()
            },
            capture: @escaping @Sendable (ComputerUseNativeHostTarget) async -> ComputerUseNativeCapture? = {
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
            self.accessibilityPermission = accessibilityPermission
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
        case permission_required
        case pixel_target_not_renderable
        case focus_required
        case activation_forbidden
        case semantic_action_failed
        case capture_unavailable
        case ui_tree_unavailable
    }

    private let hooks: Hooks

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

        let observation = makeObservation(window: window)
        switch name {
        case "screenshot", "zoom":
            return await captureResult(observation: observation, arguments: arguments)
        case "doctor":
            return ComputerUseToolResult(text: encodeObservation(observation))
        case "get_ui_tree":
            guard observation.accessibilityPermission,
                  let tree = hooks.uiTree(target) else {
                return failure(.ui_tree_unavailable, encodeObservation(observation))
            }
            return ComputerUseToolResult(text: encodeObservation(observation) + "\nui_tree: \(tree)")
        case "cursor_position":
            return ComputerUseToolResult(text: encodeObservation(observation) + "\n"
                + "cursor_position: \(Self.cursorPosition())")
        case "left_click", "right_click", "mouse_move", "scroll", "type", "key", "click_element", "open_application":
            return mutate(
                name: name,
                target: target,
                window: window,
                observation: observation,
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

    private func makeObservation(window: ComputerUseNativeWindow) -> ComputerUseNativeHostObservation {
        let accessibility = hooks.accessibilityPermission()
        let screenCapture = hooks.screenCapturePermission()
        let renderable = screenCapture && window.isOnScreen && !window.isMinimized
        var capabilities = ["observe", "targeted"]
        if renderable { capabilities.append("window_capture") }
        if accessibility { capabilities.append("semantic_ax") }
        let activity = hooks.userActivity(window.target)
        let token = stateToken(
            window: window,
            accessibilityPermission: accessibility,
            screenCapturePermission: screenCapture
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
        arguments: [String: Any]
    ) async -> ComputerUseToolResult {
        guard observation.screenCapturePermission,
              !observation.isMinimized,
              observation.isOnScreen else {
            return failure(.pixel_target_not_renderable, encodeObservation(observation))
        }
        guard let image = await hooks.capture(observation.target) else {
            return failure(.capture_unavailable, encodeObservation(observation))
        }
        _ = arguments
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
        arguments: [String: Any]
    ) -> ComputerUseToolResult {
        // Check the physical user before any permission or action probe: human
        // activity always wins and cannot be hidden by a stale automation call.
        if hooks.userActivity(target) == .human {
            return failure(.human_activity, encodeObservation(observation))
        }
        guard let expected = arguments["expected_state_token"] as? String,
              !expected.isEmpty else {
            return failure(.missing_state_token, encodeObservation(observation))
        }
        guard expected == observation.stateToken else {
            return failure(.stale_state_token, encodeObservation(observation))
        }

        switch name {
        case "left_click":
            let coordinate = arguments["coordinate"] as? [Double]
                ?? (arguments["coordinate"] as? [NSNumber])?.map(\.doubleValue)
                ?? []
            guard observation.screenCapturePermission,
                  observation.isOnScreen,
                  !observation.isMinimized else {
                return failure(.pixel_target_not_renderable, encodeObservation(observation))
            }
            guard hooks.leftClick(target, coordinate) else {
                return failure(.semantic_action_failed, encodeObservation(observation))
            }
            return ComputerUseToolResult(text: "native left click applied\n\(encodeObservation(observation))")
        case "click_element":
            guard observation.accessibilityPermission else {
                return failure(.permission_required, encodeObservation(observation))
            }
            let role = arguments["role"] as? String ?? ""
            let label = arguments["label"] as? String ?? ""
            guard !role.isEmpty, !label.isEmpty,
                  hooks.semanticAction(target, role, label) else {
                return failure(.semantic_action_failed, encodeObservation(observation))
            }
            return ComputerUseToolResult(text: "native semantic action applied\n\(encodeObservation(observation))")
        case "open_application":
            // Activation changes the human's active app and is never implicit.
            return failure(.activation_forbidden, encodeObservation(observation))
        case "type":
            let text = arguments["text"] as? String ?? ""
            guard !text.isEmpty, hooks.typeText(target, text) else {
                return failure(.focus_required, encodeObservation(observation))
            }
            return ComputerUseToolResult(text: "native background typing applied\n\(encodeObservation(observation))")
        case "right_click", "mouse_move", "scroll", "key":
            // These operations traditionally depend on focus or a physical
            // cursor. Native host control cannot steal either from the human.
            _ = window
            _ = target
            return failure(
                name == "type" || name == "key" ? .focus_required : .pixel_target_not_renderable,
                encodeObservation(observation)
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
        screenCapturePermission: Bool
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
        let material = [
            pid, windowID, title, bundleID, onScreen, minimized,
            originX, originY, width, height, accessibility, screenCapture,
        ].joined(separator: "|")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func target(from arguments: [String: Any]) -> ComputerUseNativeHostTarget? {
        guard let pid = int32(arguments["target_pid"]),
              let windowID = uint32(arguments["target_window_id"]),
              pid > 0,
              windowID > 0 else {
            return nil
        }
        return ComputerUseNativeHostTarget(pid: pid, windowID: windowID)
    }

    private static func int32(_ value: Any?) -> Int32? {
        if let value = value as? Int { return Int32(exactly: value) }
        if let value = value as? Int32 { return value }
        if let value = value as? NSNumber { return value.int32Value }
        if let value = value as? String { return Int32(value) }
        return nil
    }

    private static func uint32(_ value: Any?) -> UInt32? {
        if let value = value as? UInt32 { return value }
        if let value = value as? UInt { return UInt32(exactly: value) }
        if let value = value as? Int { return UInt32(exactly: value) }
        if let value = value as? NSNumber { return UInt32(exactly: value.intValue) }
        if let value = value as? String { return UInt32(value) }
        return nil
    }

    private static func cursorPosition() -> String {
        let point = NSEvent.mouseLocation
        return "(\(point.x),\(point.y))"
    }

    public enum NativePlatform {
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

        public static func screenCapturePermission() -> Bool {
            CGPreflightScreenCaptureAccess()
        }

        private static let activityMonitor = ComputerUseNativeActivityMonitor()
        private static let activityMonitorToken: Any? = {
            NSEvent.addGlobalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel]
            ) { event in
                guard let cgEvent = event.cgEvent else { return }
                let synthetic = cgEvent.getIntegerValueField(.eventSourceUserData)
                    == ComputerUseNativeActivityMonitor.syntheticEventUserData
                if event.type == .keyDown {
                    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
                    activityMonitor.record(.init(
                        kind: .keyboard,
                        pid: pid,
                        timestampNanoseconds: DispatchTime.now().uptimeNanoseconds,
                        isSynthetic: synthetic
                    ))
                } else if let target = windowUnderPointer(cgEvent.location) {
                    activityMonitor.record(.init(
                        kind: .mouse,
                        pid: target.pid,
                        windowID: target.windowID,
                        timestampNanoseconds: DispatchTime.now().uptimeNanoseconds,
                        isSynthetic: synthetic
                    ))
                }
            }
        }()

        public static func userActivity(target: ComputerUseNativeHostTarget) -> ComputerUseNativeUserActivity {
            _ = activityMonitorToken
            return activityMonitor.activity(for: target)
        }

        public static func capture(target: ComputerUseNativeHostTarget) async -> ComputerUseNativeCapture? {
            guard let content = await shareableContent(),
                  let window = content.windows.first(where: { $0.windowID == CGWindowID(target.windowID) }),
                  window.isOnScreen else {
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.width = max(Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)), 1)
            configuration.height = max(Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)), 1)
            configuration.showsCursor = false
            guard let image = await captureImage(filter: filter, configuration: configuration) else {
                return nil
            }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                return nil
            }
            return ComputerUseNativeCapture(data: data.base64EncodedString(), mimeType: "image/png")
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
        ) async -> CGImage? {
            await withCheckedContinuation { continuation in
                SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                ) { image, _ in
                    continuation.resume(returning: image)
                }
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
            matches(ownerWindow, bounds: targetBounds) else {
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

        private static func attribute(_ attribute: CFString, from element: AXUIElement) -> Any? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
            return value
        }

        private static func elementAttribute(_ key: CFString, from element: AXUIElement) -> AXUIElement? {
            guard let value = attribute(key, from: element) else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }

        private static func valueAttribute(_ key: CFString, from element: AXUIElement) -> AXValue? {
            guard let value = attribute(key, from: element) else { return nil }
            return unsafeBitCast(value, to: AXValue.self)
        }

        private static func exactAXWindow(target: ComputerUseNativeHostTarget) -> AXUIElement? {
            guard let bounds = targetBounds(target) else { return nil }
            let app = AXUIElementCreateApplication(target.pid)
            guard let windows = attribute(kAXWindowsAttribute as CFString, from: app) as? [AXUIElement] else {
                return nil
            }
            return windows.first { matches($0, bounds: bounds) }
        }

        private static func targetBounds(_ target: ComputerUseNativeHostTarget) -> CGRect? {
            listWindows(bundleID: nil).first { $0.target == target }?.bounds
        }

        private static func sameAXWindow(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
            guard let lhsFrame = frame(of: lhs), let rhsFrame = frame(of: rhs) else { return false }
            return framesEqual(lhsFrame, rhsFrame)
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
            if let children = attribute(kAXChildrenAttribute as CFString, from: element) as? [AXUIElement],
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
            guard let children = attribute(kAXChildrenAttribute as CFString, from: element) as? [AXUIElement] else {
                return false
            }
            return children.contains { find(element: $0, role: role, label: label, depth: depth + 1) }
        }
    }
}
