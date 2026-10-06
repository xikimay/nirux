import AppKit
import WebKit
import XCTest
@testable import Nirux

/// Find in a browser column's page: ⌘F, through the app's key interceptor
/// and menu bar, opens the column's find bar, which finds a word with
/// WebKit's find, counts it and steps through its matches.
@MainActor
final class WebPageFindTests: XCTestCase {
    private static let page = """
        <p id="first">alpha needle</p>
        <p id="second">beta</p>
        <p id="third">gamma NEEDLE needle</p>
        <script>
        addEventListener("keydown", event => {
            if (window.ownSearch && event.metaKey && event.key === "f") {
                event.preventDefault();
                document.title = "own search";
            }
        });
        </script>
        """

    func testCommandFFindsAWordInTheBrowserPage() throws {
        try UIFlowHarness.run { harness in
            try harness.withApp {
                let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
                let page = harness.repo + "/find.html"
                let otherPage = harness.repo + "/other.html"
                try Self.page.write(toFile: page, atomically: true, encoding: .utf8)
                try "<p>Nothing to see</p>".write(toFile: otherPage, atomically: true, encoding: .utf8)
                workspace.addColumn(webViewURL: URL(fileURLWithPath: page).absoluteString)
                harness.shell.relayout(animated: false)
                let column = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex])
                let browser = try XCTUnwrap(column.webViewColumn)
                let webView = browser.webView
                harness.waitUntil("the page to load") { webView.url != nil && !webView.isLoading }
                harness.window.makeFirstResponder(webView)

                // A page with its own search keeps ⌘F.
                run("ownSearch = true", in: webView, harness: harness)
                pressCommandFInPage(webView)
                harness.waitUntil("the page's own search", timeout: 10) { webView.title == "own search" }
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                XCTAssertNil(column.findBar, "the find bar took ⌘F from the page")

                // Unhandled, ⌘F comes back from WebKit to Edit > Find.
                run("ownSearch = false", in: webView, harness: harness)
                pressCommandFInPage(webView)
                harness.waitUntil("the find bar", timeout: 10) { column.isFindBarOpen }
                let bar = try XCTUnwrap(column.findBar)
                XCTAssertTrue(bar.isEditing, "the find field doesn't have the keyboard")
                XCTAssertGreaterThan(bar.frame.width, 0)

                harness.type("needle", into: bar.field)
                harness.waitUntil("WebKit to count the matches", timeout: 10) { bar.status == "3 matches" }
                waitForSelection("first@6:needle", in: webView)
                // Still the same match, which WebKit would pass by.
                harness.type("Needle", into: bar.field)
                waitForSelection("first@6:needle", in: webView)
                harness.shell.focusActiveTerminal(in: harness.window)
                XCTAssertTrue(bar.isEditing, "the page took the keyboard from the open find bar")
                harness.press("g", keyCode: 0x05, [.command])
                waitForSelection("third@6:NEEDLE", in: webView)
                typeInField("\r", keyCode: 0x24, in: harness)
                waitForSelection("third@13:needle", in: webView)
                // ⇧⌘G reaches Find Previous only from the keyboard: a
                // synthetic one matches ⌘G's item or none (MenuShortcutTests
                // checks the chord).
                try XCTUnwrap(
                    bar.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Previous Match" }
                ).performClick(nil)
                waitForSelection("third@6:NEEDLE", in: webView)

                typeInField("\u{1b}", keyCode: 0x35, in: harness)
                XCTAssertFalse(column.isFindBarOpen)
                XCTAssertNil(bar.status)
                XCTAssertIdentical(harness.window.firstResponder, webView, "the page didn't get the keyboard back")

                // Reopened, the bar counts the matches again, from the
                // selected one, or from the top where WebKit drops a page's
                // selection as the field takes the keyboard; never past it.
                pressCommandFInPage(webView)
                harness.waitUntil("the find bar to reopen", timeout: 10) { column.isFindBarOpen && bar.status == "3 matches" }
                waitForSelection("third@6:NEEDLE", "first@6:needle", in: webView)

                // A new page has none of the matches counted.
                browser.navigate(to: URL(fileURLWithPath: otherPage).absoluteString)
                harness.waitUntil("the other page", timeout: 10) { webView.url?.lastPathComponent == "other.html" && bar.status == nil }
                harness.type("absent", into: bar.field)
                harness.waitUntil("WebKit to find nothing", timeout: 10) { bar.status == WebPageFind.notFound }
            }
        }
    }

    /// Edit > Find and Find Next/Previous act on a terminal or browser
    /// column; an editor column leaves ⌘F to Monaco.
    func testTheFindItemsFollowTheFocusedColumn() throws {
        try UIFlowHarness.run { harness in
            try harness.withApp {
                let app = try XCTUnwrap(NSApp.delegate as? NiruxApp)
                let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
                let items = [#selector(NiruxApp.showFind(_:)), #selector(NiruxApp.findNextMatch(_:)), #selector(NiruxApp.findPreviousMatch(_:))]
                    .compactMap { action in NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.action == action } }
                XCTAssertEqual(items.count, 3)
                let enabled = { @MainActor in items.map { app.validateMenuItem($0) } }

                XCTAssertNotNil(workspace.columns[safe: workspace.focusedIndex]?.terminalView)
                XCTAssertEqual(enabled(), [true, true, true])
                workspace.addColumn(webViewURL: "about:blank")
                XCTAssertEqual(enabled(), [true, true, true])
                harness.shell.openEditorColumn()
                XCTAssertNotNil(workspace.columns[safe: workspace.focusedIndex]?.editorColumn)
                XCTAssertEqual(enabled(), [false, false, false])
            }
        }
    }

    /// Without WebKit's private find calls, the public one still finds,
    /// steps through the matches and tells "Not found", with no count.
    func testThePublicFindFindsWithoutCounting() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = webView
        window.orderFront(nil)
        defer { window.close() }
        webView.loadHTMLString(Self.page, baseURL: nil)
        wait("the page to load") { !webView.isLoading && webView.url != nil }
        let find = WebPageFind(webView: webView, usesPrivateFind: false)

        find.update("needle")
        waitForSelection("first@6:needle", in: webView)
        find.next()
        waitForSelection("third@6:NEEDLE", in: webView)
        find.previous()
        waitForSelection("first@6:needle", in: webView)
        XCTAssertNil(find.status)
        find.update("absent")
        wait("no match") { find.status == WebPageFind.notFound }
    }

    /// A browser column's bar sits under the header the column draws
    /// itself, and goes down the page with its down arrow.
    func testABrowserColumnsBarOpensUnderItsHeader() throws {
        let column = ColumnState(url: "about:blank")
        column.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        column.layoutWithHeader(width: 600, height: 400)
        column.showFindBar()
        let bar = try XCTUnwrap(column.findBar)
        XCTAssertTrue(column.view.subviews.last === bar, "drawn above the page")
        XCTAssertEqual(bar.frame.maxY, 400 - ColumnHeaderView.height - 10)
        XCTAssertEqual(bar.frame.maxX, 590)
        XCTAssertEqual(bar.field.accessibilityLabel(), "Find in Page")

        bar.layoutSubtreeIfNeeded()
        func button(_ label: String) throws -> NSButton {
            try XCTUnwrap(bar.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == label }, label)
        }
        XCTAssertLessThan(try button("Previous Match").frame.minX, try button("Next Match").frame.minX, "the up arrow goes back")

        // The counter leaves the field room, or hides on a narrow column.
        bar.status = "1000+ matches"
        bar.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(bar.field.frame.width, FindBar.minimumFieldWidth)
        bar.frame.size.width = 180
        bar.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(bar.field.frame.width, FindBar.minimumFieldWidth)
    }

    func testTheCounterReadsLikeSafaris() {
        XCTAssertEqual(WebPageFind.status(matches: 1), "1 match")
        XCTAssertEqual(WebPageFind.status(matches: 12), "12 matches")
        XCTAssertEqual(WebPageFind.status(matches: 1000), "1000 matches")
        // WebKit's report past the most it counts.
        XCTAssertEqual(WebPageFind.status(matches: UInt(UInt32.max)), "1000+ matches")
    }

    // MARK: - Helpers

    /// ⌘F as AppKit sends it on once the key interceptor returned it, as
    /// it does every find chord of a browser column: to the key window's
    /// views, where the web view takes it for the page. The test process
    /// has no key window, so this step is taken here. WebKit resends a key
    /// the page left unhandled through NSApp.sendEvent: to the interceptor,
    /// then the menu.
    private func pressCommandFInPage(_ webView: WKWebView, file: StaticString = #filePath, line: UInt = #line) {
        let passes = WebContentKeyRouting.passesToWebContent(
            isEditor: false, characters: "f", charactersIgnoringModifiers: "f", keyCode: 0x03, modifierFlags: .command
        )
        XCTAssertTrue(passes, "the key interceptor keeps ⌘F from the page", file: file, line: line)
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: webView.window?.windowNumber ?? 0,
            context: nil,
            characters: "f",
            charactersIgnoringModifiers: "f",
            isARepeat: false,
            keyCode: 0x03
        ) else { return XCTFail("no key event", file: file, line: line) }
        XCTAssertTrue(webView.performKeyEquivalent(with: event), "the web view didn't take ⌘F", file: file, line: line)
    }

    /// Runs `script` in the page and waits for it.
    private func run(_ script: String, in webView: WKWebView, harness: UIFlowHarness) {
        let answer = SelectionAnswer()
        answer.isAsking = true
        webView.evaluateJavaScript(script) { _, _ in
            MainActor.assumeIsolated { answer.isAsking = false }
        }
        harness.waitUntil("the page to run \(script)") { !answer.isAsking }
    }

    /// A plain key typed into the focused find field. The key interceptor
    /// leaves those to the field (TerminalFindKeyRouting.routeInField),
    /// and with no key window AppKit would drop it: the window delivers it
    /// to its first responder instead.
    private func typeInField(_ characters: String, keyCode: UInt16, in harness: UIFlowHarness) {
        XCTAssertEqual(TerminalFindKeyRouting.routeInField(keyCode: keyCode, modifierFlags: []), .field)
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { return XCTFail("no key event") }
        harness.window.sendEvent(event)
    }

    /// Asks the page for its selection, as "id@offset:text", until it is
    /// one of `expected`: WebKit finds after the call returns.
    private func waitForSelection(
        _ expected: String..., in webView: WKWebView, file: StaticString = #filePath, line: UInt = #line
    ) {
        let script = """
            (() => {
                const selection = getSelection();
                const node = selection.anchorNode;
                return node ? `${node.parentElement.id}@${selection.anchorOffset}:${selection}` : "";
            })()
            """
        let answer = SelectionAnswer()
        wait("the page to select \(expected)", file: file, line: line) {
            if !answer.isAsking {
                answer.isAsking = true
                webView.evaluateJavaScript(script) { result, _ in
                    MainActor.assumeIsolated {
                        answer.latest = result as? String
                        answer.isAsking = false
                    }
                }
            }
            return answer.latest.map(expected.contains) == true
        }
        if answer.latest.map(expected.contains) != true {
            XCTFail("the page selected \(answer.latest ?? "nothing")", file: file, line: line)
        }
    }

    @MainActor
    private final class SelectionAnswer {
        var latest: String?
        var isAsking = false
    }

    /// Spins the main run loop until `condition` holds, 10 s at most.
    private func wait(
        _ description: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(description)", file: file, line: line)
    }
}
