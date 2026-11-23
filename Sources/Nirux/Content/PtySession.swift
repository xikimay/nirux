import AppKit
import Foundation
import GhosttyTerminal
import os

/// Bridges libghostty's InMemoryTerminalSession to a real PTY + shell.
/// The .inMemory backend correctly routes special keys (backspace, arrows)
/// via TerminalHardwareKeyRouter.directControlInputForAppKit.
final class PtySession: @unchecked Sendable {
    let terminalSession: InMemoryTerminalSession
    // Store fd in a sendable wrapper so closures can capture it
    private let state = PtyState()
    /// Called when the shell reports a new working directory (via OSC 7)
    var onCwdChanged: ((String) -> Void)? {
        get { state.onCwdChanged }
        set { state.onCwdChanged = newValue }
    }

    /// Called when the terminal title changes (via OSC 0/2)
    var onTitleChanged: ((String) -> Void)? {
        get { state.onTitleChanged }
        set { state.onTitleChanged = newValue }
    }

    /// Called when an OSC 9 notification is received AND this session has
    /// no hook coverage — hooked sessions get the same turn-complete signal
    /// from the Stop hook, so firing both would double-count.
    var onOsc9Received: (() -> Void)? {
        get { state.onOsc9Received }
        set { state.onOsc9Received = newValue }
    }

    /// What Antigravity or Codex reported of itself (OSC 7501), on the main
    /// queue: give it to `applyProgramStatus` or `noteCodexStatus` once it
    /// is known to come from the agent in front.
    var onProgramStatus: ((AgentProgramStatus) -> Void)? {
        get { state.onProgramStatus }
        set { state.onProgramStatus = newValue }
    }

    /// Takes in Antigravity's status: the reason to alert with, if any (see
    /// `AgentStatusMachine.noteProgramStatus`).
    func applyProgramStatus(
        _ status: AgentProgramStatus, from process: ProcessInstance?, isUserFocused: Bool
    ) -> AgentAttentionReason? {
        state.machine.noteProgramStatus(status, from: process, isUserFocused: isUserFocused, now: Date())
    }

    /// A sign-in wait past its grace, once (see
    /// `AgentStatusMachine.takeLateSignInAlert`).
    func takeLateSignInAlert(isUserFocused: Bool) -> AgentAttentionReason? {
        state.machine.takeLateSignInAlert(isUserFocused: isUserFocused, now: Date().timeIntervalSince1970)
    }

    /// Takes in Codex's status (see `AgentStatusMachine.codexQueueRefusal`).
    func noteCodexStatus(_ status: AgentProgramStatus, from process: ProcessInstance?) {
        state.machine.noteCodexStatus(status, from: process, now: Date().timeIntervalSince1970)
    }

    func codexStatus(of process: ProcessInstance) -> AgentProgramStatus? {
        guard let report = state.machine.codexStatus, report.isFrom(process) else { return nil }
        return report.status
    }

    func programStatus(of foreground: ForegroundProcess?) -> AgentProgramStatus? {
        guard let foreground else { return nil }
        switch foreground.agent {
        case .codex: return codexStatus(of: foreground.instance)
        case .agy:
            guard let report = state.machine.programStatus, report.isFrom(foreground.instance) else { return nil }
            return report.status
        default: return nil
        }
    }

    /// Called on the main queue when the output shows a local dev-server
    /// URL (`http://localhost:5173/`). Throttled per port.
    var onLocalServerURL: ((LocalServerURL) -> Void)? {
        get { state.onLocalServerURL }
        set { state.onLocalServerURL = newValue }
    }

    /// Called on the main queue when the shell process exits.
    var onProcessExit: (() -> Void)? {
        get { state.onProcessExit }
        set { state.onProcessExit = newValue }
    }

    /// True after the shell process exited. The session can be restarted
    /// with another `start(...)` call — the terminal surface (and its
    /// scrollback) survives.
    var hasExited: Bool { state.hasExited }

    /// Last applied grid size — the right starting size for a restart.
    var lastSize: (cols: Int, rows: Int) { (state.lastCols, state.lastRows) }

    /// The shell's pid while it runs.
    var shellPID: pid_t? { state.childPid > 0 ? state.childPid : nil }

    /// Start of the agent's current turn (drives the "working · 12m"
    /// display in the sidebar). Nil between turns.
    var agentTurnStartedAt: Date? {
        state.machine.turnStartedAt.map { Date(timeIntervalSince1970: $0) }
    }

    /// Why the agent waits on the user, while it does.
    var agentAttentionReason: AgentAttentionReason? { state.machine.attentionReason }

    /// The turn end the agent reported at `time` is done and still stands
    /// (see `AgentStatusMachine.isTurnDone`).
    func isAgentTurnDone(endedAt time: TimeInterval) -> Bool {
        state.machine.isTurnDone(endedAt: time)
    }

    /// See `AgentStatusMachine.circlingHint`.
    var agentCirclingHint: AgentCirclingHint? { state.machine.circlingHint }

    /// A Claude turn end that hasn't alerted (see
    /// `AgentStatusMachine.isQuietTurnEnd`): no Dock badge.
    var isQuietTurnEnd: Bool { state.machine.isQuietTurnEnd }
    /// Why Nirux may not press Esc in the agent's turn now (see
    /// `AgentStatusMachine.interruptRefusal`).
    func interruptRefusal(snapshot: ProcessSnapshot) -> AgentInterruptRefusal? {
        readTranscriptPrompts()
        return state.machine.interruptRefusal(foreground: foregroundProcess(snapshot: snapshot))
    }

    /// Esc, as the key, but no draft (see `noteInterruptSent`): the prompt
    /// whose turn it interrupts.
    func sendInterrupt() -> TimeInterval? {
        guard let promptAt = state.machine.noteInterruptSent(now: Date().timeIntervalSince1970) else { return nil }
        state.writeToPty(Data([0x1B]))
        return promptAt
    }

    /// See `AgentStatusMachine.noteInterruptIgnored`.
    func noteInterruptIgnored(promptAt: TimeInterval) {
        state.machine.noteInterruptIgnored(promptAt: promptAt)
    }

    /// Claude confirmed the interrupt of `promptAt`'s turn: it is over.
    func noteInterrupted(promptAt: TimeInterval) -> Bool {
        state.machine.noteInterrupted(promptAt: promptAt, now: Date().timeIntervalSince1970)
    }

    /// When a key or paste last reached the terminal.
    var lastInputAt: TimeInterval { state.machine.lastInputAt }
    /// The same, for what may sit in the prompt (scrolled arrows too).
    var lastDraftInputAt: TimeInterval { state.machine.lastDraftInputAt }

    /// See `AgentStatusMachine.hold`.
    var agentHold: AgentHold? {
        state.recordPendingTerminalInput()
        return state.machine.hold
    }

    /// A dialog that keys would answer is open.
    var dialogWaitsForKeys: Bool { state.machine.pendingDialogs.contains(where: state.machine.waitsForKeys) }

    /// The question the foreground `claude`'s last turn ended on (see
    /// `AgentStatusMachine.askedQuestion`).
    func agentAskedQuestion(foreground: ForegroundProcess?) -> AgentAttentionReason? {
        agentQuestion(foreground: foreground).map { .askedInReply($0.text) }
    }

    /// The same, with when it was asked and whether a yes or no answers it.
    func agentQuestion(foreground: ForegroundProcess?) -> AgentStatusMachine.AskedQuestion? {
        state.machine.visibleQuestion(foreground: foreground)
    }

    /// See `AgentStatusMachine.noteQuestionSeen`.
    func noteAgentQuestionSeen() {
        state.machine.noteQuestionSeen()
    }

    /// A question its last turn end asked that the user hasn't read yet.
    var agentHasUnseenQuestion: Bool { state.machine.askedQuestion.map { !$0.isSeen } ?? false }

    /// See `AgentStatusMachine.dismissQuestion`.
    @discardableResult
    func dismissAgentQuestion(askedAt since: TimeInterval? = nil) -> Bool {
        state.machine.dismissQuestion(askedAt: since)
    }

    /// See `AgentStatusMachine.lastTurnEndedAt`.
    var agentLastTurnEndedAt: TimeInterval { state.machine.lastTurnEndedAt }

    /// When the last prompt Claude Code didn't mark as a poll event went into
    /// its agent: the user's, or a Mission message (2.1.328 sends no mark,
    /// so every prompt). Nil before one.
    var agentLastUserPromptAt: TimeInterval? { state.machine.lastUserPromptAt }

    /// See `AgentStatusMachine.lastPromptTyper`.
    var agentLastPromptTyper: AgentStatusMachine.PromptTyper { state.machine.lastPromptTyper }

