import os
import AppKit

// MARK: - Mission messages that wait too long for a prompt: the row's line, the log, one more try

/// Mission messages waiting for an agent's prompt past
/// `NiruxShellView.missionMessageStallAge` while the agent doesn't work.
struct SidebarWaitingMessages: Hashable {
    let count: Int
    /// When the oldest was sent.
    let since: TimeInterval
    /// Why the oldest isn't typed; nil: the prompt is free.
    let refusal: AgentPromptRefusal?
    /// The prompt looks free, yet the tries at typing failed.
    var untypable = false
    /// Held by a `claude` with no prompt since it started that doesn't say
    /// it sits at its prompt, which would take one on the user's word now:
    /// the row offers to type it (`NiruxShellView.typeWaitingMessagesNow`).
    var offersTypeNow = false
    /// With the offer, that `claude`: the offer is for it, not one started
    /// since.
    var heldBy: ProcessInstance?
    /// The agent they wait for, as the row names it.
    var agent = "Claude Code"
    /// "2 messages waiting since 22:21 · a dialog may be open", written at
    /// the check: the day shows once it is another.
    let line: String

    init(
        count: Int, since: TimeInterval, refusal: AgentPromptRefusal?, untypable: Bool = false, offersTypeNow: Bool = false,
        heldBy: ProcessInstance? = nil, agent: String = "Claude Code", now: TimeInterval
    ) {
        self.count = count
        self.since = since
        self.refusal = refusal
        self.untypable = untypable
        self.offersTypeNow = offersTypeNow
        self.heldBy = heldBy
        self.agent = agent
        let time = ProjectBoard.clockTime(Date(timeIntervalSince1970: since), now: Date(timeIntervalSince1970: now))
        line = "\(count == 1 ? "1 message" : "\(count) messages") waiting since \(time) · "
            + Self.why(refusal, untypable: untypable, agent: agent).short
    }

    var tooltip: String {
        let why = "Mission messages not typed into this agent's prompt yet: \(Self.why(refusal, untypable: untypable, agent: agent).long)."
        return offersTypeNow ? why + " " + Self.typeNowAdvice : why
    }

    static let typeNowAdvice = "If its terminal shows its prompt, empty, Type it now types one of them; the rest follow its turn. "
        + "Click the line to see its terminal."

    /// Why they wait: a few words for the row, the whole of it for the
    /// tooltip. `agent`: "Claude Code", or "Codex", whose messages go into
    /// its own queue.
    static func why(_ refusal: AgentPromptRefusal?, untypable: Bool, agent: String = "Claude Code") -> (short: String, long: String) {
        let codex = agent == "Codex"
        return switch refusal {
        case .noClaude?: ("no \(agent) there", "its terminal doesn't run \(agent)")
        case .restarted?: (
            "its \(agent) restarted",
            "its \(agent) restarted since, and Nirux types a message sent to the one before into no other"
        )
        case .noPromptYet? where agent == "Antigravity": (
            "no turn ended since it started",
            "its Antigravity hasn't ended a turn since it started, where a screen of its own may be up; they go in after its first one"
        )
        case .noPromptYet? where codex: (
            "no state from Codex yet",
            "its Codex hasn't reported its state since it started (Codex 0.167 or later does); they go in once it reports its turn over"
        )
        case .noPromptYet?: (
            "no prompt since it started",
            "its Claude Code took no prompt since it started and doesn't say it sits at its prompt (a screen of its own may be up); "
                + "they go in once it does, or after its first prompt"
        )
        case .noConversation?: (
            "its conversation isn't known yet",
            "Nirux doesn't know yet which conversation its Codex runs; it learns it when the turn its launch prompt started ends"
        )
        case .dialog?: ("a dialog may be open", "a dialog may be open there; they go in once it closes and the turn ends")
        case .failedTurn?: ("its last turn failed", "its last turn failed; they go in after its next turn")
        case .draft?: (
            "held by a draft until its next prompt",
            "keys reached its prompt since its last prompt, so it may hold a draft; they go in after its next prompt"
        )
        case .working?, .verdict?: ("its turn isn't over", "its turn isn't over yet")
        case nil where untypable && codex: (
            "Codex didn't take them",
            "its Codex reports its turn over, but it didn't take them into its queue"
        )
        case nil where untypable: (
            "typing failed",
            "its prompt looks free, but typing them failed; they go in at its next turn end if they can"
        )
        case nil: ("Nirux tries again", "its prompt looks free, and Nirux tries again")
        }
    }
}

