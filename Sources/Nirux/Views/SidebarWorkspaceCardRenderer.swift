import AppKit

struct SidebarWorkspaceCardRenderResult {
    let bottomY: CGFloat
    let views: [NSView]
    let hitAreas: [SidebarHitArea]
    /// Initially-clear overlay covering the row — SidebarView tints it
    /// while the pointer is anywhere over the row.
    let cardHoverView: NSView
    /// The "⋯" action badge — brightens while directly hovered.
    let menuBadge: SidebarBadgeView?
    /// Initially-clear backing view per column chip (keyed by column index)
    /// for the chip hover highlight.
    let columnHoverViews: [Int: NSView]
    /// Allow / Deny and Resume buttons, keyed like `SidebarHoverTarget`'s
    /// button keys.
    let approvalButtons: [String: SidebarBadgeView]
}

/// No border: the selected row is tinted, the others light under the
/// pointer. An archived row that asks nothing is one line.
@MainActor
final class SidebarWorkspaceCardRenderer {
    typealias Metrics = SidebarExpandedMetrics

    private let layout: SidebarCardLayout
    private let yOffset: CGFloat
    /// The row moves (see `SidebarView.animates`): a line of light runs
    /// under it while its agent works, and its mark draws a check when a
    /// turn ends.
    private let animates: Bool
    /// When the row's agent ended its turn (`CACurrentMediaTime`), while
    /// its check may still be drawing (see `SidebarView.turnEndNotedAt`).
    private let turnEndedAt: CFTimeInterval?
    /// When the row's pull request became ready to merge, and when it was
    /// merged, while the row still shows it (see SidebarView+Merge).
    private let readyAt: CFTimeInterval?
    private let mergedAt: CFTimeInterval?
    /// The clock the row's movements are timed from (`CACurrentMediaTime`).
    private let now: CFTimeInterval

    private var views: [NSView] = []
    private var hitAreas: [SidebarHitArea] = []
    private var menuBadge: SidebarBadgeView?
    private var columnHoverViews: [Int: NSView] = [:]
    private var approvalButtons: [String: SidebarBadgeView] = [:]

    private var workspace: WorkspaceInfo { layout.workspace }

    init(
        workspace: WorkspaceInfo, sidebarWidth: CGFloat, yOffset: CGFloat, animates: Bool = true,
        turnEndedAt: CFTimeInterval? = nil, readyAt: CFTimeInterval? = nil, mergedAt: CFTimeInterval? = nil,
        now: CFTimeInterval = CACurrentMediaTime()
    ) {
        layout = SidebarCardLayout(workspace: workspace, sidebarWidth: sidebarWidth)
        self.yOffset = yOffset
        self.animates = animates
        self.turnEndedAt = turnEndedAt
        self.readyAt = readyAt
        self.mergedAt = mergedAt
        self.now = now
    }

    func render() -> SidebarWorkspaceCardRenderResult {
        let frame = NSRect(
            x: layout.cardX, y: yOffset - layout.height, width: layout.cardWidth, height: layout.height
        )
        if workspace.isActive { append(Self.selectionGlass(frame: frame)) }
        let cardHover = SidebarBackgroundView(frame: frame)
        cardHover.wantsLayer = true
        cardHover.layer?.cornerRadius = layout.isCompact ? Theme.Radius.control : Theme.Radius.card
        append(cardHover)
        if layout.isCompact {
            buildCompactRow(frame: frame)
        } else if workspace.isLead {
            buildLeadRow(frame: frame)
        } else {
            buildRow(frame: frame)
        }
        if animates, layout.summary.mark == .working { buildWorkingLine(frame: frame) }
        buildMergeSweep(frame: frame)
        // Last: the first area under the pointer takes the click.
        hitAreas.append(SidebarHitArea(frame: frame, region: .workspace(workspace.index)))

        return SidebarWorkspaceCardRenderResult(
            bottomY: frame.minY,
            views: views,
            hitAreas: hitAreas,
            cardHoverView: cardHover,
            menuBadge: menuBadge,
            columnHoverViews: columnHoverViews,
            approvalButtons: approvalButtons
        )
    }

    // MARK: - Row

    private func buildRow(frame: NSRect) {
        var top = frame.maxY - Metrics.rowPaddingY
        buildTitleRow(top: top)
        top -= Metrics.titleRowHeight + Metrics.statusGap
        if let goal = layout.goal {
            let label = textLabel(goal, font: Theme.Font.body, color: Theme.Color.textSecondary)
            label.frame = NSRect(x: layout.indentX, y: top - Metrics.statusRowHeight,
                                 width: max(0, layout.contentMaxX - layout.indentX), height: Metrics.statusRowHeight)
            label.toolTip = goal
            append(label)
            top -= Metrics.statusRowHeight
        }
        buildStep(top: top)
        if layout.statusBelowStep { top -= Metrics.statusRowHeight }
        let statusLink = buildStatusLine(top: top)
        top -= CGFloat(layout.statusLineCount) * Metrics.statusRowHeight
        let lineCount = max(layout.chipRows.count, layout.links.isEmpty ? 0 : 1)
        var chipAreas: [SidebarHitArea] = []
        if lineCount > 0 { top -= Metrics.columnsGap }
        for line in 0..<lineCount {
            if line == 0 { buildLinks(top: top) }
            if line < layout.chipRows.count {
                chipAreas += buildChips(layout.chipRows[line], top: top)
            }
            top -= Metrics.chipHeight + (line < lineCount - 1 ? Metrics.chipGap : 0)
        }
        buildActionBlock(top: top)
        hitAreas += chipAreas
        if let statusLink { hitAreas.append(statusLink) }
    }

    private func buildTitleRow(top: CGFloat) {
        let rowY = top - Metrics.titleRowHeight
        let mark = buildMark(layout.summary.mark, centerY: rowY + Metrics.titleRowHeight / 2)
        // A task's full row (see `showsTurnEnds`), when its mark is the
        // grey dot.
        // A turn's end on a task's full row (see `showsTurnEnds`), over its
        // grey dot, or over the ring of the checks its push started.
        if let mark, Self.drawsTurnEnd(over: layout.summary.mark) {
            buildCheck(over: mark, startedAt: turnEndedAt, holds: true)
        }

        var maxX = layout.contentMaxX
        if let trailing = trailingLabel() {
            trailing.frame = NSRect(
                x: maxX - trailing.fittingSize.width, y: rowY,
                width: trailing.fittingSize.width, height: Metrics.titleRowHeight
            )
            append(trailing)
            maxX = trailing.frame.minX - Theme.Space.sm
        }
        if let usage = usageLabel() {
            let width = usage.fittingSize.width
            usage.frame = NSRect(x: maxX - width, y: rowY, width: width, height: Metrics.titleRowHeight)
            append(usage)
            maxX = usage.frame.minX - Theme.Space.sm
        }
        let badge = menuButton(frame: NSRect(
            x: maxX - Metrics.menuButtonWidth, y: rowY + (Metrics.titleRowHeight - Metrics.menuButtonHeight) / 2,
            width: Metrics.menuButtonWidth, height: Metrics.menuButtonHeight
        ))

        let title = textLabel(workspace.title, font: Theme.Font.title, color: Theme.Color.textPrimary)
        title.toolTip = titleToolTip()
        if let subtask = workspace.subtaskText { title.setAccessibilityLabel("\(workspace.title), \(subtask)") }
        title.frame = NSRect(
            x: layout.indentX, y: rowY,
            width: max(0, badge.frame.minX - Theme.Space.sm - layout.indentX), height: Metrics.titleRowHeight + 1
        )
        append(title)
    }

