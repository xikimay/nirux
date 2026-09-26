import Foundation
import Security

/// Per-launch secret that lets Nirux tell its own terminals apart from any
/// other `nirux://` caller. URL handlers are reachable by every local app and
/// by any web page (one click on a browser's "Open Nirux?" prompt), so
/// actions that start processes must either present this value or be
/// confirmed by the user.
///
/// Exported to every terminal as `NIRUX_LAUNCH_ID`; the installed skills and
/// the in-app worktree flow pass it back as `launch=${NIRUX_LAUNCH_ID}`, left
/// for the agent's shell to expand so the value stays out of prompts,
/// transcripts and the scrollback (unless `open` itself fails and echoes the
/// URL back). The names avoid TOKEN/KEY/SECRET, which
/// agent CLIs can strip from tool environments (e.g. Claude Code's
/// CLAUDE_CODE_SUBPROCESS_ENV_SCRUB).
///
/// It proves "sent from inside a Nirux terminal", nothing finer: any process
/// in a terminal (including a sandboxed agent) inherits it. It is never
/// persisted: a relaunch (including a Sparkle update) rotates it, and
/// terminals are recreated with the new value.
enum NiruxLaunchAuthorization {
    static let environmentKey = "NIRUX_LAUNCH_ID"
    static let queryItemName = "launch"

    static let launchID: String = makeLaunchID()

    static func isValid(_ candidate: String?, expected: String = launchID) -> Bool {
        guard let candidate, !expected.isEmpty else { return false }
        let lhs = Array(candidate.utf8)
        let rhs = Array(expected.utf8)
        guard lhs.count == rhs.count else { return false }
        // Constant-time: don't leak the matching prefix length via timing.
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    private static func makeLaunchID() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // SystemRandomNumberGenerator is also CSPRNG-backed on Darwin.
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Parsed `nirux://` request. `init(url:)` is pure so the routing rules can
/// be tested; `resolvingPaths()` does the filesystem part (off the main
/// actor), and the remaining checks happen where the action is performed
/// (`OpenEditorRequest`, `HandoverFile`, `GitWorktree.create`).
struct NiruxURLRequest: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// nirux://new-workspace?cwd=...&title=...&agent=claude|codex&profile=...
        case newWorkspace(cwd: String?, title: String?, agent: NiruxApp.WorkspaceAgent?)
        /// nirux://new-worktree?branch=...&repo=...&agent=...&handover=...&profile=...
        case newWorktree(NewWorktree)
        /// nirux://open-editor?file=...&line=...&endLine=...&workspace=...
        /// Parsed separately by `OpenEditorRequest`, which needs file I/O.
        case openEditor
    }

    struct NewWorktree: Equatable, Sendable {
        let branch: String
        let repo: String
        let agent: NiruxApp.WorkspaceAgent?
        /// Kept even when it breaks the handover rules: only the handover is
        /// dropped then (see `HandoverFile.transfer`), not the whole request.
        let handoverPath: String?
        let parentWorkspaceID: String?
        let parentAgentUUID: String?
    }

    enum Disposition: Equatable {
        case perform
        case confirm
        case openEditor
    }

    let action: Action
    let profileID: String?
    let launchID: String?

    init(action: Action, profileID: String?, launchID: String?) {
        self.action = action
        self.profileID = profileID
        self.launchID = launchID
    }

    init?(url: URL) {
        guard url.scheme == "nirux" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            guard let raw = items.first(where: { $0.name == name })?.value, !raw.isEmpty else { return nil }
            return raw
        }
        let agent = value("agent").flatMap(NiruxApp.WorkspaceAgent.init(rawValue:))

