import AppKit
import os

/// What the shell keeps for the stale-rows log.
@MainActor
final class SidebarStaleLogState {
    /// When each last happened since launch, on the sidebar's clock.
    var lastWakeAt: CFTimeInterval?
    var lastUnlockAt: CFTimeInterval?
    var lastSessionReturnAt: CFTimeInterval?
    var lastFrontAt: CFTimeInterval?
    var lastUncoveredAt: CFTimeInterval?
    /// The window showed at the last change of a window's occlusion.
    var windowShowed = false
    let observers = ObserverBag()
}

/// One line in the system log when the pointer comes back to the sidebar
/// or Nirux comes to the front: the moments at which rows of tasks that
/// were gone were seen to stay, until a click or a pass over the list. It
/// tells the three places that can be behind apart. `same=0`: the list
/// held isn't the store's (and `drag`, `deferred`, `refresh`, `heartbeat`
/// say what held it). `rows`, `stray`, `nolayer` or `ghosts` off: the rows
/// drawn aren't the list's. All in order: the screen was behind, and the
/// seconds since the wake, the unlock, the session's return, the front and
/// the window uncovered say after what.
///
/// Counts and booleans only: no title, no path, no text. Read with
/// `log show --predicate 'subsystem == "com.xikimay.nirux" AND category == "sidebar"'`.
enum SidebarStaleLog {
    static let logger = Logger(subsystem: "com.xikimay.nirux", category: "sidebar")

    /// What a line was written for.
    enum Trigger: String {
        case move, press, front
    }

    struct Facts: Equatable {
        var trigger: Trigger
        /// How long the pointer had left the sidebar alone; nil: never
        /// there before, or not a pointer's line.
        var pointerIdle: CFTimeInterval?
        /// The tasks the store lists in the space on screen, and whether
        /// the sidebar holds those, in that order.
        var stored = 0
        var holdsStored = false
        var drawn = SidebarView.DrawnFacts()
        /// Seconds since a refresh last read the agents, and whether the
        /// heartbeat that asks for one runs.
        var sinceRefresh: TimeInterval = 0
        var heartbeatRuns = false
        var isAppActive = false
        var isWindowKey = false
        var windowShows = false
        var isDisplayAsleep = false
        var isSessionOut = false
        /// Seconds since each last happened; nil: not since launch.
        var sinceWake: CFTimeInterval?
        var sinceUnlock: CFTimeInterval?
        var sinceSessionReturn: CFTimeInterval?
        var sinceFront: CFTimeInterval?
        var sinceUncovered: CFTimeInterval?
    }

    static func line(_ facts: Facts) -> String {
        let drawn = facts.drawn
        let fields: [(String, String)] = [
            ("trigger", facts.trigger.rawValue), ("idle", seconds(facts.pointerIdle)),
            ("store", "\(facts.stored)"), ("held", "\(drawn.held)"), ("same", flag(facts.holdsStored)),
            ("rows", "\(drawn.rowsDrawn)/\(drawn.rowsExpected)"), ("stray", "\(drawn.strayLayers)"),
            ("nolayer", "\(drawn.viewsWithoutLayer)"), ("needsDisplay", flag(drawn.needsDisplay)),
            ("ghosts", "\(drawn.foldGhosts)"), ("ghostOpacity", String(format: "%.2f", drawn.foldGhostOpacity)),
            ("pulls", "\(drawn.foldPulls)"),
            ("drag", flag(drawn.isDragTracked)), ("deferred", flag(drawn.hasDeferredUpdate)), ("skipped", flag(drawn.skippedRebuild)),
            ("animates", flag(drawn.animates)), ("expanded", flag(drawn.isExpanded)), ("fits", flag(drawn.fits)),
            ("rebuild", seconds(drawn.sinceRebuild)), ("update", seconds(drawn.sinceUpdate)),
            ("refresh", seconds(facts.sinceRefresh)), ("heartbeat", flag(facts.heartbeatRuns)),
            ("active", flag(facts.isAppActive)), ("key", flag(facts.isWindowKey)), ("visible", flag(facts.windowShows)),
            ("displayAsleep", flag(facts.isDisplayAsleep)), ("sessionOut", flag(facts.isSessionOut)),
            ("wake", seconds(facts.sinceWake)), ("unlock", seconds(facts.sinceUnlock)),
            ("session", seconds(facts.sinceSessionReturn)), ("front", seconds(facts.sinceFront)),
            ("uncovered", seconds(facts.sinceUncovered))
        ]
        return fields.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }

