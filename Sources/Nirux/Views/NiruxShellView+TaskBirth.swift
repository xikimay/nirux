import AppKit

/// The ⌘N sheet as it looked when its task started, and where it was in
/// the shell: what folds toward the task's row.
struct TaskSheetPicture {
    let image: CGImage
    let frame: NSRect
}

// MARK: - A task's birth

/// On Start, once the worktree is ready: the sheet's picture folds toward
/// the sidebar, the task's row opens there with a spring, and the agent's
/// column slides in from the right, as fast as a workspace shows today.
/// Until then the sheet stays up: a start that fails shows its error
/// there. Nothing of this plays while the interface may not move
/// (`agentLightsMayMove`): the sheet closes and the workspace shows as
/// before.
extension NiruxShellView {
    static let taskBirthGhostName = "nirux.taskBirth.ghost"
    static let taskBirthSlideKey = "taskBirthSlide"
    static let taskBirthBackdropKey = "taskBirthBackdrop"
    /// When the row opens, after the fold began: as the picture reaches it.
    static let taskBirthRowDelay: CFTimeInterval = 0.2
    /// The column's way in: a workspace switch's time (`wsSlide`).
    static let taskBirthSlideDuration: CFTimeInterval = 0.3

    /// Before the sheet closes on a task that starts: its picture, for the
    /// fold. None for a sheet the user closed meanwhile.
    func takeTaskSheetPicture(of panel: NewTaskPanel) {
        pendingTaskSheet = nil
        guard agentLightsMayMove, !panel.isHidden, let window, let sheet = panel.panel, let content = sheet.contentView,
              content.bounds.width > 0, content.bounds.height > 0,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let image = rep.cgImage else { return }
        pendingTaskSheet = TaskSheetPicture(image: image, frame: convert(window.convertFromScreen(sheet.frame), from: nil))
    }

    /// The task's workspace just opened, its row is in the sidebar: the
    /// row opens with a spring, and the sheet's picture, if one was taken,
    /// folds toward it.
    func playTaskBirth(of workspace: WorkspaceState) {
        let picture = pendingTaskSheet
        pendingTaskSheet = nil
        guard agentLightsMayMove else { return }
        // Without a sheet (a task its Lead starts) nothing travels to the
        // row: it opens at once.
        sidebar.noteBirth(workspaceID: workspace.id, delay: picture == nil ? 0 : Self.taskBirthRowDelay)
        guard let picture, let shellLayer = layer else { return }
        // Toward the row, or the rail's tile; the top of the sidebar when
        // the row isn't listed.
        let target = sidebar.rowFrame(workspaceID: workspace.id).map { convert($0, from: sidebar) }
            ?? NSRect(x: sidebar.frame.minX, y: sidebar.frame.maxY - 80, width: sidebar.frame.width, height: 40)
        let ghost = CALayer()
        ghost.name = Self.taskBirthGhostName
        ghost.frame = picture.frame
        ghost.contents = picture.image
        ghost.backgroundColor = Theme.Color.base.cgColor
        ghost.cornerRadius = Theme.Radius.panel
        ghost.masksToBounds = true
        ghost.borderWidth = 1
        ghost.borderColor = Theme.Color.lineStrong.cgColor
        // Gone unless its fold runs: a dropped animation leaves nothing.
        ghost.opacity = 0
        shellLayer.addSublayer(ghost)

        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: NSPoint(x: picture.frame.midX, y: picture.frame.midY))
        move.toValue = NSValue(point: NSPoint(x: target.midX, y: target.midY))
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = max(0.15, min(1, target.width / max(picture.frame.width, 1)))
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.35, 1]
        let fold = CAAnimationGroup()
        fold.animations = [move, shrink, fade]
        fold.duration = 0.42
        fold.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.2, 1)
        ghost.add(fold, forKey: "fold")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak ghost] in ghost?.removeFromSuperlayer() }
    }

    /// The new workspace's column slides in from the right, over a picture
    /// of what was on screen that fades away under it: a new task shows
    /// one column, and nothing stale may stay beside it. The container
    /// moves, as column scrolling does: the terminal's own layer is never
    /// transformed.
    func slideInNewWorkspace(_ workspace: WorkspaceState, over snapshot: NSView) {
        let curve = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        viewport.addSubview(snapshot, positioned: .below, relativeTo: verticalStrip)
        // Gone unless its fade runs: a dropped animation leaves nothing.
        snapshot.alphaValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Self.taskBirthSlideDuration
        fade.timingFunction = curve
        snapshot.layer?.add(fade, forKey: Self.taskBirthBackdropKey)
        if let container = workspace.containerView.layer {
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = viewport.bounds.width
            slide.toValue = 0
            slide.duration = Self.taskBirthSlideDuration
            slide.timingFunction = curve
            container.add(slide, forKey: Self.taskBirthSlideKey)
        }
        // Not on an animation's completion, which a window out of view may
        // never report.
        // Long after: the fade starts when this turn of the run loop ends,
        // which may take a while (the birth's rebuilds, saving the state).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak snapshot] in
            snapshot?.removeFromSuperview()
        }
    }
}
