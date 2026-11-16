import AppKit

// MARK: - A task's row opens

/// The row of a task that just started opens with a spring, and the tasks
/// under it give way (see `NiruxShellView.playTaskBirth`). The sidebar
/// rebuilds every row on each change, so the motion is timed from the
/// birth: a rebuild in the middle carries on.
extension SidebarView {
    static let birthKey = "birth"
    static let birthSpringKey = "birth.spring"
    /// One push per birth: a row under two tasks born together gives way
    /// to both.
    static func birthPushKey(_ workspaceID: String) -> String { birthPushPrefix + workspaceID }
    private static let birthPushPrefix = "birthPush."
    /// How long a birth is replayed on a rebuilt row, from when it opens.
    static let birthDuration: CFTimeInterval = 1.2

    /// A task's workspace just opened: its row opens after `delay` (the
    /// time the sheet's picture takes to reach it), if rows may move.
    func noteBirth(workspaceID: String, delay: CFTimeInterval = 0) {
        let now = clock()
        rowOpensAt = rowOpensAt.filter { now - $0.value < Self.birthDuration }
        railBirthsPlayed.formIntersection(rowOpensAt.keys)
        guard animates else { return }
        rowOpensAt[workspaceID] = now + delay
        railBirthsPlayed.remove(workspaceID)
        // Not `update`: during a row drag it would put the last list back
        // in place of the one that waits for the drop.
        rebuildContent()
    }

    /// The workspace's row, or its icon on the folded rail, in the
    /// sidebar's coordinates; nil when the sidebar doesn't show it.
    func rowFrame(workspaceID: String) -> NSRect? {
        guard isExpanded else {
            guard !iconRail.isHidden, let icon = iconRail.iconFrame(of: workspaceID) else { return nil }
            return convert(icon, from: iconRail)
        }
        guard let index = lastInfos.first(where: { $0.id == workspaceID })?.index,
              let area = hitAreas.first(where: { if case .workspace(index) = $0.region { true } else { false } })
        else { return nil }
        return convert(area.frame, from: contentDocumentView)
    }

    /// After a rebuild: the rows born a moment ago carry on opening. Not
    /// while rows may not move, whatever started before.
    func applyBirthMotion() {
        guard animates else {
            // The checklist card outlives rebuilds: its push goes now.
            if let card = onboardingCardView?.layer {
                card.animationKeys()?.filter { $0.hasPrefix(Self.birthPushPrefix) }.forEach(card.removeAnimation)
            }
            return
        }
        let now = clock()
        guard isExpanded else {
            // The rail's icons outlive rebuilds: each birth plays once, on
            // the layers' clock.
            let layerNow = CACurrentMediaTime()
            for (workspaceID, opens) in rowOpensAt where now - opens < Self.birthDuration && !railBirthsPlayed.contains(workspaceID) {
                // Not shown yet (an update to come): the next rebuild tries.
                if iconRail.playBirth(of: workspaceID, opens: layerNow + (opens - now)) { railBirthsPlayed.insert(workspaceID) }
            }
            return
        }
        // In the list's own coordinates, as the views' frames are.
        let rows: [(info: WorkspaceInfo, frame: NSRect)] = hitAreas.compactMap { area in
            guard case .workspace(let index) = area.region, let info = lastInfos.first(where: { $0.index == index })
            else { return nil }
            return (info, area.frame)
        }
        // A list taller than the sidebar scrolls: which rows kept their
        // place on screen depends on the scroll, so none is pushed.
        let fits = contentDocumentView.frame.height <= listFrame.height + 0.5
        for (workspaceID, opens) in rowOpensAt where now - opens < Self.birthDuration {
            guard let born = rows.first(where: { $0.info.id == workspaceID }) else { continue }
            let own = born.frame.insetBy(dx: -1, dy: -1)
            let isUnder = { (frame: NSRect) in frame.maxY <= born.frame.minY + 1 }
            // What gives way: what is laid out under it, top down. Not what
            // is laid out from the sidebar's bottom and never moved: the
            // list's Archived block.
            let flowsUnder: (NSView) -> Bool
            if !fits {
                flowsUnder = { _ in false }
            } else {
                let tasks = rows.filter { !$0.info.isInactive && isUnder($0.frame) }.map { $0.frame.insetBy(dx: -1, dy: -1) }
                let card = onboardingCardView
                flowsUnder = { view in tasks.contains { $0.contains(view.frame) } || (view === card && isUnder(view.frame)) }
            }
            let room = born.frame.height + SidebarExpandedMetrics.workspaceGap
            for view in expandedViews + [onboardingCardView].compactMap({ $0 }) {
                if own.contains(view.frame) {
                    view.wantsLayer = true
                    view.layer?.add(Self.birthAppearance(at: opens), forKey: Self.birthKey)
                    view.layer?.add(Self.birthSpring(from: 8, at: opens, damping: 16), forKey: Self.birthSpringKey)
                } else if flowsUnder(view) {
                    view.wantsLayer = true
                    // Barely past its place: a whole list doesn't bounce.
                    view.layer?.add(
                        Self.birthSpring(from: room, at: opens, damping: 26), forKey: Self.birthPushKey(workspaceID)
                    )
                }
            }
        }
    }

    /// Unseen until it opens (when the sheet's picture lands), then in.
    static func birthAppearance(at beginTime: CFTimeInterval) -> CABasicAnimation {
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.duration = 0.25
        appear.beginTime = beginTime
        appear.fillMode = .backwards
        return appear
    }

    /// From `offset` away from its place to it, in its layer's y (up the
    /// screen in the sidebar's list, down it in a flipped view's), starting
    /// at `beginTime`; held there until then. Added to whatever else moves
    /// the view.
    static func birthSpring(
        from offset: CGFloat, at beginTime: CFTimeInterval, damping: CGFloat
    ) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: "transform.translation.y")
        spring.fromValue = offset
        spring.toValue = 0
        spring.isAdditive = true
        spring.damping = damping
        spring.stiffness = 220
        spring.duration = spring.settlingDuration
        spring.beginTime = beginTime
        spring.fillMode = .backwards
        return spring
    }
}
