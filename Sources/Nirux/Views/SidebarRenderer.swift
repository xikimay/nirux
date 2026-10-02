import AppKit

/// Formatting + rendering helpers for the sidebar's workspace cards (and the
/// few other surfaces that describe a column or a wait): column rows with
/// icons, git diff stats, PR state, CI status, review decision — this file
/// is the single source of truth for how any of that looks.
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

    /// Build a colored "+42 -8" attributed string at the given font size.
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

    /// Compact labels: "passed" / "failed" / "running".
    static func ciStatusDisplay(_ ciStatus: String) -> (dot: String, color: NSColor, text: String) {
        switch ciStatus {
        case "SUCCESS":
            return ("●", .systemGreen, "passed")
        case "FAILURE":
            return ("✗", .systemRed, "failed")
        case "PENDING":
            return ("◐", .systemYellow, "running")
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
        if column.isProjectBoard {
            return sfSymbol("tablecells", color: color)
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
        case "gemini":
            return sfSymbol("sparkle", color: color)
        case "opencode":
            return sfSymbol("chevron.left.forwardslash.chevron.right", color: color)
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
        } else if column.isProjectBoard {
            displayName = "Project Board"
        } else if column.isWebView {
            displayName = column.webTitle?.isEmpty == false ? column.webTitle! : "web"
        } else {
            displayName = column.stuck?.agentName ?? column.processName ?? "shell"
        }
        // Unsaved-changes dot — same amber as the editor tab bar's. Before
        // the name: these labels truncate tail-first, and a state indicator
        // must survive long file names.
        if column.isEditor, column.editorIsDirty {
            result.append(NSAttributedString(string: "● ", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize - 3, weight: .regular),
                .foregroundColor: NSColor(red: 0.95, green: 0.7, blue: 0.3, alpha: 1)
            ]))
        }
        result.append(NSAttributedString(string: displayName, attributes: [.font: font, .foregroundColor: textColor]))

        // Time in the current turn for working agents — "· 12m" in green
        // next to the name.
        if column.agentStatus == .working, let elapsed = column.agentElapsedSeconds {
            result.append(NSAttributedString(string: " · \(shortDuration(elapsed))", attributes: [
                .font: font,
                .foregroundColor: NSColor.systemGreen.withAlphaComponent(0.65)
            ]))
        }
        // A stuck agent says so whatever its status — focusing the column
        // or the app clears attention, not the wait or the failure.
        if let stuck = column.stuck {
            result.append(NSAttributedString(string: " · \(stuck.label)", attributes: [
                .font: font,
                .foregroundColor: stuck.isFailure
                    ? NSColor.systemRed.withAlphaComponent(0.9)
                    : NSColor.systemOrange.withAlphaComponent(0.8)
            ]))
            return result
        }
        // Why a waiting agent waits — "· permission · Bash" in orange when
        // it is blocked on the user, a muted "· done" when its turn ended.
        if column.agentStatus == .needsAttention, let reason = column.attentionReason {
            result.append(NSAttributedString(string: " · \(reason.shortLabel)", attributes: [
                .font: font,
                .foregroundColor: attentionTextColor(for: reason)
            ]))
        }

        return result
    }

    /// Row tooltip: what exactly the agent waits on ("Bash: git push").
    static func attentionTooltip(for column: ColumnInfo) -> String? {
        if let stuck = column.stuck { return stuck.tooltip }
        guard column.agentStatus == .needsAttention, let reason = column.attentionReason else { return nil }
        let detail = reason.detailLine.flatMap { AgentText.clean($0, maxLength: 300) }
        return [reason.headline, detail].compactMap { $0 }.joined(separator: " — ")
    }

    static func attentionTextColor(for reason: AgentAttentionReason) -> NSColor {
        if reason.isFailure { return NSColor.systemRed.withAlphaComponent(0.9) }
        return reason == .turnFinished
            ? NSColor.white.withAlphaComponent(0.45)
            : NSColor.systemOrange.withAlphaComponent(0.8)
    }

    /// Compact duration for sidebar rows: 42s, 12m, 1h05m. Pure —
    /// nonisolated so ColumnInfo's display-granularity Hashable can use it.
    nonisolated static func shortDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        return "\(total / 3600)h\(String(format: "%02d", (total % 3600) / 60))m"
    }
}
