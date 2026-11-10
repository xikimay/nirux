import AppKit

// MARK: - The merge, on a task's row

/// What a row shows of its pull request's way out: the checks' ring gives
/// way to a drawn check when they pass, one sweep of light crosses the row
/// when the pull request is merged, and the row folds away when its task is
/// archived or closed, the Archived count bumping for an archive.
///
/// Each plays once, for a change seen between two refreshes of the same
/// space: a row that was already merged at launch, or in another space,
/// shows none. The sidebar rebuilds every row on each change, so each is
/// timed from its moment and a rebuild in the middle carries on.
extension SidebarView {
    /// A row that just left the list: where it was, what it looked like.
    struct Fold {
        let workspaceID: String
        let startedAt: CFTimeInterval
        /// From the top of the list's document to the row's top: the
        /// document's height changes with the list.
        let top: CGFloat
        let frame: NSRect
        let picture: CGImage?
        /// The tasks that were listed under it: they come up.
        let under: Set<String>
    }

    static let foldGhostID = NSUserInterfaceItemIdentifier("nirux.sidebar.fold")
    static let foldLeaveKey = "leave"
    /// One pull per fold: a row under two tasks that left together comes
    /// up for both.
    static func foldPullKey(_ workspaceID: String) -> String { "foldPull.\(workspaceID)" }
    static let archivedBumpKey = "bump"
    static let foldDuration: CFTimeInterval = 0.45
    static let bumpDuration: CFTimeInterval = 0.5