    /// The time since the last activity (how long it has waited, or sat),
    /// how long the turn has run, or the pull request a "Ready to merge" or
    /// "Merged" line doesn't name. `trailing` overrides the summary's.
    private func trailingLabel(_ trailing: SidebarRowSummary.Trailing? = nil) -> NSTextField? {
        var shown = trailing ?? layout.summary.trailing
        // The task step names the pull request.
        if case .pullRequest? = shown, !layout.isCompact && !workspace.isLead { shown = Self.age(of: workspace) }
        guard let shown else { return nil }
        let label = textLabel(shown.text, font: Theme.Font.caption, color: Theme.Color.textTertiary)
        label.alignment = .right
        let description: String?
        switch shown {
        case .pullRequest:
            description = workspace.prInfo.map(SidebarRenderer.pullRequestToolTip)
        case .turn(let text):
            description = "This turn has run \(text)"
        case .age(let text):
            description = text == "now" ? "Last activity less than a minute ago" : "Last activity \(text) ago"
        }
        label.toolTip = description
        label.setAccessibilityLabel(description)
        return label
    }

    /// "142k · 4.2M": the context of its latest session, then what the task
    /// spent over the week; a warning once the context is worth compacting
    /// or the session reached the subagents' soft cap.
    private func usageLabel() -> NSTextField? {
        guard let usage = workspace.usage else { return nil }
        let label = textLabel(
            usage.isWarning ? usage.text.asWarning : usage.text, font: Theme.Font.captionDigits,
            color: usage.isWarning ? .niruxWarning : Theme.Color.textTertiary
        )
        label.alignment = .right
        let toolTip = usage.toolTip(now: Date().timeIntervalSince1970)
        label.toolTip = toolTip
        label.setAccessibilityLabel("Token usage: " + toolTip.replacingOccurrences(of: "\n", with: ", "))
        return label
    }

    private static func age(of workspace: WorkspaceInfo) -> SidebarRowSummary.Trailing? {
        workspace.lastActivityAt.map { .age(SidebarView.cardAge(since: $0)) }
    }

    /// The title's tooltip: what the row may not print — the task it is a
    /// sub-task of, the branch, the changes, the phase, the purpose, the
    /// last summary, the blocker and the next step, whole.
    private func titleToolTip() -> String {
        var lines = [workspace.title]
        for agent in workspace.columns.compactMap(\.agentLabel) { lines.append("Agent: \(agent)") }
        if let subtask = workspace.subtaskText { lines.append(subtask) }
        if let branch = workspace.gitBranch { lines.append("Branch: \(branch)") }
        if let stats = workspace.diffStats { lines.append("Changes: \(SidebarRenderer.formatDiffStats(stats))") }
        lines.append("Phase: \(workspace.phase.displayName)")
        if let purpose = workspace.purpose { lines.append("Purpose: \(purpose)") }
        if let summary = workspace.lastSummary, summary != layout.summary.status.text { lines.append("Last: \(summary)") }
        if let blocker = workspace.blockerText { lines.append("Blocker: \(blocker)") }
        if let next = workspace.nextStepText { lines.append("Next: \(next)") }
        if workspace.columns.contains(where: { $0.isEditor && $0.editorIsDirty }) { lines.append("Unsaved changes in the editor") }
        if workspace.lastActivityAt == nil { lines.append("No activity yet") }
        return lines.joined(separator: "\n")
    }

    /// The row's state as the glass interface's state icon (`StateIcon`,
    /// as on the rail, the command bar and the inbox): a wait's amber disc
    /// with its reason, from the column that waits; a failure's "!"; work's
    /// ring with its station; a finished turn's grey check; checks passed,
    /// merged, blocked, asking its parent. The ring of checks that run
    /// (the family's dashed ring) turns while rows may move. Returns the
    /// icon a turn's end draws its check over (the grey ring, the grey
    /// check, the ring of checks).
    @discardableResult
    private func buildMark(_ mark: SidebarRowMark, centerY: CGFloat) -> NSView? {
        let center = NSPoint(x: Metrics.markCenterX + layout.nestIndent, y: centerY)
        if mark == .checksRunning { return buildChecksRing(center: center) }
        // Only the row's own mark waits for the user: a compact row's is
        // merged or grey. The status line says it to VoiceOver.
        let icon = mark == .needsYou ? workspace.stateIcon(summary: layout.summary) : StateIcon(mark: mark, station: workspace.station)
        let host = Self.stateIconView(icon, size: Metrics.stateIconSize, center: center)
        append(host)
        // Drawn once, when the checks pass in front of the user.
        if mark == .readyToMerge { buildCheck(over: host, startedAt: readyAt, holds: false) }
        return Self.drawsTurnEnd(over: mark) ? host : nil
    }

