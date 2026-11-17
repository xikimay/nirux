import XCTest

/// Colors and the dark appearance come from `Theme`: outside it, an
/// `NSColor`/`CGColor` initializer (or `.init`) with number components, a
/// hex literal, `niruxAccent`, orange or a forced `.darkAqua` fails this test. Other named system colors and white
/// alphas are left to the redesign PRs.
final class ThemeGuardTests: XCTestCase {
    private static let advice = """
        use Theme instead of literal colors: window, board, status bar → Theme.Color.canvas; sidebar, panel, palette, \
        sheet → .base; card, column header, active tab, find bar → .surface; menu, popover, toast, hint → .raised; \
        text → .textPrimary/.textSecondary/.textTertiary; \
        agent states → .working/.waiting/.error/.idle (.waiting only when something waits for the user's answer); \
        merged PR → .done; checks passed → .success; \
        a warning → NSColor.niruxWarning, its words after "⚠︎ " (String.asWarning), never orange or yellow (they read as amber) \
        nor .waiting; \
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
    /// counts below are each file's today; lower a count when you remove some.
    func testNoNewLiteralFontsRadiiOrShadows() throws {
        let literal = try NSRegularExpression(pattern: #"""
            (systemFont|boldSystemFont|monospacedSystemFont|monospacedDigitSystemFont) \( \s* ofSize: \s* [0-9]
            | cornerRadius \s* = \s* [0-9] | xRadius: \s* [0-9]
            | shadow(Opacity|Radius|BlurRadius) \s* = \s* [0-9] | shadowOffset \s* = \s* (CGSize|NSSize) \( \s* width: \s* -? [0-9]
            """#, options: .allowCommentsAndWhitespace)
        XCTAssertEqual(try grown(literal, past: Self.literalCounts), [], "use Theme.Font, Theme.Radius and Theme's tokens; add one to Util/Theme.swift when none fits")
    }

    /// What else holds a value of its own instead of a token: a symbol's
    /// point size, a corner radius from a local constant (a capsule's half
    /// height stays free), a named system colour, a white alpha. Same rule:
    /// the counts only go down.
    func testNoNewSymbolSizesLocalRadiiSystemColoursOrWhiteAlphas() throws {
        let loose = try NSRegularExpression(pattern: #"""
            SymbolConfiguration \( \s* pointSize: \s* [0-9]
            | cornerRadius \s* = \s* (?!Theme\.Radius|[0-9]) (?![^\n]* / \s* 2 \b)
            | \.system(Green|Red|Blue|Purple|Pink|Teal|Indigo|Gray|Brown|Mint|Cyan) \b
            | \.white\.withAlphaComponent\(
            """#, options: .allowCommentsAndWhitespace)
        XCTAssertEqual(try grown(loose, past: Self.looseCounts), [], "use Theme.Symbol sizes, Theme.Radius and Theme.Color; add a token to Util/Theme.swift when none fits")
    }

    /// "path: count, was ceiling" for each source past its ceiling.
    private func grown(_ pattern: NSRegularExpression, past ceilings: [String: Int]) throws -> [String] {
        let paths = try FileManager.default.subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") && $0 != "Util/Theme.swift" }
        XCTAssertGreaterThan(paths.count, 100, "found too few sources under \(sources.path)")
        return try paths.sorted().compactMap { path in
            let text = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
            let count = pattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            let allowed = ceilings[path] ?? 0
            return count > allowed ? "\(path): \(count), was \(allowed)" : nil
        }
    }

    private static let literalCounts: [String: Int] = [
        "Model/WorkspaceState.swift": 1,
        "Views/ColumnInternalViews.swift": 3,
        "Views/CommandPalette+URLMode.swift": 4,
        "Views/CommandPalette.swift": 3,
        "Views/EditorSearchPanel.swift": 4,
        "Views/EditorTabBar.swift": 4,
        "Views/FilePickerPanel.swift": 4,
        "Views/FindBar.swift": 4,
        "Views/LocalServerChipView.swift": 3,
        "Views/MissionReplyViewController.swift": 1,
        "Views/NewSpacePanel.swift": 2,
        "Views/NewTaskPanel.swift": 1,
        "Views/NiruxShellView+SidebarGit.swift": 1,
        "Views/RaycastPanel.swift": 2,
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
        "Views/WorkspaceNameCard.swift": 4,
        "Views/WorktreeCleanupPanel.swift": 7
    ]

    private static let looseCounts: [String: Int] = [
        "Model/WorkspaceState.swift": 1,
        "Views/BoardSettingsPanel.swift": 7,
        "Views/BoardStagesView.swift": 2,
        "Views/ClaudeUsageIndicator.swift": 1,
        "Views/ColumnHeaderView.swift": 2,
        "Views/ColumnIndicatorView.swift": 1,
        "Views/ColumnInternalViews.swift": 7,
        "Views/CommandBarView.swift": 1,
        "Views/CommandPalette+URLMode.swift": 2,
        "Views/CommandPalette.swift": 9,
        "Views/EdgeGlowView.swift": 2,
        "Views/EditorColumn.swift": 1,
        "Views/EditorFileTree.swift": 8,
        "Views/EditorSearchPanel.swift": 6,
        "Views/EditorTabBar.swift": 4,
        "Views/FilePickerPanel.swift": 4,
        "Views/FindBar.swift": 3,
        "Views/GlassView.swift": 7,
        "Views/GlobalSearchPanel.swift": 8,
        "Views/KeepAwakeIndicator.swift": 2,
        "Views/KeyCap.swift": 1,
        "Views/LocalServerChipView.swift": 2,
        "Views/MergeQueueConfirmationPanel.swift": 6,
        "Views/MissionReplyViewController.swift": 2,
        "Views/NewSpacePanel.swift": 2,
        "Views/NewTaskPanel.swift": 1,
        "Views/NiruxShellView+SidebarGit.swift": 1,
        "Views/NiruxShellView+TaskBirth.swift": 1,
        "Views/NiruxShellView+Workspaces.swift": 1,
        "Views/OnboardingChecklistView.swift": 17,
        "Views/ProjectMemoryPanel.swift": 3,
        "Views/RaycastPanel.swift": 2,
        "Views/RequestCardView.swift": 1,
        "Views/ReviewSendPanel.swift": 1,
        "Views/SessionHistoryPanel.swift": 1,
        "Views/SettingsSidebar.swift": 2,
        "Views/SidebarApprovalBlockRenderer.swift": 1,
        "Views/SidebarBadgeView.swift": 1,
        "Views/SidebarCatchUp.swift": 1,
        "Views/SidebarShortcutHintView.swift": 4,
        "Views/SidebarView+Drag.swift": 4,
        "Views/SidebarView+Rendering.swift": 2,
        "Views/SidebarWorkspaceCardRenderer.swift": 7,
        "Views/SpaceArrivalBanner.swift": 1,
        "Views/SpaceFileEditorPane.swift": 1,
        "Views/SpaceSettingsDefaultsPane.swift": 1,
        "Views/StatusBarView.swift": 9,
        "Views/TransientHintView.swift": 3,
        "Views/WebAddressField.swift": 1,
        "Views/WorkspaceContextPanel.swift": 18,
        "Views/WorkspaceNameCard.swift": 1,
        "Views/WorktreeCleanupPanel.swift": 13
    ]

    /// 1-based lines of `path` with a literal color, `.darkAqua`, `niruxAccent`, or orange or yellow as a colour
    /// (`amberLines`).
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
        // Git's mark of a modified file keeps the colour editors give it.
        let allLines = text.components(separatedBy: "\n")
        lines += Self.amberLines(in: text).filter { line in
            !(path == "Views/EditorFileTree.swift" && allLines[line - 1].contains("case .modified"))
        }
        return lines.sorted()
    }

    /// 1-based lines of `text` that use orange or yellow as a colour, which read as amber (something waits for the
    /// user's answer): `systemOrange`, `NSColor.yellow` or `Color.orange` (a chain split over lines too), and an implicit
    /// `.orange` where a colour is meant (`= .orange`, `return .orange`, `[.orange`, `{ .yellow`, `?? .orange`, a line
    /// starting with it). Not in a comment, not a `case` pattern's names, not a member of something else
    /// (`palette?.orange`). A warning is `NSColor.niruxWarning`.
    static func amberLines(in text: String) -> [Int] {
        // Comments and case patterns go, each line kept: its number stays.
        let code = text.components(separatedBy: "\n").map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return "" }
            var code = line
            if let comment = code.range(of: #"\s//.*$"#, options: .regularExpression) { code.removeSubrange(comment) }
            if let pattern = code.range(of: #"^\s*case\s[^:]*:"#, options: .regularExpression) { code.removeSubrange(pattern) }
            return code
        }.joined(separator: "\n")
        guard let amber = try? NSRegularExpression(pattern: #"""
            \b system (Orange|Yellow) \b
            | \b (NS|UI|CG)? Color \s* \. \s* (orange|yellow) \b
            | (?: ^ | [\[({,:=] | \b return | \?\? | \s\? ) [\x20\t]* \. (orange|yellow) \b
            """#, options: [.allowCommentsAndWhitespace, .anchorsMatchLines]) else { return [1] }
        return amber.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap { match in
            Range(match.range, in: code).map { code[..<$0.lowerBound].components(separatedBy: "\n").count }
        }
    }

    /// Each form the guard is for, put back: caught; comments and names that aren't colours: not.
    func testTheAmberGuardCatchesOrangeAndYellowAsColoursOnly() {
        let colours = [
            "return .orange", "let tones = [.orange, .red]", "let pick = { .yellow }", "Text(\"x\").foregroundColor(Color.orange)",
            "let c = NSColor\n    .orange", "label.textColor = .systemYellow", "let c = x ?? .orange", "let c = isOn ? .orange : .gray",
            "layer.borderColor = NSColor.systemOrange.cgColor", "    .orange", "switch tone { case .low: return .yellow }"
        ]
        for snippet in colours { XCTAssertEqual(Self.amberLines(in: snippet), [1], snippet) }
        let others = [
            "/// never systemOrange", "let x = 1 // .orange here", "let c = palette?.orange", "case .red, .orange:",
            "let name = \"Orange\"", "  // NSColor.orange", "let url = \"https://example.com/orange\""
        ]
        for snippet in others { XCTAssertEqual(Self.amberLines(in: snippet), [], snippet) }
    }
}
