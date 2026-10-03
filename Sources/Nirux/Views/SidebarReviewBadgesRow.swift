import AppKit

/// The selected card's review passes: `CR ✓  PM ✓  CS ·  ADV ·`. Green ran
/// on HEAD, grey ran on an earlier commit, a dot never ran.
@MainActor
enum SidebarReviewBadgesRow {
    static func label(_ badges: ReviewBadges, x: CGFloat, width: CGFloat, top: CGFloat) -> NSTextField {
        let label = NSTextField.sidebarLine(attributedText(badges))
        label.toolTip = toolTip(badges)
        label.frame = NSRect(
            x: x,
            y: top - SidebarExpandedMetrics.actionLineHeight,
            width: width,
            height: SidebarExpandedMetrics.actionLineHeight
        )
        return label
    }

    private static func attributedText(_ badges: ReviewBadges) -> NSAttributedString {
        let font = Theme.Font.caption
        let text = NSMutableAttributedString()
        for pass in ReviewPass.allCases {
            if text.length > 0 { text.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            let mark: String
            let color: NSColor
            if badges.isFresh(pass) {
                mark = "✓"
                color = Theme.Color.success
            } else if badges.runs[pass] != nil {
                mark = "✓"
                color = Theme.Color.textSecondary
            } else {
                mark = "·"
                color = Theme.Color.textTertiary
            }
            text.append(NSAttributedString(
                string: "\(pass.badge) \(mark)",
                attributes: [.font: font, .foregroundColor: color]
            ))
        }
        return text
    }

    static func toolTip(_ badges: ReviewBadges, now: Date = Date()) -> String {
        ReviewPass.allCases.map { pass in
            guard let run = badges.runs[pass] else { return "\(pass.displayName): not run" }
            let ran = "\(pass.displayName): ran \(SidebarView.relativeAge(since: run.at, now: now)) ago"
                + " on \(run.head.prefix(7))"
            return badges.isFresh(pass) ? ran : ran + ", not the current HEAD"
        }.joined(separator: "\n")
    }
}