    /// See `AgentStatusMachine.mayAskParent`.
    func mayAskParent(endingTurnAt turnEndedAt: TimeInterval) -> Bool {
        state.machine.mayAskParent(endingTurnAt: turnEndedAt)
    }

    /// See `AgentStatusMachine.isCurrentTurnEnd`.
    func isCurrentTurnEnd(_ turnEndedAt: TimeInterval) -> Bool {
        state.machine.isCurrentTurnEnd(turnEndedAt)
    }

    /// Types a quick answer (Yes, No, a reply) to the turn end of
    /// `turnEndedAt` when it may go in (`AgentStatusMachine
    /// .acceptsQuickAnswer`), as a prompt the user's click sends; false,
    /// and nothing typed, otherwise.
    func typeQuickAnswer(_ terminalInput: String, to turnEndedAt: TimeInterval, foreground: ForegroundProcess?) -> Bool {
        readTranscriptPrompts()
        guard !hasExited, state.machine.acceptsQuickAnswer(
            to: turnEndedAt, foreground: foreground, now: Date().timeIntervalSince1970
        ) else { return false }
        typePromptFromUser(terminalInput)
        return true
    }

    /// Types a prompt the user's click sends into this agent (see
    /// `AgentStatusMachine.notePromptFromUser`).
    func typePromptFromUser(_ terminalInput: String) {
        state.machine.notePromptFromUser()
        sendRaw(terminalInput)
    }

    /// See `AgentStatusMachine.awaitsVerdict`.
    func awaitsTurnEndVerdict(_ request: TurnEndRequest) -> Bool {
        state.machine.awaitsVerdict(request)
    }

    /// See `AgentStatusMachine.applyTurnEndVerdict`.
    func applyTurnEndVerdict(
        _ verdict: TurnEndVerdict,
        for request: TurnEndRequest,
        isUserFocused: Bool
    ) -> AgentAttentionReason? {
        state.machine.applyTurnEndVerdict(verdict, for: request, isUserFocused: isUserFocused)
    }

    /// When the user last typed into this terminal (0: never).
    var lastKeystrokeAt: TimeInterval { state.machine.lastKeystrokeAt }

    /// The oldest dialog (permission, question) the agent may be showing —
    /// even while the column is focused and reads as idle.
    var pendingAgentDialog: AgentPermissionRequest? { state.machine.pendingDialogs.first }

    /// The dialog the foreground `claude` is showing, if any (see
    /// `AgentStatusMachine.visibleDialog`).
    func agentVisibleDialog(foreground: ForegroundProcess?) -> AgentPermissionRequest? {
        state.machine.visibleDialog(foreground: foreground)
    }

    /// Read the foreground Codex's own state between heartbeat ticks, including a dialog over a working turn.
    func taskActivity(foreground: ForegroundProcess?, status: AgentStatus) -> (status: AgentStatus, codexChoice: AgentAttentionReason?) {
        guard let report = state.machine.codexReport(foreground: foreground)?.status else { return (status, nil) }
        if let choice = report.codexChoice { return (.needsAttention, choice) }
        switch report.state {
        case .working: return (.working, nil)
        case .idle: return (.idle, nil)
        case .done: return (agentAttentionReason == .turnFinished ? status : .idle, nil)
        case .blocked, .error: return (status, nil)
        }
    }

    /// The request the sidebar can answer, or whose answer is on its way.
    func sidebarApproval(now: TimeInterval) -> AgentPermissionRequest? {
        state.machine.sidebarApproval(now: now)
    }

    func markApprovalSent(
        requestID: String,
        behavior: PermissionApproval.Behavior,
        now: TimeInterval
    ) -> AgentPermissionRequest? {
        state.machine.markApprovalSent(requestID: requestID, behavior: behavior, now: now)
    }

    func takeUndecidedApprovals(
        where shouldTake: (AgentPermissionRequest) -> Bool = { _ in true }
    ) -> [AgentPermissionRequest] {
        state.machine.takeUndecidedApprovals(where: shouldTake)
    }

    func dropApproval(requestID: String) -> AgentPermissionRequest? {
        state.machine.dropApproval(requestID: requestID)
    }

    // MARK: Stuck agents (see `AgentStuckState`), and Mission `tell`

    func agentStuckState(now: TimeInterval, waitThreshold: TimeInterval?, foreground: ForegroundProcess?) -> AgentStuckState? {
        state.machine.stuckState(
            now: now, waitThreshold: waitThreshold, silence: agentSilence(waitThreshold: waitThreshold), foreground: foreground
        )
    }

    func takeAgentStuckAlert(
        now: TimeInterval,
        waitThreshold: TimeInterval?,
        foreground: ForegroundProcess?
    ) -> AgentAttentionReason? {
        state.machine.takeStuckAlert(
            now: now, waitThreshold: waitThreshold, silence: agentSilence(waitThreshold: waitThreshold), foreground: foreground
        )
    }

    /// What blocks the agent on the user now (see `AgentWait`): a silent
    /// turn past the stuck-agent setting's `waitThreshold` too.
    func agentBlockedWait(now: TimeInterval, waitThreshold: TimeInterval?, foreground: ForegroundProcess?) -> AgentWait? {
        state.machine.blockedWait(now: now, silence: agentSilence(waitThreshold: waitThreshold), foreground: foreground)
    }

    /// The awake clock silences are measured on (`AgentSilence`).
    var awakeClock: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// The silence past its threshold, if the transcript's end waits on
    /// Claude's reply: read once per size of it, since nothing grows while
    /// it lasts. Without a transcript, no proof: no silence.
    private func agentSilence(waitThreshold: TimeInterval?) -> AgentSilence? {
        let signs = state.lifeSigns
        guard let since = signs.lastAt, let startedAt = signs.lastWallAt, let transcript = signs.transcript,
              awakeClock() - since >= AgentSilence.threshold(waitThreshold: waitThreshold)
        else { return nil }
        let awaited = transcript.awaited ?? TranscriptLastMessage.awaitedReply(path: transcript.path) ?? .none
        state.lifeSigns.noteAwaited(awaited)
        return awaited == .none ? nil : AgentSilence(since: since, startedAt: startedAt)
    }

    /// What Interrupt would do in the silent turn of `foreground`: refused
    /// where Esc could answer a dialog, open the rewind or close a screen
    /// typed keys left (`silentInterruptRefusal`); else the transcript's
    /// end says whether Claude gives a prompt back. A message Claude took in
    /// mid-turn (a peer's, a poll's) is no prompt of the user's.
    func silentInterruptPlan(foreground: ForegroundProcess?) -> SilentInterruptPlan {
        readTranscriptPrompts()
        if let refusal = state.machine.silentInterruptRefusal(foreground: foreground) { return .refused(refusal) }
        return state.lifeSigns.transcript?.awaited == .prompt ? .givesBackPrompt : .stops
    }

    /// Esc into the turn gone silent at `since` (`AgentSilence.since`), on
    /// the user's click, while it still is (see `silentInterruptPlan`).
    /// A prompt given back ends the turn at once, as the user's draft;
    /// otherwise the turn ends once Claude writes its interrupt (see
    /// `noteInterrupted`).
    func interruptSilentTurn(
        since: TimeInterval, waitThreshold: TimeInterval?, snapshot: ProcessSnapshot, now: TimeInterval
    ) -> SilentInterrupt {
        guard !snapshot.isEmpty else { return .noProcesses }
        let foreground = foregroundProcess(snapshot: snapshot)
        guard case .silent(let silence)? = agentStuckState(now: now, waitThreshold: waitThreshold, foreground: foreground),
              silence.since == since
        else { return .notSilent }
        let plan = silentInterruptPlan(foreground: foreground)
        if case .refused(let refusal) = plan { return .refused(refusal) }
        guard let promptAt = sendInterrupt() else { return .refused(.notWorking) }
        guard plan == .givesBackPrompt else { return .stopping(promptAt: promptAt) }
        _ = state.machine.noteInterrupted(promptAt: promptAt, now: now)
        state.machine.notePromptGivenBack(now: now)
        return .promptGivenBack
    }

    /// The main thread's turn waits on the model (see
    /// `AgentStatusMachine.awaitsModel`).
    func agentAwaitsModel(foreground: ForegroundProcess?) -> Bool {
        state.machine.awaitsModel(foreground: foreground)
    }

    /// The agent's transcript measures `size` at `now`, epoch seconds (see
    /// `AgentLifeSigns`).
    func noteAgentTranscript(path: String, size: Int64, now: TimeInterval) {
        state.lifeSigns.noteTranscript(path: path, size: size, awake: awakeClock(), wall: now)
    }

    func forgetAgentTranscript() {
        state.lifeSigns.forgetTranscript()
    }

