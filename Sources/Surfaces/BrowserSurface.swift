import Foundation
import AppKit
import WebKit
import CoreModel
import DesignSystemKit

@MainActor
public final class BrowserSurface: NSObject, Surface, WKNavigationDelegate {
    public static let defaultInitialURLString = "https://www.remotecode.io/from-app"

    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    private let webView: WKWebView
    private let addressBar: NSTextField
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let openExternalButton = NSButton()
    private let progressBar = NSProgressIndicator()
    private let errorOverlay = NSView()
    private let errorLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton()
    private var googleLegacyLayoutReloads = Set<String>()
    private var retainedURL: URL?
    private var isVisible = true
    private var progressObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    private var waitForToken = 0
    private var isClosed = false
    public var onNavigationChange: ((SurfaceID, String, String?) -> Void)?
    public var externalURLOpener: ((URL) -> Void)?

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
        wv.customUserAgent = Self.currentSafariUserAgent()
        self.webView = wv

        let tf = NSTextField()
        tf.placeholderString = "Enter URL and press Return"
        tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tf.drawsBackground = true
        tf.backgroundColor = DS.NS.surfaceRaised
        tf.textColor = DS.NS.text
        tf.bezelStyle = .roundedBezel
        tf.focusRingType = .none
        self.addressBar = tf

