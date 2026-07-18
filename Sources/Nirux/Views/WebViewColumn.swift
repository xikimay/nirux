import AppKit
import WebKit

/// A WKWebView column with navigation bar, integrated into Nirux's niri scroll.
@MainActor
final class WebViewColumn: NSView, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private let navBar: NSView
    private let backBtn: NSButton
    private let fwdBtn: NSButton
    private let reloadBtn: NSButton
    private let urlField: NSTextField
    private let progressBar: NSView
    private(set) var currentURL: String = ""
    private(set) var pageTitle: String = ""
    private var observations: [NSKeyValueObservation] = []
    /// Destination URLs of in-flight downloads, for the completion
    /// notification's reveal-in-Finder action.
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    private static let barHeight: CGFloat = 32
    private static let barBg = NSColor(red: 0.13, green: 0.13, blue: 0.17, alpha: 1)
    private static let fieldBg = NSColor(red: 0.18, green: 0.18, blue: 0.22, alpha: 1)
    private static let accent: NSColor = .niruxAccent

    /// Shared data store — all WebViews share the same cookies
    static let sharedDataStore = WKWebsiteDataStore.default()

    init(url: String) {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.websiteDataStore = Self.sharedDataStore

        // Allow media playback
        config.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: .zero, configuration: config)
        navBar = NSView()
        backBtn = NSButton()
        fwdBtn = NSButton()
        reloadBtn = NSButton()
        urlField = NSTextField()
        progressBar = NSView()

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1).cgColor

        setupNavBar()
        setupProgressBar()
        setupWebView()
        navigate(to: url)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupNavBar() {
        navBar.wantsLayer = true
        navBar.layer?.backgroundColor = Self.barBg.cgColor
        addSubview(navBar)

        // Back button
        configureNavButton(backBtn, symbol: "◀", action: #selector(goBackAction))
        backBtn.isEnabled = false
        navBar.addSubview(backBtn)

        // Forward button
        configureNavButton(fwdBtn, symbol: "▶", action: #selector(goForwardAction))
        fwdBtn.isEnabled = false
        navBar.addSubview(fwdBtn)

        // Reload button
        configureNavButton(reloadBtn, symbol: "↻", action: #selector(reloadAction))
        navBar.addSubview(reloadBtn)

        // URL field
        urlField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        urlField.textColor = .white
        urlField.backgroundColor = Self.fieldBg
        urlField.isBezeled = false
        urlField.focusRingType = .none
        urlField.drawsBackground = true
        urlField.isEditable = true
        urlField.placeholderString = "Enter URL..."
        urlField.cell?.wraps = false
        urlField.cell?.isScrollable = true
        urlField.cell?.usesSingleLineMode = true
        urlField.target = self
        urlField.action = #selector(urlFieldAction)
        urlField.wantsLayer = true
        urlField.layer?.cornerRadius = 4
        navBar.addSubview(urlField)
    }

    private func configureNavButton(_ btn: NSButton, symbol: String, action: Selector) {
        btn.title = symbol
        btn.bezelStyle = .accessoryBarAction
        btn.isBordered = false
        btn.font = .systemFont(ofSize: 14)
        btn.contentTintColor = .secondaryLabelColor
        btn.target = self
        btn.action = action
    }

    private func setupProgressBar() {
        progressBar.wantsLayer = true
        progressBar.layer?.backgroundColor = Self.accent.cgColor
        progressBar.isHidden = true
        addSubview(progressBar)
    }

    private func setupWebView() {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.underPageBackgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1)
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

        // Inject JS to look more like a real Chrome browser
        let antiDetectScript = WKUserScript(source: Self.antiDetectJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        webView.configuration.userContentController.addUserScript(antiDetectScript)
        addSubview(webView)

        observations = [
            webView.observe(\.estimatedProgress, options: .new) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let progress = wv.estimatedProgress
                    self.progressBar.isHidden = progress >= 1.0
                    self.progressBar.frame.size.width = self.bounds.width * progress
                }
            },
            webView.observe(\.title, options: .new) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.pageTitle = wv.title ?? ""
                }
            },
            webView.observe(\.url, options: .new) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = wv.url?.absoluteString else { return }
                    self.currentURL = url
                    self.urlField.stringValue = url
                }
            },
            webView.observe(\.canGoBack, options: .new) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.backBtn.isEnabled = wv.canGoBack
                    self?.backBtn.contentTintColor = wv.canGoBack ? .white : .tertiaryLabelColor
                }
            },
            webView.observe(\.canGoForward, options: .new) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.fwdBtn.isEnabled = wv.canGoForward
                    self?.fwdBtn.contentTintColor = wv.canGoForward ? .white : .tertiaryLabelColor
                }
            }
        ]
    }

    // MARK: - Layout

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutViews()
    }

    override func layout() {
        super.layout()
        layoutViews()
    }

    private func layoutViews() {
        let height = Self.barHeight
        let pad: CGFloat = 4
        let btnW: CGFloat = 28

        navBar.frame = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)

        // Buttons: back, forward, reload
        backBtn.frame = NSRect(x: pad, y: 4, width: btnW, height: height - 8)
        fwdBtn.frame = NSRect(x: pad + btnW, y: 4, width: btnW, height: height - 8)
        reloadBtn.frame = NSRect(x: pad + btnW * 2, y: 4, width: btnW, height: height - 8)

        // URL field fills the rest
        let fieldX = pad + btnW * 3 + 4
        urlField.frame = NSRect(x: fieldX, y: 5, width: bounds.width - fieldX - pad, height: height - 10)

        // Progress bar
        progressBar.frame = NSRect(x: 0, y: bounds.height - height - 2, width: 0, height: 2)

        // WebView fills below nav bar
        webView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - height - 2)
    }

    // MARK: - Navigation

    func navigate(to urlString: String) {
        var url = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.contains("://") {
            if url.contains(".") || url.hasPrefix("localhost") {
                url = "https://" + url
            } else {
                url = "https://www.google.com/search?q=" + (url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url)
            }
        }
        currentURL = url
        urlField.stringValue = url
        if let parsedURL = URL(string: url) {
            webView.load(URLRequest(url: parsedURL))
        }
    }

    @objc private func goBackAction() { webView.goBack() }
    @objc private func goForwardAction() { webView.goForward() }
    @objc private func reloadAction() { webView.reload() }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    /// Move keyboard focus to the URL field with the text selected (Cmd+L).
    func focusAddressBar() {
        window?.makeFirstResponder(urlField)
        urlField.selectText(nil)
    }

    /// Open the Web Inspector. WKWebView has no public API for this;
    /// developerExtrasEnabled is set, so `_showInspector` exists — guard the
    /// call so a future WebKit rename degrades to a no-op instead of a crash.
    func toggleInspector() {
        let inspector = Selector(("_showInspector"))
        if webView.responds(to: inspector) {
            webView.perform(inspector)
        }
    }

    @objc private func urlFieldAction() {
        navigate(to: urlField.stringValue)
        window?.makeFirstResponder(webView)
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.async { [weak self] in
            self?.progressBar.isHidden = true
            if let url = self?.currentURL, !url.isEmpty {
                URLHistory.add(url)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.progressBar.isHidden = true
        }
    }

    /// Responses WebKit can't display (archives, binaries, attachments)
    /// become downloads instead of failing silently. Signatures must match
    /// the WKNavigationDelegate requirements exactly (including the
    /// @MainActor @Sendable handler) or WebKit never calls them.
    @MainActor
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
        } else {
            decisionHandler(.download)
        }
    }

    @MainActor
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    @MainActor
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    @MainActor
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: - WKUIDelegate (popups, alerts, new windows)

    /// Handle target=_blank links and OAuth popups (Google Sign-In etc.)
    @MainActor func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Open in same webview instead of blocking
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    /// JS alert()
    @MainActor
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    /// JS confirm()
    @MainActor
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @Sendable (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    deinit {
        observations.removeAll()
    }

    // MARK: - Anti-detection JS

    private static var antiDetectJS: String {
        // Build languages list from system preferences
        let langs = Locale.preferredLanguages.prefix(4)
        let langsJS = langs.map { "'\($0)'" }.joined(separator: ", ")

        return """
        // Make navigator.webdriver undefined (bot detection)
        Object.defineProperty(navigator, 'webdriver', { get: () => undefined });

        // Add window.chrome object (Chrome detection)
        if (!window.chrome) {
            window.chrome = {
                runtime: {},
                loadTimes: function() {},
                csi: function() {},
                app: { isInstalled: false }
            };
        }

        // Fix navigator.vendor
        Object.defineProperty(navigator, 'vendor', { get: () => 'Google Inc.' });

        // Fix navigator.plugins (empty in WKWebView, Chrome has some)
        Object.defineProperty(navigator, 'plugins', {
            get: () => [1, 2, 3, 4, 5]
        });

        // Dynamic languages from system preferences
        Object.defineProperty(navigator, 'languages', {
            get: () => [\(langsJS)]
        });

        // Fix permissions API (some sites check this)
        if (navigator.permissions) {
            const origQuery = navigator.permissions.query;
            navigator.permissions.query = (params) => {
                if (params.name === 'notifications') {
                    return Promise.resolve({ state: 'prompt', onchange: null });
                }
                return origQuery.call(navigator.permissions, params);
            };
        }
        """
    }
}

// MARK: - WKDownloadDelegate

extension WebViewColumn: WKDownloadDelegate {
    /// Save to ~/Downloads with a unique name (foo.zip → foo-2.zip → …).
    @MainActor
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            completionHandler(nil)
            return
        }
        var destination = downloads.appendingPathComponent(suggestedFilename)
        let ext = destination.pathExtension
        let base = destination.deletingPathExtension().lastPathComponent
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            destination = downloads.appendingPathComponent(name)
            counter += 1
        }
        downloadDestinations[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    @MainActor
    func downloadDidFinish(_ download: WKDownload) {
        let destination = downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        NSLog("[WebViewColumn] download finished")
        if let destination {
            NiruxNotifier.shared.postDownloadFinished(
                filename: destination.lastPathComponent,
                fileURL: destination
            )
        } else if NSApp.isActive == false {
            // Surface completion when the app is in the background.
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    @MainActor
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        NSLog("[WebViewColumn] download failed: \(error.localizedDescription)")
    }
}

