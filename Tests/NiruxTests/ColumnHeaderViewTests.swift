import AppKit
import XCTest
@testable import Nirux

/// The header every column shows: what gives way first, the ⋯ menu, the
/// agent's pill, and what each column type puts in it.
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
        elapsed: TimeInterval? = 720, deferred: SidebarDeferredAgent? = nil
    ) -> ColumnInfo {
        ColumnInfo(
            index: 0, processName: process, abbreviatedCwd: "~/acme", isFocused: false, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: status, isEditor: false, editorFileName: nil,
            agentElapsedSeconds: elapsed, attentionReason: reason, deferredAgent: deferred
        )
    }

    /// The visible views' drawn extents (a label's text, without its cell
    /// margins), left to right, never overlapping.
    private func assertNoOverlap(_ views: [NSView], at width: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let extents = views.filter { !$0.isHidden }.map { view in
            view is NSTextField ? view.frame.insetBy(dx: ColumnHeaderView.labelInset, dy: 0) : view.frame
        }
        for (left, right) in zip(extents, extents.dropFirst()) {
            XCTAssertLessThanOrEqual(left.maxX, right.minX, "overlap at \(width) pt", file: file, line: line)
        }
    }

    // MARK: - Layout

    /// From wide to narrow, the context goes first, then the accessories,
    /// the status and the trailing buttons; the title and ⋯ stay. Nothing
    /// overlaps, and what went never comes back at a narrower width.
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

        let slots: [(String, NSView)] = [
            ("title", header.titleLabel), ("context", header.contextLabel), ("status", header.statusPill),
            ("usage", usage), ("diff", diff), ("search", search), ("⋯", header.menuButton)
        ]
        var hiddenAt: [String: CGFloat] = [:]
        for width in stride(from: 560, through: 120, by: -2) {
            header.frame.size.width = CGFloat(width)
            header.layoutNow()
            if width == 560 { XCTAssertEqual(slots.filter { $0.1.isHidden }.map(\.0), [], "all fit at 560 pt") }
            for (name, view) in slots {
                if view.isHidden, hiddenAt[name] == nil { hiddenAt[name] = CGFloat(width) }
                if hiddenAt[name] != nil { XCTAssertTrue(view.isHidden, "\(name) came back at \(width) pt") }
            }
            assertNoOverlap(slots.map(\.1), at: CGFloat(width))
        }
        let order = ["context", "usage", "status", "diff", "search"].map { hiddenAt[$0] ?? 0 }
        XCTAssertEqual(order, order.sorted(by: >), "gave way in this order: \(hiddenAt)")
        XCTAssertTrue(order.allSatisfy { $0 > 0 }, "\(hiddenAt)")
        XCTAssertNil(hiddenAt["title"])
        XCTAssertNil(hiddenAt["⋯"])
    }

    /// The browser's bar: the trailing button goes before the leading
    /// ones, the address keeps its room until they're gone, and ⋯ stays
    /// clear of them.
    func testLeadingButtonsAndTheCenterViewGiveWayLast() {
        let header = ColumnHeaderView(frame: NSRect(x: 0, y: 0, width: 400, height: ColumnHeaderView.height))
        let back = button(Theme.Symbol.back, "Back")
        let forward = button(Theme.Symbol.forward, "Forward")
        let reload = button(Theme.Symbol.reload, "Reload")
        let inspector = button(Theme.Symbol.webInspector, "Toggle Web Inspector")
        let address = NSView()
        header.leadingButtons = [back, forward, reload]
        header.trailingButtons = [inspector]
        header.centerView = address
        header.menuProvider = { NSMenu() }

        var hiddenAt: [String: CGFloat] = [:]
        let slots: [(String, NSView)] = [
            ("back", back), ("forward", forward), ("reload", reload), ("address", address),
            ("inspector", inspector), ("⋯", header.menuButton)
        ]
        for width in stride(from: 400, through: 60, by: -2) {
            header.frame.size.width = CGFloat(width)
            header.layoutNow()
            for (name, view) in slots where view.isHidden && hiddenAt[name] == nil { hiddenAt[name] = CGFloat(width) }
            assertNoOverlap(slots.map(\.1), at: CGFloat(width))
            if !address.isHidden {
                XCTAssertGreaterThanOrEqual(address.frame.width, ColumnHeaderView.minimumTitleWidth, "at \(width) pt")
            }
        }
        let order = ["inspector", "reload", "forward", "back", "address"].map { hiddenAt[$0] ?? 0 }
        XCTAssertEqual(order, order.sorted(by: >), "gave way in this order: \(hiddenAt)")
        XCTAssertNil(hiddenAt["⋯"])
        XCTAssertEqual(header.currentMenu().items.prefix(4).map(\.title), ["Back", "Forward", "Reload", "Toggle Web Inspector"],
                       "in bar order, at the top of ⋯")
    }

    /// A button without room still acts: it heads the ⋯ menu under its
    /// own name, with its state, even in a header without a menu of its
    /// own.
    func testHiddenButtonsHeadTheMenu() {
        let header = ColumnHeaderView(frame: NSRect(x: 0, y: 0, width: 110, height: ColumnHeaderView.height))
        header.title = "ColumnHeaderView.swift"
        let diff = button(Theme.Symbol.diff, "Toggle Editor Diff")
        diff.target = self
        diff.action = #selector(dummyAction)
        diff.isOn = true
        let refresh = button(Theme.Symbol.reload, "Refresh")
        header.trailingButtons = [diff, refresh]
        header.layoutNow()
        XCTAssertFalse(header.menuButton.isHidden, "⋯ shows to hold what has no room")

        diff.toolTip = "Toggle Editor Diff · showing HEAD"
        let menu = header.currentMenu()
        XCTAssertEqual(menu.items.map(\.title), ["Toggle Editor Diff", "Refresh"], "named once, whatever the tooltip says")
        XCTAssertTrue(menu.items[0].target === self)
        XCTAssertEqual(menu.items[0].action, #selector(dummyAction))
        XCTAssertEqual(menu.items[0].state, .on)
        diff.isEnabled = false
        XCTAssertNil(header.currentMenu().items[0].action, "a disabled button's item is disabled")

        header.frame.size.width = 560
        header.layoutNow()
        XCTAssertEqual(header.overflowButtons.count, 0)
        XCTAssertTrue(header.menuButton.isHidden, "no menu of its own, nothing to hold")
    }

    @objc private func dummyAction() {}

    /// A title cut short has itself as tooltip; one read whole has none.
    func testCutShortTitleHasItsTooltip() {
        let header = ColumnHeaderView(frame: NSRect(x: 0, y: 0, width: 160, height: ColumnHeaderView.height))
        header.title = "✳ Refactor the login redirect so that it keeps the query string"
        header.layoutNow()
        XCTAssertEqual(header.titleLabel.toolTip, header.title)
        header.frame.size.width = 900
        header.layoutNow()
        XCTAssertNil(header.titleLabel.toolTip)
        header.titleToolTip = "/repo/Sources/a.swift"
        XCTAssertEqual(header.titleLabel.toolTip, "/repo/Sources/a.swift")
    }

    func testFocusTintsTheTypeSymbolButNotAnAppIcon() {
        let header = ColumnHeaderView(frame: NSRect(x: 0, y: 0, width: 400, height: ColumnHeaderView.height))
        header.icon = .symbol(Theme.Symbol.editor)
        XCTAssertEqual(header.iconView.contentTintColor, Theme.Color.textTertiary)
        header.isFocused = true
        XCTAssertEqual(header.iconView.contentTintColor, Theme.Color.accent)
        header.icon = .image(NSImage(size: NSSize(width: 16, height: 16)))
        XCTAssertNil(header.iconView.contentTintColor)
    }

    /// The edge glows sit over the headers' strip: clicks go through them.
    func testEdgeGlowLetsClicksThrough() {
        let glow = EdgeGlowView(edge: .top)
        glow.frame = NSRect(x: 0, y: 0, width: 400, height: 32)
        glow.setVisible(true)
        XCTAssertNil(glow.hitTest(NSPoint(x: 380, y: 16)))
    }

    // MARK: - Agent status

    /// Amber only while the agent waits on the user; a finished turn shows
    /// nothing; a failure is red, under one name whichever way it came.
    func testAgentPillIsAmberOnlyWhileTheAgentWaitsOnTheUser() throws {
        let reasons: [AgentAttentionReason] = [
            .permission(tool: "Bash", summary: "git push"), .permission(tool: "ExitPlanMode", summary: nil),
            .question("Which database?"), .turnFinished, .apiError(kind: "rate_limit", detail: "429"), .exitedMidTurn,
            .stillWaiting(.question(nil), waited: 600)
        ]
        for reason in reasons {
            let status = ColumnHeaderView.Status.agent(info(.needsAttention, reason: reason), wait: nil, now: 0)
            XCTAssertEqual(status?.tone == .waiting, reason.isBlockingDialog, "\(reason)")
            XCTAssertEqual(status?.tone == .error, reason.isFailure, "\(reason)")
        }
        XCTAssertNil(ColumnHeaderView.Status.agent(info(.needsAttention, reason: .turnFinished), wait: nil, now: 0))
        // Without a reason (no hooks), or a notification: maybe a dialog.
        XCTAssertEqual(ColumnHeaderView.Status.agent(info(.needsAttention), wait: nil, now: 0)?.tone, .waiting)
        XCTAssertEqual(
            ColumnHeaderView.Status.agent(info(.needsAttention, reason: .message("Claude needs you")), wait: nil, now: 0)?.tone,
            .waiting
        )

        let permission = try XCTUnwrap(ColumnHeaderView.Status.agent(
            info(.needsAttention, reason: .permission(tool: "Bash", summary: "git push")), wait: nil, now: 0
        ))
        XCTAssertEqual(permission.text, "permission · Bash")
        XCTAssertEqual(permission.symbol, Theme.Symbol.permission)
        XCTAssertEqual(permission.toolTip, "needs permission — Bash: git push")

        let apiError = AgentAttentionReason.apiError(kind: "overloaded", detail: nil)
        let fromStatus = ColumnHeaderView.Status.agent(info(.needsAttention, reason: apiError), wait: nil, now: 0)
        let fromWait = ColumnHeaderView.Status.agent(info(.idle), wait: AgentWait(reason: apiError, since: 0), now: 5)
        XCTAssertEqual(fromStatus?.text, "stopped")
        XCTAssertEqual(fromWait?.text, fromStatus?.text)

        let working = try XCTUnwrap(ColumnHeaderView.Status.agent(info(.working), wait: nil, now: 0))
        XCTAssertEqual(working.text, "working · 12m")
        XCTAssertNil(working.symbol, "a dot, which breathes")
        XCTAssertNil(ColumnHeaderView.Status.agent(info(.idle, process: "zsh"), wait: nil, now: 0))
    }

    /// A dialog on screen stays amber while the user looks at its column
    /// (its status then reads idle), with how long it has waited.
    func testOpenDialogStaysAmberOnTheFocusedColumn() throws {
        let wait = AgentWait(reason: .permission(tool: "Bash", summary: nil), since: 1_000)
        let focused = info(.idle)
        let young = try XCTUnwrap(ColumnHeaderView.Status.agent(focused, wait: wait, now: 1_030))
        XCTAssertEqual(young.tone, .waiting)
        XCTAssertEqual(young.text, "permission · Bash")
        XCTAssertEqual(ColumnHeaderView.Status.agent(focused, wait: wait, now: 1_000 + 4 * 60)?.text, "permission · Bash · 4m")

        let deferred = SidebarDeferredAgent(processName: "claude", summary: "Fix login", columnID: UUID())
        let notResumed = try XCTUnwrap(ColumnHeaderView.Status.agent(info(.idle, deferred: deferred), wait: nil, now: 0))
        XCTAssertEqual(notResumed.text, "not resumed")
        XCTAssertEqual(notResumed.tone, .neutral)
    }

    // MARK: - Columns

    func testTerminalHeaderShowsTheProcessAndItsAgent() throws {
        let column = ColumnState(cwd: "/tmp")
        let header = try XCTUnwrap(column.header)
        column.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        column.layoutWithHeader(width: 600, height: 400)
        XCTAssertEqual(header.frame, NSRect(x: 0, y: 370, width: 600, height: ColumnHeaderView.height))
        XCTAssertEqual(column.terminalView?.frame.height, 370, "the terminal starts under the header")

        column.terminalTitle = "claude"
        column.updateHeaderAgentState(info(.working), wait: nil, now: 0)
        XCTAssertEqual(header.title, "claude")
        XCTAssertNotEqual(header.icon, .symbol(Theme.Symbol.terminal), "the agent's logo")
        XCTAssertEqual(header.status?.tone, .working)

        column.updateHeaderAgentState(info(.idle, process: "zsh"), wait: nil, now: 0)
        XCTAssertEqual(header.icon, .symbol(Theme.Symbol.terminal))
        XCTAssertNil(header.status)
        XCTAssertEqual(header.currentMenu().items.first?.title, "Find in Terminal…")
    }

    func testTerminalHeaderKeepsTheDevServerChip() throws {
        let column = ColumnState(cwd: "/tmp")
        column.terminalTitle = "npm"
        column.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        column.layoutWithHeader(width: 600, height: 400)
        let header = try XCTUnwrap(column.header)

        column.setLocalServerChip(LocalServerURL(isSecure: false, host: "localhost", port: 5173, path: "/"))
        let chip = try XCTUnwrap(header.accessories.compactMap { $0 as? LocalServerChipView }.first)
        XCTAssertFalse(chip.isHidden)
        XCTAssertEqual(chip.frame.height, LocalServerChipView.height, "a capsule")
        XCTAssertEqual(chip.frame.maxX, header.menuButton.frame.minX - Theme.Space.sm)

        column.setLocalServerChip(nil)
        XCTAssertTrue(chip.isHidden, "no URL, no chip")
    }

    /// A restored agent that hasn't resumed says so wherever its title is
    /// read (Global Search).
    func testNotResumedAgentSaysSoInItsTitle() {
        let launch = DeferredAgentLaunch(agent: .claude(resume: .session("s1"), mode: .default), title: "Fix login", lastStatus: nil)
        let column = ColumnState(cwd: "/tmp", deferredAgent: launch)
        column.updateHeaderTitle(snapshot: ProcessSnapshot(entries: []))
        XCTAssertEqual(column.header?.title, "claude")
        XCTAssertEqual(column.titleText, "claude (not resumed) · /tmp")
    }

    /// Every column type's header is on top, and its ⋯ menu ends with the
    /// column's items.
    func testEveryColumnTypePutsItsHeaderOnTop() throws {
        let web = ColumnState(url: "about:blank")
        web.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let webColumn = try XCTUnwrap(web.webViewColumn)
        webColumn.frame = web.view.bounds
        webColumn.layoutSubtreeIfNeeded()
        XCTAssertTrue(web.header === webColumn.header)
        XCTAssertEqual(webColumn.header.frame.maxY, 400)
        XCTAssertLessThanOrEqual(webColumn.webView.frame.maxY, webColumn.header.frame.minY)

        let board = ProjectBoardView(frame: .zero)
        board.frame.size = NSSize(width: 600, height: 400)
        XCTAssertEqual(board.header.frame, NSRect(x: 0, y: 0, width: 600, height: ColumnHeaderView.height), "flipped: on top")

        let editor = makeEditor(root: FileManager.default.temporaryDirectory.path)
        let terminal = ColumnState(cwd: "/tmp")
        for header in [web.header, board.header, editor.header, terminal.header].compactMap({ $0 }) {
            XCTAssertEqual(header.currentMenu().items.suffix(5).map(\.title),
                           ["Move Left", "Move Right", "Cycle Width", "", "Close Column"])
        }
    }

    func testEditorHeaderNamesTheActiveFileAndItsDiff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("header-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root + "/Sources/App", withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        try "let a = 1\n".write(toFile: root + "/Sources/App/main.swift", atomically: true, encoding: .utf8)

        let editor = makeEditor(root: root)
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
        XCTAssertEqual(editor.header.currentMenu().items.first?.title, "Save All")
    }

    func testEditorContextIsTheDirectoryInTheWorkspace() {
        XCTAssertEqual(EditorColumn.directoryContext(of: "/repo/README.md", workspaceCwd: "/repo"), "")
        XCTAssertEqual(EditorColumn.directoryContext(of: "/repo/Sources/A/b.swift", workspaceCwd: "/repo/"), "Sources/A")
        XCTAssertEqual(EditorColumn.directoryContext(of: "/repository/b.swift", workspaceCwd: "/repo"), "/repository")
    }

    /// An editor in a window: leaving it ends its file watch and frees its
    /// script handler, as closing its column does in the app.
    private func makeEditor(root: String) -> EditorColumn {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let editor = EditorColumn(workspaceCwd: root)
        window.contentView?.addSubview(editor)
        addTeardownBlock {
            editor.removeFromSuperview()
            window.close()
        }
        return editor
    }
}

