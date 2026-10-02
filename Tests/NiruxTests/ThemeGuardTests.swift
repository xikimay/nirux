import XCTest

/// Colors and the dark appearance come from `Theme`: a literal RGB color
/// or a forced `.darkAqua` anywhere else in the app fails this test.
final class ThemeGuardTests: XCTestCase {
    /// Files not migrated yet, each with the change that will migrate it.
    private static let pending: Set<String> = [
        "NiruxApp+Settings.swift", // rewritten as a tabbed window by chore/ui-cleanup
        "Views/PilotSidebarRenderer.swift", // Pilot Mode removal (#69)
        "Views/WorkspaceState+PilotPanel.swift" // Pilot Mode removal (#69)
    ]

    func testColorsAndAppearanceComeFromTheme() throws {
        let literalColor = try NSRegularExpression(
            pattern: #"NSColor\(\s*(red|calibratedRed|deviceRed|srgbRed|displayP3Red|white|calibratedWhite|deviceWhite):\s*[0-9.]"#
        )
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Nirux")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let path = String(url.path.dropFirst(sources.path.count + 1))
            guard path != "Util/Theme.swift", !Self.pending.contains(path) else { continue }
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if literalColor.firstMatch(in: line, range: range) != nil || line.contains(".darkAqua") {
                    offenders.append("\(path):\(index + 1)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "found too few sources under \(sources.path)")
        XCTAssertEqual(offenders, [], "use Theme.Color / Theme.appearance instead")
    }
}
