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

    /// A press on Allow / Deny decides only on its release (see
    /// `approvalClickDecision`), never on the press. The loop also keeps
    /// the press from moving the window.
    func trackApprovalClick(_ region: SidebarHitRegion, event: NSEvent) {
        guard case let .permissionDecision(_, _, requestID, behavior) = region else { return }
        let key = SidebarHoverTarget.approvalButtonKey(requestID: requestID, behavior: behavior)
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
            if let decision = Self.approvalClickDecision(
                pressed: region,
                released: hitArea(at: point)?.region,
                clickCount: event.clickCount,
                armedAtPress: armedAtPress,
                armedAtRelease: isApprovalButtonArmed(key)
            ) {
                onPermissionDecision?(decision.workspaceIndex, decision.columnIndex, decision.requestID, decision.behavior)
            }
            return
        }
    }
}
