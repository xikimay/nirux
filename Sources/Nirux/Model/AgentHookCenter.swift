import Foundation

/// Routes agent hook events to the column that emitted them.
///
/// Claude Code hooks and Codex `notify` invoke `Nirux --hook`, which appends
/// one JSON line per event to `hook-events.jsonl` in the state directory.
/// This center watches the file AND its directory (appends only fire on the
/// file's own vnode), drains it debounced, and dispatches each event to the
/// matching column's PtySession via `resolver`.
///
/// The file doubles as a queue: events emitted while Nirux isn't running are
/// replayed on launch so agent statuses catch up immediately.
@MainActor
final class AgentHookCenter {
    static let shared = AgentHookCenter()

    /// Pure path computation — the hook-receiver process (nonisolated CLI
    /// entry point) writes here too.
    nonisolated static var eventsURL: URL {
        Persistence.stateDirectory.appendingPathComponent("hook-events.jsonl")
    }

    struct Resolution {
        let workspace: WorkspaceState
        let column: ColumnState
        let columnIndex: Int
        /// App active AND focused column of the active workspace — see
        /// resolveAgentColumn.
        let isUserFocused: Bool
        /// Whether the sidebar may hold the column's permission requests.
        let approvalHold: PermissionApprovalHold
    }

    struct AppliedEvent {
        let event: AgentHookEvent
        let resolution: Resolution
        /// What the column's Claude would restore to changed (another
        /// session, or its first prompt) — the state file must learn it.
        var claudeRestoreChanged = false
        /// The column's `claude`, when it confirmed it runs the event's
        /// session: the session history may record it.
        var claudeSessionAgent: ForegroundProcess?
    }

    /// Given NIRUX_AGENT_UUID, locate the owning column. Set by the shell.
    var resolver: ((String) -> Resolution?)?
    var onEventsApplied: (([AppliedEvent]) -> Void)?
    /// Sidebar approvals (Settings → Agents). Off, every request a
    /// receiver still holds for a decision is released.
    var approvalsEnabled = false
    /// Where sidebar decisions go; tests point it at a temporary directory.
    var approvalChannel: () -> PermissionApprovalChannel = { .standard }
    /// Reads Claude turn ends' final messages (Settings → Notifications):
    /// only a turn that asks something alerts. Nil: every turn end alerts,
    /// and the messages are dropped as they arrive.
    var turnEndClassifier: (any TurnEndClassifier)?
    /// Writes each Claude turn's status line on its task's row (Settings →
    /// Notifications). Nil: no line is written.
    var turnStatusWriter: (any TurnStatusWriter)?
    /// Something reads Claude turns' final messages. Not: they're dropped
    /// as they arrive.
    var readsFinalMessages: Bool { turnEndClassifier != nil || turnStatusWriter != nil }
    /// A turn end's status line settled on its task
    /// (`WorkspaceState.settleTurnStatus`): its row and the state file
    /// should learn it.
    var onTurnStatus: ((WorkspaceState) -> Void)?
    /// A turn end got its verdict: its prompt, which Nirux leaves alone
    /// meanwhile (`AgentStatusMachine.awaitsAnyVerdict`), may take the
    /// messages waiting for it.
    var onTurnEndSettled: (() -> Void)?
    /// An agent's turn just ended and is done, as far as hooks can tell
    /// (`AgentStatusMachine.isTurnDone`): its column shows it. Said once
    /// per turn end, when it is known: at Codex's report, at Claude's Stop
    /// when nothing reads its final message, else at its verdict. With
    /// the time the turn ended, for whoever shows it to check that it
    /// still stands by then.
    var onTurnDone: ((Resolution, TimeInterval) -> Void)?
    /// A turn end older than this is no news: a backlog replayed at
    /// launch, a verdict that took too long.
    static let turnDoneFreshness: TimeInterval = 30
    private var lastApprovalSweep: TimeInterval = 0

    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirFd: Int32 = -1
    private var pendingDrain: DispatchWorkItem?
    private var started = false

    /// Upper bound for one drain. If the app stays closed for days while
    /// hooked agents keep working the file grows unboundedly; only the tail
    /// matters (the latest status per session).
    private static let maxDrainBytes = 1_000_000

