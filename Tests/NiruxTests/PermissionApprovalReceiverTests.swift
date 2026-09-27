import XCTest
@testable import Nirux

/// The real hook receiver (`Nirux --hook claude`), run as Claude runs it,
/// against a temporary state directory whose marker names this test
/// process as the listening app.
final class PermissionApprovalReceiverTests: XCTestCase {
    private var stateDir: URL!
    private var channel: PermissionApprovalChannel!

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-receiver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        channel = PermissionApprovalChannel(directory: stateDir.appendingPathComponent("permission-approvals"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    private var eventsURL: URL { stateDir.appendingPathComponent("hook-events.jsonl") }

    private func niruxExecutable() throws -> String {
        let url = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Nirux")
        return try XCTUnwrap(
            FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil,
            "Nirux executable not found at \(url.path)"
        )
    }

    private struct Receiver {
        let process: Process
        let stdout: Pipe
        let exited: DispatchSemaphore
    }

    private func startReceiver(command: String = "git push origin main", session: String = "sess") throws -> Receiver {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest", "session_id": session, "cwd": "/proj",
            "tool_name": "Bash", "tool_input": ["command": command]
        ]
        let stdin = Pipe()
        let stdout = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try niruxExecutable())
        process.arguments = ["--hook", "claude"]
        process.environment = [
            "NIRUX_STATE_DIR": stateDir.path, "NIRUX_AGENT_UUID": "uuid-1", "HOME": "/Users/me",
            "PATH": "/usr/bin:/bin"
        ]
        process.standardInput = stdin
        process.standardOutput = stdout
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        stdin.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
        try stdin.fileHandleForWriting.close()
        return Receiver(process: process, stdout: stdout, exited: exited)
    }

    private func queuedEvents() -> [AgentHookEvent] {
        ((try? String(contentsOf: eventsURL, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .compactMap { try? JSONDecoder().decode(AgentHookEvent.self, from: Data($0.utf8)) }
    }

    /// The PermissionRequest the receiver queued, once it is there.
    private func queuedRequest(timeout: TimeInterval = 10) -> AgentHookEvent? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let request = queuedEvents().first(where: { $0.name == .permissionRequest }) { return request }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    private func finish(_ receiver: Receiver) throws -> (status: Int32, stdout: String) {
        guard receiver.exited.wait(timeout: .now() + 10) == .success else {
            receiver.process.terminate()
            XCTFail("receiver kept waiting")
            return (-1, "")
        }
        let output = receiver.stdout.fileHandleForReading.readDataToEndOfFile()
        return (receiver.process.terminationStatus, String(bytes: output, encoding: .utf8) ?? "<not UTF-8>")
    }

    private func listen() throws {
        XCTAssertTrue(channel.setListening(try XCTUnwrap(ProcessInstance.running(pid: getpid()))))
    }

    func testSidebarAllowReachesClaude() throws {
        try listen()
        let receiver = try startReceiver()
        let request = try XCTUnwrap(queuedRequest())
        let requestID = try XCTUnwrap(request.approvalRequestID)
        XCTAssertEqual(request.toolSummary, "git push origin main")
        let deadline = try XCTUnwrap(request.approvalDeadline)
        XCTAssertEqual(deadline - request.timestamp, PermissionApproval.mainThreadWindow, accuracy: 0.01)

        XCTAssertTrue(channel.send(PermissionApprovalDecision(
            requestID: requestID, sessionID: "sess", agentUUID: "uuid-1", behavior: .allow,
            issuedAt: Date().timeIntervalSince1970
        )))
        let (status, stdout) = try finish(receiver)
        XCTAssertEqual(status, 0)
        let output = try XCTUnwrap(PermissionApproval.hookOutput(for: .allow, isSubagent: false))
        let expected = try XCTUnwrap(String(bytes: output, encoding: .utf8))
        XCTAssertEqual(stdout, expected)

        let resolved = try XCTUnwrap(queuedEvents().last)
        XCTAssertEqual(resolved.name, .approvalResolved)
        XCTAssertEqual(resolved.approvalRequestID, requestID)
        XCTAssertEqual(resolved.approvalOutcome, .allow)
    }

    func testDecisionForAnotherSessionDecidesNothing() throws {
        try listen()
        let receiver = try startReceiver()
        let requestID = try XCTUnwrap(queuedRequest()?.approvalRequestID)
        channel.send(PermissionApprovalDecision(
            requestID: requestID, sessionID: "teammate", agentUUID: "uuid-1", behavior: .allow,
            issuedAt: Date().timeIntervalSince1970
        ))
        let (status, stdout) = try finish(receiver)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(stdout, "", "the terminal dialog stays the answer")
        XCTAssertEqual(queuedEvents().last?.approvalOutcome, .invalid)
    }

    func testReleaseLetsTheTerminalAnswer() throws {
        try listen()
        let receiver = try startReceiver()
        let requestID = try XCTUnwrap(queuedRequest()?.approvalRequestID)
        channel.send(PermissionApprovalDecision(
            requestID: requestID, sessionID: "sess", agentUUID: "uuid-1", behavior: .release,
            issuedAt: Date().timeIntervalSince1970
        ))
        let (_, stdout) = try finish(receiver)
        XCTAssertEqual(stdout, "")
        XCTAssertEqual(queuedEvents().last?.approvalOutcome, .release)
    }

    /// Option off (no marker): the receiver behaves exactly as before.
    func testWithoutTheOptionTheReceiverNeitherWaitsNorPrints() throws {
        let started = Date()
        let receiver = try startReceiver()
        let (status, stdout) = try finish(receiver)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(stdout, "")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let events = queuedEvents()
        XCTAssertEqual(events.map(\.name), [.permissionRequest])
        XCTAssertNil(events.first?.approvalRequestID)
    }

    func testCommandTheSidebarCannotShowExactlyIsNotHeld() throws {
        try listen()
        let receiver = try startReceiver(command: "echo ok\nrm -rf /tmp/x")
        let (_, stdout) = try finish(receiver)
        XCTAssertEqual(stdout, "")
        XCTAssertNil(queuedEvents().first?.approvalRequestID)
    }
}
