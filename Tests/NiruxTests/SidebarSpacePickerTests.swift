import XCTest
@testable import Nirux

/// The space picker at the top of the sidebar (and behind the rail's space
/// tile), and the menu bar's ⌥⌘1…⌥⌘9.
@MainActor
final class SidebarSpacePickerTests: XCTestCase {
    private func space(
        _ id: String, isActive: Bool = false, workspaces: Int = 1, tasks: Int = 1, attention: AttentionSignal? = nil
    ) -> ProfileInfo {
        ProfileInfo(
            id: id, name: id == WorkspaceProfile.defaultID ? "General" : id, colorHex: "#78A3F7", isActive: isActive,
            workspaceCount: workspaces, taskCount: tasks, attention: attention
        )
    }

    private var spaces: [ProfileInfo] {
        [
            space(WorkspaceProfile.defaultID, isActive: true, workspaces: 3, tasks: 2),
            space("client", workspaces: 6, tasks: 4, attention: .waiting),
            space("perso", workspaces: 0, tasks: 0, attention: .error)
        ]
    }

    /// General first, then each space with its task count, amber only
    /// while an agent waits on the user, and ⌥⌘1…; then New Space… and the
    /// active space's settings. Choosing a space switches to it.
    func testMenuListsSpacesThenNewSpaceAndSettings() throws {
        let sidebar = SidebarView()
        sidebar.update(profiles: spaces, workspaces: [])
        var selected: [String] = []
        sidebar.onProfileClicked = { selected.append($0) }

        let menu = sidebar.spacePickerMenu()
        // An attributed title is the title: the amber dot is in it.
        XCTAssertEqual(menu.items.map(\.title), ["General", "client  ●", "perso  ●", "", "New Space…", "Space Settings"])
        XCTAssertEqual(menu.items.prefix(3).map(\.state), [.on, .off, .off])
        XCTAssertEqual(menu.items.prefix(3).map { $0.badge?.stringValue }, ["2", "4", "0"])
        XCTAssertEqual(menu.items.prefix(3).map(\.keyEquivalent), ["1", "2", "3"])
        XCTAssertTrue(menu.items.prefix(3).allSatisfy { $0.keyEquivalentModifierMask == [.command, .option] })
        func mark(_ index: Int) -> NSColor? {
            guard let title = menu.items[index].attributedTitle else { return nil }
            return title.attribute(.foregroundColor, at: title.length - 1, effectiveRange: nil) as? NSColor
        }
        XCTAssertEqual([mark(0), mark(1), mark(2)], [nil, Theme.Color.waiting, Theme.Color.error])
        XCTAssertTrue(try XCTUnwrap(menu.item(withTitle: "Space Settings")?.submenu).items.contains { $0.title == "Rename Space…" })

        menu.performActionForItem(at: 1)
        XCTAssertEqual(selected, ["client"])
    }

    /// The closed picker says when an agent waits in another space, which
    /// the sidebar doesn't show: not for the space on screen, whose cards
    /// say it, nor for an error. The rail's space tile says it too.
    func testPickerSaysAnotherSpaceWaits() throws {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        sidebar.isExpanded = true
        func pickerValue() throws -> String? {
            try XCTUnwrap(sidebar.contentDocumentView.subviews.lazy.compactMap { $0 as? SidebarSectionToggleView }.first {
                $0.accessibilityLabel() == "Space"
            }).accessibilityValue() as? String
        }

        sidebar.update(profiles: spaces, workspaces: [])
        XCTAssertEqual(try pickerValue(), "General. An agent waits for you in client")
        sidebar.isExpanded = false
        XCTAssertEqual(sidebar.railTileViews[.railButton(.project)]?.style.badge, Theme.Color.waiting)

        var calm = spaces
        calm[0] = space(WorkspaceProfile.defaultID, isActive: true, attention: .waiting)
        calm[1] = space("client")
        sidebar.update(profiles: calm, workspaces: [])
        XCTAssertNil(sidebar.railTileViews[.railButton(.project)]?.style.badge)
        sidebar.isExpanded = true
        XCTAssertEqual(try pickerValue(), "General")
    }

