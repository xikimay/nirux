import AppKit
import WebKit

/// A WKWebView column with its header (back, forward, reload, the address,
/// the Web Inspector), integrated into Nirux's niri scroll.
@MainActor
final class WebViewColumn: NSView, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let header = ColumnHeaderView()
    let backButton = ColumnHeaderButton(symbol: Theme.Symbol.back, toolTip: "Back")
    let forwardButton = ColumnHeaderButton(symbol: Theme.Symbol.forward, toolTip: "Forward")
    let reloadButton = ColumnHeaderButton(symbol: Theme.Symbol.reload, toolTip: "Reload")
    let inspectorButton = ColumnHeaderButton(symbol: Theme.Symbol.webInspector, toolTip: "Toggle Web Inspector")
    let urlField = AddressField()
    private let addressBox = AddressBox()
    private let progressBar: NSView
    private(set) var currentURL: String = "" {
        didSet { if currentURL != oldValue { onURLChanged?() } }
    }
    /// Fires when the displayed URL changes (navigation, redirects).
    var onURLChanged: (() -> Void)?
    private(set) var pageTitle: String = ""
    private var observations: [NSKeyValueObservation] = []
    /// Destination URLs of in-flight downloads, for the completion
    /// notification's reveal-in-Finder action.
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    private static let accent: NSColor = Theme.Color.accent

    /// Shared data store — all WebViews share the same cookies
    static let sharedDataStore = WKWebsiteDataStore.default()

    init(url: String) {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.websiteDataStore = Self.sharedDataStore

        // Allow media playback
        config.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: .zero, configuration: config)
        progressBar = NSView()

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.surface.cgColor

        setupHeader()
        setupProgressBar()
        setupWebView()
        navigate(to: url)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupHeader() {
        header.icon = .symbol(Theme.Symbol.browser)
        for (button, action) in [
            (backButton, #selector(goBackAction)), (forwardButton, #selector(goForwardAction)),
            (reloadButton, #selector(reloadAction)), (inspectorButton, #selector(inspectorAction))
        ] {
            button.target = self
            button.action = action
        }
        backButton.isEnabled = false
        forwardButton.isEnabled = false
        header.leadingButtons = [backButton, forwardButton, reloadButton]
        header.trailingButtons = [inspectorButton]
        header.menuProvider = {
            let menu = NSMenu()
            ColumnHeaderView.columnMenuItems().forEach(menu.addItem)
            return menu
        }

        urlField.placeholderString = "Enter URL..."
        urlField.target = self
        urlField.action = #selector(urlFieldAction)
        addressBox.field = urlField
        header.centerView = addressBox
        addSubview(header)
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
        webView.underPageBackgroundColor = Theme.Color.surface
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
                    self.urlField.url = url
                }
            },
            webView.observe(\.canGoBack, options: .new) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.backButton.isEnabled = wv.canGoBack
                }
            },
            webView.observe(\.canGoForward, options: .new) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.forwardButton.isEnabled = wv.canGoForward
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
        let height = ColumnHeaderView.height
        header.frame = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)

        // Progress bar
        progressBar.frame = NSRect(x: 0, y: bounds.height - height - 2, width: 0, height: 2)

        // WebView fills below the header
        webView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - height - 2))
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
        urlField.url = url
        if let parsedURL = URL(string: url) {
            webView.load(URLRequest(url: parsedURL))
        }
    }

    @objc private func goBackAction() { webView.goBack() }
    @objc private func goForwardAction() { webView.goForward() }
    @objc private func reloadAction() { webView.reload() }
    @objc private func inspectorAction() { toggleInspector() }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    /// Move keyboard focus to the URL field with the text selected (Cmd+L).
    func focusAddressBar() {
        urlField.beginEditing()
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

