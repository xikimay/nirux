import AppKit
import XCTest
@testable import Nirux

/// Each Claude turn end writes where its task stands, in a few words, on
/// the task's row: its own Sonnet call, apart from the turn-end verdict.
@MainActor
final class TurnStatusLineTests: XCTestCase {
    // MARK: - The model's answer

    func testAnswerIsItsFirstLine() {
        let read = ClaudeTurnStatusWriter.status(fromAnswer:)
        XCTAssertEqual(read("fix pushed, CI green"), .line("fix pushed, CI green"))
        XCTAssertEqual(read("S: PR #41 merged."), .line("PR #41 merged"), "no label, no final period")
        XCTAssertEqual(read(" \n“tests fail on CI”\nThe tests fail because…"), .line("tests fail on CI"), "the first line only")
        XCTAssertEqual(read("**waits on merge go-ahead**"), .line("waits on merge go-ahead"))
        XCTAssertEqual(read("still thinking..."), .line("still thinking..."))
        XCTAssertEqual(read("-"), .unchanged)
        XCTAssertEqual(read("S: -"), .unchanged)
        XCTAssertEqual(read("—"), .unchanged)
        XCTAssertEqual(read("–"), .unchanged)
        XCTAssertEqual(read(String(repeating: "word ", count: 40)).map { if case .line(let text) = $0 { text.count } else { 0 } },
                       ClaudeTurnStatusWriter.maxLength, "cut")
        XCTAssertNil(read(""))
        XCTAssertNil(read(" \n \"\" "))
    }

    /// Its run: Sonnet, its own prompt, the message on standard input.
    func testRunAsksSonnetWithItsOwnPrompt() async throws {
        let seen = Locked<(arguments: [String], input: String)?>(nil)
        let writer = ClaudeTurnStatusWriter(
            checkSetup: { .ready(BranchReview.ClaudeCLI(path: "/bin/echo")) },
            runProcess: { _, arguments, input in
                seen.value = (arguments, String(decoding: input, as: UTF8.self))
                return BoundedProcess.Outcome(
                    standardOutput: Data([
                        #"{"type":"system","subtype":"init","apiKeySource":"none"}"#,
                        #"{"type":"result","is_error":false,"result":"S: fix pushed, CI green."}"#
                    ].joined(separator: "\n").utf8),
                    standardError: Data(), terminationStatus: 0, stop: nil
                )
            }
        )
        writer.prepare()
        let deadline = Date().addingTimeInterval(10)
        while !writer.knowsSetup, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let status = await writer.status(of: "Pushed the fix; CI is green.")
        XCTAssertEqual(status, .line("fix pushed, CI green"))
        let run = try XCTUnwrap(seen.value)
        let model = try XCTUnwrap(run.arguments.firstIndex(of: "--model"))
        XCTAssertEqual(run.arguments[model + 1], "claude-sonnet-5-5")
        let prompt = try XCTUnwrap(run.arguments.firstIndex(of: "--system-prompt"))
        XCTAssertEqual(run.arguments[prompt + 1], ClaudeTurnStatusWriter.systemPrompt)
        XCTAssertNotEqual(ClaudeTurnStatusWriter.systemPrompt, ClaudeTurnEndClassifier.systemPrompt)
        XCTAssertEqual(run.input, "<message>\nPushed the fix; CI is green.\n</message>")
    }

    // MARK: - At a turn end

    private let t0: TimeInterval = 1_700_000_000

    private func event(_ name: AgentHookEvent.Name, at offset: TimeInterval, message: String? = nil, uuid: String?) -> AgentHookEvent {
        AgentHookEvent(kind: .claude, name: name, agentUUID: uuid, sessionID: "s", finalMessage: message, timestamp: t0 + offset)
    }

