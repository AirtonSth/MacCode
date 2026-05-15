import Foundation
import AppKit
import WebKit
import CoreModel

@MainActor
public final class BrowserSurface: NSObject, Surface, WKNavigationDelegate {
    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    private let webView: WKWebView
    private let addressBar: NSTextField
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()

    public init(workspaceID: WorkspaceID, initialURL: URL? = nil, title: String = "browser") {
        self.descriptor = SurfaceDescriptor(
            type: .browser,
            title: title,
            iconName: "browser",
            metadata: ["workspace": workspaceID.value.uuidString]
        )

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = WKWebsiteDataStore.default()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        self.webView = wv

        let tf = NSTextField()
        tf.placeholderString = "Enter URL and press Return"
        tf.font = .systemFont(ofSize: 12)
        self.addressBar = tf

        let toolbar = NSView()
        for b in [backButton, forwardButton, reloadButton] {
            b.bezelStyle = .recessed
            b.controlSize = .small
        }
        backButton.title = "◀"
        forwardButton.title = "▶"
        reloadButton.title = "↻"

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        for v in [toolbar, wv] { v.translatesAutoresizingMaskIntoConstraints = false }
        for v in [backButton, forwardButton, reloadButton, tf] { v.translatesAutoresizingMaskIntoConstraints = false; toolbar.addSubview(v) }
        container.addSubview(toolbar)
        container.addSubview(wv)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 32),
            backButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 4),
            backButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            forwardButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            reloadButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 2),
            reloadButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            tf.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: 6),
            tf.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -6),
            tf.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            wv.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        self.view = container
        super.init()
        wv.navigationDelegate = self
        backButton.target = self; backButton.action = #selector(goBack)
        forwardButton.target = self; forwardButton.action = #selector(goForward)
        reloadButton.target = self; reloadButton.action = #selector(reload)
        tf.target = self; tf.action = #selector(goAddress)

        if let url = initialURL {
            navigate(to: url)
        } else {
            let blank = """
            <html><body style="background:#0a0e13;color:#cfd9e4;font:14px -apple-system">
            <h2>RemoteCode 2 Browser Surface</h2>
            <p>Enter a URL above. Local dev URLs (localhost) and file:// URLs are allowed.</p>
            </body></html>
            """
            webView.loadHTMLString(blank, baseURL: nil)
        }
    }

    public func navigate(to url: URL) {
        addressBar.stringValue = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
    @objc private func reload() { webView.reload() }
    @objc private func goAddress() {
        var s = addressBar.stringValue.trimmingCharacters(in: .whitespaces)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s) else { return }
        navigate(to: url)
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url { addressBar.stringValue = url.absoluteString }
        if let title = webView.title, !title.isEmpty {
            descriptor.title = title
        }
    }

    // MARK: Surface

    public func focus() { view.window?.makeFirstResponder(webView) }
    public func unfocus() {}
    public func close() { webView.stopLoading() }
    public func sendText(_ text: String) { /* not applicable for browser */ }
    public func readText() -> String { webView.url?.absoluteString ?? "" }
    public func snapshot() -> [String: String] {
        ["url": webView.url?.absoluteString ?? "", "title": webView.title ?? ""]
    }
}
