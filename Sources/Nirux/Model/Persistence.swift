import Foundation

/// Saves/restores workspace layout to ~/Library/Application Support/nirux/state.json
///
/// Recovery copies live next to it:
/// - `state.backup.1…5.json`: 1 mirrors the last state written, 2…5 are the
///   distinct states before it (including any another build wrote).
/// - `state.daily.YYYY-MM-DD.json`: the first save of each day, kept for a
///   week, because an active session cycles through the backups in a minute.
/// - `state.corrupt.<timestamp>.json`: a state.json this build could not
///   read or decode (hand edit, disk damage, a newer build's format), copied
///   (or hard-linked, if unreadable) before a save replaces it. Never read
///   back; kept for manual recovery.
enum Persistence {
    private static let maxBackups = 5
    private static let loadCache = PersistenceLoadCache()
    /// Prefix of the uniquely named files a save stages before renaming them
    /// into place; crash leftovers are swept once a day.
    static let stagingPrefix = "state.tmp-"

    private static var stateURL: URL {
        // Development builds need NIRUX_STATE_DIR: on the real state they
        // would restore AND re-save the installed app's file, duplicating
        // live agent sessions, so RealStateGuard stops them without it.
        // (HOME is not respected by Application Support resolution — this is.)
        if let override = stateDirectoryOverride(in: ProcessInfo.processInfo.environment) {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("state.json")
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("nirux")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("[Nirux Persistence] Failed to create state dir: %@", error.localizedDescription)
        }
        return dir.appendingPathComponent("state.json")
    }

    /// The folder NIRUX_STATE_DIR moves the state to; nil when the state is
    /// the real one. RealStateGuard asks the same question at launch.
    static func stateDirectoryOverride(in environment: [String: String]) -> String? {
        guard let override = environment["NIRUX_STATE_DIR"], !override.isEmpty else { return nil }
        return override
    }

    /// Whether state.json or any recovery copy exists, readable or not. Tells
    /// a fresh install from one whose state couldn't be loaded.
    static var hasStoredState: Bool {
        let dir = stateDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.contains { name in
            name == "state.json"
                || (name.hasPrefix("state.backup.") && name.hasSuffix(".json"))
                || (name.hasPrefix("state.daily.") && name.hasSuffix(".json"))
                || (name.hasPrefix("state.corrupt.") && name.hasSuffix(".json"))
        }
    }

    /// The directory holding state.json — also where the hook-events log
    /// lives. Resolves NIRUX_STATE_DIR the same way stateURL does (the hook
    /// receiver process inherits that env from the terminal that spawned it,
    /// so both ends always agree on the location).
    static var stateDirectory: URL {
        stateURL.deletingLastPathComponent()
    }

    private static func backupURL(_ index: Int, in dir: URL) -> URL {
        dir.appendingPathComponent("state.backup.\(index).json")
    }

    /// Writes state.json only when its bytes change, so the 10 s heartbeat
    /// doesn't cycle identical copies through the backups. `now` picks the
    /// daily snapshot's date.
    @discardableResult
    static func save(_ state: PersistedState, now: Date = Date()) -> Bool {
        let url = stateURL
        let dir = url.deletingLastPathComponent()
        do {
            let encoder = JSONEncoder()
            // Stable key order keeps unchanged state byte-identical.
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(state)
            let existing = try? Data(contentsOf: url)
            if existing != data {
                guard keepCurrentState(at: url, contents: existing, now: now) else { return false }
                if existing == nil, FileManager.default.fileExists(atPath: url.path) {
                    try replaceUnreadable(url, with: data, in: dir)
                } else {
                    try data.write(to: url, options: .atomic)
                }
                // A state recovered for bytes that may come back is stale now.
                loadCache.clear()
                // Only after a successful write, so failing retries (disk
                // full) can't cycle the history out.
                pushBackup(data, in: dir)
            }
            writeDailySnapshotIfNeeded(data, in: dir, now: now)
            return true
        } catch {
            NSLog("[Nirux Persistence] Failed to save state: %@", error.localizedDescription)
            return false
        }
    }