/// What the shell keeps of waiting messages between refreshes.
struct MissionWaitState {
    /// The last check, by column, and when it ran: the sidebar asks several
    /// times a second, and the setting it reads is on disk.
    var shown: [UUID: SidebarWaitingMessages] = [:]
    var checkedAt: TimeInterval?
    /// "<message id> <reason>" of each line written to the log, while the
    /// message waits: one line per message and reason.
    var logged: Set<String> = []
    var lastRetryAt: TimeInterval = 0
    /// Tries at typing each message whose prompt looked free.
    var tries: [String: Int] = [:]
    /// Mission handoffs, read from disk when the waiting messages change.
    var handoffsEnabled: (for: Set<String>, enabled: Bool)?
    /// When Nirux last typed into each column: until that prompt goes in, its
    /// text reads as a draft.
    var typedAt: [UUID: TimeInterval] = [:]
    /// Mission messages Nirux is typing (a long paste, then Enter), or typed
    /// without being able to record it: none is typed or given up twice.
    var typing: Set<String> = []
    /// Each `claude` whose session record the log said it couldn't find,
    /// read or see a status in: once per process, while it runs.
    var recordIssuesLogged: Set<ProcessInstance> = []
    /// Each `claude` whose record the last check couldn't read: said only
    /// at the second read in a row (one may land mid-write).
    var unreadableRecords: Set<ProcessInstance> = []
    /// Session records read since the last check, by process: what the
    /// sidebar's refreshes read between checks, a read taking a sysctl and a
    /// file (`NiruxShellView.sessionRecord(of:)`).
    var recordReadings: [ProcessInstance: ClaudeSessionRecord.Reading] = [:]
    /// A typing pass waits for a queue a writer held (`hooksReadBeforeTyping`).
    var typingPassSoon = false
    /// How long Codex or Antigravity may take to start a message Nirux
    /// handed it at a free prompt before its sender hears it hasn't
    /// (`checkStarted`).
    var startWait: TimeInterval = 20
    /// Columns whose Codex is being handed a message: one at a time, so
    /// that its queue keeps their order.
    var codexQueuing: Set<UUID> = []

    /// Nirux typed into `column`'s prompt: it says nothing of it until the
    /// next check.
    mutating func noteTyped(into column: ColumnState, at time: TimeInterval) {
        typedAt[column.id] = time
        shown[column.id] = nil
    }
}

/// `log show --predicate 'subsystem == "com.xikimay.nirux" AND category == "missions"'`.
enum MissionWaitLog {
    static let logger = Logger(subsystem: "com.xikimay.nirux", category: "missions")
}

extension NiruxShellView {
    /// How long a message may wait for the prompt of an agent that doesn't
    /// work before its row says so and the log says why: well past a turn
    /// end's verdict.
    nonisolated static let missionMessageStallAge: TimeInterval = 180
    nonisolated static let missionWaitCheckInterval: TimeInterval = 5
    /// How long a message may wait over a draft, or at a free prompt, before
    /// the log says why: past a turn end's verdict.
    nonisolated static let missionWaitLogAge: TimeInterval = 30
    /// What Nirux types goes in within a second: a draft before then is
    /// its own text.
    nonisolated static let typedTextGrace: TimeInterval = 10

    /// Tries at typing a message whose prompt looks free, before its row
    /// says typing failed.
    nonisolated static let missionTypingTries = 3

    private struct WaitingMessage {
        let id: String
        let kind: String
        let sentAt: TimeInterval
        let runningSince: TimeInterval
        /// The agent kind it goes to (`recipientKind`): a Codex child's goes
        /// into Codex's queue (`queueForCodex`).
        var agentKind = NiruxApp.WorkspaceAgent.claude.rawValue

        var toCodex: Bool { agentKind == NiruxApp.WorkspaceAgent.codex.rawValue }
        var agentName: String { Mission.agentName(ofKind: agentKind) ?? agentKind }
    }