    /// The transcript a silence was read from: where Claude writes the
    /// interrupt an Esc caused.
    var agentTranscriptPath: String? { state.lifeSigns.transcript?.path }

    // MARK: The trust question (see `AgentTrustPrompt`)

    /// Whether to read the screen for the trust question now: the agent
    /// may be asking it, the last read is `readInterval` old, and none is
    /// on its way. True marks a read on its way: end it with
    /// `finishTrustPromptRead`.
    func beginTrustPromptRead(foreground: ForegroundProcess?, now: TimeInterval) -> Bool {
        guard !hasExited, !state.trustPromptReadInFlight, now - state.trustPromptReadAt >= AgentTrustPrompt.readInterval,
              state.machine.watchesForTrustPrompt(foreground: foreground, now: now)
        else { return false }
        state.trustPromptReadInFlight = true
        state.trustPromptReadAt = now
        return true
    }

    /// Reads the rows on screen off the main thread, where Ghostty locks the
    /// terminal for the read, and says on the main thread whether they show
    /// a trust question: nil without a surface to read.
    func readTrustPrompt(completion: @escaping @MainActor @Sendable (Bool?) -> Void) {
        let session = terminalSession
        DispatchQueue.global(qos: .utility).async {
            let shown = session.readViewportText().map(AgentTrustPrompt.isShown(in:))
            DispatchQueue.main.async { @MainActor in completion(shown) }
        }
    }

    func finishTrustPromptRead(shown: Bool?, foreground: ForegroundProcess, now: TimeInterval) {
        state.trustPromptReadInFlight = false
        state.machine.noteTrustPrompt(shown: shown, foreground: foreground, now: now)
    }

    /// The trust question the foreground agent asks, if any.
    func agentTrustPrompt(foreground: ForegroundProcess?) -> AgentTrustPrompt.Sighting? {
        state.machine.visibleTrustPrompt(foreground: foreground)
    }

    var agentMidTurnExit: AgentMidTurnExit? { state.machine.midTurnExit }

    var agentTurnFailure: AgentTurnFailure? { state.machine.turnFailure }

    func noteAgentExited(_ exit: AgentMidTurnExit) {
        state.machine.noteAgentExited(exit)
    }

    func clearAgentMidTurnExit() {
        state.machine.clearMidTurnExit()
    }

    /// Why Resume can't type `continue` now, if it can't (see
    /// `AgentStatusMachine.resumeRefusal`). `foreground` is this terminal's
    /// foreground process in `snapshot`; the failed `claude` may be it or
    /// run under it (a launcher that spawns it).
    func agentResumeRefusal(
        foreground: ForegroundProcess?,
        snapshot: ProcessSnapshot,
        now: TimeInterval
    ) -> AgentResumeRefusal? {
        guard !hasExited, let foreground else { return .notClaude }
        readTranscriptPrompts()
        return state.machine.resumeRefusal(
            foreground: foreground,
            ownsEmitter: { snapshot.ownsEmitter($0, foreground: foreground) },
            now: now
        )
    }

    /// Resume a turn that failed on an API error: `continue` and Enter,
    /// typed only when `agentResumeRefusal` allows it. Returns the refusal
    /// otherwise.
    func resumeFailedTurn(snapshot: ProcessSnapshot, now: TimeInterval) -> AgentResumeRefusal? {
        let foreground = foregroundProcess(snapshot: snapshot)
        if let refusal = agentResumeRefusal(foreground: foreground, snapshot: snapshot, now: now) { return refusal }
        guard let input = TypedPromptSanitizer.terminalInput(for: "continue") else { return .notStopped }
        state.machine.markResumeSent(now: now)
        sendRaw(input)
        state.machine.noteResumeTyped()
        return nil
    }

    // MARK: Branch Review comments (docs/design/branch-review.md, section 6.2)

    /// Why a Branch Review's comments can't go into this column's prompt
    /// now, if they can't (see `AgentStatusMachine.reviewSendRefusal`).
    func reviewSendRefusal(snapshot: ProcessSnapshot) -> ReviewSendRefusal? {
        guard !hasExited else { return .noAgent }
        readTranscriptPrompts()
        return state.machine.reviewSendRefusal(foreground: foregroundProcess(snapshot: snapshot))
    }

    /// The folder the agent here works in: the process in front's (where
    /// `claude --worktree` moved it), or else the shell's.
    func agentCwd(snapshot: ProcessSnapshot) -> String? {
        if let instance = foregroundInstance(snapshot: snapshot), instance.pid > 0, instance.pid != state.childPid,
           let folder = Self.cwd(ofExecedProcess: instance.pid) {
            return folder
        }
        return childCwd
    }

    /// The agent running here now, in front or under a program in front (a
    /// launcher: `npx`, `caffeinate`), by the process tree alone: not one
    /// the hooks last named, which may have ended.
    func runningAgent(snapshot: ProcessSnapshot) -> CodingAgent? {
        guard !hasExited, state.childPid > 0 else { return nil }
        if let agent = foregroundProcessName(snapshot: snapshot).flatMap(CodingAgent.init(rawValue:)) { return agent }
        return snapshot.firstDescendantName(of: state.childPid) { CodingAgent(rawValue: $0) != nil }
            .flatMap(CodingAgent.init(rawValue:))
    }

    /// How a paste ended.
    enum PasteOutcome: Equatable, Sendable {
        case pasted
        /// The terminal closed, or refused the rest.
        case closed
        /// Another program came to the front (the agent quit, or was
        /// stopped): the rest isn't written, not to reach a shell.
        case agentLeft
        case cancelled
        /// The agent stopped reading.
        case timedOut
    }

    /// How a paste ended, and how many of its bytes reached the terminal:
    /// none, nothing of it sits anywhere.
    struct PasteResult: Equatable, Sendable {
        let outcome: PasteOutcome
        let written: Int
    }

    /// Writes `text` to the terminal off the main thread: a long paste
    /// fills the terminal's input queue, which empties only as the agent
    /// reads it, so one write would block the app meanwhile, or stop short
    /// of the paste's end. A byte at a time, each once the terminal takes
    /// one (it says so once a byte is free: a longer write could block
    /// past Cancel and the deadline), and only while `process`'s group is
    /// in front: what a shell would read as typed lines never reaches it,
    /// and what the agent left unread is dropped. It counts as typed.
    /// Cancelled, or timed out, the agent still in front, the paste is
    /// ended (`ESC[201~`) if the terminal takes it, so that Claude isn't
    /// left in it. Meanwhile, a wheel scroll's arrows aren't passed on:
    /// inside the paste they would be its text. `done` comes on the main
    /// queue, with when the paste counted as typed (`lastInputAt` then:
    /// later input is someone's).
    func pasteInBackground(
        _ text: String, keepingInFront process: ProcessInstance?, cancelled: @escaping @Sendable () -> Bool,
        done: @escaping @MainActor @Sendable (_ result: PasteResult, _ typedAt: TimeInterval) -> Void
    ) {
        let data = Data(text.utf8)
        // Gone already, it reads as no group: nothing is written.
        let group = process.map { getpgid($0.pid) }
        let fd = hasExited ? nil : state.descriptorForWrite(of: data)
        let typedAt = lastInputAt
        let pasting = state.pasting
        pasting.withLock { $0 += 1 }
        Self.writeInBackground(data, to: fd, group: group, cancelled: cancelled) { result in
            pasting.withLock { $0 -= 1 }
            done(result, typedAt)
        }
    }

    /// What one write to the terminal surely takes: about what its input
    /// queue holds. A longer text goes through `pasteInBackground`.
    nonisolated static let inputQueueBytes = 1_024

    /// `ESC[200~` and `ESC[201~`.
    private nonisolated static let markerLength = 6

    /// Past this, a paste the agent doesn't read ends.
    nonisolated static let pasteTimeout: TimeInterval = 30

    /// `data` written to `fd`, a descriptor of its own (closed after), off
    /// the main thread; `done` on the main queue.
    private nonisolated static func writeInBackground(
        _ data: Data, to fd: Int32?, group: pid_t?, cancelled: @escaping @Sendable () -> Bool,
        done: @escaping @MainActor @Sendable (PasteResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = fd.map { fd in
                defer { close(fd) }
                return writePaste(data, to: fd, group: group, cancelled: cancelled, deadline: Date().addingTimeInterval(pasteTimeout))
            } ?? PasteResult(outcome: .closed, written: 0)
            DispatchQueue.main.async { done(result) }
        }
    }

