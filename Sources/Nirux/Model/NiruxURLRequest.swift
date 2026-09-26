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
/// for the agent's shell to expand so the value never appears in a prompt,
/// a transcript or the scrollback. The names avoid TOKEN/KEY/SECRET, which
/// agent CLIs can strip from tool environments (e.g. Claude Code's
/// CLAUDE_CODE_SUBPROCESS_ENV_SCRUB).
/// It is never persisted: a relaunch (including a Sparkle update) rotates it,
/// and terminals are recreated with the new value.
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

/// Parsed `nirux://` request. Parsing is pure (no filesystem access) so the
/// routing rules can be tested; filesystem checks happen where the action is
/// performed (`OpenEditorRequest`, `HandoverFile`, `GitWorktree.create`).
struct NiruxURLRequest: Equatable {
    enum Action: Equatable {
        /// nirux://new-workspace?cwd=...&title=...&agent=claude|codex&profile=...
        case newWorkspace(cwd: String?, title: String?, agent: NiruxApp.WorkspaceAgent?)
        /// nirux://new-worktree?branch=...&repo=...&agent=...&handover=...&profile=...
        case newWorktree(NewWorktree)
        /// nirux://open-editor?file=...&line=...&endLine=...&workspace=...
        /// Parsed separately by `OpenEditorRequest`, which needs file I/O.
        case openEditor
    }

    struct NewWorktree: Equatable {
        let branch: String
        let repo: String
        let agent: NiruxApp.WorkspaceAgent?
        let handoverPath: String?
        let parentWorkspaceID: String?
        let parentAgentUUID: String?
    }

    let action: Action
    let profileID: String?
    let launchID: String?

    /// Actions that start a shell or an agent. `open-editor` only displays a
    /// size-capped text file and never executes anything, so the show-code
    /// skill keeps working unchanged without a launch ID.
    var requiresAuthorization: Bool {
        switch action {
        case .newWorkspace, .newWorktree: return true
        case .openEditor: return false
        }
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
            let handover = value("handover")
            if let handover, !HandoverFile.isAllowedSourcePath(handover) { return nil }
            action = .newWorktree(NewWorktree(
                branch: branch,
                repo: repo,
                agent: agent,
                handoverPath: handover,
                parentWorkspaceID: value("parentWorkspace"),
                parentAgentUUID: value("parentAgent")
            ))
        case "open-editor":
            action = .openEditor
        default:
            return nil
        }
        profileID = ["profile", "profileID", "space"].lazy.compactMap(value).first
        launchID = value(NiruxLaunchAuthorization.queryItemName)
    }

    // MARK: - Confirmation

    struct Confirmation: Equatable {
        let message: String
        let details: String
        let confirmButton: String
    }

    /// Text for the alert shown when a request arrives without a valid launch
    /// ID. Everything the action will do is spelled out, including the agent's
    /// permission mode: a request from a web page would inherit it.
    func confirmation(claudeMode: ClaudeLaunchMode, codexMode: CodexLaunchMode) -> Confirmation? {
        let intro = "This request did not come from a Nirux terminal. "
            + "It may come from a web page, a document, or another app. "
            + "Only continue if you started it."
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
                details: intro + "\n\n" + lines.joined(separator: "\n"),
                confirmButton: "Open Workspace"
            )
        case let .newWorktree(request):
            var lines = [
                "Repository: \(Self.displaySafe(request.repo))",
                "Branch: \(Self.displaySafe(request.branch))",
                agentLine(request.agent)
            ]
            if let handover = request.handoverPath {
                lines.append(
                    "Handover: \(Self.displaySafe(handover)) — moved into the worktree; "
                        + "the agent is told to follow it."
                )
            }
            return Confirmation(
                message: request.agent == nil
                    ? "Create a worktree?" : "Create a worktree and start an agent?",
                details: intro + "\n\n" + lines.joined(separator: "\n"),
                confirmButton: "Create Worktree"
            )
        case .openEditor:
            return nil
        }
    }

    /// Caller-controlled text is shown verbatim in the alert: neutralize
    /// control characters (a newline could fake extra lines) and cap length.
    static func displaySafe(_ value: String, limit: Int = 300) -> String {
        let cleaned = String(String.UnicodeScalarView(value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? "\u{FFFD}" : scalar
        }))
        return cleaned.count > limit ? String(cleaned.prefix(limit)) + "…" : cleaned
    }
}