    /// Makes what state.json holds survive the write that replaces it,
    /// without moving it: the atomic write swaps it out, so state.json is
    /// never missing. A decodable file already is backup.1 or gets pushed
    /// (another build or a hand edit wrote it); one this build can't decode
    /// is copied to state.corrupt.*; one it can't even read is hard-linked
    /// there, which needs no read access. False when that failed: then it
    /// must not be replaced.
    private static func keepCurrentState(at url: URL, contents: Data?, now: Date) -> Bool {
        let dir = url.deletingLastPathComponent()
        guard let contents else {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return true }
            guard !isDirectory.boolValue else {
                NSLog("[Nirux Persistence] state.json is a directory — not replacing it")
                return false
            }
            return setAsideUnusable(url, contents: nil, now: now)
        }
        let decodable = loadCache.lookup(path: url.path, contents: contents)?.decodedFromContents
            ?? (decode(contents, name: url.lastPathComponent) != nil)
        guard decodable else { return setAsideUnusable(url, contents: contents, now: now) }
        return contents == (try? Data(contentsOf: backupURL(1, in: dir))) || pushBackup(contents, in: dir)
    }

    /// Swaps new contents in for a state.json that can't be read. rename(2)
    /// replaces it atomically, like the usual write, but unlike Data's
    /// atomic write it doesn't carry the unreadable permissions over.
    private static func replaceUnreadable(_ url: URL, with data: Data, in dir: URL) throws {
        let staged = stagingURL(in: dir)
        do {
            try data.write(to: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        guard rename(staged.path, url.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? FileManager.default.removeItem(at: staged)
            throw POSIXError(code)
        }
    }

    /// Unique per call: other processes may share the state directory.
    private static func stagingURL(in dir: URL) -> URL {
        dir.appendingPathComponent("\(stagingPrefix)\(UUID().uuidString).json")
    }

    /// Shift state.backup.N.json → N+1 and put `data` in 1, so backup.1
    /// mirrors the last write and 2…5 are the distinct states before it.
    /// backup.1 moves out of the way first: when it can't (immutable, a
    /// directory), nothing else has moved, so retries can't drain the chain.
    /// False when `data` didn't land in backup.1.
    @discardableResult
    private static func pushBackup(_ data: Data, in dir: URL) -> Bool {
        let fm = FileManager.default
        let newest = backupURL(1, in: dir)
        let staged = stagingURL(in: dir)
        let displaced = stagingURL(in: dir)
        do {
            try data.write(to: staged)
            if fm.fileExists(atPath: newest.path) { try fm.moveItem(at: newest, to: displaced) }
        } catch {
            try? fm.removeItem(at: staged)
            NSLog("[Nirux Persistence] Failed to update %@: %@", newest.lastPathComponent, error.localizedDescription)
            return false
        }
        // rename(2) replaces its destination atomically; a failed one keeps it.
        for index in stride(from: maxBackups - 1, through: 2, by: -1)
        where fm.fileExists(atPath: backupURL(index, in: dir).path) {
            rename(backupURL(index, in: dir).path, backupURL(index + 1, in: dir).path)
        }
        if fm.fileExists(atPath: displaced.path) { rename(displaced.path, backupURL(2, in: dir).path) }
        guard rename(staged.path, newest.path) == 0 else {
            try? fm.removeItem(at: staged)
            return false
        }
        return true
    }

    /// `now` decides which daily snapshots are dated in the future.
    static func load(now: Date = Date()) -> PersistedState? {
        let url = stateURL
        let dir = url.deletingLastPathComponent()
        let contents: Data
        do {
            contents = try Data(contentsOf: url)
        } catch {
            // Missing file is normal on first run — don't log it.
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            NSLog("[Nirux Persistence] Failed to load state.json: %@", error.localizedDescription)
            return recoverFromCopies(in: dir, now: now)
        }
        if let cached = loadCache.lookup(path: url.path, contents: contents) { return cached.state }
        let decoded = decode(contents, name: url.lastPathComponent)
        let state = decoded ?? recoverFromCopies(in: dir, now: now)
        loadCache.store(.init(path: url.path, contents: contents, state: state, decodedFromContents: decoded != nil))
        return state
    }

    /// Corruption recovery: the rotating backups newest-first, then the daily
    /// snapshots newest-first.
    private static func recoverFromCopies(in dir: URL, now: Date) -> PersistedState? {
        let candidates = (1...maxBackups).map { backupURL($0, in: dir) } + dailySnapshotURLs(in: dir, now: now)
        for url in candidates {
            if let recovered = load(from: url) {
                NSLog("[Nirux Persistence] state.json unreadable — recovered from %@", url.lastPathComponent)
                return recovered
            }
        }
        return nil
    }

    private static func load(from url: URL) -> PersistedState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return decode(try Data(contentsOf: url), name: url.lastPathComponent)
        } catch {
            NSLog("[Nirux Persistence] Failed to load %@: %@", url.lastPathComponent, error.localizedDescription)
            return nil
        }
    }

    private static func decode(_ data: Data, name: String) -> PersistedState? {
        do {
            return try JSONDecoder().decode(PersistedState.self, from: data)
        } catch {
            NSLog("[Nirux Persistence] Failed to load %@: %@", name, error.localizedDescription)
            return nil
        }
    }

    /// Applies `update` to the saved settings, keeping the saved layout. When
    /// nothing loads (state.json missing, or it and every copy unreadable),
    /// they are saved with `liveLayout`, the layout on screen, rather than
    /// with no workspaces, which a relaunch after a crash, or another build,
    /// would restore until the next heartbeat. The layout is empty only when
    /// that is nil.
    /// `liveLayout` is evaluated only then: it scans processes and settles
    /// restored columns.
    @discardableResult
    static func updateSettings(
        liveLayout: @autoclosure () -> PersistedState?,
        _ update: (inout PersistedSettings) -> Void
    ) -> Bool {
        var state = load() ?? liveLayout() ?? PersistedState(workspaces: [], activeWorkspaceIndex: 0)
        var settings = state.settings ?? PersistedSettings()
        update(&settings)
        state.settings = settings
        return save(state)
    }
}

struct PersistedState: Codable {
    var workspaces: [PersistedWorkspace]
    var activeWorkspaceIndex: Int
    var settings: PersistedSettings?
    var workspaceProfiles: [WorkspaceProfile]?
    var activeProfileID: String?
    var activeWorkspaceID: String?
    var projectsFileVersion: Int? // mirror/marker rules: see ProjectStore
}

