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
    /// A row that just left the list: where it was, what it looked like,
    /// and where the rows under it were.
    struct Fold {
        let workspaceID: String
        let startedAt: CFTimeInterval
        /// From the top of the list's document to the row's top: the
        /// document's height changes with the list.
        let top: CGFloat
        let frame: NSRect
        let picture: CGImage?
        /// The tasks listed under it, by id, and the checklist card if it
        /// was there: how far from the document's top each one's top was.
        let under: [String: CGFloat]
        let cardTop: CGFloat?
        /// The task listed right above it, and how far from the document's
        /// top its bottom was: the picture stays under it if it grows (the
        /// selection moving there).
        let above: (id: String, bottom: CGFloat)?
        /// The list fitted the sidebar: rows were where the list put them,
        /// whatever the scroll.
        let fitted: Bool
    }

    static let foldGhostID = NSUserInterfaceItemIdentifier("nirux.sidebar.fold")
    static let foldLeaveKey = "leave"
    /// One pull per row, whatever the folds above it: it comes up by its
    /// own way, once.
    static let foldPullKey = "foldPull"
    static let archivedBumpKey = "bump"
    /// The row's picture closing.
    static let foldDuration: CFTimeInterval = 0.36
    /// How long a fold is replayed on a rebuilt list: the rows' spring up
    /// takes longer than the picture.
    static let foldMotionDuration: CFTimeInterval = 1
    static let bumpDuration: CFTimeInterval = 0.5

    /// Another space comes on screen: nothing of the last one's plays on
    /// its rows.
    func forgetRowMoments() {
        readyAt = [:]
        mergedAt = [:]
        folds = []
        archivedBumpAt = nil
        // The checklist card outlives rebuilds: its pull goes now.
        onboardingCardView?.layer?.removeAnimation(forKey: Self.foldPullKey)
    }

    /// Between two refreshes: what changed on the rows that both list.
    /// `previous` and `infos` are the same space's. Called before the rows
    /// are rebuilt, while the old ones can still be pictured. Nothing for
    /// the rail, which shows none of it.
    func noteRowMoments(from previous: [WorkspaceInfo], to infos: [WorkspaceInfo]) {
        let now = clock()
        readyAt = readyAt.filter { now - $0.value < SidebarWorkspaceCardRenderer.readyCheckDuration }
        mergedAt = mergedAt.filter { now - $0.value < SidebarWorkspaceCardRenderer.mergeSweepDuration }
        folds.removeAll { now - $0.startedAt >= Self.foldMotionDuration }
        if let bumped = archivedBumpAt, now - bumped >= Self.bumpDuration { archivedBumpAt = nil }
        guard animates, isExpanded, previous != infos else { return }
        let current = Dictionary(infos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var archived = false
        for old in previous {
            guard let new = current[old.id] else {
                // Closed, or its worktree cleaned up. Not the Lead, whose
                // row sits apart from the tasks.
                if !old.isInactive, !old.isLead { fold(old, at: now) }
                continue
            }
            if !old.isInactive, new.isInactive, fold(old, at: now) { archived = true }
            guard old.prInfo != new.prInfo else { continue }
            if old.prInfo?.state == "OPEN", new.prInfo?.state == "MERGED" { mergedAt[old.id] = now }
            if old.rowSummary.mark == .checksRunning, new.rowSummary.mark == .readyToMerge { readyAt[old.id] = now }
        }
        if archived { archivedBumpAt = now }
    }

    /// The row goes: its picture is kept to fold away, and where the rows
    /// under it were. False when it wasn't listed.
    @discardableResult
    private func fold(_ workspace: WorkspaceInfo, at now: CFTimeInterval) -> Bool {
        guard let frame = hitAreas.first(where: { if case .workspace(workspace.index) = $0.region { true } else { false } })?.frame
        else { return false }
        var picture: CGImage?
        if frame.width > 0, frame.height > 0, let rep = contentDocumentView.bitmapImageRepForCachingDisplay(in: frame) {
            contentDocumentView.cacheDisplay(in: frame, to: rep)
            picture = rep.cgImage
        }
        let height = contentDocumentView.bounds.height
        // By the list as it still is: its tasks, not what is laid out from
        // the sidebar's bottom.
        var under: [String: CGFloat] = [:]
        for area in hitAreas {
            guard case .workspace(let index) = area.region, area.frame.maxY <= frame.minY + 1,
                  let info = lastInfos.first(where: { $0.index == index }), !info.isInactive
            else { continue }
            under[info.id] = height - area.frame.maxY
        }
        let card = onboardingCardView.flatMap { card in card.frame.maxY <= frame.minY + 1 ? height - card.frame.maxY : nil }
        let above = hitAreas.compactMap { area -> (id: String, bottom: CGFloat)? in
            guard case .workspace(let index) = area.region, area.frame.minY >= frame.maxY - 1,
                  let info = lastInfos.first(where: { $0.index == index })
            else { return nil }
            return (info.id, height - area.frame.minY)
        }.max { $0.bottom < $1.bottom }
        folds.append(Fold(
            workspaceID: workspace.id, startedAt: now, top: height - frame.maxY, frame: frame, picture: picture,
            under: under, cardTop: card, above: above, fitted: contentDocumentView.frame.height <= bounds.height + 0.5
        ))
        return true
    }

    /// After a rebuild: the rows that left a moment ago carry on folding,
    /// the rows under them coming up, and the Archived count its bump. Not
    /// while rows may not move, whatever started before.
    func applyMergeMotion() {
        // The checklist card outlives rebuilds: its pull, if any, is
        // given again below.
        onboardingCardView?.layer?.removeAnimation(forKey: Self.foldPullKey)
        guard isExpanded, animates else { return }
        let now = clock()
        let height = contentDocumentView.bounds.height
        // A list taller than the sidebar scrolls: where rows were on screen
        // depended on the scroll, so nothing folds or comes up; the rows
        // just take their places, as they did.
        let fits = contentDocumentView.frame.height <= bounds.height + 0.5
        let live = folds.filter { now - $0.startedAt < Self.foldMotionDuration && $0.fitted && fits }
            .sorted { $0.startedAt < $1.startedAt }
        // Each task that was under a fold comes up from where it was, by
        // its own way (the rows above may have changed too: another one
        // selected grows by its links), from the first fold that moved it:
        // once, however many left.
        let rows = expandedViews
        for area in hitAreas {
            guard case .workspace(let index) = area.region,
                  let info = lastInfos.first(where: { $0.index == index }), !info.isInactive,
                  let fold = live.first(where: { $0.under[info.id] != nil }), let oldTop = fold.under[info.id]
            else { continue }
            let moved = oldTop - (height - area.frame.maxY)
            guard moved > 0.5 else { continue }
            let pull = Self.foldPull(by: moved, at: fold.startedAt)
            let place = area.frame.insetBy(dx: -1, dy: -1)
            for view in rows where place.contains(view.frame) {
                view.wantsLayer = true
                view.layer?.add(pull, forKey: Self.foldPullKey)
            }
        }
        if let card = onboardingCardView, let fold = live.first(where: { $0.cardTop != nil }), let oldTop = fold.cardTop {
            let moved = oldTop - (height - card.frame.maxY)
            if moved > 0.5 {
                card.wantsLayer = true
                card.layer?.add(Self.foldPull(by: moved, at: fold.startedAt), forKey: Self.foldPullKey)
            }
        }
        for fold in live where now - fold.startedAt < Self.foldDuration {
            // Under the row above it, which may have grown since.
            var top = fold.top
            if let above = fold.above, let index = lastInfos.first(where: { $0.id == above.id })?.index,
               let area = hitAreas.first(where: { if case .workspace(index) = $0.region { true } else { false } }) {
                top += (height - area.frame.minY) - above.bottom
            }
            addFoldGhost(for: fold, at: NSRect(
                x: fold.frame.minX, y: height - top - fold.frame.height, width: fold.frame.width, height: fold.frame.height
            ))
        }
        if let archivedBumpAt, now - archivedBumpAt < Self.bumpDuration, let count = archivedCountLabel {
            // A label has no layer of its own until it is asked for one.
            count.wantsLayer = true
            guard let label = count.layer else { return }
            // About its centre: an AppKit view's layer is anchored at its
            // bottom-left corner.
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

    /// From `distance` lower up to its place, from `beginTime`. Added to
    /// whatever else moves the view.
    private static func foldPull(by distance: CGFloat, at beginTime: CFTimeInterval) -> CASpringAnimation {
        let pull = CASpringAnimation(keyPath: "transform.translation.y")
        pull.fromValue = -distance
        pull.toValue = 0
        pull.isAdditive = true
        pull.damping = 26
        pull.stiffness = 240
        pull.duration = pull.settlingDuration
        pull.beginTime = beginTime
        pull.fillMode = .backwards
        return pull
    }

    /// The row's picture, where it was, closing toward its top edge and
    /// fading. On a sublayer of its own: AppKit owns the view's layer and
    /// may redraw it.
    private func addFoldGhost(for fold: Fold, at frame: NSRect) {
        let ghost = SidebarBackgroundView(frame: frame)
        ghost.identifier = Self.foldGhostID
        ghost.wantsLayer = true
        let picture = CALayer()
        picture.frame = ghost.bounds
        picture.contents = fold.picture
        // Gone unless its fold runs.
        picture.opacity = 0
        ghost.layer?.addSublayer(picture)
        addSubviewDoc(ghost)
        expandedViews.append(ghost)
        // About its top edge: the picture's anchor is its centre.
        let close = CABasicAnimation(keyPath: "transform")
        close.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        var closed = CATransform3DMakeTranslation(0, frame.height / 2, 0)
        closed = CATransform3DScale(closed, 1, 0.05, 1)
        closed = CATransform3DTranslate(closed, 0, -frame.height / 2, 0)
        close.toValue = NSValue(caTransform3D: closed)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let leave = CAAnimationGroup()
        leave.animations = [close, fade]
        leave.duration = Self.foldDuration
        leave.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        leave.beginTime = fold.startedAt
        leave.fillMode = .backwards
        picture.add(leave, forKey: Self.foldLeaveKey)
    }
}
