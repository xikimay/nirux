import XCTest
@testable import Nirux

/// Antigravity's status through OSC 7501, as agy 1.5.12 sent it when probed.
final class AgentProgramStatusTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func status(_ state: AgentProgramStatus.State, kind: String? = nil, _ message: String? = nil) -> AgentProgramStatus {
        AgentProgramStatus(state: state, kind: kind, message: message)
    }

    // MARK: - Reading

    func testSequencesAreReadForAntigravityOnly() {
        var scanner = AgentProgramStatus.Scanner()
        let output = "text\u{1b}]7501;state=blocked:kind=permission:app=antigravity:msg=QXBwcm92ZSBCYXNoOiBlY2hvIG5pcnV4LXByb2Jl\u{07}more"
            + "\u{1b}]7501;state=done:app=antigravity:msg=b2s=\u{1b}\\"
            + "\u{1b}]7501;state=working:app=claude-code\u{07}\u{1b}]7501;?\u{07}\u{1b}]7501;state=thinking:app=antigravity\u{07}"
        XCTAssertEqual(scanner.statuses(in: output), [
            status(.blocked, kind: "permission", "Approve Bash: echo nirux-probe"),
            status(.done, "ok")
        ])
        XCTAssertFalse(scanner.isWaiting)
    }

    func testASequenceCutBetweenTwoReadsIsReadWhole() {
        var scanner = AgentProgramStatus.Scanner()
        XCTAssertEqual(scanner.statuses(in: "\u{1b}]7501;state=blocked:kind=quest"), [])
        XCTAssertTrue(scanner.isWaiting)
        XCTAssertEqual(
            scanner.statuses(in: "ion:app=antigravity:msg=V2hpY2ggY29sb3IgZG8geW91IHByZWZlcj8=\u{07}"),
            [status(.blocked, kind: "question", "Which color do you prefer?")]
        )
        XCTAssertFalse(scanner.isWaiting)
        // Cut in its prefix, even right after the escape.
        XCTAssertEqual(scanner.statuses(in: "out\u{1b}]75"), [])
        XCTAssertEqual(scanner.statuses(in: "01;state=working:app=antigravity\u{07}"), [status(.working)])
        XCTAssertEqual(scanner.statuses(in: "out\u{1b}"), [])
        XCTAssertEqual(scanner.statuses(in: "]7501;state=idle:app=antigravity\u{07}"), [status(.idle)])
        // A long answer: its state, without the rest of its text.
        let long = String(repeating: "QUFB", count: AgentProgramStatus.Scanner.maxCarry)
        XCTAssertEqual(scanner.statuses(in: AgentProgramStatus.prefix + "state=done:app=antigravity:msg=" + long), [])
        XCTAssertEqual(scanner.statuses(in: long + "\u{07}"), [status(.done)])
        XCTAssertFalse(scanner.isWaiting)
    }

    func testEachStateSaysWhyItWaits() {
        XCTAssertEqual(status(.blocked, kind: "permission", "Trust this folder?").attentionReason, .permission(tool: nil, summary: "Trust this folder?"))
        XCTAssertEqual(status(.blocked, kind: "question", "Red or blue?").attentionReason, .question("Red or blue?"))
        XCTAssertEqual(status(.blocked, kind: "auth", "Sign in required").attentionReason, .message("Sign in required"))
        XCTAssertEqual(status(.done, "ok").attentionReason, .turnFinished)
        XCTAssertEqual(status(.error, "quota").attentionReason, .apiError(kind: nil, detail: "quota"))
        XCTAssertNil(status(.working).attentionReason)
        XCTAssertNil(status(.idle).attentionReason)
    }

    func testNiruxTerminalsAskAgyForIt() {
        let environment = WorkspaceState.makeTerminalEnvironment(
            profileID: "p", workspaceID: "w", agentUUID: "a", missionID: nil,
            missionHandoffsEnabled: false, executablePath: nil, launchID: "l"
        )
        XCTAssertEqual(environment["AGY_CLI_OSC7501"], "on")
    }

    // MARK: - Status

    func testAgySaysWhatItDoesAndWhyItWaits() {
        var machine = AgentStatusMachine()
        _ = machine.tick(fgName: "agy", isUserFocused: false, now: t0)
        // Every launch signs in for a moment: nothing to say.
        XCTAssertNil(machine.noteProgramStatus(status(.blocked, kind: "auth", "Sign in required"), isUserFocused: false, now: t0))
        XCTAssertNil(machine.noteProgramStatus(status(.idle), isUserFocused: false, now: t0 + 1))
        XCTAssertEqual(machine.tick(fgName: "agy", isUserFocused: false, now: t0 + 2), .idle)
        XCTAssertNil(machine.noteProgramStatus(status(.working), isUserFocused: false, now: t0 + 3))
        XCTAssertEqual(machine.tick(fgName: "agy", isUserFocused: false, now: t0 + 4), .working)
        let approve = status(.blocked, kind: "permission", "Approve Bash: echo hi")
        XCTAssertEqual(machine.noteProgramStatus(approve, isUserFocused: false, now: t0 + 5), .permission(tool: nil, summary: "Approve Bash: echo hi"))
        XCTAssertNil(machine.noteProgramStatus(approve, isUserFocused: false, now: t0 + 6), "said once")
        // Its dialog waits on the user, seen or not, and ⌘J goes to it.
        XCTAssertEqual(machine.tick(fgName: "agy", isUserFocused: true, now: t0 + 7), .needsAttention)
        XCTAssertEqual(machine.attentionReason, .permission(tool: nil, summary: "Approve Bash: echo hi"))
        let agy = ForegroundProcess(instance: ProcessInstance(pid: 42, startedAt: t0.timeIntervalSince1970), name: "agy", arguments: [])
        XCTAssertEqual(
            machine.blockedWait(now: t0.timeIntervalSince1970 + 7, foreground: agy),
            AgentWait(reason: .permission(tool: nil, summary: "Approve Bash: echo hi"), since: t0.timeIntervalSince1970 + 5)
        )
        _ = machine.noteProgramStatus(status(.working), isUserFocused: false, now: t0 + 8)
        XCTAssertEqual(machine.tick(fgName: "agy", isUserFocused: false, now: t0 + 8.5), .working)
        XCTAssertEqual(machine.noteProgramStatus(status(.done, "ok"), isUserFocused: false, now: t0 + 9), .turnFinished)
        XCTAssertEqual(machine.tick(fgName: "agy", isUserFocused: false, now: t0 + 10), .needsAttention)
        XCTAssertEqual(machine.tick(fgName: "agy", isUserFocused: true, now: t0 + 11), .idle, "seen")
        // A redraw may say it again: still seen.
        XCTAssertNil(machine.noteProgramStatus(status(.done, "ok"), isUserFocused: false, now: t0 + 12))
        XCTAssertEqual(machine.tick(fgName: "agy", isUserFocused: false, now: t0 + 13), .idle, "seen once is enough")
    }

    /// What the user watches ends without an alert, as Claude's does; the
    /// turn's clock runs through its approvals.
    func testAgyInSightNeverAlertsAndItsTurnKeepsItsClock() {
        var machine = AgentStatusMachine()
        _ = machine.tick(fgName: "agy", isUserFocused: true, now: t0)
        _ = machine.noteProgramStatus(status(.working), isUserFocused: true, now: t0 + 1)
        XCTAssertNil(machine.noteProgramStatus(status(.blocked, kind: "permission", "Approve Bash: ls"), isUserFocused: true, now: t0 + 2))
        _ = machine.noteProgramStatus(status(.working), isUserFocused: true, now: t0 + 3)
        XCTAssertEqual(machine.turnStartedAt, t0.timeIntervalSince1970 + 1)
        XCTAssertNil(machine.noteProgramStatus(status(.done, "ok"), isUserFocused: true, now: t0 + 4))
        XCTAssertEqual(machine.tick(fgName: "agy", isUserFocused: true, now: t0 + 5), .idle)
    }

    /// A status Nirux missed can't hold a column working: past a minute of
    /// silence its output says more. A restarted terminal forgets it.
    func testAMissedStatusYieldsToTheOutput() {
        var machine = AgentStatusMachine()
        _ = machine.tick(fgName: "agy", isUserFocused: false, now: t0)
        _ = machine.noteProgramStatus(status(.working), isUserFocused: false, now: t0 + 1)
        XCTAssertEqual(machine.tick(fgName: "agy", isUserFocused: false, now: t0 + 30), .working)
        XCTAssertNotEqual(machine.tick(fgName: "agy", isUserFocused: false, now: t0 + 62), .working)
        XCTAssertNil(machine.programStatus, "its next working is a new turn's")
        _ = machine.noteProgramStatus(status(.error, "quota"), isUserFocused: false, now: t0 + 63)
        let agy = ForegroundProcess(instance: ProcessInstance(pid: 42, startedAt: t0.timeIntervalSince1970), name: "agy", arguments: [])
        XCTAssertEqual(machine.blockedWait(now: t0.timeIntervalSince1970 + 64, foreground: agy)?.reason, .apiError(kind: nil, detail: "quota"))
        machine.reset()
        XCTAssertNil(machine.programStatus)
    }

    func testASignInThatLastsNeedsTheUser() {
        var machine = AgentStatusMachine()
        _ = machine.tick(fgName: "agy", isUserFocused: false, now: t0)
        _ = machine.noteProgramStatus(status(.blocked, kind: "auth", "Sign in required"), isUserFocused: false, now: t0)
        XCTAssertEqual(machine.tick(fgName: "agy", isUserFocused: false, now: t0 + 2), .idle)
        XCTAssertEqual(machine.tick(fgName: "agy", isUserFocused: false, now: t0 + 6), .needsAttention)
        XCTAssertEqual(machine.attentionReason, .message("Sign in required"))
    }

    /// The trust question comes as agy starts, before the heartbeat sees it
    /// in front: it still alerts, and goes once agy does.
    func testAStatusBeforeTheHeartbeatSeesAgyAlertsAndGoesWithIt() {
        var machine = AgentStatusMachine()
        _ = machine.tick(fgName: "zsh", isUserFocused: false, now: t0)
        let trust = status(.blocked, kind: "permission", "Trust this folder?")
        XCTAssertEqual(machine.noteProgramStatus(trust, isUserFocused: false, now: t0 + 1), .permission(tool: nil, summary: "Trust this folder?"))
        XCTAssertEqual(machine.tick(fgName: "agy", isUserFocused: false, now: t0 + 2), .needsAttention)
        XCTAssertEqual(machine.tick(fgName: "zsh", isUserFocused: false, now: t0 + 3), .idle)
        XCTAssertNil(machine.programStatus)
    }
}
