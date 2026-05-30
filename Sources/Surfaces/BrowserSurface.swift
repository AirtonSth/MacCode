import Foundation
import AppKit
import WebKit
import CoreModel
import DesignSystemKit
import os

@MainActor
public final class BrowserSurface: NSObject, Surface, WKNavigationDelegate, WKUIDelegate {
    public static let defaultInitialURLString = "https://www.remotecode.io/from-app"

    // Structured navigation/diagnostics logging (QA-MAC_BROWSER-006) so mirror
    // desyncs and field load failures are traceable. URLs are %{public}-omitted
    // by default to avoid leaking browsed addresses; only outcomes/codes log.
    private static let log = Logger(subsystem: "io.remotecode.app", category: "browser")

    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    private let webView: WKWebView
    private let addressBar: NSTextField
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let openExternalButton = NSButton()
    private let progressBar = NSProgressIndicator()
    private let findBar = NSView()
    private let findField = NSTextField()
    private let findPrevButton = NSButton()
    private let findNextButton = NSButton()
    private let findCloseButton = NSButton()
    private let errorOverlay = NSView()
    private let errorLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton()
    private var googleLegacyLayoutReloads = Set<String>()
    private var googleLegacyLayoutReloadOrder: [String] = []
    private static let googleLegacyLayoutReloadCap = 32
    private var retainedURL: URL?
    private var isVisible = true
    /// Test-only read of the hidden/visible gate (QA-MAC_BROWSER-004) so tests
    /// can assert the "navigate while hidden is deferred" contract directly.
    var isVisibleForTesting: Bool { isVisible }
    private var progressObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?
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
        wv.setAccessibilityIdentifier("browser.webview")
        self.webView = wv

        let tf = NSTextField()
        tf.placeholderString = "Search or enter address"
        tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tf.drawsBackground = true
        tf.backgroundColor = DS.NS.surfaceRaised
        tf.textColor = DS.NS.text
        tf.bezelStyle = .roundedBezel
        tf.focusRingType = .none
        tf.setAccessibilityIdentifier("browser.url-field")
        tf.setAccessibilityLabel("Address")
        self.addressBar = tf

        let toolbar = NSView()
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = DS.NS.surface.cgColor
        for (b, glyph, help, axID) in [
            (backButton, "chevron.backward", "Back", "browser.back"),
            (forwardButton, "chevron.forward", "Forward", "browser.forward"),
            (reloadButton, "arrow.clockwise", "Reload", "browser.reload"),
            (openExternalButton, "arrow.up.forward.square", "Open in Default Browser", "browser.open-external")
        ] {
            b.isBordered = false
            b.bezelStyle = .inline
            b.image = NSImage(systemSymbolName: glyph, accessibilityDescription: help)
            b.contentTintColor = DS.NS.textSecondary
            b.imageScaling = .scaleProportionallyDown
            b.toolTip = help
            b.setAccessibilityIdentifier(axID)
            b.setAccessibilityLabel(help)
        }

        let container = BrowserContainerView()
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

        // In-page Find bar (UX-MAC_BROWSER-010), shown on Cmd-F over the webView.
        findBar.wantsLayer = true
        findBar.layer?.backgroundColor = DS.NS.surface.cgColor
        findBar.isHidden = true
        findBar.setAccessibilityIdentifier("browser.find-bar")
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findField.placeholderString = "Find on page"
        findField.bezelStyle = .roundedBezel
        findField.focusRingType = .none
        findField.setAccessibilityIdentifier("browser.find-field")
        findField.setAccessibilityLabel("Find on page")
        findField.translatesAutoresizingMaskIntoConstraints = false
        for (b, glyph, help, axID) in [
            (findPrevButton, "chevron.up", "Previous match", "browser.find-prev"),
            (findNextButton, "chevron.down", "Next match", "browser.find-next"),
            (findCloseButton, "xmark", "Close find", "browser.find-close")
        ] {
            b.isBordered = false
            b.bezelStyle = .inline
            b.image = NSImage(systemSymbolName: glyph, accessibilityDescription: help)
            b.contentTintColor = DS.NS.textSecondary
            b.imageScaling = .scaleProportionallyDown
            b.toolTip = help
            b.setAccessibilityIdentifier(axID)
            b.setAccessibilityLabel(help)
        }
        let findStack = NSStackView(views: [findField, findPrevButton, findNextButton, findCloseButton])
        findStack.orientation = .horizontal
        findStack.spacing = 4
        findStack.translatesAutoresizingMaskIntoConstraints = false
        findBar.addSubview(findStack)
        container.addSubview(findBar)
        NSLayoutConstraint.activate([
            findBar.trailingAnchor.constraint(equalTo: wv.trailingAnchor, constant: -12),
            findBar.topAnchor.constraint(equalTo: wv.topAnchor, constant: 8),
            findStack.topAnchor.constraint(equalTo: findBar.topAnchor, constant: 6),
            findStack.bottomAnchor.constraint(equalTo: findBar.bottomAnchor, constant: -6),
            findStack.leadingAnchor.constraint(equalTo: findBar.leadingAnchor, constant: 8),
            findStack.trailingAnchor.constraint(equalTo: findBar.trailingAnchor, constant: -8),
            findField.widthAnchor.constraint(equalToConstant: 180)
        ])

