import AppKit

// MARK: - Allow / Deny clicks (sidebar permission approvals)

/// When an Allow / Deny button starts accepting clicks: once it has sat
/// at the same place for `SidebarView.approvalArmingDelay`.
struct SidebarApprovalButtonArming: Equatable {
    let frame: NSRect
    /// `ProcessInfo.systemUptime` seconds.
    let armedAt: TimeInterval

    /// After a rebuild: buttons at a new place (or new) start their delay
    /// again; buttons that stayed put keep theirs. The rows and the glass
    /// interface's requests (`RequestArming`) arm alike.
    @MainActor
    static func rearmed(_ previous: [String: Self], frames: [String: NSRect], now: TimeInterval) -> [String: Self] {
        frames.reduce(into: [:]) { arming, entry in
            if let kept = previous[entry.key], kept.frame == entry.value {
                arming[entry.key] = kept
            } else {
                arming[entry.key] = Self(frame: entry.value, armedAt: now + SidebarView.approvalArmingDelay)
            }
        }
    }

    /// Scrolling slides buttons under a still pointer: every button waits
    /// its delay again.
    @MainActor
    static func restarted(_ arming: [String: Self], now: TimeInterval) -> [String: Self] {
        arming.mapValues { Self(frame: $0.frame, armedAt: now + SidebarView.approvalArmingDelay) }
    }
}

/// A decision clicked in the sidebar, where its button was released.
struct SidebarApprovalClick: Equatable {
    let workspaceIndex: Int
    let columnIndex: Int
    let requestID: String
    let behavior: PermissionApproval.Behavior
}

/// Resume clicked in the sidebar, where its button was released.
struct SidebarResumeClick: Equatable {
    let workspaceIndex: Int
    let columnIndex: Int
    let failedAt: TimeInterval
}

/// Interrupt clicked in the sidebar, where its button was released.
struct SidebarInterruptClick: Equatable {
    let workspaceIndex: Int
    let columnIndex: Int
    let since: TimeInterval
}

/// Type it now clicked on a row of waiting Mission messages.
struct SidebarTypeNowClick: Equatable {
    let workspaceIndex: Int
    let columnIndex: Int
    let since: TimeInterval
}

/// Yes, No or Reply… clicked under a turn's question.
struct SidebarTurnAnswerClick: Equatable {
    let question: SidebarTurnQuestion
    let answer: SidebarTurnAnswer
}

/// Reply… or Accept clicked under a Mission question's recommendation,
/// where the button was released.
struct SidebarMissionAnswerClick: Equatable {
    let workspaceIndex: Int
    let columnIndex: Int
    let questionID: String
    let accepts: Bool
}

/// Resume clicked on the row of a restored agent that hasn't resumed yet.
struct SidebarDeferredResumeClick: Equatable {
    let workspaceIndex: Int
    let columnIndex: Int
    let columnID: UUID
}

extension SidebarView {
    /// A block appears, moves or changes to the next request on its own
    /// (the agent asks, a decision lands, a card above grows): a button
    /// that just got under the pointer must not take a click aimed at
    /// what was there.
    static let approvalArmingDelay: TimeInterval = 0.6

    /// After a rebuild: buttons at a new place (or new) start their delay
    /// again; buttons that stayed put keep theirs.
    func refreshApprovalArming(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        approvalButtonArming = SidebarApprovalButtonArming.rearmed(approvalButtonArming, frames: approvalButtonViews.mapValues(\.frame), now: now)
    }

    func isApprovalButtonArmed(_ key: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        approvalButtonArming[key].map { now >= $0.armedAt } ?? false
    }