    private static func flag(_ value: Bool) -> String { value ? "1" : "0" }

    /// To the tenth of a second; "-" for what never happened.
    private static func seconds(_ value: TimeInterval?) -> String {
        guard let value, value.isFinite else { return "-" }
        return String(format: "%.1f", max(0, value))
    }
}

extension NiruxShellView {
    /// The sidebar tells when the pointer comes back to it.
    func wireSidebarStaleLog() {
        sidebar.onPointerReturn = { [weak self] gesture, idle in
            self?.logSidebarState(gesture == .move ? .move : .press, pointerIdle: idle)
        }
    }

    /// What may leave the screen behind, as the system says it: kept for
    /// the next line, and a line when Nirux comes to the front. The app's
    /// shell only (`NiruxApp`): a test's shell would hear the activation
    /// other processes take from each other.
    func followSystemForSidebarStaleLog() {
        let system = NSWorkspace.shared.notificationCenter
        let events: [(NotificationCenter, Notification.Name, SidebarStaleLogEvent)] = [
            (system, NSWorkspace.screensDidWakeNotification, .wake),
            (system, NSWorkspace.sessionDidBecomeActiveNotification, .sessionReturn),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked"), .unlock),
            (.default, NSApplication.didBecomeActiveNotification, .front),
            (.default, NSWindow.didChangeOcclusionStateNotification, .occlusion)
        ]
        for (center, name, event) in events {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteSidebarStaleLogEvent(event) }
            }
            sidebarStaleLog.observers.add(token, on: center)
        }
    }

    enum SidebarStaleLogEvent {
        case wake, sessionReturn, unlock, front, occlusion
    }

    /// Keeps when it happened. Nirux coming to the front writes a line
    /// too, before the heartbeat it starts again refreshes anything: its
    /// `front` is the time since the front before this one.
    func noteSidebarStaleLogEvent(_ event: SidebarStaleLogEvent) {
        let now = sidebar.clock()
        switch event {
        case .wake: sidebarStaleLog.lastWakeAt = now
        case .sessionReturn: sidebarStaleLog.lastSessionReturnAt = now
        case .unlock: sidebarStaleLog.lastUnlockAt = now
        case .occlusion:
            // Any window's: this one's is read again, and counts when it
            // went from covered to shown.
            let shows = sideEffects.windowShows(window)
            if shows, !sidebarStaleLog.windowShowed { sidebarStaleLog.lastUncoveredAt = now }
            sidebarStaleLog.windowShowed = shows
        case .front:
            logSidebarState(.front, pointerIdle: nil)
            sidebarStaleLog.lastFrontAt = now
        }
    }

    func sidebarStaleFacts(_ trigger: SidebarStaleLog.Trigger, pointerIdle: CFTimeInterval?) -> SidebarStaleLog.Facts {
        let now = sidebar.clock()
        let state = sidebarStaleLog
        // What a refresh would list (see `updateSidebar`).
        let stored = visibleWorkspaceIndices.map { workspaces[$0].id }
        return SidebarStaleLog.Facts(
            trigger: trigger, pointerIdle: pointerIdle,
            stored: stored.count, holdsStored: stored == sidebar.lastInfos.map(\.id),
            drawn: sidebar.drawnFacts(),
            sinceRefresh: ProcessInfo.processInfo.systemUptime - lastMetadataRefreshAt,
            heartbeatRuns: heartbeatTimer != nil,
            isAppActive: NSApp.isActive, isWindowKey: window?.isKeyWindow ?? false,
            windowShows: sideEffects.windowShows(window),
            isDisplayAsleep: agentLights.isDisplayAsleep, isSessionOut: agentLights.isSessionInactive,
            sinceWake: state.lastWakeAt.map { now - $0 }, sinceUnlock: state.lastUnlockAt.map { now - $0 },
            sinceSessionReturn: state.lastSessionReturnAt.map { now - $0 }, sinceFront: state.lastFrontAt.map { now - $0 },
            sinceUncovered: state.lastUncoveredAt.map { now - $0 }
        )
    }

    func logSidebarState(_ trigger: SidebarStaleLog.Trigger, pointerIdle: CFTimeInterval?) {
        sideEffects.logSidebarState(SidebarStaleLog.line(sidebarStaleFacts(trigger, pointerIdle: pointerIdle)))
    }
}
