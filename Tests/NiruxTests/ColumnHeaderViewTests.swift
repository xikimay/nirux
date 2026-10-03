import AppKit
import XCTest
@testable import Nirux

/// The header every column shows: its slots, what gives way first, the ⋯
/// menu, and what each column type puts in it.
@MainActor
final class ColumnHeaderViewTests: XCTestCase {
    private func button(_ symbol: String, _ toolTip: String) -> ColumnHeaderButton {
        ColumnHeaderButton(symbol: symbol, toolTip: toolTip)
    }

    private func label(_ text: String) -> ColumnHeaderLabel {
        let label = ColumnHeaderLabel()
        label.stringValue = text
        return label
    }

    private func info(
        _ status: AgentStatus, reason: AgentAttentionReason? = nil, process: String = "claude",
        elapsed: TimeInterval? = 720, stuck: SidebarStuckState? = nil, deferred: SidebarDeferredAgent? = nil
    ) -> ColumnInfo {
        ColumnInfo(
            index: 0, processName: process, abbreviatedCwd: "~/acme", isFocused: false, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: status, isEditor: false, editorFileName: nil,
            agentElapsedSeconds: elapsed, attentionReason: reason, stuck: stuck, deferredAgent: deferred
        )
    }

    // MARK: - Layout

    /// From wide to narrow, the context goes first, then the accessories,
    /// the status, and the trailing buttons from the left; the title and ⋯
    /// stay. What went stays gone at any narrower width.
    func testSlotsGiveWayInOrderAsTheBarNarrows() {
        let header = ColumnHeaderView(frame: NSRect(x: 0, y: 0, width: 560, height: ColumnHeaderView.height))
        header.title = "claude"
        header.context = "~/Projects/acme-app"
        header.status = .init("working · 12m", tone: .working)
        let usage = label("ctx 62%")
        header.accessories = [usage]
        let diff = button(Theme.Symbol.diff, "Toggle Editor Diff")
        let search = button(Theme.Symbol.search, "Search Workspace")
        header.trailingButtons = [diff, search]
        header.menuProvider = { NSMenu() }

        header.layoutNow()
        let shown: [(String, NSView)] = [
            ("context", header.contextLabel), ("status", header.statusPill), ("usage", usage),
            ("diff", diff), ("search", search), ("⋯", header.menuButton)
        ]
        XCTAssertEqual(shown.filter { $0.1.isHidden }.map(\.0), [], "all fit at 560 pt")
        let xs = shown.map(\.1.frame.minX)
        XCTAssertEqual(xs, xs.sorted(), "context, status, accessories, buttons, then ⋯, left to right")

        var hiddenAt: [String: CGFloat] = [:]
        for width in stride(from: 560, through: 100, by: -2) {
            header.frame.size.width = CGFloat(width)
            header.layoutNow()
            for (name, view) in shown {
                if view.isHidden, hiddenAt[name] == nil { hiddenAt[name] = CGFloat(width) }
                if hiddenAt[name] != nil { XCTAssertTrue(view.isHidden, "\(name) came back at \(width) pt") }
            }
            XCTAssertFalse(header.titleLabel.isHidden)
            XCTAssertGreaterThan(header.titleLabel.frame.width, 0, "at \(width) pt")
        }
        let order = ["context", "usage", "status", "diff", "search"]
        let widths = order.map { hiddenAt[$0] ?? 0 }
        XCTAssertEqual(widths, widths.sorted(by: >), "gave way in this order: \(hiddenAt)")
        XCTAssertTrue(widths.allSatisfy { $0 > 0 }, "\(hiddenAt)")
        XCTAssertNil(hiddenAt["⋯"])
    }

