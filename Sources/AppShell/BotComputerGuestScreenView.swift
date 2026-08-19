import CoreModel
import DesignSystemKit
import SwiftUI
import WebKit

/// Interactive noVNC guest screen. The URL must already be 127.0.0.1.
struct BotComputerGuestScreenView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard (try? BotComputerGuestSpec.validateScreenURL(url)) != nil else { return }
        if view.url != url {
            view.load(URLRequest(url: url))
        }
    }
}

/// Shared Desk/Studio chrome: live screen plus Start / Stop / Terminal.
struct BotComputerGuestCanvas: View {
    let url: URL?
    let running: Bool
    let startIdentifier: String
    let stopIdentifier: String
    let terminalIdentifier: String
    let screenIdentifier: String
    let onStart: () -> Void
    let onStop: () -> Void
    let onTerminal: () -> Void

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
                    Button("Start", action: onStart)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(startIdentifier)
                }
            }
            if let url {
                BotComputerGuestScreenView(url: url)
                    .frame(minHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .accessibilityIdentifier(screenIdentifier)
            } else {
                Text("Start the Linux desktop to use this machine.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
                    .accessibilityIdentifier(screenIdentifier)
            }
        }
    }
}
