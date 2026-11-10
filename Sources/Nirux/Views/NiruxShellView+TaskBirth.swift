import AppKit

/// The ⌘N sheet as it looked when its task started, and where it was in
/// the shell: what folds toward the task's row.
struct TaskSheetPicture {
    let image: CGImage
    let frame: NSRect
}

// MARK: - A task's birth

/// On Start, once the worktree is ready: the sheet's picture folds toward
/// the sidebar, the task's row opens there with a spring, then the agent's
/// column slides in from the right. Until then the sheet stays up: a start
/// that fails shows its error there. Nothing of this plays while the
/// interface may not move (`agentLightsMayMove`): the sheet closes and the
/// workspace shows as before.
extension NiruxShellView {
    static let taskBirthGhostName = "nirux.taskBirth.ghost"
    static let taskBirthSlideKey = "taskBirthSlide"
    /// When the row opens and the column starts in, after the fold began.
    static let taskBirthRowDelay: CFTimeInterval = 0.2
    static let taskBirthSlideDelay: CFTimeInterval = 0.3

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
        let now = CACurrentMediaTime()
        sidebar.noteBirth(workspaceID: workspace.id, now: now)
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
    /// of what was on screen. The container moves, as column scrolling
    /// does: the terminal's own layer is never transformed.
    func slideInNewWorkspace(_ workspace: WorkspaceState, over snapshot: NSView) {
        viewport.addSubview(snapshot, positioned: .below, relativeTo: verticalStrip)
        if let container = workspace.containerView.layer {
            let slide = CASpringAnimation(keyPath: "transform.translation.x")
            slide.fromValue = viewport.bounds.width
            slide.toValue = 0
            slide.damping = 18
            slide.stiffness = 170
            slide.duration = slide.settlingDuration
            // Held off to the right until the row has opened.
            slide.beginTime = CACurrentMediaTime() + Self.taskBirthSlideDelay
            slide.fillMode = .backwards
            container.add(slide, forKey: Self.taskBirthSlideKey)
        }
        // Not on the animation's completion, which a window out of view
        // may never report.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.taskBirthSlideDelay + 0.9) { [weak snapshot] in
            snapshot?.removeFromSuperview()
        }
    }
}
