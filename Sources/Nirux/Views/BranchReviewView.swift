import AppKit
import WebKit

/// The Branch Review column's view (docs/branch-review.md, section 1):
/// `review.html` in a web view, under the column's header. The page shows
/// text that neither Nirux nor the user wrote, and has a bridge to Swift
/// (section 1.1):
/// - the web view loads only its bundled page; every other navigation is
///   cancelled, and a web link opens in the browser instead;
/// - the bridge takes messages only from the main frame of that page, and
///   they carry ids and links, never text to type;
/// - data reaches the page as call arguments, never spliced into a script.
@MainActor
final class BranchReviewView: NSView, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
    static let messageHandler = "review"

    let header = ColumnHeaderView()
    let refreshButton = ColumnHeaderButton(symbol: Theme.Symbol.reload, toolTip: "Refresh")
    private let webView: WKWebView
    /// The bundled page; nil when the build lacks it.
    let pageURL: URL?
    /// The page loaded and installed `NiruxReview`.
    private(set) var isPageReady = false
    /// The last page or status sent before the page was ready, sent once it
    /// is. A diff isn't kept: a page that loads has no row open.
    private var pendingCall: (body: String, arguments: [String: Any])?
    /// `load` was called: the page loads, or is loaded.
    private(set) var isLoaded = false
    /// Times the page's process died since the column opened or the user
    /// last clicked Refresh: a review that crashes it, while showing or
    /// after, mustn't reload it forever. Two crashes far apart (memory
    /// pressure) also stop it, until Refresh.
    private(set) var crashes = 0

    /// The page asks for a file's diff, by its id in the page's data and
    /// that data's generation.
    var onLoadFile: ((_ id: Int, _ generation: Int) -> Void)?
    var onRefresh: (() -> Void)?
    /// The Reload banner's button: show the branch as it is now.
    var onReload: (() -> Void)?
    /// The button a status offers (`showStatus(_:action:)`).
    var onStatusAction: (() -> Void)?
    /// The page is ready for data: after its first load, and after its
    /// process crashed and it loaded again.
    var onPageReady: (() -> Void)?
    /// The view entered a window (true) or left it (false): the column
    /// closed, or its workspace moved.
    var onWindowChange: ((Bool) -> Void)?
    /// The page's text selection came (true) or went (false).
    var onSelection: ((Bool) -> Void)?
    /// Reviewed checkboxes: mark (true) or clear the files of these ids in
    /// the page's data of that generation; `sequence` counts the page's
    /// clicks.
    var onReviewed: ((_ ids: [Int], _ reviewed: Bool, _ generation: Int, _ sequence: Int) -> Void)?
    /// Explain: the changed files, or every file again (`fresh`).
    var onExplain: ((_ fresh: Bool) -> Void)?
    var onCancelExplain: (() -> Void)?
    /// The page's "Include untracked files".
    var onIncludeUntracked: ((Bool) -> Void)?
    /// One of Claude's notes, by its id, marked wrong (true) or not.
    var onMarkWrong: ((_ id: String, _ wrong: Bool) -> Void)?
    /// A web link to open, http or https only.
    var openLink: (URL) -> Void = { NSWorkspace.shared.open($0) }

    init(pageURL: URL? = BranchReviewView.bundledPage()) {
        self.pageURL = pageURL
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.canvas.cgColor
        appearance = Theme.appearance

        header.icon = .symbol(Theme.Symbol.branchReview)
        header.title = "Branch Review"
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        header.trailingButtons = [refreshButton]
        header.menuProvider = { Self.headerMenu() }

        config.userContentController.add(WeakMessageHandler(self), name: Self.messageHandler)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        // Pinch to zoom the page's text.
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = Theme.Color.canvas
        addSubview(webView)
        addSubview(header)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func headerMenu() -> NSMenu {
        let menu = NSMenu()
        ColumnHeaderView.columnMenuItems().forEach(menu.addItem)
        return menu
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window != nil)
    }

    /// The page scrolls with the keyboard once the column has the focus.
    func takeKeyboard() {
        window?.makeFirstResponder(webView)
    }

    @objc private func refreshClicked() {
        onRefresh?()
    }

    /// `EditorAssets/review.html` in the app (`bundle.sh` copies the assets
    /// into Contents/Resources) or in the SwiftPM resource bundle, as the
    /// editor finds its page.
    static func bundledPage() -> URL? {
        if let resources = Bundle.main.resourceURL {
            let candidate = resources.appendingPathComponent("EditorAssets/review.html")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return Bundle.module.url(forResource: "review", withExtension: "html", subdirectory: "EditorAssets")
    }

    /// Loads the page, once: a review restored in a workspace off screen
    /// waits until it shows.
    func load() {
        guard !isLoaded else { return }
        isLoaded = true
        loadPage()
    }

    private func loadPage() {
        guard let pageURL else {
            header.status = ColumnHeaderView.Status("Missing", tone: .error, toolTip: "This build lacks the review page.")
            return
        }
        isPageReady = false
        webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let headerHeight = ColumnHeaderView.height
        header.frame = NSRect(x: 0, y: bounds.height - headerHeight, width: bounds.width, height: headerHeight)
        header.layoutNow()
        webView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - headerHeight))
    }

    // MARK: - Calls into the page

    /// The page's data (`BranchReview.Page`, encoded).
    func show(pageJSON: String) {
        call("NiruxReview.show(json)", ["json": pageJSON])
    }

    /// The user asked for the review again (Refresh): try the page again.
    func forgetCrashes() {
        crashes = 0
    }

    /// A file's diff (`BranchReview.FileDiff`, encoded). Dropped while
    /// the page loads: its rows are gone.
    func showDiff(json: String) {
        guard isPageReady else { return }
        call("NiruxReview.showDiff(json)", ["json": json])
    }

    /// The stored review (`BranchReview.Page.Review`, encoded): each
    /// file's Reviewed state, and whether it can be changed. Dropped while
    /// the page loads: the page's data holds it.
    func showReview(json: String) {
        guard isPageReady else { return }
        call("NiruxReview.showReview(json)", ["json": json])
    }

    /// Explain's bar (`BranchReview.Page.ExplainBar`, encoded): the page
    /// updates it in place. Dropped while the page loads: the page's data
    /// carries it.
    func showExplain(json: String) {
        guard isPageReady else { return }
        call("NiruxReview.showExplain(json)", ["json": json])
    }

    /// A note's mark as the review file holds it; nil: the click wasn't
    /// taken, the page keeps the last mark it was told. With `from` and
    /// `to`, the page's notes go from one version to the other (`Page
    /// .notesVersion`) if they were at the first: only marks changed.
    func markNote(id: String, wrong: Bool?, from: Int? = nil, to: Int? = nil) {
        guard isPageReady else { return }
        call("NiruxReview.markNote(id, wrong, from, to)", [
            "id": id, "wrong": wrong ?? NSNull(), "from": from ?? NSNull(), "to": to ?? NSNull()
        ])
    }

    /// A message in place of the page, with a button titled `action` when
    /// there is something to do (`onStatusAction`).
    func showStatus(_ message: String, action: String? = nil) {
        call("NiruxReview.showStatus(message, action)", ["message": message, "action": action ?? NSNull()])
    }

    /// Something changed under the page (a new head, a pause, another
    /// branch): the page stays as it is, under a banner whose button
    /// (`action`, Reload by default) calls `onReload`. Dropped while the
    /// page loads: the column sends it again once it is ready.
    func showReload(_ message: String, action: String? = nil) {
        guard isPageReady else { return }
        call("NiruxReview.showReload(message, action)", ["message": message, "action": action ?? NSNull()])
    }

    /// What the banner said waits no more.
    func hideReload() {
        guard isPageReady else { return }
        call("NiruxReview.hideReload()", [:])
    }

    private func call(_ body: String, _ arguments: [String: Any]) {
        guard isPageReady else {
            pendingCall = (body, arguments)
            return
        }
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
            if case .failure(let error) = result {
                NiruxDebugLog.log("BranchReviewView: \(body) failed: \(error)")
            }
        }
    }

    // MARK: - WKScriptMessageHandler

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // Delivered on the main thread (WebKit's documentation); Xcode 16.4
        // declares `WKScriptMessage.body` main-actor.
        MainActor.assumeIsolated {
            guard message.frameInfo.isMainFrame, Self.isPage(message.frameInfo.request.url, pageURL),
                  let body = message.body as? [String: Any], let type = body["type"] as? String
            else { return }
            receive(type: type, body: body)
        }
    }

    /// The bundled page's own URL, whatever its fragment.
    nonisolated static func isPage(_ url: URL?, _ pageURL: URL?) -> Bool {
        guard let url, let pageURL, url.isFileURL, pageURL.isFileURL else { return false }
        return url.standardizedFileURL.path == pageURL.standardizedFileURL.path
    }

    private func receive(type: String, body: [String: Any]) {
        switch type {
        case "ready":
            isPageReady = true
            if let onPageReady {
                // The column sends what the page shows, banner included,
                // rather than the last call alone: after the page's process
                // died, a banner may have been dropped while it loaded.
                pendingCall = nil
                onPageReady()
            } else if let pending = pendingCall {
                pendingCall = nil
                call(pending.body, pending.arguments)
            }
        case "loadFile":
            guard let id = body["id"] as? Int, let generation = body["generation"] as? Int else { return }
            onLoadFile?(id, generation)
        case "reload":
            onReload?()
        case "statusAction":
            onStatusAction?()
        case "selection":
            guard let active = body["active"] as? Bool else { return }
            onSelection?(active)
        case "reviewed":
            guard let ids = body["ids"] as? [Int], ids.count <= 1_000_000, let reviewed = body["reviewed"] as? Bool,
                  let generation = body["generation"] as? Int, let sequence = body["sequence"] as? Int
            else { return }
            onReviewed?(ids, reviewed, generation, sequence)
        case "explain":
            guard let fresh = body["fresh"] as? Bool else { return }
            onExplain?(fresh)
        case "cancelExplain":
            onCancelExplain?()
        case "includeUntracked":
            guard let include = body["include"] as? Bool else { return }
            onIncludeUntracked?(include)
        case "markWrong":
            guard let id = body["id"] as? String, id.utf8.count <= 100, let wrong = body["wrong"] as? Bool else { return }
            onMarkWrong?(id, wrong)
        case "openLink":
            guard let text = body["url"] as? String, let url = Self.webLink(text) else { return }
            openLink(url)
        default:
            break
        }
    }

    /// An http or https URL with a host; anything else isn't opened.
    nonisolated static func webLink(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host?.isEmpty == false
        else { return nil }
        return url
    }

    // MARK: - WKNavigationDelegate

    // Signatures must match WebKit's exactly, the @MainActor @Sendable
    // handler included, or WebKit never calls them (see WebViewColumn).
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        // Only `loadPage`'s load: a reload (the context menu's) would
        // drop what the page shows without the column knowing.
        let url = navigationAction.request.url
        if navigationAction.targetFrame?.isMainFrame == true, Self.isPage(url, pageURL),
           navigationAction.navigationType == .other {
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .linkActivated, let url, let link = Self.webLink(url.absoluteString) {
            openLink(link)
        }
        decisionHandler(.cancel)
    }

    /// The page's process died: load it again, and the column sends its
    /// data once the page is ready.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pendingCall = nil
        crashes += 1
        loadPage()
    }

    // MARK: - WKUIDelegate

    /// A link that asks for a new window opens in the browser.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, let link = Self.webLink(url.absoluteString) {
            openLink(link)
        }
        return nil
    }
}

/// The content controller keeps its handlers: through this one, it doesn't
/// keep the view (and its web view) alive once the column closes.
@MainActor
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            target?.userContentController(userContentController, didReceive: message)
        }
    }
}
