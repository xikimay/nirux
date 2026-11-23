import AppKit
import ApplicationServices

// All AX lookups and events go to the PID returned by the runner's spawn.
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func pointAttribute(_ el: AXUIElement, _ name: String) -> CGPoint? {
    guard let value = attribute(el, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue((value as! AXValue), .cgPoint, &point) else { return nil }
    return point
}

func sizeAttribute(_ el: AXUIElement, _ name: String) -> CGSize? {
    guard let value = attribute(el, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue((value as! AXValue), .cgSize, &size) else { return nil }
    return size
}

func frameOf(_ el: AXUIElement) -> CGRect? {
    guard let origin = pointAttribute(el, kAXPositionAttribute),
          let size = sizeAttribute(el, kAXSizeAttribute) else { return nil }
    return CGRect(origin: origin, size: size)
}

func menuItem(_ parent: AXUIElement, title: String, depth: Int) -> AXUIElement? {
    guard depth > 0 else { return nil }
    for child in attribute(parent, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if attribute(child, kAXTitleAttribute) as? String == title { return child }
        if let found = menuItem(child, title: title, depth: depth - 1) { return found }
    }
    return nil
}

func editorHasFocus(_ app: AXUIElement) -> Bool {
    guard var node = element(app, kAXFocusedUIElementAttribute),
          attribute(node, kAXRoleAttribute) as? String == kAXTextAreaRole else { return false }
    for _ in 0..<32 {
        guard let parent = element(node, kAXParentAttribute) else { break }
        if attribute(parent, kAXRoleAttribute) as? String == "AXWebArea" { return true }
        node = parent
    }
    return false
}

func key(_ pid: pid_t, _ code: CGKeyCode, flags: CGEventFlags = [], text: String? = nil) {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { exit(1) }
        event.flags = flags
        if let text {
            let units = Array(text.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        event.postToPid(pid)
    }
}

struct AXRectPayload: Encodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.size.width)
        height = Double(rect.size.height)
    }
}

struct AXControlPayload: Encodable {
    let role: String
    let label: String
    let title: String
    let value: String
    let enabled: Bool
    let frame: AXRectPayload
    let inWindow: Bool
}

struct AXSnapshotPayload: Encodable {
    let window: AXRectPayload
    let controls: [AXControlPayload]
}

func writeJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try! encoder.encode(value))
}

let trackedRoles: Set<String> = [
    kAXButtonRole,
    kAXMenuButtonRole,
    kAXStaticTextRole,
    kAXTextFieldRole,
    kAXCheckBoxRole,
]

func collectControls(
    _ root: AXUIElement,
    windowFrame: CGRect,
    maxDepth: Int = 14,
    maxNodes: Int = 700
) -> [(AXUIElement, AXControlPayload)] {
    var results: [(AXUIElement, AXControlPayload)] = []
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    var visited = 0
    let paddedWindow = windowFrame.insetBy(dx: -2, dy: -2)
    while let (node, depth) = stack.popLast(), visited < maxNodes {
        visited += 1
        let role = attribute(node, kAXRoleAttribute) as? String ?? ""
        let desc = attribute(node, kAXDescriptionAttribute) as? String ?? ""
        let title = attribute(node, kAXTitleAttribute) as? String ?? ""
        let rawValue = attribute(node, kAXValueAttribute) as? String ?? ""
        let label = !desc.isEmpty ? desc : title
        if trackedRoles.contains(role), !label.isEmpty, let rect = frameOf(node) {
            let enabled = (attribute(node, kAXEnabledAttribute) as? Bool) ?? true
            let visible = rect.width > 0 && rect.height > 0 && paddedWindow.contains(rect)
            let payload = AXControlPayload(
                role: role,
                label: label,
                title: title,
                value: rawValue,
                enabled: enabled,
                frame: AXRectPayload(rect),
                inWindow: visible
            )
            results.append((node, payload))
        }
        guard depth < maxDepth else { continue }
        let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
        for child in children.reversed() {
            stack.append((child, depth + 1))
        }
    }
    return results
}

func pressMenuItem(_ app: AXUIElement, menuTitle: String, itemTitle: String) -> Bool {
    guard let bar = element(app, kAXMenuBarAttribute),
          let menu = menuItem(bar, title: menuTitle, depth: 1),
          let item = menuItem(menu, title: itemTitle, depth: 2) else { return false }
    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
}

