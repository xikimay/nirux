import XCTest
@testable import Nirux

/// How ⌘P shows a recorded session (see SessionHistory), and which column
/// holds a session a Resume must not start twice.
final class SessionHistoryTests: XCTestCase {
    private func record(
        name: String? = nil, workspaceTitle: String? = nil, branch: String? = nil,
        cwd: String? = nil, pullRequest: AgentSessionRecord.PullRequest? = nil, lastActivityAt: TimeInterval = 1000
    ) -> AgentSessionRecord {
        var record = AgentSessionRecord(
            schemaVersion: 1, agent: .claude, sessionID: "s1", startedAt: 0, lastStartAt: 0,
            lastActivityAt: lastActivityAt, endedAt: lastActivityAt, status: .idle, hasConversation: true
        )
        record.name = name
        record.workspaceTitle = workspaceTitle
        record.cwd = cwd
        record.pullRequest = pullRequest
        record.checkout = branch.map {
            AgentSessionRecord.Checkout(branch: $0, worktreeRoot: "/repos/app.feat-x", mainCheckout: "/repos/app")
        }
        return record
    }

    func testTheTitleIsTheLaunchNameThenTheWorkspaceThenTheBranchThenTheFolder() {
        XCTAssertEqual(SessionHistory.title(of: record(name: "feat/x · web", workspaceTitle: "ws", branch: "feat/x")), "feat/x · web")
        XCTAssertEqual(SessionHistory.title(of: record(name: " ", workspaceTitle: "billing", branch: "feat/x")), "billing")
        XCTAssertEqual(SessionHistory.title(of: record(branch: "feat/x", cwd: "/repos/other")), "feat/x")
        XCTAssertEqual(SessionHistory.title(of: record(cwd: "/repos/other")), "other")
        XCTAssertEqual(SessionHistory.title(of: record()), "Claude session")
    }

    /// When, the branch unless the title names it, the pull request, the
    /// checkout's folder (rather than the cwd inside it).
    func testTheSubtitleSaysWhenWhereAndWhichPullRequest() {
        let merged = AgentSessionRecord.PullRequest(number: 112, url: "https://github.com/o/r/pull/112", state: "MERGED")
        let session = record(workspaceTitle: "billing", branch: "feat/x", cwd: "/repos/app.feat-x/Sources", pullRequest: merged)
        XCTAssertEqual(
            SessionHistory.subtitle(of: session, now: 1000 + 3 * 3600) { "~" + $0 },
            "3 h ago · feat/x · #112 merged · ~/repos/app.feat-x"
        )
        let named = record(name: "feat/x · web", branch: "feat/x", lastActivityAt: 1000)
        XCTAssertEqual(SessionHistory.subtitle(of: named, now: 1030) { $0 }, "just now · /repos/app.feat-x")
        // A title that merely contains the branch doesn't name it; a
        // detached checkout has none.
        XCTAssertEqual(SessionHistory.subtitle(of: record(name: "maintenance", branch: "main"), now: 1000) { $0 },
                       "just now · main · /repos/app.feat-x")
        XCTAssertEqual(SessionHistory.subtitle(of: record(name: "x", branch: "HEAD"), now: 1000) { $0 }, "just now · /repos/app.feat-x")
    }

    func testAgo() {
        XCTAssertEqual(SessionHistory.ago(-5), "just now")
        XCTAssertEqual(SessionHistory.ago(59), "just now")
        XCTAssertEqual(SessionHistory.ago(60), "1 min ago")
        XCTAssertEqual(SessionHistory.ago(3599), "59 min ago")
        XCTAssertEqual(SessionHistory.ago(3600), "1 h ago")
        XCTAssertEqual(SessionHistory.ago(86_399), "23 h ago")
        XCTAssertEqual(SessionHistory.ago(86_400), "yesterday")
        XCTAssertEqual(SessionHistory.ago(2 * 86_400), "2 days ago")
    }

    func testTheSearchCoversTheBranchWorkspaceFolderAndPullRequest() {
        let pullRequest = AgentSessionRecord.PullRequest(number: 7, url: "", state: "OPEN")
        let candidate = SessionHistory.candidate(of: record(
            name: "feat/x · web", workspaceTitle: "billing", branch: "feat/x", pullRequest: pullRequest
        ))
        XCTAssertEqual(candidate, PaletteRanking.Candidate(
            title: "feat/x · web", keys: ["feat/x", "billing", "app.feat-x", "#7"]
        ))
    }

