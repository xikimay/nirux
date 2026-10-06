import WebKit

/// Find in page for a browser column (⌘F), with WebKit's own find, the one
/// Safari runs: it selects the match and scrolls to it, highlights every
/// match and counts them. The counter reads like Safari's ("12 matches"):
/// WebKit's index of the current match drifts as the needle is edited.
///
/// WKWebView's public `find(_:configuration:completionHandler:)` neither
/// highlights nor counts, so this drives its private find calls while
/// WebKit has them, and falls back on the public one otherwise, which only
/// tells "Not found".
@MainActor
final class WebPageFind: NSObject {
    /// Matches counted at most, as in Safari.
    nonisolated static let maxCount = 1000
    nonisolated static let notFound = "Not found"

    /// The counter changed; nil shows none.
    var onStatusChange: ((String?) -> Void)?
    private(set) var status: String? {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    private(set) var needle = ""
    /// From a search to `end` or a new document: an answer arriving after
    /// those is dropped.
    private var isSearching = false
    /// The column owns both: WebKit holds this object weakly.
    private let webView: WKWebView
    private let privateFind: WebKitPrivateFind?

    init(webView: WKWebView, usesPrivateFind: Bool = true) {
        self.webView = webView
        privateFind = usesPrivateFind ? Self.privateFind(of: webView) : nil
        super.init()
        // A weak reference: the browser column keeps this object.
        privateFind?.setFindDelegate(self)
    }

    /// The field's text changed, or the bar reopened: search from the
    /// selected match, which stays selected while it still matches.
    func update(_ text: String) {
        needle = text
        guard !text.isEmpty else {
            clearHighlights()
            return
        }
        // WebKit searches from the selection, and past it when the match it
        // finds is the selection itself: from the selection's start, the
        // same needle (a case change, a bar reopened) finds it again. In the
        // app's own JavaScript world, before the find: WebKit keeps the
        // order of both. Main frame only: a match in a frame may still move.
        webView.evaluateJavaScript(
            "{ const selection = getSelection(); if (selection.rangeCount) selection.collapseToStart(); }",
            in: nil, in: .defaultClient
        )
        find(backwards: false)
    }

    func next() {
        find(backwards: false)
    }

    func previous() {
        find(backwards: true)
    }

    /// The bar closed: the highlights go, the match stays selected, as in
    /// Safari.
    func end() {
        isSearching = false
        clearHighlights()
    }

    /// A new document replaced the one searched, with none of its matches:
    /// an answer about the old one is dropped.
    func pageDidChange() {
        isSearching = false
        status = nil
    }

    private func clearHighlights() {
        privateFind?.hideFindUI()
        status = nil
    }

    private func find(backwards: Bool) {
        guard !needle.isEmpty else { return }
        isSearching = true
        if let privateFind {
            var options: PrivateFindOptions = [.caseInsensitive, .wrapAround, .showFindIndicator, .showHighlight]
            if backwards { options.insert(.backwards) }
            privateFind.findString(needle, options: options.rawValue, maxCount: UInt(Self.maxCount))
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        let searched = needle
        webView.find(searched, configuration: configuration) { [weak self] result in
            guard let self, isSearching, needle == searched else { return }
            status = result.matchFound ? nil : Self.notFound
        }
    }

    nonisolated static func status(matches: UInt) -> String {
        switch matches {
        case 0: notFound
        case 1: "1 match"
        // Past `maxCount`, WebKit reports UInt32.max.
        case ...UInt(maxCount): "\(matches) matches"
        default: "\(maxCount)+ matches"
        }
    }

    // MARK: - _WKFindDelegate

    @objc(_webView:didFindMatches:forString:withMatchIndex:)
    func webView(_ webView: WKWebView, didFindMatches matches: UInt, forString string: String, withMatchIndex index: Int) {
        guard isSearching, string == needle else { return }
        status = Self.status(matches: matches)
    }

    @objc(_webView:didFailToFindString:)
    func webView(_ webView: WKWebView, didFailToFindString string: String) {
        guard isSearching, string == needle else { return }
        status = Self.notFound
    }

    // MARK: - Private find calls

    /// `_WKFindOptions` (WebKit's _WKFindOptions.h).
    private struct PrivateFindOptions: OptionSet {
        let rawValue: UInt
        static let caseInsensitive = Self(rawValue: 1 << 0)
        static let backwards = Self(rawValue: 1 << 3)
        static let wrapAround = Self(rawValue: 1 << 4)
        /// The bounce on the match found.
        static let showFindIndicator = Self(rawValue: 1 << 6)
        /// Every match highlighted; also makes WebKit count them.
        static let showHighlight = Self(rawValue: 1 << 7)
    }

    /// The web view as its private find calls, when it answers all of them.
    private static func privateFind(of webView: WKWebView) -> WebKitPrivateFind? {
        let selectors = ["_findString:options:maxCount:", "_hideFindUI", "_setFindDelegate:"].map(NSSelectorFromString)
        guard selectors.allSatisfy(webView.responds(to:)) else { return nil }
        return unsafeBitCast(webView, to: WebKitPrivateFind.self)
    }
}

/// WKWebView's private find calls (WKWebViewPrivate.h), which Safari's
/// find bar drives.
@objc private protocol WebKitPrivateFind {
    @objc(_findString:options:maxCount:)
    func findString(_ string: String, options: UInt, maxCount: UInt)
    @objc(_hideFindUI)
    func hideFindUI()
    @objc(_setFindDelegate:)
    func setFindDelegate(_ delegate: AnyObject?)
}