        let toolbar = NSView()
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = DS.NS.surface.cgColor
        for (b, glyph, help) in [
            (backButton, "chevron.backward", "Back"),
            (forwardButton, "chevron.forward", "Forward"),
            (reloadButton, "arrow.clockwise", "Reload"),
            (openExternalButton, "arrow.up.forward.square", "Open in Default Browser")
        ] {
            b.isBordered = false
            b.bezelStyle = .inline
            b.image = NSImage(systemSymbolName: glyph, accessibilityDescription: help)
            b.contentTintColor = DS.NS.textSecondary
            b.imageScaling = .scaleProportionallyDown
            b.toolTip = help
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        for v in [toolbar, wv] { v.translatesAutoresizingMaskIntoConstraints = false }
        for v in [backButton, forwardButton, reloadButton, tf, openExternalButton] { v.translatesAutoresizingMaskIntoConstraints = false; toolbar.addSubview(v) }
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
            tf.trailingAnchor.constraint(equalTo: openExternalButton.leadingAnchor, constant: -6),
            tf.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            openExternalButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -6),
            openExternalButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            wv.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let toolbarDivider = NSView()
        toolbarDivider.wantsLayer = true
        toolbarDivider.layer?.backgroundColor = DS.NS.line.cgColor
        toolbarDivider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolbarDivider)
        NSLayoutConstraint.activate([
            toolbarDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbarDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbarDivider.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbarDivider.heightAnchor.constraint(equalToConstant: 1)
        ])

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.isHidden = true
        progressBar.controlSize = .small
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(progressBar)
        NSLayoutConstraint.activate([
            progressBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: toolbarDivider.bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2)
        ])

        errorOverlay.wantsLayer = true
        errorOverlay.layer?.backgroundColor = DS.NS.bg.cgColor
        errorOverlay.isHidden = true
        errorOverlay.translatesAutoresizingMaskIntoConstraints = false
        let errorIcon = NSImageView()
        errorIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Error")
        errorIcon.contentTintColor = DS.NS.textSecondary
        errorIcon.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.alignment = .center
        errorLabel.maximumNumberOfLines = 0
        errorLabel.textColor = DS.NS.text
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        retryButton.title = "Retry"
        retryButton.bezelStyle = .rounded
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        let errorStack = NSStackView(views: [errorIcon, errorLabel, retryButton])
        errorStack.orientation = .vertical
        errorStack.alignment = .centerX
        errorStack.spacing = 12
        errorStack.translatesAutoresizingMaskIntoConstraints = false
        errorOverlay.addSubview(errorStack)
        container.addSubview(errorOverlay)
        NSLayoutConstraint.activate([
            errorOverlay.topAnchor.constraint(equalTo: wv.topAnchor),
            errorOverlay.leadingAnchor.constraint(equalTo: wv.leadingAnchor),
            errorOverlay.trailingAnchor.constraint(equalTo: wv.trailingAnchor),
            errorOverlay.bottomAnchor.constraint(equalTo: wv.bottomAnchor),
            errorStack.centerXAnchor.constraint(equalTo: errorOverlay.centerXAnchor),
            errorStack.centerYAnchor.constraint(equalTo: errorOverlay.centerYAnchor),
            errorStack.leadingAnchor.constraint(greaterThanOrEqualTo: errorOverlay.leadingAnchor, constant: 24),
            errorStack.trailingAnchor.constraint(lessThanOrEqualTo: errorOverlay.trailingAnchor, constant: -24),
            errorIcon.widthAnchor.constraint(equalToConstant: 32),
            errorIcon.heightAnchor.constraint(equalToConstant: 32)
        ])

        container.wantsLayer = true
        container.layer?.backgroundColor = DS.NS.bg.cgColor
        self.view = container
        super.init()
        wv.navigationDelegate = self
        backButton.target = self; backButton.action = #selector(goBack)
        forwardButton.target = self; forwardButton.action = #selector(goForward)
        reloadButton.target = self; reloadButton.action = #selector(reload)
        openExternalButton.target = self; openExternalButton.action = #selector(openInDefaultBrowser)
        retryButton.target = self; retryButton.action = #selector(reload)
        tf.target = self; tf.action = #selector(goAddress)

        backButton.isEnabled = false
        forwardButton.isEnabled = false
        observeLoadingState()

        navigate(to: initialURL ?? Self.defaultInitialURL)
    }

    private func observeLoadingState() {
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.progressBar.doubleValue = webView.estimatedProgress
            }
        }
        loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateLoadingChrome(isLoading: webView.isLoading)
            }
        }
    }

    private func updateLoadingChrome(isLoading: Bool) {
        if isLoading {
            progressBar.isHidden = false
            reloadButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Stop")
            reloadButton.toolTip = "Stop"
        } else {
            progressBar.isHidden = true
            progressBar.doubleValue = 0
            reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
            reloadButton.toolTip = "Reload"
        }
        updateNavigationButtons()
    }

    private func updateNavigationButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
        backButton.contentTintColor = webView.canGoBack ? DS.NS.textSecondary : DS.NS.textSecondary.withAlphaComponent(0.35)
        forwardButton.contentTintColor = webView.canGoForward ? DS.NS.textSecondary : DS.NS.textSecondary.withAlphaComponent(0.35)
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorOverlay.isHidden = false
    }

    private func hideError() {
        errorOverlay.isHidden = true
    }

    public static var defaultInitialURL: URL {
        URL(string: defaultInitialURLString)!
    }

    static func normalizedInitialURL(_ url: URL?) -> URL {
        guard let url else { return defaultInitialURL }
        return isAboutBlank(url) ? defaultInitialURL : url
    }

    private static func isAboutBlank(_ url: URL) -> Bool {
        url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "about:blank"
    }

    public func navigate(to url: URL) {
        let url = Self.normalizedInitialURL(url)
        retainedURL = url
        addressBar.stringValue = url.absoluteString
        hideError()
        waitForToken &+= 1
        guard isVisible else { return }
        webView.load(URLRequest(url: url))
        if Self.isGoogleHost(url.host) {
            scheduleGoogleLegacyLayoutRefresh(for: url.absoluteString)
        }
    }

    static func safariLikeUserAgent(safariVersion: String) -> String {
        let osToken = "10_15_7"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X \(osToken)) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Safari/605.1.15"
    }

    static func isGoogleHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "google.com" || host.hasSuffix(".google.com")
    }

    private static func currentSafariUserAgent() -> String {
        safariLikeUserAgent(
            safariVersion: installedSafariVersion() ?? "17.0"
        )
    }

    private static func installedSafariVersion() -> String? {
        let paths = [
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app",
            "/Applications/Safari.app"
        ]
        for path in paths {
            if let bundle = Bundle(path: path),
               let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               !version.isEmpty {
                return version
            }
        }
        return nil
    }

    public func navigate(string: String) -> Bool {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return false }
        if !s.contains("://") { s = "https://" + s }
        guard let u = URL(string: s) else { return false }
        navigate(to: u)
        return true
    }

    public func currentURL() -> String { webView.url?.absoluteString ?? "" }
    public func currentTitle() -> String { webView.title ?? "" }
    public func goBackAction() { webView.goBack() }
    public func goForwardAction() { webView.goForward() }
    public func reloadAction() { webView.reload() }
    public func openInDefaultBrowserAction() { openCurrentURLInDefaultBrowser() }

    public func evaluate(_ js: String, completion: @escaping (Any?, Error?) -> Void) {
        webView.evaluateJavaScript(js, completionHandler: completion)
    }

    /// Returns an array of {ref, tag, text, role, attrs} for all visible
    /// elements that look interactable. ref is a stable per-snapshot id
    /// the browser stores on a WeakMap so subsequent click/fill calls can
    /// resolve to the same node even if the DOM is reshuffled.
    public func snapshot(completion: @escaping (String) -> Void) {
        let js = #"""
        (function(){
          window.__rc2 = window.__rc2 || { refs: new Map(), counter: 0 };
          const out = [];
          const isVisible = (el) => {
            if (!el) return false;
            const s = getComputedStyle(el);
            if (s.display === 'none' || s.visibility === 'hidden' || s.opacity === '0') return false;
            const r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          };
          const interactable = (el) => {
            const t = el.tagName;
            if (['A','BUTTON','INPUT','TEXTAREA','SELECT','LABEL','SUMMARY'].includes(t)) return true;
            if (el.getAttribute('role')) return true;
            if (el.onclick) return true;
            if (el.getAttribute('contenteditable') === 'true') return true;
            return false;
          };
          document.querySelectorAll('*').forEach(el => {
            if (!isVisible(el) || !interactable(el)) return;
            const ref = 'rc2-' + (++window.__rc2.counter);
            window.__rc2.refs.set(ref, el);
            out.push({
              ref,
              tag: el.tagName,
              text: (el.innerText || '').slice(0, 200),
              role: el.getAttribute('role') || null,
              name: el.getAttribute('name') || null,
              type: el.getAttribute('type') || null,
              placeholder: el.getAttribute('placeholder') || null,
              href: el.tagName === 'A' ? el.getAttribute('href') : null,
              value: ('value' in el) ? el.value : null,
              bounding: (() => { const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height }; })()
            });
          });
          return JSON.stringify({ url: location.href, title: document.title, elements: out });
        })()
        """#
        evaluate(js) { value, _ in
            if let s = value as? String { completion(s) }
            else { completion("{\"error\":\"snapshot failed\"}") }
        }
    }

    public func performAction(_ kind: String, ref: String, value: String?, completion: @escaping (String) -> Void) {
        let val = (value ?? "").replacingOccurrences(of: "`", with: "\\`")
        let js = """
        (function(){
          const ref = "\(ref)";
          if (!window.__rc2 || !window.__rc2.refs.has(ref)) {
            return JSON.stringify({ ok: false, error: 'ref not found; call snapshot first' });
          }
          const el = window.__rc2.refs.get(ref);
          try {
            switch ("\(kind)") {
              case 'click':
                el.click();
                break;
              case 'focus':
                el.focus();
                break;
              case 'fill':
                el.focus();
                if ('value' in el) {
                  el.value = `\(val)`;
                  el.dispatchEvent(new Event('input', { bubbles: true }));
                  el.dispatchEvent(new Event('change', { bubbles: true }));
                } else if (el.isContentEditable) {
                  el.textContent = `\(val)`;
                }
                break;
              case 'type':
                el.focus();
                const txt = `\(val)`;
                for (const ch of txt) {
                  el.dispatchEvent(new KeyboardEvent('keydown', { key: ch, bubbles: true }));
                  if ('value' in el) el.value += ch;
                  el.dispatchEvent(new InputEvent('input', { data: ch, bubbles: true }));
                  el.dispatchEvent(new KeyboardEvent('keyup', { key: ch, bubbles: true }));
                }
                el.dispatchEvent(new Event('change', { bubbles: true }));
                break;
              case 'check':
                el.checked = true;
                el.dispatchEvent(new Event('change', { bubbles: true }));
                break;
              case 'uncheck':
                el.checked = false;
                el.dispatchEvent(new Event('change', { bubbles: true }));
                break;
              case 'select':
                if (el.tagName === 'SELECT') {
                  el.value = `\(val)`;
                  el.dispatchEvent(new Event('change', { bubbles: true }));
                }
                break;
              case 'hover':
                el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
                break;
            }
            return JSON.stringify({ ok: true });
          } catch (e) {
            return JSON.stringify({ ok: false, error: String(e) });
          }
        })()
        """
        evaluate(js) { value, _ in
            if let s = value as? String { completion(s) } else { completion("{\"ok\":false}") }
        }
    }

    public func waitFor(_ selector: String, timeoutMs: Int, completion: @escaping (String) -> Void) {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000.0)
        let escaped = selector.replacingOccurrences(of: "`", with: "\\`")
        waitForToken &+= 1
        let token = waitForToken
        func poll() {
            let probe = "(function(){ return document.querySelector(`\(escaped)`) ? true : false; })()"
            self.evaluate(probe) { [weak self] value, _ in
                guard let self, !self.isClosed, self.waitForToken == token else {
                    completion("{\"ok\":false,\"error\":\"cancelled\"}")
                    return
                }
                if (value as? Bool) == true {
                    completion("{\"ok\":true}")
                } else if Date() > deadline {
                    completion("{\"ok\":false,\"error\":\"timeout\"}")
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
                }
            }
        }
        poll()
    }

    public func screenshotPNG() -> Data? {
        let bounds = webView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        guard let rep = webView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        webView.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
    @objc private func reload() {
        if webView.isLoading {
            webView.stopLoading()
        } else {
            hideError()
            webView.reload()
        }
    }
    @objc private func openInDefaultBrowser() { openCurrentURLInDefaultBrowser() }
    @objc private func goAddress() {
        var s = addressBar.stringValue.trimmingCharacters(in: .whitespaces)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s) else { return }
        navigate(to: url)
    }

    private func openCurrentURLInDefaultBrowser() {
        guard let url = webView.url ?? retainedURL ?? URL(string: addressBar.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
        if let externalURLOpener {
            externalURLOpener(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        hideError()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url {
            addressBar.stringValue = url.absoluteString
            publishNavigationChange(url: url, title: webView.title)
        }
        hideError()
        updateNavigationButtons()
        reloadGoogleOnceAfterClearingLegacyLayoutCookie()
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error)
    }

    private func handleNavigationFailure(_ error: Error) {
        let ns = error as NSError
        // Ignore user/programmatic cancellations (e.g. stopLoading, new navigation superseding this one).
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        showError(error.localizedDescription)
        updateNavigationButtons()
    }

    public func publishNavigationChange(url: URL, title: String?) {
        descriptor.metadata["url"] = url.absoluteString
        if let title, !title.isEmpty {
            descriptor.title = title
        }
        onNavigationChange?(descriptor.id, url.absoluteString, title)
    }

    private func scheduleGoogleLegacyLayoutRefresh(for key: String) {
        guard !googleLegacyLayoutReloads.contains(key) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self,
                  self.webView.url?.absoluteString == key,
                  !self.googleLegacyLayoutReloads.contains(key) else { return }
            self.expireGoogleLegacyLayoutCookieAndReload(key: key)
        }
    }

    private func reloadGoogleOnceAfterClearingLegacyLayoutCookie() {
        guard let url = webView.url, Self.isGoogleHost(url.host) else { return }
        let key = url.absoluteString
        guard !googleLegacyLayoutReloads.contains(key) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.webView.url?.absoluteString == key else { return }
            self.expireGoogleLegacyLayoutCookieAndReload(key: key)
        }
    }

    private func expireGoogleLegacyLayoutCookieAndReload(key: String) {
        let js = "document.cookie='__Secure-STRP=; Max-Age=0; path=/; domain=.google.com; Secure'"
        evaluate(js) { [weak self] _, _ in
            guard let self, self.webView.url?.absoluteString == key else { return }
            self.googleLegacyLayoutReloads.insert(key)
            self.webView.reload()
        }
    }

    // MARK: Surface

    public func focus() { view.window?.makeFirstResponder(webView) }
    public func unfocus() {}
    public func didBecomeVisible() {
        guard !isVisible else { return }
        isVisible = true
        // The webView stayed resident while hidden (WebKit suspends the
        // offscreen process), so scroll/forms/history survive. Only load
        // fresh content if nothing is loaded yet, or a navigate() arrived
        // while hidden and was deferred (retainedURL diverged from the
        // resident page).
        if webView.url == nil {
            navigate(to: retainedURL ?? Self.defaultInitialURL)
        } else if let pending = retainedURL, pending != webView.url {
            navigate(to: pending)
        }
    }
    public func didBecomeHidden() {
        guard isVisible else { return }
        isVisible = false
        retainedURL = webView.url ?? retainedURL
        // Keep the document resident; WebKit suspends the offscreen web
        // process. Blanking + reloading on every tab switch destroyed
        // scroll position, form input, and back/forward history.
    }
    public func close() {
        isClosed = true
        waitForToken &+= 1
        progressObservation?.invalidate()
        progressObservation = nil
        loadingObservation?.invalidate()
        loadingObservation = nil
        onNavigationChange = nil
        webView.navigationDelegate = nil
        webView.stopLoading()
    }
    public func sendText(_ text: String) { /* not applicable for browser */ }
    public func readText() -> String { webView.url?.absoluteString ?? "" }
    public func snapshot() -> [String: String] {
        ["url": webView.url?.absoluteString ?? "", "title": webView.title ?? ""]
    }
}