/// The ⋯ items act on their own column, whichever has the focus.
@MainActor
final class ColumnHeaderMenuFlowTests: XCTestCase {
    func testColumnItemsActOnTheirOwnColumn() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.addColumn()
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertEqual(workspace.columns.count, 2)
            let first = workspace.columns[0]
            let second = workspace.columns[1]
            shell.focusColumnByIndex(1)
            let widthBefore = first.widthFraction

            harness.perform(["Cycle Width"], in: try XCTUnwrap(first.header).currentMenu())
            XCTAssertEqual(workspace.focusedIndex, 0, "the item's column took the focus")
            XCTAssertNotEqual(first.widthFraction, widthBefore)

            shell.focusColumnByIndex(0)
            harness.perform(["Close Column"], in: try XCTUnwrap(second.header).currentMenu())
            harness.waitUntil("its column closes") { workspace.columns.count == 1 }
            XCTAssertTrue(workspace.columns.first === first, "the other column stays")
        }
    }
}

/// The browser header's address field.
@MainActor
final class WebAddressFieldTests: XCTestCase {
    func testAtRestTheHostIsDimmedBeforeThePath() {
        let cases: [(String, String, String)] = [
            ("https://github.com/acme/app", "github.com/", "acme/app"),
            ("HTTPS://Example.com/a?b=c#d", "Example.com/", "a?b=c#d"),
            ("https://github.com", "", "github.com"),
            ("http://localhost:5173/checkout", "http://localhost:5173/", "checkout"),
            ("http://localhost:5173", "http://", "localhost:5173"),
            ("about:blank", "", "about:blank"),
            ("file:///tmp/a.html", "", "file:///tmp/a.html")
        ]
        for (url, dimmed, primary) in cases {
            let parts = AddressField.displayParts(url)
            XCTAssertEqual(parts.dimmed, dimmed, url)
            XCTAssertEqual(parts.primary, primary, url)
        }
        let display = AddressField.display("https://github.com/acme")
        XCTAssertEqual(display.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, Theme.Color.textTertiary)
        XCTAssertEqual(display.attribute(.foregroundColor, at: 11, effectiveRange: nil) as? NSColor, Theme.Color.textPrimary)
    }