    /// `data` written to `fd` as the terminal takes it, a byte once
    /// `poll` says one is free (a blocking terminal: a write of more could
    /// block), while `group` (when known) is the terminal's foreground
    /// process group, until `deadline`, unless `cancelled`.
    nonisolated static func writePaste(
        _ data: Data, to fd: Int32, group: pid_t?, cancelled: @Sendable () -> Bool, deadline: Date
    ) -> PasteResult {
        var offset = 0
        let outcome = writePaste(data, to: fd, group: group, cancelled: cancelled, deadline: deadline, offset: &offset)
        return PasteResult(outcome: outcome, written: offset)
    }

    private nonisolated static func writePaste(
        _ data: Data, to fd: Int32, group: pid_t?, cancelled: @Sendable () -> Bool, deadline: Date, offset: inout Int
    ) -> PasteOutcome {
        func writable(_ wait: Int32) -> Bool? {
            var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let count = poll(&ready, 1, wait)
            if count < 0 { return errno == EINTR ? false : nil }
            if ready.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return nil }
            return count > 0
        }
        func ended(_ outcome: PasteOutcome) -> PasteOutcome {
            // Still the agent's: its paste ends, rather than wait open; a
            // byte at a time, each the terminal takes at once.
            guard offset > 0, group.map({ tcgetpgrp(fd) == $0 }) ?? true else { return outcome }
            let ending = Date().addingTimeInterval(2)
            var end = Array("\u{1B}[201~".utf8)[...]
            while let byte = end.first, Date() < ending {
                guard let ready = writable(100) else { break }
                if ready, withUnsafePointer(to: byte, { write(fd, $0, 1) }) == 1 { end = end.dropFirst() }
            }
            return outcome
        }
        while offset < data.count {
            if cancelled() { return ended(.cancelled) }
            if let group, tcgetpgrp(fd) != group {
                // What the agent left unread would reach what is in front.
                tcflush(fd, TCIFLUSH)
                return .agentLeft
            }
            if Date() > deadline { return ended(.timedOut) }
            guard let ready = writable(100) else { return .closed }
            if !ready { continue }
            // The paste's markers go whole: Claude gives up on an escape
            // that stalls halfway (the queue is empty at an idle prompt).
            let length = offset == 0 || offset == data.count - markerLength ? min(markerLength, data.count - offset) : 1
            let written = data.withUnsafeBytes { buffer in write(fd, buffer.baseAddress! + offset, length) }
            if written < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return .closed
            }
            offset += written
        }
        return .pasted
    }

    /// Calls `action(true)` once, on the main thread's next prompt that
    /// goes in after `time` holding `header` (a Branch Review message's
    /// first line, as `AgentHookEvent.reviewHeader` reads it), from
    /// `process` when it is known: what was pasted reached Claude only
    /// once the user submitted it. `action(false)` on a prompt without it
    /// (cleared, or set aside: it is still listened for), and once it can't
    /// be taken any more:
    /// a new session or the session's end (the prompt it sat in is gone),
    /// another `claude`'s prompt, the process gone (`settlePromptWatchers`),
    /// the terminal exited, restarted or closed, or a day later.
    func onNextPrompt(
        after time: TimeInterval, from process: ProcessInstance?, header: String,
        _ action: @escaping @Sendable (_ taken: Bool) -> Void
    ) {
        // Another paste of the same message's header: a prompt can't tell
        // them apart, so the one before (cleared, or joined) is let go,
        // rather than marked sent for what this one holds.
        state.settlePromptWatchers { $0.header == header }
        state.promptWatchers.append(PtyState.PromptWatcher(after: time, process: process, header: header, action: action))
    }

    /// Past this, a paste waiting for its prompt is let go.
    nonisolated static let promptWatchLimit: TimeInterval = 24 * 3600

    /// Lets go of the pastes whose `claude` no longer runs (it quit, the
    /// shell stays), or that waited a day: no hook may come to say so. The
    /// shell's metadata refresh calls it, with its process table.
    func settlePromptWatchers(snapshot: ProcessSnapshot) {
        guard !state.promptWatchers.isEmpty, !snapshot.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        state.settlePromptWatchers { watcher in
            watcher.process.map { !snapshot.contains($0) } == true || now > watcher.after + Self.promptWatchLimit
        }
    }

    /// A descriptor of its own on the terminal, nothing noted (tests).
    func duplicateDescriptorForTests() -> Int32? {
        state.duplicateDescriptor()
    }

    /// Whether a Mission message may be typed now into the prompt of a
    /// `claude` already running at `runningSince` (see
    /// `AgentStatusMachine.isPromptFree`).
    func acceptsMissionMessage(runningSince: TimeInterval, snapshot: ProcessSnapshot, seenByUser: Bool = false) -> Bool {
        missionPromptRefusal(runningSince: runningSince, snapshot: snapshot, seenByUser: seenByUser) == nil
    }

    /// When the last hook event came, of any command (0: none).
    var lastAgentHookAt: TimeInterval { state.machine.lastEventAt }

    /// See `AgentStatusMachine.promptFacts`, and what the session record
    /// of the `claude` in front says.
    /// See `AgentStatusMachine.promptFacts`, and what the session record
    /// of the `claude` in front says (`record`: how to read it).
    func missionPromptFacts(
        now: TimeInterval, snapshot: ProcessSnapshot, record: (ProcessInstance) -> ClaudeSessionRecord.Reading = { sessionRecord(of: $0) }
    ) -> String {
        let facts = foregroundProcess(snapshot: snapshot).flatMap { $0.interactiveAgent == .claude ? $0.instance : nil }
            .map { " record=" + record($0).facts(of: $0, now: now) }
        readTranscriptPrompts()
        return state.machine.promptFacts(now: now) + (facts ?? "")
    }

    /// Why `acceptsMissionMessage` says no, nil when it says yes, at `now`.
    /// `seenByUser`: the user says its `claude` with no prompt yet sits at
    /// its prompt (see `ClaudeSessionRecord.Reading.allowsTypingOnSight`).
    /// `record`: how to read the session record of a `claude` with no
    /// prompt yet (a check's own reading, between checks).
    func missionPromptRefusal(
        runningSince: TimeInterval, snapshot: ProcessSnapshot, seenByUser: Bool = false,
        agent: CodingAgent = .claude, now: TimeInterval = Date().timeIntervalSince1970,
        record: (ProcessInstance) -> ClaudeSessionRecord.Reading = { sessionRecord(of: $0) }
    ) -> AgentPromptRefusal? {
        guard !hasExited else { return .noClaude }
        readTranscriptPrompts()
        return state.machine.promptRefusal(
            foreground: foregroundProcess(snapshot: snapshot), runningSince: runningSince, seenByUser: seenByUser, agent: agent
        ) {
            seenByUser ? record($0).allowsTypingOnSight(of: $0, now: now) : record($0).showsIdlePrompt(of: $0, now: now)
        }
    }

    /// Whether `foreground`, the column's `claude`, that took no prompt since
    /// it started, sits at its empty prompt at `now` (see
    /// `AgentStatusMachine.sitsAtFirstPrompt`; `record` as
    /// `missionPromptRefusal` takes it).
    func sitsAtFirstPrompt(
        _ foreground: ForegroundProcess, now: TimeInterval,
        record: (ProcessInstance) -> ClaudeSessionRecord.Reading = { sessionRecord(of: $0) }
    ) -> Bool {
        state.machine.sitsAtFirstPrompt(foreground.instance) { record($0).showsIdlePrompt(of: $0, now: now) }
    }

    /// Whether Enter may follow a paste whose keys went in at `typedAt`, into
    /// the prompt of `process`: no key since, no dialog its hooks listed,
    /// still in front. (Its session record is read apart: it may lag.)
    func mayPressEnter(after typedAt: TimeInterval, for process: ProcessInstance?, snapshot: ProcessSnapshot) -> Bool {
        lastInputAt == typedAt && !dialogWaitsForKeys && foregroundProcess(snapshot: snapshot)?.instance == process
    }

    /// The session record of `process`, a `claude`, in the config folder
    /// its own environment names, else Nirux's, which its terminal inherits
    /// (macOS hides a system binary's); a relative one is the process's,
    /// against its working directory.
    static func sessionRecord(
        of process: ProcessInstance, inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> ClaudeSessionRecord.Reading {
        let own = ProcessSnapshot.environment(of: process.pid)
        let url = ClaudeSessionRecord.url(pid: process.pid, environment: own.isEmpty ? inherited : own) {
            cwd(ofExecedProcess: process.pid)
        }
        return ClaudeSessionRecord.read(at: url)
    }

    /// See `AgentStatusMachine.codexQueueRefusal`.
    func codexQueueRefusal(runningSince: TimeInterval, snapshot: ProcessSnapshot) -> AgentPromptRefusal? {
        guard !hasExited else { return .noClaude }
        return state.machine.codexQueueRefusal(foreground: foregroundProcess(snapshot: snapshot), runningSince: runningSince)
    }

    /// Whether `process`, the column's `codex` or `agy`, started a turn
    /// after `time` (what it said through OSC 7501).
    func startedTurn(since time: TimeInterval, by process: ProcessInstance) -> Bool {
        if let turn = state.machine.agyTurn, turn.process == process, turn.startedAt > time { return true }
        guard let worked = state.machine.codexWorked, worked.at > time else { return false }
        return worked.process.map { $0 == process } ?? (process.startedAt <= worked.at)
    }

    /// See `AgentStatusMachine.agyFacts`.
    func agyFacts(now: TimeInterval) -> String {
        state.machine.agyFacts(now: now)
    }

    /// See `AgentStatusMachine.codexFacts`.
    func codexFacts(now: TimeInterval) -> String {
        state.machine.codexFacts(now: now)
    }

    func hasAgyTurn(in process: ProcessInstance) -> Bool {
        state.machine.agyTurn?.process == process
    }

    func finishedMissionTurn(in foreground: ForegroundProcess, after sentAt: TimeInterval) -> Bool {
        switch foreground.interactiveAgent {
        case .agy:
            guard let turn = state.machine.agyTurn, turn.process == foreground.instance else { return false }
            return turn.startedAt >= sentAt && turn.ended != nil
        case .codex:
            guard startedTurn(since: sentAt, by: foreground.instance),
                  let report = state.machine.codexReport(foreground: foreground) else { return false }
            return [.done, .idle, .error].contains(report.status.state)
        case .claude: return finishedTurn(afterTypingAt: sentAt)
        default: return false
        }
    }

    /// See `AgentStatusMachine.finishedTurn(afterTypingAt:)`.
    func finishedTurn(afterTypingAt typedAt: TimeInterval) -> Bool {
        readTranscriptPrompts()
        return state.machine.finishedTurn(afterTypingAt: typedAt)
    }

    /// Requests whose dialogs a prompt typed at the box closed, as its
    /// transcript told: their receivers wait for nothing (main queue).
    var onApprovalsAbandoned: (([AgentPermissionRequest]) -> Void)?
    /// The user typed a prompt to its agent, at the box or elsewhere, as its
    /// hook or its transcript line told, with its time
    /// (`AgentStatusMachine.lastPromptByUserAt`). Not one Nirux typed, nor
    /// one Claude took in by itself (main queue).
    var onUserPrompt: ((TimeInterval) -> Void)?

    /// What the transcript of the `claude` in front gained since the last
    /// read: who sent its prompts (see
    /// `AgentStatusMachine.noteTranscriptPrompt`). Read before Nirux
    /// decides what to type into its prompt, and at each heartbeat.
    func readTranscriptPrompts() {
        guard var reader = state.transcriptPrompts else { return }
        _ = reader.readAppended(budget: Self.transcriptPromptBudget)
        let prompts = reader.takePrompts()
        state.transcriptPrompts = reader
        let userPromptBefore = state.machine.lastPromptByUserAt
        let abandoned = prompts.flatMap { state.machine.noteTranscriptPrompt($0) }
        if !abandoned.isEmpty { onApprovalsAbandoned?(abandoned) }
        noteUserPrompt(since: userPromptBefore)
    }

    private func noteUserPrompt(since before: TimeInterval?) {
        guard let typedAt = state.machine.lastPromptByUserAt, typedAt != before else { return }
        onUserPrompt?(typedAt)
    }

    /// A read on the main queue stays short; a long tool output takes a few.
    private static let transcriptPromptBudget = 4 * 1024 * 1024
    /// Where reading a transcript starts: the prompt of the hook that named
    /// it may be written already.
    private static let transcriptPromptTail = 256 * 1024

    /// Whether `foreground`, the column's `claude`, took a prompt since it
    /// started (see `AgentStatusMachine.prompt(since:)`); nil while no hook
    /// of it reached the column, as for a `claude` without Nirux's hooks:
    /// nothing tells.
    func agentTookPrompt(since foreground: ForegroundProcess) -> Bool? {
        guard state.machine.hookAgent == .claude else { return nil }
        return state.machine.prompt(since: foreground.instance.startedAt) != nil
    }

    /// The user's login shell ($SHELL) when it's a mainstream
    /// POSIX-compatible one, else zsh. Restricted to an allowlist because
    /// command-backed columns launch it with zsh-style `-i -l -c` flags
    /// that exotic shells (nu, xonsh, elvish) reject — for those users the
    /// hardcoded /bin/zsh was the working behavior. Computed once — checked
    /// in the parent process, never post-fork.
    static let defaultShell: String = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        if shell.hasPrefix("/"), Shell.launchable.contains((shell as NSString).lastPathComponent),
           FileManager.default.fileExists(atPath: shell) {
            return shell
        }
        return "/bin/zsh"
    }()

    /// Compute agent status. With Claude Code hooks installed, lifecycle
    /// events (prompt submitted, tool call, turn stop, permission request)
    /// are authoritative; agents without hooks fall back to output-activity
    /// detection. Called on the heartbeat with a shared process snapshot;
    /// `processTableRead` false when that snapshot came back empty;
    /// `claudeFiredHooks` per `ColumnState.claudeHooksFired(by:)` (see
    /// `AgentStatusMachine.tick`).
    func agentStatus(
        foregroundProcess: ForegroundProcess?,
        isUserFocused: Bool,
        processTableRead: Bool,
        claudeFiredHooks: Bool
    ) -> AgentStatus {
        let fgName = processTableRead ? foregroundProcess?.name ?? "" : nil
        if processTableRead { state.machine.keepProgramStatus(of: foregroundProcess?.instance) }
        readTranscriptPrompts()
        return state.machine.tick(
            fgName: fgName, claudeFiredHooks: claudeFiredHooks, isUserFocused: isUserFocused, now: Date()
        )
    }

    /// Apply a hook event routed by AgentHookCenter (main queue).
    /// `firedAttention` means the column flipped INTO needsAttention — the
    /// caller then fires the workspace-level notification path.
    @discardableResult
    func applyAgentHook(_ event: AgentHookEvent, isUserFocused: Bool) -> AgentHookOutcome {
        // The transcript its own `claude` writes: who sent each prompt.
        if event.kind == .claude, event.agentID == nil, let path = event.transcriptPath, state.transcriptPrompts?.path != path {
            state.transcriptPrompts = TranscriptPromptReader(path: path, tailBytes: Self.transcriptPromptTail)
            state.machine.readsTranscript = true
        }
        let dialogsBefore = state.machine.pendingDialogs.count
        let userPromptBefore = state.machine.lastPromptByUserAt
        let outcome = state.machine.apply(event, isUserFocused: isUserFocused)
        noteUserPrompt(since: userPromptBefore)
        state.lifeSigns.note(awake: awakeClock(), wall: event.timestamp)
        if event.agentID == nil, !state.promptWatchers.isEmpty { state.settlePromptWatchers(on: event) }
        let dialogs = state.machine.pendingDialogs
        if dialogs.count != dialogsBefore {
            // Stale-gate reports need the trail: which event opened or
            // closed what (NIRUX_TERM_DEBUG=1).
            NiruxDebugLog.log("agent dialogs \(dialogsBefore)→\(dialogs.count) on \(event.name.rawValue) "
                + "agent=\(event.agentID ?? "main"): "
                + dialogs.map { "\($0.toolName ?? "?")[\($0.key ?? "-")]" }.joined(separator: ","))
        }
        return outcome
    }

    /// Last computed agent state (no snapshot needed — read from persistent state)
    var cachedAgentState: AgentStatus { state.machine.state }

    /// Epoch seconds of the agent's last sign of life: output that wasn't
    /// input echo (since the foreground command started), or a hook event
    /// (of any command). 0 = none.
    var lastAgentActivityAt: TimeInterval { max(state.machine.lastReadAt, state.machine.lastEventAt) }

    /// The last status tick saw a recognized agent in the foreground.
    var lastSeenRunningAgent: Bool {
        state.machine.lastForegroundName.flatMap(CodingAgent.init(rawValue:)) != nil
    }

    /// The agent whose hook events reached this session: closing only
    /// trusts an "idle" status that hooks drive.
    var hookAgent: CodingAgent? { state.machine.hookAgent }

    /// A recognized agent that closing this terminal would kill: the
    /// foreground process, or any descendant of the shell — a job suspended
    /// with ^Z, or an agent under a wrapper, dies with the PTY too. Fails
    /// closed: an empty snapshot, or a turn the status machine still sees
    /// in flight, falls back to the heartbeat's last view of the agent — so
    /// an agent that exited since the last tick (≤ 2 s) may still prompt.
    func terminalAgent(snapshot: ProcessSnapshot) -> CodingAgent? {
        guard !hasExited, state.childPid > 0 else { return nil }
        if let agent = runningAgent(snapshot: snapshot) { return agent }
        guard snapshot.isEmpty || cachedAgentState != .idle else { return nil }
        return state.machine.lastForegroundName.flatMap(CodingAgent.init(rawValue:)) ?? state.machine.hookAgent
    }

    /// Nirux types prompts (PR Feedback's Address, "Ask Agent Why CI
    /// Failed") only while an agent driven by hooks is in front. Claude's
    /// hooks report the dialogs such a prompt must not answer; an agent
    /// read from its output says nothing of them, so its permission prompt
    /// looks like any silence and a prompt could land on it. (Codex's
    /// notify reports turn ends only: the same blind spot, accepted.) A
    /// stable UUID alone is not enough: the same column can later fall
    /// back to an idle shell.
    func acceptsTypedPrompts(snapshot: ProcessSnapshot) -> Bool {
        guard !hasExited else { return false }
        return foregroundProcessName(snapshot: snapshot).flatMap(CodingAgent.init(rawValue:))?.statusSource == .hooks
    }

    /// Clear attention flag (user has seen it)
    func clearAgentAttention() {
        state.machine.clearAttention()
    }

    /// Name of the foreground process (e.g. "zsh", "node", "claude").
    /// Shows what's running right now — no caching, no filtering.
    func foregroundProcessName(snapshot: ProcessSnapshot) -> String? {
        // childPid is cleared on exit — pid 0 would resolve to kernel_task.
        guard state.childPid > 0 else { return nil }
        return state.foregroundProcess(snapshot: snapshot)?.name
    }

    func foregroundProcess(snapshot: ProcessSnapshot) -> ForegroundProcess? {
        state.foregroundProcess(snapshot: snapshot)
    }

    func foregroundInstance(snapshot: ProcessSnapshot) -> ProcessInstance? {
        guard let shellPID else { return nil }
        return snapshot.foregroundInstance(shellPID: shellPID)
    }

    func isProcessInForegroundJob(
        _ process: ProcessInstance,
        snapshot: ProcessSnapshot
    ) -> Bool {
        state.isProcessInForegroundJob(process, snapshot: snapshot)
    }

    /// Returns the cwd of the child process (follows cd), nil until the
    /// shell has exec'd.
    /// Uses `proc_pidinfo(PROC_PIDVNODEPATHINFO)` — `/proc` isn't available
    /// on macOS and `proc_pidpath` gives the executable path, not the cwd.
    var childCwd: String? {
        guard state.childPid > 0 else { return nil }
        return Self.cwd(ofExecedProcess: state.childPid)
    }

    /// Nil until `pid` has exec'd. Before that, the child `start` forked
    /// may not have reached its `chdir` yet and still sits in Nirux's own
    /// working directory (`/` for the app, the checkout under `swift test`):
    /// an editor, a save or a file picker reading it would root itself
    /// there. The flag is read first: a fork starts without it, it never
    /// clears, and the `chdir` comes before the exec, so the cwd read after
    /// it is the shell's.
    static func cwd(ofExecedProcess pid: pid_t) -> String? {
        var bsdInfo = proc_bsdshortinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bsdInfo, bsdSize) == bsdSize,
              bsdInfo.pbsi_flags & UInt32(PROC_FLAG_EXEC) != 0 else { return nil }
        // Use proc_pidinfo with PROC_PIDVNODEPATHINFO to get cwd
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size))
        guard ret == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cpath in
                String(cString: cpath)
            }
        }
    }

    init() {
        let st = state
        terminalSession = InMemoryTerminalSession(
            write: { data in
                guard !st.dropsDuringPaste(data) else { return }
                st.noteTerminalWrite(data)
                st.writeToPty(data)
            },
            resize: { viewport in
                st.resize(cols: Int(viewport.columns), rows: Int(viewport.rows))
            }
        )
    }

    /// Keys reached the prompt since it last emptied (see
    /// `AgentStatusMachine.hasDraft`).
    var hasPromptDraft: Bool {
        state.recordPendingTerminalInput()
        readTranscriptPrompts()
        return state.machine.hasDraft
    }

    private var shellLaunchInputAt: TimeInterval?

    func sendShellLaunchCommand(_ command: String) {
        let hadDraft = hasPromptDraft
        sendRaw("\(command)\n")
        shellLaunchInputAt = hadDraft ? nil : state.machine.lastDraftInputAt
    }

    /// A launch line Nirux sent to an empty shell before the worker started
    /// belongs to the shell. Any later draft belongs to the terminal.
    func taskResumeDraft(foreground: ProcessInstance?) -> TimeInterval? {
        guard !hasExited, hasPromptDraft else { return nil }
        let draft = state.machine.lastDraftInputAt
        if draft == shellLaunchInputAt, let foreground, draft < foreground.startedAt { return nil }
        return draft
    }

    /// Send raw bytes directly to the PTY, bypassing ghostty.
    /// Used for keys that ghostty's inMemory backend doesn't route correctly
    /// (e.g. Enter when Claude Code enables kitty keyboard protocol).
    /// `typedByNirux`: a message Nirux types itself, not for the user.
    func sendRaw(_ data: Data, typedByNirux: Bool = false) {
        state.noteTypedInput(data, byNirux: typedByNirux)
        state.writeToPty(data)
    }

    /// Whether ghostty writes the user's text (see `PtyState.noteTerminalWrite`):
    /// terminal replies (device attributes, focus and mouse reports…) all
    /// start with ESC; a bracketed paste does too, with its own marker.
    static func isUserText(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        return first != 0x1B || data.starts(with: [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]) // ESC[200~
    }

    func sendRaw(_ string: String, typedByNirux: Bool = false) {
        if let data = string.data(using: .utf8) {
            sendRaw(data, typedByNirux: typedByNirux)
        }
    }

    /// Resize the PTY (notify the shell of new terminal dimensions)
    func resize(cols: Int, rows: Int) {
        state.resize(cols: cols, rows: rows)
    }

    /// Force a SIGWINCH to the foreground process group so TUI apps redraw.
    /// Uses tcgetpgrp() to target the entire group (zsh + codex/claude/vim etc.)
    func forceRedraw() {
        guard state.ptyFd >= 0, state.childPid > 0 else { return }
        state.markTerminalRedraw()
        state.lastCols = 0
        state.lastRows = 0
        // Send to the foreground process group of the terminal
        let pgrp = tcgetpgrp(state.ptyFd)
        if pgrp > 0 {
            killpg(pgrp, SIGWINCH)
        } else {
            kill(state.childPid, SIGWINCH)
        }
    }

    func start(
        shell: String = "/bin/zsh",
        args: [String] = ["-l"],
        cwd: String,
        cols: Int = 80,
        rows: Int = 24,
        environment: [String: String] = [:]
    ) {
        // Compute PATH BEFORE fork (Foundation APIs like FileManager are not
        // async-signal-safe and crash in child processes). The effective path
        // is memoized via a static-let and only applied to the child, leaving
        // the parent process's PATH untouched.
        let effectivePath = Shell.effectivePath

        // Read settings BEFORE fork — FileManager is forbidden in child process
        let noFlicker = Persistence.load()?.settings?.claudeNoFlicker != false

        // Prefer the viewport size that arrived while the PTY didn't exist yet
        // (the shell start is deferred ~0.5s after the surface) — otherwise the
        // fork keeps the caller's 80x24 and the upstream debounces never
        // re-send the real size.
        let initialCols = state.pendingCols > 0 ? state.pendingCols : cols
        let initialRows = state.pendingRows > 0 ? state.pendingRows : rows
        NiruxDebugLog.log("pty start cols=\(initialCols) rows=\(initialRows) (pending \(state.pendingCols)x\(state.pendingRows))")

        var ws = winsize()
        ws.ws_col = UInt16(initialCols)
        ws.ws_row = UInt16(initialRows)

        var fd: Int32 = 0
        let pid = forkpty(&fd, nil, nil, &ws)

        if pid == 0 {
            // Child: exec shell via execv (not execl which is unavailable in Swift 6)
            setenv("PATH", effectivePath, 1)
            setenv("TERM", "xterm-256color", 1)
            setenv("LANG", "en_US.UTF-8", 1)
            // libghostty-spm sets it in Nirux's process for its own exec
            // backend; a shell finding it would source Ghostty's
            // integration, which Nirux's terminals never had.
            unsetenv("GHOSTTY_RESOURCES_DIR")
            for (name, value) in environment {
                setenv(name, value, 1)
            }
            if noFlicker {
                setenv("CLAUDE_CODE_NO_FLICKER", "1", 1)
            }

            chdir(cwd)

            var cArgs: [UnsafeMutablePointer<CChar>?] = [strdup(shell)]
            for arg in args { cArgs.append(strdup(arg)) }
            cArgs.append(nil)
            execv(shell, cArgs)
            _exit(1)
        }

        guard pid > 0 else {
            // Fork failed — keep the session in the exited state so the
            // restart overlay stays actionable instead of dead-ending.
            state.hasExited = true
            state.onProcessExit?()
            return
        }
        state.ptyFd = fd
        state.childPid = pid
        state.hasExited = false
        state.lastCols = initialCols
        state.lastRows = initialRows
        state.markPtyStarted()

        // Read PTY output → feed to terminal for rendering
        let session = terminalSession
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))
        source.setEventHandler { [state] in
            state.readFromPty(into: session)
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        state.readSource = source

        // Watch for shell exit — without this a dead shell leaves a mute
        // terminal with no way to know (or restart). Also reaps the zombie.
        state.exitSource?.cancel()
        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exitSource.setEventHandler { [state] in
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            // Cancel the read source BEFORE clearing the fd: its cancel
            // handler closes the master fd. Left armed, it would spin at
            // EOF (or, when a grandchild holds the pty open, never fire at
            // all) — leaking the fd and, after a restart reassigns
            // state.ptyFd, reading from the NEW shell's fd.
            state.readSource?.cancel()
            state.readSource = nil
            state.ptyFd = -1
            // Clear childPid so deinit can't SIGTERM whatever process later
            // recycles this pid, and process attribution stops resolving
            // the dead shell's identity.
            state.childPid = 0
            state.hasExited = true
            state.machine.reset()
            state.expirePromptWatchers()
            state.onProcessExit?()
        }
        exitSource.resume()
        state.exitSource = exitSource
    }

    /// The shell hangs up, as when its window closes: it hangs its jobs up,
    /// then exits. (Its last release would SIGTERM it, whenever that comes.)
    func hangUp() {
        if state.childPid > 0 { kill(state.childPid, SIGHUP) }
    }

    deinit {
        state.exitSource?.cancel()
        state.readSource?.cancel()
        // The column closed: its pastes are let go, on the main queue as
        // ever (the last release may come from a paste's thread).
        let state = state
        DispatchQueue.main.async { state.expirePromptWatchers() }
        if state.childPid > 0 { kill(state.childPid, SIGTERM) }
    }
}

