import AppKit

/// Formatting + rendering helpers for the sidebar's workspace cards (and the
/// few other surfaces that describe a column or a wait): column icons and
/// names, git diff stats, PR state, CI status, review decision, attention
/// colors — this file is the single source of truth for how any of that
/// looks.
@MainActor
enum SidebarRenderer {

    // MARK: - Diff stats

    /// Format "2 files changed, 42 insertions(+), 8 deletions(-)" → "2 files, +42 -8"
    static func formatDiffStats(_ raw: String) -> String {
        var files = ""
        var changes: [String] = []
        if let range = raw.range(of: #"(\d+) file"#, options: .regularExpression) {
            let num = String(raw[range]).prefix(while: \.isNumber)
            files = "\(num) files"
        }
        if let range = raw.range(of: #"(\d+) insertion"#, options: .regularExpression) {
            let num = String(raw[range]).prefix(while: \.isNumber)
            changes.append("+\(num)")
        }
        if let range = raw.range(of: #"(\d+) deletion"#, options: .regularExpression) {
            let num = String(raw[range]).prefix(while: \.isNumber)
            changes.append("-\(num)")
        }
        if files.isEmpty { return raw }
        return changes.isEmpty ? files : "\(files), \(changes.joined(separator: " "))"
    }

    /// The card's diff: "+214 −38" in green and red, "3 files" when only
    /// binary files changed, git's own text when it can't be read.
    static func diffAttributedString(_ raw: String) -> NSAttributedString {
        let font = Theme.Font.mono
        func number(_ word: String) -> String? {
            raw.range(of: #"(\d+) \#(word)"#, options: .regularExpression)
                .map { String(raw[$0].prefix(while: \.isNumber)) }
        }
        let insertions = number("insertion")
        let deletions = number("deletion")
        guard insertions != nil || deletions != nil else {
            let files = number("file").map { "\($0) files" } ?? raw
            return NSAttributedString(string: files, attributes: [.font: font, .foregroundColor: Theme.Color.textTertiary])
        }
        let result = NSMutableAttributedString()
        if let insertions {
            result.append(NSAttributedString(string: "+\(insertions)", attributes: [
                .font: font, .foregroundColor: Theme.Color.success.withAlphaComponent(0.85)
            ]))
        }
        if let deletions {
            if result.length > 0 { result.append(NSAttributedString(string: " ", attributes: [.font: font])) }
            result.append(NSAttributedString(string: "\u{2212}\(deletions)", attributes: [
                .font: font, .foregroundColor: Theme.Color.error.withAlphaComponent(0.85)
            ]))
        }
        return result
    }

    // MARK: - PR state / CI / review decision

    static func prStateDisplay(_ pullRequest: PRInfo) -> (text: String, color: NSColor) {
        if pullRequest.isDraft {
            return ("draft", Theme.Color.textTertiary)
        }
        switch pullRequest.state {
        case "MERGED":
            return ("merged", Theme.Color.done)
        case "CLOSED":
            return ("closed", Theme.Color.textTertiary)
        default:
            return ("open", Theme.Color.textSecondary)
        }
    }

    /// The card's one check sign for a CI rollup, and its words: a running
    /// check is grey, never amber.
    static func ciStatusDisplay(_ ciStatus: String) -> (symbol: String?, color: NSColor, text: String) {
        switch ciStatus {
        case "SUCCESS":
            return (Theme.Symbol.checksPassed, Theme.Color.success, "passed")
        case "FAILURE":
            return (Theme.Symbol.checksFailed, Theme.Color.error, "failed")
        case "PENDING":
            return (Theme.Symbol.checksRunning, Theme.Color.textTertiary, "running")
        default:
            return (nil, Theme.Color.textTertiary, ciStatus.lowercased())
        }
    }

    /// Review decision or conflict, for the pull request's tooltip. Nil when
    /// there's nothing meaningful to say (no decision and no conflict).
    static func reviewDecisionText(reviewDecision: String?, mergeable: String?) -> String? {
        if mergeable == "CONFLICTING" { return "conflict" }
        switch reviewDecision {
        case "APPROVED": return "approved"
        case "CHANGES_REQUESTED": return "changes requested"
        case "REVIEW_REQUIRED": return "review requested"
        default: return nil
        }
    }

    /// "#142 open · checks failed · conflict": what the card's PR sign
    /// stands for.
    static func pullRequestToolTip(_ pullRequest: PRInfo) -> String {
        var parts = ["Pull request #\(pullRequest.number) \(prStateDisplay(pullRequest).text)"]
        if let ciStatus = pullRequest.ciStatus { parts.append("checks \(ciStatusDisplay(ciStatus).text)") }
        if let review = reviewDecisionText(reviewDecision: pullRequest.reviewDecision, mergeable: pullRequest.mergeable) {
            parts.append(review)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Attention

    /// The color of an attention signal: amber only for a wait on the user.
    static func color(for signal: AttentionSignal) -> NSColor {
        switch signal {
        case .waiting: return Theme.Color.waiting
        case .error: return Theme.Color.error
        case .finished: return Theme.Color.textSecondary
        }
    }

    // MARK: - Column icons

    private static let claudeAppIcon: NSImage? = {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }()

    private static let codexAppIcon: NSImage? = {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }()

    /// The desktop app's icon for an agent that has one installed (the
    /// palette's agent rows show it too).
    static func agentAppIcon(processName: String) -> NSImage? {
        switch processName {
        case "claude": claudeAppIcon
        case "codex": codexAppIcon
        default: nil
        }
    }

    /// The symbol an agent's chip shows without its app icon.
    static func agentSymbol(processName: String) -> String? {
        switch processName {
        case "claude": "sparkles"
        case "codex": "brain.head.profile"
        default: nil
        }
    }

    /// An SF Symbol in one color.
    static func symbol(_ name: String, color: NSColor, pointSize: CGFloat = 10) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return symbol.withSymbolConfiguration(config)
    }

    /// Icon of a column chip (web globe, agent app icon, or process-
    /// specific SF symbol).
    static func columnIcon(for column: ColumnInfo, color: NSColor) -> NSImage? {
        if column.isEditor {
            return symbol(Theme.Symbol.editor, color: color)
        }
        if column.isProjectBoard {
            return symbol(Theme.Symbol.projectBoard, color: color)
        }
        if column.isBranchReview {
            return symbol(Theme.Symbol.branchReview, color: color)
        }
        if column.isWebView {
            return symbol(Theme.Symbol.browser, color: color)
        }
        guard let processName = (column.deferredAgent?.processName ?? column.processName)?.lowercased() else {
            return symbol(Theme.Symbol.terminal, color: color)
        }
        switch processName {
        case "claude", "codex":
            return agentAppIcon(processName: processName)
                ?? agentSymbol(processName: processName).flatMap { symbol($0, color: color) }
        case "gemini":
            return symbol("sparkle", color: color)
        case "opencode":
            return symbol("curlybraces", color: color)
        case "vim", "nvim", "vi", "helix", "hx", "nano", "emacs":
            return symbol("pencil.line", color: color)
        case "ssh", "mosh":
            return symbol("network", color: color)
        case "htop", "top", "btop":
            return symbol("chart.bar", color: color)
        default:
            return symbol(Theme.Symbol.terminal, color: color)
        }
    }

    /// What a column holds, in a word or two: the file, the page, the
    /// process.
    static func columnName(_ column: ColumnInfo) -> String {
        if column.isEditor { return column.editorFileName ?? "editor" }
        if column.isProjectBoard { return "Board" }
        if column.isBranchReview { return "Branch Review" }
        if column.isWebView { return column.webTitle?.isEmpty == false ? column.webTitle! : "web" }
        return column.deferredAgent?.processName ?? column.stuck?.agentName ?? column.processName ?? "shell"
    }

    /// Chip tooltip: what exactly the agent waits on ("Bash: git push").
    static func attentionTooltip(for column: ColumnInfo) -> String? {
        column.deferredAgent?.tooltip ?? column.attentionToolTip
    }

    /// A filled circle, for the dots inside chips. Drawn now, at 2×: no
    /// drawing closure for AppKit to call later, on whatever thread.
    /// `isHollow`: a ring, as the space picker draws an empty space.
    static func dot(_ color: NSColor, diameter: CGFloat, isHollow: Bool = false) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let pixels = Int(ceil(diameter * 2))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return NSImage(size: size) }
        if isHollow {
            let lineWidth: CGFloat = 3 // 1.5 pt at 2x
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(lineWidth)
            context.strokeEllipse(in: CGRect(x: 0, y: 0, width: pixels, height: pixels).insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        } else {
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        }
        guard let image = context.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: image, size: size)
    }

