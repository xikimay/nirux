import Foundation

/// Agent status state machine for one terminal column.
///
/// Two information sources, in decreasing order of reliability:
/// 1. **Hook events** (Claude Code hooks / Codex notify, routed via
///    `AgentHookCenter`) — exact lifecycle signals. Once a Claude session
///    proves it emits hooks, they are authoritative: `working` means a turn
///    is in flight; a dialog (PermissionRequest), `Stop` or a
///    `Notification` stops it, with the reason attached. No output
///    heuristic can misfire on redraws, spinners, or long silent tool
///    calls — except in the one stretch hooks leave silent, right after
///    the user answers a dialog (`isRunningAnsweredDialog`).
/// 2. **Output activity fallback** (agents without hooks — Codex between
///    turns, Claude sessions started before the hooks were installed):
///    recent PTY output means working; silence means the turn ended.
///
/// Pure value type with injected time — fully unit-testable. `PtySession`
/// owns one instance and feeds it reads, writes, resizes and hook events.
struct AgentStatusMachine {
    private(set) var state: AgentStatus = .idle {
        // Leaving attention ends the episode: the next one alerts again.
        didSet { if state != .needsAttention { attentionAlerted = false } }
    }
    /// The last Claude turn end, while it hasn't alerted: its verdict is on
    /// its way (`AgentHookOutcome.turnEnd`), or it came back done. The
    /// column says "done" without counting in the Dock badge (see
    /// `isQuietTurnEnd`). It lasts until the next main-thread prompt, turn
    /// end or conversation, whatever the column's status does meanwhile:
    /// the sidebar idles the focused column of a Nirux in the background,
    /// a subagent's tool call sets it working, activating Nirux idles every
    /// column, and none of these means the user read the message.
    private(set) var quietTurnEnd: QuietTurnEnd?

    enum QuietTurnEnd: Equatable {
        case pending(turnEndedAt: TimeInterval)
        case done
        /// Claude went on by itself (a tool call) before the verdict: no
        /// verdict applies to an agent at work, and the next turn end, or a
        /// prompt, alerts for this unread one as before.
        case superseded
    }

    /// The last turn end's final message asks the user something (its
    /// verdict): the message's last line, and when the turn ended. Unlike
    /// the attention, which activating Nirux clears, it lasts like an open
    /// dialog, so the sidebar, the column's header and ⌘J keep saying who
    /// waits for an answer: until the next prompt (the answer), turn end or
    /// conversation, or until the user looks at the column (`noteSeen`).
    private(set) var askedQuestion: AskedQuestion?

    struct AskedQuestion: Equatable {
        let text: String?
        let since: TimeInterval
        /// A plain yes or no answers it, and its text is the message's
        /// own (`TurnEndQuestion`).
        var isYesNo = false
    }
    /// Set by UserPromptSubmit/PreToolUse/PostToolUse, cleared by
    /// Stop/SessionEnd and by a dialog opening.
    private(set) var hookWorking = false
    /// Dialogs Claude may be showing (permission, AskUserQuestion,
    /// elicitation), oldest first. Independent of `state`: a focused
    /// column shows `.idle` while its dialog stays open. Entries leave only
    /// on hook evidence that the dialog closed — the matching tool call
    /// finishing, a new prompt, the turn or session ending — never on a
    /// guess: typed prompts are refused while any is pending, and a
    /// prompt typed into an open dialog would answer it. A manual denial
    /// fires no hook, so an entry can outlive its dialog until then.
    private(set) var pendingDialogs: [AgentPermissionRequest] = []
    /// Why the column last asked for attention (turn finished, message…);
    /// a pending dialog outranks it — see `attentionReason`.
    private var lastAttentionReason: AgentAttentionReason?
    /// The external alert went out for the current attention episode.
    private var attentionAlerted = false
    /// Epoch seconds a dialog last closed (and when it had opened), and of
    /// the event being applied.
    private var lastDialogClosedAt: TimeInterval = 0
    private var lastClosedDialogRequestedAt: TimeInterval = 0
    private(set) var lastEventAt: TimeInterval = 0
    /// Codex's last turnComplete: output before it is the finished turn's.
    private var turnEndedAt: TimeInterval = 0
    /// Claude's last main-thread turn end (Stop, StopFailure).
    private var mainTurnEndedAt: TimeInterval = 0
    /// A Stop hook kept a turn of this conversation going after its Stop
    /// (a review gate). Nothing tells a Stop that such a hook is about to
    /// block from one that ends the turn: Claude only moves again seconds
    /// later. So from then on, only a Stop that follows the hook
    /// (`stop_hook_active`) is taken for the end of its turn. The price:
    /// in such a conversation a turn the hook lets through at once shows
    /// no end, and a hook that blocks twice in a row shows one too early.
    /// Better a missing "done" than a false one.
    private var stopHooksKeepGoing = false
    /// That turn end is known to be the turn's last Stop.
    private var mainTurnEndIsLast = true
    /// Its final message ends on a question: read where there is one to
    /// read (Claude's, with the turn-end classifier on), or its verdict
    /// said it asks. Whoever looks at the column reads it there and gets
    /// no alert, but the turn isn't done.
    private var mainTurnEndAsks = false
    /// The last new conversation in this process, or its end: a quick
    /// answer never crosses one (`acceptsQuickAnswer`).
    private var conversationChangedAt: TimeInterval = 0
    /// Start of the current turn (epoch seconds): UserPromptSubmit, else
    /// the first turn event seen (a turn already running at launch). Nil
    /// between turns. Drives the "working · 12m" display.
    private(set) var turnStartedAt: TimeInterval?
    /// A turn is in flight by hook evidence alone: unlike `turnStartedAt`,
    /// which the output fallback also drives, a suspend (Ctrl-Z) and `fg`
    /// leave it as it was.
    private(set) var hookTurnInFlight = false
    /// Agent kind ("claude") once this session has emitted a hook event —
    /// proof that hooks are installed and authoritative for this session.
    private(set) var hookKind: String?
    /// Epoch seconds of the last PTY read that wasn't input echo (drives
    /// the fallback heuristic). 0 = never. Plain TimeInterval — a single
    /// aligned 8-byte store — because noteRead runs on the PTY read queue
    /// while tick reads it on the main queue; an Optional<Date> could tear.
    private(set) var lastReadAt: TimeInterval = 0
    /// Epoch seconds of the last write or resize — output within the echo
    /// window after one of these is the terminal answering the user, not
    /// agent work. 0 = never.
    private var lastInteractionAt: TimeInterval = 0
    /// Epoch seconds of the last keystroke Nirux sent (`PtySession.sendRaw`)
    /// — unlike `lastInteractionAt`, never terminal replies or resizes.
    private(set) var lastKeystrokeAt: TimeInterval = 0
    /// Every keystroke or paste, never reset by Claude's reminders: input
    /// that may have reached a shell an agent just left.
    private(set) var lastInputAt: TimeInterval = 0
    /// The same, typed while no dialog was believed open: text that may sit
    /// in the agent's prompt as a draft.
    private(set) var lastDraftInputAt: TimeInterval = 0

