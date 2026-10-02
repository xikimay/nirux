import XCTest
import AppKit
@testable import Nirux

/// Records what a search session sends to Ghostty and holds its delayed
/// sends until the test fires them.
@MainActor
private final class SearchRecorder {
    var sent: [TerminalSearchCommand] = []
    var pending: [(delay: TimeInterval, work: @MainActor @Sendable () -> Void)] = []

    lazy var session = TerminalSearchSession(
        send: { [unowned self] command in self.sent.append(command) },
        schedule: { [unowned self] delay, work in self.pending.append((delay, work)) }
    )

    func firePending() {
        let works = pending
        pending = []
        for entry in works { entry.work() }
    }
}

/// The find bar of a terminal column: what it sends to libghostty, when,
/// and how its keys and focus behave.
final class TerminalSearchTests: XCTestCase {

    // MARK: - Binding actions

    func testCommandsUseGhosttyBindingActions() {
        XCTAssertEqual(TerminalSearchCommand.search("error").bindingAction, "search:error")
        // Ghostty keeps everything after the first colon as the text.
        XCTAssertEqual(TerminalSearchCommand.search("a:b").bindingAction, "search:a:b")
        XCTAssertEqual(TerminalSearchCommand.search("").bindingAction, "search:")
        XCTAssertEqual(TerminalSearchCommand.next.bindingAction, "navigate_search:next")
        XCTAssertEqual(TerminalSearchCommand.previous.bindingAction, "navigate_search:previous")
        XCTAssertEqual(TerminalSearchCommand.end.bindingAction, "end_search")
        XCTAssertEqual(TerminalSearchCommand.scrollToBottom.bindingAction, "scroll_to_bottom")
    }

    // MARK: - Typing

    @MainActor
    func testANeedleOfThreeCharactersIsSentAtOnce() {
        let recorder = SearchRecorder()
        recorder.session.update("err")
        XCTAssertEqual(recorder.sent, [.search("err")])
        // Only the settle timer that holds back navigation, no pause.
        XCTAssertEqual(recorder.pending.map(\.delay), [TerminalSearchSession.navigationDelay])
    }

    @MainActor
    func testAShortNeedleWaitsAndOnlyTheLatestEditIsSent() {
        let recorder = SearchRecorder()
        recorder.session.update("e")
        recorder.session.update("er")
        XCTAssertEqual(recorder.sent, [])
        XCTAssertEqual(recorder.pending.map(\.delay), [0.3, 0.3])

        recorder.firePending()
        XCTAssertEqual(recorder.sent, [.search("er")])
    }

    @MainActor
    func testTypingPastTheShortLengthSupersedesThePause() {
        let recorder = SearchRecorder()
        recorder.session.update("er")
        recorder.session.update("err")
        recorder.firePending()
        XCTAssertEqual(recorder.sent, [.search("err")])
    }

    @MainActor
    func testClearingTheFieldCancelsTheSearchAtOnce() {
        let recorder = SearchRecorder()
        recorder.session.update("error")
        recorder.session.update("")
        XCTAssertEqual(recorder.sent, [.search("error"), .search("")])
    }

    @MainActor
    func testUnchangedTextIsNotResent() {
        let recorder = SearchRecorder()
        recorder.session.update("error")
        recorder.session.update("error")
        // A copied line's trailing newline sanitizes to the text already searched.
        recorder.session.update("error\n")
        recorder.session.update("err\tor")
        recorder.session.update("err or")
        XCTAssertEqual(recorder.sent, [.search("error"), .search("err or")])
    }

    @MainActor
    func testImmediateUpdateSkipsThePause() {
        let recorder = SearchRecorder()
        recorder.session.update("e", immediately: true)
        XCTAssertEqual(recorder.sent, [.search("e")])
        XCTAssertEqual(recorder.pending.map(\.delay), [TerminalSearchSession.navigationDelay])
    }

    // MARK: - Navigation

