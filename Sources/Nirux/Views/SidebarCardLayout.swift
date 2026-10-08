import AppKit

/// A column chip on a card's third line: the column's icon, then what it
/// is doing. Clicking it focuses the column; a restored agent's chip is its
/// Resume button.
@MainActor
struct SidebarColumnChip {
    enum Style { case plain, focused, waiting, error, resume }

    let column: ColumnInfo
    let style: Style
    let text: NSAttributedString
    let width: CGFloat
    let toolTip: String
    let accessibilityLabel: String

    init(_ column: ColumnInfo) {
        self.column = column
        let attention = column.attention
        style = Self.style(of: column)
        let color = Self.color(of: style)

        let font = Theme.Font.caption
        let text = NSMutableAttributedString()
        if let icon = SidebarRenderer.columnIcon(for: column, color: color) {
            text.append(Self.attachment(icon, side: 12, font: font))
        }
        // Unsaved changes: the editor tab bar's dot.
        if column.isEditor, column.editorIsDirty {
            text.append(Self.spacer())
            text.append(Self.attachment(SidebarRenderer.dot(Theme.Color.textPrimary, diameter: 5), side: 5, font: font))
        }
        var status: String?
        if column.deferredAgent != nil {
            status = "paused"
            text.append(Self.spacer())
            text.append(NSAttributedString(string: "Resume", attributes: [.font: font, .foregroundColor: color]))
        } else if let attention, let label = column.attentionLabel {
            status = label
            text.append(Self.spacer())
            text.append(NSAttributedString(string: label, attributes: [
                .font: font, .foregroundColor: attention == .finished ? Theme.Color.textSecondary : color
            ]))
        } else if column.agentStatus == .working {
            status = ["working", column.elapsedDisplay].compactMap { $0 }.joined(separator: " ")
            text.append(Self.spacer())
            text.append(Self.attachment(SidebarRenderer.dot(Theme.Color.working, diameter: 6), side: 6, font: font))
            if let elapsed = column.elapsedDisplay {
                text.append(Self.spacer())
                text.append(NSAttributedString(string: elapsed, attributes: [.font: font, .foregroundColor: color]))
            }
        }
        self.text = text
        width = ceil(text.size().width) + SidebarExpandedMetrics.chipPaddingX * 2

        var name = SidebarRenderer.columnName(column)
        if column.isEditor, column.editorIsDirty { name += " · unsaved" }
        if let status { name += " · \(status)" }
        toolTip = [name, SidebarRenderer.attentionTooltip(for: column)].compactMap { $0 }.joined(separator: "\n")
        accessibilityLabel = column.isFocused ? "\(name), focused" : name
    }

    private static func style(of column: ColumnInfo) -> Style {
        if column.deferredAgent != nil { return .resume }
        switch column.attention {
        case .waiting?: return .waiting
        case .error?: return .error
        case .finished?, nil: return column.isFocused ? .focused : .plain
        }
    }

    private static func color(of style: Style) -> NSColor {
        switch style {
        case .plain: return Theme.Color.textSecondary
        case .focused: return Theme.Color.textPrimary
        case .waiting: return Theme.Color.waiting
        case .error: return Theme.Color.error
        case .resume: return Theme.Color.accent
        }
    }

    var fillColor: NSColor {
        switch style {
        case .plain: return Theme.Color.fillHover
        case .focused: return Theme.Color.fillSelected
        case .waiting: return Theme.Color.waiting.withAlphaComponent(0.16)
        case .error: return Theme.Color.error.withAlphaComponent(0.15)
        case .resume: return Theme.Color.accent.withAlphaComponent(0.16)
        }
    }