    /// The user has typed at least once since the shell started. Fallback
    /// attention is gated on this: output before the first keystroke is
    /// launch noise (banners, session replay, redraws), never a turn.
    private(set) var hasUserInput = false

    /// Foreground-process tracking (the isAgent gate and startup window in
    /// `tick`).
    private(set) var lastForegroundName: String?
    private(set) var foregroundSince: Date?

    /// The last turn ended on an API error (StopFailure). Unlike the
    /// attention it raised, it lasts until the agent moves again: a new
    /// prompt or tool call, another turn's end, the session's end.
    private(set) var turnFailure: AgentTurnFailure?
    /// The agent process died mid-turn (see `noteAgentExited`). Cleared by
    /// a new session, an agent back in the foreground, or the user.
    private(set) var midTurnExit: AgentMidTurnExit?
    /// `requestedAt` of the dialogs whose long wait already alerted: one
    /// alert per dialog.
    private var longWaitAlerted: Set<TimeInterval> = []
    /// The main thread's prompts: when the last one went in, and the
    /// `prompt_id`s of the current and recent ones. A StopFailure about an
    /// earlier prompt arrived late (Claude doesn't wait for it) and ends
    /// nothing; one about a prompt never seen (a turn Claude started by
    /// itself) counts.
    private(set) var lastPromptAt: TimeInterval?
    private var turnPromptID: String?
    private var recentPromptIDs: [String] = []
    /// The main agent's tool calls of the turn in flight, for the hint
    /// that it may be going in circles (`circlingHint`).
    private var circling = AgentCirclingWatch()

    private static let echoWindow: TimeInterval = 0.3
    private static let activityWindow: TimeInterval = 3.0
    /// Ignore fallback transitions right after a foreground-process change —
    /// startup output of the new command is not a completed turn either.
    private static let startupWindow: TimeInterval = 5.0
    /// An async `permission_prompt` landing this soon after a dialog closed
    /// is about that dialog — if it was open long enough for Claude's
    /// reminder (~6 s without typing) to be due.
    private static let reminderRaceWindow: TimeInterval = 3.0
    private static let reminderDelay: TimeInterval = 5.0
    /// A mid-turn exit counts once its SessionEnd, which Claude sends
    /// before exiting, has had time to arrive: the queue drains 0.15 s
    /// after a receiver writes, and a heartbeat may see the process gone
    /// first.
    static let exitConfirmationDelay: TimeInterval = 3.0
    /// Resume offers `continue` again after this long without a new turn.
    static let resumeRetryDelay: TimeInterval = 15.0

    /// Agents Nirux integrates with: lifecycle hooks (Claude Code), turn
    /// notifications (Codex), launch presets and session restore.
    static let integratedAgentProcesses: Set<String> = ["claude", "codex"]

    /// Agents recognized by foreground process name alone — no hooks, no
    /// launcher, no restore. Their status comes from the output-activity
    /// fallback in `tick`; closing their column asks first like any agent's.
    /// Names are `ProcessSnapshot.execName` results: Gemini CLI runs as
    /// `node [flags] …/gemini`, opencode as a native `opencode` binary.
    static let activityOnlyAgentProcesses: Set<String> = ["gemini", "opencode"]

    /// Central gate for local agent status, nested-hook attribution and
    /// close confirmation.
    static func isRecognizedAgentProcess(_ name: String) -> Bool {
        integratedAgentProcesses.contains(name) || activityOnlyAgentProcesses.contains(name)
    }

    /// Nirux types prompts (PR Feedback's Address, "Ask Agent Why CI
    /// Failed") only into integrated agents. Claude's hooks report the
    /// dialogs such a prompt must not answer; an activity-only agent
    /// reports nothing, so its permission prompt looks like any silence and
    /// a prompt could land on it. (Codex's notify reports turn ends only —
    /// the same blind spot, accepted before this tier existed.)
    static func acceptsTypedPrompts(processName name: String) -> Bool {
        integratedAgentProcesses.contains(name)
    }

    /// The turn end an agent reported at `time` (Claude's Stop, Codex's
    /// turn-complete) is done, as far as hooks can tell, and still stands:
    /// the column may show it as finished (a sweep of light). Not while
    /// its verdict is on its way, not when its final message asks the user
    /// something or the turn failed, not while a dialog is open, and not
    /// once the agent moved again. Not either for a Stop that may not be
    /// the end (see `stopHooksKeepGoing`).
    func isTurnDone(endedAt time: TimeInterval) -> Bool {
        guard time > 0, state != .working, openDialogs.isEmpty else { return false }
        // Codex reports the end of a turn, and nothing after it.
        if turnEndedAt == time { return true }
        guard mainTurnEndedAt == time, mainTurnEndIsLast, !mainTurnEndAsks, turnFailure == nil else { return false }
        switch quietTurnEnd {
        case .pending?, .superseded?: return false
        case .done?, nil: return true
        }
    }

    /// Why the column wants the user, while it does: the oldest dialog
    /// still believed open, else the last attention event's reason.
    var attentionReason: AgentAttentionReason? {
        guard state == .needsAttention else { return nil }
        // Dialogs are Claude's: a suspended claude's stay pending behind an
        // activity-only agent, but don't explain that agent's silence.
        if let lastForegroundName, Self.activityOnlyAgentProcesses.contains(lastForegroundName) {
            return lastAttentionReason
        }
        // A failed turn outranks the idle reminder that may follow it.
        return openDialogs.first?.reason ?? turnFailure?.reason ?? lastAttentionReason
    }

    /// Pending dialogs no later tool event of their agent has superseded —
    /// what the column's own status believes is on screen.
    var openDialogs: [AgentPermissionRequest] {
        pendingDialogs.filter { !$0.mayBeAnswered }
    }

    /// Name-only entry point (a hook event without payload details).
    /// Returns true when the column should alert.
    mutating func applyHook(
        _ name: AgentHookEvent.Name,
        kind: AgentHookEvent.Kind,
        source: String? = nil,
        isUserFocused: Bool
    ) -> Bool {
        apply(AgentHookEvent(kind: kind, name: name, source: source), isUserFocused: isUserFocused).firedAttention
    }

