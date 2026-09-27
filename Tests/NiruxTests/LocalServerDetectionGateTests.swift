import XCTest
@testable import Nirux

/// End to end on a real PTY: output is only scanned for dev-server URLs
/// once something was typed, so `claude --continue` transcript replays and
/// Nirux's own redraw nudges at launch never produce proposals.
final class LocalServerDetectionGateTests: XCTestCase {
    private final class Detections {
        var urls: [LocalServerURL] = []
    }

    @MainActor
    func testDetectionWaitsForTypedInputAndIgnoresTheRedrawNudge() async throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-localhost-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", stateDirectory.path, 1)
        defer {
            if let previousStateDirectory {
                setenv("NIRUX_STATE_DIR", previousStateDirectory, 1)
            } else {
                unsetenv("NIRUX_STATE_DIR")
            }
            try? FileManager.default.removeItem(at: stateDirectory)
        }

        let detections = Detections()
        let session = PtySession()
        session.onLocalServerURL = { detections.urls.append($0) }
        session.start(
            shell: "/bin/zsh",
            args: ["-f", "-c", "while true; do printf 'Local: http://localhost:4321/\\n'; sleep 0.1; done"],
            cwd: stateDirectory.path
        )

        // Printed over and over, but nobody typed anything yet.
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(detections.urls.isEmpty)

        // Nirux's Ctrl+L repaint nudge isn't typing either.
        session.sendRaw(Data([0x0C]))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(detections.urls.isEmpty)

        session.sendRaw("x")
        let deadline = Date().addingTimeInterval(3)
        while detections.urls.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(detections.urls.first?.urlString, "http://localhost:4321/")
    }
}
