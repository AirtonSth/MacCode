import CoreModel
import DesignSystemKit
import SwiftUI
import WebKit

/// Interactive noVNC guest screen. The URL must already be 127.0.0.1.
struct BotComputerGuestScreenView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> BotComputerGuestWebView {
        let configuration = WKWebViewConfiguration()
        // The only audio in vnc.html is the RFB bell. The URL already asks
        // noVNC not to play it (bell=off); this blocks any autoplay outright
        // so the guest can never make the Mac beep.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.embedStyleScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let view = BotComputerGuestWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        return view
    }

    /// The app owns the viewer chrome (Rebuild / Stop), so noVNC's floating
    /// control-bar handle reads as a broken leftover. Hide it and blend the
    /// page background into the surrounding pane (DS.Palette.surface).
    private static let embedStyleScript = """
    (function() {
      const style = document.createElement('style');
      style.textContent = `
        html, body { background: #171D24 !important; }
        #noVNC_control_bar_anchor { display: none !important; }
      `;
      document.documentElement.appendChild(style);
    })();
    """

    func updateNSView(_ view: BotComputerGuestWebView, context: Context) {
        guard (try? BotComputerGuestSpec.validateScreenURL(url)) != nil else { return }
        if view.url != url {
            view.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.window?.makeFirstResponder(webView)
            webView.evaluateJavaScript(
                """
                (function() {
                  const canvas = document.querySelector('canvas');
                  if (canvas) {
                    canvas.tabIndex = 0;
                    canvas.focus();
                  }
                })();
                """,
                completionHandler: nil
            )
        }
    }
}

/// Clicks on the guest must steal key focus from the Desk composer.
final class BotComputerGuestWebView: WKWebView {
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        evaluateJavaScript(
            "var c = document.querySelector('canvas'); if (c) { c.tabIndex = 0; c.focus(); }",
            completionHandler: nil
        )
        return accepted
    }
}

enum BotComputerGuestLaunchState: Equatable {
    case idle
    case starting
    case failed(String)

    var isStarting: Bool {
        self == .starting
    }

    var failureMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

/// Shared Desk/Studio chrome: live screen plus Start or Rebuild / Stop.
struct BotComputerGuestCanvas: View {
    let url: URL?
    let running: Bool
    let rebuilding: Bool
    let launchState: BotComputerGuestLaunchState
    let startIdentifier: String
    let rebuildIdentifier: String
    let stopIdentifier: String
    let screenIdentifier: String
    let onStart: () -> Void
    let onRebuild: () -> Void
    let onStop: () -> Void
    var onOpenInNewWindow: (() -> Void)? = nil
    var openInNewWindowIdentifier: String = "bots.desk.desktop.openInNewWindow"

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Text("Linux desktop")
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                Spacer(minLength: 0)
                if running {
                    Button(action: onRebuild) {
                        HStack(spacing: DS.Space.xs) {
                            if rebuilding {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(rebuilding ? "Rebuilding…" : "Rebuild")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(rebuilding)
                    .accessibilityLabel(rebuilding ? "Rebuilding Linux desktop" : "Rebuild Linux desktop")
                    .accessibilityIdentifier(rebuildIdentifier)
                    Button("Stop", action: onStop)
                        .buttonStyle(.bordered)
                        .disabled(rebuilding)
                        .accessibilityIdentifier(stopIdentifier)
                } else {
                    Button(action: onStart) {
                        HStack(spacing: DS.Space.xs) {
                            if launchState.isStarting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(startButtonTitle)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(launchState.isStarting)
                    .accessibilityLabel(startButtonAccessibilityLabel)
                    .accessibilityHint(startButtonAccessibilityHint)
                    .accessibilityIdentifier(startIdentifier)
                }
                if let onOpenInNewWindow {
                    DSIconButton("rectangle.on.rectangle", help: "Open in New Window") {
                        onOpenInNewWindow()
                    }
                    .accessibilityIdentifier(openInNewWindowIdentifier)
                }
            }
            if let url {
                // Match the guest framebuffer (start.sh Xvfb size, pinned against
                // BotComputerGuestSpec) so the viewer hugs the actual screen.
                BotComputerGuestScreenView(url: url)
                    .aspectRatio(
                        CGFloat(BotComputerGuestSpec.screenWidth) / CGFloat(BotComputerGuestSpec.screenHeight),
                        contentMode: .fit
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                    )
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier(screenIdentifier)
            } else {
                emptyScreen
            }
        }
    }

    @ViewBuilder
    private var emptyScreen: some View {
        VStack(spacing: DS.Space.sm) {
            switch launchState {
            case .idle:
                Text("Start the Linux desktop to use this machine.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
            case .starting:
                ProgressView()
                    .controlSize(.small)
                Text("Starting Linux desktop…")
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                Text("First launch can take a few minutes while Docker prepares the desktop.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(DS.Palette.warning)
                    .accessibilityHidden(true)
                Text(message)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel(
                        BotComputerDockerRecovery.matching(message)?.accessibilityLabel ?? message
                    )
            }
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(screenIdentifier)
    }

    private var startButtonTitle: String {
        if launchState.isStarting { return "Starting…" }
        return launchState.failureMessage == nil ? "Start" : "Try Again"
    }

    private var startButtonAccessibilityLabel: String {
        if launchState.isStarting { return "Starting Linux desktop" }
        if case .failed(let message) = launchState,
           let recovery = BotComputerDockerRecovery.matching(message) {
            return recovery.accessibilityAction
        }
        return startButtonTitle
    }

    private var startButtonAccessibilityHint: String {
        if case .failed(let message) = launchState {
            return BotComputerDockerRecovery.matching(message)?.accessibilityLabel ?? message
        }
        return "Starts the Linux desktop."
    }
}
