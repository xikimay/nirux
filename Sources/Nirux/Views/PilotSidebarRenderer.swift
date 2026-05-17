import AppKit

/// Shared formatting + rendering helpers used by both SidebarView (expanded
/// mode) and WorkspaceState's pilot panel. Both surfaces render the same
/// workspace metadata — column rows with icons, agent-status dots, git diff
/// stats, PR state, CI status, review decision — and this file is the single
/// source of truth for how any of that looks.
@MainActor
enum PilotSidebarRenderer {

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

    /// Build a colored "+42 -8" attributed string at the given font size.
    /// Used by both the sidebar and the pilot panel diff stats row.
    static func diffStatsAttributedString(_ compact: String, fontSize: CGFloat) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let attrStr = NSMutableAttributedString()
        for part in compact.split(separator: " ") {
            let segment = String(part)
            let color: NSColor
            if segment.hasPrefix("+") {
                color = .systemGreen
            } else if segment.hasPrefix("-") {
                color = .systemRed
            } else {
                color = NSColor.white.withAlphaComponent(0.3)
            }
            if !attrStr.string.isEmpty {
                attrStr.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            attrStr.append(NSAttributedString(string: segment, attributes: [
                .font: font, .foregroundColor: color
            ]))
        }
        return attrStr
    }

    // MARK: - PR state / CI / review decision

    static func prStateDisplay(_ pullRequest: PRInfo) -> (text: String, color: NSColor) {
        if pullRequest.isDraft {
            return ("draft", NSColor.white.withAlphaComponent(0.35))
        }
        switch pullRequest.state {
        case "MERGED":
            return ("merged", NSColor(red: 0.64, green: 0.47, blue: 0.97, alpha: 1))
        case "CLOSED":
            return ("closed", NSColor.systemRed.withAlphaComponent(0.6))
        default:
            return ("open", .niruxAccent)
        }
    }

    enum CIStatusStyle {
        /// Compact labels for the sidebar: "passed" / "failed" / "running".
        case short
        /// Verbose labels for the pilot panel: "checks passed" / "checks failed".
        case long
    }

    static func ciStatusDisplay(_ ciStatus: String, style: CIStatusStyle) -> (dot: String, color: NSColor, text: String) {
        switch ciStatus {
        case "SUCCESS":
            return ("●", .systemGreen, style == .long ? "checks passed" : "passed")
        case "FAILURE":
            return ("✗", .systemRed, style == .long ? "checks failed" : "failed")
        case "PENDING":
            return ("◐", .systemYellow, style == .long ? "checks running" : "running")
        default:
            return ("○", NSColor.white.withAlphaComponent(0.3), ciStatus.lowercased())
        }
    }

    /// Review decision or conflict banner. Returns nil when there's nothing
    /// meaningful to show (no decision and no conflict).
    static func reviewDecisionDisplay(
        reviewDecision: String?, mergeable: String?
    ) -> (dot: String, text: String, color: NSColor)? {
        if mergeable == "CONFLICTING" {
            return ("⚠", "conflict", .systemRed)
        }
        guard let decision = reviewDecision, !decision.isEmpty else { return nil }
        switch decision {
        case "APPROVED": return ("✓", "approved", .systemGreen)
        case "CHANGES_REQUESTED": return ("⚑", "changes requested", .systemOrange)
        case "REVIEW_REQUIRED": return ("⟳", "review requested", .systemYellow)
        default: return nil
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

    /// SF symbol configured for a column-row glyph. Used for fallback icons
    /// when an app icon isn't available.
    static func sfSymbol(_ name: String, color: NSColor) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return symbol.withSymbolConfiguration(config)
    }

    /// Icon glyph for a column row (web globe, agent app icon, or process-
    /// specific SF symbol).
    static func columnIcon(for column: ColumnInfo, color: NSColor) -> NSImage? {
        if column.isEditor {
            return sfSymbol("doc.text", color: color)
        }
        if column.isWebView {
            return sfSymbol("globe", color: color)
        }
        guard let processName = column.processName?.lowercased() else {
            return sfSymbol("apple.terminal", color: color)
        }
        switch processName {
        case "claude":
            return claudeAppIcon ?? sfSymbol("sparkles", color: color)
        case "codex":
            return codexAppIcon ?? sfSymbol("brain.head.profile", color: color)
        case "vim", "nvim", "vi", "helix", "hx", "nano", "emacs":
            return sfSymbol("pencil.line", color: color)
        case "ssh", "mosh":
            return sfSymbol("network", color: color)
        case "htop", "top", "btop":
            return sfSymbol("chart.bar", color: color)
        default:
            return sfSymbol("apple.terminal", color: color)
        }
    }

    /// Attributed column row: focus indicator + icon + display name.
    /// `fontSize` controls both the text and the icon attachment baseline.
    static func attributedColumn(_ column: ColumnInfo, fontSize: CGFloat = 11) -> NSAttributedString {
        let textColor = column.isFocused
            ? NSColor.white.withAlphaComponent(0.8)
            : NSColor.white.withAlphaComponent(0.35)
        let font = NSFont.monospacedSystemFont(
            ofSize: fontSize,
            weight: column.isFocused ? .medium : .regular
        )
        let result = NSMutableAttributedString()

        let indicator = column.isFocused ? "▸ " : "  "
        result.append(NSAttributedString(string: indicator, attributes: [.font: font, .foregroundColor: textColor]))

        if let icon = columnIcon(for: column, color: textColor) {
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = CGRect(x: 0, y: -2, width: 13, height: 13)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: " ", attributes: [.font: font]))
        }

        let displayName: String
        if column.isEditor {
            displayName = column.editorFileName ?? "editor"
        } else if column.isWebView {
            displayName = column.webTitle?.isEmpty == false ? column.webTitle! : "web"
        } else {
            displayName = column.processName ?? "shell"
        }
        result.append(NSAttributedString(string: displayName, attributes: [.font: font, .foregroundColor: textColor]))

        return result
    }

    // MARK: - Agent status dot

    /// Create a pulsing agent-status dot view. Returns nil for `.idle` status.
    /// Caller is responsible for adding the returned view to its parent and
    /// tracking it for later removal.
    static func makeAgentDot(
        status: AgentStatus, x: CGFloat, yOffset: CGFloat, rowHeight: CGFloat, size: CGFloat
    ) -> NSView? {
        guard status != .idle else { return nil }
        let dotColor: NSColor = status == .working ? .systemGreen : .systemOrange
        let dot = NSView(frame: NSRect(
            x: x, y: yOffset - rowHeight + (rowHeight - size) / 2,
            width: size, height: size
        ))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = dotColor.cgColor
        dot.layer?.cornerRadius = size / 2

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = status == .working ? 0.3 : 0.4
        pulse.duration = status == .working ? 1.0 : 0.5
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.layer?.add(pulse, forKey: "pulse")

        return dot
    }
}
