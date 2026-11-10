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
    static func birthPushKey(_ workspaceID: String) -> String { birthPushPrefix }
    private static let birthPushPrefix = "birthPush."
    /// How long a birth is replayed on a rebuilt row, from when it opens.
    static let birthDuration: CFTimeInterval = 1.2

    /// A task's workspace just opened: its row opens after `delay` (the
    /// time the sheet's picture takes to reach it), if rows may move.
    func noteBirth(workspaceID: String, delay: CFTimeInterval = 0) {
        let now = clock()
        rowOpensAt = rowOpensAt.filter { now - $0.value < Self.birthDuration }
        guard animates else { return }
        rowOpensAt[workspaceID] = now
        // Not `update`: during a row drag it would put the last list back
        // in place of the one that waits for the drop.
        rebuildContent()
    }

    /// The workspace's row, or its tile in the collapsed rail, in the
    /// sidebar's coordinates; nil when the sidebar doesn't list it.
    func rowFrame(workspaceID: String) -> NSRect? {
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
        // In the list's own coordinates, as the views' frames are.
        let rows: [(info: WorkspaceInfo, frame: NSRect)] = hitAreas.compactMap { area in
            guard case .workspace(let index) = area.region, let info = lastInfos.first(where: { $0.index == index })
            else { return nil }
            return (info, area.frame)
        }
        // A list taller than the sidebar scrolls: which rows kept their
        // place on screen depends on the scroll, so none is pushed.
        let fits = contentDocumentView.frame.height <= bounds.height + 0.5
        for (workspaceID, opens) in rowOpensAt where now - opens < Self.birthDuration {
            guard let born = rows.first(where: { $0.info.id == workspaceID }) else { continue }
            let own = born.frame.insetBy(dx: -1, dy: -1)
            let isUnder = { (frame: NSRect) in frame.maxY <= born.frame.minY + 1 }
            // What gives way: what is laid out under it, top down. Not what
            // is laid out from the sidebar's bottom and never moved: the
            // list's Archived block, the rail's "+".
            let flowsUnder: (NSView) -> Bool
            if false {
                flowsUnder = { _ in false }
            } else if isExpanded {
                let tasks = rows.filter { isUnder($0.frame) }.map { $0.frame.insetBy(dx: -1, dy: -1) }
                let card = onboardingCardView
                flowsUnder = { view in tasks.contains { $0.contains(view.frame) } || (view === card && isUnder(view.frame)) }
            } else {
                // The rail: the tiles, the separator, the archived ones.
                let add = hitAreas.first { area in
                    if case .railButton(.newWorkspace) = area.region { return true }
                    return false
                }?.frame.insetBy(dx: -1, dy: -1)
                flowsUnder = { view in isUnder(view.frame) && add != nil }
            }
            // (A rail tile's area holds its gap.)
            let room = born.frame.height
            for view in expandedViews + [onboardingCardView].compactMap({ $0 }) {
                if own.contains(view.frame) {
                    // Unseen until it opens (when the sheet's picture
                    // lands), then in.
                    let appear = CABasicAnimation(keyPath: "opacity")
                    appear.fromValue = 0
                    appear.toValue = 1
                    appear.duration = 0.25
                    appear.beginTime = opens
                    appear.fillMode = .backwards
                    view.wantsLayer = true
                    view.layer?.add(appear, forKey: Self.birthKey)
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

    /// From `offset` above its place down to it, starting at `beginTime`;
    /// held up there until then. Added to whatever else moves the view.
    private static func birthSpring(
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