    /// Compact duration for sidebar chips: 42s, 12m, 1h05m. Pure —
    /// nonisolated so ColumnInfo's display-granularity Hashable can use it.
    nonisolated static func shortDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        return "\(total / 3600)h\(String(format: "%02d", (total % 3600) / 60))m"
    }
}

extension NSTextField {
    /// A one-line sidebar label: styled text never wraps its last word onto
    /// a line below the frame; it truncates at the tail (or clips).
    @MainActor
    static func sidebarLine(_ text: NSAttributedString, lineBreakMode: NSLineBreakMode = .byTruncatingTail) -> NSTextField {
        // The string's paragraph style decides, not the field's.
        let line = NSMutableAttributedString(attributedString: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreakMode
        line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
        let label = NSTextField(labelWithAttributedString: line)
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.cell?.isScrollable = false
        label.lineBreakMode = lineBreakMode
        return label
    }
}

/// Sidebar text that wraps: lines of one height, at most `maxLines` of
/// them, the last one cut with "…". `lineCount` says how many a width
/// takes before any view exists (`SidebarCardLayout` sizes rows with it),
/// `label` draws them.
@MainActor
enum SidebarWrappedText {
    /// `text` wrapping by words, every line `lineHeight` tall. `indent`
    /// hangs the lines after the first (a list item under its marker,
    /// which a tab follows).
    static func wrapping(_ text: NSAttributedString, lineHeight: CGFloat, indent: CGFloat = 0) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        if indent > 0 {
            paragraph.headIndent = indent
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            paragraph.defaultTabInterval = indent
        }
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// One cell measures every text: what a label of that width lays out.
    private static let measuringCell: NSTextFieldCell = {
        let cell = NSTextFieldCell(textCell: "")
        cell.wraps = true
        cell.isScrollable = false
        cell.lineBreakMode = .byWordWrapping
        return cell
    }()

