import Foundation

/// Saves/restores workspace layout to ~/Library/Application Support/nirux/state.json
enum Persistence {
    private static var stateURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("nirux")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("[Nirux Persistence] Failed to create state dir: %@", error.localizedDescription)
        }
        return dir.appendingPathComponent("state.json")
    }

    static func save(_ state: PersistedState) {
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            NSLog("[Nirux Persistence] Failed to save state: %@", error.localizedDescription)
        }
    }

    static func load() -> PersistedState? {
        let url = stateURL
        // Missing file is normal on first run — don't log it.
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(PersistedState.self, from: data)
        } catch {
            NSLog("[Nirux Persistence] Failed to load state: %@", error.localizedDescription)
            return nil
        }
    }
}

struct PersistedState: Codable {
    var workspaces: [PersistedWorkspace]
    var activeWorkspaceIndex: Int
    var settings: PersistedSettings?
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
        case .workspaceWrite: return "Workspace Write (sandboxed, non-blocking)"
        case .readOnly: return "Read-only"
        case .fullAuto: return "Full Auto (no sandbox, non-blocking)"
        case .bypass: return "Yolo (bypass approvals & sandbox)"
        }
    }

    /// argv tail to append after `codex` / `codex resume --last`.
    var cliArgs: [String] {
        switch self {
        case .default: return []
        case .fullAccess: return ["--sandbox", "danger-full-access"]
        case .workspaceWrite: return ["--sandbox", "workspace-write", "--ask-for-approval", "on-failure"]
        case .readOnly: return ["--sandbox", "read-only"]
        case .fullAuto: return ["--sandbox", "danger-full-access", "--ask-for-approval", "on-failure", "--search"]
        case .bypass: return ["--dangerously-bypass-approvals-and-sandbox"]
        }
    }
}

struct PersistedSettings: Codable {
    var claudeLaunchMode: ClaudeLaunchMode?
    var claudeNoFlicker: Bool? = true
    var codexLaunchMode: CodexLaunchMode?

    init(
        claudeLaunchMode: ClaudeLaunchMode? = nil,
        claudeNoFlicker: Bool? = true,
        codexLaunchMode: CodexLaunchMode? = nil
    ) {
        self.claudeLaunchMode = claudeLaunchMode
        self.claudeNoFlicker = claudeNoFlicker
        self.codexLaunchMode = codexLaunchMode
    }

    enum CodingKeys: String, CodingKey {
        case claudeLaunchMode
        case claudeNoFlicker
        case codexLaunchMode
        case claudeBypassPermissions // legacy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let mode = try c.decodeIfPresent(ClaudeLaunchMode.self, forKey: .claudeLaunchMode) {
            claudeLaunchMode = mode
        } else if let legacy = try c.decodeIfPresent(Bool.self, forKey: .claudeBypassPermissions) {
            // Old `claudeBypassPermissions: true` emitted `--dangerously-skip-permissions`,
            // so migrate it to `.skipPermissions` rather than the milder `.bypassPermissions`.
            claudeLaunchMode = legacy ? .skipPermissions : .default
        } else {
            claudeLaunchMode = nil
        }
        claudeNoFlicker = try c.decodeIfPresent(Bool.self, forKey: .claudeNoFlicker) ?? true
        codexLaunchMode = try c.decodeIfPresent(CodexLaunchMode.self, forKey: .codexLaunchMode)
    }

    /// Custom encoder is required because `CodingKeys` carries the legacy
    /// `claudeBypassPermissions` key, which has no matching stored property —
    /// the synthesized encoder rejects that.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(claudeLaunchMode, forKey: .claudeLaunchMode)
        try c.encodeIfPresent(claudeNoFlicker, forKey: .claudeNoFlicker)
        try c.encodeIfPresent(codexLaunchMode, forKey: .codexLaunchMode)
    }
}

struct PersistedWorkspace: Codable {
    var title: String
    var cwd: String
    var columns: [PersistedColumn]
    var focusedColumnIndex: Int
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

    /// Non-optional accessor — missing or unknown `columnType` means terminal.
    var resolvedType: ColumnKind { columnType ?? .terminal }

    init(
        widthPreset: Double, cwd: String, columnType: ColumnKind?,
        webViewURL: String?,
        editorOpenFiles: [String]? = nil,
        editorActiveFile: String? = nil,
        claudeLaunchMode: ClaudeLaunchMode?,
        codexLaunchMode: CodexLaunchMode?
    ) {
        self.widthPreset = widthPreset
        self.cwd = cwd
        self.columnType = columnType
        self.webViewURL = webViewURL
        self.editorOpenFiles = editorOpenFiles
        self.editorActiveFile = editorActiveFile
        self.claudeLaunchMode = claudeLaunchMode
        self.codexLaunchMode = codexLaunchMode
    }

    enum CodingKeys: String, CodingKey {
        case widthPreset, cwd, columnType, webViewURL
        case editorOpenFiles, editorActiveFile
        case editorOpenFile // legacy single-file editor state
        case claudeLaunchMode
        case codexLaunchMode
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
    }

    /// Custom encoder is required because `CodingKeys` carries the legacy
    /// `claudeBypassPermissions` / `editorOpenFile` keys with no matching
    /// stored property.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(widthPreset, forKey: .widthPreset)
        try c.encode(cwd, forKey: .cwd)
        try c.encodeIfPresent(columnType, forKey: .columnType)
        try c.encodeIfPresent(webViewURL, forKey: .webViewURL)
        try c.encodeIfPresent(editorOpenFiles, forKey: .editorOpenFiles)
        try c.encodeIfPresent(editorActiveFile, forKey: .editorActiveFile)
        try c.encodeIfPresent(claudeLaunchMode, forKey: .claudeLaunchMode)
        try c.encodeIfPresent(codexLaunchMode, forKey: .codexLaunchMode)
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