    /// A state icon centred on `center`, in a host that takes no click (as
    /// the dot didn't) and has a layer of its own: a check drawn over it
    /// fades it meanwhile. The rows, the Lead's row and the catch-up card.
    static func stateIconView(_ icon: StateIcon, size: CGFloat, center: NSPoint) -> SidebarBackgroundView {
        let host = SidebarBackgroundView(frame: NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
        host.wantsLayer = true
        let view = StateIconView(icon, size: size)
        view.frame = host.bounds
        view.setAccessibilityElement(false)
        host.addSubview(view)
        return host
    }

    /// The selected row's pane of glass (the glass interface, 3.4): a
    /// translucent fill, a light rim, and the light on its top edge, at
    /// every transparency level, Opaque included.
    static let selectionGlassID = NSUserInterfaceItemIdentifier("nirux.sidebar.selection")
    static func selectionGlass(frame: NSRect) -> NSView {
        let pane = SidebarBackgroundView(frame: frame)
        pane.identifier = selectionGlassID
        pane.wantsLayer = true
        let radius = Theme.Radius.card
        pane.layer?.cornerRadius = radius
        pane.layer?.backgroundColor = Theme.Color.selectionGlass.cgColor
        pane.layer?.borderWidth = 1
        pane.layer?.borderColor = Theme.Color.line.cgColor
        let light = CALayer()
        // The layer's y goes up: its top edge, inside the rounded corners.
        light.frame = CGRect(x: radius, y: frame.height - 2, width: max(0, frame.width - 2 * radius), height: 1)
        light.backgroundColor = Theme.Color.lineStrong.cgColor
        pane.layer?.addSublayer(light)
        return pane
    }

    /// Whether a turn's end can show on this workspace's row: a task's
    /// full row. An archived task's compact row stays quiet, and the
    /// Lead's row has no grey dot.
    static func showsTurnEnds(_ workspace: WorkspaceInfo) -> Bool {
        !workspace.isLead && !workspace.showsCompactRow
    }

    /// The marks a turn's end draws its check over: the grey dot, the grey
    /// check of a finished turn, and the ring of checks that run (an agent
    /// that pushed, then stopped).
    static func drawsTurnEnd(over mark: SidebarRowMark) -> Bool {
        mark == .idle || mark == .finished || mark == .checksRunning
    }

    /// The rail's working badge breathes, in phase with every other one
    /// and with the columns' lights: a rebuild doesn't restart it. Only
    /// where `SidebarView.animates` allows it (Reduce motion, the setting,
    /// a window nobody sees). A row shows work as a line of light instead
    /// (`buildWorkingLine`).
    static func breathe(_ layer: CALayer?) {
        layer?.add(CABasicAnimation.lightMovement(for: .working), forKey: "breathe")
    }

    // MARK: - Motion

    static let workingLineID = NSUserInterfaceItemIdentifier("nirux.sidebar.workingLine")
    static let turnEndCheckID = NSUserInterfaceItemIdentifier("nirux.sidebar.turnEndCheck")
    static let checksRingID = NSUserInterfaceItemIdentifier("nirux.sidebar.checksRing")
    static let mergeSweepID = NSUserInterfaceItemIdentifier("nirux.sidebar.mergeSweep")
    static let workingLineKey = "run"
    static let checkDrawKey = "draw"
    static let checksRingKey = "turn"
    static let mergeSweepKey = "sweep"
    /// How long the merge's sweep takes to cross its row.
    static let mergeSweepDuration: CFTimeInterval = 1.0
    /// The check drawn when a pull request's checks pass.
    static let readyCheckDuration: CFTimeInterval = 0.6
    /// How long a turn's end shows on its row: the check draws, holds,
    /// then gives way to the grey dot.
    static let checkDuration: CFTimeInterval = 1.6
    /// One pass of a working row's line.
    static let workingLineDuration: CFTimeInterval = 3

    /// A thin line of light running along the row's bottom edge while its
    /// agent works. Timed from the clock, not from when the row was built:
    /// every row's line runs in step, and a rebuilt row's carries on
    /// exactly where the old one was.
    private func buildWorkingLine(frame: NSRect) {
        let inset = Theme.Radius.card
        let line = SidebarBackgroundView(frame: NSRect(
            x: frame.minX + inset, y: frame.minY + 1, width: max(0, frame.width - inset * 2), height: 2
        ))
        line.identifier = Self.workingLineID
        line.wantsLayer = true
        line.layer?.masksToBounds = true
        line.layer?.cornerRadius = 1
        let width = line.frame.width
        let bandWidth = width * 0.3
        let green = Theme.Color.working
        let band = CAGradientLayer()
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.colors = ([0, 0.9, 0] as [CGFloat]).map { green.withAlphaComponent($0).cgColor }
        // Rests out of sight: a run that never starts shows nothing.
        band.frame = CGRect(x: -bandWidth, y: 0, width: bandWidth, height: line.frame.height)
        line.layer?.addSublayer(band)
        let run = CABasicAnimation(keyPath: "position.x")
        run.fromValue = -bandWidth / 2
        run.toValue = width + bandWidth / 2
        run.duration = Self.workingLineDuration
        run.repeatCount = .infinity
        // Began when the clock's current pass did.
        run.beginTime = now - now.truncatingRemainder(dividingBy: run.duration)
        // Under the same cap as every light (`CABasicAnimation.lightMovement`):
        // a working row asks for no more frames than the dots ever did,
        // and its pass is slow enough to stay smooth at that rate.
        run.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 15)
        band.add(run, forKey: Self.workingLineKey)
        append(line)
    }

    /// One turn of the ring that says a pull request's checks run.
    static let checksRingDuration: CFTimeInterval = 1.6

    /// The pull request's checks run: a grey ring turns where the row's
    /// mark is, in step with every other one. A still dashed ring while
    /// rows may not move, and for an archived task, whose pull request
    /// isn't read again: nothing turns there for ever.
    private func buildChecksRing(center: NSPoint) -> NSView {
        let size = Metrics.stateIconSize
        let icon = StateIcon(.waiting, stage: StateIcon.stage(of: workspace.station))
        guard animates, !workspace.isInactive else {
            // Still: the family's own dashed ring.
            let still = Self.stateIconView(icon, size: size, center: center)
            still.identifier = Self.checksRingID
            append(still)
            return still
        }
        // One arc of the family's ring going round, its station inside.
        let host = SidebarBackgroundView(frame: NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
        host.identifier = Self.checksRingID
        host.wantsLayer = true
        let ring = icon.ringLayer(side: size)
        ring.lineCap = .round
        ring.strokeEnd = 0.37
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = Self.checksRingDuration
        turn.repeatCount = .infinity
        // Began when the clock's current turn did: a rebuilt row's
        // ring carries on exactly where the old one was.
        turn.beginTime = now - now.truncatingRemainder(dividingBy: turn.duration)
        // Endless, so under the lights' cap
        // (`CABasicAnimation.lightMovement`), and slow enough to stay
        // smooth at that rate.
        turn.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 15)
        ring.add(turn, forKey: Self.checksRingKey)
        host.layer?.addSublayer(ring)
        if let pie = icon.pieLayer(side: size) { host.layer?.addSublayer(pie) }
        append(host)
        return host
    }

    /// At the merge, one sweep of light crosses the row. Timed from the
    /// moment the pull request was seen merged: a rebuild in the middle
    /// carries on, and once it is over nothing is built.
    private func buildMergeSweep(frame: NSRect) {
        guard animates, let mergedAt, now - mergedAt < Self.mergeSweepDuration else { return }
        let host = SidebarBackgroundView(frame: frame)
        host.identifier = Self.mergeSweepID
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        host.layer?.cornerRadius = Theme.Radius.card
        let width = frame.width * 0.5
        let green = Theme.Color.working
        let band = CAGradientLayer()
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.colors = ([0, 0.24, 0] as [CGFloat]).map { green.withAlphaComponent($0).cgColor }
        // Rests out of sight: a sweep that never runs shows nothing.
        band.frame = CGRect(x: -width, y: 0, width: width, height: frame.height)
        host.layer?.addSublayer(band)
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -width / 2
        sweep.toValue = frame.width + width / 2
        sweep.duration = Self.mergeSweepDuration
        sweep.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        sweep.beginTime = mergedAt
        sweep.fillMode = .backwards
        band.add(sweep, forKey: Self.mergeSweepKey)
        append(host)
    }

