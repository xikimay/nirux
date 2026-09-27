import AppKit

// MARK: - Allow / Deny clicks (sidebar permission approvals)

/// When an Allow / Deny button starts accepting clicks: once it has sat
/// at the same place for `SidebarView.approvalArmingDelay`.
struct SidebarApprovalButtonArming: Equatable {
    let frame: NSRect
    /// `ProcessInfo.systemUptime` seconds.
    let armedAt: TimeInterval
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

    /// A press on Allow / Deny decides only as a single click released on
    /// the same button, armed at both ends: never on the press, never the
    /// second click of a double click. The loop also keeps the press from
    /// moving the window.
    func trackApprovalClick(_ region: SidebarHitRegion, event: NSEvent) {
        guard case let .permissionDecision(workspaceIndex, columnIndex, requestID, behavior) = region,
              event.clickCount == 1 else { return }
        let key = SidebarHoverTarget.approvalButtonKey(requestID: requestID, behavior: behavior)
        guard isApprovalButtonArmed(key), let window else { return }
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
            guard let area = hitArea(at: point),
                  case let .permissionDecision(_, _, releasedID, releasedBehavior) = area.region,
                  releasedID == requestID, releasedBehavior == behavior,
                  isApprovalButtonArmed(key) else { return }
            onPermissionDecision?(workspaceIndex, columnIndex, requestID, behavior)
            return
        }
    }
}