    /// Apply one hook event. `firedAttention` asks for the external alert
    /// (dock bounce, notification) once per attention episode, and only
    /// for events Claude itself alerts on: a turn's end, its notifications.
    /// A PermissionRequest shows at once in the column but leaves the alert
    /// to Claude's `permission_prompt` notification, sent ~6 s later only
    /// if the dialog is really on screen and unanswered — another
    /// PermissionRequest hook may have answered it, and nobody was asked.
    mutating func apply(_ event: AgentHookEvent, isUserFocused: Bool) -> AgentHookOutcome {
        let now = event.timestamp
        lastEventAt = now
        let waitingBefore = pendingDialogs.filter { $0.approval.map { $0.sent == nil } ?? false }
        var outcome = AgentHookOutcome()
        applyEvent(event, now: now, isUserFocused: isUserFocused, outcome: &outcome)
        // A receiver still waiting on a dialog that just closed otherwise
        // (answered at the terminal, turn over) will never get a decision.
        outcome.abandonedApprovals = waitingBefore.filter { waiting in
            waiting.approval?.requestID != event.approvalRequestID
                && !pendingDialogs.contains { $0.approval?.requestID == waiting.approval?.requestID }
        }
        return outcome
    }

    private mutating func applyEvent(
        _ event: AgentHookEvent,
        now: TimeInterval,
        isUserFocused: Bool,
        outcome: inout AgentHookOutcome
    ) {
        switch event.name {
        case .sessionStart:
            startConversation(event, isUserFocused: isUserFocused, outcome: &outcome)
        case .userPromptSubmit:
            startTurn(event, now: now, isUserFocused: isUserFocused, outcome: &outcome)
        case .preToolUse:
            hookKind = event.kind.rawValue
            noteTurnActivity(at: now)
            noteMainThreadMoved(event)
            noteProgress(of: event)
            resumeUnlessBlocked()
        case .postToolUse:
            hookKind = event.kind.rawValue
            noteTurnActivity(at: now)
            noteMainThreadMoved(event)
            // The call ran: its dialog, if it had one, was answered.
            if let key = event.toolKey,
               let index = pendingDialogs.firstIndex(where: { $0.isSameCall(key: key, as: event) }) {
                noteClosed(pendingDialogs.remove(at: index))
            }
            noteCallEnded(event, at: now)
            noteProgress(of: event)
            resumeUnlessBlocked()
        case .permissionRequest:
            hookKind = event.kind.rawValue
            noteTurnActivity(at: now)
            noteMainThreadMoved(event)
            var request = AgentPermissionRequest(
                toolName: event.toolName,
                summary: event.toolSummary,
                key: event.toolKey,
                agentID: event.agentID,
                sessionID: event.sessionID,
                requestedAt: now
            )
            if let requestID = event.approvalRequestID, let deadline = event.approvalDeadline,
               let text = event.approvalText {
                request.approval = PermissionApprovalTicket(
                    requestID: requestID, deadline: deadline, text: text, isSubagent: event.agentID != nil
                )
            }
            // The same call asked again (a plan re-proposed after "keep
            // planning"): the earlier dialog is gone.
            if let key = request.key { pendingDialogs.removeAll { $0.isSameCall(key: key, as: event) } }
            pendingDialogs.append(request)
            _ = block(for: request.reason, isUserFocused: isUserFocused, alert: false)
        case .notification:
            hookKind = event.kind.rawValue
            applyNotification(event, now: now, isUserFocused: isUserFocused, outcome: &outcome)
        case .subagentStop:
            // Its dialogs closed with it (a denial fires no hook).
            if let agentID = event.agentID {
                closeDialogs { $0.agentID == agentID }
            }
        case .stop, .stopFailure:
            applyTurnEnd(event, now: now, isUserFocused: isUserFocused, outcome: &outcome)
        case .sessionEnd:
            endTurn()
            settleQuietTurnEnd(isUserFocused: isUserFocused, outcome: &outcome)
            askedQuestion = nil
            conversationChangedAt = now
            closeDialogs { event.sessionID == nil || $0.sessionID == event.sessionID }
            lastAttentionReason = nil
            hookKind = nil
            turnFailure = nil
            // The exit was a clean one after all.
            midTurnExit = nil
            state = .idle
        case .turnComplete:
            // Codex: no working-state hooks — output fallback covers that.
            // The notify payload only marks the end of a turn.
            endTurn()
            turnEndedAt = now
            outcome.attention = .turnFinished
            outcome.firedAttention = block(for: .turnFinished, isUserFocused: isUserFocused)
        case .approvalResolved:
            applyApprovalResolution(event)
        }
    }

    private mutating func startTurn(
        _ event: AgentHookEvent,
        now: TimeInterval,
        isUserFocused: Bool,
        outcome: inout AgentHookOutcome
    ) {
        hookKind = event.kind.rawValue
        // A prompt was typed at the session's input, which no dialog of
        // it covered: they are all closed. This also frees the subagent
        // dialogs an interrupt (Esc) left behind with no hook. (Missed
        // race: a message queued earlier and sent while a background
        // subagent's dialog is up.)
        closeDialogs { $0.sessionID == event.sessionID }
        turnStartedAt = now
        hookTurnInFlight = true
        turnFailure = nil
        if event.agentID == nil {
            settleQuietTurnEnd(isUserFocused: isUserFocused, outcome: &outcome)
            askedQuestion = nil
            circling.reset()
            lastPromptAt = now
            turnPromptID = event.promptID
            if let promptID = event.promptID { recentPromptIDs = Array((recentPromptIDs + [promptID]).suffix(8)) }
        }
        resumeUnlessBlocked()
    }

    private mutating func startConversation(
        _ event: AgentHookEvent,
        isUserFocused: Bool,
        outcome: inout AgentHookOutcome
    ) {
        hookKind = event.kind.rawValue
        // Auto (mid-turn) or /compact: same conversation, no turn ends.
        guard event.source != "compact" else { return }
        // A new conversation in this process (startup, /clear, /resume):
        // whatever dialogs the old one showed are gone. `/clear` took what
        // was typed at the prompt, but fires no UserPromptSubmit.
        endTurn()
        settleQuietTurnEnd(isUserFocused: isUserFocused, outcome: &outcome)
        askedQuestion = nil
        // Another conversation may run under other hooks.
        stopHooksKeepGoing = false
        conversationChangedAt = event.timestamp
        if event.source == "clear" { lastPromptAt = event.timestamp }
        closeDialogs { _ in true }
        lastAttentionReason = nil
        turnFailure = nil
        midTurnExit = nil
        state = .idle
    }