    /// The menu bar's Space menu hears of every change to the spaces, so
    /// its chords are right before it ever opens.
    func testSidebarAnnouncesSpaceChanges() {
        let sidebar = SidebarView()
        let counter = NotificationCounter()
        NotificationCenter.default.addObserver(
            counter, selector: #selector(NotificationCounter.count(_:)),
            name: SidebarView.spacesDidChangeNotification, object: sidebar
        )
        defer { NotificationCenter.default.removeObserver(counter) }

        sidebar.update(profiles: spaces, workspaces: [])
        sidebar.update(profiles: spaces, workspaces: [])
        XCTAssertEqual(counter.posted, 1)
        sidebar.update(profiles: Array(spaces.prefix(2)), workspaces: [])
        XCTAssertEqual(counter.posted, 2)
    }

    /// The Tasks header's "+" opens New…, for VoiceOver too, and its hit
    /// area is under it.
    func testTasksHeaderPlusOpensNew() throws {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        sidebar.isExpanded = true
        sidebar.update(profiles: spaces, workspaces: [])
        var opened = 0
        sidebar.onNewWorkspace = { opened += 1 }

        let plus = try XCTUnwrap(sidebar.newTaskButton)
        XCTAssertTrue(plus.isAccessibilityElement())
        XCTAssertEqual(plus.accessibilityLabel(), "New…")
        XCTAssertTrue(plus.accessibilityPerformPress())
        XCTAssertEqual(opened, 1)
        guard case .newTask? = sidebar.hitArea(at: NSPoint(x: plus.frame.midX, y: plus.frame.midY))?.region else {
            return XCTFail("the + has no hit area")
        }
    }

    /// The Space menu's nine items follow the spaces, and bind ⌥⌘1…⌥⌘9
    /// without taking a chord from another item of the menu bar (⌘1…⌘9
    /// focus columns).
    func testMenuBarSpaceItemsFollowSpacesWithFreeChords() throws {
        var profiles = spaces
        let menu = SpaceListMenu(title: "Space") { profiles }
        menu.addSpaceItems()
        menu.refresh()
        XCTAssertEqual(menu.spaceItems.filter { !$0.isHidden }.map(\.title), ["General", "client  ●", "perso  ●"])
        XCTAssertEqual(menu.spaceItems.map(\.keyEquivalent), ["1", "2", "3", "", "", "", "", "", ""])

        // The items are reused: a mark that went away leaves no title behind.
        profiles[1] = space("client")
        menu.refresh()
        XCTAssertNil(menu.spaceItems[1].attributedTitle)
        XCTAssertEqual(menu.spaceItems[1].title, "client")

        profiles = (0..<10).map { space("s\($0)", isActive: $0 == 0) }
        menu.refresh()
        XCTAssertEqual(menu.spaceItems.map(\.title), (0..<9).map { "s\($0)" })
        XCTAssertFalse(menu.spaceItems.contains(where: \.isHidden))
        let spaceChords = Set(menu.spaceItems.map { KeyChord($0.keyEquivalent, $0.keyEquivalentModifierMask) })
        XCTAssertEqual(spaceChords, Set((1...9).map { KeyChord("\($0)", [.command, .option]) }))

        func flatten(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { item in [item] + (item.submenu.map(flatten) ?? []) }
        }
        let mainMenu = NiruxApp().makeMainMenu()
        let others = flatten(mainMenu).filter { !$0.keyEquivalent.isEmpty }
        for item in others where spaceChords.contains(KeyChord(item.keyEquivalent, item.keyEquivalentModifierMask)) {
            XCTFail("\"\(item.title)\" takes a space's chord")
        }
        let barSpaces = try XCTUnwrap(mainMenu.items.lazy.compactMap { $0.submenu as? SpaceListMenu }.first)
        XCTAssertEqual(barSpaces.spaceItems.map(\.tag), Array(1...9))
        XCTAssertTrue(barSpaces.spaceItems.allSatisfy { $0.action == #selector(NiruxApp.selectSpaceByNumber(_:)) })
    }
}

private final class NotificationCounter: NSObject {
    private(set) var posted = 0

    @objc func count(_ notification: Notification) {
        posted += 1
    }
}