    /// An image sitting on the text line, centered on its cap height. The
    /// run carries the line's font: a fontless one would make the line
    /// taller and clip its descenders.
    static func attachment(_ image: NSImage, side: CGFloat, font: NSFont) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        let height = min(side, side / max(aspect, 1))
        attachment.bounds = CGRect(
            x: 0, y: (font.capHeight - height) / 2, width: height * aspect, height: height
        )
        return withFont(NSAttributedString(attachment: attachment), font)
    }

    /// Four points between a chip's parts.
    static func spacer(_ width: CGFloat = Theme.Space.xs, font: NSFont = Theme.Font.caption) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: NSSize(width: width, height: 1))
        attachment.bounds = CGRect(x: 0, y: 0, width: width, height: 1)
        return withFont(NSAttributedString(attachment: attachment), font)
    }

    private static func withFont(_ text: NSAttributedString, _ font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        result.addAttribute(.font, value: font, range: NSRange(location: 0, length: result.length))
        return result
    }
}

/// A link at the right end of a card's third line.
@MainActor
struct SidebarCardLink {
    let text: NSAttributedString
    let width: CGFloat
    let url: String
    let toolTip: String

    init(text: NSAttributedString, url: String, toolTip: String) {
        self.text = text
        width = ceil(text.size().width)
        self.url = url
        self.toolTip = toolTip
    }
}

/// What a workspace card shows and where, before any view exists: the
/// renderer draws it, `SidebarExpandedMetrics.workspaceHeight` measures it.
@MainActor
struct SidebarCardLayout {
    typealias Metrics = SidebarExpandedMetrics

    struct ChipPlacement {
        let chip: SidebarColumnChip
        /// From the chip rows' left edge (`indentX`).
        let x: CGFloat
    }

    let workspace: WorkspaceInfo
    let sidebarWidth: CGFloat
    let isCompact: Bool
    let state: SidebarCardState
    let showsBranchRow: Bool
    /// Line 3's right end, left to right: PR feedback, the pull request,
    /// its checks.
    let links: [SidebarCardLink]
    let chipRows: [[ChipPlacement]]
    let actions: [SidebarCardAction]
    let height: CGFloat

    init(workspace: WorkspaceInfo, sidebarWidth: CGFloat) {
        self.workspace = workspace
        self.sidebarWidth = sidebarWidth
        isCompact = workspace.showsCompactRow
        state = workspace.cardState
        showsBranchRow = workspace.gitBranch != nil || workspace.diffStats != nil
        links = Self.links(for: workspace)
        actions = isCompact ? [] : workspace.cardActions

        let rowWidth = sidebarWidth - (Metrics.workspaceInsetX + Metrics.cardPaddingX) * 2 - Metrics.cardIndent
        let linksWidth = links.reduce(CGFloat(0)) { $0 + $1.width } + Self.linkGaps(links)
        let firstRowWidth = rowWidth - (links.isEmpty ? 0 : linksWidth + Theme.Space.sm)
        var rows: [[ChipPlacement]] = []
        var row: [ChipPlacement] = []
        var x: CGFloat = 0
        for chip in workspace.columns.map(SidebarColumnChip.init) {
            let available = rows.isEmpty ? firstRowWidth : rowWidth
            // A first chip too wide for the space left of the links starts
            // on the next line, never under them.
            if x + chip.width > available, !row.isEmpty || (rows.isEmpty && available < rowWidth) {
                rows.append(row)
                row = []
                x = 0
            }
            row.append(ChipPlacement(chip: chip, x: x))
            x += chip.width + Metrics.chipGap
        }
        if !row.isEmpty { rows.append(row) }
        chipRows = rows

        if isCompact {
            height = Metrics.compactRowHeight
        } else {
            let lineCount = CGFloat(max(rows.count, links.isEmpty ? 0 : 1))
            var height = Metrics.cardPaddingY * 2 + Metrics.titleRowHeight
            if showsBranchRow { height += Metrics.cardRowGap + Metrics.branchRowHeight }
            if lineCount > 0 {
                height += Metrics.cardRowGap + Metrics.chipRowTopGap
                    + lineCount * Metrics.chipHeight + (lineCount - 1) * Metrics.chipGap
            }
            self.height = height + Metrics.actionBlockHeight(actions)
        }
    }

    var cardX: CGFloat { Metrics.workspaceInsetX }
    var cardWidth: CGFloat { sidebarWidth - Metrics.workspaceInsetX * 2 }
    var contentX: CGFloat { cardX + Metrics.cardPaddingX }
    var contentMaxX: CGFloat { cardX + cardWidth - Metrics.cardPaddingX }
    var indentX: CGFloat { contentX + Metrics.cardIndent }

