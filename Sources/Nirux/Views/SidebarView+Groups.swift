import AppKit

// MARK: - Groups (docs/sidebar-groups.md)

extension SidebarView {
    /// Some workspace is listed under it.
    func hasGroup(_ workspace: WorkspaceInfo) -> Bool {
        lastInfos.contains { $0.groupParentID == workspace.id }
    }

    /// Its children, each followed by its own, listed or folded.
    func groupMembers(of workspace: WorkspaceInfo) -> [WorkspaceInfo] {
        lastInfos.filter { $0.groupParentID == workspace.id }.flatMap { [$0] + groupMembers(of: $0) }
    }

    /// The summary rows under the workspaces of `infos` that have children.
    func groupTogglesHeight(_ infos: [WorkspaceInfo]) -> CGFloat {
        CGFloat(infos.filter(hasGroup).count) * (SidebarExpandedMetrics.groupToggleHeight + SidebarExpandedMetrics.workspaceGap)
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
        let label = NSTextField.sidebarLine(Self.groupSummary(members: groupMembers(of: parent), isFolded: parent.isGroupFolded))
        label.frame = NSRect(x: textX, y: rowFrame.minY + 1, width: rowFrame.maxX - metrics.cardPaddingX - textX, height: 16)
        label.setAccessibilityElement(false)
        addSubviewDoc(label)
        expandedViews.append(label)
        hitAreas.append(SidebarHitArea(
            frame: rowFrame, region: .link(url: Self.groupToggleActionURL(workspaceIndex: parent.index), label: label)
        ))
        let toggle = SidebarSectionToggleView(frame: rowFrame)
        toggle.toolTip = "\(parent.isGroupFolded ? "Show" : "Hide") the workspaces opened from \(parent.title)"
        toggle.setAccessibilityLabel("Workspaces opened from \(parent.title): \(label.stringValue.dropFirst(2))")
        toggle.setAccessibilityExpanded(!parent.isGroupFolded)
        let index = parent.index
        toggle.onPress = { [weak self] in self?.onWorkspaceAction?(.toggleGroup, index) }
        addSubviewDoc(toggle)
        expandedViews.append(toggle)
        return rowFrame.minY
    }

    /// "▾ 3 workspaces"; folded, where they stand, most pressing first:
    /// "▸ 3 · 1 waiting · ✕ 1 · 2 done · 1 working", each count in its
    /// state's color. ✕ counts open pull requests with red checks; done,
    /// children whose Mission completed or whose pull request merged.
    static func groupSummary(members: [WorkspaceInfo], isFolded: Bool) -> NSAttributedString {
        let font = Theme.Font.caption
        func count(_ isCounted: (WorkspaceInfo) -> Bool) -> Int { isFolded ? members.filter(isCounted).count : 0 }
        let allCounts: [(word: String, count: Int, color: NSColor)] = [
            ("waiting", count { $0.cardState == .waiting }, Theme.Color.waiting),
            ("✕", count { $0.prInfo?.state == "OPEN" && $0.prInfo?.ciStatus == "FAILURE" }, Theme.Color.error),
            ("done", count { $0.isMissionCompleted || $0.prInfo?.state == "MERGED" }, Theme.Color.done),
            ("working", count { $0.cardState == .working }, Theme.Color.working)
        ]
        let counts = allCounts.filter { $0.count > 0 }
        // The counts say what they are: the noun would push them out.
        let total = counts.isEmpty ? workspaceCountText(members.count) : "\(members.count)"
        let text = NSMutableAttributedString(
            string: "\(isFolded ? "▸" : "▾") \(total)",
            attributes: [.font: font, .foregroundColor: Theme.Color.textTertiary]
        )
        for (word, count, color) in counts {
            text.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: Theme.Color.textTertiary]))
            text.append(NSAttributedString(
                string: word == "✕" ? "✕ \(count)" : "\(count) \(word)",
                attributes: [.font: font, .foregroundColor: color]
            ))
        }
        return text
    }
}