    /// The main thread's turn ended: Stop, or StopFailure in its place when
    /// an API error ended it. Either way none of its dialogs is open. A
    /// failed turn leaves the agent at its prompt, saying so until it
    /// moves again.
    private mutating func applyTurnEnd(
        _ event: AgentHookEvent,
        now: TimeInterval,
        isUserFocused: Bool,
        outcome: inout AgentHookOutcome
    ) {
        hookKind = event.kind.rawValue
        if event.name == .stopFailure {
            // Claude reports the main thread's failures only; a subagent's
            // would end nothing of the main thread's.
            guard event.agentID == nil else { return }
            // Claude doesn't wait for StopFailure: a new prompt may have
            // started the next turn before it arrived.
            if let failed = event.promptID, failed != turnPromptID, recentPromptIDs.contains(failed) { return }
        }
        closeDialogs { $0.agentID == nil && $0.sessionID == event.sessionID }
        endTurn()
        if event.stopHookActive == true {
            // The last Stop wasn't the end: a Stop hook kept the turn going,
            // and this one ends it (read below).
            quietTurnEnd = nil
            stopHooksKeepGoing = true
        } else {
            // A turn Claude started by itself (no prompt) ended before the
            // last one's verdict.
            settleQuietTurnEnd(isUserFocused: isUserFocused, outcome: &outcome)
        }
        askedQuestion = nil
        mainTurnEndedAt = now
        mainTurnEndIsLast = event.stopHookActive == true || !stopHooksKeepGoing
        mainTurnEndAsks = event.finalMessage.map(TurnEndText.endsOnQuestion) ?? false
        turnFailure = event.name == .stopFailure
            ? AgentTurnFailure(
                kind: event.errorKind, detail: event.detail, failedAt: now,
                promptAt: lastPromptAt, emitter: event.emitterProcess
            )
            : nil
        let reason = turnFailure?.reason ?? .turnFinished
        outcome.attention = reason
        // Its final message may ask something or not: the alert waits for
        // the verdict (`applyTurnEndVerdict`). Nobody needs one while the
        // user looks at the column, and a dialog still open (a subagent's)
        // waits on the user whatever the message says.
        if turnFailure == nil, openDialogs.isEmpty, event.kind == .claude, let message = event.finalMessage,
           !isUserFocused {
            _ = block(for: reason, isUserFocused: false, alert: false)
            // The earlier turn end just alerted (`settleQuietTurnEnd`): that
            // was this episode's alert, the verdict only says why.
            if outcome.firedAttention { attentionAlerted = true }
            quietTurnEnd = .pending(turnEndedAt: now)
            outcome.turnEnd = TurnEndRequest(message: message, turnEndedAt: now)
            return
        }
        outcome.firedAttention = block(for: reason, isUserFocused: isUserFocused)
    }

    /// The last turn end is behind: a prompt went in, the conversation
    /// changed or ended, another turn ended. One not read yet (its verdict
    /// on its way, or superseded) alerts as every turn end did, unless the
    /// user looks at the column: they may not have read it (Nirux types
    /// Mission messages, a `claude -p` ends its session with its turn).
    private mutating func settleQuietTurnEnd(isUserFocused: Bool, outcome: inout AgentHookOutcome) {
        if quietTurnEnd?.isUnread == true, !isUserFocused {
            outcome.attention = .turnFinished
            outcome.firedAttention = true
        }
        quietTurnEnd = nil
    }

    /// The turn end `request` asked about still waits for its verdict.
    func awaitsVerdict(_ request: TurnEndRequest) -> Bool {
        quietTurnEnd == .pending(turnEndedAt: request.turnEndedAt)
    }

    /// The column shows a turn end that hasn't alerted (`attentionReason`
    /// is nil out of attention), and nothing else waits: no dialog, no
    /// failed turn, no other attention since.
    var isQuietTurnEnd: Bool {
        quietTurnEnd != nil && attentionReason == .turnFinished
    }

    /// The verdict on the turn end `request` asked about: the reason to
    /// alert with, or nil. A turn that asks alerts, amber; one the
    /// classifier couldn't read alerts as every turn end did; one that's
    /// done stays quiet. `isUserFocused` is now's: a user looking at the
    /// column needs no alert. Dropped once that turn end is behind (a new
    /// prompt, a later turn end, another conversation) or another attention
    /// alerted since (see `block`). A dialog opened since doesn't drop it:
    /// it may close without alerting (another hook answers it), and while
    /// it waits the user is needed anyway.
    mutating func applyTurnEndVerdict(
        _ verdict: TurnEndVerdict,
        for request: TurnEndRequest,
        isUserFocused: Bool
    ) -> AgentAttentionReason? {
        guard quietTurnEnd == .pending(turnEndedAt: request.turnEndedAt) else { return nil }
        // Settled, whichever way: nothing is left to alert for later.
        quietTurnEnd = nil
        let reason: AgentAttentionReason
        switch verdict {
        case .done:
            quietTurnEnd = .done
            return nil
        case .asks(let question):
            // The question the classifier quoted, else the one it ends on,
            // else its last line.
            let line = question?.text ?? TurnEndText.questionLine(of: request.message) ?? TurnEndText.lastLine(of: request.message)
            reason = .askedInReply(line)
            mainTurnEndAsks = true
            // A user looking at the column reads it there.
            if !isUserFocused {
                askedQuestion = AskedQuestion(text: line, since: request.turnEndedAt, isYesNo: question?.isYesNo == true)
            }
            // A question always alerts, even after this episode's "finished
            // its turn": missing one is what this is all about.
            attentionAlerted = false
        case .unknown:
            reason = .turnFinished
        }
        return block(for: reason, isUserFocused: isUserFocused) ? reason : nil
    }

    /// The question the foreground `claude` asked at its last turn end, if
    /// any: as `visibleDialog`, this very `claude`'s.
    func visibleQuestion(foreground: ForegroundProcess?) -> AskedQuestion? {
        guard let askedQuestion, let foreground, foreground.name == "claude",
              askedQuestion.since >= foreground.instance.startedAt
        else { return nil }
        return askedQuestion
    }

    /// The user looks at the column (Nirux active, the column focused):
    /// they read the question there.
    mutating func noteSeen() {
        askedQuestion = nil
    }

