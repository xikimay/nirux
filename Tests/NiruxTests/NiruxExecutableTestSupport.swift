import XCTest

extension XCTestCase {
    /// The Nirux binary built with these tests, for tests that run it the
    /// way agents do (hooks, the status line).
    func niruxExecutable() throws -> String {
        let url = Bundle(for: type(of: self)).bundleURL.deletingLastPathComponent().appendingPathComponent("Nirux")
        return try XCTUnwrap(
            FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil,
            "Nirux executable not found at \(url.path)"
        )
    }
}