        switch url.host {
        case "new-workspace":
            if let cwd = value("cwd"), !cwd.hasPrefix("/") { return nil }
            action = .newWorkspace(cwd: value("cwd"), title: value("title"), agent: agent)
        case "new-worktree":
            guard let branch = value("branch"),
                  let repo = value("repo"), repo.hasPrefix("/")
            else { return nil }
            action = .newWorktree(NewWorktree(
                branch: branch,
                repo: repo,
                agent: agent,
                handoverPath: value("handover"),
                parentWorkspaceID: value("parentWorkspace"),
                parentAgentUUID: value("parentAgent")
            ))
        case "open-editor":
            action = .openEditor
        default:
            return nil
        }
        profileID = ["profile", "profileID", "space"].lazy.compactMap(value).first
        launchID = Self.launchID(in: url)
    }

    /// First `launch=` value, also read for URLs that fail to parse so a
    /// broken request from a Nirux terminal can still be reported.
    static func launchID(in url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let raw = items.first(where: { $0.name == NiruxLaunchAuthorization.queryItemName })?.value,
              !raw.isEmpty else { return nil }
        return raw
    }

    func hasValidLaunchID(expected: String = NiruxLaunchAuthorization.launchID) -> Bool {
        NiruxLaunchAuthorization.isValid(launchID, expected: expected)
    }

    /// The security gate. Starting a shell or an agent needs this launch's
    /// ID or the user's confirmation. `open-editor` only displays a
    /// size-capped text file and never executes anything, so it keeps
    /// working without the ID (it just doesn't bring Nirux to the front).
    func disposition(expectedLaunchID: String = NiruxLaunchAuthorization.launchID) -> Disposition {
        switch action {
        case .openEditor:
            return .openEditor
        case .newWorkspace, .newWorktree:
            return hasValidLaunchID(expected: expectedLaunchID) ? .perform : .confirm
        }
    }

    /// Replace `cwd`/`repo` with their realpath, so the confirmation shows
    /// exactly the folder the action will use (no `/./` padding or `..`
    /// tricks). Nil when the folder doesn't exist. Blocking file-system
    /// calls: run off the main actor.
    func resolvingPaths(
        realPath: (String) -> String? = { $0.realPath },
        isDirectory: (String) -> Bool = NiruxURLRequest.directoryExists
    ) -> NiruxURLRequest? {
        func resolve(_ path: String) -> String? {
            guard let resolved = realPath(path), isDirectory(resolved) else { return nil }
            return resolved
        }
        switch action {
        case let .newWorkspace(cwd, title, agent):
            var resolvedCwd: String?
            if let cwd {
                guard let resolved = resolve(cwd) else { return nil }
                resolvedCwd = resolved
            }
            return NiruxURLRequest(
                action: .newWorkspace(cwd: resolvedCwd, title: title, agent: agent),
                profileID: profileID,
                launchID: launchID
            )
        case .newWorktree(let request):
            guard let repo = resolve(request.repo) else { return nil }
            return NiruxURLRequest(
                action: .newWorktree(NewWorktree(
                    branch: request.branch,
                    repo: repo,
                    agent: request.agent,
                    handoverPath: request.handoverPath,
                    parentWorkspaceID: request.parentWorkspaceID,
                    parentAgentUUID: request.parentAgentUUID
                )),
                profileID: profileID,
                launchID: launchID
            )
        case .openEditor:
            return self
        }
    }

    /// A request the user confirmed (no valid launch ID) must not link the
    /// new agent to a live parent agent's Mission mailbox: the sheet doesn't
    /// show that link, and it would give an outside caller a channel to it.
    func droppingMissionLink() -> NiruxURLRequest {
        guard case .newWorktree(let request) = action else { return self }
        return NiruxURLRequest(
            action: .newWorktree(NewWorktree(
                branch: request.branch,
                repo: request.repo,
                agent: request.agent,
                handoverPath: request.handoverPath,
                parentWorkspaceID: nil,
                parentAgentUUID: nil
            )),
            profileID: profileID,
            launchID: launchID
        )
    }

    static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Confirmation

    struct Confirmation: Equatable {
        let message: String
        let details: String
        let confirmButton: String
    }

    /// Text for the sheet shown when a request arrives without a valid
    /// launch ID. Everything the action will do is spelled out, including
    /// the agent's permission mode: a request from a web page would inherit
    /// it. Call it on a request that went through `resolvingPaths()`.
    func confirmation(claudeMode: ClaudeLaunchMode, codexMode: CodexLaunchMode) -> Confirmation? {
        // One wording whether the launch ID is missing or stale: a caller
        // could add a fake `launch=` to pick a more reassuring text.
        let intro = "This request didn’t come from a current Nirux terminal. That happens with an agent "
            + "using an outdated Nirux skill (run “Install Agent Skills” from the command palette), or a "
            + "terminal started before Nirux last restarted (for example inside tmux). It may also come "
            + "from a web page, a document or another app. Only continue if you started it."
        // Confirming runs git in the folder (worktree creation, sidebar status),
        // and a repository's own hooks and config can execute code.
        let gitNote = "Nirux runs git in this folder: a repository you don’t trust can run code that way."
        func agentLine(_ agent: NiruxApp.WorkspaceAgent?) -> String {
            switch agent {
            case .claude: return "Agent: Claude Code — \(claudeMode.displayName)"
            case .codex: return "Agent: Codex — \(codexMode.displayName)"
            case nil: return "Agent: none (plain shell)"
            }
        }
        switch action {
        case let .newWorkspace(cwd, title, agent):
            var lines = [
                "Folder: \(Self.displaySafe(cwd ?? NSHomeDirectory()))",
                agentLine(agent)
            ]
            if let title { lines.append("Title: \(Self.displaySafe(title))") }
            return Confirmation(
                message: agent == nil ? "Open a new workspace?" : "Open a new workspace and start an agent?",
                details: intro + "\n\n" + lines.joined(separator: "\n") + "\n\n" + gitNote,
                confirmButton: "Open Workspace"
            )
        case let .newWorktree(request):
            var lines = [
                "Repository: \(Self.displaySafe(request.repo))",
                "Branch: \(Self.displaySafe(request.branch))",
                agentLine(request.agent)
            ]
            if let handover = request.handoverPath {
                let shown = Self.displaySafe(handover)
                if !HandoverFile.isAllowedSourcePath(handover) {
                    lines.append("Handover: \(shown) — will be ignored (not a /tmp/nirux-handover-* file).")
                } else if request.agent != nil {
                    lines.append("Handover: \(shown) — moved into the worktree; the agent is told to follow it.")
                } else {
                    lines.append("Handover: \(shown) — moved into the worktree.")
                }
            }
            return Confirmation(
                message: request.agent == nil
                    ? "Create a worktree?" : "Create a worktree and start an agent?",
                details: intro + "\n\n" + lines.joined(separator: "\n") + "\n\n" + gitNote,
                confirmButton: "Create Worktree"
            )
        case .openEditor:
            return nil
        }
    }

    /// Caller-controlled text is shown verbatim in the sheet. Neutralize
    /// control and line/paragraph separators (U+2028/2029 render as line
    /// breaks and could fake extra lines), flatten exotic spaces, and cut
    /// overly long values in the middle so both ends stay visible.
    static func displaySafe(_ value: String, limit: Int = 300) -> String {
        let hidden = CharacterSet.controlCharacters.union(.newlines)
        let scalars = value.unicodeScalars.map { scalar -> Unicode.Scalar in
            if hidden.contains(scalar) { return "\u{FFFD}" }
            if CharacterSet.whitespaces.contains(scalar) { return " " }
            return scalar
        }
        // Count scalars, not characters: one letter carrying thousands of
        // combining marks is a single Character but draws over nearby lines.
        guard scalars.count > limit else { return String(String.UnicodeScalarView(scalars)) }
        let head = limit / 3
        let kept = scalars.prefix(head) + ["…"] + scalars.suffix(limit - head)
        return String(String.UnicodeScalarView(kept))
    }

    /// `displaySafe` per line, for multi-line text Nirux composes itself
    /// (git errors, explanations) that embeds caller-controlled values.
    static func displaySafeLines(_ value: String, limit: Int = 300) -> String {
        value.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(20)
            .map { displaySafe(String($0), limit: limit) }
            .joined(separator: "\n")
    }
}