    @MainActor
    func testNavigationSendsAPendingNeedleFirstThenWaitsForItsMatches() {
        let recorder = SearchRecorder()
        recorder.session.update("e")
        recorder.session.next()
        // Ghostty has no match yet for a needle that just arrived.
        XCTAssertEqual(recorder.sent, [.search("e")])
        XCTAssertEqual(recorder.pending.last?.delay, TerminalSearchSession.navigationDelay)

        recorder.firePending()
        XCTAssertEqual(recorder.sent, [.search("e"), .next])

        // Settled: navigation goes out at once.
        recorder.session.previous()
        XCTAssertEqual(recorder.sent, [.search("e"), .next, .previous])
    }

    @MainActor
    func testReturnRightAfterTypingWaitsForTheNeedleToSettle() {
        let recorder = SearchRecorder()
        recorder.session.update("error")
        recorder.session.next()
        recorder.session.previous()
        XCTAssertEqual(recorder.sent, [.search("error")])

        recorder.firePending()
        XCTAssertEqual(recorder.sent, [.search("error"), .next, .previous], "queued in order")
    }

    @MainActor
    func testANewNeedleDropsNavigationsQueuedForTheOldOne() {
        let recorder = SearchRecorder()
        recorder.session.update("error")
        recorder.session.next()
        recorder.session.update("panic")
        recorder.firePending()
        XCTAssertEqual(recorder.sent, [.search("error"), .search("panic")])
    }

    @MainActor
    func testNavigationWithoutANeedleSendsNothing() {
        let recorder = SearchRecorder()
        recorder.session.next()
        recorder.session.previous()
        recorder.session.update("error")
        recorder.session.update("")
        recorder.session.next()
        XCTAssertEqual(recorder.sent, [.search("error"), .search("")])
    }

    // MARK: - Closing and typing

    @MainActor
    func testClosingKeepsTheViewportAndTypingReturnsToThePrompt() {
        let recorder = SearchRecorder()
        recorder.session.update("error")
        recorder.firePending()
        recorder.session.next()
        recorder.session.end()
        XCTAssertEqual(recorder.sent, [.search("error"), .next, .end], "Esc keeps the reading position")

        recorder.session.returnToPrompt()
        recorder.session.returnToPrompt()
        XCTAssertEqual(recorder.sent, [.search("error"), .next, .end, .scrollToBottom], "once, on the first keystroke")
    }

    @MainActor
    func testTypingWithTheBarOpenReturnsToThePromptAfterNavigating() {
        let recorder = SearchRecorder()
        recorder.session.update("error")
        recorder.firePending()
        recorder.session.next()
        recorder.session.returnToPrompt()
        XCTAssertEqual(recorder.sent, [.search("error"), .next, .scrollToBottom])
    }

    @MainActor
    func testTypingWithoutNavigatingLeavesTheViewportAlone() {
        let recorder = SearchRecorder()
        recorder.session.returnToPrompt()
        recorder.session.update("error")
        recorder.session.returnToPrompt()
        recorder.session.end()
        recorder.session.returnToPrompt()
        XCTAssertEqual(recorder.sent, [.search("error"), .end])
    }

    @MainActor
    func testClosingDropsAPendingNeedleOrNavigation() {
        let recorder = SearchRecorder()
        recorder.session.update("e")
        recorder.session.end()
        recorder.firePending()
        XCTAssertEqual(recorder.sent, [.end])
        XCTAssertEqual(recorder.session.needle, "")

        recorder.sent = []
        recorder.session.update("error")
        recorder.session.next()
        recorder.session.end()
        recorder.firePending()
        XCTAssertEqual(recorder.sent, [.search("error"), .end])
    }

    @MainActor
    func testTheSameNeedleSearchesAgainAfterClosing() {
        let recorder = SearchRecorder()
        recorder.session.update("error")
        recorder.session.end()
        recorder.session.update("error")
        XCTAssertEqual(recorder.sent, [.search("error"), .end, .search("error")])
    }

    // MARK: - Needle policy

    func testShortNeedleDelay() {
        XCTAssertEqual(TerminalSearchSession.delay(for: ""), 0)
        XCTAssertEqual(TerminalSearchSession.delay(for: "ab"), 0.3)
        XCTAssertEqual(TerminalSearchSession.delay(for: "abc"), 0)
        // Counted in characters, not bytes or scalars.
        XCTAssertEqual(TerminalSearchSession.delay(for: "\u{E9}\u{E9}"), 0.3)
        XCTAssertEqual(TerminalSearchSession.delay(for: "e\u{301}e\u{301}e\u{301}"), 0)
    }

