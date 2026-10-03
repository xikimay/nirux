import CryptoKit
import XCTest

/// CI doesn't build JavaScript: `pierre-diff.bundle.js` is committed, built
/// by Web/pierre-diff/build.sh, which records the SHA-256 of its sources and
/// of the bundle in Web/pierre-diff/SHA256SUMS. A source edited without a
/// rebuild, or a bundle rebuilt or edited without its sources, fails here.
final class PierreDiffBundleTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let advice = "run Web/pierre-diff/build.sh, and commit the bundle with its sources and SHA256SUMS"

    func testBundleAndSourcesMatchTheRecordedHashes() throws {
        let recorded = try Self.recordedHashes()
        XCTAssertEqual(recorded.keys.sorted(), [
            "Sources/Nirux/EditorAssets/pierre-diff.bundle.js",
            "Web/pierre-diff/build.sh",
            "Web/pierre-diff/package-lock.json",
            "Web/pierre-diff/package.json",
            "Web/pierre-diff/pierre-diff-entry.js"
        ])
        for (path, hash) in recorded.sorted(by: { $0.key < $1.key }) {
            let data = try Data(contentsOf: Self.root.appendingPathComponent(path))
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(actual, hash, "\(path) changed since its hash was recorded: \(Self.advice)")
        }
    }

    /// `shasum -a 256` lines: the hash, two spaces, the path from the root.
    private static func recordedHashes() throws -> [String: String] {
        let text = try String(contentsOf: root.appendingPathComponent("Web/pierre-diff/SHA256SUMS"), encoding: .utf8)
        var hashes: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].count == 64, parts[1].hasPrefix(" ") else {
                XCTFail("malformed SHA256SUMS line: \(line)")
                continue
            }
            hashes[String(parts[1].dropFirst())] = String(parts[0])
        }
        return hashes
    }
}