    /// The `approvalButtonViews` key of a button region: Allow, Deny,
    /// Resume, Interrupt. Nil for anything else.
    static func armedButtonKey(for region: SidebarHitRegion) -> String? {
        switch region {
        case let .permissionDecision(_, _, requestID, behavior):
            return SidebarHoverTarget.approvalButtonKey(requestID: requestID, behavior: behavior)
        case let .agentResume(workspaceIndex, columnIndex, failedAt):
            return SidebarHoverTarget.resumeButtonKey(workspaceIndex: workspaceIndex, columnIndex: columnIndex, failedAt: failedAt)
        case let .agentInterrupt(workspaceIndex, columnIndex, since):
            return SidebarHoverTarget.interruptButtonKey(workspaceIndex: workspaceIndex, columnIndex: columnIndex, since: since)
        case let .missionTypeNow(workspaceIndex, columnIndex, since):
            return SidebarHoverTarget.typeNowButtonKey(workspaceIndex: workspaceIndex, columnIndex: columnIndex, since: since)
        case let .deferredAgentResume(_, _, columnID):
            return SidebarHoverTarget.deferredResumeButtonKey(columnID: columnID)
        case let .turnAnswer(_, _, question, answer):
            return SidebarHoverTarget.turnAnswerButtonKey(question: question, answer: answer)
        case let .missionAnswer(_, _, questionID, accepts):
            return SidebarHoverTarget.missionAnswerButtonKey(questionID: questionID, accepts: accepts)
        default:
            return nil
        }
    }

