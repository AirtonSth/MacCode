import Foundation
import AppKit
import WebKit
import CoreModel
import DesignSystemKit

@MainActor
public final class BrowserSurface: NSObject, Surface, WKNavigationDelegate {
    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    private let webView: WKWebView
    private let addressBar: NSTextField
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private var googleLegacyLayoutReloads = Set<String>()

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
        for (b, glyph) in [(backButton, "chevron.backward"), (forwardButton, "chevron.forward"), (reloadButton, "arrow.clockwise")] {
            b.isBordered = false
            b.bezelStyle = .inline
            b.image = NSImage(systemSymbolName: glyph, accessibilityDescription: glyph)
            b.contentTintColor = DS.NS.textSecondary
            b.imageScaling = .scaleProportionallyDown
        }

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

        container.wantsLayer = true
        container.layer?.backgroundColor = DS.NS.bg.cgColor
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
            <html><body style="background:#0F1419;color:#9DA9B5;font:14px/1.6 -apple-system;display:flex;align-items:center;justify-content:center;height:90vh;margin:0">
            <div style="text-align:center;max-width:420px">
            <div style="font-size:34px;margin-bottom:12px">🌐</div>
            <h2 style="color:#E7EDF3;font-weight:600;font-size:18px">Browser surface</h2>
            <p>Enter a URL above. Local dev URLs (localhost) and file:// URLs are allowed.</p>
            </div></body></html>
            """
            webView.loadHTMLString(blank, baseURL: nil)
        }
    }

    public func navigate(to url: URL) {
        addressBar.stringValue = url.absoluteString
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
        func poll() {
            let probe = "(function(){ return document.querySelector(`\(escaped)`) ? true : false; })()"
            self.evaluate(probe) { value, _ in
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
        reloadGoogleOnceAfterClearingLegacyLayoutCookie()
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
    public func close() { webView.stopLoading() }
    public func sendText(_ text: String) { /* not applicable for browser */ }
    public func readText() -> String { webView.url?.absoluteString ?? "" }
    public func snapshot() -> [String: String] {
        ["url": webView.url?.absoluteString ?? "", "title": webView.title ?? ""]
    }
}
