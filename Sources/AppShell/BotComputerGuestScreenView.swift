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
        let view = BotComputerGuestWebView()
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        return view
    }

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

/// Shared Desk/Studio chrome: live screen plus Start / Stop / Terminal.
struct BotComputerGuestCanvas: View {
    let url: URL?
    let running: Bool
    let launchState: BotComputerGuestLaunchState
    let startIdentifier: String
    let stopIdentifier: String
    let terminalIdentifier: String
    let screenIdentifier: String
    let onStart: () -> Void
    let onStop: () -> Void
    let onTerminal: () -> Void
    var onOpenInNewWindow: (() -> Void)? = nil
    var openInNewWindowIdentifier: String = "bots.desk.desktop.openInNewWindow"
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Text("Linux desktop")
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                Spacer(minLength: 0)
                if running {
                    Button("Stop", action: onStop)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(stopIdentifier)
                    Button("Terminal", action: onTerminal)
                        .buttonStyle(.bordered)
                        .disabled(!running)
                        .accessibilityIdentifier(terminalIdentifier)
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
                BotComputerGuestScreenView(url: url)
                    .frame(minHeight: compact ? 180 : 280)
                    .frame(maxHeight: .infinity)
                    .clipped()
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
        launchState.isStarting ? "Starting Linux desktop" : startButtonTitle
    }
}