        errorOverlay.wantsLayer = true
        errorOverlay.layer?.backgroundColor = DS.NS.bg.cgColor
        errorOverlay.isHidden = true
        errorOverlay.setAccessibilityIdentifier("browser.error-overlay")
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
        retryButton.setAccessibilityIdentifier("browser.error-retry")
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
        wv.uiDelegate = self
        backButton.target = self; backButton.action = #selector(goBack)
        forwardButton.target = self; forwardButton.action = #selector(goForward)
        reloadButton.target = self; reloadButton.action = #selector(reload)
        openExternalButton.target = self; openExternalButton.action = #selector(openInDefaultBrowser)
        retryButton.target = self; retryButton.action = #selector(reload)
        tf.target = self; tf.action = #selector(goAddress)
        findField.target = self; findField.action = #selector(findNext)
        findPrevButton.target = self; findPrevButton.action = #selector(findPrev)
        findNextButton.target = self; findNextButton.action = #selector(findNext)
        findCloseButton.target = self; findCloseButton.action = #selector(closeFind)
        container.onFocusAddressBar = { [weak self] in self?.focusAddressBar() }
        container.onShowFind = { [weak self] in self?.showFind() }
        container.onEscape = { [weak self] in self?.closeFind() }
        container.onZoomIn = { [weak self] in self?.adjustZoom(by: 0.1) }
        container.onZoomOut = { [weak self] in self?.adjustZoom(by: -0.1) }
        container.onZoomReset = { [weak self] in self?.resetZoom() }

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
        // Push title changes to the iOS mirror as they happen (IMP-MAC_BROWSER-011),
        // not just on didFinish, so the mirror shows the human title between
        // SPA navigations that never fire a fresh navigation finish.
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                guard let self, let url = webView.url else { return }
                self.publishNavigationChange(url: url, title: webView.title)
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

    // Computed once per process: installedSafariVersion() walks bundle/plist
    // disk paths, and the result is identical for every surface (PERF-003).
    private static let cachedSafariUserAgent: String = safariLikeUserAgent(
        safariVersion: installedSafariVersion() ?? "17.0"
    )

