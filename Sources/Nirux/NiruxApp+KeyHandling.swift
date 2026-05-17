import AppKit

// MARK: - Key Interception & Click-to-Focus

extension NiruxApp {
    /// Click on a column to focus it without changing layout.
    func setupClickToFocus() {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
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

    /// Route ALL key input directly to PTY, bypassing ghostty entirely.
    /// Ghostty only handles rendering — we handle ALL input.
    /// This prevents ghostty's broken inMemory key handling from interfering.
    func setupKeyInterceptor() {
        // Also consume flagsChanged to prevent ghostty from sending modifier
        // key events to the PTY (breaks Claude Code's kitty keyboard protocol)
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let shell = self?.shell else { return event }
            if shell.isOverlayActive { return event }
            guard let workspace = shell.activeWorkspaceForKeyIntercept,
                  let col = workspace.columns[safe: workspace.focusedIndex]
            else { return event }
            // Don't consume modifiers for WebView or editor columns
            if col.isWebView || col.isEditor { return event }
            return nil
        }

        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let shell = self?.shell else { return event }

            // Don't intercept when an overlay is active (picker, etc.)
            if shell.isOverlayActive { return event }

            guard let workspace = shell.activeWorkspaceForKeyIntercept,
                  let col = workspace.columns[safe: workspace.focusedIndex]
            else { return event }

            // WebView and Editor (Monaco) columns handle their own keyboard
            // input, but Cmd+key combos must bypass the WebView so menu
            // shortcuts (Cmd+Arrow, Cmd+T, etc.) keep working. WKWebView's
            // performKeyEquivalent consumes Cmd+Arrow for back/forward and
            // Monaco grabs arrow keys before the menu system sees them, so
            // we invoke the menu action directly and consume the event.
            if col.isWebView || col.isEditor {
                if event.modifierFlags.contains(.command) {
                    // Cmd+P is bound to "Command Palette" in the menu, but in
                    // an editor column Monaco rebinds it to its own quick-open
                    // (which Nirux replaces with the workspace file picker).
                    // Let Monaco see it instead of the menu — there's a
                    // dedicated palette shortcut elsewhere if the user wants
                    // the global one.
                    if col.isEditor, event.charactersIgnoringModifiers == "p" {
                        return event
                    }
                    // Cmd+W: in an editor with open tabs, close the active
                    // tab first; only fall through to "Close Column" once
                    // the tab list is empty. Mirrors VSCode/Cursor.
                    if col.isEditor, event.charactersIgnoringModifiers == "w",
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
                return event
            }

            guard let pty = col.pty else { return event }

            // Cmd+key: some go to PTY (Cmd+Backspace), rest to menu system
            if event.modifierFlags.contains(.command) {
                // Cmd+S: toggle sidebar — must intercept here because
                // ghostty's performKeyEquivalent swallows the event
                if event.charactersIgnoringModifiers == "s" {
                    shell.toggleSidebar()
                    return nil
                }
                let bytes = KeyMapper.bytesForEvent(event)
                if !bytes.isEmpty {
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

            // ALL other keys: send to PTY and ALWAYS consume.
            // Never let ghostty's keyDown handler see the event.
            let bytes = KeyMapper.bytesForEvent(event)
            if !bytes.isEmpty {
                pty.sendRaw(bytes)
            }
            return nil // ALWAYS consume — even if bytes is empty (modifier-only)
        }
    }
}