    func start() {
        guard !started else { return }
        started = true

        // Two watchers, because vnode events don't cover both cases:
        // - the DIRECTORY fires when hook-events.jsonl is created/renamed/
        //   deleted (first event ever, or the next event after a drain),
        // - the FILE itself fires when a receiver appends to it — appends
        //   don't touch directory metadata, so a dir-only watcher would
        //   miss them entirely.
        let dirPath = Persistence.stateDirectory.path
        dirFd = open(dirPath, O_RDONLY | O_DIRECTORY)
        if dirFd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: dirFd,
                eventMask: [.write, .extend, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.watchEventsFileIfPresent()
                self?.scheduleDrain()
            }
            source.setCancelHandler { [dirFd] in close(dirFd) }
            source.resume()
            dirSource = source
        } else {
            NSLog("[AgentHooks] cannot watch state dir %@ — hook status disabled", dirPath)
        }
        watchEventsFileIfPresent()

        // Replay anything queued while the app was closed.
        drain()
    }

    private func watchEventsFileIfPresent() {
        guard fileSource == nil else { return }
        let fd = open(Self.eventsURL.path, O_RDONLY)
        guard fd >= 0 else { return } // not created yet — the dir watcher will call back
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // The drain renames the file aside — the vnode we were watching
            // is now the processing file, so re-attach to the fresh log on
            // the next directory event instead of draining a deleted node.
            if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
                self.fileSource?.cancel()
                self.fileSource = nil
                return
            }
            self.scheduleDrain()
        }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        fileSource = source
    }

    /// Coalesce rapid hook bursts (PreToolUse storms) into one read.
    private func scheduleDrain() {
        guard pendingDrain == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.pendingDrain = nil
            self?.drain()
        }
        pendingDrain = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    /// Move the events file aside and process it, then delete. Receivers
    /// appending DURING the drain create a fresh log (O_CREAT) — nothing is
    /// lost between read and truncate, unlike read-then-truncate-in-place.
    /// Public so tests and the launch path can force a cycle.
    func drain() {
        let url = Self.eventsURL
        let aside = url.deletingPathExtension().appendingPathExtension("processing")
        let fm = FileManager.default
        try? fm.removeItem(at: aside)
        do {
            try fm.moveItem(at: url, to: aside)
        } catch {
            return // no log file (yet) — the common case
        }
        defer { try? fm.removeItem(at: aside) }

        guard var slice = try? Data(contentsOf: aside), !slice.isEmpty else { return }
        if slice.count > Self.maxDrainBytes {
            slice = slice.suffix(Self.maxDrainBytes / 4)
            // Drop the partial first line of the tail slice.
            if let nl = slice.firstIndex(of: 0x0A) { slice = slice.suffix(from: slice.index(after: nl)) }
        }

        let decoder = JSONDecoder()
        var appliedEvents: [AppliedEvent] = []
        var snapshot: ProcessSnapshot?
        for line in slice.split(separator: 0x0A) {
            guard let event = try? decoder.decode(AgentHookEvent.self, from: Data(line)) else { continue }
            if let appliedEvent = dispatch(event, snapshot: &snapshot) { appliedEvents.append(appliedEvent) }
        }
        // One sidebar refresh per drain, not per event: updateSidebar does a
        // full process-table scan, and a PreToolUse storm (or launch replay
        // of a long backlog) would otherwise run dozens back-to-back on the
        // main thread.
        if !appliedEvents.isEmpty { onEventsApplied?(appliedEvents) }
    }

    @discardableResult
    func dispatch(_ event: AgentHookEvent) -> AppliedEvent? {
        var snapshot: ProcessSnapshot?
        return dispatch(event, snapshot: &snapshot)
    }

    /// `snapshot` is taken on the first routed event and shared by the rest
    /// of the drain — one process-table scan per burst, not per event.
    private func dispatch(_ event: AgentHookEvent, snapshot: inout ProcessSnapshot?) -> AppliedEvent? {
        var event = event
        if !Self.keepsFinalMessage(readsFinalMessages: readsFinalMessages, foreground: nil) { event.finalMessage = nil }
        let resolution = event.agentUUID.flatMap { resolver?($0) }
        var claudeRestoreChanged = false
        var claudeSessionAgent: ForegroundProcess?
        var isApprovalEligible = false
        if let resolution, let pty = resolution.column.pty {
            let processes = snapshot ?? ProcessSnapshot()
            snapshot = processes
            let foregroundProcess = pty.foregroundProcess(snapshot: processes)
            switch event.kind {
            case .claude:
                // `claude -p` runs PermissionRequest hooks with no dialog to
                // show, then denies the call itself: nobody is asked.
                if event.name == .permissionRequest, Self.isHeadlessClaude(foregroundProcess) {
                    releaseHeldRequest(event)
                    return nil
                }
                switch resolution.column.admitClaudeHook(event, foregroundProcess: foregroundProcess, snapshot: processes) {
                case .rejected:
                    // Not the column's agent (a nested `claude -p` inheriting
                    // its UUID, a `claude` under Codex) or a session it left.
                    releaseHeldRequest(event)
                    return nil
                case .accepted:
                    break
                case .restoreChanged:
                    claudeRestoreChanged = true
                }
                let isFromOwnClaude = resolution.column.isFromOwnClaude(
                    event, foregroundProcess: foregroundProcess, snapshot: processes
                )
                // `claude -p` has no conversation to come back to.
                if isFromOwnClaude, !Self.isHeadlessClaude(foregroundProcess) {
                    claudeSessionAgent = foregroundProcess
                }
                if isFromOwnClaude, event.reportsAccount, let onNiruxAccount = event.onNiruxAccount, let foregroundProcess {
                    resolution.column.noteClaudeAccount(
                        onNiruxAccount: onNiruxAccount, of: foregroundProcess.instance, cwd: event.cwd
                    )
                }
                if event.name == .stop, !Self.keepsFinalMessage(readsFinalMessages: true, foreground: foregroundProcess) {
                    event.finalMessage = nil
                }
                isApprovalEligible = event.name == .permissionRequest && event.approvalRequestID != nil
                    && PermissionApproval.isDisplayable(toolName: event.toolName, text: event.approvalText)
                    && isFromOwnClaude
            case .codex:
                if Self.isNestedCodexHook(foregroundName: foregroundProcess?.name) { return nil }
            }
        }
        if event.name == .permissionRequest, event.approvalRequestID != nil,
           !Self.keepsApproval(
               eligible: approvalsEnabled && isApprovalEligible,
               hold: resolution?.approvalHold ?? .never,
               isSubagent: event.agentID != nil,
               deadline: event.approvalDeadline,
               now: Date().timeIntervalSince1970
           ) {
            releaseHeldRequest(event)
            event.approvalRequestID = nil
            event.approvalDeadline = nil
            event.approvalText = nil
        }
        if let resolution { _ = apply(event, to: resolution) }
        return resolution.map {
            AppliedEvent(
                event: event, resolution: $0, claudeRestoreChanged: claudeRestoreChanged,
                claudeSessionAgent: claudeSessionAgent
            )
        }
    }

    /// `event`, admitted, applied to its column: the requests it closed
    /// released, the alert it fires, then what follows a turn end (its
    /// verdict, its status line).
    @discardableResult
    func apply(_ event: AgentHookEvent, to resolution: Resolution) -> AgentHookOutcome {
        guard let pty = resolution.column.pty else { return AgentHookOutcome() }
        var event = event
        // The status line reads the message whether or not the classifier
        // does; the column reads it for the verdict only.
        let statusMessage = turnStatusWriter == nil ? nil : event.finalMessage
        if turnEndClassifier == nil { event.finalMessage = nil }
        let outcome = pty.applyAgentHook(event, isUserFocused: resolution.isUserFocused)
        for request in outcome.abandonedApprovals {
            release(request, agentUUID: event.agentUUID)
        }
        if outcome.firedAttention {
            resolution.column.notifyAgentAttention(reason: outcome.attention)
        }
        // (Read only for an event that ends a turn.)
        settleTurnEnd(
            of: event, outcome: outcome, in: resolution,
            waitsOnParent: resolution.workspace.waitsOnParent(resolution.column)
        )
        // Every turn end of the main thread the column took: watched or
        // not, ending on a question or not. One without a run leaves the
        // line from before it behind.
        if event.kind == .claude, event.name == .stop, event.agentID == nil, pty.isCurrentTurnEnd(event.timestamp),
           !(statusMessage.map { writeTurnStatus(of: $0, endedAt: event.timestamp, in: resolution.workspace) } ?? false) {
            resolution.workspace.forgetTurnStatus(turnEndedAt: event.timestamp)
        }
        return outcome
    }

    /// What follows `event` once its column took it, if it ended a turn:
    /// the final message is read for its verdict, or, with nothing to
    /// wait for (Codex's report, a Stop whose message nobody reads), the
    /// turn is done now (`onTurnDone`). `waitsOnParent`: a Mission child
    /// that asked its parent ended its turn to wait for the answer.
    func settleTurnEnd(
        of event: AgentHookEvent, outcome: AgentHookOutcome, in resolution: Resolution,
        waitsOnParent: @autoclosure () -> Bool
    ) {
        if let request = outcome.turnEnd, let agentUUID = event.agentUUID {
            classifyTurnEnd(request, agentUUID: agentUUID, waitsOnParent: waitsOnParent())
        } else if event.name == .turnComplete || event.name == .stop, !waitsOnParent() {
            reportTurnDone(endedAt: event.timestamp, in: resolution)
            noteQuestionWithoutVerdict(event, seen: resolution.isUserFocused)
        }
    }

    /// A Claude turn end that gets no verdict: nobody to alert (the user
    /// looks at its column, `seen`), or a dialog still open waits on the
    /// user first. When its final message ends on a question, it asks all
    /// the same: its column keeps saying so (`AgentStatusMachine.noteQuestion`).
    /// The message's own line, after the same moment's wait as a verdict
    /// (`waitBeforeAsking`). Only with the option that reads final messages
    /// on, at the end of that wait too. (A final message is the Stop's of
    /// a Claude main thread: no other event carries one.)
    private func noteQuestionWithoutVerdict(_ event: AgentHookEvent, seen: Bool) {
        guard let agentUUID = event.agentUUID, let message = event.finalMessage,
              let question = Self.endingQuestion(of: message)
        else { return }
        let delay = questionVerdictDelay
        questionNote = Task { @MainActor [weak self] in
            // Put behind already (a later Stop in the same drain, a replayed
            // backlog): no wait for it.
            guard let self, self.resolver?(agentUUID)?.column.pty?.isCurrentTurnEnd(event.timestamp) == true else { return }
            await self.waitBeforeAsking(delay)
            guard self.turnEndClassifier != nil, let resolution = self.resolver?(agentUUID),
                  resolution.column.pty?.noteAgentQuestion(question, in: message, endingTurnAt: event.timestamp, seen: seen) == true
            else { return }
            // No alert refreshes the sidebar for it, and no heartbeat with
            // Nirux in the background.
            resolution.workspace.onMetadataChanged?()
        }
    }

    /// The last of those notes, on its way or done. Tests wait for it.
    private(set) var questionNote: Task<Void, Never>?

    /// The line a final message ends on when it is a question: the
    /// message's own, a yes/no one when no "or" or question word says
    /// otherwise.
    static func endingQuestion(of message: String) -> TurnEndQuestion? {
        TurnEndText.questionLine(of: message).map { TurnEndQuestion(text: $0, isYesNo: TurnEndText.isYesNoQuestion($0)) }
    }

    /// The moment a turn end that ends on a question waits before it asks,
    /// as a model call would take: a Stop hook that blocked that end (a
    /// review gate) keeps the turn going, and its continuation puts the
    /// end behind first. Tests take the clock.
    var waitBeforeAsking: @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }

    /// Asks the classifier about a turn end, then applies its verdict. A
    /// Mission child that asked its parent before ending its turn waits on
    /// it, not on the user: nothing to alert the user for, and the turn
    /// isn't done either.
    func classifyTurnEnd(_ request: TurnEndRequest, agentUUID: String, waitsOnParent: Bool) {
        guard !waitsOnParent, let classifier = turnEndClassifier else {
            applyTurnEndVerdict(
                waitsOnParent ? .done : .unknown, for: request, agentUUID: agentUUID, reportsDone: !waitsOnParent
            )
            return
        }
        let endingQuestion = Self.endingQuestion(of: request.message)
        let questionDelay = questionVerdictDelay
        Task { @MainActor [weak self] in
            // Put behind already (a later Stop in the same drain, a replayed
            // backlog): no run for it.
            guard let self, self.awaitsVerdict(request, agentUUID: agentUUID) else { return }
            // Ends on a question: it asks, whatever a model would read,
            // after the moment's wait (a continuation puts this turn end
            // behind first: the verdict then drops, as a late one does).
            if let endingQuestion {
                await self.waitBeforeAsking(questionDelay)
                self.applyTurnEndVerdict(.asks(endingQuestion), for: request, agentUUID: agentUUID)
                return
            }
            let verdict = await classifier.classify(request.message)
            // Turned off meanwhile: every turn end alerts.
            self.applyTurnEndVerdict(self.turnEndClassifier == nil ? .unknown : verdict, for: request, agentUUID: agentUUID)
        }
    }

    /// Asks for the status line of the turn that ended at `time` in
    /// `workspace`, then settles it there (`WorkspaceState.settleTurnStatus`):
    /// meanwhile the row shows no line from an older turn. None for the
    /// Lead, whose row has no status line, nor for a turn end replayed at
    /// launch, which is no news. True when its run is on its way.
    @discardableResult
    func writeTurnStatus(of message: String, endedAt time: TimeInterval, in workspace: WorkspaceState) -> Bool {
        guard let writer = turnStatusWriter, !workspace.isLead, now() - time < Self.turnDoneFreshness,
              workspace.awaitTurnStatus(turnEndedAt: time)
        else { return false }
        Task { @MainActor [weak self, weak workspace] in
            // Put behind already (a later turn end in the same drain): no
            // run for it.
            guard let workspace, workspace.awaitedTurnStatus == time else { return }
            let status = await writer.status(of: message)
            guard let self else { return }
            // Turned off meanwhile: no line.
            if workspace.settleTurnStatus(self.turnStatusWriter == nil ? nil : status, turnEndedAt: time) {
                self.onTurnStatus?(workspace)
            }
        }
        return true
    }

    /// How long a turn end that ends on a question waits before it asks
    /// (see `classifyTurnEnd`); tests shorten it.
    var questionVerdictDelay: TimeInterval = 1.5

    private func awaitsVerdict(_ request: TurnEndRequest, agentUUID: String) -> Bool {
        resolver?(agentUUID)?.column.pty?.awaitsTurnEndVerdict(request) == true
    }

    /// The verdict on a turn end, applied to its column found again (the
    /// user may look at it now): an alert when the turn asks something, or
    /// when the classifier couldn't tell. The alert refreshes the sidebar
    /// and the Dock badge; nothing else a verdict does shows.
    func applyTurnEndVerdict(
        _ verdict: TurnEndVerdict, for request: TurnEndRequest, agentUUID: String, reportsDone: Bool = true
    ) {
        guard let resolution = resolver?(agentUUID), let pty = resolution.column.pty else { return }
        // A verdict that comes too late (a prompt, a later turn end) says
        // nothing of the column any more.
        let isAwaited = pty.awaitsTurnEndVerdict(request)
        if let reason = pty.applyTurnEndVerdict(verdict, for: request, isUserFocused: resolution.isUserFocused) {
            resolution.column.notifyAgentAttention(reason: reason)
        }
        if isAwaited, reportsDone { reportTurnDone(endedAt: request.turnEndedAt, in: resolution) }
        onTurnEndSettled?()
    }

    /// Tells `onTurnDone` about the turn end reported at `time`, if it is
    /// done and news.
    private func reportTurnDone(endedAt time: TimeInterval, in resolution: Resolution) {
        guard now() - time < Self.turnDoneFreshness, resolution.column.pty?.isAgentTurnDone(endedAt: time) == true
        else { return }
        onTurnDone?(resolution, time)
    }

    /// Epoch seconds; tests set the clock their events are stamped from.
    var now: () -> TimeInterval = { Date().timeIntervalSince1970 }

    /// Whether the sidebar holds a request its receiver waits on:
    /// `eligible` (the option is on, and the column's own `claude` asked
    /// for the column's session), the column's card can show the buttons
    /// (see `PermissionApprovalHold`), and the wait is not about to end.
    nonisolated static func keepsApproval(
        eligible: Bool,
        hold: PermissionApprovalHold,
        isSubagent: Bool,
        deadline: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        guard eligible, hold.holds(isSubagent: isSubagent), let deadline else { return false }
        return now < deadline - PermissionApproval.sendMargin
    }

    /// Clear decisions no receiver claimed, at most once a minute.
    func sweepApprovalsIfDue(now: TimeInterval = Date().timeIntervalSince1970) {
        guard approvalsEnabled, now - lastApprovalSweep >= 60 else { return }
        lastApprovalSweep = now
        approvalChannel().sweep()
    }

    /// Tell the receiver of a held PermissionRequest to stop waiting: the
    /// sidebar won't answer it.
    private func releaseHeldRequest(_ event: AgentHookEvent) {
        guard event.name == .permissionRequest, let requestID = event.approvalRequestID else { return }
        sendRelease(
            requestID: requestID, sessionID: event.sessionID, agentUUID: event.agentUUID,
            deadline: event.approvalDeadline
        )
    }

    func release(_ request: AgentPermissionRequest, agentUUID: String?) {
        guard let ticket = request.approval else { return }
        sendRelease(
            requestID: ticket.requestID, sessionID: request.sessionID, agentUUID: agentUUID,
            deadline: ticket.deadline
        )
    }

    private func sendRelease(requestID: String, sessionID: String?, agentUUID: String?, deadline: TimeInterval?) {
        let now = Date().timeIntervalSince1970
        // A receiver past its deadline is gone: nothing to release.
        guard let deadline, now < deadline else { return }
        approvalChannel().send(PermissionApprovalDecision(
            requestID: requestID,
            sessionID: sessionID ?? "",
            agentUUID: agentUUID ?? "",
            behavior: .release,
            issuedAt: now
        ))
    }

    /// Whether a Stop's final message goes on to the classifier and the
    /// status line: none reads it with both options off, and a `claude -p`
    /// run in the terminal asks nobody, and is no task, at its turn end.
    nonisolated static func keepsFinalMessage(readsFinalMessages: Bool, foreground: ForegroundProcess?) -> Bool {
        readsFinalMessages && !isHeadlessClaude(foreground)
    }

    nonisolated static func isHeadlessClaude(_ process: ForegroundProcess?) -> Bool {
        guard let process, process.name == "claude" else { return false }
        return process.hasFlag("-p") || process.hasFlag("--print")
    }

    /// `codex exec` (alias `e`): a run, not a conversation to come back to.
    /// The subcommand follows Codex's global options, and `codex` itself may
    /// be a script its runtime runs (`node …/bin/codex`, from npm or bun).
    nonisolated static func isHeadlessCodex(_ process: ForegroundProcess?) -> Bool {
        guard let process, process.name == "codex",
              let codex = process.arguments.firstIndex(where: {
                  (($0 as NSString).lastPathComponent as NSString).deletingPathExtension == "codex"
              })
        else { return false }
        var index = codex + 1
        while let argument = process.arguments[safe: index], argument != "--" {
            guard argument.hasPrefix("-") else { return argument == "exec" || argument == "e" }
            index += codexOptionsWithValue.contains(argument) ? 2 : 1
        }
        return false
    }

    /// Codex's global options whose value is the next argument.
    private nonisolated static let codexOptionsWithValue: Set<String> = [
        "-c", "--config", "--enable", "--disable", "--remote", "--remote-auth-token-env", "-i", "--image",
        "-m", "--model", "--local-provider", "-p", "--profile", "-s", "--sandbox", "-C", "--cd", "--add-dir",
        "-a", "--ask-for-approval"
    ]

    /// A Codex hook while another agent owns the terminal came from a
    /// `codex exec` that agent launched.
    nonisolated static func isNestedCodexHook(foregroundName: String?) -> Bool {
        guard let foregroundName, AgentStatusMachine.isRecognizedAgentProcess(foregroundName) else { return false }
        return foregroundName != "codex"
    }

    func stop() {
        pendingDrain?.cancel()
        pendingDrain = nil
        dirSource?.cancel()
        dirSource = nil
        dirFd = -1
        fileSource?.cancel()
        fileSource = nil
        started = false
    }
}