struct PersistedSettings: Codable {
    var claudeLaunchMode: ClaudeLaunchMode?
    var claudeNoFlicker: Bool? = true
    var codexLaunchMode: CodexLaunchMode?
    var sidebarExpanded: Bool?
    var sidebarWidth: Double?
    /// Parent/child messages between worktree agents (Missions). On for a
    /// new install; a state file keeps what it holds (before the Lead it
    /// was an opt-in Experimental setting, always written). A space's Lead
    /// and its tasks use Missions whatever it says (`Mission.reportsToLead`).
    var missionHandoffsEnabled: Bool = true
    /// Answer Claude permission dialogs from the sidebar (see
    /// `PermissionApproval`). On for a new install, as Mission handoffs.
    var sidebarApprovalsEnabled: Bool = true
    /// See `KeepAwakeController`. On by default: missing decodes to true.
    var keepMacAwakeWhileAgentsWork: Bool = true
    /// Lights that breathe and pulse, and the other animations of the
    /// interface. Off, states show without moving. On by default: missing
    /// decodes to true.
    var animatesInterface: Bool = true
    /// The Claude plan usage limits in the title bar (see
    /// `ClaudeUsageLimits`). Opt-in: it makes Nirux Claude Code's status
    /// line. Missing decodes to false.
    var showClaudeUsageLimits: Bool = false
    /// A Claude turn end alerts (banner, Dock) only when its final message
    /// asks something (see `ClaudeTurnEndClassifier`). On by default:
    /// missing decodes to true.
    var alertOnlyWhenClaudeAsks: Bool = true
    /// Each Claude turn end writes where its task stands on its row (see
    /// `ClaudeTurnStatusWriter`). On by default; missing decodes to
    /// `alertOnlyWhenClaudeAsks`: whoever turned that off kept final
    /// messages away from a model.
    var showTurnStatus: Bool = true
    var generateTaskNames: Bool = true
    /// After an absence, a card lists the tasks whose turn ended meanwhile
    /// (see `SidebarCatchUp`). On by default: missing decodes to true.
    var showCatchUp: Bool = true
    /// A pull request whose checks failed says when the failure looks
    /// flaky (see `CITriage`). On by default: missing decodes to true.
    var triageCIFailures: Bool = true
    /// Minutes a dialog may wait before its agent reads as stuck; 0 = off.
    var stuckAgentMinutes: Int?
    /// A working Claude that may be going in circles says so on its row
    /// (see `AgentCirclingHint`). On by default: missing decodes to true.
    var agentCirclingHint: Bool = true
    /// First-launch checklist. Nil in state files that predate it; see
    /// `OnboardingChecklist.launchState`.
    var onboardingChecklist: OnboardingChecklistState?
    /// A value a newer build wrote, kept so saving doesn't erase it.
    private var unknownOnboardingChecklistRawValue: String?
    /// When restored agents start; nil means `AgentResumeOnLaunch.defaultValue`.
    var agentResumeOnLaunch: AgentResumeOnLaunch?
    /// A value a newer build wrote, kept so saving doesn't erase it.
    private var unknownAgentResumeOnLaunchRawValue: String?
    /// How much of the desktop shows through the chrome (Settings ›
    /// Appearance); nil means `InterfaceTransparency.defaultValue`.
    var interfaceTransparency: InterfaceTransparency?
    /// A value a newer build wrote, kept so saving doesn't erase it.
    private var unknownInterfaceTransparencyRawValue: String?
    /// The terminals' background opacity (Settings › Appearance ›
    /// Terminals), 0.6 to 1; nil means 1.
    var terminalOpacity: Double?
    /// Branch Review's Explain: the account each project (space) accepted
    /// the first-use notice for (`ExplainAccount.identity`), by project id.
    /// Asked again when the account changes.
    var explainNoticeAccounts: [String: String] = [:]
    /// Branch Review's Explain: the model and effort it asks for; nil runs
    /// `BranchReview.ExplainSettings`'s defaults.
    var explainModel: String?
    var explainEffort: String?
    /// Where a task without a repository gets its folder (see
    /// NewTask+Folder); nil: `~/Nirux Tasks`.
    var tasksFolder: String?
    /// A task without a repository started once: the ⌘N sheet no longer
    /// says that Claude Code asks to trust each new folder.
    var startedFolderTask: Bool = false
    /// The order of the Board's lines, the Board's switch's. Missing, or
    /// one this build doesn't know, reads as the sidebar's.
    var boardOrder = BoardStages.Order.sidebar

    init(
        claudeLaunchMode: ClaudeLaunchMode? = nil,
        claudeNoFlicker: Bool? = true,
        codexLaunchMode: CodexLaunchMode? = nil,
        sidebarExpanded: Bool? = nil,
        missionHandoffsEnabled: Bool = true,
        sidebarApprovalsEnabled: Bool = true,
        onboardingChecklist: OnboardingChecklistState? = nil
    ) {
        self.claudeLaunchMode = claudeLaunchMode
        self.claudeNoFlicker = claudeNoFlicker
        self.codexLaunchMode = codexLaunchMode
        self.sidebarExpanded = sidebarExpanded
        self.missionHandoffsEnabled = missionHandoffsEnabled
        self.sidebarApprovalsEnabled = sidebarApprovalsEnabled
        self.onboardingChecklist = onboardingChecklist
    }

