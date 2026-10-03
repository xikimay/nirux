import XCTest

/// Colors and the dark appearance come from `Theme`: a literal color or a
/// forced `.darkAqua` anywhere else in the app fails this test.
final class ThemeGuardTests: XCTestCase {
    private static let advice = """
        use Theme instead of literal colors: window or board → Theme.Color.canvas; sidebar, panel, sheet → .base; \
        bar, card, tab → .surface; floating → .raised; text → .textPrimary/.textSecondary/.textTertiary; \
        agent states → .working/.waiting/.error/.done; NSAppearance(named: .darkAqua) → Theme.appearance
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

    /// 1-based lines of `path` with a literal color or `.darkAqua`.
    private func offendingLines(in path: String) throws -> [Int] {
        // `\s*` spans newlines: the codebase splits long initializers over lines.
        let literalColor = try NSRegularExpression(pattern: #"""
            (NSColor\(\s*(red|calibratedRed|deviceRed|srgbRed|displayP3Red|white|calibratedWhite|deviceWhite|hue|calibratedHue|deviceHue|hex)
            |CGColor\(\s*(red|srgbRed|gray|genericGrayGamma2_2Gray)):\s*[0-9.]
            """#, options: .allowCommentsAndWhitespace)
        let text = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
        var lines: [Int] = []
        for match in literalColor.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            lines.append(text[..<range.lowerBound].components(separatedBy: "\n").count)
        }
        for (index, line) in text.components(separatedBy: "\n").enumerated() where line.contains(".darkAqua") {
            lines.append(index + 1)
        }
        return lines.sorted()
    }
}
