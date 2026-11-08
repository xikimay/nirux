import AppKit

// MARK: - Space picker menu (see ProjectStore)

extension SidebarView {
    /// The space picker's menu (and the rail's space tile's): every space,
    /// then New Space…, Space Settings… (one window for the active space:
    /// name, color, repositories, brief, board, templates, memory) and
    /// Delete Space…, which the window doesn't offer.
    func spacePickerMenu() -> NSMenu {
        let menu = NSMenu()
        addSpaceList(to: menu)
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addClosureItem(title: Self.newSpaceTitle) { [weak self] in
            self?.onCreateProfile?()
        }
        guard let active = lastProfiles.first(where: \.isActive) else { return menu }
        menu.addClosureItem(title: Self.spaceSettingsTitle) { [weak self] in
            self?.onShowSpaceSettings?(active.id)
        }
        if active.id != WorkspaceProfile.defaultID {
            menu.addClosureItem(title: "Delete Space…") { [weak self] in
                self?.onDeleteProfile?(active.id)
            }
        }
        return menu
    }

    /// Shared with the menu bar's Space › Space Settings….
    static let spaceSettingsTitle = "Space Settings…"

    /// One item per space, General first: its color, its name, an amber
    /// dot while an agent there waits on the user, its task count, and
    /// ⌥⌘1…⌥⌘9 for the first nine (the menu bar's Space menu binds them).
    func addSpaceList(to menu: NSMenu) {
        for (position, profile) in lastProfiles.enumerated() {
            let item = menu.addClosureItem(title: profile.name) { [weak self] in
                self?.onProfileClicked?(profile.id)
            }
            Self.describeSpace(item, profile: profile, position: position)
        }
    }

    /// A space's menu item, in the picker and in the menu bar alike (which
    /// reuses its items: everything set here is set every time).
    static func describeSpace(_ item: NSMenuItem, profile: ProfileInfo, position: Int) {
        // A title set over an attributed one doesn't replace what is drawn.
        item.attributedTitle = nil
        item.title = profile.name
        item.state = profile.isActive ? .on : .off
        let isGeneral = profile.id == WorkspaceProfile.defaultID
        item.image = isGeneral
            ? SidebarRenderer.symbol(Theme.Symbol.generalSpace, color: Theme.Color.textSecondary, pointSize: 12)
            : SidebarRenderer.dot(profileColor(hex: profile.colorHex), diameter: 9, isHollow: profile.workspaceCount == 0)
        if #available(macOS 14.4, *) {
            item.subtitle = isGeneral ? "Everything without a space" : nil
        }
        // Amber while an agent waits on the user; red once something broke
        // (an agent's error, a failed check), as the cards say it.
        let mark: (color: NSColor, note: String)? = switch profile.attention {
        case .waiting?: (Theme.Color.waiting, "An agent waits for you")
        case .error?: (Theme.Color.error, "An agent stopped or a check failed")
        default: nil
        }
        if let mark {
            // The menu's own font: an attributed title draws in its own.
            let font = NSFont.menuFont(ofSize: 0)
            let title = NSMutableAttributedString(string: profile.name, attributes: [.font: font])
            title.append(NSAttributedString(string: "  ●", attributes: [.font: font, .foregroundColor: mark.color]))
            item.attributedTitle = title
            item.toolTip = mark.note
            item.setAccessibilityLabel("\(profile.name), \(mark.note.lowercased())")
        } else {
            item.toolTip = nil
            item.setAccessibilityLabel(nil)
        }
        item.badge = NSMenuItemBadge(string: "\(profile.taskCount)")
        if let key = spaceKeyEquivalent(position: position) {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = [.command, .option]
        } else {
            item.keyEquivalent = ""
        }
    }

    /// ⌥⌘1 to ⌥⌘9: the first nine spaces. ⌘1…⌘9 focus columns.
    static func spaceKeyEquivalent(position: Int) -> String? {
        (0..<9).contains(position) ? "\(position + 1)" : nil
    }

    /// "Move to Space" for a workspace card. Cards list the active space's
    /// workspaces, so every other space is a target. Nil with no other space.
    func moveToSpaceItem(workspaceIndex: Int) -> NSMenuItem? {
        let otherSpaces = lastProfiles.filter { !$0.isActive }
        guard !otherSpaces.isEmpty,
              let workspaceID = lastInfos.first(where: { $0.index == workspaceIndex })?.id
        else { return nil }
        let item = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for space in otherSpaces {
            submenu.addClosureItem(title: space.name) { [weak self] in
                self?.onMoveWorkspaceToProfile?(workspaceID, space.id)
            }
        }
        item.submenu = submenu
        return item
    }
}
