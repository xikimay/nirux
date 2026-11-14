import XCTest

/// Colors and the dark appearance come from `Theme`: outside it, an
/// `NSColor`/`CGColor` initializer (or `.init`) with number components, a
/// hex literal, `niruxAccent` or a forced `.darkAqua` fails this test. Named system colors and white
/// alphas are left to the redesign PRs.
final class ThemeGuardTests: XCTestCase {
    private static let advice = """
        use Theme instead of literal colors: window, board, status bar → Theme.Color.canvas; sidebar, panel, palette, \
        sheet → .base; card, column header, active tab, find bar → .surface; menu, popover, toast, hint → .raised; \
        text → .textPrimary/.textSecondary/.textTertiary; \
        agent states → .working/.waiting/.error/.idle (.waiting only when something waits for the user's answer); \
        merged PR → .done; checks passed → .success; a warning → NSColor.systemOrange, never .waiting; \
        NSColor.niruxAccent → .accent; NSAppearance(named: .darkAqua) → Theme.appearance
        """

    private let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Nirux")

    func testColorsAndAppearanceComeFromTheme() throws {
        // Paths relative to Sources/Nirux, whatever symlinks lead there.
        let paths = try FileManager.default.subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") && $0 != "Util/Theme.swift" }
        var offenders: [String] = []
        for path in paths {
            offenders += try offendingLines(in: path).map { "\(path):\($0)" }
        }
        XCTAssertGreaterThan(paths.count, 100, "found too few sources under \(sources.path)")
        XCTAssertEqual(offenders, [], Self.advice)
    }

    /// Font sizes, corner radii and shadows written as numbers outside
    /// `Theme`: no file may gain any (docs/design/glass-interface.md). The
    /// counts below are what each file held on 2026-11-14; lower a count when
    /// you remove some. The Board's and the merge queue's files join once the
    /// Board's swap is done.
    func testNoNewLiteralFontsRadiiOrShadows() throws {
        let literal = try NSRegularExpression(pattern: #"""
            (systemFont|boldSystemFont|monospacedSystemFont|monospacedDigitSystemFont) \( \s* ofSize: \s* [0-9]
            | cornerRadius \s* = \s* [0-9] | xRadius: \s* [0-9]
            | shadow(Opacity|Radius) \s* = \s* [0-9] | shadowOffset \s* = \s* (CGSize|NSSize) \( \s* width: \s* -? [0-9]
            """#, options: .allowCommentsAndWhitespace)
        let paths = try FileManager.default.subpathsOfDirectory(atPath: sources.path).filter {
            $0.hasSuffix(".swift") && $0 != "Util/Theme.swift"
                && !$0.hasPrefix("Views/Board") && !$0.hasPrefix("Model/Board")
                && !$0.hasPrefix("Views/ProjectBoard") && !$0.hasPrefix("Model/ProjectBoard")
                && !$0.hasPrefix("Views/MergeQueue") && !$0.hasPrefix("Model/MergeQueue")
        }
        var grown: [String] = []
        for path in paths {
            let text = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
            let count = literal.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            let allowed = Self.literalCounts[path] ?? 0
            if count > allowed { grown.append("\(path): \(count), was \(allowed)") }
        }
        XCTAssertEqual(grown, [], "use Theme.Font, Theme.Radius and Theme's tokens; add one to Util/Theme.swift when none fits")
    }

    private static let literalCounts: [String: Int] = [
        "Model/WorkspaceState.swift": 1,
        "Views/ClaudeUsageIndicator.swift": 1,
        "Views/ColumnInternalViews.swift": 9,
        "Views/CommandPalette+URLMode.swift": 4,
        "Views/CommandPalette.swift": 5,
        "Views/EditorFileTree.swift": 8,
        "Views/EditorSearchPanel.swift": 5,
        "Views/EditorTabBar.swift": 4,
        "Views/FilePickerPanel.swift": 5,
        "Views/FindBar.swift": 3,
        "Views/GlobalSearchPanel.swift": 7,
        "Views/LocalServerChipView.swift": 3,
        "Views/MissionReplyViewController.swift": 1,
        "Views/NewSpacePanel.swift": 2,
        "Views/NewTaskPanel.swift": 3,
        "Views/NiruxShellView+SidebarGit.swift": 1,
        "Views/OnboardingChecklistView.swift": 13,
        "Views/ProjectMemoryPanel.swift": 1,
        "Views/RaycastPanel.swift": 2,
        "Views/SessionHistoryPanel.swift": 1,
        "Views/SidebarRail.swift": 3,
        "Views/SidebarShortcutHintView.swift": 4,
        "Views/SidebarView+Drag.swift": 5,
        "Views/SidebarView+Rendering.swift": 1,
        "Views/SidebarWorkspaceCardRenderer.swift": 1,
        "Views/SpaceArrivalBanner.swift": 3,
        "Views/SpaceFileEditorPane.swift": 1,
        "Views/SpaceSettingsDefaultsPane.swift": 1,
        "Views/SpaceSettingsGeneralPane.swift": 3,
        "Views/StatusBarView.swift": 6,
        "Views/ToastView.swift": 3,
        "Views/TransientHintView.swift": 2,
        "Views/WorkspaceContextPanel.swift": 13,
        "Views/WorkspaceNameCard.swift": 4,
        "Views/WorktreeCleanupPanel.swift": 7
    ]

    /// 1-based lines of `path` with a literal color, `.darkAqua` or `niruxAccent`.
    private func offendingLines(in path: String) throws -> [Int] {
        // `\s*` spans newlines: the codebase splits long initializers over lines.
        let literalColor = try NSRegularExpression(pattern: #"""
            ( (NSColor|CGColor) (\.init)? | (?<![\w)\]]) \.init ) \( \s*
            (red|calibratedRed|deviceRed|srgbRed|displayP3Red|white|calibratedWhite|deviceWhite|genericGamma22White
                |hue|calibratedHue|deviceHue|hex|gray|genericGrayGamma2_2Gray)
            \s*:\s* (CGFloat\(\s*)? [0-9.]
            | niruxColor\(\s*hex:\s*"
            """#, options: .allowCommentsAndWhitespace)
        let text = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
        var lines: [Int] = []
        for match in literalColor.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            lines.append(text[..<range.lowerBound].components(separatedBy: "\n").count)
        }
        // The deprecated alias keeps old branches building; the guard names the token.
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let isAliasDefinition = path == "Util/Extensions.swift" && line.contains("static let niruxAccent")
            if line.contains(".darkAqua") || (line.contains("niruxAccent") && !isAliasDefinition) {
                lines.append(index + 1)
            }
        }
        return lines.sorted()
    }
}
