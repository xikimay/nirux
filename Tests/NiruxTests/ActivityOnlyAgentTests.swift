import XCTest
@testable import Nirux

/// Gemini CLI and OpenCode: recognized by process name, with no hooks.
final class ActivityOnlyAgentTests: XCTestCase {
    private let isAgent = AgentStatusMachine.isRecognizedAgentProcess
    private var machine = AgentStatusMachine()
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func entry(
        _ pid: pid_t, parent: pid_t, group: pid_t, foreground: pid_t = 10,
        name: String, _ arguments: [String]
    ) -> ProcessSnapshot.Entry {
        .init(
            pid: pid, parentPID: parent, processGroupID: group,
            terminalForegroundProcessGroupID: foreground,
            name: name, startedAt: TimeInterval(pid), arguments: arguments
        )
    }

    // MARK: - Process names

    func testRuntimeFlagsBeforeAnAgentScriptAreSkipped() {
        let bin = "/Users/me/.nvm/versions/node/v24.13.1/bin"
        // Gemini CLI's `#!/usr/bin/env -S node --no-warnings=DEP0040` shebang.
        XCTAssertEqual(ProcessSnapshot.execName(from: ["node", "--no-warnings=DEP0040", "\(bin)/gemini"]), "gemini")
        // Its relaunched child, spawned from `process.execPath`.
        XCTAssertEqual(ProcessSnapshot.execName(from: [
            "\(bin)/node", "--no-warnings=DEP0040", "--max-old-space-size=24576", "\(bin)/gemini", "--yolo"
        ]), "gemini")
        // A shell alias: `alias gemini="node --no-deprecation $(which gemini)"`.
        XCTAssertEqual(ProcessSnapshot.execName(from: ["node", "--no-deprecation", "\(bin)/gemini"]), "gemini")
        XCTAssertEqual(ProcessSnapshot.execName(from: ["node", "\(bin)/gemini"]), "gemini")
        XCTAssertEqual(ProcessSnapshot.execName(from: ["node", "--no-deprecation", "\(bin)/claude"]), "claude")
    }

    func testOtherFlaggedRuntimeLaunchesKeepTheRuntimeName() {
        // The first bare argument after `-r` is the flag's value, not the
        // script: only an agent name is trusted there.
        XCTAssertEqual(ProcessSnapshot.execName(from: ["node", "-r", "dotenv/config", "server.js"]), "node")
        XCTAssertEqual(ProcessSnapshot.execName(from: ["node", "--inspect", "server.js"]), "node")
        XCTAssertEqual(ProcessSnapshot.execName(from: ["python3", "-m", "http.server"]), "python3")
        XCTAssertEqual(ProcessSnapshot.execName(from: ["node", "--version"]), "node")
        XCTAssertEqual(ProcessSnapshot.execName(from: ["node", "server.js"]), "server")
    }

    func testNativeOpencodeKeepsItsName() {
        XCTAssertEqual(ProcessSnapshot.execName(from: ["opencode"]), "opencode")
        XCTAssertEqual(ProcessSnapshot.execName(from: ["/Users/me/.opencode/bin/opencode", "run"]), "opencode")
    }

    func testFlaggedGeminiIsTheForegroundAgentAndADescendant() {
        let gemini = ["node", "--no-warnings=DEP0040", "/opt/homebrew/bin/gemini"]
        let child = ["/opt/homebrew/bin/node", "--no-warnings=DEP0040", "--max-old-space-size=8192",
                     "/opt/homebrew/bin/gemini"]
        let running = ProcessSnapshot(entries: [
            entry(10, parent: 1, group: 10, foreground: 20, name: "zsh", ["zsh"]),
            entry(20, parent: 10, group: 20, foreground: 20, name: "node", gemini),
            entry(21, parent: 20, group: 20, foreground: 20, name: "node", child)
        ])
        XCTAssertEqual(running.foregroundProcess(shellPID: 10)?.name, "gemini")
        XCTAssertEqual(running.firstDescendantName(of: 10, where: isAgent), "gemini")

        // ^Z, then the launcher died: only its relaunched child is left.
        let orphanedChild = ProcessSnapshot(entries: [
            entry(10, parent: 1, group: 10, foreground: 10, name: "zsh", ["zsh"]),
            entry(21, parent: 10, group: 20, foreground: 10, name: "node", child)
        ])
        XCTAssertEqual(orphanedChild.foregroundProcess(shellPID: 10)?.name, "zsh")
        XCTAssertEqual(orphanedChild.firstDescendantName(of: 10, where: isAgent), "gemini")
    }

