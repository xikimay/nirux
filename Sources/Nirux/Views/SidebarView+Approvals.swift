import AppKit

// MARK: - Allow / Deny clicks (sidebar permission approvals)

/// When an Allow / Deny button starts accepting clicks: once it has sat
/// at the same place for `SidebarView.approvalArmingDelay`.
struct SidebarApprovalButtonArming: Equatable {
    let frame: NSRect
    /// `ProcessInfo.systemUptime` seconds.
    let armedAt: TimeInterval
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

/// Yes, No or Reply… clicked under a turn's question.
struct SidebarTurnAnswerClick: Equatable {
    let question: SidebarTurnQuestion
    let answer: SidebarTurnAnswer
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
        var arming: [String: SidebarApprovalButtonArming] = [:]
        for (key, button) in approvalButtonViews {
            if let previous = approvalButtonArming[key], previous.frame == button.frame {
                arming[key] = previous
            } else {
                arming[key] = SidebarApprovalButtonArming(frame: button.frame, armedAt: now + Self.approvalArmingDelay)
            }
        }
        approvalButtonArming = arming
    }

    func isApprovalButtonArmed(_ key: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        approvalButtonArming[key].map { now >= $0.armedAt } ?? false
    }

    /// The `approvalButtonViews` key of a button region: Allow, Deny,
    /// Resume. Nil for anything else.
    static func armedButtonKey(for region: SidebarHitRegion) -> String? {
        switch region {
        case let .permissionDecision(_, _, requestID, behavior):
            return SidebarHoverTarget.approvalButtonKey(requestID: requestID, behavior: behavior)
        case let .agentResume(workspaceIndex, columnIndex, failedAt):
            return SidebarHoverTarget.resumeButtonKey(workspaceIndex: workspaceIndex, columnIndex: columnIndex, failedAt: failedAt)
        case let .deferredAgentResume(_, _, columnID):
            return SidebarHoverTarget.deferredResumeButtonKey(columnID: columnID)
        case let .turnAnswer(_, _, question, answer):
            return SidebarHoverTarget.turnAnswerButtonKey(question: question, answer: answer)
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
        let now = ProcessInfo.processInfo.systemUptime
        approvalButtonArming = approvalButtonArming.mapValues {
            SidebarApprovalButtonArming(frame: $0.frame, armedAt: now + Self.approvalArmingDelay)
        }
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

    /// The second press of a double-click whose first click made a button
    /// act: the rebuild may have put anything there (a deferred agent's
    /// Resume row goes away, the card below moves up). It does nothing.
    static func isLeftoverPress(clickCount: Int, at time: TimeInterval, after action: TimeInterval) -> Bool {
        clickCount > 1 && time - action < NSEvent.doubleClickInterval
    }

    /// A press on Allow / Deny / Resume acts only on its release (see
    /// `approvalClickDecision`, `resumeClick`, `deferredResumeClick`), never
    /// on the press. The loop also keeps the press from moving the window.
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
            }
            return
        }
    }
}
