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
        FileHandle.standardOutput.write(try! JSONEncoder().encode(info))
        return 0
    }
    guard args.count >= 2, let pid = pid_t(args[1]), pid > 1 else { return 2 }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1)
    let hasWindow = element(app, kAXFocusedWindowAttribute) != nil
        && attribute(app, kAXFrontmostAttribute) as? Bool == true
    if args[0] == "window" { return hasWindow ? 0 : 3 }
    guard hasWindow else { return 3 }
    switch args[0] {
    case "open-editor":
        guard let bar = element(app, kAXMenuBarAttribute),
              let columns = menuItem(bar, title: "Columns", depth: 1),
              let item = menuItem(columns, title: "Open Editor", depth: 2),
              AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else { return 1 }
    case "editor-focus":
        return editorHasFocus(app) ? 0 : 1
    case "terminal": key(pid, 18, flags: .maskCommand) // ⌘1
    case "editor": key(pid, 19, flags: .maskCommand) // ⌘2
    case "save": key(pid, 1, flags: .maskCommand)
    case "quit": key(pid, 12, flags: .maskCommand)
    case "text", "command":
        guard args.count == 3 else { return 2 }
        for char in args[2] { key(pid, 0, text: String(char)) }
        if args[0] == "command" { key(pid, 36) }
    default: return 2
    }
    return 0
}

exit(run(Array(CommandLine.arguments.dropFirst())))