    enum CodingKeys: String, CodingKey {
        case claudeLaunchMode
        case claudeNoFlicker
        case codexLaunchMode
        case sidebarExpanded
        case sidebarWidth
        case missionHandoffsEnabled
        case sidebarApprovalsEnabled
        case keepMacAwakeWhileAgentsWork
        case animatesInterface
        case showClaudeUsageLimits
        case alertOnlyWhenClaudeAsks
        case showTurnStatus
        case generateTaskNames
        case showCatchUp
        case triageCIFailures
        case stuckAgentMinutes
        case agentCirclingHint
        case onboardingChecklist
        case agentResumeOnLaunch
        case interfaceTransparency
        case terminalOpacity
        case explainNoticeAccounts
        case explainModel
        case explainEffort
        case tasksFolder
        case startedFolderTask
        case boardOrder
        case claudeManualMode
        case claudeBypassPermissions // legacy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A mode this build doesn't know reads as none, not as a file that
        // can't be read.
        if let mode = (try? container.decodeIfPresent(ClaudeLaunchMode.self, forKey: .claudeLaunchMode)) ?? nil {
            claudeLaunchMode = mode
        } else if !container.contains(.claudeLaunchMode),
                  (try? container.decodeIfPresent(Bool.self, forKey: .claudeManualMode)) == true {
            claudeLaunchMode = .manual
        } else if let legacy = (try? container.decodeIfPresent(Bool.self, forKey: .claudeBypassPermissions)) ?? nil {
            // Old `claudeBypassPermissions: true` emitted `--dangerously-skip-permissions`,
            // which `.skipPermissions` keeps.
            claudeLaunchMode = legacy ? .skipPermissions : .default
        } else {
            claudeLaunchMode = nil
        }
        claudeNoFlicker = try container.decodeIfPresent(Bool.self, forKey: .claudeNoFlicker) ?? true
        codexLaunchMode = (try? container.decodeIfPresent(CodexLaunchMode.self, forKey: .codexLaunchMode)) ?? nil
        sidebarExpanded = try container.decodeIfPresent(Bool.self, forKey: .sidebarExpanded)
        sidebarWidth = try? container.decode(Double.self, forKey: .sidebarWidth)
        missionHandoffsEnabled = try container.decodeIfPresent(Bool.self, forKey: .missionHandoffsEnabled) ?? true
        sidebarApprovalsEnabled = try container.decodeIfPresent(Bool.self, forKey: .sidebarApprovalsEnabled) ?? true
        keepMacAwakeWhileAgentsWork = try container.decodeIfPresent(Bool.self, forKey: .keepMacAwakeWhileAgentsWork) ?? true
        animatesInterface = (try? container.decodeIfPresent(Bool.self, forKey: .animatesInterface)) ?? true
        showClaudeUsageLimits = try container.decodeIfPresent(Bool.self, forKey: .showClaudeUsageLimits) ?? false
        alertOnlyWhenClaudeAsks = try container.decodeIfPresent(Bool.self, forKey: .alertOnlyWhenClaudeAsks) ?? true
        showTurnStatus = (try? container.decodeIfPresent(Bool.self, forKey: .showTurnStatus)) ?? alertOnlyWhenClaudeAsks
        generateTaskNames = (try? container.decodeIfPresent(Bool.self, forKey: .generateTaskNames)) ?? true
        showCatchUp = (try? container.decodeIfPresent(Bool.self, forKey: .showCatchUp)) ?? true
        triageCIFailures = try container.decodeIfPresent(Bool.self, forKey: .triageCIFailures) ?? true
        stuckAgentMinutes = (try? container.decodeIfPresent(Int.self, forKey: .stuckAgentMinutes)).flatMap { $0 }.map { max(0, $0) }
        agentCirclingHint = try container.decodeIfPresent(Bool.self, forKey: .agentCirclingHint) ?? true
        // A value from a newer build must not make the whole state file
        // undecodable: it reads as "no record" and is written back as is.
        if let raw = try? container.decodeIfPresent(String.self, forKey: .onboardingChecklist) {
            onboardingChecklist = OnboardingChecklistState(rawValue: raw)
            if onboardingChecklist == nil { unknownOnboardingChecklistRawValue = raw }
        }
        if let raw = try? container.decodeIfPresent(String.self, forKey: .agentResumeOnLaunch) {
            agentResumeOnLaunch = AgentResumeOnLaunch(rawValue: raw)
            if agentResumeOnLaunch == nil { unknownAgentResumeOnLaunchRawValue = raw }
        }
        if let raw = try? container.decodeIfPresent(String.self, forKey: .interfaceTransparency) {
            interfaceTransparency = InterfaceTransparency(rawValue: raw)
            if interfaceTransparency == nil { unknownInterfaceTransparencyRawValue = raw }
        }
        terminalOpacity = (try? container.decodeIfPresent(Double.self, forKey: .terminalOpacity)).flatMap { $0 }.map(TerminalOpacity.clamped)
        explainNoticeAccounts = (try? container.decodeIfPresent([String: String].self, forKey: .explainNoticeAccounts)) ?? [:]
        explainModel = try? container.decodeIfPresent(String.self, forKey: .explainModel)
        explainEffort = try? container.decodeIfPresent(String.self, forKey: .explainEffort)
        // Only an absolute path: anything else falls back to the default.
        tasksFolder = (try? container.decodeIfPresent(String.self, forKey: .tasksFolder)).flatMap { $0 }.flatMap {
            $0.hasPrefix("/") ? $0 : nil
        }
        startedFolderTask = (try? container.decodeIfPresent(Bool.self, forKey: .startedFolderTask)) ?? false
        boardOrder = (try? container.decodeIfPresent(String.self, forKey: .boardOrder)).flatMap { $0 }
            .flatMap(BoardStages.Order.init(rawValue:)) ?? .sidebar
    }