    // MARK: - Held sessions

    /// The column that runs a session, before one that will (going there
    /// would resume it through Claude's picker), before one whose agent
    /// died on it.
    func testTheColumnRunningASessionHoldsItFirst() {
        let running = UUID()
        let restored = UUID()
        let exited = UUID()
        let holders = [
            AgentSessionHolder(workspaceID: "c", columnID: exited, exitedSessionID: "s1"),
            AgentSessionHolder(workspaceID: "b", columnID: restored, deferredSessionID: "s1"),
            AgentSessionHolder(workspaceID: "a", columnID: running, liveText: ["claude", "--resume", "s1"])
        ]
        XCTAssertEqual(HeldAgentSession.find("s1", in: holders), HeldAgentSession(workspaceID: "a", columnID: running, state: .running))
        XCTAssertEqual(
            HeldAgentSession.find("s1", in: Array(holders.prefix(2))),
            HeldAgentSession(workspaceID: "b", columnID: restored, state: .restored)
        )
        XCTAssertEqual(
            HeldAgentSession.find("s1", in: Array(holders.prefix(1))),
            HeldAgentSession(workspaceID: "c", columnID: exited, state: .exited)
        )
        XCTAssertNil(HeldAgentSession.find("s2", in: holders))
        XCTAssertNil(HeldAgentSession.find("", in: holders))
    }

    /// An id names a session as an argument of its own, never inside
    /// another word.
    func testAnArgumentMentionsASessionWholly() {
        let id = "0b5e33d2-6a8f-4c43-9d3e-2f1c7a9b8e10"
        XCTAssertTrue(AgentSessionHolder.mentions(id, in: ["claude", "--resume", id]))
        XCTAssertTrue(AgentSessionHolder.mentions(id, in: ["claude", "--resume=" + id.uppercased()]))
        XCTAssertFalse(AgentSessionHolder.mentions(id, in: ["tail", "-f", "/x/\(id).jsonl"]))
        XCTAssertFalse(AgentSessionHolder.mentions("1", in: ["claude", "--resume", id]))
        XCTAssertFalse(AgentSessionHolder.mentions("", in: [""]))
    }

    func testADeferredAgentResumesASessionOnlyWithItsID() {
        XCTAssertEqual(DeferredAgentLaunch.Agent.claude(resume: .session("s1"), mode: .default).sessionID, "s1")
        XCTAssertEqual(DeferredAgentLaunch.Agent.codex(resume: .session("t1"), mode: .default).sessionID, "t1")
        XCTAssertNil(DeferredAgentLaunch.Agent.claude(resume: .picker, mode: .default).sessionID)
        XCTAssertNil(DeferredAgentLaunch.Agent.claude(resume: nil, mode: .default).sessionID)
    }

    @MainActor
    func testALaunchHoldsItsColumnForAWhile() {
        let state = SessionResumeState()
        let column = ColumnState(url: "about:blank")
        let other = ColumnState(url: "about:blank")
        state.noteLaunch(of: "s1", in: column, now: 100)
        XCTAssertEqual(state.launchedSession(in: column, now: 100 + SessionResumeState.launchGrace), "s1")
        XCTAssertNil(state.launchedSession(in: other, now: 100))
        XCTAssertNil(state.launchedSession(in: column, now: 100.5 + SessionResumeState.launchGrace))
        // Another launch in the same column replaces it.
        state.noteLaunch(of: "s2", in: column, now: 110)
        XCTAssertEqual(state.launchedSession(in: column, now: 110), "s2")
    }
}

/// What the Session History panel lists and says it will do (see
/// SessionHistoryPanel).
final class SessionHistoryPanelModelTests: XCTestCase {
    private func record(_ id: String, title: String, agent: AgentHookEvent.Kind = .claude, branch: String = "feat/x") -> AgentSessionRecord {
        var record = AgentSessionRecord(
            schemaVersion: 1, agent: agent, sessionID: id, startedAt: 0, lastStartAt: 0,
            lastActivityAt: 1, endedAt: 1, status: .idle, hasConversation: true
        )
        record.name = title
        record.checkout = AgentSessionRecord.Checkout(branch: branch, worktreeRoot: "/repos/app.x", mainCheckout: "/repos/app")
        return record
    }