/// Sendable state container for PTY file descriptors
private final class PtyState: @unchecked Sendable {
    var ptyFd: Int32 = -1
    var childPid: pid_t = 0
    var readSource: DispatchSourceRead?
    var exitSource: DispatchSourceProcess?
    var hasExited: Bool = false
    var onCwdChanged: ((String) -> Void)?
    var onTitleChanged: ((String) -> Void)?
    var onOsc9Received: (() -> Void)?
    var onProgramStatus: ((AgentProgramStatus) -> Void)?
    private static let programStatusPrefix = Data(AgentProgramStatus.prefix.utf8)
    /// Read-queue only.
    private var programStatusScanner = AgentProgramStatus.Scanner()
    var onLocalServerURL: ((LocalServerURL) -> Void)?
    var onProcessExit: (() -> Void)?
    var machine = AgentStatusMachine()
    /// Main thread only, as the hook events that feed it.
    var lifeSigns = AgentLifeSigns()
    /// The transcript the `claude` in front writes, as far as read (main
    /// thread only).
    var transcriptPrompts: TranscriptPromptReader?

    /// Background pastes running (`PtySession.pasteInBackground`).
    let pasting = OSAllocatedUnfairLock(initialState: 0)

    /// A wheel scroll's arrows while a paste runs: they would be its text.
    func dropsDuringPaste(_ data: Data) -> Bool {
        AgentStatusMachine.isUpDownArrows(data) && pasting.withLock { $0 > 0 }
    }
    /// Main thread only: when the screen was last read for a trust
    /// question (see AgentTrustPrompt), and whether a read is on its way.
    var trustPromptReadAt: TimeInterval = 0
    var trustPromptReadInFlight = false
    /// Read-queue only. A (re)start sets `localServerStateIsStale` from
    /// main instead of resetting them, so a straggling read handler of the
    /// previous shell never sees them replaced mid-scan.
    private var localServerScanner = LocalServerURLScanner()
    private var localServerLastForwarded: [Int: TimeInterval] = [:]
    private var localServerStateIsStale = false
    private static let localServerForwardInterval: TimeInterval = 1
    /// Something reached the PTY through `sendRaw` — keystrokes (including
    /// the Enter after a ⌘V paste, which itself goes through ghostty),
    /// dropped files, prompts and commands Nirux types. Unlike
    /// `machine.hasUserInput` it ignores ghostty's own writes (replies to
    /// the terminal queries Claude Code sends at startup) and the lone
    /// Ctrl+L redraw nudge. Once open, a TUI repaint can still resurface
    /// an old URL — at most one proposal per port, and only if listening.
    private var hasTypedInput = false