/// Pending confirmations. Bounded, one sheet at a time. A Cancel drops the
/// rest of the queue and starts a cooldown that doubles with each consecutive
/// Cancel, so a page re-sending the URL can't keep the window covered.
struct URLConfirmationQueue {
    static let capacity = 4
    static let cooldown: TimeInterval = 5
    static let maxCooldown: TimeInterval = 300

    private(set) var pending: [NiruxURLRequest] = []
    private(set) var isPresenting = false
    private var cooldownUntil: TimeInterval = 0
    private var consecutiveCancels = 0
    private var lastCancelAt: TimeInterval = -.infinity

    var isIdle: Bool { !isPresenting && pending.isEmpty }

    /// False when the request was dropped (queue full or cooling down).
    mutating func enqueue(_ request: NiruxURLRequest, now: TimeInterval) -> Bool {
        guard now >= cooldownUntil, pending.count < Self.capacity else { return false }
        pending.append(request)
        return true
    }

    /// Next request to present, or nil when a sheet is already up or there
    /// is nothing left. Marks the queue as presenting.
    mutating func startNext() -> NiruxURLRequest? {
        guard !isPresenting, !pending.isEmpty else { return nil }
        isPresenting = true
        return pending.removeFirst()
    }

    mutating func finish(confirmed: Bool, now: TimeInterval) {
        isPresenting = false
        guard !confirmed else {
            consecutiveCancels = 0
            return
        }
        pending.removeAll()
        // The back-off only escalates within a burst; after a long quiet
        // spell a single Cancel starts from the base cooldown again.
        if now - lastCancelAt > Self.maxCooldown * 2 { consecutiveCancels = 0 }
        lastCancelAt = now
        consecutiveCancels += 1
        let delay = Self.cooldown * pow(2, Double(min(consecutiveCancels - 1, 16)))
        cooldownUntil = now + min(delay, Self.maxCooldown)
    }
}