    /// A trailing button without room still acts: it heads the ⋯ menu,
    /// with its state.
    func testHiddenButtonsHeadTheMenu() {
        let header = ColumnHeaderView(frame: NSRect(x: 0, y: 0, width: 120, height: ColumnHeaderView.height))
        header.title = "ColumnHeaderView.swift"
        let diff = button(Theme.Symbol.diff, "Toggle Editor Diff")
        diff.target = self
        diff.action = #selector(dummyAction)
        diff.isOn = true
        let search = button(Theme.Symbol.search, "Search Workspace")
        search.action = #selector(NiruxApp.showWorkspaceSearch(_:))
        header.trailingButtons = [diff, search]
        header.menuProvider = {
            let menu = NSMenu()
            menu.addItem(withTitle: "Close Column", action: #selector(NiruxApp.closeColumn(_:)), keyEquivalent: "")
            return menu
        }
        header.layoutNow()
        XCTAssertTrue(diff.isHidden)
        XCTAssertTrue(header.overflowButtons.contains { $0 === diff })

        let menu = header.currentMenu()
        let first = menu.items[0]
        XCTAssertEqual(first.title, "Toggle Editor Diff")
        XCTAssertTrue(first.target === self)
        XCTAssertEqual(first.action, #selector(dummyAction))
        XCTAssertEqual(first.state, .on)
        XCTAssertTrue(menu.items[header.overflowButtons.count].isSeparatorItem)
        XCTAssertEqual(menu.items.last?.title, "Close Column")

        diff.isEnabled = false
        XCTAssertNil(header.currentMenu().items[0].action, "a disabled button's item is disabled")

        header.frame.size.width = 560
        header.layoutNow()
        XCTAssertEqual(header.overflowButtons.count, 0)
        XCTAssertEqual(header.currentMenu().items.map(\.title), ["Close Column"])
    }

    @objc private func dummyAction() {}

    func testFocusTintsTheTypeSymbolButNotAnAppIcon() {
        let header = ColumnHeaderView(frame: NSRect(x: 0, y: 0, width: 400, height: ColumnHeaderView.height))
        header.icon = .symbol(Theme.Symbol.editor)
        XCTAssertEqual(header.iconView.contentTintColor, Theme.Color.textTertiary)
        header.isFocused = true
        XCTAssertEqual(header.iconView.contentTintColor, Theme.Color.accent)
        header.icon = .image(NSImage(size: NSSize(width: 16, height: 16)))
        XCTAssertNil(header.iconView.contentTintColor)
    }

    // MARK: - Agent status

    /// Amber only while a dialog waits on the user's answer; a finished turn
    /// shows nothing; a failure is red.
    func testAgentPillIsAmberOnlyWhileADialogWaits() throws {
        let reasons: [AgentAttentionReason] = [
            .permission(tool: "Bash", summary: "git push"), .permission(tool: "ExitPlanMode", summary: nil),
            .question("Which database?"), .turnFinished, .message("Claude is waiting for your input"),
            .apiError(kind: "rate_limit", detail: "429"), .exitedMidTurn,
            .stillWaiting(.question(nil), waited: 600)
        ]
        for reason in reasons {
            let status = ColumnHeaderView.Status.agent(info(.needsAttention, reason: reason))
            XCTAssertEqual(status?.tone == .waiting, reason.isBlockingDialog, "\(reason)")
            if reason.isFailure { XCTAssertEqual(status?.tone, .error, "\(reason)") }
            if !reason.isBlockingDialog, !reason.isFailure { XCTAssertNil(status, "\(reason)") }
        }
        let permission = try XCTUnwrap(ColumnHeaderView.Status.agent(
            info(.needsAttention, reason: .permission(tool: "Bash", summary: "git push"))
        ))
        XCTAssertEqual(permission.text, "permission · Bash")
        XCTAssertEqual(permission.symbol, Theme.Symbol.permission)
        XCTAssertEqual(permission.toolTip, "needs permission — Bash: git push")
        XCTAssertEqual(
            ColumnHeaderView.Status.agent(info(.needsAttention, reason: .question(nil)))?.symbol, Theme.Symbol.question
        )
        XCTAssertEqual(
            ColumnHeaderView.Status.agent(info(.needsAttention, reason: .apiError(kind: "overloaded", detail: nil)))?.text,
            "stopped"
        )

        let working = try XCTUnwrap(ColumnHeaderView.Status.agent(info(.working)))
        XCTAssertEqual(working.text, "working · 12m")
        XCTAssertEqual(working.tone, .working)
        XCTAssertNil(working.symbol, "a dot, which breathes")
        XCTAssertEqual(ColumnHeaderView.Status.agent(info(.working, elapsed: nil))?.text, "working")
        XCTAssertNil(ColumnHeaderView.Status.agent(info(.idle, process: "zsh")))
    }

    /// A stuck agent says so whatever its status; a restored one that
    /// hasn't resumed says that.
    func testStuckAndNotResumedAgents() throws {
        let waiting = ColumnHeaderView.Status.agent(info(
            .idle, stuck: .waiting(.permission(tool: "Bash", summary: nil), duration: "2h05m")
        ))
        XCTAssertEqual(waiting?.text, "permission · Bash · 2h05m")
        XCTAssertEqual(waiting?.tone, .waiting)

        let failed = ColumnHeaderView.Status.agent(info(
            .working, stuck: .stoppedOnError(kind: "rate_limit", detail: "429", failedAt: 1, resume: .offered)
        ))
        XCTAssertEqual(failed?.tone, .error)
        XCTAssertEqual(failed?.symbol, Theme.Symbol.agentError)

        let deferred = SidebarDeferredAgent(processName: "claude", summary: "Fix login", columnID: UUID())
        let notResumed = try XCTUnwrap(ColumnHeaderView.Status.agent(info(.idle, deferred: deferred)))
        XCTAssertEqual(notResumed.text, "not resumed")
        XCTAssertEqual(notResumed.tone, .neutral)
        XCTAssertEqual(notResumed.toolTip, deferred.tooltip)
    }

    // MARK: - Columns

    func testTerminalHeaderShowsTheProcessItsAgentAndTheFocus() throws {
        let column = ColumnState(cwd: "/tmp")
        let header = try XCTUnwrap(column.header)
        XCTAssertTrue(header === column.terminalHeader)
        column.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        column.layoutWithTitleBar(width: 600, height: 400)
        XCTAssertEqual(header.frame, NSRect(x: 0, y: 370, width: 600, height: ColumnHeaderView.height))
        XCTAssertEqual(column.terminalView?.frame.height, 370, "the terminal starts under the header")

        column.terminalTitle = "claude"
        column.updateHeaderAgentState(info(.working))
        XCTAssertEqual(header.title, "claude")
        XCTAssertEqual(header.icon, .terminal(processName: "claude"))
        XCTAssertEqual(header.status?.tone, .working)
        XCTAssertEqual(column.titleText, "claude")

        column.updateHeaderAgentState(info(.idle, process: "zsh"))
        XCTAssertEqual(header.icon, .symbol(Theme.Symbol.terminal))
        XCTAssertNil(header.status)

        column.setHeaderFocused(true)
        XCTAssertTrue(header.isFocused)
        XCTAssertEqual(Self.columnItems(header), ["Move Left", "Move Right", "Cycle Width", "", "Close Column"])
        XCTAssertEqual(header.currentMenu().items.first?.title, "Find in Terminal…")
    }

    func testTerminalHeaderKeepsTheDevServerChip() throws {
        let column = ColumnState(cwd: "/tmp")
        column.terminalTitle = "npm"
        column.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        column.layoutWithTitleBar(width: 600, height: 400)
        let header = try XCTUnwrap(column.header)

        column.setLocalServerChip(LocalServerURL(isSecure: false, host: "localhost", port: 5173, path: "/"))
        let chip = try XCTUnwrap(header.accessories.compactMap { $0 as? LocalServerChipView }.first)
        XCTAssertFalse(chip.isHidden)
        XCTAssertEqual(chip.frame.maxX, header.menuButton.frame.minX - Theme.Space.sm)

        column.setLocalServerChip(nil)
        XCTAssertTrue(chip.isHidden, "no URL, no chip")
    }

    func testEveryColumnTypePutsItsHeaderOnTop() throws {
        let web = ColumnState(url: "about:blank")
        web.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let webColumn = try XCTUnwrap(web.webViewColumn)
        webColumn.frame = web.view.bounds
        webColumn.layoutSubtreeIfNeeded()
        let webHeader = try XCTUnwrap(web.header)
        XCTAssertTrue(webHeader === webColumn.header)
        XCTAssertEqual(webHeader.frame.maxY, 400)
        XCTAssertLessThanOrEqual(webColumn.webView.frame.maxY, webHeader.frame.minY)
        XCTAssertEqual(webHeader.leadingButtons, [webColumn.backButton, webColumn.forwardButton, webColumn.reloadButton])
        XCTAssertEqual(webHeader.trailingButtons, [webColumn.inspectorButton])
        XCTAssertFalse(webColumn.backButton.isEnabled, "no history yet")
        XCTAssertEqual(Self.columnItems(webHeader), ["Move Left", "Move Right", "Cycle Width", "", "Close Column"])

        let board = ProjectBoardView(frame: .zero)
        board.frame.size = NSSize(width: 600, height: 400)
        XCTAssertEqual(board.header.frame, NSRect(x: 0, y: 0, width: 600, height: ColumnHeaderView.height), "flipped: on top")
        XCTAssertEqual(Self.columnItems(board.header), ["Move Left", "Move Right", "Cycle Width", "", "Close Column"])
    }

    func testEditorHeaderNamesTheActiveFileAndItsDiff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("header-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root + "/Sources/App", withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        try "let a = 1\n".write(toFile: root + "/Sources/App/main.swift", atomically: true, encoding: .utf8)

        let editor = EditorColumn(workspaceCwd: root)
        editor.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        editor.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.header.frame, NSRect(x: 0, y: 370, width: 700, height: ColumnHeaderView.height),
                       "across the file tree too")
        XCTAssertEqual(editor.header.title, "Editor")
        XCTAssertFalse(editor.diffButton.isEnabled, "no file, no diff")

        editor.open(path: "Sources/App/main.swift", takeFocus: false, interactive: false)
        XCTAssertEqual(editor.header.title, "main.swift")
        XCTAssertEqual(editor.header.context, "Sources/App")
        XCTAssertTrue(editor.diffButton.isEnabled)
        XCTAssertFalse(editor.diffButton.isOn)
        XCTAssertEqual(editor.header.trailingButtons, [editor.diffButton, editor.searchButton])
        XCTAssertEqual(editor.header.currentMenu().items.first?.title, "Save All")
        XCTAssertEqual(Self.columnItems(editor.header), ["Move Left", "Move Right", "Cycle Width", "", "Close Column"])
    }

    func testEditorContextIsTheDirectoryInTheWorkspace() {
        XCTAssertEqual(EditorColumn.directoryContext(of: "/repo/README.md", workspaceCwd: "/repo"), "")
        XCTAssertEqual(EditorColumn.directoryContext(of: "/repo/Sources/A/b.swift", workspaceCwd: "/repo/"), "Sources/A")
        XCTAssertEqual(EditorColumn.directoryContext(of: "/repository/b.swift", workspaceCwd: "/repo"), "/repository")
    }

    /// The column's own items end every ⋯ menu.
    private static func columnItems(_ header: ColumnHeaderView) -> [String] {
        Array(header.currentMenu().items.suffix(5).map(\.title))
    }
}

/// The browser header's address field.
@MainActor
final class WebAddressFieldTests: XCTestCase {
    func testAtRestTheHostIsDimmedBeforeThePath() {
        let cases: [(String, String, String)] = [
            ("http://localhost:5173/checkout", "localhost:5173/", "checkout"),
            ("HTTPS://Example.com/a?b=c#d", "Example.com/", "a?b=c#d"),
            ("https://github.com", "", "github.com"),
            ("https://github.com/", "", "github.com/"),
            ("about:blank", "", "about:blank"),
            ("file:///tmp/a.html", "", "file:///tmp/a.html")
        ]
        for (url, dimmed, primary) in cases {
            let parts = AddressField.displayParts(url)
            XCTAssertEqual(parts.dimmed, dimmed, url)
            XCTAssertEqual(parts.primary, primary, url)
        }
        let display = AddressField.display("http://localhost:5173/checkout")
        XCTAssertEqual(display.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, Theme.Color.textTertiary)
        XCTAssertEqual(display.attribute(.foregroundColor, at: 15, effectiveRange: nil) as? NSColor, Theme.Color.textPrimary)
    }

