import AppKit
import ApplicationServices

/// The one foreground workflow in computer-use: install our own extension
/// through Chrome's normal UI, under the host-wide setup lease.
@MainActor
public enum ChromeExtensionInstallAutomation {
    private typealias Native = ComputerUseNativeHostBackend.NativePlatform

    public static func install(folder: URL, targetPID: Int32? = nil) async throws {
        guard AXIsProcessTrusted() else {
            throw failure("Enable Accessibility for RemoteCode in System Settings > Privacy & Security, then call browser_setup again.")
        }
        guard Native.activityMonitoringAvailable() else {
            throw failure("Computer Use could not monitor human activity. Check RemoteCode's Accessibility permission, then retry browser_setup.")
        }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let chrome: NSRunningApplication
        if let targetPID {
            guard let running = NSRunningApplication(processIdentifier: targetPID), running.bundleIdentifier == "com.google.Chrome" else {
                throw failure("The requested Chrome process is no longer running.")
            }
            chrome = running
        } else {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
                throw failure("Install Google Chrome, then call browser_setup again.")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            chrome = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        try await ComputerUseHostQueue.shared.withExclusive(targetPID: chrome.processIdentifier, kind: .mutation) {
            try await install(folder: folder, chrome: chrome, previousApp: previousApp)
        }
    }

    private static func install(folder: URL, chrome: NSRunningApplication, previousApp: NSRunningApplication?) async throws {
        let app = AXUIElementCreateApplication(chrome.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 2)
        let window = try await wait("Chrome's main window") { element(app, "AXMainWindow") }
        guard find(window, { string($0, "AXRole") == "AXSheet" }) == nil else {
            throw failure("Chrome has an open dialog. Close it before retrying browser_setup.")
        }
        chrome.activate(options: [])
        _ = try await wait("Chrome to become active") { chrome.isActive ? true : nil }
        let target = try await wait("the exact Chrome window") {
            Native.listWindows(bundleID: "com.google.Chrome").first(where: {
                $0.target.pid == chrome.processIdentifier && $0.isOnScreen && !$0.isMinimized
                    && Native.exactAXWindow(target: $0.target).map { CFEqual($0, window) } == true
            })?.target
        }
        guard Native.userActivity(target: target) != .human else {
            throw failure("human_activity: Chrome is in use. Retry browser_setup when the user is finished.")
        }
        let enhanced = attribute(app, "AXEnhancedUserInterface") as? Bool ?? false
        if !enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        defer {
            if !enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
            if chrome.isActive, Native.userActivity(target: target) != .human { previousApp?.activate(options: []) }
        }

        func check() throws {
            try Task.checkCancellation()
            guard chrome.isActive, element(app, "AXMainWindow").map({ CFEqual($0, window) }) == true,
                  Native.userActivity(target: target) != .human else {
                throw failure("human_activity: Chrome focus or user activity changed. Setup stopped; inspect Chrome before retrying.")
            }
        }
        func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
            try check()
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: code, keyDown: down) else {
                    throw failure("Could not send the Chrome setup key.")
                }
                event.flags = down ? flags : []
                event.setIntegerValueField(.eventSourceUserData, value: ComputerUseNativeActivityMonitor.syntheticEventUserData)
                event.post(tap: .cghidEventTap)
            }
        }
        func press(_ element: AXUIElement) throws {
            try check()
            guard attribute(element, "AXEnabled") as? Bool != false,
                  AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
                throw failure("Chrome did not accept the setup button. Check for a browser policy or dialog, then retry.")
            }
        }
        func field(_ element: AXUIElement, value: String) throws {
            try check()
            guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success else {
                throw failure("Chrome did not accept the extension folder path.")
            }
        }

        // A new tab preserves the user's current page. Never navigate an
        // arbitrary existing tab or type into an unverified text field.
        let tabs = try await wait("Chrome's tab strip", check: check) { find(window) { string($0, "AXRole") == "AXTabGroup" } }
        let previousTabCount = (attribute(tabs, "AXChildren") as? [AXUIElement] ?? []).count
        try key(17, flags: .maskCommand) // Command-T
        let address = try await wait("Chrome's new-tab address field", check: check) {
            guard (attribute(tabs, "AXChildren") as? [AXUIElement] ?? []).count > previousTabCount,
                  let focused = element(app, "AXFocusedUIElement"), string(focused, "AXRole") == "AXTextField",
                  string(focused, "AXDescription") == "Address and search bar" || string(focused, "AXDescription") == "Barra de endereço e pesquisa" else { return nil as AXUIElement? }
            return focused
        }
        try field(address, value: ChromeProfileConnection.setupURL.absoluteString)
        try key(36) // Return
        let page = try await wait("Chrome's extension manager", check: check) {
            find(window) {
                string($0, "AXRole") == "AXWebArea" && (attribute($0, "AXURL") as? URL)?.scheme == "chrome"
                    && (attribute($0, "AXURL") as? URL)?.host == "extensions"
            }
        }
        let developer = try await wait("Developer mode (or Modo do desenvolvedor)", check: check) {
            find(page) { string($0, "AXRole") == "AXCheckBox" && ["Developer mode", "Modo do desenvolvedor"].contains(string($0, "AXTitle")) }
        }
        if (attribute(developer, "AXValue") as? NSNumber)?.boolValue != true { try press(developer) }
        let load = try await wait("Load unpacked (or Carregar sem compactação)", check: check) {
            find(page) { string($0, "AXRole") == "AXButton" && ["Load unpacked", "Carregar sem compactação"].contains(string($0, "AXTitle")) }
        }
        try press(load)
        let panel = try await wait("Chrome's extension folder picker", check: check) { find(window) { string($0, "AXIdentifier") == "open-panel" } }
        try key(5, flags: [.maskCommand, .maskShift]) // Command-Shift-G
        let path = try await wait("the Go to Folder field", check: check) { find(panel) { string($0, "AXIdentifier") == "PathTextField" } }
        try field(path, value: folder.path)
        _ = try await wait("the exact extension folder", check: check) {
            find(panel) {
                string($0, "AXRole") == "AXList"
                    && URL(fileURLWithPath: string($0, "AXIdentifier")).resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path
            }
        }
        try key(36)
        _ = try await wait("the folder picker to finish navigation", check: check) {
            find(panel, { string($0, "AXIdentifier") == "GoToWindow" }) == nil ? true : nil
        }
        let select = try await wait("Select in Chrome's extension folder picker", check: check) { find(panel) { string($0, "AXIdentifier") == "OKButton" } }
        try press(select)
        _ = try await wait("Chrome to finish loading the extension", check: check) {
            find(window, { string($0, "AXIdentifier") == "open-panel" }) == nil ? true : nil
        }
        // Keep the setup tab visible for inspection; the caller verifies the
        // native connection and never treats these UI actions as success alone.
    }

    private static func wait<T>(_ step: String, check: () throws -> Void = {}, read: () -> T?) async throws -> T {
        for _ in 0..<40 {
            try Task.checkCancellation()
            try check()
            if let value = read() { return value }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw failure("Chrome setup stopped while waiting for \(step). Check Chrome's visible dialog or policy before retrying browser_setup.")
    }

    private static func failure(_ message: String) -> ChromeProfileConnection.Failure { .init(message: message) }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private static func string(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func find(_ root: AXUIElement, _ predicate: (AXUIElement) -> Bool, depth: Int = 0) -> AXUIElement? {
        guard depth < 32 else { return nil }
        if predicate(root) { return root }
        for child in attribute(root, "AXChildren") as? [AXUIElement] ?? [] {
            if let found = find(child, predicate, depth: depth + 1) { return found }
        }
        return nil
    }
}