    /// A quick answer (Yes, No, a reply) to the turn end of `turnEndedAt`
    /// may be typed now: that turn end is still the last thing that
    /// happened (no prompt, turn end or conversation change since, the
    /// same `claude`), no keys at the prompt since the last prompt (a draft
    /// started during the turn stays there, a screen no hook tells of may
    /// be open: `hasDraft`), no dialog
    /// waits, Claude isn't working, and its terminal is quiet (a Stop
    /// hook's continuation runs its spinner before any hook says so).
    /// Anything else, and "yes" could land in a draft, a dialog or a later
    /// turn.
    func acceptsQuickAnswer(to turnEndedAt: TimeInterval, foreground: ForegroundProcess?, now: TimeInterval) -> Bool {
        guard let foreground, foreground.name == "claude", !AgentHookCenter.isHeadlessClaude(foreground),
              foreground.instance.startedAt <= turnEndedAt
        else { return false }
        return isCurrentTurnEnd(turnEndedAt) && !hasDraft && pendingDialogs.isEmpty && !hookWorking
            && now - lastReadAt >= Self.quietBeforeQuickAnswer
    }

    /// When the agent's last turn ended (Claude's main thread, or Codex's
    /// report), epoch seconds; 0 before any.
    var lastTurnEndedAt: TimeInterval { max(mainTurnEndedAt, turnEndedAt) }

    /// The turn end of `turnEndedAt` is still the last thing that happened
    /// in this conversation: no prompt, turn end or conversation since.
    /// Seen or not, its question still waits for an answer.
    func isCurrentTurnEnd(_ turnEndedAt: TimeInterval) -> Bool {
        mainTurnEndedAt == turnEndedAt && conversationChangedAt < turnEndedAt && (lastPromptAt ?? 0) < turnEndedAt
    }

    /// Output this recent says Claude draws something: its spinner at work.
    static let quietBeforeQuickAnswer: TimeInterval = 1.5

    /// The user's click types a prompt into this agent (Address PR
    /// Feedback, Why Failed): they engage with it. The turn end before is
    /// read, so the prompt alerts for nothing and a verdict on its way
    /// drops; the question it asked is behind them.
    mutating func notePromptFromUser() {
        if quietTurnEnd != nil { quietTurnEnd = .done }
        askedQuestion = nil
    }

    /// A turn end waits for its verdict: Nirux types nothing of its own
    /// into the prompt meanwhile (see `isPromptFree`). A prompt would
    /// settle it as unread, alerting for a turn the verdict may find done.
    /// A prompt the user's click sends goes in (`notePromptFromUser`).
    var awaitsAnyVerdict: Bool {
        if case .pending = quietTurnEnd { return true }
        return false
    }

    /// A main-thread tool event: the failed turn is behind.
    private mutating func noteMainThreadMoved(_ event: AgentHookEvent) {
        guard event.agentID == nil else { return }
        turnFailure = nil
        // Went on by itself (a Stop hook blocked its end, a background
        // task, a wakeup): a verdict would land on an agent at work, and
        // the question is behind it. A turn end not read yet stays owed.
        switch quietTurnEnd {
        case .pending?: quietTurnEnd = .superseded
        case .done?: quietTurnEnd = nil
        case .superseded?, nil: break
        }
        askedQuestion = nil
    }

    /// The receiver's report on a sidebar approval. A decision that
    /// reached Claude closes its dialog: Claude applied it (the call runs,
    /// or the agent reads the denial and goes on), or ignored it because
    /// the dialog was answered first. Anything else only ends the
    /// sidebar's chance to answer; the dialog stays in the terminal.
    private mutating func applyApprovalResolution(_ event: AgentHookEvent) {
        guard let requestID = event.approvalRequestID,
              let index = pendingDialogs.firstIndex(where: { $0.approval?.requestID == requestID }) else { return }
        switch event.approvalOutcome {
        case .allow?, .deny?:
            noteClosed(pendingDialogs.remove(at: index))
            resumeUnlessBlocked()
        case .release?, .expired?, .invalid?, nil:
            if pendingDialogs[index].approval?.sent != nil {
                // Said on the card for a moment: answer in the terminal.
                pendingDialogs[index].approval?.undelivered = true
            } else {
                pendingDialogs[index].approval = nil
            }
        }
    }

    /// The oldest dialog the sidebar can still answer, or whose decision
    /// is on its way: an open dialog (see `openDialogs`) whose card has
    /// something to show.
    func sidebarApproval(now: TimeInterval) -> AgentPermissionRequest? {
        openDialogs.first { $0.approval?.display(now: now) != nil }
    }

    /// Record a sidebar decision on an open request. Nil when the request
    /// can no longer be answered (closed, expired, already decided).
    mutating func markApprovalSent(
        requestID: String,
        behavior: PermissionApproval.Behavior,
        now: TimeInterval
    ) -> AgentPermissionRequest? {
        guard let index = pendingDialogs.firstIndex(where: { $0.approval?.requestID == requestID }),
              !pendingDialogs[index].mayBeAnswered,
              pendingDialogs[index].approval?.isOpen(now: now) == true else { return nil }
        pendingDialogs[index].approval?.sent = behavior
        pendingDialogs[index].approval?.sentAt = now
        return pendingDialogs[index]
    }

    /// Stop holding one request (its decision could not be sent). Returns
    /// it, ticket included, so its receiver can be released.
    mutating func dropApproval(requestID: String) -> AgentPermissionRequest? {
        guard let index = pendingDialogs.firstIndex(where: { $0.approval?.requestID == requestID }) else {
            return nil
        }
        let request = pendingDialogs[index]
        pendingDialogs[index].approval = nil
        return request
    }

    /// Drop the sidebar's hold on the requests it has not decided (those
    /// `shouldTake` picks), returning them so their receivers can be
    /// released: the terminal dialog answers.
    mutating func takeUndecidedApprovals(
        where shouldTake: (AgentPermissionRequest) -> Bool = { _ in true }
    ) -> [AgentPermissionRequest] {
        var taken: [AgentPermissionRequest] = []
        for index in pendingDialogs.indices {
            guard let ticket = pendingDialogs[index].approval, ticket.sent == nil,
                  shouldTake(pendingDialogs[index]) else { continue }
            taken.append(pendingDialogs[index])
            pendingDialogs[index].approval = nil
        }
        return taken
    }