    private let first = "0b5e33d2-6a8f-4c43-9d3e-2f1c7a9b8e10"
    private let second = "1c6f44e3-7b9a-4d54-8e4f-3a2d8b0c9f21"

    private func ended(_ record: AgentSessionRecord) -> SessionHistoryRow {
        SessionHistoryRow(record: record, held: nil, place: nil)
    }

    /// With text, a title the query names comes before a looser match, even
    /// an older one; the agent's name isn't searched (its switch is).
    func testTheTextRanksLikeThePalette() {
        let rows = [ended(record(first, title: "build-lint", branch: "x")), ended(record(second, title: "billing", branch: "y"))]
        XCTAssertEqual(
            SessionHistory.filtered(rows, by: SessionHistoryFilter(text: "bill")).map { SessionHistory.title(of: $0.record) },
            ["billing", "build-lint"]
        )
        XCTAssertEqual(SessionHistory.filtered(rows, by: SessionHistoryFilter(text: "  ")), rows)
        XCTAssertEqual(SessionHistory.filtered(rows, by: SessionHistoryFilter(text: "claude")), [])
    }

    func testTheSwitchesFilterByPullRequestAndAgent() {
        var withPR = record(first, title: "a")
        withPR.pullRequest = AgentSessionRecord.PullRequest(number: 1, url: "", state: "OPEN")
        let codex = record(second, title: "b", agent: .codex)
        let rows = [ended(withPR), ended(codex)]
        XCTAssertEqual(SessionHistory.filtered(rows, by: SessionHistoryFilter(pullRequest: .with)), [ended(withPR)])
        XCTAssertEqual(SessionHistory.filtered(rows, by: SessionHistoryFilter(pullRequest: .without)), [ended(codex)])
        XCTAssertEqual(SessionHistory.filtered(rows, by: SessionHistoryFilter(agent: .codex)), [ended(codex)])
    }

    /// Held sessions first, each part in the order given (newest first);
    /// an id a launch line can't hold is left out.
    func testHeldSessionsComeFirst() {
        let column = UUID()
        let held = HeldAgentSession(workspaceID: "w", columnID: column, state: .running)
        let rows = SessionHistory.rows(
            [record(first, title: "newer"), record("--forged", title: "forged"), record(second, title: "older")],
            holder: { $0.sessionID == self.second ? held : nil },
            place: { _ in "repo › Claude" },
            liveState: { _, _ in .working }
        )
        XCTAssertEqual(rows.map { SessionHistory.title(of: $0.record) }, ["older", "newer"])
        XCTAssertEqual(rows.first?.place, "repo › Claude")
        XCTAssertEqual(rows.first?.liveState, .working)
        XCTAssertNil(rows.last?.liveState)
        XCTAssertEqual(rows.map(\.isOpen), [true, false])
    }

    func testTheOutcomeSaysWhatReturnDoes() {
        let session = record(first, title: "x")
        let restored = SessionHistoryRow(
            record: session, held: HeldAgentSession(workspaceID: "w", columnID: UUID(), state: .restored), place: "repo › Claude"
        )
        let goTo = SessionHistory.outcome(of: restored, plan: nil) { $0 }
        XCTAssertEqual(goTo.action, "Go to repo › Claude")
        XCTAssertEqual(goTo.detail, "Its agent resumes there.")

        let ended = SessionHistoryRow(record: session, held: nil, place: nil)
        XCTAssertEqual(SessionHistory.outcome(of: ended, plan: nil) { $0 }.action, "Resume")
        let recreated = SessionHistory.outcome(of: ended, plan: .success(AgentSessionResume.Plan(
            place: .recreatedWorktree(mainCheckout: "/repos/app", ref: "feat/x"), directory: "/repos/app.x", warning: "Careful."
        ))) { $0 }
        XCTAssertEqual(recreated.action, "Bring the worktree back at /repos/app.x, then resume (asks first)")
        XCTAssertEqual(recreated.detail, "Careful.")
        XCTAssertTrue(recreated.isWarning)
        let gone = SessionHistory.outcome(of: ended, plan: .failure(.transcriptGone)) { $0 }
        XCTAssertFalse(gone.isPossible)
        XCTAssertEqual(gone.detail, SessionHistory.message(.transcriptGone, agent: .claude))
    }
}