    // MARK: - Status

    /// Gemini CLI and OpenCode have no hooks: the same output-activity
    /// cycle, where an unrecognized process (`node`) stays idle.
    func testActivityOnlyAgentsFollowTheFallbackCycle() {
        for name in ["gemini", "opencode"] {
            machine = AgentStatusMachine()
            XCTAssertEqual(machine.tick(fgName: name, isUserFocused: false, now: t0), .idle, name)
            machine.noteUserInput(now: t0 + 5)
            machine.noteRead(now: t0 + 6)
            XCTAssertEqual(machine.tick(fgName: name, isUserFocused: false, now: t0 + 6.5), .working, name)
            XCTAssertEqual(machine.tick(fgName: name, isUserFocused: false, now: t0 + 20), .needsAttention, name)
            XCTAssertNil(machine.attentionReason, "silence can't tell a finished turn from a prompt")
            XCTAssertEqual(machine.tick(fgName: name, isUserFocused: true, now: t0 + 21), .idle, name)
        }
        machine = AgentStatusMachine()
        _ = machine.tick(fgName: "node", isUserFocused: false, now: t0)
        machine.noteUserInput(now: t0 + 5)
        machine.noteRead(now: t0 + 6)
        XCTAssertEqual(machine.tick(fgName: "node", isUserFocused: false, now: t0 + 6.5), .idle)
    }

    func testActivityOnlyAgentTakingOverDropsClaudesDialogs() {
        // claude died without SessionEnd, leaving a dialog; gemini now owns
        // the terminal.
        _ = machine.tick(fgName: "claude", isUserFocused: false, now: t0)
        _ = machine.apply(AgentHookEvent(kind: .claude, name: .permissionRequest), isUserFocused: false)
        XCTAssertEqual(machine.pendingDialogs.count, 1)
        _ = machine.tick(fgName: "gemini", isUserFocused: false, now: t0 + 1)
        XCTAssertTrue(machine.pendingDialogs.isEmpty)
        XCTAssertEqual(machine.state, .idle)
    }

    // MARK: - Capabilities

    func testRecognizedButNotARemotePromptTarget() {
        for name in ["gemini", "opencode"] {
            XCTAssertTrue(AgentStatusMachine.isRecognizedAgentProcess(name), name)
            XCTAssertTrue(AgentStatusMachine.activityOnlyAgentProcesses.contains(name), name)
        }
        XCTAssertTrue(AgentStatusMachine.activityOnlyAgentProcesses.isDisjoint(with: AgentStatusMachine.integratedAgentProcesses))
        XCTAssertFalse(AgentStatusMachine.isRecognizedAgentProcess("node"))
    }

    func testRemotePromptsReachOnlyIntegratedAgents() {
        XCTAssertTrue(AgentStatusMachine.acceptsRemotePrompts(processName: "claude"))
        XCTAssertTrue(AgentStatusMachine.acceptsRemotePrompts(processName: "codex"))
        // Recognized, but without hooks Nirux can't see their permission
        // prompts: a remote prompt could answer one blindly.
        XCTAssertFalse(AgentStatusMachine.acceptsRemotePrompts(processName: "gemini"))
        XCTAssertFalse(AgentStatusMachine.acceptsRemotePrompts(processName: "opencode"))
        XCTAssertFalse(AgentStatusMachine.acceptsRemotePrompts(processName: "zsh"))
    }

    // MARK: - Close confirmation

    func testCloseAlertNamesTheAgentWithoutTrustingItsIdle() {
        let gemini = WorkspaceClosePolicy.LiveAgent(processName: "gemini", machineStatus: .idle, hookKind: nil)
        XCTAssertEqual(gemini.displayName, "Gemini")
        XCTAssertNil(gemini.status, "the fallback reads idle through silent tool calls")
        let opencode = WorkspaceClosePolicy.LiveAgent(processName: "opencode", machineStatus: .working, hookKind: nil)
        XCTAssertEqual(opencode.displayName, "OpenCode")
        XCTAssertEqual(opencode.status, .working)
        XCTAssertEqual(
            WorkspaceClosePolicy.columnConfirmation(for: gemini),
            ["Gemini is running — closing the column ends its session."]
        )
        XCTAssertEqual(
            WorkspaceClosePolicy.columnConfirmation(for: opencode),
            ["OpenCode is working — closing the column ends its session."]
        )
    }
}