    /// Claude notifications by `notification_type`. Informational types
    /// change nothing; untyped ones (older Claude) keep asking for
    /// attention with their message, as before types existed.
    private mutating func applyNotification(
        _ event: AgentHookEvent,
        now: TimeInterval,
        isUserFocused: Bool,
        outcome: inout AgentHookOutcome
    ) {
        let reason: AgentAttentionReason
        switch event.notificationType {
        case "auth_success", "agent_completed":
            return
        case "quota_auto_resume_fired":
            // Claude resumes the turn by itself.
            if event.agentID == nil { turnFailure = nil }
            return
        case "elicitation_complete", "elicitation_response":
            // The form was answered: its dialog is gone.
            if let index = pendingDialogs.firstIndex(where: {
                $0.isQuestion && $0.key == nil && $0.agentID == event.agentID
            }) {
                noteClosed(pendingDialogs.remove(at: index))
            }
            return
        case "permission_prompt":
            // Sent ~6 s into a dialog nobody touched — after its
            // PermissionRequest, or alone (a sandboxed command's network
            // request fires no PermissionRequest). Either way a dialog is
            // on screen and no keystroke answered it.
            lastKeystrokeAt = 0
            if let open = openDialogs.first {
                reason = open.reason
            } else if !pendingDialogs.isEmpty {
                // Every entry looked answered, yet one waits: the newest
                // (older ones were likely denied, which fires no hook).
                pendingDialogs[pendingDialogs.count - 1].mayBeAnswered = false
                reason = pendingDialogs[pendingDialogs.count - 1].reason
            } else if now - lastDialogClosedAt < Self.reminderRaceWindow,
                      now - lastClosedDialogRequestedAt >= Self.reminderDelay {
                // The hook is async: this reminder raced the close of the
                // dialog it was about (old enough for its reminder).
                return
            } else {
                reason = .permission(tool: nil, summary: event.detail)
                pendingDialogs.append(AgentPermissionRequest(
                    toolName: nil, summary: event.detail, key: nil,
                    agentID: event.agentID, sessionID: event.sessionID, requestedAt: now
                ))
            }
        case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
            lastKeystrokeAt = 0
            reason = .question(event.detail)
            pendingDialogs.append(AgentPermissionRequest(
                toolName: nil, summary: event.detail, key: nil,
                agentID: event.agentID, sessionID: event.sessionID, requestedAt: now, isQuestion: true
            ))
        case "idle_prompt":
            // Claude finished responding a minute ago: the main thread sits
            // at its prompt, not in a dialog. Its Stop said so already: the
            // reminder alerts nobody and leaves a finished turn the user
            // looked at seen. Only a turn
            // still believed running (Esc fires no Stop, a Stop can get
            // lost) ends here.
            closeDialogs { $0.agentID == nil && $0.sessionID == event.sessionID }
            guard hookTurnInFlight || hookWorking else { return }
            endTurn()
            // Esc is a key: the user stopped it. Background subagents may
            // have worked on after its Stop. Otherwise the turn's Stop got
            // lost, and this is its end.
            let promptAt = lastPromptAt ?? 0
            if lastInputAt > promptAt || mainTurnEndedAt >= promptAt {
                _ = block(for: .turnFinished, isUserFocused: isUserFocused, alert: false)
                return
            }
            reason = .turnFinished
        default:
            reason = .message(event.detail)
        }
        outcome.attention = reason
        outcome.firedAttention = block(for: reason, isUserFocused: isUserFocused)
    }

    /// The agent waits on the user: it no longer works (leave hookWorking
    /// set and the next tick would flip needsAttention straight back to
    /// `.working` while the agent sits idle). True when the external alert
    /// should go out: once per attention episode.
    private mutating func block(for reason: AgentAttentionReason, isUserFocused: Bool, alert: Bool = true) -> Bool {
        hookWorking = false
        lastAttentionReason = reason
        if isUserFocused {
            state = .idle
            return false
        }
        state = .needsAttention
        // An alerting attention (alerted now, or earlier in this episode)
        // speaks for a turn end not read yet: it needs no alert of its
        // own, nor to take this attention's reason.
        if alert, quietTurnEnd?.isUnread == true { quietTurnEnd = nil }
        guard alert, !attentionAlerted else { return false }
        attentionAlerted = true
        return true
    }

    /// A tool event from an agent: it got past its dialogs — answered, or
    /// denied, which fires no hook. The status believes it; the gate on
    /// prompts Nirux types keeps the entries until proof (a call can run
    /// beside an open dialog). Claude's `permission_prompt` reopens them if
    /// one still waits.
    private mutating func noteProgress(of event: AgentHookEvent) {
        for index in pendingDialogs.indices
        where pendingDialogs[index].agentID == event.agentID && pendingDialogs[index].sessionID == event.sessionID {
            // A request the sidebar holds is unanswered: its column was
            // never on screen, where the terminal could answer it. This
            // event is a sibling call's.
            if pendingDialogs[index].approval?.isHeld(at: event.timestamp) == true { continue }
            pendingDialogs[index].mayBeAnswered = true
        }
    }

    /// A tool event: the agent works — unless a dialog still waits. Other
    /// subagents keep calling tools while one waits on the user, and the
    /// column must keep saying it is blocked.
    private mutating func resumeUnlessBlocked() {
        guard openDialogs.isEmpty else { return }
        hookWorking = true
        state = .working
    }

    private mutating func closeDialogs(where shouldClose: (AgentPermissionRequest) -> Bool) {
        for dialog in pendingDialogs where shouldClose(dialog) { noteClosed(dialog) }
        pendingDialogs.removeAll(where: shouldClose)
    }

    private mutating func noteClosed(_ dialog: AgentPermissionRequest) {
        lastDialogClosedAt = lastEventAt
        lastClosedDialogRequestedAt = dialog.requestedAt
    }

    /// A turn already running when Nirux first heard of it starts here.
    private mutating func noteTurnActivity(at timestamp: TimeInterval) {
        if turnStartedAt == nil { turnStartedAt = timestamp }
        hookTurnInFlight = true
    }

    private mutating func endTurn() {
        hookWorking = false
        turnStartedAt = nil
        hookTurnInFlight = false
        circling.reset()
    }

    /// The agent may be going in circles in the turn in flight: its
    /// commands keep hanging, or one keeps failing (see
    /// `AgentCirclingHint`). Shown while the column works.
    var circlingHint: AgentCirclingHint? { circling.hint }

    /// A tool call ended, for `circlingHint`. The main agent's only: a
    /// subagent's calls say nothing of it, nor does the bookkeeping of
    /// background commands. A shell command counts with those of its
    /// program, unless it counts by its exact text; any other tool with its
    /// exact repeats (the same URL, file, action: `toolKey`). An end a
    /// newer receiver wrote says nothing.
    private mutating func noteCallEnded(_ event: AgentHookEvent, at time: TimeInterval) {
        guard event.agentID == nil, let tool = event.toolName, !AgentToolOutcome.taskTools.contains(tool) else { return }
        let end = event.toolEnd.map(AgentToolEnd.init(rawValue:))
        if case .some(.none) = end { return }
        let isShell = AgentToolInput.shellTools.contains(tool)
        let exact = (isShell ? event.toolCommandKey : event.toolKey).map { "\(tool) \($0)" }
        circling.noteCallEnded(
            key: isShell ? exact ?? event.toolFamily : exact ?? tool, name: isShell ? event.toolFamily : tool, end: end ?? nil, at: time
        )
    }

