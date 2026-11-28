import AppKit
import XCTest
@testable import Nirux

/// Runs every command of the palette in a real window (see UIFlowHarness),
/// the way a user does: type its title, pick it, press Return. The nightly
/// once shipped a panel that crashed as it opened (#46) because no test
/// opened it; here, a new command without a test fails
/// `testEveryPaletteCommandHasAFlowTest`.
@MainActor
final class PaletteCommandFlowTests: UIFlowTestCase {
    /// The palette commands each test runs: all of them, and no other.
    /// Every command of the palette is listed here or exempted with the
    /// reason; keep the exemptions empty unless a command truly can't run
    /// in CI.
    static let commandCoverage = UIFlowCoverage(
        kind: .paletteCommand,
        tests: [
            "testTerminalColumnCommands": ["New Terminal", "Resize Column (Cycle Width)"],
            "testEditorCommands": ["Open Editor", "Toggle Editor Diff", "Search Workspace"],
            "testOpenInYourEditorCommand": ["Open in Zed"],
            "testSearchEverywhere": ["Search Everywhere"],
            "testBrowserCommands": ["Open Browser", "Toggle Web Inspector"],
            "testOpenIsolatedTestBrowser": ["Open Isolated Test Browser"],
            "testImportBrowserCookies": ["Import Browser Cookies"],
            "testAgentCommands": ["Open Claude Code", "Open Codex", "Open Antigravity", "Next Waiting Agent"],
            "testSessionHistoryCommand": ["Session History…"],
            "testTokenUsageCommand": ["Token Usage"],
            "testWhatsNewCommand": ["What’s New"],
            "testRestartLeadCommand": [NiruxShellView.restartLeadTitle],
            "testPromoteToLeadCommand": [NiruxShellView.promoteToLeadTitle],
            "testProjectMemoryCommand": ["Space Memory…"],
            "testResumeAllAgentsCommand": ["Resume All Agents"],
            "testWorkspaceCommands": ["Rename Workspace", "Show/Hide Sidebar", "Show/Hide Archived", "Open Board"],
            "testWorktreeCommands": ["Open Worktree", "Clean Up Merged Worktrees…"],
            "testNewCommand": ["New…"],
            "testCheckpointCommands": ["Save Checkpoint…", "Checkpoints…"],
            "testReviewBranchCommand": ["Review Branch"],
            "testSetupCommands": ["Show Getting Started", "Install Agent Skills", "Open Settings"]
        ],
        exemptions: [:]
    )

    override class var coverage: UIFlowCoverage? { commandCoverage }

    // MARK: - Guard

    func testEveryPaletteCommandHasAFlowTest() throws {
        try UIFlowHarness.run { harness in
            // Import Browser Cookies is offered only with a Chromium browser,
            // Open in Zed only with Zed installed and set to open files.
            harness.cookieSources = [UIFlowHarness.cookieSource(.chrome)]
            harness.shell.sideEffects.applicationURL = { $0 == "dev.zed.Zed" ? URL(fileURLWithPath: "/Applications/Zed.app") : nil }
            XCTAssertTrue(Persistence.updateSettings(liveLayout: nil) { $0.openFilesIn = "dev.zed.Zed" })
            let titles = harness.paletteCommandTitles()
            XCTAssertEqual(titles.count, Set(titles).count, "two palette commands share a title: \(titles)")
            // Restart Lead… is offered only in a space with a Lead, Promote to
            // Lead… on a task of a space that can have one.
            let lead = try harness.makeLead()
            harness.shell.addWorkspace(title: "task", cwd: harness.worktree, profileID: lead.space)
            let withLead = harness.paletteCommandTitles()
            XCTAssertEqual(withLead.count, Set(withLead).count, "two palette commands share a title: \(withLead)")
            Self.commandCoverage.checkEveryItemIsCovered(
                offered: Array(Set(titles + withLead)), testNames: UIFlowCoverage.testNames(of: Self.self)
            )
        }
    }

    /// A symbol newer than the deployment target draws nothing there, and
    /// CI runs a later macOS: check each against the system's list of when
    /// symbols shipped.
    func testPaletteSymbolsShipWithMacOS14() throws {
        let availability = try SymbolAvailability()
        try UIFlowHarness.run { harness in
            harness.cookieSources = [UIFlowHarness.cookieSource(.chrome)]
            var names = ["circle.fill", "command"] + CodingAgent.allCases.map(\.symbolName)
            for action in harness.paletteCommands() {
                if case .symbol(let name) = action.icon { names.append(name) }
            }
            for name in names {
                XCTAssertTrue(try availability.ships(name, byMacOS: [14, 0]), name)
            }
        }
    }

    // MARK: - Columns

    func testTerminalColumnCommands() throws {
        try UIFlowHarness.run { harness in
            let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
            let columnCount = workspace.columns.count

            harness.runPaletteCommand("New Terminal")
            XCTAssertEqual(workspace.columns.count, columnCount + 1)
            let column = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex])
            XCTAssertNotNil(column.terminalView)
            XCTAssertIdentical(workspace.columns.last, column)