    /// A column whose Claude took a prompt, and the center that routes to
    /// it, watched by the user or not; the clock just after its events.
    private func task(watched: Bool) throws -> (
        center: AgentHookCenter, workspace: WorkspaceState, resolution: AgentHookCenter.Resolution, uuid: String,
        alerts: Locked<[AgentAttentionReason?]>
    ) {
        let workspace = WorkspaceState(title: "ws", cwd: NSTemporaryDirectory())
        let column = try XCTUnwrap(workspace.columns.first)
        let uuid = try XCTUnwrap(column.agentUUID)
        let alerts = Locked<[AgentAttentionReason?]>([])
        // Never the notification center: it aborts a test run.
        column.onAgentAttention = { alerts.value.append($0) }
        let resolution = AgentHookCenter.Resolution(
            workspace: workspace, column: column, columnIndex: 0, isUserFocused: watched, approvalHold: .never
        )
        let center = AgentHookCenter()
        let start = t0
        center.now = { start + 10 }
        center.resolver = { _ in resolution }
        center.apply(event(.sessionStart, at: 0, uuid: uuid), to: resolution)
        center.apply(event(.userPromptSubmit, at: 1, uuid: uuid), to: resolution)
        return (center, workspace, resolution, uuid, alerts)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Every turn end of the main thread gets its line: watched or not,
    /// ending on a question or not, with the alert option off.
    func testEveryTurnEndGetsALine() async throws {
        for (watched, message) in [(true, "Pushed the fix."), (false, "Pushed the fix."), (true, "PR #41 is green. Merge it?")] {
            let (center, workspace, resolution, uuid, _) = try task(watched: watched)
            let writer = FakeWriter(.line("fix pushed, CI green"))
            center.turnStatusWriter = writer
            var landed: [WorkspaceState] = []
            center.onTurnStatus = { landed.append($0) }
            center.apply(event(.stop, at: 5, message: message, uuid: uuid), to: resolution)
            try await waitFor { !landed.isEmpty }
            XCTAssertEqual(writer.messages.value, [message])
            XCTAssertEqual(workspace.turnStatusLine, "fix pushed, CI green")
            XCTAssertTrue(landed.first === workspace, "its row and the state file learn it")
        }
    }

    /// The column reads the message for the verdict only: with the alert
    /// option off, the turn alerts at once, as before.
    func testTheColumnReadsTheMessageForTheVerdictOnly() throws {
        let (center, _, resolution, uuid, alerts) = try task(watched: false)
        center.turnStatusWriter = FakeWriter(.unchanged)
        let outcome = center.apply(event(.stop, at: 5, message: "Pushed the fix.", uuid: uuid), to: resolution)
        XCTAssertNil(outcome.turnEnd, "no verdict waited for")
        XCTAssertEqual(alerts.value, [.turnFinished])

        let (classifying, _, classified, classifiedUUID, classifiedAlerts) = try task(watched: false)
        classifying.turnStatusWriter = FakeWriter(.unchanged)
        classifying.turnEndClassifier = UnansweringClassifier()
        let read = classifying.apply(event(.stop, at: 5, message: "Pushed the fix.", uuid: classifiedUUID), to: classified)
        XCTAssertNotNil(read.turnEnd)
        XCTAssertEqual(classifiedAlerts.value, [], "the verdict decides")
    }

    /// No run for a Stop that isn't the column's last turn end (one older
    /// than the last prompt), for one replayed at launch, for one a later
    /// turn end put behind in the same drain, for the Lead, nor with the
    /// option off.
    func testNoRunForATurnEndBehindReplayedOrTheLeads() async throws {
        let (center, workspace, resolution, uuid, _) = try task(watched: true)
        let writer = FakeWriter(.line("fix pushed"))
        center.turnStatusWriter = writer
        center.apply(event(.stop, at: 0.5, message: "Old.", uuid: uuid), to: resolution)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(writer.messages.value, [], "older than the last prompt")
        let start = t0
        center.now = { start + 5 + AgentHookCenter.turnDoneFreshness }
        center.apply(event(.stop, at: 5, message: "Replayed.", uuid: uuid), to: resolution)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(writer.messages.value, [], "replayed at launch")
        center.now = { start + 10 }
        center.apply(event(.userPromptSubmit, at: 6, uuid: uuid), to: resolution)
        center.apply(event(.stop, at: 7, message: "Behind.", uuid: uuid), to: resolution)
        center.apply(event(.userPromptSubmit, at: 7.5, uuid: uuid), to: resolution)
        center.apply(event(.stop, at: 8, message: "Last.", uuid: uuid), to: resolution)
        try await waitFor { workspace.turnStatusLine != nil }
        XCTAssertEqual(writer.messages.value, ["Last."])

        let (leadCenter, lead, leadResolution, leadUUID, _) = try task(watched: false)
        lead.isLead = true
        leadCenter.turnStatusWriter = writer
        leadCenter.apply(event(.stop, at: 5, message: "Lead.", uuid: leadUUID), to: leadResolution)
        center.turnStatusWriter = nil
        center.apply(event(.userPromptSubmit, at: 8.5, uuid: uuid), to: resolution)
        center.apply(event(.stop, at: 9, message: "Off.", uuid: uuid), to: resolution)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(writer.messages.value, ["Last."], "its row has no status line")
    }

    /// While its run goes, a turn end shows no line from an older turn;
    /// "-" keeps the line it had; no answer (a rest, a full run queue, the
    /// option turned off meanwhile) leaves none until the next turn.
    func testATurnEndShowsItsOwnLineOrNone() async throws {
        let (center, workspace, resolution, uuid, _) = try task(watched: true)
        var landed = 0
        center.onTurnStatus = { _ in landed += 1 }
        center.turnStatusWriter = FakeWriter(.line("tests fail on CI"))
        center.apply(event(.stop, at: 2, message: "Tests fail.", uuid: uuid), to: resolution)
        try await waitFor { landed == 1 }

        center.turnStatusWriter = FakeWriter(.line("fix pushed, CI green"), delay: 0.3)
        center.apply(event(.userPromptSubmit, at: 3, uuid: uuid), to: resolution)
        center.apply(event(.stop, at: 4, message: "Fixed.", uuid: uuid), to: resolution)
        XCTAssertNil(workspace.turnStatusLine, "not the former turn's")
        XCTAssertEqual(workspace.statusLine, "tests fail on CI", "the resting line, meanwhile")
        try await waitFor { landed == 2 }
        XCTAssertEqual(workspace.turnStatusLine, "fix pushed, CI green")

        center.turnStatusWriter = FakeWriter(.unchanged)
        center.apply(event(.userPromptSubmit, at: 5, uuid: uuid), to: resolution)
        center.apply(event(.stop, at: 6, message: "It's the cache.", uuid: uuid), to: resolution)
        try await waitFor { landed == 3 }
        XCTAssertEqual(workspace.turnStatusLine, "fix pushed, CI green")

        center.turnStatusWriter = FakeWriter(nil)
        center.apply(event(.userPromptSubmit, at: 7, uuid: uuid), to: resolution)
        center.apply(event(.stop, at: 8, message: "Merged.", uuid: uuid), to: resolution)
        try await waitFor { landed == 4 }
        XCTAssertNil(workspace.turnStatusLine)
        XCTAssertEqual(workspace.lastSummary, "fix pushed, CI green", "still the panel's last summary")

        center.turnStatusWriter = FakeWriter(.line("PR #41 merged"), delay: 0.3)
        center.apply(event(.userPromptSubmit, at: 9, uuid: uuid), to: resolution)
        center.apply(event(.stop, at: 9.5, message: "Merged.", uuid: uuid), to: resolution)
        center.turnStatusWriter = nil
        try await waitFor { landed == 5 }
        XCTAssertNil(workspace.turnStatusLine)

        // A turn end with no message to read (another account, a headless
        // run): the line from before says nothing of it.
        center.turnStatusWriter = FakeWriter(.line("PR #41 merged"))
        center.apply(event(.userPromptSubmit, at: 10, uuid: uuid), to: resolution)
        center.apply(event(.stop, at: 10.5, message: "Merged.", uuid: uuid), to: resolution)
        try await waitFor { landed == 6 }
        center.apply(event(.userPromptSubmit, at: 11, uuid: uuid), to: resolution)
        center.apply(event(.stop, at: 11.5, uuid: uuid), to: resolution)
        XCTAssertNil(workspace.turnStatusLine)
        XCTAssertNil(workspace.statusLine)
    }

    // MARK: - On the task

    /// The newest turn end's run decides, whatever order the runs end in;
    /// a newer Codex report wins over an older Claude run; the user's own
    /// summary is never replaced, and never said beside a finished turn's
    /// check.
    func testNewestTurnDecidesAndTheUsersSummaryStays() {
        let workspace = WorkspaceState(title: "ws", cwd: NSTemporaryDirectory())
        XCTAssertNil(workspace.statusLine)
        XCTAssertTrue(workspace.awaitTurnStatus(turnEndedAt: 10))
        XCTAssertTrue(workspace.settleTurnStatus(.line("tests fail on CI"), turnEndedAt: 10))
        XCTAssertEqual(workspace.statusLine, "tests fail on CI")
        XCTAssertFalse(workspace.awaitTurnStatus(turnEndedAt: 5), "older than one known")
        XCTAssertTrue(workspace.awaitTurnStatus(turnEndedAt: 12))
        XCTAssertTrue(workspace.awaitTurnStatus(turnEndedAt: 14))
        XCTAssertFalse(workspace.settleTurnStatus(.line("fix in progress"), turnEndedAt: 12), "put behind")
        XCTAssertNil(workspace.turnStatusLine, "the newest turn's is on its way")
        XCTAssertTrue(workspace.settleTurnStatus(.line("fix pushed, CI green"), turnEndedAt: 14))
        XCTAssertEqual(workspace.lastSummary, "fix pushed, CI green", "the context panel's summary")

        XCTAssertTrue(workspace.awaitTurnStatus(turnEndedAt: 20))
        workspace.recordAgentActivity(at: 21, automaticSummary: "Codex: I updated the parser and the tests now pass.")
        XCTAssertNil(workspace.statusLine, "Codex's message as it came")
        XCTAssertFalse(workspace.settleTurnStatus(.line("parser half done"), turnEndedAt: 20), "older than Codex's report")
        XCTAssertTrue(workspace.lastSummary?.hasPrefix("Codex") == true)

        workspace.lastSummary = "Ships Friday\nthen the import side"
        workspace.lastSummaryIsManual = true
        workspace.lastSummaryIsStatus = false
        XCTAssertTrue(workspace.awaitTurnStatus(turnEndedAt: 40))
        XCTAssertTrue(workspace.settleTurnStatus(.line("PR merged"), turnEndedAt: 40))
        XCTAssertEqual(workspace.statusLine, "Ships Friday then the import side", "the user's, on one line")
        XCTAssertNil(workspace.turnStatusLine, "never as a turn's outcome")
    }

    func testLineAndOptionAreKept() throws {
        let workspace = PersistedWorkspace(
            title: "ws", cwd: "/tmp", columns: [], focusedColumnIndex: 0, lastSummary: "PR #41 merged", lastSummaryIsStatus: true
        )
        let decoded = try JSONDecoder().decode(PersistedWorkspace.self, from: JSONEncoder().encode(workspace))
        XCTAssertTrue(decoded.lastSummaryIsStatus)
        XCTAssertEqual(decoded.lastSummary, "PR #41 merged")
        let plain = try JSONEncoder().encode(PersistedWorkspace(title: "ws", cwd: "/tmp", columns: [], focusedColumnIndex: 0))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("lastSummaryIsStatus"), "written only when true")
        XCTAssertFalse(try JSONDecoder().decode(PersistedWorkspace.self, from: plain).lastSummaryIsStatus)

        func option(in json: String) throws -> Bool {
            try JSONDecoder().decode(PersistedSettings.self, from: Data(json.utf8)).showTurnStatus
        }
        XCTAssertTrue(try option(in: "{}"), "on by default")
        XCTAssertTrue(try JSONDecoder().decode(PersistedSettings.self, from: Data("{}".utf8)).showCatchUp, "the catch-up too")
        XCTAssertFalse(try option(in: #"{"alertOnlyWhenClaudeAsks":false}"#), "whoever kept final messages from a model")
        XCTAssertTrue(try option(in: #"{"alertOnlyWhenClaudeAsks":false,"showTurnStatus":true}"#))
        var settings = PersistedSettings()
        settings.showTurnStatus = false
        XCTAssertFalse(try JSONDecoder().decode(PersistedSettings.self, from: JSONEncoder().encode(settings)).showTurnStatus)
    }

    /// VoiceOver hears what the grey check shows.
    func testFinishedTurnsLineSaysDoneToVoiceOver() throws {
        let column = ColumnInfo(
            index: 0, processName: "claude", abbreviatedCwd: nil, isFocused: false, isWebView: false, webTitle: nil,
            terminalTitle: nil, agentStatus: .needsAttention, isEditor: false, editorFileName: nil, attentionReason: .turnFinished
        )
        var info = WorkspaceInfo(
            id: "ws", index: 0, title: "checkout", profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: 1, focusedColumn: 0, gitBranch: "feat/checkout", notification: nil, isActive: false,
            columns: [column], prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil,
            phase: .active, lastSummary: nil, lastActivityAt: nil
        )
        info.statusLine = "fix pushed, CI green"
        info.turnStatusLine = "fix pushed, CI green"
        let views = SidebarWorkspaceCardRenderer(workspace: info, sidebarWidth: 260, yOffset: 500).render().views
        let line = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.stringValue == "fix pushed, CI green" })
        XCTAssertEqual(line.accessibilityLabel(), "Done: fix pushed, CI green")
    }

    /// The title's tooltip says the last summary when the row doesn't.
    func testTitleTooltipSaysTheSummaryTheRowDoesNot() throws {
        func tooltip(statusLine: String?) throws -> String {
            var info = WorkspaceInfo(
                id: "ws", index: 0, title: "checkout", profileID: WorkspaceProfile.defaultID, isInactive: false,
                columnCount: 0, focusedColumn: 0, gitBranch: "feat/checkout", notification: nil, isActive: false,
                columns: [], prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil,
                phase: .active, lastSummary: "fix pushed, CI green", lastActivityAt: nil
            )
            info.statusLine = statusLine
            let views = SidebarWorkspaceCardRenderer(workspace: info, sidebarWidth: 260, yOffset: 500).render().views
            return try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.stringValue == "checkout" }?.toolTip)
        }
        XCTAssertTrue(try tooltip(statusLine: nil).contains("Last: fix pushed, CI green"))
        XCTAssertFalse(try tooltip(statusLine: "fix pushed, CI green").contains("Last:"), "the row says it")
    }
}

/// Answers its status, after a delay if asked, and records what it read.
private final class FakeWriter: TurnStatusWriter, @unchecked Sendable {
    let answer: TurnStatus?
    let delay: TimeInterval
    let messages = Locked<[String]>([])

    init(_ answer: TurnStatus?, delay: TimeInterval = 0) {
        self.answer = answer
        self.delay = delay
    }

    func status(of message: String) async -> TurnStatus? {
        messages.value.append(message)
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        return answer
    }
}

/// A classifier whose verdict never comes.
private final class UnansweringClassifier: TurnEndClassifier, @unchecked Sendable {
    func classify(_ message: String) async -> TurnEndVerdict {
        try? await Task.sleep(for: .seconds(60))
        return .unknown
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
