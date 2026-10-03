import AppKit

/// The card's review row: `CR ✓  PM ✓  CS ·  ADV ·`. Green ran on HEAD,
/// orange ran on an earlier commit, a dot never ran.
@MainActor
enum SidebarReviewBadgesRow {
    static func label(_ badges: ReviewBadges, isActive: Bool, x: CGFloat, width: CGFloat, top: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithAttributedString: attributedText(badges, isActive: isActive))
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = toolTip(badges)
        label.frame = NSRect(
            x: x,
            y: top - SidebarExpandedMetrics.reviewHeight,
            width: width,
            height: SidebarExpandedMetrics.reviewHeight
        )
        return label
    }

    private static func attributedText(_ badges: ReviewBadges, isActive: Bool) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        let text = NSMutableAttributedString()
        for pass in ReviewPass.allCases {
            if text.length > 0 { text.append(NSAttributedString(string: "  ")) }
            let mark: String
            let color: NSColor
            if badges.isFresh(pass) {
                mark = "✓"
                color = .systemGreen
            } else if badges.runs[pass] != nil {
                mark = "✓"
                color = .systemOrange
            } else {
                mark = "·"
                color = NSColor.white.withAlphaComponent(isActive ? 0.42 : 0.30)
            }
            text.append(NSAttributedString(
                string: "\(pass.badge) \(mark)",
                attributes: [.font: font, .foregroundColor: color]
            ))
        }
        return text
    }

    private static func toolTip(_ badges: ReviewBadges, now: Date = Date()) -> String {
        ReviewPass.allCases.map { pass in
            guard let run = badges.runs[pass] else { return "\(pass.displayName): not run" }
            let ran = "\(pass.displayName): ran \(SidebarView.relativeAge(since: run.at, now: now)) ago"
                + " on \(run.head.prefix(7))"
            return badges.isFresh(pass) ? ran : ran + ", not the current HEAD"
        }.joined(separator: "\n")
    }
}