    /// A green check is stroked where the row's mark is. At a turn's end
    /// (`holds`) it stays about a second, then gives way to the grey dot;
    /// when a pull request becomes ready, it gives way at once to the
    /// check the row keeps. Timed from `startedAt`, so a rebuild in the
    /// middle carries on; once it is over the mark alone is built.
    private func buildCheck(over dot: NSView, startedAt: CFTimeInterval?, holds: Bool) {
        let duration = holds ? Self.checkDuration : Self.readyCheckDuration
        guard animates, let turnEndedAt = startedAt, now - turnEndedAt < duration else { return }
        let size: CGFloat = 12
        let host = SidebarBackgroundView(frame: NSRect(
            x: dot.frame.midX - size / 2, y: dot.frame.midY - size / 2, width: size, height: size
        ))
        host.identifier = Self.turnEndCheckID
        host.wantsLayer = true
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 2.25, y: 5.6))
        path.addLine(to: CGPoint(x: 4.65, y: 3.2))
        path.addLine(to: CGPoint(x: 9.75, y: 8.4))
        let check = CAShapeLayer()
        check.frame = host.bounds
        check.path = path
        check.fillColor = nil
        check.strokeColor = Theme.Color.working.cgColor
        check.lineWidth = 1.6
        check.lineCap = .round
        check.lineJoin = .round
        // Gone once its time is over, whether or not the animations ran.
        check.opacity = 0
        host.layer?.addSublayer(check)

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.45
        draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        let show = CAKeyframeAnimation(keyPath: "opacity")
        show.values = [1, 1, 0]
        show.keyTimes = [0, 0.75, 1]
        show.duration = duration
        // The mark waits for the check to leave.
        let wait = CAKeyframeAnimation(keyPath: "opacity")
        wait.values = [0, 0, 1]
        wait.keyTimes = [0, 0.75, 1]
        wait.duration = duration
        for animation in [draw, show, wait] as [CAAnimation] {
            animation.beginTime = turnEndedAt
            animation.fillMode = .backwards
        }
        check.add(draw, forKey: Self.checkDrawKey)
        check.add(show, forKey: "show")
        dot.layer?.add(wait, forKey: "wait")
        append(host)
    }

    private func buildStep(top: CGFloat) {
        let color: NSColor = switch layout.step {
        case .merged: Theme.Color.done
        case .ready: Theme.Color.success
        default: layout.summary.mark == .error ? Theme.Color.error : Theme.Color.textSecondary
        }
        let badge = SidebarBadgeView(text: layout.stepTitle, textColor: color, fillColor: color.withAlphaComponent(0.12),
                                    font: Theme.Font.captionEmphasized)
        badge.frame = NSRect(x: layout.indentX, y: top - Metrics.statusRowHeight, width: layout.stepWidth, height: Metrics.statusRowHeight)
        badge.setAccessibilityElement(true)
        badge.setAccessibilityRole(.staticText)
        badge.setAccessibilityLabel(layout.stepTitle)
        append(badge)
    }

    // MARK: - Status line

    /// "Needs you · npm run migrate" in amber, "Stopped on an API error"
    /// in red, "Working", "Asking web-main", "#39 · checks passed", "Ready
    /// to merge", "Merged · Clean up", else the branch. It wraps, up to
    /// the lines the layout gives it (`SidebarRowSummary.statusLineLimit`),
    /// then ends on "…". A line that does something (the Mission question
    /// popover, the pull request, Clean up) is a link as wide as its text.
    private func buildStatusLine(top: CGFloat) -> SidebarHitArea? {
        let status = layout.summary.status
        let text = layout.statusText
        guard text.length > 0 else { return nil }
        let label = layout.statusLineLimit > 1
            ? SidebarWrappedText.label(text, lineHeight: Metrics.statusRowHeight, maxLines: layout.statusLineLimit)
            : NSTextField.sidebarLine(text)
        let x = layout.indentX + (layout.statusBelowStep ? 0 : layout.stepWidth + Theme.Space.xs)
        let height = CGFloat(layout.statusLineCount) * Metrics.statusRowHeight
        label.frame = NSRect(x: x, y: top - height, width: max(0, layout.contentMaxX - x), height: height)
        label.toolTip = statusToolTip(status)
        // The grey check says it on screen.
        if layout.summary.mark == .finished { label.setAccessibilityLabel("Done: \(status.text)") }
        if let question = shownQuestion(status) { Self.describe(label, question: question) }
        append(label)
        guard let action = status.action else { return nil }
        let url: String
        switch action {
        case .missionQuestion(let columnIndex):
            url = SidebarView.missionQuestionActionURL(workspaceIndex: workspace.index, columnIndex: columnIndex)
        case .cleanUp:
            url = SidebarView.cleanupActionURL(workspaceIndex: workspace.index)
        case let .resume(columnIndex, columnID):
            url = SidebarView.resumeActionURL(workspaceIndex: workspace.index, columnIndex: columnIndex, columnID: columnID)
        }
        // Several lines: all of them.
        guard layout.statusLineCount == 1 else {
            return SidebarHitArea(frame: label.frame.insetBy(dx: -2, dy: -2), region: .link(url: url, label: label))
        }
        // Over the link's words only ("Clean up"), else the whole text.
        let full = ceil(label.attributedStringValue.size().width)
        var start: CGFloat = 0
        let printed = text.string
        if let link = status.linkText, printed.hasSuffix(link) {
            let prefix = label.attributedStringValue.attributedSubstring(
                from: NSRange(location: 0, length: (printed as NSString).length - (link as NSString).length)
            )
            start = floor(prefix.size().width)
        }
        let width = min(label.frame.width, full + 4) - start
        guard width > 0 else { return nil }
        return SidebarHitArea(
            frame: NSRect(x: label.frame.minX - 2 + start, y: label.frame.minY - 2, width: width + 2, height: label.frame.height + 4),
            region: .link(url: url, label: label)
        )
    }

    /// The status line as the row prints it (`SidebarRowSummary.lineText`).
    static func statusText(_ summary: SidebarRowSummary, shown: String) -> NSAttributedString {
        let status = summary.status
        let font = status.tone == .branch ? Theme.Font.mono : Theme.Font.body
        let color: NSColor = switch status.tone {
        case .needsYou: Theme.Color.waiting
        case .error: Theme.Color.error
        case .neutral, .branch: Theme.Color.textSecondary
        }
        let text = NSMutableAttributedString(string: shown, attributes: [.font: font, .foregroundColor: color])
        if let link = status.linkText, shown.hasSuffix(link) {
            text.addAttribute(
                .foregroundColor, value: Theme.Color.accent,
                range: NSRange(location: (shown as NSString).length - (link as NSString).length, length: (link as NSString).length)
            )
        }
        return text
    }

    /// The Mission question the status line shows, asked or answered.
    private func shownQuestion(_ status: SidebarStatusLine) -> SidebarMissionQuestion? {
        if case .missionQuestion(let columnIndex)? = status.action {
            return workspace.columns.first { $0.index == columnIndex }?.missionQuestion
        }
        return layout.summary.mark == .asking ? WorkspaceInfo.questionColumn(in: workspace.columns)?.missionQuestion : nil
    }

    /// What the line can't hold: the pull request, what Clean up does,
    /// what the agent waits on. A Mission question's: `describe`.
    private func statusToolTip(_ status: SidebarStatusLine) -> String {
        switch status.action {
        case .missionQuestion?:
            return status.text
        case .resume?:
            let agent = workspace.columns.lazy.compactMap(\.deferredAgent).first
            return agent?.tooltip ?? status.text
        case .cleanUp?:
            return "Clean Up Worktree…: checks, then asks before deleting this worktree’s folder and "
                + "local branch and closing the workspaces open in it. The remote branch is kept."
        case nil:
            let asking = workspace.columns.first { $0.attention == .waiting } ?? workspace.columns.first { $0.attention == .error }
            return [status.text, status.detail ?? asking?.attentionToolTip].compactMap { $0 }.joined(separator: "\n")
        }
    }

    /// The pull request's links, right-aligned on the first chip line.
    private func buildLinks(top: CGFloat) {
        let rowY = top - Metrics.chipHeight
        var x = layout.contentMaxX - layout.links.reduce(CGFloat(0)) { $0 + $1.width }
            - SidebarCardLayout.linkGaps(layout.links)
        for link in layout.links {
            let label = NSTextField.sidebarLine(link.text, lineBreakMode: .byClipping)
            let height = ceil(label.fittingSize.height)
            label.frame = NSRect(x: x - 2, y: rowY + (Metrics.chipHeight - height) / 2, width: link.width + 4, height: height)
            label.toolTip = link.toolTip
            append(label)
            hitAreas.append(SidebarHitArea(
                frame: NSRect(x: x - 2, y: rowY, width: link.width + 4, height: Metrics.chipHeight),
                region: .link(url: link.url, label: label)
            ))
            x += link.width + Theme.Space.xs
        }
    }

    private func buildChips(_ row: [SidebarCardLayout.ChipPlacement], top: CGFloat) -> [SidebarHitArea] {
        let rowY = top - Metrics.chipHeight
        var areas: [SidebarHitArea] = []
        let maxWidth = layout.contentMaxX - layout.indentX
        for placement in row {
            let chip = placement.chip
            let frame = NSRect(
                x: layout.indentX + placement.x, y: rowY,
                width: min(chip.width, maxWidth - placement.x), height: Metrics.chipHeight
            )
            let background = SidebarBackgroundView(frame: frame)
            background.wantsLayer = true
            background.layer?.cornerRadius = Theme.Radius.chip
            background.layer?.backgroundColor = chip.fillColor.cgColor
            append(background)
            // Initially clear, tinted by SidebarView while the pointer is
            // over this chip.
            let hover = SidebarBackgroundView(frame: frame)
            hover.wantsLayer = true
            hover.layer?.cornerRadius = Theme.Radius.chip
            append(hover)
            columnHoverViews[chip.column.index] = hover

            let label = NSTextField.sidebarLine(chip.text, lineBreakMode: .byClipping)
            let height = ceil(label.fittingSize.height)
            label.frame = NSRect(
                x: frame.minX + Metrics.chipPaddingX - 2, y: rowY + (Metrics.chipHeight - height) / 2,
                width: max(0, frame.width - Metrics.chipPaddingX * 2) + 4, height: height
            )
            label.toolTip = chip.toolTip
            label.setAccessibilityLabel(chip.accessibilityLabel)
            append(label)
            if let deferred = chip.column.deferredAgent {
                areas += buildResumeChip(deferred, columnIndex: chip.column.index, frame: frame)
                continue
            }
            // A focused column that waits or broke keeps a sign of focus.
            if chip.column.isFocused, [.waiting, .error].contains(chip.style) {
                background.layer?.borderWidth = 1
                background.layer?.borderColor = Theme.Color.accent.withAlphaComponent(0.6).cgColor
            }
            areas.append(SidebarHitArea(
                frame: frame.insetBy(dx: -Metrics.chipGap / 2, dy: -2),
                region: .column(workspaceIndex: workspace.index, columnIndex: chip.column.index)
            ))
        }
        return areas
    }

    /// A restored agent that hasn't resumed: "Resume" starts it here,
    /// armed and hovered like Allow / Deny; its icon focuses the column, as
    /// the row did around the button.
    private func buildResumeChip(_ deferred: SidebarDeferredAgent, columnIndex: Int, frame: NSRect) -> [SidebarHitArea] {
        let iconWidth = Metrics.chipPaddingX + 12 + Theme.Space.xs / 2
        let (icon, resume) = frame.divided(atDistance: iconWidth, from: .minXEdge)
        let button = SidebarBadgeView(text: "", textColor: .clear, fillColor: .clear, font: Theme.Font.caption)
        button.frame = resume
        button.cornerRadius = Theme.Radius.chip
        button.hoverFillColor = Theme.Color.accent.withAlphaComponent(0.14)
        button.toolTip = deferred.tooltip
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel("Resume \(deferred.agent.rawValue) here")
        views.last?.setAccessibilityElement(false)
        append(button)
        approvalButtons[SidebarHoverTarget.deferredResumeButtonKey(columnID: deferred.columnID)] = button
        return [
            SidebarHitArea(
                frame: NSRect(x: resume.minX, y: resume.minY - 2, width: resume.width + Metrics.chipGap / 2, height: resume.height + 4),
                region: .deferredAgentResume(workspaceIndex: workspace.index, columnIndex: columnIndex, columnID: deferred.columnID)
            ),
            SidebarHitArea(
                frame: NSRect(x: icon.minX - Metrics.chipGap / 2, y: icon.minY - 2, width: icon.width + Metrics.chipGap / 2, height: icon.height + 4),
                region: .column(workspaceIndex: workspace.index, columnIndex: columnIndex)
            )
        ]
    }

    // MARK: - Action block

    /// Approvals, Resume, a question, Clean up, then what's next: under
    /// line 3, after a separator unless it only says something.
    private func buildActionBlock(top: CGFloat) {
        let actions = layout.actions
        guard !actions.isEmpty else { return }
        var top = top
        if actions.allSatisfy(\.isQuiet) {
            top -= Metrics.quietBlockGap
        } else {
            top -= Metrics.actionBlockGap
            let separator = SidebarBackgroundView(frame: NSRect(
                x: layout.contentX, y: top - 1, width: layout.contentMaxX - layout.contentX, height: 1
            ))
            separator.wantsLayer = true
            separator.layer?.backgroundColor = Theme.Color.line.cgColor
            append(separator)
            top -= 1 + Metrics.actionBlockGap
        }
        for (position, action) in actions.enumerated() {
            if position > 0 { top -= Metrics.actionRowGap }
            buildAction(action, top: top)
            top -= Metrics.height(
                of: action, width: layout.contentMaxX - layout.contentX, textWidth: layout.contentMaxX - layout.indentX
            )
        }
    }

    private func buildAction(_ action: SidebarCardAction, top: CGFloat) {
        let x = layout.contentX
        let width = layout.contentMaxX - layout.contentX
        switch action {
        case let .approval(columnIndex, agent, approval):
            add(SidebarApprovalBlockRenderer(
                approval: approval, agent: agent, workspaceIndex: workspace.index, columnIndex: columnIndex,
                x: x, width: width, top: top
            ).render())
        case let .resume(columnIndex, kind, detail, failedAt, resume):
            add(SidebarResumeBlockRenderer(
                kind: kind, detail: detail, failedAt: failedAt, resume: resume,
                workspaceIndex: workspace.index, columnIndex: columnIndex, x: x, width: width, top: top
            ).render())
        case let .interrupt(columnIndex, since):
            add(SidebarInterruptBlockRenderer(
                since: since, workspaceIndex: workspace.index, columnIndex: columnIndex, x: x, width: width, top: top
            ).render())
        case let .contextOffer(columnIndex, offer):
            add(SidebarContextOfferBlockRenderer(
                offer: offer, workspaceIndex: workspace.index, columnIndex: columnIndex, x: x, width: width, top: top
            ).render())
        case let .turnQuestion(columnIndex, question):
            add(SidebarTurnQuestionBlockRenderer(
                question: question, workspaceIndex: workspace.index, columnIndex: columnIndex, x: x, width: width, top: top
            ).render())
        case let .missionRecommendation(columnIndex, question):
            add(SidebarMissionRecommendationBlockRenderer(
                question: question, workspaceIndex: workspace.index, columnIndex: columnIndex, x: x, width: width, top: top
            ).render())
        case let .dialog(columnIndex, dialog):
            add(SidebarDialogBlockRenderer(
                dialog: dialog, workspaceIndex: workspace.index, columnIndex: columnIndex, x: x, width: width, top: top
            ).render())
        case .reviewBadges(let badges):
            let indent = layout.indentX
            let prefix = textLabel("Reviews", font: Theme.Font.caption, color: Theme.Color.textTertiary)
            prefix.frame = NSRect(x: indent, y: top - Metrics.actionLineHeight, width: prefix.fittingSize.width, height: Metrics.actionLineHeight)
            append(prefix)
            let badgesX = prefix.frame.maxX + Theme.Space.sm
            append(SidebarReviewBadgesRow.label(
                badges, x: badgesX, width: layout.contentMaxX - badgesX, top: top
            ))
        case let .cleanup(offer, number):
            buildCleanup(offer, pullRequest: number, top: top)
        case let .missionQuestion(columnIndex, question):
            let label = wrappedActionLine(Self.missionQuestionText(question), maxLines: Metrics.missionQuestionMaxLines, top: top)
            append(label)
            Self.describe(label, question: question)
            guard !question.isAnswered else { return }
            hitAreas.append(SidebarHitArea(
                frame: label.frame.insetBy(dx: -2, dy: -2),
                region: .link(
                    url: SidebarView.missionQuestionActionURL(workspaceIndex: workspace.index, columnIndex: columnIndex),
                    label: label
                )
            ))
        case .next(let text):
            let label = wrappedActionLine(Self.nextText(text), maxLines: Metrics.nextStepMaxLines, top: top)
            label.toolTip = "Next: \(text)"
            append(label)
        case .leadRecovery(let issue):
            let label = NSTextField.sidebarLine(Self.actionText(issue.title, link: issue.action))
            label.toolTip = issue.title + " · " + issue.action
            label.setAccessibilityLabel(label.toolTip)
            label.frame = NSRect(x: layout.indentX, y: top - Metrics.actionLineHeight,
                                 width: layout.contentMaxX - layout.indentX, height: Metrics.actionLineHeight)
            append(label)
            hitAreas.append(SidebarHitArea(frame: label.frame, region: .link(
                url: SidebarView.leadRecoveryURL(issue, workspaceID: workspace.id), label: label
            )))
        case .ruleProposals(let count):
            let label = NSTextField.sidebarLine(Self.actionText(Self.ruleProposalsTitle(count: count), link: "Review"))
            label.toolTip = "The Lead proposes \(count == 1 ? "a rule" : "\(count) rules") for the space brief, from a "
                + "defect it found twice. Review: add, edit or dismiss \(count == 1 ? "it" : "them"). Nothing reaches the brief "
                + "without you."
            label.setAccessibilityLabel(Self.ruleProposalsTitle(count: count) + ", review")
            label.frame = NSRect(
                x: layout.indentX, y: top - Metrics.actionLineHeight,
                width: layout.contentMaxX - layout.indentX, height: Metrics.actionLineHeight
            )
            append(label)
            hitAreas.append(SidebarHitArea(
                frame: label.frame.insetBy(dx: -2, dy: -2),
                region: .link(url: SidebarView.ruleProposalsActionURL(spaceID: workspace.profileID), label: label)
            ))
        case .dailyPass(let note):
            let label = NSTextField.sidebarLine(NSAttributedString(string: note, attributes: [
                .font: Theme.Font.caption, .foregroundColor: Theme.Color.textSecondary
            ]))
            label.toolTip = "What the Lead's daily pass read of the space's day. Its reply in its terminal says what it proposes, "
                + "and why."
            label.frame = NSRect(
                x: layout.indentX, y: top - Metrics.actionLineHeight,
                width: layout.contentMaxX - layout.indentX, height: Metrics.actionLineHeight
            )
            append(label)
        case .heldMessages(let held):
            let label = NSTextField.sidebarLine(NSAttributedString(string: held.line, attributes: [
                .font: Theme.Font.caption, .foregroundColor: Theme.Color.textSecondary
            ]))
            label.toolTip = held.tooltip
            label.frame = NSRect(
                x: layout.indentX, y: top - Metrics.actionLineHeight,
                width: layout.contentMaxX - layout.indentX, height: Metrics.actionLineHeight
            )
            append(label)
        case let .waitingMessages(columnIndex, waiting):
            let label = wrappedActionLine(Self.waitingText(waiting), maxLines: Metrics.waitingMessagesMaxLines, top: top)
            label.toolTip = waiting.tooltip
            label.setAccessibilityLabel(waiting.line)
            append(label)
            // First, and only over the line: the button's area reaches into it.
            hitAreas.append(SidebarHitArea(
                frame: label.frame.insetBy(dx: -2, dy: waiting.offersTypeNow ? 0 : -2),
                region: .column(workspaceIndex: workspace.index, columnIndex: columnIndex)
            ))
            if waiting.offersTypeNow { buildTypeNow(waiting, columnIndex: columnIndex, top: label.frame.minY) }
        }
    }

    /// Under a row of waiting messages: "If its prompt is empty", then
    /// Type it now at the trailing edge, a button as Interrupt is.
    private func buildTypeNow(_ waiting: SidebarWaitingMessages, columnIndex: Int, top: CGFloat) {
        let button = SidebarActionButton.secondary(
            "Type it now", symbol: Theme.Symbol.typeNow, label: "Type it now: type one waiting message into claude"
        )
        button.toolTip = SidebarWaitingMessages.typeNowAdvice
        let x = layout.indentX
        add(SidebarButtonRow.render(
            button,
            key: SidebarHoverTarget.typeNowButtonKey(workspaceIndex: workspace.index, columnIndex: columnIndex, since: waiting.since),
            region: .missionTypeNow(workspaceIndex: workspace.index, columnIndex: columnIndex, since: waiting.since),
            workspaceIndex: workspace.index, x: x, width: layout.contentMaxX - x, top: top
        ) { y, width in
            let hint = NSTextField(labelWithString: "If its prompt is empty")
            hint.font = Theme.Font.caption
            hint.textColor = Theme.Color.textSecondary
            hint.lineBreakMode = .byTruncatingTail
            hint.toolTip = SidebarWaitingMessages.typeNowAdvice
            hint.frame = NSRect(x: x, y: y - 1, width: max(0, width), height: Metrics.actionLineHeight + 2)
            return hint
        })
    }

    /// A line of the action block that wraps, under the title: as tall as
    /// `SidebarExpandedMetrics.height(of:width:textWidth:)` counts it.
    private func wrappedActionLine(_ text: NSAttributedString, maxLines: Int, top: CGFloat) -> NSTextField {
        let width = layout.contentMaxX - layout.indentX
        let height = SidebarWrappedText.height(text, width: width, lineHeight: Metrics.actionLineHeight, maxLines: maxLines)
        let label = SidebarWrappedText.label(text, lineHeight: Metrics.actionLineHeight, maxLines: maxLines)
        label.frame = NSRect(x: layout.indentX, y: top - height, width: width, height: height)
        return label
    }

    /// "Rule proposed", "2 rules proposed".
    static func ruleProposalsTitle(count: Int) -> String {
        count == 1 ? "Rule proposed" : "\(count) rules proposed"
    }

    /// "Rule proposed · Review": grey, the link in the accent.
    private static func actionText(_ title: String, link: String) -> NSAttributedString {
        let font = Theme.Font.caption
        let result = NSMutableAttributedString(string: title + " · ", attributes: [
            .font: font, .foregroundColor: Theme.Color.textSecondary
        ])
        result.append(NSAttributedString(string: link, attributes: [.font: font, .foregroundColor: Theme.Color.accent]))
        return result
    }

    /// "Asking web-main · <question>" in grey while the parent may answer,
    /// "Needs you · <question>" in amber once it waits on the user.
    static func missionQuestionText(_ question: SidebarMissionQuestion) -> NSAttributedString {
        let font = Theme.Font.caption
        guard !question.isAnswered else {
            return NSAttributedString(string: answeredText(question), attributes: [
                .font: font, .foregroundColor: Theme.Color.textSecondary
            ])
        }
        guard question.handOff == nil else {
            return NSAttributedString(string: question.needsYouLine, attributes: [
                .font: font, .foregroundColor: Theme.Color.waiting
            ])
        }
        let result = NSMutableAttributedString(string: "Asking \(question.parentTitle)", attributes: [
            .font: font, .foregroundColor: Theme.Color.textSecondary
        ])
        if let text = AgentText.clean(question.text, maxLength: 300) {
            result.append(NSAttributedString(string: " · \(text)", attributes: [
                .font: font, .foregroundColor: Theme.Color.textTertiary
            ]))
        }
        return result
    }

    /// The meaning first: a long parent title is what the line cuts.
    static func answeredText(_ question: SidebarMissionQuestion) -> String {
        question.parentTitle == "you" ? "Your answer is ready" : "Answer ready · from \(question.parentTitle)"
    }

    /// A Mission question's tooltip and VoiceOver label, on the status line
    /// or its own line: the whole question (or answer) and what happens.
    static func describe(_ label: NSTextField, question: SidebarMissionQuestion) {
        if question.isAnswered {
            label.toolTip = "Answer from \(question.parentTitle): \(question.text)\n\nNirux types it into this agent’s "
                + "prompt once its turn is over and nothing is typed there. A Claude started since it asked "
                + "takes it after one prompt from you."
            label.setAccessibilityLabel("Answer from \(question.parentTitle) waiting: \(question.text)")
        } else {
            label.toolTip = ([question.text] + [question.recommendationLine, "\(question.explanation) Click to answer."].compactMap { $0 })
                .joined(separator: "\n\n")
            label.setAccessibilityLabel(
                question.handOff == nil ? "Asking \(question.parentTitle): \(question.text)" : "Needs you, a question: \(question.text)"
            )
        }
    }

    static func waitingText(_ waiting: SidebarWaitingMessages) -> NSAttributedString {
        NSAttributedString(string: waiting.line, attributes: [.font: Theme.Font.caption, .foregroundColor: Theme.Color.textSecondary])
    }

    static func nextText(_ text: String) -> NSAttributedString {
        let font = Theme.Font.caption
        let result = NSMutableAttributedString(string: "Next", attributes: [
            .font: font, .foregroundColor: Theme.Color.textTertiary
        ])
        result.append(SidebarColumnChip.spacer(6))
        result.append(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: Theme.Color.textSecondary
        ]))
        return result
    }

    /// "PR merged", then "Clean up": the ⋯ menu's "Clean Up Worktree…",
    /// with the same checks and confirmation. "Cleaning up…" while one
    /// runs, which does nothing.
    private func buildCleanup(_ offer: MergedCleanupOffer, pullRequest number: Int, top: CGFloat) {
        let rowY = top - Metrics.actionLineHeight
        let merged = textLabel("PR merged", font: Theme.Font.caption, color: Theme.Color.done)
        merged.toolTip = "Pull request #\(number) merged"
        merged.frame = NSRect(x: layout.indentX, y: rowY, width: merged.fittingSize.width, height: Metrics.actionLineHeight)
        append(merged)
        let link: NSTextField
        switch offer {
        case .available:
            link = textLabel("Clean up", font: Theme.Font.caption, color: Theme.Color.accent)
            link.toolTip = "Clean Up Worktree…: checks, then asks before deleting this worktree’s folder and "
                + "local branch and closing the workspaces open in it. The remote branch is kept."
        case .inProgress:
            link = textLabel("Cleaning up…", font: Theme.Font.caption, color: Theme.Color.textTertiary)
        }
        let width = link.fittingSize.width
        link.alignment = .right
        link.frame = NSRect(x: layout.contentMaxX - width, y: rowY, width: width, height: Metrics.actionLineHeight)
        append(link)
        guard offer == .available else { return }
        hitAreas.append(SidebarHitArea(
            frame: link.frame.insetBy(dx: -2, dy: -2),
            region: .link(url: SidebarView.cleanupActionURL(workspaceIndex: workspace.index), label: link)
        ))
    }

    private func add(_ block: SidebarApprovalBlockRenderer.Result) {
        views += block.views
        hitAreas += block.hitAreas
        approvalButtons.merge(block.buttons) { _, new in new }
    }

    // MARK: - Lead row

    /// The space's Lead (docs/design/spaces.md, "The Lead"): its sign, its title,
    /// and its state icon, small, while it works, needs you or broke; then
    /// the action block, as any row.
    private func buildLeadRow(frame: NSRect) {
        let rowY = frame.maxY - Metrics.leadRowHeight
        let midY = rowY + Metrics.leadRowHeight / 2
        let icon = SidebarImageView(image: SidebarRenderer.symbol(Theme.Symbol.lead, color: Theme.Color.accent, pointSize: 13))
        icon.frame = NSRect(x: (Metrics.markCenterX + layout.nestIndent) - 8, y: midY - 8, width: 16, height: 16)
        icon.setAccessibilityElement(false)
        append(icon)

        var maxX = layout.contentMaxX
        if [.working, .needsYou, .error].contains(layout.summary.mark) {
            let size = Metrics.leadStateIconSize
            let host = Self.stateIconView(
                workspace.stateIcon(summary: layout.summary), size: size, center: NSPoint(x: maxX - size / 2, y: midY)
            )
            append(host)
            maxX = host.frame.minX - Theme.Space.sm
        }
        if let usage = usageLabel() {
            let size = usage.fittingSize
            usage.frame = NSRect(x: maxX - size.width, y: midY - ceil(size.height) / 2, width: size.width, height: ceil(size.height))
            append(usage)
            maxX = usage.frame.minX - Theme.Space.sm
        }
        let badge = menuButton(frame: NSRect(
            x: maxX - Metrics.menuButtonWidth, y: midY - Metrics.menuButtonHeight / 2,
            width: Metrics.menuButtonWidth, height: Metrics.menuButtonHeight
        ))

        let title = textLabel(workspace.title, font: Theme.Font.title, color: Theme.Color.textPrimary)
        // Its words only: the row has no link to press ("Paused", not
        // "Paused · Resume": selecting the row resumes it).
        var status = layout.summary.status.text
        if let link = layout.summary.status.linkText, status.hasSuffix(" · \(link)") {
            status = String(status.dropLast(" · \(link)".count))
        }
        title.toolTip = "\(workspace.title)\n\(status)"
        title.setAccessibilityLabel("\(workspace.title), \(status)")
        let height = ceil(title.fittingSize.height)
        title.frame = NSRect(
            x: layout.indentX, y: midY - height / 2,
            width: max(0, badge.frame.minX - Theme.Space.sm - layout.indentX), height: height
        )
        append(title)
        buildActionBlock(top: rowY)
    }

    // MARK: - Compact row

    /// An archived workspace: its state, its title, its merged PR or age.
    private func buildCompactRow(frame: NSRect) {
        let midY = frame.midY
        buildMark(layout.state == .done ? .merged : .idle, centerY: midY)

        var maxX = layout.contentMaxX
        let trailing: NSTextField?
        if layout.state == .done, let number = workspace.prInfo?.number {
            trailing = trailingLabel(.pullRequest(number))
        } else {
            trailing = trailingLabel(Self.age(of: workspace))
        }
        if let trailing {
            let width = trailing.fittingSize.width
            let height = ceil(trailing.fittingSize.height)
            trailing.frame = NSRect(x: maxX - width, y: midY - height / 2, width: width, height: height)
            append(trailing)
            maxX = trailing.frame.minX - Theme.Space.sm
        }
        let badge = menuButton(frame: NSRect(
            x: maxX - Metrics.menuButtonWidth, y: midY - Metrics.menuButtonHeight / 2,
            width: Metrics.menuButtonWidth, height: Metrics.menuButtonHeight
        ))

        let titleX = layout.indentX
        let title = textLabel(workspace.title, font: Theme.Font.body, color: Theme.Color.textSecondary)
        title.toolTip = titleToolTip()
        let height = ceil(title.fittingSize.height)
        title.frame = NSRect(x: titleX, y: midY - height / 2, width: max(0, badge.frame.minX - Theme.Space.sm - titleX), height: height)
        append(title)
    }

    // MARK: - Pieces

    /// "⋯": the workspace menu, shown while the pointer is over the row; it
    /// answers clicks either way.
    private func menuButton(frame: NSRect) -> SidebarBadgeView {
        let badge = SidebarBadgeView(text: "", textColor: Theme.Color.textSecondary, fillColor: .clear, font: Theme.Font.caption)
        badge.frame = frame
        badge.symbolName = Theme.Symbol.more
        badge.hoverTextColor = Theme.Color.textPrimary
        badge.hoverFillColor = Theme.Color.fillPressed
        badge.hidesUntilHover = true
        badge.toolTip = "Workspace actions"
        badge.setAccessibilityElement(true)
        badge.setAccessibilityRole(.button)
        badge.setAccessibilityLabel("Workspace actions")
        menuBadge = badge
        append(badge)
        hitAreas.append(SidebarHitArea(frame: frame.insetBy(dx: -4, dy: -2), region: .workspaceMenu(workspace.index)))
        return badge
    }

    private func textLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func append(_ view: NSView) {
        views.append(view)
    }
}

