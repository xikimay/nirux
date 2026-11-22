import WebKit
import XCTest
@testable import Nirux

@MainActor
final class IsolatedBrowserTests: XCTestCase {
    func testSessionBelongsToItsWorkspaceAndRestoresFresh() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let first = try XCTUnwrap(shell.activeWorkspace)
            let url = URL(fileURLWithPath: harness.repo + "/README.md").absoluteString
            @MainActor func browser(in workspace: WorkspaceState, isolated: Bool) throws -> WebViewColumn {
                workspace.addColumn(webViewURL: url, isIsolated: isolated)
                return try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.webViewColumn)
            }

            let regular = try browser(in: first, isolated: false)
            XCTAssertIdentical(regular.webView.configuration.websiteDataStore, WKWebsiteDataStore.default())
            XCTAssertNil(regular.header.status)
            XCTAssertNil(regular.header.currentMenu().item(withTitle: "Clear Session"))

            let one = try browser(in: first, isolated: true)
            let store = one.webView.configuration.websiteDataStore
            XCTAssertFalse(store.isPersistent)
            XCTAssertNotIdentical(store, WKWebsiteDataStore.default())
            let two = try browser(in: first, isolated: true)
            XCTAssertIdentical(two.webView.configuration.websiteDataStore, store)

            shell.addWorkspace(title: "second", cwd: harness.worktree)
            let second = try XCTUnwrap(shell.activeWorkspace)
            let other = try browser(in: second, isolated: true)
            let otherStore = other.webView.configuration.websiteDataStore
            XCTAssertFalse(otherStore.isPersistent)
            XCTAssertNotIdentical(otherStore, WKWebsiteDataStore.default())
            XCTAssertNotIdentical(otherStore, store)

            shell.saveState()
            shell.restoreState()
            let restored = try XCTUnwrap(shell.workspaces.first { $0.id == first.id })
            let browsers = restored.columns.compactMap(\.webViewColumn)
            XCTAssertEqual(browsers.filter { !$0.isIsolated }.count, 1)
            let isolated = browsers.filter(\.isIsolated)
            XCTAssertEqual(isolated.count, 2)
            let freshStore = try XCTUnwrap(isolated.first).webView.configuration.websiteDataStore
            XCTAssertFalse(freshStore.isPersistent)
            XCTAssertNotIdentical(freshStore, store)
            XCTAssertTrue(isolated.allSatisfy { $0.webView.configuration.websiteDataStore === freshStore })
        }
    }

    func testHeaderClearsOnlyItsSessionsWebsiteData() throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let other = WKWebsiteDataStore.nonPersistent()
        let column = WebViewColumn(url: "http://localhost", dataStore: store, isIsolated: true)
        column.header.frame.size = NSSize(width: 600, height: ColumnHeaderView.height)
        column.header.layoutNow()
        let badge = column.header.statusPill
        XCTAssertFalse(badge.isHidden)
        XCTAssertEqual(badge.label.stringValue, "Test")
        XCTAssertEqual(badge.status?.tone, .neutral)
        XCTAssertTrue(badge.toolTip?.contains("cleared on restart") == true)

        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "example.test", .path: "/", .name: "session", .value: "signed-in"
        ]))
        for session in [store, other] {
            var seeded = false
            session.httpCookieStore.setCookie(cookie) { seeded = true }
            waitUntil("the test cookie to be set") { seeded }
        }
        @MainActor func hasCookie(in session: WKWebsiteDataStore) -> Bool {
            var cookies: [HTTPCookie]?
            session.httpCookieStore.getAllCookies { cookies = $0 }
            waitUntil("WebKit to return the cookies") { cookies != nil }
            return cookies?.contains { $0.name == cookie.name } == true
        }

        XCTAssertTrue(hasCookie(in: store))
        let menu = column.header.currentMenu()
        let clear = try XCTUnwrap(menu.item(withTitle: "Clear Session"))
        menu.performActionForItem(at: menu.index(of: clear))
        waitUntil("Clear Session to remove the cookie") { !hasCookie(in: store) }
        XCTAssertTrue(hasCookie(in: other))
    }

    func testServerChipOpensAnIsolatedColumnBesideItsTerminal() throws {
        try UIFlowHarness.run { harness in
            let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
            let terminal = try XCTUnwrap(workspace.columns.first)
            let server = LocalServerURL(isSecure: false, host: "localhost", port: 5173, path: "/app")
            workspace.addColumn(webViewURL: server.urlString)
            terminal.setLocalServerChip(server)
            let chip = try XCTUnwrap(terminal.header?.accessories.compactMap { $0 as? LocalServerChipView }.first)
            let menu = try XCTUnwrap(chip.menu)
            let item = try XCTUnwrap(menu.item(withTitle: "Open in Isolated Test Browser"))
            menu.performActionForItem(at: menu.index(of: item))
            harness.waitUntil("the isolated server column") {
                workspace.columns[safe: workspace.focusedIndex]?.webViewColumn?.isIsolated == true
            }
            XCTAssertEqual(workspace.focusedIndex, 1)
            XCTAssertEqual(workspace.columns[safe: 1]?.webViewColumn?.currentURL, server.urlString)
        }
    }
}