    /// The branch without the longest prefix it shares with a sibling's,
    /// cut after that prefix's last `/` or `-`: worktrees of one repo tell
    /// apart by their ends (`tomiir/payouts-ledger` → `ledger`).
    static func distinctiveBranch(_ branch: String, siblings: [String]) -> String {
        let shared = siblings.filter { $0 != branch }.map { branch.commonPrefix(with: $0).count }.max() ?? 0
        guard let separator = branch.prefix(shared).lastIndex(where: { $0 == "/" || $0 == "-" }) else { return branch }
        let rest = branch[branch.index(after: separator)...]
        return rest.isEmpty ? branch : String(rest)
    }

    /// Between the feedback and the pull request, and the pull request and
    /// its checks.
    static func linkGaps(_ links: [SidebarCardLink]) -> CGFloat {
        CGFloat(max(links.count - 1, 0)) * Theme.Space.xs
    }

    private static func links(for workspace: WorkspaceInfo) -> [SidebarCardLink] {
        guard let pullRequest = workspace.prInfo else { return [] }
        var links: [SidebarCardLink] = []
        if let feedback = workspace.prFeedback {
            links.append(SidebarCardLink(
                text: feedbackText(feedback),
                url: SidebarView.prFeedbackActionURL(workspaceID: workspace.id),
                toolTip: "PR feedback nobody dealt with: \(feedback.humans) from people, \(feedback.bots) from bots"
            ))
        }
        let (_, color) = SidebarRenderer.prStateDisplay(pullRequest)
        let font = Theme.Font.mono
        let number = NSMutableAttributedString()
        let symbol = pullRequest.state == "MERGED" ? Theme.Symbol.merged : Theme.Symbol.pullRequest
        if let icon = SidebarRenderer.symbol(symbol, color: color) {
            number.append(SidebarColumnChip.attachment(icon, side: 12, font: font))
            number.append(SidebarColumnChip.spacer())
        }
        number.append(NSAttributedString(string: "#\(pullRequest.number)", attributes: [
            .font: font, .foregroundColor: color
        ]))
        links.append(SidebarCardLink(
            text: number,
            url: SidebarView.openActionURL(workspaceIndex: workspace.index, url: pullRequest.url),
            toolTip: SidebarRenderer.pullRequestToolTip(pullRequest)
        ))
        if let ciStatus = pullRequest.ciStatus, pullRequest.state == "OPEN" {
            let display = SidebarRenderer.ciStatusDisplay(ciStatus)
            if let name = display.symbol, let icon = SidebarRenderer.symbol(name, color: display.color) {
                // The failed check, else the PR's Checks tab, which lists
                // running and finished runs.
                let url = (ciStatus == "FAILURE" ? pullRequest.failedCheckUrl : nil) ?? "\(pullRequest.url)/checks"
                links.append(SidebarCardLink(
                    text: SidebarColumnChip.attachment(icon, side: 12, font: font),
                    url: SidebarView.openActionURL(workspaceIndex: workspace.index, url: url),
                    toolTip: "Checks \(display.text)"
                ))
            }
        }
        return links
    }

    private static func feedbackText(_ feedback: SidebarPRFeedback) -> NSAttributedString {
        let font = Theme.Font.caption
        let text = NSMutableAttributedString()
        for (symbol, count) in [(Theme.Symbol.prFeedback, feedback.humans), (Theme.Symbol.botFeedback, feedback.bots)] where count > 0 {
            if text.length > 0 { text.append(SidebarColumnChip.spacer(6)) }
            if let icon = SidebarRenderer.symbol(symbol, color: Theme.Color.textSecondary) {
                text.append(SidebarColumnChip.attachment(icon, side: 12, font: font))
                text.append(SidebarColumnChip.spacer(2))
            }
            text.append(NSAttributedString(string: "\(count)", attributes: [
                .font: font, .foregroundColor: Theme.Color.textSecondary
            ]))
        }
        return text
    }
}
