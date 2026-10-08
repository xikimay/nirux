import AppKit

// MARK: - Groups (docs/sidebar-groups.md)

extension SidebarView {
    /// Some workspace is listed under it, and could show: not when the
    /// card itself is listed only for being on screen or asking the user,
    /// in a folded section or group.
    func showsGroupToggle(_ workspace: WorkspaceInfo) -> Bool {
        lastInfos.contains { $0.groupParentID == workspace.id }
            && listsWorkspace(isInactive: workspace.isInactive, isInFoldedGroup: workspace.isInFoldedGroup, isActive: false)
    }

    /// Its children, each followed by its own, listed or folded.
    func groupMembers(of workspace: WorkspaceInfo) -> [WorkspaceInfo] {
        lastInfos.filter { $0.groupParentID == workspace.id }.flatMap { [$0] + groupMembers(of: $0) }
    }

    /// The summary rows under the workspaces of `infos` that have children.
    func groupTogglesHeight(_ infos: [WorkspaceInfo]) -> CGFloat {
        CGFloat(infos.filter(showsGroupToggle).count) * (SidebarExpandedMetrics.groupToggleHeight + SidebarExpandedMetrics.workspaceGap)
    }

    /// The row under a workspace with children, where its children start:
    /// it folds and unfolds them.
    func buildGroupToggle(_ parent: WorkspaceInfo, yOffset: CGFloat) -> CGFloat {
        let metrics = SidebarExpandedMetrics.self
        let rowX = metrics.workspaceInsetX + metrics.groupIndent
        let rowFrame = NSRect(
            x: rowX, y: yOffset - metrics.groupToggleHeight,
            width: bounds.width - metrics.workspaceInsetX - rowX, height: metrics.groupToggleHeight
        )
        let textX = rowX + metrics.cardPaddingX
        let members = groupMembers(of: parent)
        let label = NSTextField.sidebarLine(Self.groupSummary(members: members, isFolded: parent.isGroupFolded))
        label.frame = NSRect(x: textX, y: rowFrame.minY + 1, width: rowFrame.maxX - metrics.cardPaddingX - textX, height: 16)
        label.setAccessibilityElement(false)
        addSubviewDoc(label)
        expandedViews.append(label)
        hitAreas.append(SidebarHitArea(
            frame: rowFrame, region: .link(url: Self.groupToggleActionURL(workspaceIndex: parent.index), label: label)
        ))
        let toggle = SidebarSectionToggleView(frame: rowFrame)
        toggle.toolTip = "\(parent.isGroupFolded ? "Show" : "Hide") the workspaces opened from \(parent.title)"
        toggle.setAccessibilityLabel("Workspaces opened from \(parent.title), \(members.count)")
        toggle.setAccessibilityExpanded(!parent.isGroupFolded)
        let index = parent.index
        toggle.onPress = { [weak self] in self?.toggleGroup(workspaceIndex: index) }
        addSubviewDoc(toggle)
        expandedViews.append(toggle)
        return rowFrame.minY
    }

    /// Keeps the row under the pointer, as `toggleInactiveSection` does.
    func toggleGroup(workspaceIndex: Int) {
        keepingDocumentTop { onWorkspaceAction?(.toggleGroup, workspaceIndex) }
    }

    /// "▾ 3 workspaces"; folded, where they stand, most pressing first:
    /// "▸ 3 · 1 waiting · ✕ 1 · 2 done · 1 working", each count in its
    /// state's color. ✕ counts open pull requests with red checks; done,
    /// children whose Mission completed or whose pull request merged.
    static func groupSummary(members: [WorkspaceInfo], isFolded: Bool) -> NSAttributedString {
        let font = Theme.Font.caption
        func count(_ isCounted: (WorkspaceInfo) -> Bool) -> Int { members.filter(isCounted).count }
        let waiting = count { $0.cardState == .waiting }
        let red = count { $0.prInfo?.state == "OPEN" && $0.prInfo?.ciStatus == "FAILURE" }
        let done = count { $0.isMissionCompleted || $0.prInfo?.state == "MERGED" }
        let working = count { $0.cardState == .working }
        let allCounts: [(count: Int, text: String, color: NSColor)] = [
            (waiting, "\(waiting) waiting", Theme.Color.waiting),
            (red, "✕ \(red)", Theme.Color.error),
            (done, "\(done) done", Theme.Color.done),
            (working, "\(working) working", Theme.Color.working)
        ]
        let counts = isFolded ? allCounts.filter { $0.count > 0 } : []
        // The counts say what they are: the noun would push them out.
        let total = counts.isEmpty ? workspaceCountText(members.count) : "\(members.count)"
        let text = NSMutableAttributedString(
            string: "\(isFolded ? "▸" : "▾") \(total)",
            attributes: [.font: font, .foregroundColor: Theme.Color.textTertiary]
        )
        for (_, countText, color) in counts {
            text.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: Theme.Color.textTertiary]))
            text.append(NSAttributedString(string: countText, attributes: [.font: font, .foregroundColor: color]))
        }
        return text
    }
}