func postShortcut(_ pid: pid_t, chord: String) -> Bool {
    let keyCodes: [String: CGKeyCode] = [
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
        "j": 38, "p": 35, "q": 12, "s": 1,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
    let parts = chord.lowercased().split(separator: "+").map(String.init)
    guard let keyPart = parts.last, let code = keyCodes[keyPart] else { return false }
    var flags: CGEventFlags = []
    for mod in parts.dropLast() {
        switch mod {
        case "cmd", "command": flags.insert(.maskCommand)
        case "ctrl", "control": flags.insert(.maskControl)
        case "opt", "option", "alt": flags.insert(.maskAlternate)
        case "shift": flags.insert(.maskShift)
        default: return false
        }
    }
    key(pid, code, flags: flags)
    return true
}

func run(_ args: [String]) -> Int32 {
    if args == ["preflight"] {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        var displays: UInt32 = 0
        let displayOK = CGGetActiveDisplayList(0, nil, &displays) == .success && displays > 0
        let info = [
            "display": displayOK, "onConsole": session?["kCGSSessionOnConsoleKey"] as? Bool == true,
            "unlocked": session != nil && session?["CGSSessionScreenIsLocked"] as? Bool != true,
            "accessibility": AXIsProcessTrusted(), "postEvents": CGPreflightPostEventAccess(),
        ]
        writeJSON(info)
        return 0
    }
    guard args.count >= 2, let pid = pid_t(args[1]), pid > 1 else { return 2 }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1)
    let focusedWindow = element(app, kAXFocusedWindowAttribute)
    let hasWindow = focusedWindow != nil
        && attribute(app, kAXFrontmostAttribute) as? Bool == true
    if args[0] == "window" { return hasWindow ? 0 : 3 }
    guard hasWindow, let win = focusedWindow else { return 3 }
    switch args[0] {
    case "open-editor":
        guard pressMenuItem(app, menuTitle: "Columns", itemTitle: "Open Editor") else { return 1 }
    case "menu":
        guard args.count == 4 else { return 2 }
        guard pressMenuItem(app, menuTitle: args[2], itemTitle: args[3]) else { return 1 }
    case "editor-focus":
        return editorHasFocus(app) ? 0 : 1
    case "terminal": key(pid, 18, flags: .maskCommand) // ⌘1
    case "editor": key(pid, 19, flags: .maskCommand) // ⌘2
    case "save": key(pid, 1, flags: .maskCommand)
    case "quit": key(pid, 12, flags: .maskCommand)
    case "shortcut":
        guard args.count == 3, postShortcut(pid, chord: args[2]) else { return 2 }
    case "text", "command":
        guard args.count == 3 else { return 2 }
        for char in args[2] { key(pid, 0, text: String(char)) }
        if args[0] == "command" { key(pid, 36) }
    case "window-frame":
        guard let rect = frameOf(win) else { return 1 }
        writeJSON(AXRectPayload(rect))
    case "resize-window":
        guard args.count == 4,
              let width = Double(args[2]), let height = Double(args[3]),
              width >= 400, height >= 300 else { return 2 }
        var size = CGSize(width: width, height: height)
        guard let value = AXValueCreate(.cgSize, &size),
              AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, value) == .success,
              let rect = frameOf(win) else { return 1 }
        writeJSON(AXRectPayload(rect))
    case "ax-controls":
        guard let rect = frameOf(win) else { return 1 }
        let items = collectControls(win, windowFrame: rect).map(\.1)
        writeJSON(AXSnapshotPayload(window: AXRectPayload(rect), controls: items))
    case "press-control":
        guard args.count == 3 || (args.count == 4 && args[2] == "--prefix") else { return 2 }
        let prefixMode = args.count == 4
        let needle = prefixMode ? args[3] : args[2]
        guard let rect = frameOf(win) else { return 1 }
        let match = collectControls(win, windowFrame: rect).first { _, payload in
            guard payload.enabled else { return false }
            if prefixMode { return payload.label.hasPrefix(needle) }
            return payload.label == needle
        }
        guard let target = match?.0,
              AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else { return 1 }
    default: return 2
    }
    return 0
}

exit(run(Array(CommandLine.arguments.dropFirst())))