    /// How many lines `text` takes in a label `width` wide, `maxLines` at
    /// most.
    static func lineCount(
        _ text: NSAttributedString, width: CGFloat, lineHeight: CGFloat, maxLines: Int, indent: CGFloat = 0
    ) -> Int {
        guard maxLines > 1, width > 0, text.length > 0 else { return 1 }
        measuringCell.attributedStringValue = wrapping(text, lineHeight: lineHeight, indent: indent)
        let height = measuringCell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 100_000)).height
        return min(maxLines, max(1, Int((height / lineHeight).rounded())))
    }

    /// The height of those lines.
    static func height(
        _ text: NSAttributedString, width: CGFloat, lineHeight: CGFloat, maxLines: Int, indent: CGFloat = 0
    ) -> CGFloat {
        CGFloat(lineCount(text, width: width, lineHeight: lineHeight, maxLines: maxLines, indent: indent)) * lineHeight
    }

    static func label(_ text: NSAttributedString, lineHeight: CGFloat, maxLines: Int, indent: CGFloat = 0) -> NSTextField {
        let label = NSTextField(labelWithAttributedString: wrapping(text, lineHeight: lineHeight, indent: indent))
        label.maximumNumberOfLines = maxLines
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.cell?.truncatesLastVisibleLine = true
        label.lineBreakMode = .byWordWrapping
        return label
    }
}