    /// Custom encoder is required because `CodingKeys` carries the legacy
    /// `claudeBypassPermissions` key, which has no matching stored property —
    /// the synthesized encoder rejects that.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Builds before Manual fail on an unknown `claudeLaunchMode`, and
        // with it the whole state file: they read this key's absence as
        // Claude Code default. This one reads an unknown mode as none, so
        // the next mode needs no key of its own.
        if claudeLaunchMode == .manual {
            try container.encode(true, forKey: .claudeManualMode)
        } else {
            try container.encodeIfPresent(claudeLaunchMode, forKey: .claudeLaunchMode)
        }
        try container.encodeIfPresent(claudeNoFlicker, forKey: .claudeNoFlicker)
        try container.encodeIfPresent(codexLaunchMode, forKey: .codexLaunchMode)
        try container.encodeIfPresent(sidebarExpanded, forKey: .sidebarExpanded)
        try container.encodeIfPresent(sidebarWidth, forKey: .sidebarWidth)
        try container.encode(missionHandoffsEnabled, forKey: .missionHandoffsEnabled)
        try container.encode(sidebarApprovalsEnabled, forKey: .sidebarApprovalsEnabled)
        try container.encode(keepMacAwakeWhileAgentsWork, forKey: .keepMacAwakeWhileAgentsWork)
        try container.encode(animatesInterface, forKey: .animatesInterface)
        try container.encode(showClaudeUsageLimits, forKey: .showClaudeUsageLimits)
        try container.encode(alertOnlyWhenClaudeAsks, forKey: .alertOnlyWhenClaudeAsks)
        try container.encode(generateTaskNames, forKey: .generateTaskNames)
        try container.encode(showTurnStatus, forKey: .showTurnStatus)
        try container.encode(showCatchUp, forKey: .showCatchUp)
        try container.encode(triageCIFailures, forKey: .triageCIFailures)
        try container.encodeIfPresent(stuckAgentMinutes, forKey: .stuckAgentMinutes)
        try container.encode(agentCirclingHint, forKey: .agentCirclingHint)
        try container.encodeIfPresent(
            onboardingChecklist?.rawValue ?? unknownOnboardingChecklistRawValue, forKey: .onboardingChecklist
        )
        try container.encodeIfPresent(
            agentResumeOnLaunch?.rawValue ?? unknownAgentResumeOnLaunchRawValue, forKey: .agentResumeOnLaunch
        )
        try container.encodeIfPresent(
            interfaceTransparency?.rawValue ?? unknownInterfaceTransparencyRawValue, forKey: .interfaceTransparency
        )
        try container.encodeIfPresent(terminalOpacity, forKey: .terminalOpacity)
        if !explainNoticeAccounts.isEmpty { try container.encode(explainNoticeAccounts, forKey: .explainNoticeAccounts) }
        try container.encodeIfPresent(explainModel, forKey: .explainModel)
        try container.encodeIfPresent(explainEffort, forKey: .explainEffort)
        try container.encodeIfPresent(tasksFolder, forKey: .tasksFolder)
        if startedFolderTask { try container.encode(true, forKey: .startedFolderTask) }
        if boardOrder != .sidebar { try container.encode(boardOrder.rawValue, forKey: .boardOrder) }
    }

    /// What applies: the saved settings, else the defaults (nothing saved
    /// yet, or the state file can't be read).
    static func effective(_ settings: PersistedSettings?) -> PersistedSettings {
        settings ?? PersistedSettings()
    }
}

struct PersistedWorkspace: Codable {
    var id: String?
    var title: String
    var cwd: String
    var columns: [PersistedColumn]
    var focusedColumnIndex: Int
    var profileID: String?
    var isInactive: Bool
    /// Mission owning this child workspace, when the experimental handoff
    /// flow created it. Optional for backward compatibility.
    var missionID: String?
    /// See `WorkspaceState.parentWorkspaceID`.
    var parentWorkspaceID: String?
    /// See `WorkspaceState.parentIsSettled`. Written only when true.
    var parentIsSettled: Bool
    var purpose: String?
    /// Optional manual phase override. Nil keeps the workspace on automatic
    /// phase derivation.
    var phase: WorkspacePhase?
    var unknownPhaseRawValue: String?
    var lastSummary: String?
    var lastSummaryIsManual: Bool
    /// See `WorkspaceState.lastSummaryIsStatus`. Written only when true.
    var lastSummaryIsStatus: Bool
    var lastActivityAt: TimeInterval?
    var nextStep: String?
    var blocker: String?
    /// See `WorkspaceState.nextStepIsFromLead`. Written only when true: a
    /// build before S13 drops them, and the fields become the user's.
    var nextStepIsFromLead: Bool
    var blockerIsFromLead: Bool
    /// `ReviewPass` raw values: a pass this build doesn't know is dropped
    /// on load, never a reason to fail the workspace.
    var reviewRuns: [String: ReviewRun]?
    /// See `WorkspaceState.startedOutsideNirux`. Written only when true.
    var startedOutsideNirux: Bool
    /// See `WorkspaceState.startedByAgent`. Written only when true.
    var startedByAgent: Bool
    /// See `WorkspaceState.isLead`. Written only when true: a build before
    /// the Lead restores it as a plain workspace.
    var isLead: Bool
    /// See `WorkspaceState.leadAgentUUID`. A Lead saved without it takes
    /// its first terminal.
    var leadAgentUUID: String?
    /// See `WorkspaceState.reportsToLead`. Written only when true.
    var reportsToLead: Bool
    /// See `WorkspaceState.reportsToTask`. Written only when true.
    var reportsToTask: Bool
    /// See `WorkspaceState.taskFolder`. A build before it restores the
    /// task as a plain workspace.
    var taskFolder: String?
    /// See `WorkspaceState.mergeWaits`. One this build can't read is
    /// dropped, never the workspace.
    var mergeWaits: [MergeWait]?

    init(
        id: String? = nil,
        title: String,
        cwd: String,
        columns: [PersistedColumn],
        focusedColumnIndex: Int,
        profileID: String? = nil,
        isInactive: Bool = false,
        missionID: String? = nil,
        parentWorkspaceID: String? = nil,
        parentIsSettled: Bool = false,
        purpose: String? = nil,
        phase: WorkspacePhase? = nil,
        unknownPhaseRawValue: String? = nil,
        lastSummary: String? = nil,
        lastSummaryIsManual: Bool = false,
        lastSummaryIsStatus: Bool = false,
        lastActivityAt: TimeInterval? = nil,
        nextStep: String? = nil,
        blocker: String? = nil,
        nextStepIsFromLead: Bool = false,
        blockerIsFromLead: Bool = false,
        reviewRuns: [String: ReviewRun]? = nil,
        startedOutsideNirux: Bool = false,
        startedByAgent: Bool = false,
        isLead: Bool = false,
        leadAgentUUID: String? = nil,
        reportsToLead: Bool = false,
        reportsToTask: Bool = false,
        taskFolder: String? = nil,
        mergeWaits: [MergeWait]? = nil
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.columns = columns
        self.focusedColumnIndex = focusedColumnIndex
        self.profileID = profileID
        self.isInactive = isInactive
        self.missionID = missionID
        self.parentWorkspaceID = parentWorkspaceID
        self.parentIsSettled = parentIsSettled
        self.purpose = purpose
        self.phase = phase
        self.unknownPhaseRawValue = phase == nil ? unknownPhaseRawValue : nil
        self.lastSummary = lastSummary
        self.lastSummaryIsManual = lastSummaryIsManual
        self.lastSummaryIsStatus = lastSummaryIsStatus
        self.lastActivityAt = lastActivityAt
        self.nextStep = nextStep
        self.blocker = blocker
        self.nextStepIsFromLead = nextStepIsFromLead
        self.blockerIsFromLead = blockerIsFromLead
        self.reviewRuns = reviewRuns
        self.startedOutsideNirux = startedOutsideNirux
        self.startedByAgent = startedByAgent
        self.isLead = isLead
        self.leadAgentUUID = leadAgentUUID
        self.reportsToLead = reportsToLead
        self.reportsToTask = reportsToTask
        self.taskFolder = taskFolder
        self.mergeWaits = mergeWaits
    }

