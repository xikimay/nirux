import AppKit

/// What the canary's requests do (CanaryChannel): the menus, controls and
/// keys a person uses, reached inside the app, so its window needs neither
/// the focus nor the front. An action that may open a modal alert answers
/// first: the alert's loop then runs with the channel still open.
extension NiruxApp {
    typealias CanaryKey = (characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags)

    func performCanaryRequest(_ request: LeadChannel.Request, answer: @MainActor (String, Bool) -> Void) {
        let arguments = request.argumentObject
        let windows = Self.canaryWindows(main: mainWindow)
        switch request.tool {
        case "menu":
            switch Self.menuItem(path: arguments["path"] as? [String] ?? [], in: NSApp.mainMenu) {
            case .failure(let refusal): answer(refusal.text, true)
            case .success(let target):
                answer("ok", false)
                target.menu.performActionForItem(at: target.index)
            }
        case "press":
            guard let label = arguments["label"] as? String, let element = Self.pressTarget(label: label, in: windows) else {
                return answer("Nothing enabled is labelled \(arguments["label"] ?? "").", true)
            }
            answer("Pressed \(label).", false)
            Self.press(element)
        case "key", "text":
            guard let window = mainWindow else { return answer("No main window.", true) }
            let keys: [CanaryKey] = request.tool == "text"
                ? (arguments["text"] as? String ?? "").map { (String($0), 0, []) }
                : [(
                    arguments["characters"] as? String ?? "",
                    UInt16(truncatingIfNeeded: arguments["keyCode"] as? Int ?? 0),
                    NSEvent.ModifierFlags(canaryNames: arguments["modifiers"] as? [String] ?? [])
                )]
            guard !keys.isEmpty, keys.allSatisfy({ !$0.characters.isEmpty }) else { return answer("Keys need characters.", true) }
            let (text, isError) = Self.deliver(keys, to: window)
            answer(text, isError)
        case "snapshot":
            answer(Self.snapshotJSON(of: windows), false)
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
    static func menuItem(path: [String], in menuBar: NSMenu?) -> Result<(menu: NSMenu, index: Int), CanaryRefusal> {
        var menu = menuBar
        for (depth, title) in path.enumerated() {
            guard let current = menu else { break }
            current.update()
            guard let index = current.items.firstIndex(where: { $0.title == title }) else {
                return .failure(CanaryRefusal(text: "No menu item " + path.prefix(depth + 1).joined(separator: " › ") + "."))
            }
            guard depth == path.count - 1 else {
                menu = current.items[index].submenu
                continue
            }
            guard current.items[index].submenu == nil else { return .failure(CanaryRefusal(text: title + " opens a menu.")) }
            guard current.items[index].isEnabled else { return .failure(CanaryRefusal(text: title + " is disabled.")) }
            return .success((current, index))
        }
        return .failure(CanaryRefusal(text: "No menu item " + path.joined(separator: " › ") + "."))
    }

    /// Keys as the focused view gets them. Command chords go to the menus
    /// first, as AppKit sends them. The canary's window is never key, so
    /// AppKit would drop the rest: they go to the window's first responder,
    /// and are refused when nothing in the window has the keyboard.
    static func deliver(_ keys: [CanaryKey], to window: NSWindow) -> (text: String, isError: Bool) {
        var reached: [String] = []
        for key in keys {
            let events = [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: key.modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: key.characters, charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.keyCode
                )
            }
            guard events.count == 2 else { return ("A key event couldn't be made.", true) }
            if key.modifiers.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: events[0]) == true {
                reached.append("menu")
                continue
            }
            guard let responder = window.firstResponder, responder !== window else {
                return ("Not delivered: nothing in the window has the keyboard.", true)
            }
            responder.keyDown(with: events[0])
            responder.keyUp(with: events[1])
            reached.append(String(describing: type(of: responder)))
        }
        return ("Delivered to " + Set(reached).sorted().joined(separator: ", ") + ".", false)
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

    /// The first enabled element labelled or titled `label`.
    static func pressTarget(label: String, in windows: [NSWindow]) -> NSAccessibilityProtocol? {
        for window in windows {
            var stack: [NSAccessibilityProtocol] = [window]
            while let element = stack.popLast() {
                if element.isAccessibilityElement(), element.isAccessibilityEnabled(),
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

extension NSEvent.ModifierFlags {
    /// "command", "control", "option", "shift": the canary's names.
    init(canaryNames names: [String]) {
        let flags: [String: NSEvent.ModifierFlags] = ["command": .command, "control": .control, "option": .option, "shift": .shift]
        self = names.reduce(into: []) { $0.formUnion(flags[$1] ?? []) }
    }
}