    func observeScrollingForApprovalArming() {
        contentScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(approvalClipViewScrolled(_:)),
            name: NSView.boundsDidChangeNotification,
            object: contentScrollView.contentView
        )
    }

    /// Scrolling slides buttons under a still pointer: every button waits
    /// its delay again.
    @objc func approvalClipViewScrolled(_ notification: Notification) {
        approvalButtonArming = SidebarApprovalButtonArming.restarted(approvalButtonArming, now: ProcessInfo.processInfo.systemUptime)
    }

    /// The decision a click makes, if any: a single click, released on the
    /// button it pressed (the same request and decision, wherever a rebuild
    /// meanwhile put it), armed at both ends.
    static func approvalClickDecision(
        pressed: SidebarHitRegion,
        released: SidebarHitRegion?,
        clickCount: Int,
        armedAtPress: Bool,
        armedAtRelease: Bool
    ) -> SidebarApprovalClick? {
        guard clickCount == 1, armedAtPress, armedAtRelease,
              case let .permissionDecision(_, _, pressedID, pressedBehavior) = pressed,
              case let .permissionDecision(workspaceIndex, columnIndex, releasedID, releasedBehavior)? = released,
              releasedID == pressedID, releasedBehavior == pressedBehavior else { return nil }
        return SidebarApprovalClick(
            workspaceIndex: workspaceIndex, columnIndex: columnIndex, requestID: releasedID, behavior: releasedBehavior
        )
    }

    /// The Resume a click makes, if any: the same rules as a decision, for
    /// the same failure.
    static func resumeClick(
        pressed: SidebarHitRegion,
        released: SidebarHitRegion?,
        clickCount: Int,
        armedAtPress: Bool,
        armedAtRelease: Bool
    ) -> SidebarResumeClick? {
        guard clickCount == 1, armedAtPress, armedAtRelease,
              case let .agentResume(_, _, pressedFailure) = pressed,
              case let .agentResume(workspaceIndex, columnIndex, releasedFailure)? = released,
              releasedFailure == pressedFailure else { return nil }
        return SidebarResumeClick(workspaceIndex: workspaceIndex, columnIndex: columnIndex, failedAt: releasedFailure)
    }

    /// The Interrupt a click makes, if any: the same rules, for the same
    /// silence.
    static func interruptClick(
        pressed: SidebarHitRegion,
        released: SidebarHitRegion?,
        clickCount: Int,
        armedAtPress: Bool,
        armedAtRelease: Bool
    ) -> SidebarInterruptClick? {
        guard clickCount == 1, armedAtPress, armedAtRelease,
              case let .agentInterrupt(_, _, pressedSilence) = pressed,
              case let .agentInterrupt(workspaceIndex, columnIndex, releasedSilence)? = released,
              releasedSilence == pressedSilence else { return nil }
        return SidebarInterruptClick(workspaceIndex: workspaceIndex, columnIndex: columnIndex, since: releasedSilence)
    }

    /// The Type it now a click makes, if any: the same rules, for the same
    /// waiting messages.
    static func typeNowClick(
        pressed: SidebarHitRegion,
        released: SidebarHitRegion?,
        clickCount: Int,
        armedAtPress: Bool,
        armedAtRelease: Bool
    ) -> SidebarTypeNowClick? {
        guard clickCount == 1, armedAtPress, armedAtRelease,
              case let .missionTypeNow(_, _, pressedSince) = pressed,
              case let .missionTypeNow(workspaceIndex, columnIndex, releasedSince)? = released,
              releasedSince == pressedSince else { return nil }
        return SidebarTypeNowClick(workspaceIndex: workspaceIndex, columnIndex: columnIndex, since: releasedSince)
    }

    /// The Resume of a not-resumed agent a click makes, if any: the same
    /// rules, for the same column.
    static func deferredResumeClick(
        pressed: SidebarHitRegion,
        released: SidebarHitRegion?,
        clickCount: Int,
        armedAtPress: Bool,
        armedAtRelease: Bool
    ) -> SidebarDeferredResumeClick? {
        guard clickCount == 1, armedAtPress, armedAtRelease,
              case let .deferredAgentResume(_, _, pressedColumn) = pressed,
              case let .deferredAgentResume(workspaceIndex, columnIndex, releasedColumn)? = released,
              releasedColumn == pressedColumn else { return nil }
        return SidebarDeferredResumeClick(workspaceIndex: workspaceIndex, columnIndex: columnIndex, columnID: releasedColumn)
    }

    /// A one-point spot under the pointer in the scrolled rows, for a
    /// popover whose button a rebuild replaced between press and release.
    func anchorAtPointer() -> (view: NSView, rect: NSRect)? {
        guard let window else { return nil }
        let point = contentDocumentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return (contentDocumentView, NSRect(origin: point, size: NSSize(width: 1, height: 1)))
    }

    /// The quick answer a click makes, if any: the same rules, for the same
    /// question and answer ("yes" can start a merge or a push).
    static func turnAnswerClick(
        pressed: SidebarHitRegion,
        released: SidebarHitRegion?,
        clickCount: Int,
        armedAtPress: Bool,
        armedAtRelease: Bool
    ) -> SidebarTurnAnswerClick? {
        guard clickCount == 1, armedAtPress, armedAtRelease,
              case let .turnAnswer(_, _, pressedQuestion, pressedAnswer) = pressed,
              case let .turnAnswer(_, _, releasedQuestion, releasedAnswer)? = released,
              releasedQuestion.columnID == pressedQuestion.columnID, releasedQuestion.turnEndedAt == pressedQuestion.turnEndedAt,
              releasedAnswer == pressedAnswer else { return nil }
        return SidebarTurnAnswerClick(question: releasedQuestion, answer: releasedAnswer)
    }

    /// Reply… or Accept, if a click makes one: the same rules, for the same
    /// question and button (Accept answers for the user).
    static func missionAnswerClick(
        pressed: SidebarHitRegion,
        released: SidebarHitRegion?,
        clickCount: Int,
        armedAtPress: Bool,
        armedAtRelease: Bool
    ) -> SidebarMissionAnswerClick? {
        guard clickCount == 1, armedAtPress, armedAtRelease,
              case let .missionAnswer(_, _, pressedQuestion, pressedAccepts) = pressed,
              case let .missionAnswer(workspaceIndex, columnIndex, releasedQuestion, releasedAccepts)? = released,
              releasedQuestion == pressedQuestion, releasedAccepts == pressedAccepts else { return nil }
        return SidebarMissionAnswerClick(
            workspaceIndex: workspaceIndex, columnIndex: columnIndex, questionID: releasedQuestion, accepts: releasedAccepts
        )
    }

    /// The second press of a double-click whose first click made a button
    /// act: the rebuild may have put anything there (a deferred agent's
    /// Resume row goes away, the card below moves up). It does nothing.
    static func isLeftoverPress(clickCount: Int, at time: TimeInterval, after action: TimeInterval) -> Bool {
        clickCount > 1 && time - action < NSEvent.doubleClickInterval
    }

    /// A press on Allow / Deny / Resume / Interrupt / Type it now acts only on
    /// its release (see `approvalClickDecision`, `resumeClick`,
    /// `interruptClick`, `typeNowClick`, `deferredResumeClick`), never on the
    /// press. The loop also keeps the press from moving the window.
    func trackApprovalClick(_ region: SidebarHitRegion, event: NSEvent) {
        guard let key = Self.armedButtonKey(for: region) else { return }
        let armedAtPress = isApprovalButtonArmed(key)
        guard event.clickCount == 1, armedAtPress, let window else { return }
        while true {
            guard let next = window.nextEvent(
                matching: [.leftMouseUp, .leftMouseDragged],
                until: Date(timeIntervalSinceNow: 0.25),
                inMode: .eventTracking,
                dequeue: true
            ) else {
                if !window.isVisible || NSEvent.pressedMouseButtons & 1 == 0 { return }
                continue
            }
            guard next.type == .leftMouseUp else { continue }
            let point = contentDocumentView.convert(next.locationInWindow, from: nil)
            let released = hitArea(at: point)?.region
            let armedAtRelease = isApprovalButtonArmed(key)
            if let decision = Self.approvalClickDecision(
                pressed: region, released: released, clickCount: event.clickCount,
                armedAtPress: armedAtPress, armedAtRelease: armedAtRelease
            ) {
                lastButtonActionAt = next.timestamp
                onPermissionDecision?(decision.workspaceIndex, decision.columnIndex, decision.requestID, decision.behavior)
            } else if let resume = Self.resumeClick(
                pressed: region, released: released, clickCount: event.clickCount,
                armedAtPress: armedAtPress, armedAtRelease: armedAtRelease
            ) {
                lastButtonActionAt = next.timestamp
                onAgentResume?(resume.workspaceIndex, resume.columnIndex, resume.failedAt)
            } else if let interrupt = Self.interruptClick(
                pressed: region, released: released, clickCount: event.clickCount,
                armedAtPress: armedAtPress, armedAtRelease: armedAtRelease
            ) {
                lastButtonActionAt = next.timestamp
                onAgentInterrupt?(interrupt.workspaceIndex, interrupt.columnIndex, interrupt.since)
            } else if let typeNow = Self.typeNowClick(
                pressed: region, released: released, clickCount: event.clickCount,
                armedAtPress: armedAtPress, armedAtRelease: armedAtRelease
            ) {
                lastButtonActionAt = next.timestamp
                onMissionTypeNow?(typeNow.workspaceIndex, typeNow.columnIndex, typeNow.since)
            } else if let resume = Self.deferredResumeClick(
                pressed: region, released: released, clickCount: event.clickCount,
                armedAtPress: armedAtPress, armedAtRelease: armedAtRelease
            ) {
                lastButtonActionAt = next.timestamp
                onDeferredAgentResume?(resume.workspaceIndex, resume.columnIndex, resume.columnID)
            } else if let answer = Self.turnAnswerClick(
                pressed: region, released: released, clickCount: event.clickCount,
                armedAtPress: armedAtPress, armedAtRelease: armedAtRelease
            ) {
                lastButtonActionAt = next.timestamp
                onTurnAnswer?(answer.question, answer.answer, approvalButtonViews[key])
            } else if let answer = Self.missionAnswerClick(
                pressed: region, released: released, clickCount: event.clickCount,
                armedAtPress: armedAtPress, armedAtRelease: armedAtRelease
            ) {
                lastButtonActionAt = next.timestamp
                onMissionAnswer?(answer, approvalButtonViews[key])
            }
            return
        }
    }
}
