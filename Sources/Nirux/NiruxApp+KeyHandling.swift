import AppKit
import WebKit

// MARK: - Key Interception & Click-to-Focus

extension NiruxApp {
    /// Click on a column to focus it without changing layout.
    func setupClickToFocus() {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            // Before the click is handled, so a toast it shows stays.
            if event.window === self?.mainWindow { self?.shell?.dismissToastOnInput() }
            guard let shell = self?.shell,
                  let workspace = shell.activeWorkspaceForKeyIntercept,
                  let contentView = event.window?.contentView
            else { return event }

            // Use hitTest to find the deepest view under the click
            let location = contentView.convert(event.locationInWindow, from: nil)
            guard let hitView = contentView.hitTest(location) else { return event }

            // Walk up from the hit view to find which column it belongs to
            for (index, col) in workspace.columns.enumerated() {
                if hitView === col.view || hitView.isDescendant(of: col.view) {
                    shell.focusColumnByIndex(index)
                    break
                }
            }
            return event // pass through so ghostty still handles selection etc.
        }
    }

    /// Also consume flagsChanged to prevent ghostty from sending modifier
    /// key events to the PTY (breaks Claude Code's kitty keyboard protocol)
    private func setupModifierInterceptor() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let shell = self?.shell, event.window === self?.mainWindow else { return event }
            if shell.isOverlayActive { return event }
            guard let workspace = shell.activeWorkspaceForKeyIntercept,
                  let col = workspace.columns[safe: workspace.focusedIndex]
            else { return event }
            // Don't consume modifiers for WebView or editor columns, or while
            // a terminal's find field is typing.
            if col.isWebView || col.isEditor || workspace.findFieldColumn != nil { return event }
            return nil
        }
    }

    /// A key typed while a terminal's find field has the focus edits the
    /// field, never a PTY (see TerminalFindKeyRouting).
    private static func routeFindFieldKey(_ event: NSEvent, in column: ColumnState) -> NSEvent? {
        switch TerminalFindKeyRouting.routeInField(keyCode: event.keyCode, modifierFlags: event.modifierFlags) {
        case .field:
            return event
        case .menuThenField:
            return NSApp.mainMenu?.performKeyEquivalent(with: event) == true ? nil : event
        case .fieldEditor:
            column.findBar?.field.currentEditor()?.keyDown(with: event)
            return nil
        }
    }

    /// Escape with the terminal's find bar open closes the bar instead of
    /// reaching the PTY (see TerminalFindKeyRouting). True when consumed.
    private static func closeFindBarOnEscape(_ event: NSEvent, in column: ColumnState) -> Bool {
        guard column.isFindBarOpen,
              TerminalFindKeyRouting.closesOpenFindBar(keyCode: event.keyCode, modifierFlags: event.modifierFlags)
        else { return false }
        column.closeFindBar()
        return true
    }

    /// A key that types into the terminal (bytes for the PTY, or ⌘V,
    /// which ghostty pastes and notes as input — see
    /// `PtySession.isUserText`) takes the agent-exit notice down at once.
    private static func dismissAgentExitIfTyping(_ event: NSEvent, in column: ColumnState) {
        let pastes = event.modifierFlags.contains(.command) && WebContentKeyRouting.typesLetter(
            "v", ansiKeyCode: 0x09,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            keyCode: event.keyCode
        )
        guard pastes || !KeyMapper.bytesForEvent(event).isEmpty else { return }
        column.dismissAgentExitOnTyping()
    }

    /// Cmd+Arrow and Shift+Cmd+Arrow go to the text that has the keyboard
    /// in a browser or editor column (Monaco, a field of the page, the
    /// address bar) rather than to the menu: see
    /// `WebContentKeyRouting.movesCaretToTextEdge`. True when consumed.
    private static func moveCaretInFocusedText(_ event: NSEvent, in column: ColumnState) -> Bool {
        guard WebContentKeyRouting.movesCaretToTextEdge(keyCode: event.keyCode, modifierFlags: event.modifierFlags),
              let responder = event.window?.firstResponder as? NSView,
              responder.isDescendant(of: column.view)
        else { return false }
        if let webView = responder as? WKWebView {
            // WKWebView has an input context only while the page's focused
            // element takes text. It then hands the key to the page, and
            // resends it if the page leaves it unhandled: that time it
            // answers false, and the menu gets the key.
            return webView.inputContext != nil && webView.performKeyEquivalent(with: event)
        }
        if let fieldEditor = responder as? NSTextView, fieldEditor.isEditable {
            // Returned to AppKit, the key would reach the menu first.
            fieldEditor.keyDown(with: event)
            return true
        }
        return false
    }

    /// WebView and Editor (Monaco) columns handle their own keyboard
    /// input, but Cmd+key combos must bypass the WebView so menu
    /// shortcuts (Cmd+T, Ctrl+Cmd+Arrow, etc.) keep working. A
    /// WKWebView with the keyboard hands every Cmd-chord to its page
    /// first, and Monaco keeps the arrows it binds, so we invoke the
    /// menu action directly and consume the event.
    private static func routeWebContentKey(_ event: NSEvent, in col: ColumnState) -> NSEvent? {
        guard event.modifierFlags.contains(.command) else { return event }
        if moveCaretInFocusedText(event, in: col) { return nil }
        // Browser back/forward — handled here rather than as
        // menu items: menu items would also consume Cmd+[/] in
        // EDITOR columns, killing Monaco's indent/outdent-line
        // shortcuts with a no-op action.
        if col.isWebView,
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command] {
            let typed = [event.characters, event.charactersIgnoringModifiers]
            if typed.contains("[") {
                col.webViewColumn?.goBack()
                return nil
            }
            if typed.contains("]") {
                col.webViewColumn?.goForward()
                return nil
            }
        }
        if WebContentKeyRouting.passesToWebContent(
            isEditor: col.isEditor,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        ) {
            return event
        }
        // Cmd+W: in an editor with open tabs, close the active
        // tab first; only fall through to "Close Column" once
        // the tab list is empty. Mirrors VSCode/Cursor.
        if col.isEditor,
           WebContentKeyRouting.typesLetter(
               "w", ansiKeyCode: 0x0D,
               characters: event.characters,
               charactersIgnoringModifiers: event.charactersIgnoringModifiers,
               keyCode: event.keyCode
           ),
           let editor = col.editorColumn, let active = editor.activePath {
            editor.close(path: active)
            return nil
        }
        // Let the menu bar handle this key equivalent directly,
        // bypassing the WebView's performKeyEquivalent
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return nil // consumed by menu
        }
        return event // no menu match — let WebView handle it
    }

    /// Route ALL key input directly to PTY, bypassing ghostty entirely.
    /// Ghostty only handles rendering — we handle ALL input.
    /// This prevents ghostty's broken inMemory key handling from interfering.
    /// Returns the event monitors, for a test to remove.
    @discardableResult
    func setupKeyInterceptor() -> [Any] {
        let modifierMonitor = setupModifierInterceptor()

        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // Only the main window's columns are routed here. Other windows —
            // panels, a detached Web Inspector, Sparkle — keep AppKit's own
            // key handling instead of feeding the focused column.
            guard let shell = self?.shell, event.window === self?.mainWindow else { return event }
            // Before the key is handled, so a toast it shows stays.
            shell.dismissToastOnInput()

            // Don't intercept when an overlay is active (picker, etc.)
            if shell.isOverlayActive { return event }

            guard let workspace = shell.activeWorkspaceForKeyIntercept,
                  let col = workspace.columns[safe: workspace.focusedIndex]
            else { return event }

            // Keys follow a terminal's find field while it has the focus,
            // even when the focused column changed without moving the
            // keyboard (a resize drag, an agent opening an editor column).
            if let findColumn = workspace.findFieldColumn {
                return Self.routeFindFieldKey(event, in: findColumn)
            }

            if col.isWebView || col.isEditor {
                return Self.routeWebContentKey(event, in: col)
            }

            if Self.closeFindBarOnEscape(event, in: col) { return nil }

            guard let pty = col.pty else { return event }
            Self.dismissAgentExitIfTyping(event, in: col)

            // Cmd+key: some go to PTY (Cmd+Backspace), rest to menu system
            if event.modifierFlags.contains(.command) {
                let bytes = KeyMapper.bytesForEvent(event)
                if !bytes.isEmpty {
                    col.terminalSearch?.returnToPrompt()
                    pty.sendRaw(bytes)
                    return nil
                }
                // Route Cmd+keys through the menu directly — as of libghostty
                // c6843ec, AppTerminalView.performKeyEquivalent eagerly
                // consumes Cmd+key events for its own bindings before the
                // menu sees them, so Cmd+T/Cmd+arrow/etc. silently die if we
                // just return the event here. Mirror the WebView/Editor path
                // above: invoke the menu key equivalent and consume on hit.
                if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                    return nil
                }
                return event
            }

            // Shell exited — swallow input instead of writing to a dead PTY;
            // Enter (or keypad Enter) restarts the shell.
            if pty.hasExited {
                if event.keyCode == 0x24 || event.keyCode == 0x4C {
                    col.restartShell()
                }
                return nil
            }

            // ALL other keys: send to PTY and ALWAYS consume.
            // Never let ghostty's keyDown handler see the event.
            let bytes = KeyMapper.bytesForEvent(event)
            if !bytes.isEmpty {
                // After a search jumped up the scrollback, typing returns
                // to the prompt first (Ghostty's scroll-to-bottom on
                // keystroke never runs: keys bypass it).
                col.terminalSearch?.returnToPrompt()
                pty.sendRaw(bytes)
            }
            return nil // ALWAYS consume — even if bytes is empty (modifier-only)
        }
        return [modifierMonitor, keyMonitor].compactMap { $0 }
    }
}
