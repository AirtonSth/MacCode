import CoreModel
import SwiftUI
import WebKit

/// View-only noVNC guest screen. The URL must already be 127.0.0.1.
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