    enum CodingKeys: String, CodingKey {
        case id, title, cwd, columns, focusedColumnIndex, profileID, isInactive, missionID, parentWorkspaceID, parentIsSettled
        case purpose, phase, lastSummary, lastSummaryIsManual, lastSummaryIsStatus, lastActivityAt
        case nextStep, blocker, nextStepIsFromLead, blockerIsFromLead, reviewRuns, startedOutsideNirux, startedByAgent, isLead
        case leadAgentUUID
        case reportsToLead, reportsToTask
        case taskFolder, mergeWaits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        cwd = try container.decode(String.self, forKey: .cwd)
        columns = try container.decode([PersistedColumn].self, forKey: .columns)
        focusedColumnIndex = try container.decode(Int.self, forKey: .focusedColumnIndex)
        profileID = try container.decodeIfPresent(String.self, forKey: .profileID)
        isInactive = try container.decodeIfPresent(Bool.self, forKey: .isInactive) ?? false
        missionID = try container.decodeIfPresent(String.self, forKey: .missionID)
        // Only the sidebar's order: a shape this build can't read never
        // fails the state.
        parentWorkspaceID = (try? container.decodeIfPresent(String.self, forKey: .parentWorkspaceID)) ?? nil
        parentIsSettled = (try? container.decodeIfPresent(Bool.self, forKey: .parentIsSettled)) ?? false
        purpose = try container.decodeIfPresent(String.self, forKey: .purpose)
        let phaseRawValue = try container.decodeIfPresent(String.self, forKey: .phase)
        phase = phaseRawValue.flatMap(WorkspacePhase.init(rawValue:))
        unknownPhaseRawValue = phase == nil ? phaseRawValue : nil
        lastSummary = try container.decodeIfPresent(String.self, forKey: .lastSummary)
        lastSummaryIsManual = try container.decodeIfPresent(Bool.self, forKey: .lastSummaryIsManual) ?? false
        lastSummaryIsStatus = (try? container.decodeIfPresent(Bool.self, forKey: .lastSummaryIsStatus)) ?? false
        lastActivityAt = try container.decodeIfPresent(TimeInterval.self, forKey: .lastActivityAt)
        nextStep = try container.decodeIfPresent(String.self, forKey: .nextStep)
        blocker = try container.decodeIfPresent(String.self, forKey: .blocker)
        nextStepIsFromLead = (try? container.decodeIfPresent(Bool.self, forKey: .nextStepIsFromLead)) ?? false
        blockerIsFromLead = (try? container.decodeIfPresent(Bool.self, forKey: .blockerIsFromLead)) ?? false
        // Only badges: a shape this build can't read never fails the state.
        reviewRuns = (try? container.decodeIfPresent([String: ReviewRun].self, forKey: .reviewRuns)) ?? nil
        startedOutsideNirux = (try? container.decodeIfPresent(Bool.self, forKey: .startedOutsideNirux)) ?? false
        startedByAgent = (try? container.decodeIfPresent(Bool.self, forKey: .startedByAgent)) ?? false
        isLead = (try? container.decodeIfPresent(Bool.self, forKey: .isLead)) ?? false
        leadAgentUUID = (try? container.decodeIfPresent(String.self, forKey: .leadAgentUUID)) ?? nil
        reportsToLead = (try? container.decodeIfPresent(Bool.self, forKey: .reportsToLead)) ?? false
        reportsToTask = (try? container.decodeIfPresent(Bool.self, forKey: .reportsToTask)) ?? false
        // Only an absolute path: anything else is no task folder.
        taskFolder = (try? container.decodeIfPresent(String.self, forKey: .taskFolder)).flatMap { $0 }.flatMap {
            $0.hasPrefix("/") ? $0 : nil
        }
        let waits = Lossy<MergeWait>.array(container, .mergeWaits)
        mergeWaits = waits.isEmpty ? nil : waits
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(columns, forKey: .columns)
        try container.encode(focusedColumnIndex, forKey: .focusedColumnIndex)
        try container.encodeIfPresent(profileID, forKey: .profileID)
        try container.encode(isInactive, forKey: .isInactive)
        try container.encodeIfPresent(missionID, forKey: .missionID)
        try container.encodeIfPresent(parentWorkspaceID, forKey: .parentWorkspaceID)
        if parentIsSettled { try container.encode(true, forKey: .parentIsSettled) }
        try container.encodeIfPresent(purpose, forKey: .purpose)
        try container.encodeIfPresent(
            phase?.rawValue ?? unknownPhaseRawValue,
            forKey: .phase
        )
        try container.encodeIfPresent(lastSummary, forKey: .lastSummary)
        try container.encode(lastSummaryIsManual, forKey: .lastSummaryIsManual)
        if lastSummaryIsStatus { try container.encode(true, forKey: .lastSummaryIsStatus) }
        try container.encodeIfPresent(lastActivityAt, forKey: .lastActivityAt)
        try container.encodeIfPresent(nextStep, forKey: .nextStep)
        try container.encodeIfPresent(blocker, forKey: .blocker)
        if nextStepIsFromLead { try container.encode(true, forKey: .nextStepIsFromLead) }
        if blockerIsFromLead { try container.encode(true, forKey: .blockerIsFromLead) }
        try container.encodeIfPresent(reviewRuns, forKey: .reviewRuns)
        if startedOutsideNirux { try container.encode(true, forKey: .startedOutsideNirux) }
        if startedByAgent { try container.encode(true, forKey: .startedByAgent) }
        if isLead { try container.encode(true, forKey: .isLead) }
        try container.encodeIfPresent(leadAgentUUID, forKey: .leadAgentUUID)
        if reportsToLead { try container.encode(true, forKey: .reportsToLead) }
        if reportsToTask { try container.encode(true, forKey: .reportsToTask) }
        try container.encodeIfPresent(taskFolder, forKey: .taskFolder)
        try container.encodeIfPresent(mergeWaits, forKey: .mergeWaits)
    }
}