/// An image drawn in its frame, aspect kept; clicks go through to the
/// sidebar's hit areas.
final class SidebarImageView: NSView {
    let image: NSImage?

    init(image: NSImage?) {
        self.image = image
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height, 1)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height))
    }
}

/// The action block's buttons: drawn, but in `NiruxButton`'s looks and
/// small size (the glass interface, 3.4), so that a row, the inbox and the
/// callout show the same buttons.
@MainActor
enum SidebarActionButton {
    /// Allow: the one action the block recommends.
    static func primary(_ title: String, label: String) -> SidebarBadgeView {
        configured(looking(.primary, title), label: label)
    }

    static func secondary(_ title: String, symbol: String? = nil, label: String) -> SidebarBadgeView {
        let button = looking(.secondary, title)
        button.symbolName = symbol
        return configured(button, label: label)
    }

    /// Dismiss: a grey word without a frame, lit under the pointer.
    static func quiet(_ title: String, label: String) -> SidebarBadgeView {
        configured(looking(.quiet, title), label: label)
    }

    /// A drawn button in `kind`'s look, at rest and under the pointer.
    private static func looking(_ kind: NiruxButton.Kind, _ title: String) -> SidebarBadgeView {
        let rest = NiruxButton.look(kind, hovered: false, pressed: false, enabled: true)
        let hover = NiruxButton.look(kind, hovered: true, pressed: false, enabled: true)
        let button = SidebarBadgeView(text: title, textColor: rest.text, fillColor: rest.fill, font: NiruxButton.Size.small.font)
        button.borderColor = rest.border
        button.hoverFillColor = hover.fill
        button.hoverTextColor = hover.text
        return button
    }

    private static func configured(_ button: SidebarBadgeView, label: String) -> SidebarBadgeView {
        // A capsule, as `NiruxButton`.
        button.cornerRadius = SidebarExpandedMetrics.buttonHeight / 2
        button.toolTip = label
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(label)
        return button
    }
}