    /// Editing starts from the whole URL; leaving puts the page's back.
    func testEditingShowsTheWholeURL() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        let field = AddressField()
        field.frame = NSRect(x: 10, y: 10, width: 300, height: 16)
        window.contentView?.addSubview(field)
        field.url = "http://localhost:5173/checkout"
        XCTAssertEqual(field.stringValue, "localhost:5173/checkout")

        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertEqual(field.currentEditor()?.string, "http://localhost:5173/checkout")
        field.currentEditor()?.string = "typed"
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(field.stringValue, "localhost:5173/checkout", "the page's URL again")
        XCTAssertEqual(field.textColor, Theme.Color.textPrimary)

        // A first click selects it all, as in a browser.
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 40, y: 18), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        field.mouseDown(with: click)
        XCTAssertEqual(field.currentEditor()?.selectedRange, NSRange(location: 0, length: 30))
    }
}

/// The Project Board's header: the post-merge run's pill, the project
/// and Board Settings in ⋯, what went wrong on its own line.
@MainActor
final class ProjectBoardHeaderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let utc = TimeZone(identifier: "UTC")!

    private func run(_ status: String, _ conclusion: String?) -> ProjectBoard.WorkflowRun {
        ProjectBoard.WorkflowRun(status: status, conclusion: conclusion, headSha: "43a9503ffff",
                                 createdAt: now, updatedAt: now, url: nil)
    }

    func testRunPillSaysHowThePostMergeRunEnded() {
        let status = { ProjectBoardView.runStatus($0, workflow: "nightly.yml", now: self.now, timeZone: self.utc) }
        let passed = status(run("completed", "success"))
        XCTAssertEqual(passed.text, "nightly 08:00")
        XCTAssertEqual(passed.tone, .neutral)
        XCTAssertEqual(passed.symbol, Theme.Symbol.checksPassed)
        XCTAssertEqual(passed.symbolTone, .working)
        XCTAssertEqual(passed.toolTip, "nightly: success 08:00, 43a9503")

        let failed = status(run("completed", "failure"))
        XCTAssertEqual(failed.tone, .error)
        XCTAssertEqual(failed.symbol, Theme.Symbol.checksFailed)

        let running = status(run("in_progress", nil))
        XCTAssertEqual(running.tone, .neutral, "a run in progress waits on nobody: grey, not amber")
        XCTAssertEqual(running.symbol, Theme.Symbol.checksRunning)

        XCTAssertEqual(status(run("completed", "cancelled")).text, "nightly cancelled 08:00")
        XCTAssertEqual(status(nil).text, "nightly: no run yet")
    }

    func testHeaderMenuPicksTheProjectAndOpensSettings() throws {
        let board = ProjectBoardView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        var picked: [String] = []
        var settingsOpened = 0
        board.onSelectProject = { picked.append($0) }
        board.onBoardSettings = { settingsOpened += 1 }
        let header = ProjectBoardView.Header(
            projectName: "Board", repository: "acme/widgets", status: "Updated 21:14",
            projects: [.init(id: "a", name: "Board"), .init(id: "b", name: "Tools")], projectID: "a"
        )
        board.show(.init(header: header, body: .message("…")))
        XCTAssertEqual(board.header.context, "acme/widgets")
        XCTAssertEqual(board.refreshButton.toolTip, "Refresh · Updated 21:14")
        XCTAssertTrue(board.statusLabel.isHidden)

        let menu = board.header.currentMenu()
        let projects = try XCTUnwrap(menu.items.first { $0.title == "Project" }?.submenu)
        XCTAssertEqual(projects.items.map(\.title), ["Board", "Tools"])
        XCTAssertEqual(projects.items.map(\.state), [.on, .off])
        let tools = projects.items[1]
        _ = (tools.target as? NSObject)?.perform(tools.action, with: tools)
        XCTAssertEqual(picked, ["b"])
        let settings = try XCTUnwrap(menu.items.first { $0.title == "Board Settings…" })
        _ = (settings.target as? NSObject)?.perform(settings.action, with: settings)
        XCTAssertEqual(settingsOpened, 1)

        var failing = header
        failing.status = "Retarget #14: gh: HTTP 422"
        failing.statusIsError = true
        board.show(.init(header: failing, body: .message("…")))
        XCTAssertFalse(board.statusLabel.isHidden, "what went wrong stays in sight")
        XCTAssertEqual(board.statusLabel.stringValue, "Retarget #14: gh: HTTP 422")
        XCTAssertEqual(board.refreshButton.toolTip, "Refresh")

        var deleted = header
        deleted.projectIsMissing = true
        board.show(.init(header: deleted, body: .message("…")))
        XCTAssertEqual(board.projectMenu().items.map(\.title), ["Deleted project", "Board", "Tools"])
        XCTAssertEqual(board.projectMenu().items.map(\.state), [.on, .off, .off])
    }
}
