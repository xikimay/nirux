import Foundation
import XCTest

/// Ghostty (libghostty-spm 2.2) keeps the process environment as it found it
/// at the first terminal: a slice of libc's `environ`, read again by every
/// later terminal. Nirux changing its own environment afterwards would crash
/// the next terminal it opens (see TestBootstrap). It changes it only in a
/// shell's forked child, between `forkpty` and `execv`, whose memory is its
/// own.
final class EnvironmentGuardTests: XCTestCase {
    private let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Nirux")

    func testNiruxChangesItsEnvironmentOnlyInAForkedChild() throws {
        let call = try NSRegularExpression(pattern: #"\b(setenv|unsetenv|putenv|clearenv)\s*\("#)
        let paths = try FileManager.default.subpathsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
        var offenders: [String] = []
        for path in paths {
            let text = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
            // The child's span: from `forkpty(` to its `execv(`.
            let child: Range<String.Index>? = text.range(of: "forkpty(").flatMap { fork in
                text.range(of: "execv(", range: fork.upperBound..<text.endIndex).map { fork.lowerBound..<$0.lowerBound }
            }
            for match in call.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                if let child, child.contains(range.lowerBound) { continue }
                offenders.append("\(path):\(text[..<range.lowerBound].components(separatedBy: "\n").count)")
            }
        }
        XCTAssertGreaterThan(paths.count, 100, "found too few sources under \(sources.path)")
        XCTAssertEqual(offenders, [], "change the environment of the child you start, never Nirux's own")
    }
}