    func noteTypedInput(_ data: Data, byNirux: Bool = false) {
        guard data != Self.redrawNudge else { return }
        machine.noteKeystroke(now: Date(), keys: data, byNirux: byNirux)
        hasTypedInput = true
    }

    private static let redrawNudge = Data([0x0C])

    private let pendingTerminalInput = OSAllocatedUnfairLock(initialState: [Data]())

    /// Ghostty writes to the PTY for text the user enters through it — a
    /// paste (any way: ⌘V, the Edit menu, a right-click), dictation, the
    /// emoji picker — and for its own replies to terminal queries, which
    /// may come on the read queue. The user's text counts as a keystroke,
    /// noted on the main queue like every other; arrows from a wheel scroll
    /// count as what may be at the prompt.
    func noteTerminalWrite(_ data: Data) {
        guard PtySession.isUserText(data) || AgentStatusMachine.isUpDownArrows(data) else { return }
        pendingTerminalInput.withLock { $0.append(data) }
        if Thread.isMainThread {
            recordPendingTerminalInput()
        } else {
            DispatchQueue.main.async { [self] in recordPendingTerminalInput() }
        }
    }

    /// A handover can reach the main queue before the callback for bytes already written to the PTY.
    func recordPendingTerminalInput() {
        let writes = pendingTerminalInput.withLock {
            let writes = $0
            $0 = []
            return writes
        }
        for data in writes {
            if PtySession.isUserText(data) {
                machine.noteKeystroke(now: Date(), keys: data)
            } else {
                machine.notePromptRecall(now: Date())
            }
        }
    }

