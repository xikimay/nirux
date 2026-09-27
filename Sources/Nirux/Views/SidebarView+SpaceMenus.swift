import AppKit

// MARK: - Space management menus (see ProjectStore)

extension SidebarView {
    /// The active space's items in the header menu: rename, brief, color,
    /// delete.
    func addSpaceManagementItems(to menu: NSMenu, for profile: ProfileInfo) {
        menu.addClosureItem(title: "Rename Space…") { [weak self] in
            self?.onRenameProfile?(profile.id)
        }
        menu.addClosureItem(title: "Edit Space Brief…") { [weak self] in
            self?.onEditProfileBrief?(profile.id)
        }
        let colorItem = NSMenuItem(title: "Space Color", action: nil, keyEquivalent: "")
        let colors = NSMenu()
        for color in WorkspaceProfile.palette {
            colors.addClosureItem(title: color.name) { [weak self] in
                self?.onRecolorProfile?(profile.id, color.hex)
            }.state = color.hex.caseInsensitiveCompare(profile.colorHex) == .orderedSame ? .on : .off
        }
        colorItem.submenu = colors
        menu.addItem(colorItem)
        if profile.id != WorkspaceProfile.defaultID {
            menu.addClosureItem(title: "Delete Space…") { [weak self] in
                self?.onDeleteProfile?(profile.id)
            }
        }
        menu.addItem(.separator())
    }

    /// "Move to Space" for a workspace card. Cards list the active space's
    /// workspaces, so every other space is a target. Nil with no other space.
    func moveToSpaceItem(workspaceIndex: Int) -> NSMenuItem? {
        let otherSpaces = lastProfiles.filter { !$0.isActive }
        guard !otherSpaces.isEmpty else { return nil }
        let item = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for space in otherSpaces {
            submenu.addClosureItem(title: space.name) { [weak self] in
                self?.onWorkspaceAction?(.moveToProfile(space.id), workspaceIndex)
            }
        }
        item.submenu = submenu
        return item
    }
}
