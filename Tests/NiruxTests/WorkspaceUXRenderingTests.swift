import AppKit
import XCTest
@testable import Nirux

@MainActor
final class WorkspaceUXRenderingTests: XCTestCase {
    private static let application: NSApplication = {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        return application
    }()

    private func requireInteractiveAppKit() throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != "true" else {
            throw XCTSkip("AppKit window rendering requires an interactive macOS session")
        }
        _ = Self.application
    }

    private func workspace(
        id: String,
        index: Int,
        title: String,
        isInactive: Bool,
        isActive: Bool = false
    ) -> WorkspaceInfo {
        WorkspaceInfo(
            id: id,
            index: index,
            title: title,
            profileID: WorkspaceProfile.defaultID,
            isInactive: isInactive,
            columnCount: 1,
            focusedColumn: 0,
            gitBranch: "fix/\(id)",
            hasNotification: false,
            isActive: isActive,
            columns: [
                ColumnInfo(
                    index: 0,
                    processName: "codex",
                    abbreviatedCwd: "~/nirux",
                    isFocused: isActive,
                    isWebView: false,
                    webTitle: nil,
                    terminalTitle: nil,
                    agentStatus: .idle,
                    isEditor: false,
                    editorFileName: nil
                )
            ],
            prInfo: nil,
            diffStats: nil,
            purpose: nil,
            nextStep: nil,
            blocker: nil,
            phase: isInactive ? .parked : .active,
            lastSummary: nil,
            lastActivityAt: nil
        )
    }

    func testInactiveSectionRendersCollapsedAndExpandedWithoutActivityFeed() throws {
        try requireInteractiveAppKit()
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        let window = NSWindow(
            contentRect: sidebar.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = sidebar
        window.orderFront(nil)
        defer { window.close() }

        sidebar.isExpanded = true
        sidebar.update(
            profiles: [
                ProfileInfo(
                    id: WorkspaceProfile.defaultID,
                    name: "main",
                    colorHex: "#7AA2F7",
                    isActive: true,
                    workspaceCount: 4,
                    hasAttention: false
                )
            ],
            workspaces: [
                workspace(id: "api", index: 0, title: "API cleanup", isInactive: false),
                workspace(
                    id: "workspace-ux",
                    index: 1,
                    title: "Workspace UX polish",
                    isInactive: false,
                    isActive: true
                ),
                workspace(id: "release", index: 2, title: "Release notes", isInactive: true),
                workspace(id: "search", index: 3, title: "Search prototype", isInactive: true)
            ]
        )
        sidebar.layoutSubtreeIfNeeded()

        var visibleText = text(in: sidebar)
        XCTAssertTrue(visibleText.contains("▸ INACTIVE"))
        XCTAssertFalse(visibleText.contains("Release notes"))
        XCTAssertFalse(visibleText.contains("ACTIVITY"))
        try capture(sidebar, named: "workspace-sidebar-collapsed.png")

        var renamedWorkspaceIndex: Int?
        sidebar.onWorkspaceAction = { action, index in
            if case .rename = action { renamedWorkspaceIndex = index }
        }
        let workspaceCard = try XCTUnwrap(sidebar.hitAreas.first {
            if case .workspace(1) = $0.region { return true }
            return false
        })
        sidebar.mouseDown(with: try mouseEvent(
            in: sidebar,
            at: workspaceCard.frame.center,
            clickCount: 2
        ))
        XCTAssertEqual(renamedWorkspaceIndex, 1)

        let inactiveHeader = try XCTUnwrap(sidebar.hitAreas.first {
            if case .link(let url, _) = $0.region {
                return url == SidebarView.inactiveSectionActionURL
            }
            return false
        })
        sidebar.mouseDown(with: try mouseEvent(
            in: sidebar,
            at: inactiveHeader.frame.center,
            clickCount: 1
        ))
        sidebar.layoutSubtreeIfNeeded()

        visibleText = text(in: sidebar)
        XCTAssertTrue(visibleText.contains("▾ INACTIVE"))
        XCTAssertTrue(visibleText.contains("Release notes"))
        XCTAssertTrue(visibleText.contains("Search prototype"))
        XCTAssertFalse(visibleText.contains("ACTIVITY"))
        try capture(sidebar, named: "workspace-sidebar-expanded.png")
    }

    func testWorkspaceNamingPanelAcceptsNewAndReplacementNames() throws {
        try requireInteractiveAppKit()
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        hostWindow.orderFront(nil)
        defer { hostWindow.close() }

        let namePanel = NameInputPanel()
        var submittedNames: [String] = []
        namePanel.onSubmit = { submittedNames.append($0) }
        namePanel.show(
            relativeTo: hostWindow,
            currentValue: "",
            placeholder: "Name this workspace for the task"
        )

        let newNameField = try XCTUnwrap(textField(targeting: namePanel))
        XCTAssertEqual(newNameField.placeholderString, "Name this workspace for the task")
        XCTAssertEqual(newNameField.stringValue, "")
        try capture(try XCTUnwrap(newNameField.window?.contentView), named: "workspace-name-new.png")
        newNameField.stringValue = "  Customer onboarding  "
        XCTAssertTrue(NSApp.sendAction(
            try XCTUnwrap(newNameField.action),
            to: newNameField.target,
            from: newNameField
        ))
        XCTAssertEqual(submittedNames, ["Customer onboarding"])

        namePanel.show(
            relativeTo: hostWindow,
            currentValue: "Workspace UX polish",
            placeholder: "Workspace name"
        )
        let renameField = try XCTUnwrap(textField(targeting: namePanel))
        XCTAssertEqual(renameField.placeholderString, "Workspace name")
        XCTAssertEqual(renameField.stringValue, "Workspace UX polish")
        try capture(try XCTUnwrap(renameField.window?.contentView), named: "workspace-name-rename.png")
        renameField.stringValue = "Navigation polish"
        XCTAssertTrue(NSApp.sendAction(
            try XCTUnwrap(renameField.action),
            to: renameField.target,
            from: renameField
        ))
        XCTAssertEqual(submittedNames, ["Customer onboarding", "Navigation polish"])
    }

    private func capture(_ view: NSView, named filename: String) throws {
        guard let evidenceDirectory = ProcessInfo.processInfo.environment["NO_MISTAKES_EVIDENCE_DIR"],
              !evidenceDirectory.isEmpty
        else { return }

        let directoryURL = URL(fileURLWithPath: evidenceDirectory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let transparentBitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: transparentBitmap)
        let bitmap = try opaqueBitmap(from: transparentBitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directoryURL.appendingPathComponent(filename), options: .atomic)
    }

    private func opaqueBitmap(from bitmap: NSBitmapImageRep) throws -> NSBitmapImageRep {
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.11, green: 0.11, blue: 0.14, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(
            try XCTUnwrap(bitmap.cgImage),
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        return NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
    }

    private func text(in view: NSView) -> [String] {
        var values: [String] = []
        if let label = view as? NSTextField, !label.stringValue.isEmpty {
            values.append(label.stringValue)
        }
        for subview in view.subviews {
            values.append(contentsOf: text(in: subview))
        }
        return values
    }

    private func textField(targeting target: AnyObject) -> NSTextField? {
        for window in NSApp.windows {
            guard let contentView = window.contentView else { continue }
            if let field = textFields(in: contentView).first(where: {
                ($0.target as AnyObject?) === target
            }) {
                return field
            }
        }
        return nil
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        var fields: [NSTextField] = []
        if let field = view as? NSTextField {
            fields.append(field)
        }
        for subview in view.subviews {
            fields.append(contentsOf: textFields(in: subview))
        }
        return fields
    }

    private func mouseEvent(
        in sidebar: SidebarView,
        at documentPoint: NSPoint,
        clickCount: Int
    ) throws -> NSEvent {
        let locationInWindow = sidebar.contentDocumentView.convert(documentPoint, to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: try XCTUnwrap(sidebar.window).windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 0
        ))
    }

}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