            let width = column.widthFraction
            harness.runPaletteCommand("Resize Column (Cycle Width)")
            XCTAssertNotEqual(column.widthFraction, width)
        }
    }

    func testEditorCommands() throws {
        try UIFlowHarness.run { harness in
            let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
            let readme = harness.repo + "/README.md"

            harness.runPaletteCommand("Open Editor")
            let editor = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.editorColumn)
            XCTAssertEqual(editor.workspaceCwd, harness.repo)
            harness.waitUntil("the editor to open README.md") { editor.activePath == readme }

            // README.md differs from HEAD: git reads the original off the
            // main thread.
            harness.runPaletteCommand("Toggle Editor Diff")
            harness.waitUntil("the diff of README.md") { editor.diffActivePath == readme }

            // rg or grep streams its results from a background queue.
            harness.runPaletteCommand("Search Workspace")
            let field = try XCTUnwrap(harness.waitForField(placeholder: "Search workspace…"))
            harness.type(UIFlowHarness.searchNeedle, into: field)
            let table = try XCTUnwrap(field.window?.contentView.flatMap {
                UIFlowHarness.descendant(of: $0, as: NSTableView.self)
            })
            harness.waitUntil("a search result") { table.numberOfRows > 0 && table.selectedRow == 0 }
            harness.press(.returnKey, in: field.window)
            let target = harness.repo + "/" + UIFlowHarness.searchTarget
            harness.waitUntil("the result to open in the editor") { editor.activePath == target }
            XCTAssertFalse(field.window?.isVisible ?? true, "the search panel stayed open")
            XCTAssertEqual(workspace.columns.compactMap(\.editorColumn).count, 1, "the result opened a second editor")
        }
    }

    /// The match sits far up the scrollback of a terminal in another
    /// workspace, and more matches are printed after the search: picking it
    /// brings that column forward, find bar open, and Ghostty scrolls to
    /// that very match.
    /// With "Open files in" on an editor installed, Open in <editor> opens
    /// the workspace's folder there.
    func testOpenInYourEditorCommand() throws {
        try UIFlowHarness.run { harness in
            var opened: [String] = []
            harness.shell.sideEffects.applicationURL = { $0 == "dev.zed.Zed" ? URL(fileURLWithPath: "/Applications/Zed.app") : nil }
            harness.shell.sideEffects.openInApplication = { url, _, done in
                opened.append(url.absoluteString)
                done(true)
            }
            XCTAssertTrue(Persistence.updateSettings(liveLayout: nil) { $0.openFilesIn = "dev.zed.Zed" })
            harness.runPaletteCommand("Open in Zed")
            XCTAssertEqual(opened, ["zed://file" + (try XCTUnwrap(harness.shell.activeWorkspace)).focusedWorkingDirectory])
        }
    }

    func testSearchEverywhere() throws {
        try UIFlowHarness.run { harness in
            let home = try XCTUnwrap(harness.shell.activeWorkspace)
            harness.shell.addWorkspace(title: "other", cwd: harness.worktree)
            let other = try XCTUnwrap(harness.shell.activeWorkspace)
            let column = try XCTUnwrap(other.columns.first)
            let pty = try XCTUnwrap(column.pty)
            let session = pty.terminalSession
            // The terminal's text comes from its shell, as a program's output
            // does: lines written behind the shell's back are the line
            // editor's to paint over (CI's bash redraws its wrapping prompt
            // on a SIGWINCH). The command it runs holds no match.
            @MainActor func shellPrints(_ lines: [String], as name: String, line: UInt = #line) throws {
                harness.waitUntil("the shell's prompt", line: line) {
                    pty.readsKeysAsTyped && pty.foregroundProcess(snapshot: ProcessSnapshot())?.instance.pid == pty.shellPID
                }
                let path = harness.root + "/\(name).txt"
                try lines.map { $0 + "\n" }.joined().write(toFile: path, atomically: true, encoding: .utf8)
                pty.sendRaw("cat '\(path)'\n")
            }
            let needle = "flow-scrollback-needle"
            try shellPrints((1...200).map { [20, 100, 150].contains($0) ? "\(needle) \($0)" : "row \($0)" }, as: "scrollback")
            harness.waitUntil("the rows on screen") { session.readViewportText()?.contains("row 200") == true }
            XCTAssertFalse(session.readViewportText()?.contains("\(needle) 100\n") ?? true, "the match starts on screen")
            harness.shell.focusWorkspace(id: home.id)

            harness.runPaletteCommand("Search Everywhere")
            let field = try XCTUnwrap(harness.waitForField(placeholder: GlobalSearchPanel.placeholder))
            harness.type(needle.uppercased(), into: field)
            let panel = try XCTUnwrap(harness.shell.globalSearchPanel)
            harness.waitUntil("the search to end") { !panel.isSearching && !panel.rows.isEmpty }
            XCTAssertEqual(panel.rows.map(\.excerpt), ["\(needle) 150", "\(needle) 100", "\(needle) 20"])
            XCTAssertEqual(panel.rows.map(\.place), Array(repeating: "other › Terminal 1", count: 3))
            XCTAssertEqual(panel.statusLabel?.stringValue, "3 matches in 1 of 2 terminals")

            try shellPrints(["\(needle) 201", "\(needle) 202"], as: "new-matches")
            harness.waitUntil("the new matches") { TerminalScreenText.read(session)?.contains("\(needle) 202") == true }
            harness.press(.down, in: field.window)
            harness.press(.returnKey, in: field.window)
            XCTAssertFalse(panel.isVisible)
            XCTAssertIdentical(harness.shell.activeWorkspace, other)
            XCTAssertIdentical(other.columns[safe: other.focusedIndex], column)
            XCTAssertTrue(column.isEditingFind)
            XCTAssertEqual(column.findBar?.field.stringValue, needle.uppercased())
            harness.waitUntil("Ghostty to scroll to the picked match") {
                session.readViewportText()?.contains("\(needle) 100\n") == true
            }
        }
    }

    /// The panel keeps no column alive: closing one it searched, and found
    /// matches in, ends its shell, even with the panel still open.
    func testSearchEverywhereLetsClosedColumnsGo() throws {
        try UIFlowHarness.run { harness in
            weak var closedShell: PtySession?
            let needle = "flow-closing-needle"
            try {
                harness.shell.addColumn()
                let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
                let pty = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.pty)
                closedShell = pty
                harness.waitUntil("the terminal's surface") { pty.terminalSession.readViewportText() != nil }
                pty.terminalSession.receive("\(needle)\r\n")
            }()
            harness.shell.showGlobalSearch()
            let panel = try XCTUnwrap(harness.shell.globalSearchPanel)
            let field = try XCTUnwrap(panel.searchField)
            harness.type(needle, into: field)
            harness.waitUntil("the match") { !panel.isSearching && panel.rows.count == 1 }

            harness.shell.closeActiveColumn()
            harness.waitUntil("the closed column's shell to go") { closedShell == nil }
            XCTAssertTrue(panel.isVisible)
        }
    }

    /// Offered on the active task: a task with no agent hears why.
    func testPromoteToLeadCommand() throws {
        try UIFlowHarness.run { harness in
            XCTAssertFalse(harness.paletteCommandTitles().contains(NiruxShellView.promoteToLeadTitle), "no task in General")
            let lead = try harness.makeLead()
            harness.shell.addWorkspace(title: "Grown", cwd: harness.worktree, profileID: lead.space)
            let task = try XCTUnwrap(harness.shell.activeWorkspace)
            harness.waitUntil("its shell in front") {
                guard let pty = task.columns.first?.pty, let shellPID = pty.shellPID else { return false }
                return pty.foregroundProcess(snapshot: ProcessSnapshot())?.instance.pid == shellPID
            }
            harness.runPaletteCommand(NiruxShellView.promoteToLeadTitle)
            XCTAssertEqual(harness.shell.toast?.message, "No agent runs in this task: there is no conversation to promote.")
            XCTAssertEqual(harness.terminalRestarts, [])
        }
    }

    /// Offered in a space with a Lead: it asks first.
    func testRestartLeadCommand() throws {
        try UIFlowHarness.run { harness in
            XCTAssertFalse(harness.paletteCommandTitles().contains(NiruxShellView.restartLeadTitle), "no Lead in General")
            _ = try harness.makeLead()
            harness.runPaletteCommand(NiruxShellView.restartLeadTitle)
            XCTAssertEqual(harness.alerts.last, "Restart the Lead of “Tools”?")
            XCTAssertEqual(harness.terminalRestarts, [], "cancelled")
        }
    }

    /// Fresh start on the Lead's card asks as Restart Lead does; a restart
    /// hands the new conversation its handover and says it started.
    func testALeadsFreshStartAsksAndHandsItsConversationOver() throws {
        try UIFlowHarness.run { harness in
            let lead = try harness.makeLead()
            harness.waitUntil("the Lead's shell") { lead.workspace.leadTerminal?.pty?.shellPID != nil }
            let index = try XCTUnwrap(harness.shell.workspaces.firstIndex { $0 === lead.workspace })
            let column = try XCTUnwrap(lead.workspace.columns.firstIndex { $0 === lead.workspace.leadTerminal })
            harness.shell.takeContextOffer(.freshStart, workspaceIndex: index, columnIndex: column)
            harness.waitUntil("the confirmation") { harness.alerts.last == "Restart the Lead of “Tools”?" }
            XCTAssertEqual(harness.terminalRestarts, [], "cancelled")

            var started: Bool?
            harness.shell.restartLead(
                lead.workspace, agent: .claude, handover: ["Last conversation entry: Queue #824 when green."], focus: false
            ) { started = $0 }
            harness.waitUntil("the restart") { started != nil }
            XCTAssertEqual(started, true)
            XCTAssertEqual(harness.terminalRestarts.count, 1)
            XCTAssertTrue(harness.terminalRestarts.last?.contains("Queue #824 when green.") == true)
        }
    }

    /// The cached changelog shows at once, the published one replaces it;
    /// the internal work and the search filter it, and each number links
    /// its pull request.
    func testWhatsNewCommand() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let published = Changelog(entries: [
                Changelog.Entry(pullRequest: 913, title: "⌘P: open a pull request by its number", why: "Finding a PR meant scanning the Board.",
                                kind: .new, build: 202611251854),
                Changelog.Entry(pullRequest: 917, title: "Tests: a calmer clock", why: nil, kind: .internal, build: 202611251854),
                Changelog.Entry(pullRequest: 905, title: "Columns: pin a column", why: nil, kind: .better, build: 202611250520)
            ])
            let data = try JSONEncoder().encode(published)
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent("changelog-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: cache) }
            shell.changelogStore = ChangelogStore(
                feed: "https://github.com/xikimay/nirux/releases/download/nightly/appcast.xml", cache: cache,
                load: { _ in data }, onChange: { [weak shell] in shell?.changelogDidChange() }
            )

            harness.runPaletteCommand("What’s New")
            let controller = try XCTUnwrap(shell.whatsNewWindow)
            defer { controller.close() }
            harness.waitUntil("the published changelog") { controller.textView.string.contains("⌘P: open a pull request by its number") }
            let text = { controller.textView.string }
            XCTAssertTrue(text().contains("Finding a PR meant scanning the Board."))
            XCTAssertTrue(text().contains("Columns: pin a column"))
            XCTAssertFalse(text().contains("Tests: a calmer clock"))
            let storage = try XCTUnwrap(controller.textView.textStorage)
            let number = (storage.string as NSString).range(of: "#913")
            XCTAssertEqual(storage.attribute(.link, at: number.location, effectiveRange: nil) as? URL,
                           URL(string: "https://github.com/xikimay/nirux/pull/913"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))

            controller.showsInternal.performClick(nil)
            XCTAssertTrue(text().contains("Tests: a calmer clock"))
            controller.search.stringValue = "pull request"
            XCTAssertTrue(controller.search.sendAction(controller.search.action, to: controller.search.target))
            XCTAssertTrue(text().contains("#913"))
            XCTAssertFalse(text().contains("Columns: pin a column"))
            let store = try XCTUnwrap(shell.changelogStore)
            harness.waitUntil("the fetch to end") { !store.isRefreshing }
        }
    }

    /// After an update, the card lists what the builds since the last one
    /// seen brought; See All opens the window and marks the build seen, so
    /// the next launch shows no card.
    func testWhatsNewCardAfterAnUpdate() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let seenFile = FileManager.default.temporaryDirectory.appendingPathComponent("whats-new-seen-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: seenFile) }
            shell.sideEffects.whatsNewSeenFile = seenFile
            shell.sideEffects.installedBuild = { 202611251854 }
            try "202611242135".write(to: seenFile, atomically: true, encoding: .utf8)
            let published = Changelog(entries: [
                Changelog.Entry(pullRequest: 913, title: "⌘P: open a pull request by its number", why: nil, kind: .new, build: 202611251854),
                Changelog.Entry(pullRequest: 917, title: "Tests: a calmer clock", why: nil, kind: .internal, build: 202611251854),
                Changelog.Entry(pullRequest: 906, title: "Missions: Enter is never pressed for an agent that left", why: nil,
                                kind: .fixed, build: 202611250520),
                Changelog.Entry(pullRequest: 896, title: "Columns: drag a column by its header", why: nil, kind: .new, build: 202611242135)
            ])
            let data = try JSONEncoder().encode(published)
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent("changelog-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: cache) }
            shell.changelogStore = ChangelogStore(
                feed: "https://github.com/xikimay/nirux/releases/download/nightly/appcast.xml", cache: cache,
                load: { _ in data }, onChange: { [weak shell] in shell?.changelogDidChange() }
            )

            shell.startWhatsNewAfterUpdate()
            harness.waitUntil("the card after the update") { shell.whatsNewCard != nil }
            let card = try XCTUnwrap(shell.whatsNewCard)
            XCTAssertTrue(card.text.contains("⌘P: open a pull request by its number"))
            XCTAssertTrue(card.text.contains("Missions: Enter is never pressed for an agent that left"))
            XCTAssertTrue(card.text.contains("2 nightlies, 2 changes"))
            XCTAssertTrue(card.text.contains("1 under the hood"))
            XCTAssertFalse(card.text.contains("Columns: drag a column by its header"), "the build already seen")
            XCTAssertEqual(shell.lastSeenBuild, 202611242135, "seen only once put away")

            card.primaryButton.performClick(nil)
            XCTAssertNil(shell.whatsNewCard)
            let window = try XCTUnwrap(shell.whatsNewWindow)
            defer { window.close() }
            XCTAssertTrue(window.window?.isVisible == true)
            XCTAssertEqual(shell.lastSeenBuild, 202611251854)
            let store = try XCTUnwrap(shell.changelogStore)
            harness.waitUntil("the window's fetch") { !store.isRefreshing }
            shell.startWhatsNewAfterUpdate()
            XCTAssertNil(shell.whatsNewCard, "a later launch of the same build")
        }
    }

    /// Before an update: the status bar counts what it brings since this
    /// build once the changelog holds it, and its popover lists the changes
    /// and installs.
    func testUpdatePopoverBeforeInstalling() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.sideEffects.installedBuild = { 202611242135 }
            shell.sideEffects.whatsNewSeenFile = FileManager.default.temporaryDirectory.appendingPathComponent("whats-new-seen-\(UUID().uuidString)")
            let published = Changelog(entries: [
                Changelog.Entry(pullRequest: 913, title: "⌘P: open a pull request by its number", why: nil, kind: .new, build: 202611251854),
                Changelog.Entry(pullRequest: 917, title: "Tests: a calmer clock", why: nil, kind: .internal, build: 202611251854),
                Changelog.Entry(pullRequest: 906, title: "Missions: Enter is never pressed for an agent that left", why: nil,
                                kind: .fixed, build: 202611250520),
                Changelog.Entry(pullRequest: 896, title: "Columns: drag a column by its header", why: nil, kind: .new, build: 202611242135)
            ])
            let data = try JSONEncoder().encode(published)
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent("changelog-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: cache) }
            shell.changelogStore = ChangelogStore(
                feed: "https://github.com/xikimay/nirux/releases/download/nightly/appcast.xml", cache: cache,
                load: { _ in data }, onChange: { [weak shell] in shell?.changelogDidChange() }
            )
            var installs = 0
            let notice = { shell.statusBar.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("● Update") }?.stringValue }

            shell.showAvailableUpdate(AvailableUpdate(build: 202611251854, isReady: true) { installs += 1 })
            harness.waitUntil("the update's changes") { notice() == "● Update ready · 2 changes" }
            shell.statusBar.onInstall?()
            let popover = try XCTUnwrap(shell.updatePopover)
            harness.waitUntil("the update's popover") { popover.isShown }
            let view = try XCTUnwrap(popover.contentViewController?.view as? WhatsNewCardView)
            XCTAssertTrue(view.text.contains("is ready"))
            XCTAssertTrue(view.text.contains("⌘P: open a pull request by its number"))
            XCTAssertTrue(view.text.contains("Missions: Enter is never pressed for an agent that left"))
            XCTAssertTrue(view.text.contains("1 under the hood"))
            XCTAssertFalse(view.text.contains("Columns: drag a column by its header"), "already in this build")

            view.primaryButton.performClick(nil)
            XCTAssertEqual(installs, 1)
            harness.waitUntil("the popover to close") { !popover.isShown }
            XCTAssertEqual(shell.lastSeenBuild, 202611251854, "listed here: no card after the relaunch")

            shell.showUpdatePopover()
            let again = try XCTUnwrap(shell.updatePopover)
            harness.waitUntil("the popover from Check for Updates…") { again.isShown }
            again.close()
            harness.waitUntil("the popover to close again") { !again.isShown }
        }
    }

    func testTokenUsageCommand() throws {
        try UIFlowHarness.run { harness in
            let now = Date().timeIntervalSince1970
            let limit = try XCTUnwrap(QuotaLimit(
                agent: .claude, length: 5 * 3_600, readings: [QuotaReading(time: now - 60, usedPercent: 40, resetsAt: now + 3_600)], now: now
            ))
            let readings = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
            harness.shell.usageWindowQuota = { ([limit], readings) }
            harness.runPaletteCommand("Token Usage")
            let controller = try XCTUnwrap(harness.shell.usageWindow)
            defer { controller.close() }
            harness.waitUntil("the Usage window") { controller.window?.isVisible == true }
            XCTAssertEqual(controller.headline.stringValue, "Reading the agents’ transcripts…")
            XCTAssertEqual(controller.limitsStack.arrangedSubviews.count, 1, "the limits show before the first report")
            harness.shell.usageWindowQuota = { nil }
            harness.shell.updateUsageWindowLimits()
            XCTAssertTrue(controller.limitsStack.isHidden, "the option off, the limits go")

            let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
            let session = UsageSession(
                key: UsageSessionKey(.claude, "s"), attribution: UsageAttribution(spaceID: workspace.profileID, taskID: workspace.id),
                events: [
                    UsageEvent(timestamp: now - 2 * 86_400, counts: TokenCounts(input: 1_500)),
                    UsageEvent(timestamp: now - 60, counts: TokenCounts(input: 500))
                ]
            )
            controller.update(report: UsageReport(sessions: [session], now: now), names: harness.shell.usageNames())
            XCTAssertEqual(controller.headline.stringValue, "2k tokens · 2 responses · 1 session")
            controller.period.selectedSegment = 0
            NSApp.sendAction(try XCTUnwrap(controller.period.action), to: controller.period.target, from: controller.period)
            XCTAssertEqual(controller.headline.stringValue, "500 tokens · 1 response · 1 session")
        }
    }

    /// The project's sessions, the one a restored column holds first; the
    /// switches; under the list, what Return does: going to the restored
    /// column resumes its agent there, Return on an ended one resumes it.
    func testSessionHistoryCommand() throws {
        try UIFlowHarness.run { harness in
            let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
            let restoredID = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"
            let pastID = "6f1c2a3e-0d4b-4e5f-8a9b-1c2d3e4f5a60"
            var reviewed = SessionHistoryFlowTests.session(
                "b2c3d4e5-f6a7-4b8c-9d0e-1f2a3b4c5d6e", title: "reviewed-task", folder: harness.repo, hoursAgo: 5
            )
            reviewed.pullRequest = AgentSessionRecord.PullRequest(number: 7, url: "", state: "MERGED")
            try SessionHistoryFlowTests.seed([
                SessionHistoryFlowTests.session(restoredID, title: "restored-task", folder: harness.repo),
                SessionHistoryFlowTests.session(pastID, title: "past-task", folder: harness.worktree, workspaceID: workspace.id, hoursAgo: 3),
                reviewed
            ], in: harness)
            workspace.addColumn(
                deferredAgent: DeferredAgentLaunch(launch: .claude(resume: .session(restoredID), mode: .default), title: nil, lastStatus: nil),
                agentUUID: UUID().uuidString, cwd: harness.repo
            )
            let restoredColumn = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex])
            @MainActor func titles(_ panel: SessionHistoryPanel) -> [String] { panel.rows.map { SessionHistory.title(of: $0.record) } }
            @MainActor func pick(_ segment: Int, of control: NSSegmentedControl?) throws {
                let control = try XCTUnwrap(control)
                control.selectedSegment = segment
                XCTAssertTrue(control.sendAction(control.action, to: control.target))
            }

            harness.runPaletteCommand("Session History…")
            let panel = try XCTUnwrap(harness.shell.sessionHistoryPanel)
            XCTAssertTrue(panel.isVisible)
            XCTAssertEqual(panel.items, [.header("Open"), .row(0), .header("Ended"), .row(1), .row(2)])
            XCTAssertEqual(titles(panel), ["restored-task", "past-task", "reviewed-task"])
            XCTAssertTrue(panel.actionLabel?.stringValue.hasPrefix("↩ Go to repo › ") == true)
            XCTAssertEqual(panel.resumeButton?.title, "Go To")

            let field = try XCTUnwrap(panel.searchField)
            harness.type("nothing-like-it", into: field)
            XCTAssertEqual(panel.items, [])
            XCTAssertEqual(panel.actionLabel?.stringValue, "No session matches")
            harness.type("", into: field)
            try pick(1, of: panel.pullRequestControl)
            XCTAssertEqual(titles(panel), ["reviewed-task"])
            try pick(2, of: panel.pullRequestControl)
            XCTAssertEqual(titles(panel), ["restored-task", "past-task"])
            try pick(0, of: panel.pullRequestControl)
            try pick(2, of: panel.agentControl)
            XCTAssertEqual(panel.items, [], "no Codex session")
            try pick(0, of: panel.agentControl)

            harness.press(.escape, in: field.window)
            XCTAssertFalse(panel.isVisible)

            // The restored column comes forward and resumes its agent.
            workspace.focusedIndex = 0
            harness.shell.showSessionHistory()
            harness.press(.returnKey, in: field.window)
            XCTAssertFalse(panel.isVisible)
            XCTAssertIdentical(workspace.columns[safe: workspace.focusedIndex], restoredColumn)
            XCTAssertEqual(harness.restoredAgentLaunches.count, 1)
            XCTAssertEqual(harness.agentLaunches, [])

            harness.shell.showSessionHistory()
            XCTAssertEqual(panel.selectedRow.map { SessionHistory.title(of: $0.record) }, "restored-task")
            harness.press(.down, in: field.window)
            XCTAssertEqual(panel.selectedRow.map { SessionHistory.title(of: $0.record) }, "past-task")
            harness.waitUntil("its plan") { panel.actionLabel?.stringValue == "↩ Resume in \(harness.worktree.abbreviatedPath())" }
            XCTAssertEqual(panel.resumeButton?.title, "Resume")
            harness.press(.returnKey, in: field.window)
            XCTAssertFalse(panel.isVisible)
            harness.waitUntil("the resume") { harness.agentLaunches.count == 1 }
            XCTAssertTrue(harness.agentLaunches[0].hasPrefix("command claude --resume '\(pastID)'"))
        }
    }

    /// What agents know about the repository, in one list: the project
    /// brief's rule, the worktree's CLAUDE.md, the memory Claude Code keeps
    /// in the test's home folder for the main checkout (every worktree
    /// shares it), and its index line without a file. A link selects the
    /// memory it names, clearing the filter; Return opens an item's file,
    /// at its line.
    func testProjectMemoryCommand() throws {
        try UIFlowHarness.run { harness in
            let memory = harness.home + "/.claude/projects/" + ProjectMemory.encodedProjectName(harness.repo) + "/memory"
            try FileManager.default.createDirectory(atPath: memory, withIntermediateDirectories: true)
            try "- [Flow rules](flow-rules.md) — how flows run\n- [Gone](gone.md) — no file\n"
                .write(toFile: memory + "/MEMORY.md", atomically: true, encoding: .utf8)
            try "---\nname: flow-rules\ndescription: How flows run\nmetadata:\n  type: feedback\n---\n\nSee [[harness-notes]].\n"
                .write(toFile: memory + "/flow-rules.md", atomically: true, encoding: .utf8)
            try "---\nname: harness-notes\ndescription: Not indexed\nmetadata:\n  type: reference\n---\n\nNotes.\n"
                .write(toFile: memory + "/harness-notes.md", atomically: true, encoding: .utf8)
            try "Team rule: build first.\n".write(toFile: harness.worktree + "/CLAUDE.md", atomically: true, encoding: .utf8)
            harness.shell.addWorkspace(title: "worktree", cwd: harness.worktree)
            let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
            let brief = try XCTUnwrap(SpaceBrief.ensureBriefFile(spaceID: workspace.profileID, spaceName: "Flow"))
            try ("<!-- A comment -->\n" + "- Flow fact: always on.\n").write(to: brief, atomically: true, encoding: .utf8)
            @MainActor func titles(_ panel: ProjectMemoryPanel) -> [String] {
                panel.rows.compactMap { panel.model?.knowledge.entries[safe: $0]?.title }
            }

            harness.runPaletteCommand("Space Memory…")
            harness.waitUntil("the memory panel") { harness.shell.projectMemoryPanel?.isVisible == true }
            let panel = try XCTUnwrap(harness.shell.projectMemoryPanel)
            let field = try XCTUnwrap(panel.searchField)
            XCTAssertEqual(panel.model?.location.directory.path, memory)
            XCTAssertEqual(titles(panel), ["Flow fact", "Team rule", "Flow rules", "harness-notes", "Gone"])
            XCTAssertEqual(panel.model?.knowledge.entries.map(\.scope), [.always, .team, .whenRelevant, .whenRelevant, .whenRelevant])
            XCTAssertEqual(panel.summaryLabel?.stringValue, "1 always · 1 team · 3 when relevant")
            XCTAssertEqual(panel.preview?.sourceLabel.stringValue, "Source: Space brief, line 2")

            harness.type("flow", into: field)
            XCTAssertEqual(titles(panel), ["Flow fact", "Flow rules"])
            harness.press(.down, in: field.window)
            XCTAssertEqual(panel.selectedEntry?.title, "Flow rules")
            let preview = try XCTUnwrap(panel.preview)
            let link = try XCTUnwrap(preview.textView.textStorage?.attribute(.link, at: 4, effectiveRange: nil))
            preview.textView.clicked(onLink: link, at: 4)
            XCTAssertEqual(panel.selectedEntry?.title, "harness-notes")
            XCTAssertEqual(field.stringValue, "", "the filter hiding the linked memory is cleared")

            let scopes = try XCTUnwrap(panel.scopeControl)
            scopes.selectedSegment = try XCTUnwrap(ProjectMemoryPanel.scopes.firstIndex(of: .whenRelevant)) + 1
            XCTAssertTrue(scopes.sendAction(scopes.action, to: scopes.target))
            XCTAssertEqual(titles(panel), ["Flow rules", "harness-notes", "Gone"])
            XCTAssertEqual(panel.summaryLabel?.stringValue, "3 of 5")

            harness.press(.returnKey, in: field.window)
            XCTAssertTrue(panel.isVisible, "Space Settings keeps the list, behind the editor")
            let editor = try XCTUnwrap(workspace.columns.compactMap(\.editorColumn).first)
            harness.waitUntil("the memory in the editor") { editor.activePath == memory + "/flow-rules.md" }

            // The index line without a file opens MEMORY.md, in the same
            // editor.
            harness.shell.showProjectMemory()
            harness.waitUntil("the memory panel again") { panel.isVisible && panel.rows.count == 5 }
            for _ in 0..<4 { harness.press(.down, in: field.window) }
            XCTAssertEqual(panel.selectedEntry?.title, "Gone")
            harness.press(.returnKey, in: field.window)
            harness.waitUntil("MEMORY.md in the editor") { editor.activePath == memory + "/MEMORY.md" }
            XCTAssertEqual(workspace.columns.compactMap(\.editorColumn).count, 1)
        }
    }

    func testBrowserCommands() throws {
        try UIFlowHarness.run { harness in
            let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
            let page = URL(fileURLWithPath: harness.repo + "/README.md").absoluteString

            harness.runPaletteCommand("Open Browser")
            let palette = try XCTUnwrap(harness.shell.commandPalette)
            XCTAssertEqual(palette.mode, .urlInput)
            XCTAssertTrue(palette.isVisible, "URL mode closed the palette")
            let field = try XCTUnwrap(palette.searchField)
            harness.type(page, into: field)
            harness.press(.returnKey, in: palette.panel)
            XCTAssertFalse(palette.isVisible)
            let web = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.webViewColumn)
            XCTAssertEqual(web.currentURL, page)
            // The history lives in the test's state folder.
            XCTAssertEqual(URLHistory.load().first, page)
            XCTAssertTrue(FileManager.default.fileExists(atPath: harness.stateDirectory + "/url_history.json"))

            // After a URL, the palette opens on the commands again.
            harness.shell.showCommandPalette()
            XCTAssertEqual(palette.mode, .actions)
            XCTAssertEqual(palette.searchField?.placeholderString, "Type a command, a workspace or a session...")
            palette.dismiss()

            // Reaches the focused browser column; the inspector itself
            // doesn't open in a test process.
            harness.runPaletteCommand("Toggle Web Inspector")
            XCTAssertIdentical(workspace.columns[safe: workspace.focusedIndex]?.webViewColumn, web)
        }
    }

    func testOpenIsolatedTestBrowser() throws {
        try UIFlowHarness.run { harness in
            let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
            let terminal = try XCTUnwrap(workspace.columns.first)
            let server = LocalServerURL(isSecure: false, host: "localhost", port: 5173, path: "/")
            XCTAssertTrue(workspace.localServers.book.noteDetected(server, in: terminal.id, browserPorts: [], now: 0))
            XCTAssertTrue(workspace.localServers.book.applyScan(listeningPorts: [server.port], browserPorts: [], liveColumns: [terminal.id], now: 1))

            harness.runPaletteCommand("Open Isolated Test Browser")
            let web = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.webViewColumn)
            XCTAssertTrue(web.isIsolated)
            XCTAssertEqual(web.currentURL, server.urlString)
        }
    }

    func testImportBrowserCookies() throws {
        try UIFlowHarness.run { harness in
            XCTAssertFalse(harness.paletteCommandTitles().contains("Import Browser Cookies"), "no Chromium browser to import from")
            let work = UIFlowHarness.cookieSource(.chrome, "Work", folder: "Profile 2")
            harness.cookieSources = [UIFlowHarness.cookieSource(.chrome, "Personal"), work, UIFlowHarness.cookieSource(.arc)]
            XCTAssertEqual(
                harness.paletteCommands().first { $0.title == "Import Browser Cookies" }?.subtitle, "From Chrome, Arc"
            )
            // The profile choice: Chrome's Work profile, the second button.
            harness.alertResponses = [.alertSecondButtonReturn]

            harness.runPaletteCommand("Import Browser Cookies")
            harness.waitUntil("the import result") { harness.alerts.count == 2 }
            XCTAssertEqual(harness.alerts, ["Import Cookies", "Cookies Imported"])
            XCTAssertEqual(harness.cookieImports, [work])
            // No default button: the picker comes after a read, maybe under a
            // Return meant for a terminal.
            XCTAssertEqual(harness.alertDefaultButtons.first, "")

            // macOS privacy protection kept Nirux out of the cookie file:
            // the alert names the profile and opens Full Disk Access.
            harness.cookieImportError = CookieImporter.ImportError(
                source: work, failure: .unreadable(path: work.cookiesPath, errno: EPERM)
            )
            harness.alertResponses = [.alertSecondButtonReturn, .alertFirstButtonReturn]
            harness.runPaletteCommand("Import Browser Cookies")
            harness.waitUntil("the import failure") { harness.alerts.count == 4 }
            XCTAssertEqual(harness.alerts.last, "Import Failed")
            let detail = try XCTUnwrap(harness.alertDetails.last)
            XCTAssertTrue(detail.contains("Chrome, profile “Work”") && detail.contains("Full Disk Access"), detail)
            XCTAssertEqual(harness.openedURLs, [CookieImporter.ImportError.fullDiskAccessSettings])

            // Past three profiles, a pop-up menu instead of a button each.
            harness.cookieImportError = nil
            let long = "Alexandra Martinez-Rodriguez (alexandra.martinez@verylongcompany2.example)"
            let many = (1...4).map { UIFlowHarness.cookieSource(.chrome, "Person \($0)", folder: "Profile \($0)") }
                + [UIFlowHarness.cookieSource(.chrome, long, folder: "Profile 5")]
            harness.cookieSources = many
            harness.alertMenuChoices = [3]
            harness.runPaletteCommand("Import Browser Cookies")
            harness.waitUntil("the import from the menu") { harness.alerts.count == 6 }
            XCTAssertEqual(harness.alerts.suffix(2), ["Import Cookies", "Cookies Imported"])
            XCTAssertEqual(harness.cookieImports.last, many[3])
            XCTAssertEqual(harness.alertDefaultButtons[4], "", "the pop-up picker has no default button either")
            // A long name keeps its end, which tells alike names apart.
            let longTitle = try XCTUnwrap(harness.alertMenuTitles.last?.last)
            XCTAssertTrue(longTitle.contains("…") && longTitle.hasSuffix("verylongcompany2.example)"), longTitle)

            // A browser that ran here but has no cookie file: the click says
            // so rather than doing nothing.
            harness.offeredBrowsers = [.edge]
            harness.cookieSources = []
            harness.runPaletteCommand("Import Browser Cookies")
            harness.waitUntil("the empty result") { harness.alerts.count == 7 }
            XCTAssertEqual(harness.alerts.last, "Import Failed")
            XCTAssertTrue(harness.alertDetails.last?.contains("None of the profiles in Edge has cookies yet") == true, "\(harness.alertDetails)")

            // One import at a time: while one reads the profiles, the
            // command leaves the palette and another call is ignored.
            harness.offeredBrowsers = nil
            harness.cookieSources = [UIFlowHarness.cookieSource(.chrome)]
            let importsBefore = harness.cookieImports.count
            harness.runPaletteCommand("Import Browser Cookies")
            XCTAssertFalse(harness.paletteCommandTitles().contains("Import Browser Cookies"))
            harness.shell.importBrowserCookies()
            harness.waitUntil("the import result") { harness.alerts.count >= 8 && !harness.shell.isImportingCookies }
            XCTAssertEqual(harness.alerts.count, 8)
            XCTAssertEqual(harness.cookieImports.count, importsBefore + 1)
            XCTAssertTrue(harness.paletteCommandTitles().contains("Import Browser Cookies"))

            // A read that never returns: the import stops waiting and can be
            // asked again.
            harness.shell.sideEffects.cookieReadTimeout = 0.2
            harness.cookieSourcesNeverAnswer = true
            harness.runPaletteCommand("Import Browser Cookies")
            XCTAssertTrue(harness.shell.isImportingCookies)
            harness.waitUntil("the import to stop waiting") { !harness.shell.isImportingCookies }
            XCTAssertTrue(harness.paletteCommandTitles().contains("Import Browser Cookies"))
        }
    }

    // MARK: - Agents

    func testAgentCommands() throws {
        try UIFlowHarness.run { harness in
            // ⌘J walks while the sidebar is unfolded; folded, it opens the
            // inbox (RequestFlowTests).
            if !harness.shell.isSidebarExpanded { harness.shell.toggleSidebar() }
            harness.waitUntil("the sidebar to unfold") { harness.shell.sidebar.isExpanded }
            let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
            let columnCount = workspace.columns.count

            harness.runPaletteCommand("Open Claude Code")
            XCTAssertEqual(workspace.columns.count, columnCount + 1)
            XCTAssertEqual(harness.agentLaunches.count, 1)
            XCTAssertTrue(harness.agentLaunches.last?.hasPrefix("command claude") == true, "\(harness.agentLaunches)")

            harness.runPaletteCommand("Open Codex")
            XCTAssertEqual(workspace.columns.count, columnCount + 2)
            XCTAssertEqual(harness.agentLaunches.count, 2)
            XCTAssertTrue(harness.agentLaunches.last?.hasPrefix("command codex") == true, "\(harness.agentLaunches)")

            harness.runPaletteCommand("Open Antigravity")
            XCTAssertEqual(workspace.columns.count, columnCount + 3)
            XCTAssertEqual(harness.agentLaunches.last, "command agy --mode auto")

            // Claude waits on the user (faked: a real one needs a `claude`
            // in front): the command goes to it. QuickSwitcherFlowTests
            // walks a queue.
            let claude = try XCTUnwrap(workspace.columns[safe: columnCount])
            let wait = AgentWait(reason: .question(nil), since: Date().timeIntervalSince1970 - 60)
            harness.shell.quickSwitch.agentWait = { column, _, _, _ in column === claude ? wait : nil }
            XCTAssertNotIdentical(workspace.columns[safe: workspace.focusedIndex], claude)
            harness.runPaletteCommand("Next Waiting Agent")
            XCTAssertIdentical(workspace.columns[safe: workspace.focusedIndex], claude)
        }
    }

    /// A restored agent in a workspace off screen waits until asked.
    func testResumeAllAgentsCommand() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let onScreen = try XCTUnwrap(shell.activeWorkspace)
            shell.addWorkspace(title: "restored", cwd: harness.repo)
            let restored = try XCTUnwrap(shell.activeWorkspace)
            let session = "5f0c8a52-6a0e-4d7c-9f0e-2b1f6d1c9a11"
            restored.addColumn(
                deferredAgent: DeferredAgentLaunch(
                    launch: .claude(resume: .session(session), mode: .default), title: nil, lastStatus: nil
                ),
                agentUUID: UUID().uuidString,
                cwd: harness.repo
            )
            shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0 === onScreen }))
            XCTAssertEqual(shell.deferredAgentCount, 1)
            XCTAssertEqual(harness.restoredAgentLaunches, [])

            harness.runPaletteCommand("Resume All Agents")
            let settings = try XCTUnwrap(ClaudeSpaceSettings.fileURL(spaceID: restored.profileID)).path
            XCTAssertEqual(harness.restoredAgentLaunches, ["command claude --resume '\(session)' '--settings=\(settings)'"])
            XCTAssertEqual(shell.deferredAgentCount, 0)
            XCTAssertIdentical(shell.activeWorkspace, onScreen, "agents resume where they are")
        }
    }

    // MARK: - Workspaces

    func testWorkspaceCommands() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let repoWorkspace = try XCTUnwrap(shell.activeWorkspace)

            shell.addWorkspace(title: "second", cwd: harness.home)
            let second = try XCTUnwrap(shell.workspaces.first { $0.title == "second" })

            shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0 === repoWorkspace }))
            harness.runPaletteCommand("Rename Workspace")
            let renameField = try XCTUnwrap(harness.waitForField(placeholder: "Workspace name"))
            XCTAssertEqual(renameField.stringValue, "repo")
            harness.submit("renamed", into: renameField)
            XCTAssertEqual(repoWorkspace.title, "renamed")
            XCTAssertTrue(repoWorkspace.titleIsManual)

            harness.runPaletteCommand("Show/Hide Sidebar")
            XCTAssertTrue(shell.isSidebarExpanded)
            harness.waitUntil("the sidebar to expand") { shell.sidebar.isExpanded }

            // The section only toggles with an inactive workspace to show.
            let secondIndex = try XCTUnwrap(shell.workspaces.firstIndex { $0 === second })
            harness.perform(["Organize", "Archive"], in: shell.sidebar.workspaceActionMenu(workspaceIndex: secondIndex, columnIndex: nil))
            XCTAssertTrue(second.isInactive)
            XCTAssertTrue(shell.sidebar.isInactiveSectionCollapsed)
            harness.runPaletteCommand("Show/Hide Archived")
            XCTAssertFalse(shell.sidebar.isInactiveSectionCollapsed)

            // No repository yet: the board asks for one, and runs no gh.
            // ProjectBoardFlowTests covers the board itself.
            let client = ProjectBoardFlowTests.FakeGitHub(openPullRequests: "[]", runs: "[]")
            shell.projectBoardClient = client
            harness.runPaletteCommand("Open Board")
            XCTAssertNotNil(repoWorkspace.columns[safe: repoWorkspace.focusedIndex]?.projectBoard)
            harness.waitUntil("Board Settings to open") { shell.boardSettingsPanel?.hostView != nil }
            shell.spaceSettings?.close()
            XCTAssertEqual(client.calls, [])
        }
    }

    func testWorktreeCommands() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell

            // Outside a repository, it says so instead of doing nothing.
            let repoWorkspace = try XCTUnwrap(shell.activeWorkspace)
            shell.addWorkspace(title: "home", cwd: harness.home)
            harness.runPaletteCommand("Open Worktree")
            XCTAssertEqual(shell.toast?.message, "Not in a git repository: \(harness.home.abbreviatedPath())")
            shell.focusWorkspace(id: repoWorkspace.id)

            // Lists the worktrees off the main thread, then offers them in
            // the palette.
            harness.runPaletteCommand("Open Worktree")
            let palette = try XCTUnwrap(shell.commandPalette)
            harness.waitUntil("the worktree list") {
                palette.isVisible && palette.filteredActions.map(\.title) == [harness.worktreeBranch]
            }
            harness.press(.returnKey, in: palette.panel)
            let opened = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertEqual(opened.title, harness.worktreeBranch)
            XCTAssertEqual(opened.cwd.comparablePath, harness.worktree.comparablePath)

            // Picks a row of Open Worktree by its title; returns its subtitle.
            @MainActor func pickWorktree(_ title: String) throws -> String {
                harness.runPaletteCommand("Open Worktree")
                harness.waitUntil("\(title) in the worktree list") {
                    palette.isVisible && palette.actions.contains { $0.title == title }
                }
                harness.type(title, into: try XCTUnwrap(palette.searchField))
                let row = try XCTUnwrap(palette.filteredActions.first)
                XCTAssertEqual(row.title, title)
                harness.press(.returnKey, in: palette.panel)
                return row.subtitle
            }

            // Once it is open, it goes back to that workspace...
            XCTAssertEqual(repoWorkspace.cwd, harness.repo)
            shell.focusWorkspace(id: repoWorkspace.id)
            let workspaceCount = shell.workspaces.count
            XCTAssertTrue(try pickWorktree(harness.worktreeBranch).hasPrefix("Already open · "))
            XCTAssertTrue(shell.activeWorkspace === opened)
            // ...and, from the worktree, to the main checkout's.
            XCTAssertTrue(try pickWorktree("main").hasPrefix("Already open · "))
            XCTAssertTrue(shell.activeWorkspace === repoWorkspace)
            XCTAssertEqual(shell.workspaces.count, workspaceCount)
            // A worktree inside the main checkout, as Claude Code makes them:
            // its workspace is in it, not in the main checkout.
            let nested = harness.repo + "/.claude/worktrees/nested"
            try UIFlowHarness.git(["worktree", "add", "-q", "-b", "feat/nested", nested], at: harness.repo)
            XCTAssertFalse(try pickWorktree("feat/nested").hasPrefix("Already open"))
            let nestedWorkspace = try XCTUnwrap(shell.activeWorkspace)
            shell.focusWorkspace(id: repoWorkspace.id)
            XCTAssertTrue(try pickWorktree("feat/nested").hasPrefix("Already open · "))
            XCTAssertTrue(shell.activeWorkspace === nestedWorkspace)
            XCTAssertEqual(shell.workspaces.count, workspaceCount + 1)
            shell.focusWorkspace(id: repoWorkspace.id)

            // One an agent asked for: created off the main thread, then
            // opened with an agent (the launch double).
            shell.createWorktreeWorkspace(branch: "feat/new-flow", repoRoot: harness.repo)
            harness.waitUntil("the new worktree's workspace") {
                shell.workspaces.contains { $0.title == "feat/new-flow" }
            }
            let created = try XCTUnwrap(shell.workspaces.first { $0.title == "feat/new-flow" })
            XCTAssertTrue(FileManager.default.fileExists(atPath: created.cwd + "/.git"))
            XCTAssertTrue(harness.agentLaunches.last?.hasPrefix("command claude") == true, "\(harness.agentLaunches)")

            // Inspects each worktree on an OperationQueue (#46, #48).
            harness.runPaletteCommand("Clean Up Merged Worktrees…")
            let panel = try XCTUnwrap(shell.worktreeCleanupPanel)
            let expected = Set([harness.worktree, created.cwd].map(\.comparablePath))
            harness.waitUntil("both worktrees inspected") {
                let inspected = panel.candidates.filter { $0.inspection != nil }.map(\.path.comparablePath)
                return expected.isSubset(of: Set(inspected))
            }
            panel.dismiss()
            XCTAssertNil(shell.worktreeCleanupPanel)
        }
    }

    /// ⌘N's sheet on a space with a repository: reads where its tasks
    /// branch from and its templates off the main thread, then creates the
    /// worktree and writes the handover off it too (see NewTaskFlowTests for
    /// the rest of the sheet).
    func testNewCommand() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let space = try NewTaskFlowTests.anchoredSpace(harness)
            harness.runPaletteCommand("New…")
            harness.waitUntil("the sheet") { shell.newTaskPanel?.panel?.isSheet == true }
            let sheet = try XCTUnwrap(shell.newTaskPanel)
            XCTAssertIdentical(harness.window.attachedSheet, sheet.panel)
            XCTAssertEqual(sheet.headingLabel.stringValue, "New in Repo")
            XCTAssertEqual(sheet.space.id, space.id)
            // One repository, or none: a folder of the task's own.
            XCTAssertFalse(sheet.repositoryPopup.isHidden)
            XCTAssertEqual(sheet.repositoryPopup.itemTitles, ["repo", "", "No Repository"])
            XCTAssertEqual(sheet.repositoryPopup.titleOfSelectedItem, "repo")
            harness.waitUntil("the repository's info") { sheet.info != nil }
            XCTAssertEqual(sheet.info?.target?.repository, harness.repo)
            XCTAssertEqual(sheet.info?.templates, TaskTemplates.defaults)

            // The branch follows the description, then the template. No
            // remote here: from the checkout's HEAD.
            sheet.descriptionView.string = "Sidebar flickers on resize\n\nSeen with three columns."
            sheet.descriptionView.didChangeText()
            XCTAssertEqual(sheet.branch, "feat/sidebar-flickers-on-resize")
            sheet.templatePopup.selectItem(withTitle: "Bugfix")
            sheet.templatePopup.sendAction(sheet.templatePopup.action, to: sheet.templatePopup.target)
            XCTAssertEqual(sheet.branch, "fix/sidebar-flickers-on-resize")
            XCTAssertEqual(
                sheet.lineLabel.stringValue,
                "fix/sidebar-flickers-on-resize  ·  from the checkout’s HEAD (main): origin has no default branch"
            )

            sheet.startButton.performClick(nil)
            harness.waitUntil("the task's workspace") {
                shell.workspaces.contains { $0.title == "Sidebar flickers on resize" }
            }
            XCTAssertNil(shell.newTaskPanel)
            XCTAssertNil(harness.window.attachedSheet)
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertEqual(workspace.title, "Sidebar flickers on resize")
            XCTAssertEqual(workspace.profileID, space.id)
            XCTAssertEqual(
                workspace.cwd.comparablePath,
                (harness.root + "/repo.fix-sidebar-flickers-on-resize").comparablePath
            )
            XCTAssertEqual(GitWorktree.currentBranch(at: workspace.cwd), "fix/sidebar-flickers-on-resize")
            let handover = try String(contentsOfFile: workspace.cwd + "/.claude-handover.md", encoding: .utf8)
            XCTAssertTrue(handover.contains("## Task\n\nSidebar flickers on resize\n\nSeen with three columns.\n"), handover)
            XCTAssertTrue(handover.contains("## How to proceed (template “Bugfix”)\n\n1. Reproduce the bug first"), handover)
            // The repository ignores it: an agent's `git add -A` leaves it out.
            XCTAssertEqual(try UIFlowHarness.git(["status", "--porcelain"], at: workspace.cwd), "")
            // Named after the branch and its space (#39), told to read the
            // handover.
            let launch = try XCTUnwrap(harness.agentLaunches.last)
            XCTAssertTrue(launch.hasPrefix("command claude"), launch)
            XCTAssertTrue(launch.contains("'--name=fix/sidebar-flickers-on-resize · Repo'"), launch)
            XCTAssertTrue(launch.contains("Read .claude-handover.md for full context"), launch)
        }
    }

    func testCheckpointCommands() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let store = try LocalCheckpoints(stateDirectory: Persistence.stateDirectory, workspaceID: workspace.id)
            harness.runPaletteCommand("Save Checkpoint…")
            let prompt = try XCTUnwrap(harness.window.attachedSheet?.contentView)
            let field = try XCTUnwrap(UIFlowHarness.descendant(of: prompt, as: NSTextField.self) { $0.isEditable })
            field.stringValue = "Before refactor"
            try XCTUnwrap(UIFlowHarness.button(titled: "Save", in: prompt)).performClick(nil)
            harness.waitUntil("the checkpoint confirmation") {
                shell.toast?.message.hasPrefix("Saved checkpoint") == true && harness.window.attachedSheet == nil
            }
            XCTAssertEqual(try store.list().first?.manifest?.label, "Before refactor")

            harness.runPaletteCommand("Checkpoints…")
            let panel = try XCTUnwrap(harness.window.attachedSheet?.contentView)
            harness.waitUntil("the saved row") {
                UIFlowHarness.descendant(of: panel, as: NSTextField.self) { $0.stringValue.hasPrefix("Before refactor ·") } != nil
            }
            try XCTUnwrap(UIFlowHarness.button(titled: "Delete", in: panel)).performClick(nil)
            harness.waitUntil("the empty history") {
                UIFlowHarness.descendant(of: panel, as: NSTextField.self) { $0.stringValue == "No saved checkpoints" } != nil
            }
            XCTAssertTrue(try store.list().isEmpty)
            try XCTUnwrap(UIFlowHarness.button(titled: "Done", in: panel)).performClick(nil)
        }
    }

    // MARK: - Branch Review

    func testReviewBranchCommand() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.branchReviewReader = BranchReviewPageTests.reader
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let columns = workspace.columns.count

            // Next to the focused column, at two-thirds of the width.
            harness.runPaletteCommand("Review Branch")
            XCTAssertEqual(workspace.columns.count, columns + 1)
            let column = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex])
            let review = try XCTUnwrap(column.branchReview)
            XCTAssertEqual(review.worktree, workspace.cwd)
            XCTAssertEqual(column.widthFraction, ColumnWidth.twoThirds.fraction)
            harness.waitUntil("the review to read its branch") { review.snapshot != nil }
            XCTAssertEqual(review.branch, "feat/keep-awake")
            XCTAssertEqual(review.view.header.context, "feat/keep-awake → main")

            // From another column: the same review comes to the front.
            shell.focusColumnByIndex(0)
            harness.runPaletteCommand("Review Branch")
            XCTAssertIdentical(workspace.columns[safe: workspace.focusedIndex]?.branchReview, review)
            XCTAssertEqual(workspace.columns.filter(\.isBranchReview).count, 1)
        }
    }

    // MARK: - Setup

    func testSetupCommands() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell

            harness.runPaletteCommand("Show Getting Started")
            XCTAssertEqual(shell.onboardingState, .pending)
            XCTAssertTrue(shell.isSidebarExpanded)
            // Read from the fake home, where nothing is installed yet.
            XCTAssertEqual(shell.sidebar.onboardingChecklist?.skills, .missing)

            harness.runPaletteCommand("Install Agent Skills")
            XCTAssertEqual(harness.alerts, ["Agent Skills Installed"])
            for root in AgentSkillsInstaller.roots(home: harness.home) {
                for name in NiruxShellView.agentSkills.keys {
                    let file = AgentSkillsInstaller.skillFile(root: root, name: name)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: file), "missing \(file)")
                }
            }
            XCTAssertEqual(shell.sidebar.onboardingChecklist?.skills, .installed)

            // The palette sends the action up the responder chain to the
            // app delegate.
            let app = NiruxApp()
            app.claudeStatusLineStateReader = { .none }
            let previousDelegate = NSApp.delegate
            NSApp.delegate = app
            harness.runPaletteCommand("Open Settings")
            NSApp.delegate = previousDelegate
            let settings = try XCTUnwrap(app.settingsPanel)
            XCTAssertTrue(settings.isVisible)
            settings.orderOut(nil)
            settings.close()
        }
    }
}

/// When each SF Symbol first shipped, from the system's own table.
private struct SymbolAvailability {
    private static let path = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"
    private let symbols: [String: String]
    private let releases: [String: [String: String]]

    init() throws {
        guard let table = NSDictionary(contentsOfFile: Self.path),
              let symbols = table["symbols"] as? [String: String],
              let releases = table["year_to_release"] as? [String: [String: String]]
        else { throw XCTSkip("no SF Symbols availability table at \(Self.path)") }
        self.symbols = symbols
        self.releases = releases
    }

    func ships(_ name: String, byMacOS target: [Int]) throws -> Bool {
        let year = try XCTUnwrap(symbols[name], "\(name) is not an SF Symbol")
        let macOS = try XCTUnwrap(releases[year]?["macOS"], "no macOS release for \(year)")
        let version = macOS.split(separator: ".").compactMap { Int($0) }
        return version.lexicographicallyPrecedes(target) || version == target
    }
}