struct PersistedColumn: Codable {
    var widthPreset: Double // raw CGFloat value
    var cwd: String
    var columnType: ColumnKind?
    var webViewURL: String? // current URL for webView columns
    /// Absolute paths of all open tabs in this editor column.
    var editorOpenFiles: [String]?
    /// Absolute path of the active tab. Must be present in `editorOpenFiles`.
    var editorActiveFile: String?
    var claudeLaunchMode: ClaudeLaunchMode?
    var codexLaunchMode: CodexLaunchMode?
    var agentModel: String?
    /// Exact Codex thread formerly attached to this column. Older state files
    /// omit it and restore through Codex's interactive session picker.
    var codexSessionID: String?
    /// Exact Claude session formerly attached to this column. Older state
    /// files omit it and restore through Claude's interactive session picker.
    var claudeSessionID: String?
    /// The Antigravity conversation this column's `agy` ran, from its hooks.
    var agySessionID: String?
    /// The column's Claude session was never prompted (a fresh start or
    /// /clear): there is nothing to resume, so restore starts a new one.
    var claudeSessionIsUnprompted: Bool?
    /// Stable hook-routing identity (NIRUX_AGENT_UUID) for terminal columns.
    var agentUUID: String?
    /// The space a Board column shows: its workspace's, written for the
    /// builds that read it (a Board could show another space then). A build
    /// older still restores the column as a terminal in `cwd`.
    var boardProjectID: String?
    /// The branch a Branch Review column reviews, in the worktree at `cwd`.
    /// An older build restores the column as a terminal there.
    var reviewBranch: String?
    /// An agent column's session title and status when last saved with its
    /// agent running: what the column says until its agent resumes.
    var lastAgentTitle: String?
    var lastAgentStatus: PersistedAgentStatus?

    /// Non-optional accessor — missing or unknown `columnType` means terminal.
    var resolvedType: ColumnKind { columnType ?? .terminal }

    init(
        widthPreset: Double, cwd: String, columnType: ColumnKind?,
        webViewURL: String?,
        editorOpenFiles: [String]? = nil,
        editorActiveFile: String? = nil,
        claudeLaunchMode: ClaudeLaunchMode?,
        codexLaunchMode: CodexLaunchMode?,
        agentModel: String? = nil,
        codexSessionID: String? = nil,
        claudeSessionID: String? = nil,
        claudeSessionIsUnprompted: Bool? = nil,
        agySessionID: String? = nil,
        agentUUID: String? = nil,
        boardProjectID: String? = nil,
        reviewBranch: String? = nil,
        lastAgentTitle: String? = nil,
        lastAgentStatus: PersistedAgentStatus? = nil
    ) {
        self.widthPreset = widthPreset
        self.cwd = cwd
        self.columnType = columnType
        self.webViewURL = webViewURL
        self.editorOpenFiles = editorOpenFiles
        self.editorActiveFile = editorActiveFile
        self.claudeLaunchMode = claudeLaunchMode
        self.codexLaunchMode = codexLaunchMode
        self.agentModel = agentModel
        self.codexSessionID = codexSessionID
        self.claudeSessionID = claudeSessionID
        self.claudeSessionIsUnprompted = claudeSessionIsUnprompted
        self.agySessionID = agySessionID
        self.agentUUID = agentUUID
        self.boardProjectID = boardProjectID
        self.reviewBranch = reviewBranch
        self.lastAgentTitle = lastAgentTitle
        self.lastAgentStatus = lastAgentStatus
    }

    enum CodingKeys: String, CodingKey {
        case widthPreset, cwd, columnType, webViewURL
        case editorOpenFiles, editorActiveFile
        case editorOpenFile // legacy single-file editor state
        case claudeLaunchMode
        case codexLaunchMode, agentModel
        case codexSessionID
        case claudeSessionID
        case claudeSessionIsUnprompted
        case agySessionID
        case agentUUID
        case boardProjectID
        case reviewBranch
        case lastAgentTitle
        case lastAgentStatus
        case claudeBypassPermissions // legacy
    }

    /// Custom decoder: tolerate unknown `columnType` values (from older
    /// builds or hand-edited state files) by falling back to nil instead of
    /// failing the entire decode. Also migrates the legacy
    /// `claudeBypassPermissions` bool and `editorOpenFile` single-file state.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        widthPreset = try container.decode(Double.self, forKey: .widthPreset)
        cwd = try container.decode(String.self, forKey: .cwd)
        columnType = try? container.decodeIfPresent(ColumnKind.self, forKey: .columnType)
        webViewURL = try container.decodeIfPresent(String.self, forKey: .webViewURL)