    func testSanitizingControlCharacters() {
        // Dropped at either end: Ghostty trims rows, so a copied line's
        // newline would never match.
        XCTAssertEqual(TerminalSearchSession.sanitized("error\n"), "error")
        XCTAssertEqual(TerminalSearchSession.sanitized("\r\n\terror \r\n"), "error ")
        XCTAssertEqual(TerminalSearchSession.sanitized("\n\t"), "")
        // Inside: line breaks normalized to \n, other control characters spaced.
        XCTAssertEqual(TerminalSearchSession.sanitized("one\r\ntwo\rthree\nfour"), "one\ntwo\nthree\nfour")
        XCTAssertEqual(TerminalSearchSession.sanitized("a\tb"), "a b")
        XCTAssertEqual(TerminalSearchSession.sanitized("a\u{7F}b\u{1B}c"), "a b c")
        // Spaces are text, kept even at the ends.
        XCTAssertEqual(TerminalSearchSession.sanitized(" error "), " error ")
        // Format characters stay: the zero-width joiner builds this emoji.
        let technologist = "\u{1F468}\u{200D}\u{1F4BB}"
        XCTAssertEqual(TerminalSearchSession.sanitized(technologist), technologist)
        XCTAssertEqual(TerminalSearchSession.sanitized("caf\u{E9}: 100%"), "caf\u{E9}: 100%")
    }

    // MARK: - Find bar

