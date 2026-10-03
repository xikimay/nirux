import XCTest

/// Colors and the dark appearance come from `Theme`: outside it, an
/// `NSColor`/`CGColor` initializer (or `.init`) with number components, a
/// hex literal, `niruxAccent` or a forced `.darkAqua` fails this test. Named system colors and white
/// alphas are left to the redesign PRs.
final class ThemeGuardTests: XCTestCase {
    private static let advice = """
        use Theme instead of literal colors: window, board, status bar → Theme.Color.canvas; sidebar, panel, palette, \
        sheet → .base; card, column title bar, active tab, find bar → .surface; menu, popover, toast, hint → .raised; \
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