    /// Editing starts from the whole URL; ⌘L or a click on the box's margin
    /// while editing keeps what was typed; leaving puts the page's back.
    func testEditingKeepsWhatWasTyped() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        let field = AddressField()
        let box = AddressBox(frame: NSRect(x: 10, y: 10, width: 320, height: 22))
        box.field = field
        window.contentView?.addSubview(box)
        field.url = "https://github.com/acme"
        XCTAssertEqual(field.stringValue, "github.com/acme")

        field.beginEditing()
        let editor = try XCTUnwrap(field.currentEditor())
        XCTAssertEqual(editor.string, "https://github.com/acme")
        editor.string = "localhost:30"
        field.beginEditing()
        XCTAssertEqual(field.currentEditor()?.string, "localhost:30", "⌘L selects what was typed")
        XCTAssertEqual(field.currentEditor()?.selectedRange, NSRange(location: 0, length: 12))
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 13, y: 12), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        box.mouseDown(with: click)
        XCTAssertEqual(field.currentEditor()?.string, "localhost:30", "a click on the margin keeps it")

        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(field.stringValue, "github.com/acme", "the page's URL again")
    }
}

/// The Project Board's header: the post-merge run's pill, what went wrong
/// in its place, the project and Board Settings in ⋯.
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
        XCTAssertEqual(passed.symbolTone, .success)
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

        let menu = board.header.currentMenu()
        let projects = try XCTUnwrap(menu.items.first { $0.title == "Project" }?.submenu)
        XCTAssertEqual(projects.items.map(\.title), ["Board", "Tools"])
        XCTAssertEqual(projects.items.map(\.state), [.on, .off])
        projects.performActionForItem(at: 1)
        XCTAssertEqual(picked, ["b"])
        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "Board Settings…" }))
        XCTAssertEqual(settingsOpened, 1)

        var deleted = header
        deleted.projectIsMissing = true
        board.show(.init(header: deleted, body: .message("…")))
        XCTAssertEqual(board.projectMenu().items.map(\.title), ["Deleted project", "Board", "Tools"])
        XCTAssertEqual(board.projectMenu().items.map(\.state), [.on, .off, .off])
    }

    /// What went wrong takes the run's place as a red pill: the rows under
    /// the header never move.
    func testAnErrorShowsInTheHeaderWithoutMovingTheRows() throws {
        let board = ProjectBoardView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        var header = ProjectBoardView.Header(
            projectName: "Board", repository: "acme/widgets",
            postMergeRun: ProjectBoardView.runStatus(run("completed", "success"), workflow: "nightly.yml", now: now),
            status: "Updated 21:14", projects: [.init(id: "a", name: "Board")], projectID: "a"
        )
        board.show(.init(header: header, body: .message("…")))
        let rowsTop = try XCTUnwrap(board.subviews.compactMap { $0 as? NSScrollView }.first).frame.minY

        header.status = "Retarget #14: gh: HTTP 422"
        header.statusIsError = true
        board.show(.init(header: header, body: .message("…")))
        let pill = try XCTUnwrap(board.header.status)
        XCTAssertEqual(pill.tone, .error)
        XCTAssertEqual(pill.text, "GitHub error")
        XCTAssertEqual(pill.toolTip, "Retarget #14: gh: HTTP 422")
        XCTAssertEqual(board.refreshButton.toolTip, "Refresh")
        XCTAssertEqual(board.subviews.compactMap { $0 as? NSScrollView }.first?.frame.minY, rowsTop)
    }
}
