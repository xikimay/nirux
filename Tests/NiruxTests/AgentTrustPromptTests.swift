import XCTest
@testable import Nirux

/// The trust question Claude Code and Codex ask in a new folder, before any
/// hook (AgentTrustPrompt): read on screen, it waits on the user until a key
/// or a hook reaches the agent.
final class AgentTrustPromptTests: XCTestCase {
    private let started: TimeInterval = 1_000

    private func agent(_ name: String = "claude", pid: pid_t = 42, startedAt: TimeInterval? = nil) -> ForegroundProcess {
        ForegroundProcess(instance: ProcessInstance(pid: pid, startedAt: startedAt ?? started), name: name, arguments: [])
    }

    private func hook(at time: TimeInterval) -> AgentHookEvent {
        AgentHookEvent(kind: .claude, name: .sessionStart, sessionID: "s", timestamp: time)
    }

    func testEachAgentsTrustScreenIsRecognized() {
        // Claude Code 2.1's rows, its border and a wrapped line included.
        let claude = """
        ╭──────────────────────────────────────────────╮
        │ Accessing workspace:
        │
        │ /Users/me/Nirux Tasks/Compare two libraries
        │
        │ Quick safety check: Is this a project you created or one you trust? (Like your own code, a
        │ well-known open source project, or work from your team).
        │
        │ ❯ 1. Yes, I trust this folder
        │   2. No, exit
        """
        XCTAssertTrue(AgentTrustPrompt.isShown(in: claude))
        let codex = """
        > Trust this folder?
          Codex can read, edit, and run files here, subject to your permission settings.

        › 1. Yes, continue
          2. No, quit
        """
        XCTAssertTrue(AgentTrustPrompt.isShown(in: codex))
        // A row soft-wrapped between words, or in one.
        XCTAssertTrue(AgentTrustPrompt.isShown(in: "Quick safety\ncheck: …\n❯ 1. Yes, I trust\nthis folder"))
        XCTAssertTrue(AgentTrustPrompt.isShown(in: "❯ 1. Yes, I trus\nt this folder\n  2. No, exit"))
        // A short terminal: the answers alone.
        XCTAssertTrue(AgentTrustPrompt.isShown(in: "│ ❯ 1. Yes, I trust this folder\n│   2. No, exit\n╰────╯"))
        // A conversation quoting one phrase isn't the screen.
        XCTAssertFalse(AgentTrustPrompt.isShown(in: "Claude shows “Yes, I trust this folder”: answer it once."))
        XCTAssertFalse(AgentTrustPrompt.isShown(in: "> Trust this folder?"))
        XCTAssertFalse(AgentTrustPrompt.isShown(in: ""))
    }

    func testNiruxLooksOnlyAtANewAgentNothingReachedYet() {
        var machine = AgentStatusMachine()
        let claude = agent()
        XCTAssertTrue(machine.watchesForTrustPrompt(foreground: claude, now: started + 1))
        XCTAssertTrue(machine.watchesForTrustPrompt(foreground: agent("codex"), now: started + 1))
        for other in ["zsh", "gemini"] {
            XCTAssertFalse(machine.watchesForTrustPrompt(foreground: agent(other), now: started + 1), other)
        }
        XCTAssertFalse(machine.watchesForTrustPrompt(foreground: nil, now: started + 1))
        XCTAssertFalse(machine.watchesForTrustPrompt(foreground: claude, now: started + AgentTrustPrompt.watchWindow), "the question comes first")

        // Seen asking: no need to look again.
        machine.noteTrustPrompt(shown: true, foreground: claude, now: started + 2)
        XCTAssertFalse(machine.watchesForTrustPrompt(foreground: claude, now: started + 3))

        // A key went in since it started: the user is there.
        var typed = AgentStatusMachine()
        typed.noteKeystroke(now: Date(timeIntervalSince1970: started + 1))
        XCTAssertFalse(typed.watchesForTrustPrompt(foreground: claude, now: started + 2))
        // The command that launched it was typed before: no answer.
        var launched = AgentStatusMachine()
        launched.noteKeystroke(now: Date(timeIntervalSince1970: started - 0.01))
        XCTAssertTrue(launched.watchesForTrustPrompt(foreground: claude, now: started + 2))

        // A hook came: it went past any question.
        var hooked = AgentStatusMachine()
        _ = hooked.apply(hook(at: started + 1), isUserFocused: false)
        XCTAssertFalse(hooked.watchesForTrustPrompt(foreground: claude, now: started + 2))
    }

    /// The question comes first: a screen read without it, ten times, ends
    /// the watch (a Codex has no hook to). A read with no screen counts
    /// for nothing; another agent starts afresh.
    func testNiruxStopsLookingOnceTheScreenShowedSomethingElse() {
        var machine = AgentStatusMachine()
        let codex = agent("codex")
        for read in 0..<AgentTrustPrompt.maxMisses {
            XCTAssertTrue(machine.watchesForTrustPrompt(foreground: codex, now: started + 1), "read \(read)")
            machine.noteTrustPrompt(shown: false, foreground: codex, now: started + 1)
            machine.noteTrustPrompt(shown: nil, foreground: codex, now: started + 1)
        }
        XCTAssertFalse(machine.watchesForTrustPrompt(foreground: codex, now: started + 2))
        XCTAssertTrue(machine.watchesForTrustPrompt(foreground: agent("codex", pid: 43, startedAt: started + 3), now: started + 4))
        var unread = AgentStatusMachine()
        for _ in 0..<AgentTrustPrompt.maxMisses * 2 { unread.noteTrustPrompt(shown: nil, foreground: codex, now: started + 1) }
        XCTAssertTrue(unread.watchesForTrustPrompt(foreground: codex, now: started + 2), "no surface yet: nothing read")
    }

    func testTheQuestionWaitsOnTheUserUntilAKeyOrAHook() {
        var machine = AgentStatusMachine()
        let claude = agent()
        machine.noteTrustPrompt(shown: true, foreground: claude, now: started + 2)
        XCTAssertEqual(machine.visibleTrustPrompt(foreground: claude)?.seenAt, started + 2)
        XCTAssertEqual(
            machine.blockedWait(now: started + 3, foreground: claude), AgentWait(reason: AgentTrustPrompt.reason, since: started + 2),
            "the column header and ⌘J see it"
        )
        // Another agent in front now: not its question.
        XCTAssertNil(machine.visibleTrustPrompt(foreground: agent(pid: 43, startedAt: started + 5)))
        XCTAssertNil(machine.visibleTrustPrompt(foreground: nil))

        var gone = machine
        gone.noteTrustPrompt(shown: false, foreground: claude, now: started + 4)
        XCTAssertNil(gone.visibleTrustPrompt(foreground: claude), "read again without it")

        var answered = machine
        answered.noteKeystroke(now: Date(timeIntervalSince1970: started + 10))
        XCTAssertNil(answered.visibleTrustPrompt(foreground: claude))
        XCTAssertNil(answered.blockedWait(now: started + 11, foreground: claude))

        var trusted = machine
        _ = trusted.apply(hook(at: started + 10), isUserFocused: false)
        XCTAssertNil(trusted.visibleTrustPrompt(foreground: claude))
    }
}
