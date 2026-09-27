import AppKit

// MARK: - Space management menus (see ProjectStore)

extension SidebarView {
    /// A space's items: rename, brief, board settings, color, delete. Used by
    /// the active space's header menu and by right-clicking any space's dot,
    /// so an empty space can be managed without opening a workspace in it.
    func addSpaceManagementItems(to menu: NSMenu, for profile: ProfileInfo) {
        menu.addClosureItem(title: "Rename Space…") { [weak self] in
            self?.onRenameProfile?(profile.id)
        }
        menu.addClosureItem(title: "Edit Space Brief…") { [weak self] in
            self?.onEditProfileBrief?(profile.id)
        }
        menu.addClosureItem(title: "Board Settings…") { [weak self] in
            self?.onEditBoardSettings?(profile.id)
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