    @MainActor
    func testReturnGoesToTheNextMatchAndShiftReturnToThePreviousOne() {
        let bar = TerminalFindBar(frame: .zero)
        var calls: [String] = []
        bar.onNext = { calls.append("next") }
        bar.onPrevious = { calls.append("previous") }
        bar.onClose = { calls.append("close") }
        let editor = NSTextView()

        bar.currentModifierFlags = { [] }
        XCTAssertTrue(bar.control(bar.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        bar.currentModifierFlags = { [.shift] }
        XCTAssertTrue(bar.control(bar.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(bar.control(bar.field, textView: editor, doCommandBy: #selector(NSResponder.insertLineBreak(_:))))
        XCTAssertTrue(bar.control(bar.field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(calls, ["next", "previous", "previous", "close"])

        // Tab would leave for an arbitrary view of another column.
        XCTAssertTrue(bar.control(bar.field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertTrue(bar.control(bar.field, textView: editor, doCommandBy: #selector(NSResponder.insertBacktab(_:))))

        // Editing commands stay with the field.
        XCTAssertFalse(bar.control(bar.field, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        XCTAssertFalse(bar.control(bar.field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        XCTAssertEqual(calls.count, 4)
    }

    @MainActor
    func testEditingTheFieldReportsItsText() {
        let bar = TerminalFindBar(frame: .zero)
        var needles: [String] = []
        bar.onNeedleChange = { needles.append($0) }
        bar.field.stringValue = "panic"
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.field))
        XCTAssertEqual(needles, ["panic"])
    }

    /// The key interceptor sends keys to the PTY unless the field is being
    /// edited, so this must follow the window's first responder.
    @MainActor
    func testIsEditingFollowsTheFieldFocus() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        let bar = TerminalFindBar(frame: NSRect(x: 0, y: 0, width: 320, height: TerminalFindBar.height))
        let other = NSTextView(frame: NSRect(x: 0, y: 100, width: 100, height: 50))
        window.contentView?.addSubview(bar)
        window.contentView?.addSubview(other)
        XCTAssertFalse(bar.isEditing)

        bar.focusField()
        XCTAssertTrue(bar.isEditing)

        XCTAssertTrue(window.makeFirstResponder(other))
        XCTAssertFalse(bar.isEditing)
    }

    // MARK: - Terminal column

    @MainActor
    func testTheFindBarOpensInTheTopRightCornerUnderTheTitleBar() {
        let column = ColumnState(cwd: "/tmp")
        column.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        column.layoutWithTitleBar(width: 600, height: 400)
        XCTAssertFalse(column.isFindBarOpen)

        column.showFindBar()
        let bar = try? XCTUnwrap(column.findBar)
        XCTAssertTrue(column.isFindBarOpen)
        XCTAssertTrue(column.view.subviews.last === bar, "drawn above the terminal")
        XCTAssertEqual(bar?.frame.maxX, 590)
        XCTAssertEqual(bar?.frame.maxY, 400 - column.titleBarHeight - 10)
        XCTAssertEqual(bar?.frame.width, TerminalFindBar.preferredWidth)

        // A narrow column shrinks the bar instead of overflowing it.
        column.view.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
        column.layoutWithTitleBar(width: 200, height: 400)
        XCTAssertEqual(bar?.frame.minX, 10)
        XCTAssertEqual(bar?.frame.width, 180)
    }

    @MainActor
    func testTheColumnDrivesItsSearchOnlyWhileTheBarIsOpen() {
        let column = ColumnState(cwd: "/tmp")
        column.showFindBar()
        let recorder = SearchRecorder()
        column.terminalSearch = recorder.session
        guard let bar = column.findBar else { return XCTFail("no find bar") }

        bar.field.stringValue = "error"
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.field))
        recorder.firePending()
        column.findNext()
        column.findPrevious()
        column.closeFindBar()
        XCTAssertFalse(column.isFindBarOpen)
        XCTAssertEqual(recorder.sent, [.search("error"), .next, .previous, .end])

        // Closed: ⌘G and ⇧⌘G do nothing, a second close too.
        recorder.sent = []
        column.findNext()
        column.findPrevious()
        column.closeFindBar()
        XCTAssertEqual(recorder.sent, [])

        // Reopening searches the kept text again, without the short-needle pause.
        bar.field.stringValue = "er"
        column.showFindBar()
        XCTAssertEqual(recorder.sent, [.search("er")])
    }

    // MARK: - Key routing

    func testKeysInTheFieldEditTheField() {
        let route = TerminalFindKeyRouting.routeInField
        XCTAssertEqual(route(0x00, []), .field) // a
        XCTAssertEqual(route(0x24, [.shift]), .field) // Shift+Return
        XCTAssertEqual(route(0x35, []), .field) // Escape
        XCTAssertEqual(route(0x7B, []), .field) // Left
        XCTAssertEqual(route(0x08, [.control]), .field) // Ctrl+C stays text editing
    }

    func testCommandArrowsMoveTheCaretInsteadOfSwitchingColumns() {
        let route = TerminalFindKeyRouting.routeInField
        for arrow: UInt16 in [0x7B, 0x7C, 0x7D, 0x7E] {
            XCTAssertEqual(route(arrow, [.command]), .fieldEditor)
            XCTAssertEqual(route(arrow, [.command, .shift]), .fieldEditor)
            XCTAssertEqual(route(arrow, [.command, .numericPad, .function]), .fieldEditor)
            // Previous/Next Space keep their chord, and Focus Left/Right
            // and Workspace Up/Down their Control+Cmd one.
            XCTAssertEqual(route(arrow, [.command, .option]), .menuThenField)
            XCTAssertEqual(route(arrow, [.command, .control]), .menuThenField)
        }
    }

    func testCommandChordsInTheFieldTryTheMenuFirst() {
        let route = TerminalFindKeyRouting.routeInField
        XCTAssertEqual(route(0x05, [.command]), .menuThenField) // ⌘G
        XCTAssertEqual(route(0x09, [.command]), .menuThenField) // ⌘V
        XCTAssertEqual(route(0x33, [.command]), .menuThenField) // ⌘⌫ reaches the field when unmatched
    }

    func testOnlyAPlainEscapeClosesAnOpenFindBar() {
        let closes = TerminalFindKeyRouting.closesOpenFindBar
        XCTAssertTrue(closes(0x35, []))
        XCTAssertTrue(closes(0x35, [.capsLock]))
        XCTAssertFalse(closes(0x35, [.option]))
        XCTAssertFalse(closes(0x35, [.shift]))
        XCTAssertFalse(closes(0x24, []))
    }

    @MainActor
    func testBrowserColumnsHaveNoFindBar() {
        let column = ColumnState(url: "about:blank")
        column.showFindBar()
        XCTAssertNil(column.findBar)
        XCTAssertFalse(column.isFindBarOpen)
        XCTAssertFalse(column.isEditingFind)
    }
}
