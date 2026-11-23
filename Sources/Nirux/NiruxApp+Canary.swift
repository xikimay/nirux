import AppKit

/// What the canary's requests do (CanaryChannel): the menus and keys a
/// person uses, sent inside the app, so its window needs neither the focus
/// nor the front.
extension NiruxApp {
    func performCanaryRequest(_ request: LeadChannel.Request, answer: @MainActor (String, Bool) -> Void) {
        let arguments = request.argumentObject
        switch request.tool {
        case "menu":
            let (text, isError) = Self.pickMenuItem(path: arguments["path"] as? [String] ?? [], in: NSApp.mainMenu)
            answer(text, isError)
        case "key":
            guard let window = mainWindow, let characters = arguments["characters"] as? String, !characters.isEmpty else {
                return answer("A key needs characters and the main window.", true)
            }
            let modifiers = NSEvent.ModifierFlags(canaryNames: arguments["modifiers"] as? [String] ?? [])
            let keyCode = UInt16(truncatingIfNeeded: arguments["keyCode"] as? Int ?? 0)
            Self.sendKey(characters, keyCode: keyCode, modifiers: modifiers, to: window)
            answer("ok", false)
        case "text":
            guard let window = mainWindow, let text = arguments["text"] as? String else {
                return answer("Text needs a string and the main window.", true)
            }
            for character in text { Self.sendKey(String(character), keyCode: 0, modifiers: [], to: window) }
            answer("ok", false)
        case "snapshot":
            guard let window = mainWindow else { return answer("No main window.", true) }
            let snapshot = Self.accessibilitySnapshot(of: window)
            answer(String(decoding: (try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])) ?? Data(), as: UTF8.self), false)
        case "press":
            guard let window = mainWindow, let label = arguments["label"] as? String else {
                return answer("A press needs a label and the main window.", true)
            }
            let (text, isError) = Self.press(label: label, in: window)
            answer(text, isError)
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

    /// Picks the item at `path` (titles from the menu bar down), once its
    /// menu has validated it, as a click does.
    static func pickMenuItem(path: [String], in menuBar: NSMenu?) -> (text: String, isError: Bool) {
        var menu = menuBar
        for (depth, title) in path.enumerated() {
            guard let current = menu else { break }
            current.update()
            guard let index = current.items.firstIndex(where: { $0.title == title }) else {
                return ("No menu item " + path.prefix(depth + 1).joined(separator: " › ") + ".", true)
            }
            guard depth == path.count - 1 else {
                menu = current.items[index].submenu
                continue
            }
            guard current.items[index].submenu == nil else { return (title + " opens a menu.", true) }
            guard current.items[index].isEnabled else { return (title + " is disabled.", true) }
            current.performActionForItem(at: index)
            return ("ok", false)
        }
        return ("No menu item " + path.joined(separator: " › ") + ".", true)
    }

    /// A key down and up through the app's event dispatch, so its key
    /// interceptor routes it to the focused column as it does a typed key.
    static func sendKey(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, to window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ) else { continue }
            NSApp.sendEvent(event)
        }
    }

    /// The window's accessibility elements as an assistive app reads them,
    /// depth first, at most `limit`, with what has the keyboard.
    static func accessibilitySnapshot(of window: NSWindow, limit: Int = 800) -> [String: Any] {
        var elements: [[String: Any]] = []
        var stack: [NSAccessibilityProtocol] = [window]
        while let element = stack.popLast(), elements.count < limit {
            if element.isAccessibilityElement() {
                let frame = element.accessibilityFrame()
                elements.append([
                    "role": element.accessibilityRole()?.rawValue ?? "",
                    "label": element.accessibilityLabel() ?? "",
                    "title": element.accessibilityTitle() ?? "",
                    "value": (element.accessibilityValue() as? CustomStringConvertible)?.description ?? "",
                    "enabled": element.isAccessibilityEnabled(),
                    "frame": [frame.origin.x, frame.origin.y, frame.width, frame.height].map { Double($0) },
                ])
            }
            let children = (element.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityProtocol }
            stack.append(contentsOf: children.reversed())
        }
        return [
            "elements": elements,
            "truncated": elements.count >= limit,
            "isKey": window.isKeyWindow,
            "firstResponder": window.firstResponder.map { String(describing: type(of: $0)) } ?? "",
        ]
    }

    /// Presses the first enabled element labelled or titled `label`, as
    /// VoiceOver does.
    static func press(label: String, in window: NSWindow) -> (text: String, isError: Bool) {
        var stack: [NSAccessibilityProtocol] = [window]
        while let element = stack.popLast() {
            if element.isAccessibilityElement(), element.isAccessibilityEnabled(),
               element.accessibilityLabel() == label || element.accessibilityTitle() == label {
                return element.accessibilityPerformPress() ? ("ok", false) : (label + " doesn't press.", true)
            }
            stack.append(contentsOf: (element.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityProtocol }.reversed())
        }
        return ("Nothing enabled is labelled " + label + ".", true)
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
