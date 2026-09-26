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

    private static var stateURL: URL {
        // Development escape hatch: a debug launch restores AND re-saves the
        // same state file, duplicating live agent sessions. Point
        // NIRUX_STATE_DIR elsewhere to smoke-test safely. (HOME is not
        // respected by Application Support resolution — this is.)
        if let override = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"], !override.isEmpty {
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
                try data.write(to: url, options: .atomic)
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

    /// Shift state.backup.N.json → N+1 and put `data` in 1, so backup.1
    /// mirrors the last write and 2…5 are the distinct states before it.
    /// Staged first, under a unique name since other processes may share the
    /// directory, so a write that fails leaves the chain as it was. False
    /// when `data` didn't land in backup.1.
    @discardableResult
    private static func pushBackup(_ data: Data, in dir: URL) -> Bool {
        let fm = FileManager.default
        let staged = dir.appendingPathComponent("state.backup.pending-\(UUID().uuidString).json")
        do {
            try data.write(to: staged, options: .atomic)
        } catch {
            NSLog("[Nirux Persistence] Failed to write backup: %@", error.localizedDescription)
            return false
        }
        for index in stride(from: maxBackups - 1, through: 1, by: -1) {
            let src = backupURL(index, in: dir)
            let dst = backupURL(index + 1, in: dir)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.removeItem(at: dst)
            try? fm.moveItem(at: src, to: dst)
        }
        let newest = backupURL(1, in: dir)
        try? fm.removeItem(at: newest)
        do {
            try fm.moveItem(at: staged, to: newest)
            return true
        } catch {
            try? fm.removeItem(at: staged)
            NSLog("[Nirux Persistence] Failed to update %@: %@", newest.lastPathComponent, error.localizedDescription)
            return false
        }
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
}

struct PersistedState: Codable {
    var workspaces: [PersistedWorkspace]
    var activeWorkspaceIndex: Int
    var settings: PersistedSettings?
    var workspaceProfiles: [WorkspaceProfile]?
    var activeProfileID: String?
    var activeWorkspaceID: String?
}

/// Mirrors Claude Code's `--permission-mode` values plus the legacy
/// `--dangerously-skip-permissions` shortcut. `bypassPermissions` and
/// `skipPermissions` are deliberately separate: per docs, the former still
/// prompts for writes inside protected dirs (`.git`, `.claude`, …) while the
/// latter bypasses *everything* (so we expose both honestly).
enum ClaudeLaunchMode: String, Codable, CaseIterable {
    case `default`
    case acceptEdits
    case auto
    case plan
    case dontAsk
    case bypassPermissions
    case skipPermissions

    var displayName: String {
        switch self {
        case .default: return "Default (ask for permission)"
        case .acceptEdits: return "Accept edits (file edits + common fs commands)"
        case .auto: return "Auto (approve with safety checks — research preview)"
        case .plan: return "Plan (read-only)"
        case .dontAsk: return "Don't ask (deny unless pre-approved)"
        case .bypassPermissions: return "Bypass permissions (still asks for .git/.claude)"
        case .skipPermissions: return "Skip all permissions (most aggressive)"
        }
    }

    /// argv tail to append after `claude`. Empty for `.default`.
    var cliArgs: [String] {
        switch self {
        case .default: return []
        case .acceptEdits: return ["--permission-mode", "acceptEdits"]
        case .auto: return ["--permission-mode", "auto"]
        case .plan: return ["--permission-mode", "plan"]
        case .dontAsk: return ["--permission-mode", "dontAsk"]
        case .bypassPermissions: return ["--permission-mode", "bypassPermissions"]
        case .skipPermissions: return ["--dangerously-skip-permissions"]
        }
    }
}

/// Curated presets over Codex's two CLI axes (`--ask-for-approval` and
/// `--sandbox`). Full Auto removes Codex's sandbox, enables web search, and
/// runs without approval prompts. Workspace Write preserves the old sandboxed
/// non-blocking mode.
enum CodexLaunchMode: String, Codable, CaseIterable {
    case `default`
    case fullAccess
    case workspaceWrite
    case readOnly
    case fullAuto
    case bypass

    static let niruxDefault: CodexLaunchMode = .fullAuto

    var displayName: String {
        switch self {
        case .default: return "Default (codex defaults)"
        case .fullAccess: return "Full Access (no sandbox)"
        case .workspaceWrite: return "Workspace Write (sandboxed, asks to escalate)"
        case .readOnly: return "Read-only"
        case .fullAuto: return "Full Auto (no sandbox, non-blocking)"
        case .bypass: return "Yolo (bypass approvals & sandbox)"
        }
    }

    /// argv tail to append after `codex` or either `codex resume` form.
    var cliArgs: [String] {
        switch self {
        case .default: return []
        case .fullAccess: return ["--sandbox", "danger-full-access"]
        // codex >= 0.143.0 removed the `on-failure` approval policy; `never`
        // returns sandbox failures to the model, `on-request` lets it ask.
        case .workspaceWrite: return ["--sandbox", "workspace-write", "--ask-for-approval", "on-request"]
        case .readOnly: return ["--sandbox", "read-only"]
        case .fullAuto: return ["--sandbox", "danger-full-access", "--ask-for-approval", "never", "--search"]
        case .bypass: return ["--dangerously-bypass-approvals-and-sandbox"]
        }
    }

    /// Recover a preset only when argv identifies its sandbox and approval
    /// semantics; nil leaves restore on the backward-compatible default path.
    static func detect(arguments: [String]) -> CodexLaunchMode? {
        if arguments.contains("--dangerously-bypass-approvals-and-sandbox") {
            return .bypass
        }
        guard let sandboxIndex = arguments.firstIndex(of: "--sandbox"),
              arguments.indices.contains(sandboxIndex + 1) else { return nil }
        switch arguments[sandboxIndex + 1] {
        case "workspace-write":
            return .workspaceWrite
        case "read-only":
            return .readOnly
        case "danger-full-access":
            guard let approvalIndex = arguments.firstIndex(of: "--ask-for-approval"),
                  arguments.indices.contains(approvalIndex + 1),
                  arguments[approvalIndex + 1] == "never",
                  arguments.contains("--search") else { return .fullAccess }
            return .fullAuto
        default:
            return nil
        }
    }
}

struct PersistedSettings: Codable {
    var claudeLaunchMode: ClaudeLaunchMode?
    var claudeNoFlicker: Bool? = true
    var codexLaunchMode: CodexLaunchMode?
    var sidebarExpanded: Bool?
    var inactiveWorkspacesCollapsed: Bool?
    /// Experimental and intentionally opt-in. Missing in older state files
    /// decodes to false so existing worktree behavior is unchanged.
    var missionHandoffsEnabled: Bool = false
    /// Master gate. Secrets never live here; the bot token is in Keychain.
    var telegramRemoteAccessEnabled: Bool = false
    var telegramPairedUserID: Int64?
    var telegramPairedChatID: Int64?
    var telegramNotifyOnCompletion: Bool = true
    var telegramNotifyOnAttention: Bool = true
    /// Last update claimed before execution, giving prompt delivery
    /// at-most-once semantics across app restarts.
    var telegramLastUpdateID: Int64?

    init(
        claudeLaunchMode: ClaudeLaunchMode? = nil,
        claudeNoFlicker: Bool? = true,
        codexLaunchMode: CodexLaunchMode? = nil,
        sidebarExpanded: Bool? = nil,
        inactiveWorkspacesCollapsed: Bool? = nil,
        missionHandoffsEnabled: Bool = false,
        telegramRemoteAccessEnabled: Bool = false,
        telegramPairedUserID: Int64? = nil,
        telegramPairedChatID: Int64? = nil,
        telegramNotifyOnCompletion: Bool = true,
        telegramNotifyOnAttention: Bool = true,
        telegramLastUpdateID: Int64? = nil
    ) {
        self.claudeLaunchMode = claudeLaunchMode
        self.claudeNoFlicker = claudeNoFlicker
        self.codexLaunchMode = codexLaunchMode
        self.sidebarExpanded = sidebarExpanded
        self.inactiveWorkspacesCollapsed = inactiveWorkspacesCollapsed
        self.missionHandoffsEnabled = missionHandoffsEnabled
        self.telegramRemoteAccessEnabled = telegramRemoteAccessEnabled
        self.telegramPairedUserID = telegramPairedUserID
        self.telegramPairedChatID = telegramPairedChatID
        self.telegramNotifyOnCompletion = telegramNotifyOnCompletion
        self.telegramNotifyOnAttention = telegramNotifyOnAttention
        self.telegramLastUpdateID = telegramLastUpdateID
    }

    enum CodingKeys: String, CodingKey {
        case claudeLaunchMode
        case claudeNoFlicker
        case codexLaunchMode
        case sidebarExpanded
        case inactiveWorkspacesCollapsed
        case missionHandoffsEnabled
        case telegramRemoteAccessEnabled
        case telegramPairedUserID
        case telegramPairedChatID
        case telegramNotifyOnCompletion
        case telegramNotifyOnAttention
        case telegramLastUpdateID
        case claudeBypassPermissions // legacy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let mode = try container.decodeIfPresent(ClaudeLaunchMode.self, forKey: .claudeLaunchMode) {
            claudeLaunchMode = mode
        } else if let legacy = try container.decodeIfPresent(Bool.self, forKey: .claudeBypassPermissions) {
            // Old `claudeBypassPermissions: true` emitted `--dangerously-skip-permissions`,
            // so migrate it to `.skipPermissions` rather than the milder `.bypassPermissions`.
            claudeLaunchMode = legacy ? .skipPermissions : .default
        } else {
            claudeLaunchMode = nil
        }
        claudeNoFlicker = try container.decodeIfPresent(Bool.self, forKey: .claudeNoFlicker) ?? true
        codexLaunchMode = try container.decodeIfPresent(CodexLaunchMode.self, forKey: .codexLaunchMode)
        sidebarExpanded = try container.decodeIfPresent(Bool.self, forKey: .sidebarExpanded)
        inactiveWorkspacesCollapsed = try container.decodeIfPresent(Bool.self, forKey: .inactiveWorkspacesCollapsed)
        missionHandoffsEnabled = try container.decodeIfPresent(Bool.self, forKey: .missionHandoffsEnabled) ?? false
        telegramRemoteAccessEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .telegramRemoteAccessEnabled
        ) ?? false
        telegramPairedUserID = try container.decodeIfPresent(Int64.self, forKey: .telegramPairedUserID)
        telegramPairedChatID = try container.decodeIfPresent(Int64.self, forKey: .telegramPairedChatID)
        telegramNotifyOnCompletion = try container.decodeIfPresent(
            Bool.self, forKey: .telegramNotifyOnCompletion
        ) ?? true
        telegramNotifyOnAttention = try container.decodeIfPresent(
            Bool.self, forKey: .telegramNotifyOnAttention
        ) ?? true
        telegramLastUpdateID = try container.decodeIfPresent(Int64.self, forKey: .telegramLastUpdateID)
    }

    /// Custom encoder is required because `CodingKeys` carries the legacy
    /// `claudeBypassPermissions` key, which has no matching stored property —
    /// the synthesized encoder rejects that.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(claudeLaunchMode, forKey: .claudeLaunchMode)
        try container.encodeIfPresent(claudeNoFlicker, forKey: .claudeNoFlicker)
        try container.encodeIfPresent(codexLaunchMode, forKey: .codexLaunchMode)
        try container.encodeIfPresent(sidebarExpanded, forKey: .sidebarExpanded)
        try container.encodeIfPresent(inactiveWorkspacesCollapsed, forKey: .inactiveWorkspacesCollapsed)
        try container.encode(missionHandoffsEnabled, forKey: .missionHandoffsEnabled)
        try container.encode(telegramRemoteAccessEnabled, forKey: .telegramRemoteAccessEnabled)
        try container.encodeIfPresent(telegramPairedUserID, forKey: .telegramPairedUserID)
        try container.encodeIfPresent(telegramPairedChatID, forKey: .telegramPairedChatID)
        try container.encode(telegramNotifyOnCompletion, forKey: .telegramNotifyOnCompletion)
        try container.encode(telegramNotifyOnAttention, forKey: .telegramNotifyOnAttention)
        try container.encodeIfPresent(telegramLastUpdateID, forKey: .telegramLastUpdateID)
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
    var purpose: String?
    /// Optional manual phase override. Nil keeps the workspace on automatic
    /// phase derivation.
    var phase: WorkspacePhase?
    var unknownPhaseRawValue: String?
    var lastSummary: String?
    var lastSummaryIsManual: Bool
    var lastActivityAt: TimeInterval?
    var nextStep: String?
    var blocker: String?

    init(
        id: String? = nil,
        title: String,
        cwd: String,
        columns: [PersistedColumn],
        focusedColumnIndex: Int,
        profileID: String? = nil,
        isInactive: Bool = false,
        missionID: String? = nil,
        purpose: String? = nil,
        phase: WorkspacePhase? = nil,
        unknownPhaseRawValue: String? = nil,
        lastSummary: String? = nil,
        lastSummaryIsManual: Bool = false,
        lastActivityAt: TimeInterval? = nil,
        nextStep: String? = nil,
        blocker: String? = nil
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.columns = columns
        self.focusedColumnIndex = focusedColumnIndex
        self.profileID = profileID
        self.isInactive = isInactive
        self.missionID = missionID
        self.purpose = purpose
        self.phase = phase
        self.unknownPhaseRawValue = phase == nil ? unknownPhaseRawValue : nil
        self.lastSummary = lastSummary
        self.lastSummaryIsManual = lastSummaryIsManual
        self.lastActivityAt = lastActivityAt
        self.nextStep = nextStep
        self.blocker = blocker
    }

    enum CodingKeys: String, CodingKey {
        case id, title, cwd, columns, focusedColumnIndex, profileID, isInactive, missionID
        case purpose, phase, lastSummary, lastSummaryIsManual, lastActivityAt
        case nextStep, blocker
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
        purpose = try container.decodeIfPresent(String.self, forKey: .purpose)
        let phaseRawValue = try container.decodeIfPresent(String.self, forKey: .phase)
        phase = phaseRawValue.flatMap(WorkspacePhase.init(rawValue:))
        unknownPhaseRawValue = phase == nil ? phaseRawValue : nil
        lastSummary = try container.decodeIfPresent(String.self, forKey: .lastSummary)
        lastSummaryIsManual = try container.decodeIfPresent(Bool.self, forKey: .lastSummaryIsManual) ?? false
        lastActivityAt = try container.decodeIfPresent(TimeInterval.self, forKey: .lastActivityAt)
        nextStep = try container.decodeIfPresent(String.self, forKey: .nextStep)
        blocker = try container.decodeIfPresent(String.self, forKey: .blocker)
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
        try container.encodeIfPresent(purpose, forKey: .purpose)
        try container.encodeIfPresent(
            phase?.rawValue ?? unknownPhaseRawValue,
            forKey: .phase
        )
        try container.encodeIfPresent(lastSummary, forKey: .lastSummary)
        try container.encode(lastSummaryIsManual, forKey: .lastSummaryIsManual)
        try container.encodeIfPresent(lastActivityAt, forKey: .lastActivityAt)
        try container.encodeIfPresent(nextStep, forKey: .nextStep)
        try container.encodeIfPresent(blocker, forKey: .blocker)
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
    /// Exact Codex thread formerly attached to this column. Older state files
    /// omit it and restore through Codex's interactive session picker.
    var codexSessionID: String?
    /// Stable hook-routing identity (NIRUX_AGENT_UUID) for terminal columns.
    var agentUUID: String?

    /// Non-optional accessor — missing or unknown `columnType` means terminal.
    var resolvedType: ColumnKind { columnType ?? .terminal }

    init(
        widthPreset: Double, cwd: String, columnType: ColumnKind?,
        webViewURL: String?,
        editorOpenFiles: [String]? = nil,
        editorActiveFile: String? = nil,
        claudeLaunchMode: ClaudeLaunchMode?,
        codexLaunchMode: CodexLaunchMode?,
        codexSessionID: String? = nil,
        agentUUID: String? = nil
    ) {
        self.widthPreset = widthPreset
        self.cwd = cwd
        self.columnType = columnType
        self.webViewURL = webViewURL
        self.editorOpenFiles = editorOpenFiles
        self.editorActiveFile = editorActiveFile
        self.claudeLaunchMode = claudeLaunchMode
        self.codexLaunchMode = codexLaunchMode
        self.codexSessionID = codexSessionID
        self.agentUUID = agentUUID
    }

    enum CodingKeys: String, CodingKey {
        case widthPreset, cwd, columnType, webViewURL
        case editorOpenFiles, editorActiveFile
        case editorOpenFile // legacy single-file editor state
        case claudeLaunchMode
        case codexLaunchMode
        case codexSessionID
        case agentUUID
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
        codexSessionID = try? container.decodeIfPresent(String.self, forKey: .codexSessionID)
        agentUUID = try? container.decodeIfPresent(String.self, forKey: .agentUUID)
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
        try container.encodeIfPresent(codexSessionID, forKey: .codexSessionID)
        try container.encodeIfPresent(agentUUID, forKey: .agentUUID)
    }
}

enum ColumnKind: String, Codable {
    case terminal, webView, claudeCode, codex, editor
}

// MARK: - URL History

/// Persists recently visited browser URLs to ~/Library/Application Support/nirux/url_history.json
enum URLHistory {
    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("nirux")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("[Nirux URLHistory] Failed to create history dir: %@", error.localizedDescription)
        }
        return dir.appendingPathComponent("url_history.json")
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