    func foregroundProcess(snapshot: ProcessSnapshot) -> ForegroundProcess? {
        guard childPid > 0 else { return nil }
        return snapshot.foregroundProcess(shellPID: childPid)
    }

    func isProcessInForegroundJob(
        _ process: ProcessInstance,
        snapshot: ProcessSnapshot
    ) -> Bool {
        guard childPid > 0 else { return false }
        return snapshot.isProcess(process, inForegroundProcessGroupOf: childPid)
    }

    func markPtyStarted() {
        machine.reset()
        lifeSigns = AgentLifeSigns()
        transcriptPrompts = nil
        expirePromptWatchers()
        localServerStateIsStale = true
        hasTypedInput = false
    }

    /// A Branch Review paste waiting for its prompt (see
    /// `PtySession.onNextPrompt`).
    struct PromptWatcher: Sendable {
        let after: TimeInterval
        let process: ProcessInstance?
        let header: String
        let action: @Sendable (_ taken: Bool) -> Void
    }

    var promptWatchers: [PromptWatcher] = []

    /// `event` (the main thread's) settles the watchers it concerns: a
    /// prompt holding one's header takes it; another `claude`'s prompt, or
    /// a new session, lets it go; so does the passing of a day.
    func settlePromptWatchers(on event: AgentHookEvent) {
        var taken: [PromptWatcher] = []
        var gone: [PromptWatcher] = []
        var released: [PromptWatcher] = []
        promptWatchers.removeAll { watcher in
            if event.timestamp > watcher.after + PtySession.promptWatchLimit {
                gone.append(watcher)
                return true
            }
            let other = watcher.process != nil && event.emitterProcess != nil && watcher.process != event.emitterProcess
            switch event.name {
            case .userPromptSubmit where other:
                gone.append(watcher)
                return true
            case .userPromptSubmit where event.timestamp >= watcher.after && event.reviewHeader == watcher.header:
                taken.append(watcher)
                return true
            // Claude takes the whole input: one without the message
            // means the paste was cleared, or set aside (a stash Claude
            // brings back, an automated prompt): its comments are let go,
            // and it is still listened for.
            case .userPromptSubmit where event.timestamp >= watcher.after:
                released.append(watcher)
                return false
            case .sessionStart where event.timestamp >= watcher.after && event.source != "compact",
                 .sessionEnd where event.timestamp >= watcher.after && !other:
                gone.append(watcher)
                return true
            default:
                return false
            }
        }
        taken.forEach { $0.action(true) }
        (gone + released).forEach { $0.action(false) }
    }

