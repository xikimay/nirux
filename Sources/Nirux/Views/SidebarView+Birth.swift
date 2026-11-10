import AppKit

// MARK: - A task's row opens

/// The row of a task that just started opens with a spring, pushing the
/// rows under it down (see `NiruxShellView.playTaskBirth`). The sidebar
/// rebuilds every row on each change, so the motion is timed from the
/// birth: a rebuild in the middle carries on.
extension SidebarView {
    static let birthKey = "birth"
    static let birthPushKey = "birthPush"
    /// How long a birth is replayed on a rebuilt row.
    static let birthDuration: CFTimeInterval = 1.2

    /// A task's workspace just opened: its row opens, if rows may move.
    func noteBirth(workspaceID: String, now: CFTimeInterval = CACurrentMediaTime()) {
        bornAt = bornAt.filter { now - $0.value < Self.birthDuration }
        guard animates else { return }
        bornAt[workspaceID] = now
        lastRenderSignature = nil
        update(profiles: lastProfiles, workspaces: lastInfos)
    }

    /// The workspace's row, or its tile in the collapsed rail, in the
    /// sidebar's coordinates; nil when the sidebar doesn't list it.
    func rowFrame(workspaceID: String) -> NSRect? {
        guard let index = lastInfos.first(where: { $0.id == workspaceID })?.index,
              let area = hitAreas.first(where: { if case .workspace(index) = $0.region { true } else { false } })
        else { return nil }
        return convert(area.frame, from: contentDocumentView)
    }

    /// After a rebuild: the rows born a moment ago carry on opening.
    func applyBirthMotion(now: CFTimeInterval = CACurrentMediaTime()) {
        for (workspaceID, born) in bornAt where now - born < Self.birthDuration {
            guard let index = lastInfos.first(where: { $0.id == workspaceID })?.index,
                  let row = hitAreas.first(where: { if case .workspace(index) = $0.region { true } else { false } })?.frame
            else { continue }
            let opens = born + NiruxShellView.taskBirthRowDelay
            for view in expandedViews {
                guard let layer = view.layer else { continue }
                if row.insetBy(dx: -1, dy: -1).contains(view.frame) {
                    // Unseen until the sheet's picture lands, then in.
                    let appear = CAKeyframeAnimation(keyPath: "opacity")
                    appear.values = [0, 0, 1]
                    appear.keyTimes = [0, 0.4, 1]
                    appear.duration = NiruxShellView.taskBirthRowDelay / 0.4
                    appear.beginTime = born
                    appear.fillMode = .backwards
                    layer.add(appear, forKey: Self.birthKey)
                    layer.add(Self.birthSpring(from: 8, at: opens), forKey: Self.birthKey + ".spring")
                } else if view.frame.maxY <= row.minY + 1 {
                    // The rows under it give way.
                    layer.add(
                        Self.birthSpring(from: row.height + SidebarExpandedMetrics.workspaceGap, at: opens),
                        forKey: Self.birthPushKey
                    )
                }
            }
        }
    }

    /// From `offset` above its place down to it, starting at `beginTime`;
    /// held up there until then.
    private static func birthSpring(from offset: CGFloat, at beginTime: CFTimeInterval) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: "transform.translation.y")
        spring.fromValue = offset
        spring.toValue = 0
        spring.damping = 16
        spring.stiffness = 220
        spring.duration = spring.settlingDuration
        spring.beginTime = beginTime
        spring.fillMode = .backwards
        return spring
    }
}