    /// Tells a `tell`'s sender, once, what holds it when it is still
    /// untyped `MissionEventCLI.instructionHeldNotice` after it was sent;
    /// gives it up, telling the sender, once its task closed, its Claude Code
    /// restarted on another conversation, or its day ran out. One whose day ran out long ago (an
    /// older build's, kept an hour) is given up silently.
    func sweepWaitingInstructions(now: TimeInterval, snapshot: ProcessSnapshot, store: MissionStore = .shared) {
        var held: [(delivery: MissionStore.AcceptedEvent, text: String)] = []
        var givenUp: [(delivery: MissionStore.AcceptedEvent, text: String)] = []
        // Read once, and only for a notice that names what holds a message.
        lazy var handoffsEnabled = missionWaits.handoffsEnabled?.enabled ?? Self.currentMissionHandoffsEnabled()
        for delivery in store.untypedInstructions() where !missionWaits.typing.contains(delivery.event.id) {
            let (mission, event) = (delivery.mission, delivery.event)
            let child = missionEnd(mission, parent: false)
            let sent = ProjectBoard.clockTime(Date(timeIntervalSince1970: event.timestamp), now: Date(timeIntervalSince1970: now))
            let yours = "Your message to “\(MissionPromptText.quoted(child?.workspace.title ?? mission.branch))” (sent \(sent))"
            guard let child, !child.workspace.isClosing else {
                givenUp.append((delivery, "\(yours) was never typed: its task closed first."))
                continue
            }
            guard let column = child.column else {
                givenUp.append((delivery, "\(yours) was never typed: its agent's terminal closed first."))
                continue
            }
            let since = runningSince(of: event, in: column, snapshot: snapshot, now: now)
            let agent = mission.childAgentName
            let refusal = agent == "Codex" ? column.codexMissionRefusal(runningSince: since, snapshot: snapshot)
                : column.pty?.missionPromptRefusal(
                    runningSince: since, snapshot: snapshot, agent: mission.childAgentKind, now: now, record: sessionRecord(of:)
                ) ?? .noClaude
            let holder = {
                agent == nil ? "its agent hasn't collected it"
                    : !mission.isCarried(handoffsEnabled: handoffsEnabled) ? "Mission handoffs are off"
                    : SidebarWaitingMessages.why(
                        refusal, untypable: self.missionWaits.tries[event.id, default: 0] >= Self.missionTypingTries, agent: agent ?? ""
                    ).short
            }
            // Restarted, `runningSince` says, on another conversation once it confirmed one.
            let other = conversation(of: column, foreground: column.pty?.foregroundProcess(snapshot: snapshot)) != nil
            if agent == "Codex", column.runsUnprovableCodex(snapshot: snapshot) {
                givenUp.append((delivery, "\(yours) won't be handed over: its Codex was started without a prompt, so Nirux can't "
                    + "tell which of its conversations is the task's. Give it to the user instead."))
            } else if refusal == .restarted, other, let agent {
                givenUp.append((delivery, "\(yours) won't be typed: its \(agent) restarted on another conversation, and Nirux "
                    + "types a message only into the conversation it was sent to. Send it again if it still applies."))
            } else if now >= event.instructionDeadline {
                // One an older build recorded had an hour.
                let span = event.typableUntil == nil ? "an hour" : "a day"
                givenUp.append((delivery, "\(yours) was never typed: its prompt wasn't free for \(span) (\(holder())). "
                    + "Send it again if it still applies."))
            } else if event.heldNoticeAt == nil, now - event.timestamp >= MissionEventCLI.instructionHeldNotice {
                held.append((delivery, "\(yours) isn't typed yet: \(holder()). Nirux keeps it for its next free prompt, "
                    + "a day at most."))
            }
        }
        guard !(held.isEmpty && givenUp.isEmpty), store.noteInstructions(
            heldNotice: Set(held.map(\.delivery.event.id)), expired: Set(givenUp.map(\.delivery.event.id)), at: now
        ) else { return }
        for (delivery, text) in held + givenUp where now - delivery.event.instructionDeadline < MissionEventCLI.parentMessageLifetime {
            let sender = delivery.event.leadSender
                ?? NewTask.MissionParent(workspaceID: delivery.mission.parentWorkspaceID, agentUUID: delivery.mission.parentAgentUUID)
            tellProposer(sender, text)
        }
    }