        if let openList = try? container.decodeIfPresent([String].self, forKey: .editorOpenFiles), !openList.isEmpty {
            editorOpenFiles = openList
            editorActiveFile = try container.decodeIfPresent(String.self, forKey: .editorActiveFile) ?? openList.first
        } else if let legacy = try? container.decodeIfPresent(String.self, forKey: .editorOpenFile) {
            // Old format: single file. Promote to a one-tab list.
            editorOpenFiles = [legacy]
            editorActiveFile = legacy
        } else {
            editorOpenFiles = nil
            editorActiveFile = nil
        }

        if let mode = try? container.decodeIfPresent(ClaudeLaunchMode.self, forKey: .claudeLaunchMode) {
            claudeLaunchMode = mode
        } else if let legacy = try? container.decodeIfPresent(Bool.self, forKey: .claudeBypassPermissions) {
            // See PersistedSettings: old bool true emitted `--dangerously-skip-permissions`.
            claudeLaunchMode = legacy ? .skipPermissions : nil
        } else {
            claudeLaunchMode = nil
        }
        codexLaunchMode = try? container.decodeIfPresent(CodexLaunchMode.self, forKey: .codexLaunchMode)
        agentModel = try? container.decodeIfPresent(String.self, forKey: .agentModel)
        codexSessionID = try? container.decodeIfPresent(String.self, forKey: .codexSessionID)
        claudeSessionID = try? container.decodeIfPresent(String.self, forKey: .claudeSessionID)
        claudeSessionIsUnprompted = try? container.decodeIfPresent(Bool.self, forKey: .claudeSessionIsUnprompted)
        agySessionID = try? container.decodeIfPresent(String.self, forKey: .agySessionID)
        agentUUID = try? container.decodeIfPresent(String.self, forKey: .agentUUID)
        boardProjectID = try? container.decodeIfPresent(String.self, forKey: .boardProjectID)
        reviewBranch = try? container.decodeIfPresent(String.self, forKey: .reviewBranch)
        lastAgentTitle = try? container.decodeIfPresent(String.self, forKey: .lastAgentTitle)
        lastAgentStatus = try? container.decodeIfPresent(PersistedAgentStatus.self, forKey: .lastAgentStatus)
    }

    /// Custom encoder is required because `CodingKeys` carries the legacy
    /// `claudeBypassPermissions` / `editorOpenFile` keys with no matching
    /// stored property.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(widthPreset, forKey: .widthPreset)
        try container.encode(cwd, forKey: .cwd)
        try container.encodeIfPresent(columnType, forKey: .columnType)
        try container.encodeIfPresent(webViewURL, forKey: .webViewURL)
        try container.encodeIfPresent(editorOpenFiles, forKey: .editorOpenFiles)
        try container.encodeIfPresent(editorActiveFile, forKey: .editorActiveFile)
        try container.encodeIfPresent(claudeLaunchMode, forKey: .claudeLaunchMode)
        try container.encodeIfPresent(codexLaunchMode, forKey: .codexLaunchMode)
        try container.encodeIfPresent(agentModel, forKey: .agentModel)
        try container.encodeIfPresent(codexSessionID, forKey: .codexSessionID)
        try container.encodeIfPresent(claudeSessionID, forKey: .claudeSessionID)
        try container.encodeIfPresent(claudeSessionIsUnprompted, forKey: .claudeSessionIsUnprompted)
        try container.encodeIfPresent(agySessionID, forKey: .agySessionID)
        try container.encodeIfPresent(agentUUID, forKey: .agentUUID)
        try container.encodeIfPresent(boardProjectID, forKey: .boardProjectID)
        try container.encodeIfPresent(reviewBranch, forKey: .reviewBranch)
        try container.encodeIfPresent(lastAgentTitle, forKey: .lastAgentTitle)
        try container.encodeIfPresent(lastAgentStatus, forKey: .lastAgentStatus)
    }
}

/// An older build decodes a kind it doesn't know as a terminal.
enum ColumnKind: String, Codable {
    case terminal, webView, claudeCode, codex, editor, projectBoard, branchReview
    /// Antigravity CLI.
    case agy
}

// MARK: - URL History

/// Persists recently visited browser URLs to url_history.json next to
/// state.json (~/Library/Application Support/nirux), so NIRUX_STATE_DIR
/// moves it too.
enum URLHistory {
    private static var fileURL: URL {
        Persistence.stateDirectory.appendingPathComponent("url_history.json")
    }

    private static let maxEntries = 16

    static func load() -> [String] {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            NSLog("[Nirux URLHistory] Failed to load history: %@", error.localizedDescription)
            return []
        }
    }

    static func save(_ urls: [String]) {
        let trimmed = Array(urls.prefix(maxEntries))
        do {
            let data = try JSONEncoder().encode(trimmed)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[Nirux URLHistory] Failed to save history: %@", error.localizedDescription)
        }
    }

    /// Add a URL to history (most recent first, deduped, keeps full protocol).
    /// Inputs that look like search queries (no `://`, no `.`, not `localhost`)
    /// are silently ignored so we don't fill history with typed search terms.
    static func add(_ url: String) {
        guard let fullURL = normalize(url) else { return }
        var history = load()
        history.removeAll { $0 == fullURL }
        history.insert(fullURL, at: 0)
        save(history)
    }

    /// Normalize a user-entered URL:
    /// - Already has a scheme (`https://foo`) → return verbatim
    /// - Bare host with a dot or starting with `localhost` → prefix `https://`
    /// - Everything else (looks like a search query) → nil
    ///
    /// Pulled out as an internal pure function so it's testable without
    /// touching the on-disk history store.
    static func normalize(_ url: String) -> String? {
        if url.contains("://") { return url }
        if url.contains(".") || url.hasPrefix("localhost") { return "https://" + url }
        return nil
    }
}
