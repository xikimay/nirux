import AppKit
import ImageIO
import XCTest
@testable import Nirux

@MainActor
final class BrowserDiagnosticsTests: XCTestCase {
    func testRingKeepsTheNewest200EventsInOrder() {
        var buffer = BrowserDiagnostics()
        for index in 0..<451 {
            buffer.append(kind: index.isMultiple(of: 2) ? .error : .warn, message: String(index))
        }
        XCTAssertEqual(buffer.events.map(\.message), (251..<451).map(String.init))
        XCTAssertEqual(buffer.consoleErrorCount, 100)
    }

    func testRedactionPrecedesTruncationAndDisplay() {
        var buffer = BrowserDiagnostics()
        for message in [
            String(repeating: "a", count: 990) + " ghp_" + String(repeating: "x", count: 40),
            "Authorization: Bearer sample", "https://example.test/?token=sample"
        ] {
            buffer.append(kind: .warn, message: message)
            XCTAssertEqual(buffer.events.last?.message, "[redacted]")
        }
        buffer.append(kind: .error, message: "a\n\u{202e}b" + String(repeating: "🪲", count: 500))
        XCTAssertEqual(buffer.events.last?.message, "a  b" + String(repeating: "🪲", count: 255))
    }

    func testCaptureQuotaPermissionsAndEmbeddedMetadataAreScopedToWorkspace() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let workspace = UUID().uuidString
        let other = UUID().uuidString
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                              bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let url = URL(string: "https://user:pass@example.test:8080/app?token=secret#secret")
        let capture = BrowserCapture(url: url, timestamp: Date(timeIntervalSince1970: 1000),
                                     viewport: CGSize(width: 300, height: 250), consoleErrorCount: 3)
        func save(_ id: String) throws -> URL { try capture.save(image, workspaceID: id, stateDirectory: root) }
        let sibling = try save(other)
        let first = try save(workspace)
        let folder = root.appendingPathComponent("captures").appendingPathComponent(workspace)
        XCTAssertEqual(first.deletingLastPathComponent().path, folder.path)
        for _ in 1...20 { _ = try save(workspace) }
        XCTAssertFalse(manager.fileExists(atPath: first.path))
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: folder.path).count, 20)
        XCTAssertTrue(manager.fileExists(atPath: sibling.path))
        for (url, mode) in [(folder.deletingLastPathComponent(), 0o700), (folder, 0o700), (sibling, 0o600)] {
            XCTAssertEqual(try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, mode)
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(sibling as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let png = try XCTUnwrap(properties[kCGImagePropertyPNGDictionary as String] as? [String: Any])
        let json = try XCTUnwrap(png[kCGImagePropertyPNGDescription as String] as? String)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(BrowserCapture.self, from: Data(json.utf8))
        XCTAssertEqual(saved.url, "https://example.test:8080/app")
        XCTAssertEqual(saved.timestamp, capture.timestamp)
        XCTAssertEqual(saved.viewport, capture.viewport)
        XCTAssertEqual(saved.consoleErrorCount, 3)
        XCTAssertThrowsError(try save("../" + workspace))
        let alias = UUID().uuidString
        try manager.createSymbolicLink(at: folder.deletingLastPathComponent().appendingPathComponent(alias), withDestinationURL: folder)
        XCTAssertThrowsError(try save(alias))
    }
}
