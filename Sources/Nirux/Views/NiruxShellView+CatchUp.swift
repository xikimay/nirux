import AppKit

/// The catch-up's state on the shell (see `SidebarCatchUp`).
struct CatchUpState {
    var tracker: AwayTracker
    /// How long the absence that listed the tasks lasted ("42m").
    var away = ""
    /// The tasks whose last turn ended while the user was away, latest
    /// first; each goes once opened.
    var workspaceIDs: [String] = []
    var isExpanded = false
}

extension NiruxShellView {
    /// The shortest absence that brings the card back with the user.
    static let catchUpAbsence: TimeInterval = 15 * 60

    /// Away and back: Nirux in front or not, the user's macOS session
    /// switched out or in (another account is used as often as a locked
    /// screen), the screen asleep or locked.
    func wireCatchUp() {
        catchUpState.tracker = AwayTracker(
            missing: NSApp.isActive ? [] : [.appActive], now: Date().timeIntervalSince1970
        )
        let app = NotificationCenter.default
        let system = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let changes: [(NotificationCenter, Notification.Name, AwayTracker.Condition, Bool)] = [
            (app, NSApplication.didBecomeActiveNotification, .appActive, true),
            (app, NSApplication.didResignActiveNotification, .appActive, false),
            (system, NSWorkspace.sessionDidBecomeActiveNotification, .sessionActive, true),
            (system, NSWorkspace.sessionDidResignActiveNotification, .sessionActive, false),
            (system, NSWorkspace.screensDidWakeNotification, .screenAwake, true),
            (system, NSWorkspace.screensDidSleepNotification, .screenAwake, false),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), .screenUnlocked, true),
            (distributed, Notification.Name("com.apple.screenIsLocked"), .screenUnlocked, false)
        ]
        for (center, name, condition, holds) in changes {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteAway(condition, holds: holds) }
            }
        }
    }

    /// One of the conditions changed. Back after `catchUpAbsence` or more,
    /// the card lists the tasks whose last turn ended meanwhile, in place
    /// of what an earlier absence listed. Shown from the rows on screen:
    /// activation must stay cheap (see `clearAllAgentAttention`), the next
    /// refresh brings the rest.
    func noteAway(_ condition: AwayTracker.Condition, holds: Bool, now: TimeInterval = Date().timeIntervalSince1970) {
        guard case .cameBack(let since)? = catchUpState.tracker.set(condition, holds: holds, at: now),
              now - since >= Self.catchUpAbsence
        else { return }
        catchUpState.workspaceIDs = catchUpEnabled ? tasksWhoseTurnEnded(after: since, until: now) : []
        catchUpState.away = SidebarView.cardAge(since: since, now: Date(timeIntervalSince1970: now))
        catchUpState.isExpanded = false
        sidebar.catchUp = sidebarCatchUp(infos: sidebar.displayedWorkspaceInfos)
        sidebar.refreshCatchUpCard()
    }

    /// The tasks whose last turn ended in (`since`, `now`], latest first:
    /// not the Lead (its row has no line), nor one closing, nor the one on
    /// screen, which the user sees as they come back.
    func tasksWhoseTurnEnded(after since: TimeInterval, until now: TimeInterval) -> [String] {
        let onScreen = workspaces[safe: activeWSIndex]
        return workspaces.compactMap { workspace -> (id: String, endedAt: TimeInterval)? in
            guard !workspace.isLead, !workspace.isClosing, workspace !== onScreen else { return nil }
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
        guard catchUpEnabled, !catchUpState.workspaceIDs.isEmpty else { return nil }
        if catchUpState.tracker.awaySince == nil, let onScreen = workspaces[safe: activeWSIndex]?.id {
            catchUpState.workspaceIDs.removeAll { $0 == onScreen }
        }
        catchUpState.workspaceIDs.removeAll { id in !workspaces.contains { $0.id == id && !$0.isClosing } }
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
            away: catchUpState.away, rows: rows, otherSpaces: otherSpaces, isExpanded: catchUpState.isExpanded
        )
    }

    func handleCatchUpAction(_ action: SidebarCatchUpAction) {
        switch action {
        case .dismiss:
            catchUpState.workspaceIDs = []
        case .expand:
            catchUpState.isExpanded = true
        case .open(let workspaceID):
            // Goes from the card once on screen.
            focusWorkspace(id: workspaceID)
        case .space(let profileID):
            selectProfile(profileID)
        }
        updateSidebar()
    }

    /// The option on or off at once; off, the card goes.
    func setCatchUp(enabled: Bool) {
        catchUpEnabled = enabled
        if !enabled { catchUpState.workspaceIDs = [] }
        updateSidebar()
    }
}
