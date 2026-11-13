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

/// A task row (`SidebarCardLayout`): the state mark, the title and the time,
/// then the status line; the selected row's columns; then the action block.
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
        if workspace.isActive {
            let selected = SidebarBackgroundView(frame: frame)
            selected.wantsLayer = true
            selected.layer?.cornerRadius = Theme.Radius.card
            selected.layer?.backgroundColor = Theme.Color.fillSelected.cgColor
            append(selected)
        }
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
        // The selected row's links name the pull request already.
        if case .pullRequest? = shown, !layout.links.isEmpty { shown = Self.age(of: workspace) }
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

    private static func age(of workspace: WorkspaceInfo) -> SidebarRowSummary.Trailing? {
        workspace.lastActivityAt.map { .age(SidebarView.cardAge(since: $0)) }
    }

    /// The title's tooltip: what the row may not print — the task it is a
    /// sub-task of, the branch, the changes, the phase, the purpose, the
    /// last summary, the blocker and the next step, whole.
    private func titleToolTip() -> String {
        var lines = [workspace.title]
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

    /// The sign in the state marks' column: amber for the user, red for
    /// something broken, a green dot for work, a speech bubble for a
    /// question to the parent, a slashed circle for a blocker, a check,
    /// the merge sign, a grey check for a finished turn, else grey. Returns
    /// the dot, or the grey check, which a turn's end draws over.
    @discardableResult
    private func buildMark(_ mark: SidebarRowMark, centerY: CGFloat) -> NSView? {
        let centerX = (Metrics.markCenterX + layout.nestIndent)
        // The status line says it to VoiceOver.
        func symbol(_ name: String, _ color: NSColor, _ label: String?) -> NSView? {
            let icon = SidebarImageView(image: SidebarRenderer.symbol(name, color: color, pointSize: 11))
            icon.frame = NSRect(x: centerX - 7, y: centerY - 7, width: 14, height: 14)
            icon.setAccessibilityElement(false)
            // A layer of its own: a check drawn over it hides it meanwhile.
            icon.wantsLayer = true
            append(icon)
            return nil
        }
        let color: NSColor
        switch mark {
        case .asking: return symbol(Theme.Symbol.question, Theme.Color.textSecondary, nil)
        case .blocked: return symbol(Theme.Symbol.blocked, Theme.Color.textSecondary, nil)
        case .readyToMerge:
            _ = symbol(Theme.Symbol.checksPassed, Theme.Color.success, nil)
            // Drawn once, when the checks pass in front of the user.
            if let icon = views.last { buildCheck(over: icon, startedAt: readyAt, holds: false) }
            return nil
        case .merged: return symbol(Theme.Symbol.merged, Theme.Color.done, nil)
        case .finished:
            _ = symbol(Theme.Symbol.checksPassed, Theme.Color.idle, nil)
            // The green check of a turn's end draws over it, as over the dot.
            return views.last
        case .checksRunning:
            return buildChecksRing(center: NSPoint(x: centerX, y: centerY))
        case .needsYou: color = Theme.Color.waiting
        case .error: color = Theme.Color.error
        case .working: color = Theme.Color.working
        case .idle: color = Theme.Color.idle
        }
        let size = Metrics.stateDotSize
        let dot = SidebarBackgroundView(frame: NSRect(x: centerX - size / 2, y: centerY - size / 2, width: size, height: size))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = size / 2
        dot.layer?.backgroundColor = color.cgColor
        append(dot)
        return dot
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
        let size: CGFloat = 12
        let host = SidebarBackgroundView(frame: NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
        host.identifier = Self.checksRingID
        host.wantsLayer = true
        let ring = CAShapeLayer()
        ring.frame = host.bounds
        ring.path = CGPath(ellipseIn: host.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = Theme.Color.textSecondary.cgColor
        ring.lineWidth = 1.5
        ring.lineCap = .round
        if animates, !workspace.isInactive {
            // One arc going round.
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
        } else {
            ring.lineDashPattern = [2, 2.7]
        }
        host.layer?.addSublayer(ring)
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

    // MARK: - Status line

    /// "Needs you · npm run migrate" in amber, "Stopped on an API error"
    /// in red, "Working", "Asking web-main", "#39 · checks passed", "Ready
    /// to merge", "Merged · Clean up", else the branch. It wraps, up to
    /// the lines the layout gives it (`SidebarRowSummary.statusLineLimit`),
    /// then ends on "…". A line that does something (the Mission question
    /// popover, the pull request, Clean up) is a link as wide as its text.
    private func buildStatusLine(top: CGFloat) -> SidebarHitArea? {
        let status = layout.summary.status
        let text = Self.statusText(layout.summary)
        let label = layout.statusLineLimit > 1
            ? SidebarWrappedText.label(text, lineHeight: Metrics.statusRowHeight, maxLines: layout.statusLineLimit)
            : NSTextField.sidebarLine(text)
        let x = layout.indentX
        let height = CGFloat(layout.statusLineCount) * Metrics.statusRowHeight
        label.frame = NSRect(x: x, y: top - height, width: layout.contentMaxX - x, height: height)
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
        let printed = layout.summary.lineText
        if let link = status.linkText, printed.hasSuffix(link) {
            let prefix = label.attributedStringValue.attributedSubstring(
                from: NSRange(location: 0, length: (printed as NSString).length - (link as NSString).length)
            )
            start = floor(prefix.size().width)
        }
        let width = min(label.frame.width, full + 4) - start
        return SidebarHitArea(
            frame: NSRect(x: label.frame.minX - 2 + start, y: label.frame.minY - 2, width: width + 2, height: label.frame.height + 4),
            region: .link(url: url, label: label)
        )
    }

    /// The status line as the row prints it (`SidebarRowSummary.lineText`).
    static func statusText(_ summary: SidebarRowSummary) -> NSAttributedString {
        let status = summary.status
        let font = status.tone == .branch ? Theme.Font.mono : Theme.Font.body
        let color: NSColor = switch status.tone {
        case .needsYou: Theme.Color.waiting
        case .error: Theme.Color.error
        case .neutral, .branch: Theme.Color.textSecondary
        }
        let shown = summary.lineText
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
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel("Resume \(deferred.processName) here")
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
        case let .turnQuestion(columnIndex, question):
            add(SidebarTurnQuestionBlockRenderer(
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
        case .ruleProposals(let count):
            let label = NSTextField.sidebarLine(Self.ruleProposalsText(count: count))
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
        }
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
    private static func ruleProposalsText(count: Int) -> NSAttributedString {
        let font = Theme.Font.caption
        let result = NSMutableAttributedString(string: ruleProposalsTitle(count: count) + " · ", attributes: [
            .font: font, .foregroundColor: Theme.Color.textSecondary
        ])
        result.append(NSAttributedString(string: "Review", attributes: [.font: font, .foregroundColor: Theme.Color.accent]))
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
            label.toolTip = "\(question.text)\n\n\(question.explanation) Click to answer."
            label.setAccessibilityLabel(
                question.handOff == nil ? "Asking \(question.parentTitle): \(question.text)" : "Needs you, a question: \(question.text)"
            )
        }
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
    /// and a dot for its state (green while it works, amber when it needs
    /// you, red once it broke); then the action block, as any row.
    private func buildLeadRow(frame: NSRect) {
        let rowY = frame.maxY - Metrics.leadRowHeight
        let midY = rowY + Metrics.leadRowHeight / 2
        let icon = SidebarImageView(image: SidebarRenderer.symbol(Theme.Symbol.lead, color: Theme.Color.accent, pointSize: 13))
        icon.frame = NSRect(x: (Metrics.markCenterX + layout.nestIndent) - 8, y: midY - 8, width: 16, height: 16)
        icon.setAccessibilityElement(false)
        append(icon)

        var maxX = layout.contentMaxX
        let state: NSColor? = switch layout.summary.mark {
        case .working: Theme.Color.working
        case .needsYou: Theme.Color.waiting
        case .error: Theme.Color.error
        default: nil
        }
        if let state {
            let size: CGFloat = 7
            let dot = SidebarBackgroundView(frame: NSRect(x: maxX - size, y: midY - size / 2, width: size, height: size))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = size / 2
            dot.layer?.backgroundColor = state.cgColor
            append(dot)
            maxX = dot.frame.minX - Theme.Space.sm
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
    private let image: NSImage?

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

/// The action block's buttons.
@MainActor
enum SidebarActionButton {
    /// Allow: the one action the block recommends.
    static func primary(_ title: String, label: String) -> SidebarBadgeView {
        let button = SidebarBadgeView(
            text: title, textColor: Theme.Color.canvas, fillColor: Theme.Color.accent,
            font: NSFont.systemFont(ofSize: Theme.Font.caption.pointSize, weight: .semibold)
        )
        button.hoverFillColor = Theme.Color.tint(Theme.Color.textPrimary, 0.18, over: Theme.Color.accent)
        return configured(button, label: label)
    }

    static func secondary(_ title: String, symbol: String? = nil, label: String) -> SidebarBadgeView {
        let button = SidebarBadgeView(
            text: title, textColor: Theme.Color.textPrimary, fillColor: Theme.Color.fillHover,
            font: NSFont.systemFont(ofSize: Theme.Font.caption.pointSize, weight: .medium)
        )
        button.symbolName = symbol
        button.borderColor = Theme.Color.lineStrong
        button.hoverFillColor = Theme.Color.fillPressed
        return configured(button, label: label)
    }

    /// Dismiss: a grey word without a frame, lit under the pointer.
    static func quiet(_ title: String, label: String) -> SidebarBadgeView {
        let button = SidebarBadgeView(
            text: title, textColor: Theme.Color.textTertiary, fillColor: .clear, font: Theme.Font.caption
        )
        button.hoverTextColor = Theme.Color.textPrimary
        button.hoverFillColor = Theme.Color.fillHover
        return configured(button, label: label)
    }

    private static func configured(_ button: SidebarBadgeView, label: String) -> SidebarBadgeView {
        button.cornerRadius = Theme.Radius.control
        button.toolTip = label
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(label)
        return button
    }
}
