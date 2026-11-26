import AppKit

/// What the canary's requests do (CanaryChannel): the menus, controls and
/// keys a person uses, reached inside the app, so its window needs neither
/// the focus nor the front. An action that may open a modal alert answers
/// first: the alert's loop then runs with the channel still open.
extension NiruxApp {
    typealias CanaryKey = (characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags)

    func performCanaryRequest(_ request: LeadChannel.Request, answer: @escaping @MainActor (String, Bool) -> Void) {
        let arguments = request.argumentObject
        let windows = Self.canaryWindows(main: mainWindow)
        switch request.tool {
        case "menu":
            switch Self.menuItem(path: arguments["path"] as? [String] ?? [], in: NSApp.mainMenu) {
            case .failure(let refusal): answer(refusal.text, true)
            case .success(let item):
                answer("ok", false)
                Self.pick(item)
            }
        case "press":
            guard let label = arguments["label"] as? String, let element = Self.pressTarget(label: label, in: windows) else {
                return answer("Nothing enabled is labelled \(arguments["label"] ?? "").", true)
            }
            guard element is NSControl || element is NSCell else {
                // A custom view's own press says whether it did anything.
                let pressed = element.accessibilityPerformPress()
                return answer(pressed ? "Pressed \(label)." : "\(label) has nothing to do on a press.", !pressed)
            }
            // A control's action may open a modal alert: answer first.
            answer("Pressed \(label).", false)
            Self.press(element)
        case "key", "text":
            let keys: [CanaryKey] = request.tool == "text"
                ? Self.keys(typing: arguments["text"] as? String ?? "")
                : [(
                    arguments["characters"] as? String ?? "",
                    UInt16(truncatingIfNeeded: arguments["keyCode"] as? Int ?? 0),
                    NSEvent.ModifierFlags(canaryNames: arguments["modifiers"] as? [String] ?? [])
                )]
            guard !keys.isEmpty, keys.allSatisfy({ !$0.characters.isEmpty }) else { return answer("Keys need characters.", true) }
            guard let window = mainWindow, let route = Self.keyRoute(interceptorTakesKeys: interceptorTakesKeys, in: window) else {
                return answer("Not sent: nothing in the main window has the keyboard.", true)
            }
            // Whether the view used them shows in what it does next, not here.
            answer("Sent, unconfirmed, to \(route).", false)
            send(keys, to: window)
        case "snapshot":
            answer(Self.snapshotJSON(of: windows), false)
        case "terminal":
            Self.read(canaryTerminals) { answer($0, false) }
        case "render":
            guard let view = mainWindow?.contentView, let png = Self.renderPNG(of: view) else {
                return answer("The main window didn't render.", true)
            }
            let url = Persistence.stateDirectory.appendingPathComponent(CanaryChannel.root, isDirectory: true)
                .appendingPathComponent("renders", isDirectory: true).appendingPathComponent(request.id + ".png")
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
                )
                try png.write(to: url)
                answer(url.path, false)
            } catch {
                answer("The render couldn't be saved: \(error.localizedDescription)", true)
            }
        default:
            answer("Unknown canary action: \(request.tool).", true)
        }
    }

    struct CanaryRefusal: Error {
        let text: String
    }

    /// A terminal of an open workspace, read as text (TerminalScreenText).
    struct CanaryTerminal: Sendable {
        let workspace: String
        let column: Int
        /// In the active workspace.
        let active: Bool
        /// The active workspace's focused column.
        let focused: Bool
        let read: @Sendable () -> String?
    }

    var canaryTerminals: [CanaryTerminal] {
        guard let shell else { return [] }
        return shell.workspaces.filter { !$0.isClosing }.flatMap { workspace in
            workspace.columns.enumerated().compactMap { index, column -> CanaryTerminal? in
                guard !column.isClosing, let session = column.pty?.terminalSession else { return nil }
                let active = workspace === shell.activeWorkspace
                return CanaryTerminal(
                    workspace: workspace.title, column: index, active: active, focused: active && index == workspace.focusedIndex,
                    read: { TerminalScreenText.read(session) }
                )
            }
        }
    }

    /// Their last `lines` lines as JSON, read off the main thread: Ghostty
    /// locks a terminal for the read.
    nonisolated static func read(
        _ terminals: [CanaryTerminal], lines: Int = 200, deliver: @escaping @MainActor @Sendable (String) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let payload = ["terminals": terminals.map { terminal in
                [
                    "workspace": terminal.workspace, "column": terminal.column, "active": terminal.active, "focused": terminal.focused,
                    "text": (terminal.read() ?? "").split(separator: "\n", omittingEmptySubsequences: false)
                        .suffix(lines).joined(separator: "\n"),
                ] as [String: Any]
            }]
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
            let json = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { @MainActor in deliver(json) }
        }
    }

    /// Where the canary looks and presses: an alert or a sheet first, then
    /// the main window, then the other windows on screen.
    static func canaryWindows(main: NSWindow?) -> [NSWindow] {
        var seen = Set<ObjectIdentifier>()
        return ([NSApp.modalWindow, main?.attachedSheet, main] + NSApp.windows.filter(\.isVisible))
            .compactMap { $0 }
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    /// The item at `path` (titles from the menu bar down), once its menu has
    /// validated it.
    static func menuItem(path: [String], in menuBar: NSMenu?) -> Result<NSMenuItem, CanaryRefusal> {
        var menu = menuBar
        for (depth, title) in path.enumerated() {
            guard let current = menu else { break }
            current.update()
            // A menu bar item shows its menu's title.
            guard let index = current.items.firstIndex(where: { $0.title == title || $0.submenu?.title == title }) else {
                return .failure(CanaryRefusal(text: "No menu item " + path.prefix(depth + 1).joined(separator: " › ") + "."))
            }
            guard depth == path.count - 1 else {
                menu = current.items[index].submenu
                continue
            }
            guard current.items[index].submenu == nil else { return .failure(CanaryRefusal(text: title + " opens a menu.")) }
            let item = current.items[index]
            guard item.isEnabled else { return .failure(CanaryRefusal(text: title + " is disabled.")) }
            guard let action = item.action, NSApp.target(forAction: action, to: item.target, from: item) != nil else {
                return .failure(CanaryRefusal(text: title + " has nothing to act on it."))
            }
            return .success(item)
        }
        return .failure(CanaryRefusal(text: "No menu item " + path.joined(separator: " › ") + "."))
    }

    /// Sends the item's action as a click on it does.
    static func pick(_ item: NSMenuItem) {
        guard let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    /// Where the window's keys land, told before they're sent.
    enum KeyRoute: CustomStringConvertible {
        /// A terminal column: the key interceptor maps keys to its PTY.
        case interceptor
        /// Anything else: what the interceptor hands back goes to the view
        /// with the keyboard, as AppKit sends it to the key window.
        case responder(NSResponder)

        var description: String {
            switch self {
            case .interceptor: "the terminal through the key interceptor"
            case .responder(let responder): String(describing: type(of: responder)) + " (through the key interceptor)"
            }
        }
    }

    /// Whether the key interceptor takes the main window's keys: its focused
    /// column is a terminal with nothing over it.
    var interceptorTakesKeys: Bool {
        guard let shell, !shell.isOverlayActive, let workspace = shell.activeWorkspaceForKeyIntercept,
              let column = workspace.columns[safe: workspace.focusedIndex] else { return false }
        return workspace.findFieldColumn == nil && !Self.takesWebContentKeys(column) && column.pty != nil
    }

    /// Nil when nothing in the window has the keyboard.
    static func keyRoute(interceptorTakesKeys: Bool, in window: NSWindow) -> KeyRoute? {
        if interceptorTakesKeys { return .interceptor }
        guard let responder = window.firstResponder, responder !== window else { return nil }
        return .responder(responder)
    }

    /// Every key goes through the interceptor's routing, as a typed key does.
    /// What it hands back goes where AppKit would send it: command chords to
    /// the window's views, then the menus; the rest to the view with the
    /// keyboard (the canary's window is never key, so AppKit would drop it).
    func send(_ keys: [CanaryKey], to window: NSWindow) {
        for key in keys {
            let events = [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: key.modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: key.characters, charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.keyCode
                )
            }
            guard events.count == 2, let handedBack = routeMainWindowKey(events[0]) else { continue }
            if key.modifiers.contains(.command),
               window.performKeyEquivalent(with: handedBack) || NSApp.mainMenu?.performKeyEquivalent(with: handedBack) == true {
                continue
            }
            guard let responder = window.firstResponder, responder !== window else { continue }
            responder.keyDown(with: handedBack)
            responder.keyUp(with: events[1])
        }
    }

    /// Text as US keyboard presses: each character with its key code and
    /// Shift where it needs it; others go with code 0 and their characters.
    static func keys(typing text: String) -> [CanaryKey] {
        let plain = Array("asdfhgzxcv\u{0}bqweryt123465=97-80]ou[ip\u{0}lj'k;\\,/nm.\t `")
        let shifted = Array("ASDFHGZXCV\u{0}BQWERYT!@#$^%+(&_*)}OU{IP\u{0}LJ\"K:|<?NM>\u{0}\u{0}~")
        return text.map { character in
            if character == "\r" || character == "\n" { return ("\r", 36, []) }
            if let code = plain.firstIndex(of: character), character != "\u{0}" { return (String(character), UInt16(code), []) }
            if let code = shifted.firstIndex(of: character), character != "\u{0}" { return (String(character), UInt16(code), .shift) }
            return (String(character), 0, [])
        }
    }

    /// The windows' accessibility elements as JSON.
    static func snapshotJSON(of windows: [NSWindow]) -> String {
        let payload = ["windows": windows.map { window in
            accessibilitySnapshot(of: window).merging(["title": window.title, "isSheet": window.isSheet]) { own, _ in own }
        }]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// A window's accessibility elements as an assistive app reads them,
    /// depth first, at most `limit`, with what has the keyboard.
    static func accessibilitySnapshot(of window: NSWindow, limit: Int = 800) -> [String: Any] {
        var elements: [[String: Any]] = []
        var stack: [NSAccessibilityProtocol] = [window]
        while let element = stack.popLast(), elements.count < limit {
            if element.isAccessibilityElement() {
                let frame = element.accessibilityFrame()
                let edges = [frame.origin.x, frame.origin.y, frame.width, frame.height].map { Double($0) }
                elements.append([
                    "role": element.accessibilityRole()?.rawValue ?? "",
                    "label": element.accessibilityLabel() ?? "",
                    "title": element.accessibilityTitle() ?? "",
                    "value": (element.accessibilityValue() as? CustomStringConvertible)?.description ?? "",
                    "enabled": element.isAccessibilityEnabled(),
                    "pressable": isPressable(element),
                    // JSON has no NaN or infinity: an element off every screen has no frame.
                    "frame": edges.allSatisfy(\.isFinite) ? edges : NSNull(),
                ])
            }
            stack.append(contentsOf: (element.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityProtocol }.reversed())
        }
        return [
            "elements": elements,
            "truncated": elements.count >= limit,
            "isKey": window.isKeyWindow,
            "firstResponder": window.firstResponder.map { String(describing: type(of: $0)) } ?? "",
        ]
    }

    /// Whether a control (or its cell, a button's element) is enabled; nil
    /// for a custom view, whose AXEnabled reads false although a person
    /// can click it.
    static func controlEnabled(_ element: NSAccessibilityProtocol) -> Bool? {
        (element as? NSControl)?.isEnabled ?? (element as? NSCell)?.isEnabled
    }

    /// Whether a person could press it: an enabled control, or a custom view
    /// with a press of its own (which may still have nothing to do).
    static func isPressable(_ element: NSAccessibilityProtocol) -> Bool {
        if let enabled = controlEnabled(element) { return enabled }
        guard let object = element as? NSObject else { return false }
        let press = #selector(NSView.accessibilityPerformPress)
        return type(of: object).instanceMethod(for: press) != NSView.instanceMethod(for: press)
    }

    /// The first element labelled or titled `label` that a person could
    /// press.
    static func pressTarget(label: String, in windows: [NSWindow]) -> NSAccessibilityProtocol? {
        for window in windows {
            var stack: [NSAccessibilityProtocol] = [window]
            while let element = stack.popLast() {
                if element.isAccessibilityElement(), isPressable(element),
                   element.accessibilityLabel() == label || element.accessibilityTitle() == label {
                    return element
                }
                stack.append(contentsOf: (element.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityProtocol }.reversed())
            }
        }
        return nil
    }

    /// Presses it as a click does. A control's accessibility press reports
    /// false in a window never shown although its action ran.
    static func press(_ element: NSAccessibilityProtocol) {
        if let control = element as? NSControl {
            control.performClick(nil)
        } else {
            _ = element.accessibilityPerformPress()
        }
    }

    /// The view as the app draws it; layers drawn by Metal may come out empty.
    static func renderPNG(of view: NSView) -> Data? {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}

extension NiruxApp {
    /// The launch's ties between the main shell and the notifier: whatever
    /// brings Nirux forward (the shell's questions, a clicked notification)
    /// goes through `presence`, and a click lands on its workspace or column.
    func connect(_ shellView: NiruxShellView, to notifier: NiruxNotifier) {
        shellView.sideEffects.comeToFront = { [presence] in presence.comeForward() }
        notifier.comeForward = { [presence] in presence.comeForward() }
        notifier.onActivate = { [weak shellView] workspaceID, columnIndex in
            shellView?.focusWorkspace(id: workspaceID, column: columnIndex)
        }
        notifier.onCIFailureAction = { [weak shellView] workspaceID, action in
            shellView?.handleCIFailureAction(action, workspaceID: workspaceID)
        }
        notifier.onQuickReply = { [weak shellView] target, text, workspaceID, columnIndex in
            shellView?.replyFromNotification(text, to: target, workspaceID: workspaceID, columnIndex: columnIndex)
        }
        notifier.onQuotaCompact = { [weak shellView] workspaceID, column in
            shellView?.takeNotifiedCompact(workspaceID: workspaceID, column: column) ?? false
        }
    }

    static func bringNiruxForward() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Nirux and its window come forward, unless a canary run drives it.
    func bringMainWindowForward() {
        guard presence.mayComeForward else { return }
        presence.comeForward()
        mainWindow?.makeKeyAndOrderFront(nil)
    }
}

/// A canary copy stays hidden: whatever unhides or activates it (an alert, a
/// panel, a link) is undone at once, so nothing it shows reaches the screen.
enum CanaryPresentation {
    static func keepHidden(on center: NotificationCenter, hide: @escaping @MainActor () -> Void) -> [NSObjectProtocol] {
        [NSApplication.didUnhideNotification, NSApplication.didBecomeActiveNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { hide() } }
        }
    }
}

extension NSEvent.ModifierFlags {
    /// "command", "control", "option", "shift": the canary's names.
    init(canaryNames names: [String]) {
        let flags: [String: NSEvent.ModifierFlags] = ["command": .command, "control": .control, "option": .option, "shift": .shift]
        self = names.reduce(into: []) { $0.formUnion(flags[$1] ?? []) }
    }
}
