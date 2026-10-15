import AppKit
import Carbon.HIToolbox
import CoreModel
import SwiftUI

/// Option+Space anywhere opens a floating "talk to Titio" bar: the pet above
/// a one-line field. Return sends the text to Titio and opens its chat.
@MainActor
public final class TitioQuickChatController {
    static let keyCode = UInt32(kVK_Space)
    static let modifiers = UInt32(optionKey)

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var panel: NSPanel?
    private var onSend: ((String) -> Void)?
    private(set) var registrationStatus: OSStatus = noErr
    /// True once Option+Space is registered, so hints never promise a dead shortcut.
    private(set) static var isHotKeyRegistered = false

    public init() {}

    public var isVisible: Bool { panel?.isVisible == true }

    public func install(onSend: @escaping (String) -> Void) {
        self.onSend = onSend
        guard hotKeyRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let controller = Unmanaged<TitioQuickChatController>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { controller.toggle() }
            return noErr
        }, 1, &spec, context, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x5449_5449), id: 1) // "TITI"
        registrationStatus = RegisterEventHotKey(
            Self.keyCode, Self.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        Self.isHotKeyRegistered = registrationStatus == noErr
    }

    public func toggle() {
        isVisible ? close() : show()
    }

    public func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Fresh content each time so the field is empty and takes focus.
        panel.contentView = NSHostingView(rootView: TitioQuickChatView(
            onSubmit: { [weak self] in self?.submit($0) },
            onCancel: { [weak self] in self?.close() }
        ))
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.22))
        }
        // Non-activating panel takes key without activating the app, like
        // Spotlight, so it works over whatever app is in front.
        panel.orderFrontRegardless()
        panel.makeKey()
        // SwiftUI builds the field on a later turn; focus it once it exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak panel] in
            guard let panel, panel.isVisible else { return }
            panel.makeKey()
            if let field = Self.firstTextField(in: panel.contentView) {
                panel.makeFirstResponder(field)
            }
        }
    }

    private static func firstTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for child in view.subviews {
            if let found = firstTextField(in: child) { return found }
        }
        return nil
    }

    public func close() {
        panel?.orderOut(nil)
    }

    func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        close()
        onSend?(trimmed)
    }

    private func makePanel() -> NSPanel {
        let panel = TitioQuickChatPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 210),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("titio.quickChat")
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }
}

private final class TitioQuickChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Opened from the keyboard many times a day, so it appears at once: no
/// entrance animation to wait through.
struct TitioQuickChatView: View {
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            TitioAvatarView(size: 110)
            TitioComposerField(
                size: .spotlight,
                identifier: "titio.quickChat.field",
                onSubmit: onSubmit,
                onCancel: onCancel
            )
        }
        .padding(12)
        .frame(width: 520)
    }
}