    /// Between two refreshes: what changed on the rows that both list.
    /// `previous` and `infos` are the same space's. Called before the rows
    /// are rebuilt, while the old ones can still be pictured.
    func noteRowMoments(from previous: [WorkspaceInfo], to infos: [WorkspaceInfo]) {
        let now = clock()
        readyAt = readyAt.filter { now - $0.value < SidebarWorkspaceCardRenderer.readyCheckDuration }
        mergedAt = mergedAt.filter { now - $0.value < SidebarWorkspaceCardRenderer.mergeSweepDuration }
        folds.removeAll { now - $0.startedAt >= Self.foldDuration }
        if let bumped = archivedBumpAt, now - bumped >= Self.bumpDuration { archivedBumpAt = nil }
        guard animates, previous != infos else { return }
        let current = Dictionary(infos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var archived = false
        for old in previous {
            guard let new = current[old.id] else {
                // Closed, or its worktree cleaned up.
                if !old.isInactive { fold(old, at: now) }
                continue
            }
            if !old.isInactive, new.isInactive {
                fold(old, at: now)
                archived = true
            }
            guard old.prInfo != new.prInfo else { continue }
            if old.prInfo?.state == "OPEN", new.prInfo?.state == "MERGED" { mergedAt[old.id] = now }
            if old.rowSummary.mark == .checksRunning, new.rowSummary.mark == .readyToMerge { readyAt[old.id] = now }
        }
        if archived { archivedBumpAt = now }
    }

    /// The row goes: its picture is kept to fold away, and what was under
    /// it comes up.
    private func fold(_ workspace: WorkspaceInfo, at now: CFTimeInterval) {
        guard isExpanded,
              let frame = hitAreas.first(where: { if case .workspace(workspace.index) = $0.region { true } else { false } })?.frame
        else { return }
        var picture: CGImage?
        if frame.width > 0, frame.height > 0, let rep = contentDocumentView.bitmapImageRepForCachingDisplay(in: frame) {
            contentDocumentView.cacheDisplay(in: frame, to: rep)
            picture = rep.cgImage
        }
        // By the list as it still is: the rows of the list, not what is
        // laid out from the sidebar's bottom.
        let under = hitAreas.compactMap { area -> String? in
            guard case .workspace(let index) = area.region, area.frame.maxY <= frame.minY + 1,
                  let info = lastInfos.first(where: { $0.index == index }), !info.isInactive
            else { return nil }
            return info.id
        }
        folds.append(Fold(
            workspaceID: workspace.id, startedAt: now, top: contentDocumentView.bounds.height - frame.maxY, frame: frame,
            picture: picture, under: Set(under)
        ))
    }

    /// After a rebuild: the rows that left a moment ago carry on folding,
    /// and the Archived count its bump. Not while rows may not move,
    /// whatever started before.
    func applyMergeMotion() {
        guard isExpanded, animates else { return }
        let now = clock()
        // A list taller than the sidebar scrolls: which rows kept their
        // place on screen depends on the scroll, so none is pulled.
        let fits = contentDocumentView.frame.height <= bounds.height + 0.5
        for fold in folds where now - fold.startedAt < Self.foldDuration {
            let gone = NSRect(
                x: fold.frame.minX, y: contentDocumentView.bounds.height - fold.top - fold.frame.height,
                width: fold.frame.width, height: fold.frame.height
            )
            // The tasks that were under it come up into its room, where
            // they are listed now. (Before the ghost joins the views.)
            let risen = !fits ? [] : hitAreas.compactMap { area -> NSRect? in
                guard case .workspace(let index) = area.region,
                      lastInfos.contains(where: { $0.index == index && !$0.isInactive && fold.under.contains($0.id) })
                else { return nil }
                return area.frame.insetBy(dx: -1, dy: -1)
            }
            let pull = CASpringAnimation(keyPath: "transform.translation.y")
            pull.fromValue = -(gone.height + SidebarExpandedMetrics.workspaceGap)
            pull.toValue = 0
            pull.isAdditive = true
            pull.damping = 18
            pull.stiffness = 240
            pull.duration = pull.settlingDuration
            pull.beginTime = fold.startedAt
            pull.fillMode = .backwards
            for view in expandedViews where risen.contains(where: { $0.contains(view.frame) }) {
                view.wantsLayer = true
                view.layer?.add(pull, forKey: Self.foldPullKey(fold.workspaceID))
            }

            // The row's picture closes toward its top edge and fades.
            let ghost = SidebarBackgroundView(frame: gone)
            ghost.identifier = Self.foldGhostID
            ghost.wantsLayer = true
            ghost.layer?.contents = fold.picture
            // Gone unless its fold runs.
            ghost.alphaValue = 0
            addSubviewDoc(ghost)
            expandedViews.append(ghost)
            // About its top edge: an AppKit view's layer is anchored at its
            // bottom-left corner.
            var closed = CATransform3DMakeTranslation(0, gone.height, 0)
            closed = CATransform3DScale(closed, 1, 0.05, 1)
            closed = CATransform3DTranslate(closed, 0, -gone.height, 0)
            let close = CABasicAnimation(keyPath: "transform")
            close.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            close.toValue = NSValue(caTransform3D: closed)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let leave = CAAnimationGroup()
            leave.animations = [close, fade]
            leave.duration = Self.foldDuration * 0.8
            leave.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            leave.beginTime = fold.startedAt
            leave.fillMode = .backwards
            ghost.layer?.add(leave, forKey: Self.foldLeaveKey)
        }
        if let archivedBumpAt, now - archivedBumpAt < Self.bumpDuration, let count = archivedCountLabel {
            // A label has no layer of its own until it is asked for one.
            count.wantsLayer = true
            guard let label = count.layer else { return }
            // About its centre, for the same reason.
            let centre = CGPoint(x: label.bounds.midX, y: label.bounds.midY)
            let scaled = { (scale: CGFloat) -> NSValue in
                var transform = CATransform3DMakeTranslation(centre.x, centre.y, 0)
                transform = CATransform3DScale(transform, scale, scale, 1)
                return NSValue(caTransform3D: CATransform3DTranslate(transform, -centre.x, -centre.y, 0))
            }
            let bump = CAKeyframeAnimation(keyPath: "transform")
            bump.values = [scaled(1), scaled(1.45), scaled(1)]
            bump.keyTimes = [0, 0.4, 1]
            bump.duration = Self.bumpDuration
            bump.beginTime = archivedBumpAt
            bump.fillMode = .backwards
            label.add(bump, forKey: Self.archivedBumpKey)
        }
    }
}