    /// PTY output arrived. Echo right after a keystroke/resize is not work.
    mutating func noteRead(now: Date) {
        let timestamp = now.timeIntervalSince1970
        if lastInteractionAt > 0, timestamp - lastInteractionAt < Self.echoWindow { return }
        lastReadAt = timestamp
    }

    /// A keystroke went to the PTY — marks both the echo window and real
    /// user engagement (fallback attention only counts after this).
    mutating func noteUserInput(now: Date) {
        hasUserInput = true
        lastInteractionAt = now.timeIntervalSince1970
    }

    private static let modeSwitchKey = Data([0x1B, 0x5B, 0x5A])

    /// Arrows reached the agent without a key pressed (ghostty turns a
    /// wheel scroll into them on the alternate screen): an old prompt may be
    /// recalled at its prompt now, a draft as any other (`hasDraft`). Not a
    /// keystroke: the user scrolled, typed nothing.
    mutating func notePromptRecall(now: Date) {
        lastDraftInputAt = now.timeIntervalSince1970
    }

    /// One key's bytes: a character, or a short escape sequence (a
    /// bracketed paste is longer).
    static func isOneKey(_ keys: Data) -> Bool {
        if keys.first == 0x1B { return keys.count <= 8 }
        return String(data: keys, encoding: .utf8).map { $0.count == 1 } ?? false
    }

    /// Nirux sent typed input (keys, a paste) — the only way a dialog gets
    /// answered, which terminal replies and focus reports never do.
    mutating func noteKeystroke(now: Date, keys: Data? = nil) {
        let time = now.timeIntervalSince1970
        // A key answers a dialog only while none reached it yet: answered, it stays
        // listed until its tool ends (no hook between); later keys reach the prompt.
        let answersDialog = openDialogs.contains { $0.requestedAt >= lastKeystrokeAt }
        lastKeystrokeAt = time
        lastInputAt = time
        // A mode switch (Shift-Tab) leaves the prompt as it was; any other
        // key may leave text there, or open a screen no hook tells of (Esc
        // Esc's rewind picker, Ctrl-O's transcript, a slash command's). A
        // paste or dictation is text, whatever a dialog waits for: one key
        // answers a dialog, not a write of several.
        let oneKey = keys.map(Self.isOneKey) ?? true
        if !(answersDialog && oneKey), keys != Self.modeSwitchKey { lastDraftInputAt = time }
        // Typing at the shell an agent left: the user took over.
        midTurnExit = nil
    }

    /// The terminal resized/redrew — following output is echo, not work.
    /// Does NOT count as user engagement.
    mutating func noteInteraction(now: Date) {
        lastInteractionAt = now.timeIntervalSince1970
    }

    /// Reconcile with the foreground process (heartbeat tick). `fgName` is
    /// the foreground process name, "" when there is none; nil when the
    /// process table could not be read: nothing is known then, and nothing
    /// changes. Read as "no agent", it would drop the hook authority of a
    /// `claude` idle at its prompt, and the output fallback would take its
    /// next redraw (an idle compaction's spinner) for a turn.
    /// `claudeFiredHooks`: the `claude` in front is the very process whose
    /// own hooks reached this column.
    @discardableResult
    mutating func tick(fgName: String?, claudeFiredHooks: Bool = false, isUserFocused: Bool, now: Date) -> AgentStatus {
        guard let fgName else { return state }
        let isAgent = Self.isRecognizedAgentProcess(fgName)
        if fgName != lastForegroundName { foregroundChanged(to: fgName, now: now) }

        guard isAgent else {
            hookWorking = false
            hookKind = nil
            state = .idle
            return state
        }
        // Back in front after something else held the terminal (^Z and
        // `fg`, Ctrl-G's $EDITOR): its hooks still drive it, and the turn
        // it was in goes on.
        if claudeFiredHooks, fgName == "claude", hookKind != "claude" {
            hookKind = "claude"
            hookWorking = hookTurnInFlight && openDialogs.isEmpty
        }

        // Hook-authoritative path (Claude with installed hooks): events own
        // every transition; output silence mid-turn means nothing.
        if hookKind == "claude", fgName == "claude" {
            if hookWorking || isRunningAnsweredDialog(now: now) {
                state = .working
            } else if state == .needsAttention {
                // Hooks say why they stop an agent. A wait without a
                // reason is the output fallback's guess from before they
                // took over again: an amber "needs you" on an agent idle at
                // its prompt.
                if isUserFocused || attentionReason == nil { state = .idle }
            } else if state == .working {
                state = .idle
                // The fallback's turn, if it ran one: hooks show none.
                if !hookTurnInFlight { turnStartedAt = nil }
            }
            return state
        }

        // Fallback: recent output = working; silence ends the turn.
        // Suppressed until the user has actually engaged (first keystroke)
        // and the new foreground command has settled — startup banners,
        // session replay and redraws otherwise fabricate a working →
        // needsAttention cycle for an agent that never ran a turn.
        let settled = foregroundSince.map { now.timeIntervalSince($0) >= Self.startupWindow } ?? false
        guard hasUserInput, settled else {
            state = .idle
            turnStartedAt = nil
            return state
        }
        // Output from before Codex reported its turn over is that turn's.
        let recentlyActive = lastReadAt > turnEndedAt
            && now.timeIntervalSince1970 - lastReadAt < Self.activityWindow
        // Without turn hooks, a turn is a stretch of output.
        switch state {
        case .idle:
            if recentlyActive { startFallbackTurn(now: now) }
        case .working:
            if !recentlyActive {
                state = isUserFocused ? .idle : .needsAttention
                // Silence can be a finished turn or the agent's own
                // approval prompt: no reason to claim.
                lastAttentionReason = nil
                turnStartedAt = nil
            }
        case .needsAttention:
            if recentlyActive {
                startFallbackTurn(now: now)
            } else if isUserFocused {
                state = .idle
            }
        }
        return state
    }

