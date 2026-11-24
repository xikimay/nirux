import Foundation
import NiruxCore

/// Mission messages a hook of the agent takes instead of typing
/// (docs/design/mission-delivery.md): posted to the mailbox while a waiter
/// waits on the recipient's conversation, recorded once the turn that took
/// one ends.
extension NiruxShellView {
    /// Leaves `delivery` to the waiter hook of `column`'s `claude`
    /// (`foreground`); false when typing carries it. `places`: the mailbox's
    /// at the start of the pass; `text`: the letter's, read only to post it.
    func leaveToHook(
        _ delivery: MissionStore.AcceptedEvent, in column: ColumnState, foreground: ForegroundProcess?, snapshot: ProcessSnapshot,
        places: [String: MissionLetterPlace], now: TimeInterval, text: () -> String?
    ) -> Bool {
        let mailbox = MissionWaitHook.mailbox
        let id = delivery.event.id
        let runsClaude = foreground?.agent == .claude
        let startedAt = foreground?.instance.startedAt
        let recipient = runsClaude ? conversation(of: column, foreground: foreground) : nil
        let sentTo = delivery.event.kind == .instruction ? delivery.event.childSessionID : nil
        var place = places[id]
        while true {
            // Only on proof: none in front, one on another conversation, or one started since the claim.
            let ended = place.map { place in
                guard case .claimed(let conversation, let claimedAt) = place, !snapshot.isEmpty else { return false }
                return !runsClaude || recipient.map { $0 != conversation } ?? false || startedAt.map { $0 > claimedAt } ?? false
            } ?? false
            switch MissionDeliveryPolicy.hookStep(place: place, recipient: recipient, ended: ended, sentTo: sentTo, isArmed: mailbox.isArmed) {
            case .leave:
                missionWaits.handedToHooks[id] = missionWaits.handedToHooks[id] ?? now
                return true
            case .release:
                if let claim = mailbox.claims().first(where: { $0.letter.id == id }) { try? mailbox.forget(claim) }
                place = nil
            case .retract(let conversation):
                // False: a waiter claimed it meanwhile. A disk error tries again next pass.
                guard (try? mailbox.retract(id, from: conversation)) == true else {
                    missionWaits.handedToHooks[id] = missionWaits.handedToHooks[id] ?? now
                    return true
                }
                place = nil
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

    /// Records each message a hook took once a turn of its session ended
    /// after it (a main-thread Stop of the `claude` that ran then), and
    /// frees one whose session ended first to go again, through the next
    /// waiter or typing.
    func settleHookClaims(after events: [AgentHookEvent]) {
        let ends = events.filter {
            $0.kind == .claude && $0.agentID == nil && $0.sessionID != nil && ($0.name == .stop || $0.name == .sessionEnd)
        }
        guard !ends.isEmpty else { return }
        let mailbox = MissionWaitHook.mailbox
        for claim in mailbox.claims() {
            guard let end = ends.first(where: { end in
                end.sessionID == claim.conversation && end.emitterProcess.map { $0.startedAt <= claim.claimedAt } ?? true
                    && end.timestamp >= claim.claimedAt + (end.name == .stop ? MissionWaitHook.turnAfterClaim : 0)
            }) else { continue }
            if end.name == .stop { recordHookDelivery(of: claim) }
            try? mailbox.forget(claim)
            missionWaits.handedToHooks[claim.letter.id] = nil
        }
    }

    /// At launch: what hooks took while Nirux was away counts as delivered;
    /// what still waited goes again, through this run's waiters or typing.
    func settleMissionMailbox() {
        guard MissionStore.shared.ensureLoaded() else { return }
        let mailbox = MissionWaitHook.mailbox
        for claim in mailbox.claims() {
            recordHookDelivery(of: claim)
            try? mailbox.forget(claim)
        }
        for case let (id, .waiting(conversation)) in mailbox.places() { _ = try? mailbox.retract(id, from: conversation) }
        mailbox.prune()
    }

    /// Takes back the waiting letters of messages Nirux no longer delivers
    /// (`pending`: the ones it does): expired, given up, or their Mission
    /// closed. A claim waits for its turn's end, which records it.
    func withdrawStaleLetters(pending: Set<String>) {
        let stale = Set(missionWaits.handedToHooks.keys).subtracting(pending)
        guard !stale.isEmpty else { return }
        let mailbox = MissionWaitHook.mailbox
        let places = mailbox.places()
        for id in stale {
            switch places[id] {
            case .waiting(let conversation)?:
                // False: a waiter claimed it meanwhile. A disk error tries again.
                guard (try? mailbox.retract(id, from: conversation)) == true else { continue }
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
