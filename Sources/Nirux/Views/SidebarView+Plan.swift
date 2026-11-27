import AppKit

// MARK: - The day plan (docs/design/plan.md)

/// While the space's day plan is on, the Tasks section lists each feature with its lines (its tasks' rows nested
/// under it, its to-dos and Lead lines), then the tasks in no feature as before, then the loose to-dos; the Lead's
/// own lines go under its row. Read-only for now.
extension SidebarView {
    enum PlanRow: Equatable {
        case workspace(WorkspaceInfo)
        case plan(SidebarPlanRowRenderer.Row)
    }

    /// `activeInfos` as rows, and the Lead's lines; without a plan, the rows as they always were.
    func planRows(_ activeInfos: [WorkspaceInfo]) -> (tasks: [PlanRow], lead: [PlanRow]) {
        guard let plan else {
            inFeatureIDs = []
            return (activeInfos.map(PlanRow.workspace), [])
        }
        var families: [String: [WorkspaceInfo]] = [:]
        var order: [String] = []
        for info in activeInfos {
            if info.isNested, let parent = order.last {
                families[parent, default: []].append(info)
            } else {
                order.append(info.id)
                families[info.id] = [info]
            }
        }
        let listing = plan.listing(tasks: order, folded: foldedFeatures)
        inFeatureIDs = Set(listing.entries.compactMap { if case .task(let id, true) = $0 { id } else { nil } })
        let byID = Dictionary(activeInfos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = listing.entries.flatMap { entry -> [PlanRow] in
            switch entry {
            case .feature(let feature, let isFolded):
                let forUser = feature.children.filter { line in
                    line.kind == .todo ? !line.isChecked : line.workspaceID.flatMap { byID[$0] }?.asksUser == true
                }.count
                let waits = feature.children.contains { $0.workspaceID.flatMap { byID[$0] }?.asksUser == true }
                return [.plan(.feature(feature, isFolded: isFolded, forUser: forUser, waits: waits))]
            case .task(let id, let inFeature):
                return (families[id] ?? []).map { info in
                    var info = info
                    info.inFeature = inFeature
                    return .workspace(info)
                }
            case .line(let line, let inFeature):
                return [.plan(.line(line, isNested: inFeature))]
            }
        }
        return (rows, listing.leadLines.map { .plan(.line($0, isNested: false)) })
    }

    func planRowsHeight(_ rows: [PlanRow], width: CGFloat) -> CGFloat {
        rows.reduce(CGFloat(0)) { total, row in
            switch row {
            case .workspace(let info): total + SidebarExpandedMetrics.workspaceHeight(for: info, sidebarWidth: width) + SidebarExpandedMetrics.workspaceGap
            case .plan(let plan): total + SidebarPlanRowRenderer.height(of: plan) + SidebarExpandedMetrics.workspaceGap
            }
        }
    }

    func buildPlanRows(_ rows: [PlanRow], yOffset: CGFloat) -> CGFloat {
        var currentY = yOffset
        for row in rows {
            switch row {
            case .workspace(let info):
                currentY = buildWorkspaceSection(workspace: info, yOffset: currentY)
            case .plan(let plan):
                var renderer = SidebarPlanRowRenderer(row: plan, sidebarWidth: listWidth, top: currentY)
                if case .feature(let feature, _, _, _) = plan { renderer.onFold = { [weak self] in self?.toggleFeature(feature.id) } }
                let built = renderer.render()
                built.views.forEach(addExpandedView)
                hitAreas += built.hitAreas
                currentY = built.bottomY
            }
            currentY -= SidebarExpandedMetrics.workspaceGap
        }
        return currentY
    }
}