    /// Keeps, for the sidebar to read (`missionWaits.shown`, by
    /// `ColumnState.id`), the Mission messages and Lead notices waiting for
    /// each column's prompt past `missionMessageStallAge` while its agent
    /// doesn't work: not those an agent other than Claude Code collects
    /// itself, nor those Nirux types into no `claude` running now (sent to
    /// one since restarted, or to one without Nirux's hooks). Each message's
    /// reason, with what it was read from, goes to the log once
    /// (`missionWaitLogAge`). A free prompt gets a few more tries
    /// (`missionTypingTries`), at most once a stuck-watch interval: a prompt
    /// can free up with no turn end to try at (a subagent's dialog closing
    /// after the turn). The heartbeat runs it, the stuck watch in the
    /// background.
    func checkMissionWaits(snapshot: ProcessSnapshot, now: TimeInterval, store: MissionStore = .shared) {
        guard !snapshot.isEmpty else { return }
        if let checkedAt = missionWaits.checkedAt, (0..<Self.missionWaitCheckInterval).contains(now - checkedAt) { return }
        missionWaits.checkedAt = now
        missionWaits.recordReadings = [:]
        sweepWaitingInstructions(now: now, snapshot: snapshot, store: store)
        missionWaits.typedAt = missionWaits.typedAt.filter { now - $0.value < Self.typedTextGrace }
        var waiting: [UUID: (column: ColumnState, messages: [WaitingMessage])] = [:]
        func add(_ column: ColumnState?, _ message: WaitingMessage) {
            guard let column else { return }
            waiting[column.id, default: (column, [])].messages.append(message)
        }
        let deliveries = store.pendingPromptDeliveries(now: now)
        let deliveryIDs = Set(deliveries.map(\.event.id))
        if !deliveries.isEmpty {
            let handoffsEnabled = missionWaits.handoffsEnabled.flatMap { $0.for == deliveryIDs ? $0.enabled : nil }
                ?? Self.currentMissionHandoffsEnabled()
            missionWaits.handoffsEnabled = (deliveryIDs, handoffsEnabled)
            for delivery in deliveries where delivery.mission.isCarried(handoffsEnabled: handoffsEnabled) {
                // A child Nirux delivers nothing to collects its own.
                guard Self.goesToParent(delivery.event) || delivery.mission.childAgentName != nil else { continue }
                let recipient = missionRecipient(of: delivery)
                add(recipient, WaitingMessage(
                    id: delivery.event.id, kind: delivery.event.kind.rawValue, sentAt: delivery.event.timestamp,
                    runningSince: runningSince(of: delivery.event, in: recipient, snapshot: snapshot, now: now),
                    agentKind: Self.recipientKind(of: delivery)
                ))
            }
        }
        for notice in pendingLeadNotices where now - notice.queuedAt < MissionEventCLI.parentMessageLifetime {
            add(workspaces.first { $0.id == notice.workspaceID && !$0.isClosing }?.columns.first { $0.agentUUID == notice.agentUUID },
                WaitingMessage(id: "notice-\(notice.queuedAt)", kind: "notice", sentAt: notice.queuedAt, runningSince: now))
        }
        var shown: [UUID: SidebarWaitingMessages] = [:]
        var retries: [String] = []
        var asksCodex = false
        // Freed by its REPL's word, with no turn end to type them at: at once.
        var firstPrompts: [String] = []
        for (id, entry) in waiting {
            let pty = entry.column.pty
            let foreground = pty?.foregroundProcess(snapshot: snapshot)
            let atFirstPrompt = foreground.map { pty?.agentTookPrompt(since: $0) == false } ?? false
            let refused = entry.messages.compactMap { message -> (message: WaitingMessage, refusal: AgentPromptRefusal?)? in
                if message.toCodex {
                    return (message, entry.column.codexMissionRefusal(runningSince: message.runningSince, snapshot: snapshot))
                }
                // Another agent in front: what holds its own messages, if any, says why.
                if let name = foreground?.name, name != message.agentKind, AgentStatusMachine.isRecognizedAgentProcess(name) { return nil }
                let refusal = pty.map {
                    $0.missionPromptRefusal(
                        runningSince: message.runningSince, snapshot: snapshot, agent: message.agentKind, now: now, record: sessionRecord(of:)
                    )
                } ?? .noClaude
                guard refusal != .draft || missionWaits.typedAt[id] == nil else { return nil }
                return (message, refusal)
            }
            // A draft or a free prompt, which nothing on screen explains, says
            // so within seconds; anything else, a long turn too, after a
            // stall's length.
            let overdue = refused.filter { message, refusal in
                now - message.sentAt >= (refusal == nil || refusal == .draft ? Self.missionWaitLogAge : Self.missionMessageStallAge)
            }
            func free(_ messages: [(message: WaitingMessage, refusal: AgentPromptRefusal?)]) -> [String] {
                messages.filter {
                    $0.refusal == nil && !missionWaits.typing.contains($0.message.id)
                        && missionWaits.tries[$0.message.id, default: 0] < Self.missionTypingTries
                }.map(\.message.id)
            }
            // Tries are counted at the overdue ones' pace; a Codex message's
            // only when Codex refuses it (`queueForCodex`): a retry just asks.
            retries += free(overdue.filter { !$0.message.toCodex })
            asksCodex = asksCodex || !free(overdue.filter(\.message.toCodex)).isEmpty
            if atFirstPrompt { firstPrompts += free(refused) }
            if let foreground, refused.contains(where: { $0.refusal == .noPromptYet && $0.message.agentKind == "claude" }) {
                logSessionRecordIssue(of: foreground.instance, agentUUID: entry.column.agentUUID, now: now)
            }
            for (message, refusal) in overdue {
                let reason = refusal?.rawValue ?? "free"
                guard missionWaits.logged.insert("\(message.id) \(reason)").inserted else { continue }
                let waited = Int(min(now - message.sentAt, MissionEventCLI.parentMessageLifetime * 24))
                sideEffects.logMissionWait(
                    "untyped mission message id=\(message.id.prefix(8)) kind=\(message.kind) "
                        + "agent=\(entry.column.agentUUID?.prefix(8) ?? "-") waited=\(waited)s reason=\(reason) messages=\(refused.count) "
                        + "fg=\(foreground.map { "\($0.name)/\(Int(max(now - $0.instance.startedAt, 0)))s" } ?? "-") "
                        + ((foreground?.name == AgentProgramStatus.codex ? pty?.codexFacts(now: now)
                            : foreground?.name == AgentProgramStatus.agy ? pty?.agyFacts(now: now)
                            : pty?.missionPromptFacts(now: now, snapshot: snapshot, record: sessionRecord(of:))) ?? "")
                )
            }
            let typable = refused.filter {
                $0.refusal != .working && $0.refusal != .restarted
                    && ($0.refusal != .noPromptYet || pty?.agentHookKind == "claude" || $0.message.agentKind != "claude")
            }
            guard typable.contains(where: { now - $0.message.sentAt >= Self.missionMessageStallAge }),
                  let oldest = typable.min(by: { $0.message.sentAt < $1.message.sentAt })
            else { continue }
            let offersTypeNow = atFirstPrompt && oldest.refusal != nil
                && pty?.missionPromptRefusal(
                    runningSince: oldest.message.runningSince, snapshot: snapshot, seenByUser: true, now: now, record: sessionRecord(of:)
                ) == nil
            shown[id] = SidebarWaitingMessages(
                count: typable.count, since: oldest.message.sentAt, refusal: oldest.refusal,
                untypable: oldest.refusal == nil && missionWaits.tries[oldest.message.id, default: 0] >= Self.missionTypingTries,
                offersTypeNow: offersTypeNow, heldBy: offersTypeNow ? foreground?.instance : nil,
                agent: oldest.message.agentName, now: now
            )
        }
        let pending = Set(waiting.values.flatMap { $0.messages.map(\.id) })
        missionWaits.logged = missionWaits.logged.filter { pending.contains(String($0.prefix { $0 != " " })) }
        missionWaits.tries = missionWaits.tries.filter { pending.contains($0.key) }
        missionWaits.shown = shown
        missionWaits.recordIssuesLogged = missionWaits.recordIssuesLogged.filter(snapshot.contains)
        missionWaits.unreadableRecords = missionWaits.unreadableRecords.filter(snapshot.contains)
        let retryDue = (!retries.isEmpty || asksCodex) && now - missionWaits.lastRetryAt >= Self.stuckWatchInterval
        if retryDue {
            missionWaits.lastRetryAt = now
            for retry in retries { missionWaits.tries[retry, default: 0] += 1 }
        }
        if retryDue || !firstPrompts.isEmpty { DispatchQueue.main.async { [weak self] in self?.typeMissionMessages() } }
    }

