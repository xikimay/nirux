import Foundation
import NiruxCore

/// Mission messages a hook of the agent takes instead of typing
/// (docs/design/mission-delivery.md): posted to the mailbox while a waiter
/// waits on the recipient's conversation, recorded once its transcript shows
/// the model took one in.
extension NiruxShellView {
    /// Leaves `delivery` to the waiter hook of `column`'s `claude`
    /// (`foreground`); false when typing carries it. `places`: the mailbox's
    /// at the start of the pass; `text`: the letter's, read only to post it;
    /// `enabled`: the pilot is on in Settings, else nothing new is posted.
    func leaveToHook(
        _ delivery: MissionStore.AcceptedEvent, in column: ColumnState, foreground: ForegroundProcess?,
        places: [String: MissionLetterPlace], now: TimeInterval, enabled: Bool, text: () -> String?
    ) -> Bool {
        let mailbox = MissionWaitHook.mailbox
        let id = delivery.event.id
        let recipient = foreground?.agent == .claude ? conversation(of: column, foreground: foreground) : nil
        let sentTo = delivery.event.kind == .instruction ? delivery.event.childSessionID : nil
        var place = places[id]
        while true {
            let ended = place.map { place in
                guard case .claimed(let conversation, let claimedAt) = place else { return false }
                return !Self.claudeRuns(conversation, since: claimedAt, in: mailbox)
            } ?? false
            let step = MissionDeliveryPolicy.hookStep(
                place: place, recipient: recipient, ended: ended, sentTo: sentTo, isArmed: { enabled && mailbox.isArmed($0) }
            )
            switch step {
            case .leave:
                missionWaits.handedToHooks[id] = missionWaits.handedToHooks[id] ?? now
                return true
            case .release:
                guard let claim = mailbox.claims().first(where: { $0.letter.id == id }) else {
                    place = nil
                    continue
                }
                if settle(claim, sessionEnded: true) == .recorded { return true }
                place = nil
            case .retract(let conversation):
                switch try? mailbox.retract(id, from: conversation) {
                case .retracted?: place = .owed(conversation: conversation)
                case .unknown?: place = nil
                // A waiter claimed it meanwhile; a disk error tries again next pass.
                case .claimed?, nil:
                    missionWaits.handedToHooks[id] = missionWaits.handedToHooks[id] ?? now
                    return true
                }
            case .post(let conversation):
                guard let text = text(), (try? mailbox.post(.init(id: id, text: text, postedAt: now), to: conversation)) != nil else {
                    missionWaits.handedToHooks[id] = nil
                    return false
                }
                missionWaits.handedToHooks[id] = missionWaits.handedToHooks[id] ?? now
                return true
            case .type:
                missionWaits.handedToHooks[id] = nil
                return false
            }
        }
    }

    /// Settles the claims of each session a hook event of `events` ends a
    /// turn of, or ends: see `settle`.
    func settleHookClaims(after events: [AgentHookEvent]) {
        let ends = events.filter {
            $0.kind == .claude && $0.agentID == nil && $0.sessionID != nil && [.stop, .stopFailure, .sessionEnd].contains($0.name)
        }
        guard !ends.isEmpty else { return }
        for claim in MissionWaitHook.mailbox.claims() {
            let later = ends.filter { $0.sessionID == claim.conversation && $0.timestamp >= claim.claimedAt }
            guard !later.isEmpty else { continue }
            settle(claim, sessionEnded: later.contains { $0.name == .sessionEnd })
        }
    }

    /// At launch: each claim the model took in counts as delivered; the
    /// rest, whose claude went with the last run, go again (`settle`).
    func settleMissionMailbox() {
        guard MissionStore.shared.ensureLoaded() else { return }
        let mailbox = MissionWaitHook.mailbox
        for claim in mailbox.claims() {
            settle(claim, sessionEnded: !Self.claudeRuns(claim.conversation, since: claim.claimedAt, in: mailbox))
        }
        mailbox.sweep(now: Date().timeIntervalSince1970)
    }

    enum ClaimSettlement: Equatable {
        /// The model took it in: delivered.
        case recorded
        /// Its session ended first: it goes again.
        case released
        /// Its turn may still read it.
        case kept
    }

    /// Records `claim` as delivered once its session's transcript shows the
    /// model read it; else frees it to go again when `sessionEnded`.
    @discardableResult
    func settle(_ claim: MissionMailbox.Claim, sessionEnded: Bool) -> ClaimSettlement {
        let mailbox = MissionWaitHook.mailbox
        let read = MissionWaitHook.modelRead(claim.letter, claimedAt: claim.claimedAt, transcript: mailbox.transcript(of: claim.conversation))
        guard read || sessionEnded else { return .kept }
        if read { recordHookDelivery(of: claim) }
        try? mailbox.forget(claim)
        missionWaits.handedToHooks[claim.letter.id] = nil
        return read ? .recorded : .released
    }

    /// Whether a `claude` started before `claimedAt` still runs
    /// `conversation`, stopped (Ctrl-Z) too: the one whose waiter claimed.
    nonisolated static func claudeRuns(_ conversation: String, since claimedAt: TimeInterval, in mailbox: MissionMailbox) -> Bool {
        mailbox.processes(running: conversation).contains { ProcessInstance.running(pid: $0).map { $0.startedAt <= claimedAt } ?? false }
    }

    /// Done with the letter of `id` Nirux took back, once typed.
    func letterTyped(_ id: String) {
        let mailbox = MissionWaitHook.mailbox
        guard case .owed(let conversation)? = mailbox.places()[id] else { return }
        try? mailbox.markTyped(id, in: conversation)
    }

    /// Drops the letters of messages Nirux no longer delivers (`pending`:
    /// the ones it does): expired, given up, or their Mission closed. A claim
    /// waits for its turn's end, which settles it.
    func withdrawStaleLetters(pending: Set<String>) {
        let stale = Set(missionWaits.handedToHooks.keys).subtracting(pending)
        guard !stale.isEmpty else { return }
        let mailbox = MissionWaitHook.mailbox
        let places = mailbox.places()
        for id in stale {
            switch places[id] {
            case .waiting(let conversation)?:
                // A waiter that claimed it meanwhile keeps it; a disk error tries again.
                guard (try? mailbox.retract(id, from: conversation)) == .retracted else { continue }
                try? mailbox.markTyped(id, in: conversation)
            case .owed(let conversation)?:
                try? mailbox.markTyped(id, in: conversation)
            case .claimed?:
                continue
            case nil:
                break
            }
            missionWaits.handedToHooks[id] = nil
        }
    }

    /// Records `claim`'s message as delivered, if Nirux still delivered it
    /// when the hook took it: a question older than an hour then is no
    /// longer typed, but one claimed sooner counts.
    private func recordHookDelivery(of claim: MissionMailbox.Claim) {
        guard let mission = MissionStore.shared.missions.first(where: { $0.events.contains { $0.id == claim.letter.id } }),
              let event = mission.events.first(where: { $0.id == claim.letter.id }),
              MissionStore.isPendingDelivery(event, in: mission, now: claim.claimedAt)
        else { return }
        finishTyping(.init(mission: mission, event: event), .sent, at: claim.claimedAt)
        updateSidebar()
    }
}
