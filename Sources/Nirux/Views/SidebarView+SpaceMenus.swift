import AppKit

// MARK: - Space management menus (see ProjectStore)

extension SidebarView {
    /// A space's items: rename, its repositories (not the default space's),
    /// brief, board settings, task templates, Claude Code's memory, color,
    /// delete. Used by the active space's header menu and by right-clicking
    /// any space's dot, so an empty space can be managed without opening a
    /// workspace in it.
    func addSpaceManagementItems(to menu: NSMenu, for profile: ProfileInfo) {
        menu.addClosureItem(title: "Rename Project…") { [weak self] in
            self?.onRenameProfile?(profile.id)
        }
        if profile.id != WorkspaceProfile.defaultID {
            addRepositoryItems(to: menu, spaceID: profile.id)
        }
        menu.addClosureItem(title: "Edit Project Brief…") { [weak self] in
            self?.onEditProfileBrief?(profile.id)
        }
        menu.addClosureItem(title: "Board Settings…") { [weak self] in
            self?.onEditBoardSettings?(profile.id)
        }
        menu.addClosureItem(title: "Edit Task Templates…") { [weak self] in
            self?.onEditTaskTemplates?(profile.id)
        }
        menu.addClosureItem(title: "Project Memory…") { [weak self] in
            self?.onShowProjectMemory?(profile.id)
        }
        let colorItem = NSMenuItem(title: "Project Color", action: nil, keyEquivalent: "")
        let colors = NSMenu()
        for color in WorkspaceProfile.palette {
            colors.addClosureItem(title: color.name) { [weak self] in
                self?.onRecolorProfile?(profile.id, color.hex)
            }.state = color.hex.caseInsensitiveCompare(profile.colorHex) == .orderedSame ? .on : .off
        }
        colorItem.submenu = colors
        menu.addItem(colorItem)
        if profile.id != WorkspaceProfile.defaultID {
            menu.addClosureItem(title: "Delete Project…") { [weak self] in
                self?.onDeleteProfile?(profile.id)
            }
        }
        menu.addItem(.separator())
    }

    /// "Add Repository…", then "Repositories": one submenu per repository
    /// or folder, "(Default)" after the default's name, with "Make Default"
    /// and "Remove from Space" (until Space Settings, docs/spaces.md S8).
    private func addRepositoryItems(to menu: NSMenu, spaceID: String) {
        menu.addClosureItem(title: "Add Repository…") { [weak self] in
            self?.onAddRepository?(spaceID)
        }
        let anchors = spaceAnchors?(spaceID) ?? []
        guard !anchors.isEmpty else { return }
        let item = NSMenuItem(title: "Repositories", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for anchor in anchors {
            guard let key = anchor.key else { continue }
            let title = anchor.isDefault ? "\(anchor.name) (Default)" : anchor.name
            let anchorItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            anchorItem.toolTip = anchor.folder?.abbreviatedPath(maxComponents: 6)
            let actions = NSMenu()
            if !anchor.isDefault {
                actions.addClosureItem(title: "Make Default") { [weak self] in
                    self?.onMakeDefaultAnchor?(spaceID, key)
                }
            }
            actions.addClosureItem(title: "Remove from Space") { [weak self] in
                self?.onRemoveAnchor?(spaceID, key)
            }
            anchorItem.submenu = actions
            submenu.addItem(anchorItem)
        }
        item.submenu = submenu
        menu.addItem(item)
    }

    /// "Move to Project" for a workspace card. Cards list the active space's
    /// workspaces, so every other space is a target. Nil with no other space.
    func moveToSpaceItem(workspaceIndex: Int) -> NSMenuItem? {
        let otherSpaces = lastProfiles.filter { !$0.isActive }
        guard !otherSpaces.isEmpty,
              let workspaceID = lastInfos.first(where: { $0.index == workspaceIndex })?.id
        else { return nil }
        let item = NSMenuItem(title: "Move to Project", action: nil, keyEquivalent: "")
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