    /// The session record of `process` as the last check read it, read now
    /// if it didn't (`MissionWaitState.recordReadings`).
    func sessionRecord(of process: ProcessInstance) -> ClaudeSessionRecord.Reading {
        if let reading = missionWaits.recordReadings[process] { return reading }
        let reading = PtySession.sessionRecord(of: process)
        missionWaits.recordReadings[process] = reading
        return reading
    }

    /// "Type it now" clicked on a row whose messages wait for a `claude` with
    /// no prompt since it started (`SidebarWaitingMessages.offersTypeNow`):
    /// the user says it sits at its prompt. Its terminal not on screen (another
    /// workspace, or scrolled out of view), the click shows it first, for
    /// them to look. Then one message goes in, as
    /// the row showed (`since`, its oldest's; the same `claude`), and as
    /// `ClaudeSessionRecord.Reading.allowsTypingOnSight` allows; the rest
    /// follow its turn.
    func typeWaitingMessagesNow(workspaceIndex: Int, columnIndex: Int, since: TimeInterval, tries: Int = 2) {
        // A hook may still wait out the queue's drain debounce.
        AgentHookCenter.shared.drain()
        let snapshot = ProcessSnapshot()
        // An empty process table says nothing of its claude: read it once more.
        guard !snapshot.isEmpty else {
            guard tries > 1 else { return showToast("Nirux couldn't read the running processes: try again") }
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.typeWaitingMessagesNow(workspaceIndex: workspaceIndex, columnIndex: columnIndex, since: since, tries: tries - 1)
            }
        }
        guard let column = workspaces[safe: workspaceIndex]?.columns[safe: columnIndex], let pty = column.pty,
              let waiting = missionWaits.shown[column.id], waiting.offersTypeNow, waiting.since == since,
              waiting.heldBy == pty.foregroundProcess(snapshot: snapshot)?.instance
        else { return showToast("Those messages changed: see the row again") }
        guard activeWSIndex == workspaceIndex, workspaces[workspaceIndex].showsColumn(at: columnIndex) else {
            switchToWorkspace(workspaceIndex, column: columnIndex)
            return showToast("Check that its prompt is empty, then Type it now again")
        }
        let outcome = typeMissionMessages(seenAtPrompt: column.id)
        updateSidebar(snapshot: snapshot)
        showToast(Self.typedOnSightText(outcome))
    }

    /// The toast after Type it now.
    static func typedOnSightText(_ outcome: TypedOnSight?) -> String {
        switch outcome {
        case .typed?: "Typed one; the rest follow its turn"
        case .refused(.noPromptYet?)?: "Nothing typed: Claude Code shows a screen of its own there, or its last turn isn't over"
        case .refused(let refusal?)?: "Nothing typed: \(SidebarWaitingMessages.why(refusal, untypable: false).short)"
        case .refused(nil)?: "Nothing typed: it couldn't be typed"
        case nil: "Nothing typed: none waits for its prompt now, or one is on its way"
        }
    }

    /// Writes to the log, once per process, that the session record of
    /// `process`, a `claude` messages wait on, is missing, unreadable at two
    /// reads in a row, or without a status of its own, past
    /// `missionWaitLogAge` (Claude Code writes it once it registered, the
    /// status once its REPL is up): it may have moved it, and they wait for
    /// its first prompt.
    private func logSessionRecordIssue(of process: ProcessInstance, agentUUID: String?, now: TimeInterval) {
        guard now - process.startedAt >= Self.missionWaitLogAge, !missionWaits.recordIssuesLogged.contains(process) else { return }
        let reading = sessionRecord(of: process)
        let issue = reading.isIssue(for: process, unreadableBefore: missionWaits.unreadableRecords.contains(process))
        if reading == .unreadable { missionWaits.unreadableRecords.insert(process) } else { missionWaits.unreadableRecords.remove(process) }
        guard issue else { return }
        missionWaits.recordIssuesLogged.insert(process)
        sideEffects.logMissionWait(
            "claude session record \(reading.facts(of: process, now: now)) agent=\(agentUUID?.prefix(8) ?? "-") "
                + "fg=claude/\(Int(max(now - process.startedAt, 0)))s: messages wait for its first prompt"
        )
    }
}