    /// Lets go of the watchers `isGone` says can't be taken any more.
    func settlePromptWatchers(_ isGone: (PromptWatcher) -> Bool) {
        var gone: [PromptWatcher] = []
        promptWatchers.removeAll { watcher in
            guard isGone(watcher) else { return false }
            gone.append(watcher)
            return true
        }
        gone.forEach { $0.action(false) }
    }

    /// The terminal exited or restarted: no paste waits any more.
    func expirePromptWatchers() {
        let gone = promptWatchers
        promptWatchers = []
        gone.forEach { $0.action(false) }
    }

    /// A descriptor of its own on the terminal, for `data` written off the
    /// main thread: noted as typed, as `sendRaw` notes it. Nil once the
    /// terminal closed. One of its own: the terminal's may close, and its
    /// number go to another file, while the write goes on.
    func descriptorForWrite(of data: Data) -> Int32? {
        noteTypedInput(data)
        machine.noteUserInput(now: Date())
        return duplicateDescriptor()
    }

    func duplicateDescriptor() -> Int32? {
        guard ptyFd >= 0 else { return nil }
        let fd = dup(ptyFd)
        guard fd >= 0 else { return nil }
        // Not inherited by what Nirux runs meanwhile.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    func writeToPty(_ data: Data) {
        machine.noteUserInput(now: Date())
        guard ptyFd >= 0 else { return }
        data.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress else { return }
            _ = write(ptyFd, ptr, buf.count)
        }
    }

    var lastCols: Int = 0
    var lastRows: Int = 0
    /// Last viewport size seen before the PTY existed. The shell starts ~0.5s
    /// after the surface (ColumnState defers it), so the initial grid resize
    /// arrives while ptyFd is still -1; without this the fork falls back to
    /// 80x24 and the debounces upstream never re-send the real size.
    var pendingCols: Int = 0
    var pendingRows: Int = 0

    private var targetCols: Int = 0
    private var targetRows: Int = 0
    private var winsizeQuietTimer: Timer?

    /// Coalesce winsize updates: apply the first change immediately, then hold
    /// a quiet window so storms (fullscreen transitions, width-preset cycling,
    /// session restore) deliver only the final settled size. Rapid zig-zag
    /// SIGWINCH bursts can wedge TUI renderers (Claude Code ends up stuck on
    /// an intermediate width) — a single trailing resize never does.
    func resize(cols: Int, rows: Int) {
        if Thread.isMainThread {
            resizeOnMain(cols: cols, rows: rows)
        } else {
            DispatchQueue.main.async { self.resizeOnMain(cols: cols, rows: rows) }
        }
    }

    private func resizeOnMain(cols: Int, rows: Int) {
        guard ptyFd >= 0 else {
            NiruxDebugLog.log("pty fd=-1 resize deferred cols=\(cols) rows=\(rows)")
            pendingCols = cols
            pendingRows = rows
            return
        }
        targetCols = cols
        targetRows = rows
        guard winsizeQuietTimer == nil else { return }
        applyTargetWinsize()
        startWinsizeQuietWindow()
    }

    private func startWinsizeQuietWindow() {
        winsizeQuietTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.winsizeQuietTimer = nil
            if self.targetCols != self.lastCols || self.targetRows != self.lastRows {
                self.applyTargetWinsize()
                self.startWinsizeQuietWindow()
            }
        }
    }

    private func applyTargetWinsize() {
        let cols = targetCols
        let rows = targetRows
        guard ptyFd >= 0, cols > 0, rows > 0 else { return }
        guard cols != lastCols || rows != lastRows else {
            NiruxDebugLog.log("pty fd=\(ptyFd) pid=\(childPid) resize skipped cols=\(cols) rows=\(rows)")
            return
        }
        NiruxDebugLog.log("pty fd=\(ptyFd) pid=\(childPid) TIOCSWINSZ cols=\(cols) rows=\(rows) (was \(lastCols)x\(lastRows))")
        machine.noteInteraction(now: Date())
        lastCols = cols
        lastRows = rows
        var ws = winsize()
        ws.ws_col = UInt16(cols)
        ws.ws_row = UInt16(rows)
        _ = ioctl(ptyFd, TIOCSWINSZ, &ws)
    }

    func markTerminalRedraw() {
        machine.noteInteraction(now: Date())
    }

    func readFromPty(into session: InMemoryTerminalSession) {
        guard ptyFd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = read(ptyFd, &buffer, buffer.count)
        guard bytesRead > 0 else {
            // EOF — the child is gone; stop writes from hitting a closed fd.
            ptyFd = -1
            readSource?.cancel()
            return
        }
        let data = Data(buffer[0..<bytesRead])
        machine.noteRead(now: Date())
        session.receive(data)
        if let str = String(bytes: data, encoding: .utf8),
           str.contains("\u{1b}]") {
            parseOscSequences(str)
        }
        // Only a chunk with the sequence, or one that may end in its start;
        // its payload is ASCII: a chunk that cuts a character keeps it.
        if programStatusScanner.isWaiting || data.range(of: Self.programStatusPrefix) != nil
            || data.suffix(Self.programStatusPrefix.count).contains(0x1b) {
            let statuses = programStatusScanner.statuses(in: String(decoding: data, as: UTF8.self))
            if !statuses.isEmpty, let callback = onProgramStatus {
                DispatchQueue.main.async { statuses.forEach(callback) }
            }
        }
        // Output before the first typed input is launch noise — notably
        // `claude --continue` replaying old transcripts.
        if hasTypedInput, onLocalServerURL != nil {
            detectLocalServerURLs(in: buffer, count: bytesRead)
        }
    }

    private func detectLocalServerURLs(in buffer: [UInt8], count: Int) {
        if localServerStateIsStale {
            localServerStateIsStale = false
            localServerScanner = LocalServerURLScanner()
            localServerLastForwarded = [:]
        }
        let urls = buffer.withUnsafeBytes {
            localServerScanner.scan(UnsafeRawBufferPointer(rebasing: $0[..<count]))
        }
        guard !urls.isEmpty, let callback = onLocalServerURL else { return }
        // TUIs repaint the same URL on every frame; the workspace dedupes
        // per port, this just keeps the main queue quiet. Short enough not
        // to swallow the reprint of a quick server restart.
        let now = ProcessInfo.processInfo.systemUptime
        let fresh = urls.filter { url in
            if let last = localServerLastForwarded[url.port],
               now - last < Self.localServerForwardInterval { return false }
            if localServerLastForwarded.count >= 64 { localServerLastForwarded.removeAll() }
            localServerLastForwarded[url.port] = now
            return true
        }
        guard !fresh.isEmpty else { return }
        DispatchQueue.main.async { fresh.forEach(callback) }
    }

    /// Parse OSC sequences from terminal output (cwd, title).
    private func parseOscSequences(_ str: String) {
        // OSC 7 (cwd reporting): \e]7;file://hostname/path\a
        if let callback = onCwdChanged, str.contains("\u{1b}]7;") {
            if let range = str.range(of: "file://"),
               let end = str[range.upperBound...].firstIndex(where: { $0 == "\u{07}" || $0 == "\u{1b}" }) {
                let urlPart = String(str[range.lowerBound..<end])
                if let urlComps = URLComponents(string: urlPart),
                   let path = urlComps.path.removingPercentEncoding {
                    DispatchQueue.main.async { callback(path) }
                }
            }
        }
        // OSC 0/2 (terminal title): \e]0;title\a or \e]2;title\a
        if let titleCallback = onTitleChanged {
            for prefix in ["\u{1b}]0;", "\u{1b}]2;"] {
                if let range = str.range(of: prefix) {
                    let after = str[range.upperBound...]
                    if let end = after.firstIndex(where: { $0 == "\u{07}" || $0 == "\u{1b}" }) {
                        let title = String(after[..<end])
                        DispatchQueue.main.async { titleCallback(title) }
                        break
                    }
                }
            }
        }
        // OSC 9 (notification): Claude Code emits this when a turn
        // completes. Only forwarded for sessions WITHOUT hook coverage —
        // hooked sessions get the same signal from the Stop hook, and the
        // hasUserInput gate keeps startup replay from fabricating attention.
        if str.contains("\u{1b}]9;"),
           machine.hookAgent == nil, machine.hasUserInput,
           let callback = onOsc9Received {
            DispatchQueue.main.async { callback() }
        }
    }
}