    private static func currentSafariUserAgent() -> String {
        cachedSafariUserAgent
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
        let s = string.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return false }
        guard let u = Self.resolveURL(from: s) else { return false }
        navigate(to: u)
        return true
    }

    /// Maps raw address-bar input to a URL. Scheme-less input that looks like
    /// a host (has a dot, no spaces) is treated as `https://…`; anything else
    /// (e.g. "weather tomorrow") becomes a search query against the default
    /// engine — matching Safari/Chrome omnibox behavior.
    static func resolveURL(from input: String) -> URL? {
        let s = input.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if s.contains("://") { return URL(string: s) }
        let looksLikeHost = !s.contains(" ") && s.contains(".")
        if looksLikeHost, let u = URL(string: "https://" + s) {
            return u
        }
        let q = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        return URL(string: "https://www.google.com/search?q=\(q)")
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
          // Reset refs each snapshot so detached DOM nodes from prior
          // snapshots can be GC'd (PERF-008) instead of accumulating.
          window.__rc2 = { refs: new Map(), counter: 0 };
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
          // Cap emitted elements so the JSON payload ferried to iOS over RPC
          // stays bounded on huge DOMs (PERF-007); flag when truncated.
          const MAX = 1500;
          let truncated = false;
          for (const el of document.querySelectorAll('*')) {
            if (out.length >= MAX) { truncated = true; break; }
            if (!isVisible(el) || !interactable(el)) continue;
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
          }
          return JSON.stringify({ url: location.href, title: document.title, truncated, elements: out });
        })()
        """#
        evaluate(js) { value, error in
            if let s = value as? String { completion(s) }
            else {
                Self.log.error("snapshot eval failed err=\(error?.localizedDescription ?? "nil", privacy: .public)")
                completion("{\"error\":\"snapshot failed\"}")
            }
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
        _ = navigate(string: addressBar.stringValue)
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
        Self.log.debug("nav start host=\(webView.url?.host ?? "?", privacy: .public)")
        hideError()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Self.log.debug("nav finish host=\(webView.url?.host ?? "?", privacy: .public)")
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
        Self.log.error("nav fail domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public)")
        showError(error.localizedDescription)
        updateNavigationButtons()
    }

    // MARK: WKUIDelegate

    /// target=_blank / window.open links have no destination view in a
    /// single-webView surface, so WKWebView silently drops them
    /// (UX-MAC_BROWSER-012). Load the request in this view instead.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    // IMP-MAC_BROWSER-008/012 (link/page context menu) reverted: the iOS-only
    // `contextMenuConfigurationForElement`/`WKContextMenuElementInfo` API does
    // not exist on macOS WKWebView. A macOS-correct version needs NSMenu
    // customization via the view's `willOpenMenu`/`menu(for:)` path — deferred.

    public func publishNavigationChange(url: URL, title: String?) {
        descriptor.metadata["url"] = url.absoluteString
        if let title, !title.isEmpty {
            descriptor.title = title
        }
        onNavigationChange?(descriptor.id, url.absoluteString, title)
    }

    // Bounded insert (PERF-005): the reload-dedup set previously grew without
    // limit for every distinct Google URL the tab ever visited. Cap it and
    // evict oldest so membership stays O(1) and memory stays flat.
    private func recordGoogleLegacyLayoutReload(_ key: String) {
        guard googleLegacyLayoutReloads.insert(key).inserted else { return }
        Self.log.debug("google legacy-layout reload count=\(self.googleLegacyLayoutReloads.count, privacy: .public)")
        googleLegacyLayoutReloadOrder.append(key)
        if googleLegacyLayoutReloadOrder.count > Self.googleLegacyLayoutReloadCap {
            let evicted = googleLegacyLayoutReloadOrder.removeFirst()
            googleLegacyLayoutReloads.remove(evicted)
        }
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
            self.recordGoogleLegacyLayoutReload(key)
            self.webView.reload()
        }
    }

    // MARK: Surface

    /// Drives the tab spinner during page loads (UX-MAC_BROWSER-008) via the
    /// existing Surface.isBusy hook the tab/sidebar views already read.
    public var isBusy: Bool { webView.isLoading }
    public func focus() { view.window?.makeFirstResponder(webView) }
    public func focusAddressBar() {
        view.window?.makeFirstResponder(addressBar)
        addressBar.currentEditor()?.selectAll(nil)
    }

    private func showFind() {
        findBar.isHidden = false
        view.window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
    }

    @objc private func closeFind() {
        guard !findBar.isHidden else { return }
        findBar.isHidden = true
        view.window?.makeFirstResponder(webView)
    }

    @objc private func findNext() { runFind(forward: true) }
    @objc private func findPrev() { runFind(forward: false) }

    private func runFind(forward: Bool) {
        let query = findField.stringValue
        guard !query.isEmpty else { return }
        let cfg = WKFindConfiguration()
        cfg.backwards = !forward
        cfg.caseSensitive = false
        cfg.wraps = true
        webView.find(query, configuration: cfg) { _ in }
    }

    /// Cmd-+/Cmd-- adjust page zoom; Cmd-0 resets (IMP-MAC_BROWSER-007).
    /// Clamped to a sane range so content never collapses or runs away.
    private func adjustZoom(by delta: CGFloat) {
        webView.pageZoom = min(3.0, max(0.5, webView.pageZoom + delta))
    }
    private func resetZoom() {
        webView.pageZoom = 1.0
    }
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
        titleObservation?.invalidate()
        titleObservation = nil
        onNavigationChange = nil
        externalURLOpener = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
    }
    public func sendText(_ text: String) { /* not applicable for browser */ }
    public func readText() -> String { webView.url?.absoluteString ?? "" }
    public func snapshot() -> [String: String] {
        ["url": webView.url?.absoluteString ?? "", "title": webView.title ?? ""]
    }
}

/// Container view that intercepts Cmd-L to focus the address bar, giving
/// keyboard users a way to reach the URL field (UX-MAC_BROWSER-006).
private final class BrowserContainerView: NSView {
    var onFocusAddressBar: (() -> Void)?
    var onShowFind: (() -> Void)?
    var onEscape: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomReset: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command || mods == [.command, .shift] {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "l": onFocusAddressBar?(); return true
            case "f": onShowFind?(); return true
            // Cmd-= and Cmd-+ zoom in (the + key is shift-=), Cmd-- zooms out,
            // Cmd-0 resets (IMP-MAC_BROWSER-007).
            case "=", "+": onZoomIn?(); return true
            case "-": onZoomOut?(); return true
            case "0": onZoomReset?(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Escape (keyCode 53) dismisses the find bar.
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}
