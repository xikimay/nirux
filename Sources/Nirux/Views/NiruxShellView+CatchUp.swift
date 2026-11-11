import AppKit

/// The catch-up's state on the shell (see `SidebarCatchUp`).
struct CatchUpState {
    var tracker: AwayTracker
    /// The tasks whose last turn ended while the user was away, latest
    /// first; each goes once opened or answered.
    var workspaceIDs: [String] = []
    /// When the absence that listed each began (epoch seconds).
    var awaySince: [String: TimeInterval] = [:]
    var isExpanded = false
    /// The user's macOS session is switched out (another account in
    /// front), as its notifications said.
    var isSessionSwitchedOut = false
    /// The tracker follows the system (`wireCatchUp`). A shell that
    /// doesn't (tests) only moves with what it is told.
    var followsSystem = false
}

extension NiruxShellView {
    /// The shortest absence that brings the card back with the user.
    static let catchUpAbsence: TimeInterval = 15 * 60

    /// Away and back: Nirux in front or not, the user's macOS session
    /// switched out or in (another account is used as often as a locked
    /// screen), the screen asleep or locked. Each notification reads the
    /// state again (`awayConditionsNow`); one that says the user left
    /// counts as well, in case the state read lags it. The app's shell
    /// only (`NiruxApp`): other processes' windows take the activation.
    func wireCatchUp() {
        catchUpState.followsSystem = true
        catchUpState.tracker = AwayTracker(missing: awayConditionsNow(), now: Date().timeIntervalSince1970)
        let app = NotificationCenter.default
        let system = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        // `switchedOut`: what a session notification says of the session.
        let changes: [(NotificationCenter, Notification.Name, leaving: AwayTracker.Condition?, switchedOut: Bool?)] = [
            (app, NSApplication.didBecomeActiveNotification, nil, nil),
            (app, NSApplication.didResignActiveNotification, .appActive, nil),
            (system, NSWorkspace.sessionDidBecomeActiveNotification, nil, false),
            (system, NSWorkspace.sessionDidResignActiveNotification, .sessionActive, true),
            (system, NSWorkspace.screensDidWakeNotification, nil, nil),
            (system, NSWorkspace.screensDidSleepNotification, .screenAwake, nil),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), nil, nil),
            (distributed, Notification.Name("com.apple.screenIsLocked"), .screenUnlocked, nil)
        ]
        for (center, name, leaving, switchedOut) in changes {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let switchedOut { self.catchUpState.isSessionSwitchedOut = switchedOut }
                    self.noteAway(missing: self.awayConditionsNow().union(leaving.map { [$0] } ?? []))
                }
            }
            catchUpObservers.add(token, on: center)
        }
    }

    /// What keeps the user away now: Nirux not in front, the session
    /// switched out (as its notifications said: a remote login is never
    /// on the console), the screen locked or the main display asleep, read
    /// from the system rather than from the notifications' order (a locked
    /// screen's reach an inactive app late, merged).
    func awayConditionsNow() -> Set<AwayTracker.Condition> {
        var missing: Set<AwayTracker.Condition> = []
        if !NSApp.isActive { missing.insert(.appActive) }
        if catchUpState.isSessionSwitchedOut { missing.insert(.sessionActive) }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session["CGSSessionScreenIsLocked"] as? Bool == true {
            missing.insert(.screenUnlocked)
        }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { missing.insert(.screenAwake) }
        return missing
    }

    /// Back after `catchUpAbsence` or more, the tasks whose last turn
    /// ended meanwhile go on the card, ahead of what it still holds. Shown
    /// after the activation's own work (see `clearAllAgentAttention`),
    /// from the rows on screen; the next refresh brings the rest.
    func noteAway(missing: Set<AwayTracker.Condition>, now: TimeInterval = Date().timeIntervalSince1970) {
        guard case .cameBack(let since)? = catchUpState.tracker.update(missing: missing, at: now),
              catchUpEnabled, now - since >= Self.catchUpAbsence
        else { return }
        let ended = tasksWhoseTurnEnded(after: since, until: now)
        guard !ended.isEmpty else { return }
        if catchUpState.workspaceIDs.isEmpty { catchUpState.isExpanded = false }
        for id in ended where catchUpState.awaySince[id] == nil { catchUpState.awaySince[id] = since }
        catchUpState.workspaceIDs = ended + catchUpState.workspaceIDs.filter { !ended.contains($0) }
        DispatchQueue.main.async { [weak self] in self?.showCatchUpCard() }
    }

    /// The card now, brought into view and said to VoiceOver.
    func showCatchUpCard() {
        sidebar.catchUp = sidebarCatchUp(infos: sidebar.displayedWorkspaceInfos)
        sidebar.refreshCatchUpCard(reveal: true)
        guard let card = sidebar.catchUp, sidebar.isExpanded else { return }
        NSAccessibility.post(
            element: sidebar, notification: .announcementRequested,
            userInfo: [.announcement: card.accessibilityLabel, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
    }

    /// The tasks whose last turn ended in (`since`, `now`], latest first:
    /// not the Lead (its row has no line), nor one archived or closing,
    /// nor the one on screen, which the user sees as they come back.
    func tasksWhoseTurnEnded(after since: TimeInterval, until now: TimeInterval) -> [String] {
        let onScreen = workspaces[safe: activeWSIndex]
        return workspaces.compactMap { workspace -> (id: String, endedAt: TimeInterval)? in
            guard !workspace.isInactive, !workspace.isClosing, workspace !== onScreen else { return nil }
            let endedAt = workspace.columns.compactMap { $0.pty?.agentLastTurnEndedAt }.filter { $0 > since && $0 <= now }.max()
            return endedAt.map { (workspace.id, $0) }
        }
        .sorted { $0.endedAt > $1.endedAt }
        .map(\.id)
    }

    /// The card, from the rows the sidebar shows: the listed tasks of this
    /// space, then a line for each other space that has some. A task the
    /// user opened since (on screen while they are in front), or closed,
    /// is no longer listed.
    func sidebarCatchUp(infos: [WorkspaceInfo]) -> SidebarCatchUp? {
        // A notification that never came back would keep the user away.
        if catchUpState.followsSystem, catchUpState.tracker.awaySince != nil, NSApp.isActive {
            noteAway(missing: awayConditionsNow())
        }
        guard catchUpEnabled, !catchUpState.workspaceIDs.isEmpty else { return nil }
        if catchUpState.tracker.awaySince == nil, let onScreen = workspaces[safe: activeWSIndex]?.id {
            catchUpState.workspaceIDs.removeAll { $0 == onScreen }
        }
        // Closed or archived since.
        catchUpState.workspaceIDs.removeAll { id in !workspaces.contains { $0.id == id && !$0.isClosing && !$0.isInactive } }
        catchUpState.awaySince = catchUpState.awaySince.filter { catchUpState.workspaceIDs.contains($0.key) }
        guard !catchUpState.workspaceIDs.isEmpty else { return nil }
        let order = Dictionary(catchUpState.workspaceIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = infos.filter { order[$0.id] != nil }.map(SidebarCatchUp.row(for:)).sorted {
            ($0.kind, order[$0.workspaceID] ?? 0) < ($1.kind, order[$1.workspaceID] ?? 0)
        }
        let shown = Set(rows.map(\.workspaceID))
        var elsewhere: [String: Int] = [:]
        for id in catchUpState.workspaceIDs where !shown.contains(id) {
            if let profileID = workspaces.first(where: { $0.id == id })?.profileID { elsewhere[profileID, default: 0] += 1 }
        }
        let otherSpaces = workspaceStore.profiles.compactMap { profile in
            elsewhere[profile.id].map { SidebarCatchUp.OtherSpace(profileID: profile.id, name: profile.name, count: $0) }
        }
        return SidebarCatchUp(
            since: SidebarCatchUp.sinceText(catchUpState.awaySince.values.min() ?? 0), rows: rows,
            otherSpaces: otherSpaces, isExpanded: catchUpState.isExpanded
        )
    }

    func handleCatchUpAction(_ action: SidebarCatchUpAction) {
        switch action {
        case .dismiss:
            catchUpState.awaySince = [:]
        case .expand:
            catchUpState.isExpanded = true
        case .open(let workspaceID):
            // As its row would: the column that asks or broke. It goes
            // from the card once on screen.
            let column = sidebar.displayedWorkspaceInfos.first { $0.id == workspaceID }?.rowSummary.focusColumn
            focusWorkspace(id: workspaceID, column: column)
        case .space(let profileID):
            selectProfile(profileID)
        }
        updateSidebar()
    }

    /// The user answered a listed task from its row (Yes, No, Reply…
    /// sent, Allow, Deny, Resume): it was seen.
    func noteCatchUpTaskAnswered(workspaceIndex: Int) {
        guard let id = workspaces[safe: workspaceIndex]?.id else { return }
        catchUpState.workspaceIDs.removeAll { $0 == id }
    }

    /// The option on or off at once; off, the card goes.
    func setCatchUp(enabled: Bool) {
        catchUpEnabled = enabled
        if !enabled {
            catchUpState.workspaceIDs = []
            catchUpState.awaySince = [:]
        }
        updateSidebar()
    }
}