    /// A different foreground command inherits nothing from the previous
    /// one — except hook capability, which stays (unless an activity-only
    /// agent takes over, see below): the hook event (SessionStart) can
    /// arrive BEFORE the next process-table snapshot notices the change,
    /// and clearing it here would knock the session back into the flaky
    /// fallback for no reason.
    private mutating func foregroundChanged(to fgName: String, now: Date) {
        lastForegroundName = fgName
        foregroundSince = now
        hookWorking = false
        lastReadAt = 0 // the old command's dying output is not this one's work
        // Nor its reason to wait — unless the new `claude`'s own hooks gave
        // it, which can come first too: a Stop while the heartbeat waited
        // with Nirux in the background.
        if fgName != "claude" || hookKind != "claude" { lastAttentionReason = nil }
        // A turn end found done, and the question asked, are behind with
        // it. One still waiting for its verdict gets it, and alerts as its
        // Stop would have: a `claude -p` or a crash leaves before its
        // SessionEnd is applied.
        if fgName != "claude" {
            if quietTurnEnd == .done { quietTurnEnd = nil }
            askedQuestion = nil
        }
        // Another integrated agent took over the terminal: a `claude` that
        // died without SessionEnd left its dialogs behind. (A shell in front
        // may just mean it's suspended; a new claude's SessionStart clears
        // them.) An activity-only agent keeps them: it may run in front of a
        // suspended claude whose dialog is back on `fg`, and they are what
        // keeps Nirux from typing a prompt into it.
        if Self.integratedAgentProcesses.contains(fgName), fgName != "claude" { pendingDialogs.removeAll() }
        // Another agent works here now: the calls of a `claude` that died
        // mid-turn (no Stop) aren't its own. A shell in front may be a
        // suspended claude's (^Z, Ctrl-G's editor), whose turn goes on.
        if Self.isRecognizedAgentProcess(fgName), fgName != "claude" { circling.reset() }
        // No hook ever drives an activity-only agent (a Claude or Codex hook
        // under it is a nested run's); a claude's leftover kind would mute
        // its OSC 9 notifications.
        if Self.activityOnlyAgentProcesses.contains(fgName) { hookKind = nil }
    }

    private mutating func startFallbackTurn(now: Date) {
        state = .working
        turnStartedAt = now.timeIntervalSince1970
    }

    /// Hooks go quiet once a dialog is answered: an approved tool fires
    /// nothing until it finishes, however long it runs. After the user
    /// typed into the column (the answer), sustained output — Claude's
    /// spinner while the tool runs — shows the column working; silence
    /// (a denial ends the turn) shows it idle. Never raises attention, and
    /// only with a single dialog open: with several, typing may have
    /// answered one while another still waits.
    private func isRunningAnsweredDialog(now: Date) -> Bool {
        let open = openDialogs
        guard open.count == 1, lastKeystrokeAt > open[0].requestedAt else { return false }
        return lastReadAt > lastKeystrokeAt
            && now.timeIntervalSince1970 - lastReadAt < Self.activityWindow
    }

    /// User saw the attention signal (focus, app activate).
    mutating func clearAttention() {
        if state == .needsAttention { state = .idle }
    }

    // MARK: - Stuck agents

    /// The column's foreground agent process is gone — exited, not
    /// suspended. A `claude` whose hooks run would have sent SessionEnd
    /// first; if its turn was still in flight, it crashed or was killed.
    /// (Codex and activity-only agents report no session end: their exit
    /// can't be told from a quit.)
    ///
    /// A keystroke since the agent was last seen alive may have reached the
    /// shell: the user is there and took over.
    mutating func noteAgentExited(_ exit: AgentMidTurnExit) {
        guard exit.processName == "claude", exit.firedHooks || hookKind == "claude", hookTurnInFlight,
              lastInputAt <= exit.lastSeenAt else { return }
        midTurnExit = exit
    }

    /// An agent is back in the foreground, or the user dealt with the exit.
    mutating func clearMidTurnExit() {
        midTurnExit = nil
    }

    /// The alert a stuck state owes, once: a dialog crossing the wait
    /// threshold (each dialog alerts once; an answered one and the next
    /// start over), an exit once confirmed. A failed turn alerted as its
    /// StopFailure arrived.
    mutating func takeStuckAlert(
        now: TimeInterval,
        waitThreshold: TimeInterval?,
        foreground: ForegroundProcess?
    ) -> AgentAttentionReason? {
        switch stuckState(now: now, waitThreshold: waitThreshold, foreground: foreground) {
        case .exitedMidTurn(let exit)?:
            guard !exit.alerted else { return nil }
            midTurnExit?.alerted = true
            return .exitedMidTurn
        case .waiting(let reason, let since)?:
            // Forget dialogs gone; each one still listed alerts once.
            longWaitAlerted.formIntersection(pendingDialogs.map(\.requestedAt))
            guard longWaitAlerted.insert(since).inserted else { return nil }
            return .stillWaiting(reason, waited: now - since)
        case .stoppedOnError?, nil:
            return nil
        }
    }

    /// `continue` is about to be typed: its own keystroke follows, and is
    /// not the user's (see `noteResumeTyped`).
    mutating func markResumeSent(now: TimeInterval) {
        turnFailure?.resumeSentAt = now
    }

    mutating func noteResumeTyped() {
        turnFailure?.resumeKeystrokeAt = lastDraftInputAt
    }

    /// New shell in the same terminal (start/restart) — everything resets.
    mutating func reset() {
        state = .idle
        quietTurnEnd = nil
        askedQuestion = nil
        hookWorking = false
        hookKind = nil
        pendingDialogs.removeAll()
        lastAttentionReason = nil
        lastDialogClosedAt = 0
        lastClosedDialogRequestedAt = 0
        lastEventAt = 0
        turnEndedAt = 0
        mainTurnEndedAt = 0
        stopHooksKeepGoing = false
        mainTurnEndIsLast = true
        mainTurnEndAsks = false
        conversationChangedAt = 0
        turnStartedAt = nil
        lastReadAt = 0
        lastInteractionAt = 0
        lastKeystrokeAt = 0
        hasUserInput = false
        lastForegroundName = nil
        foregroundSince = nil
        turnFailure = nil
        midTurnExit = nil
        longWaitAlerted = []
        lastPromptAt = nil
        turnPromptID = nil
        recentPromptIDs = []
        hookTurnInFlight = false
        lastInputAt = 0
        lastDraftInputAt = 0
        circling.reset()
    }
}

extension AgentStatusMachine.QuietTurnEnd {
    /// Not read yet: a verdict on its way, or superseded by Claude going on.
    var isUnread: Bool {
        switch self {
        case .pending, .superseded: return true
        case .done: return false
        }
    }
}
