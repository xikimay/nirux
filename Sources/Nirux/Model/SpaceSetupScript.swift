import CryptoKit
import Foundation

/// A repository's setup script (docs/projects.md, section 5): what a new
/// worktree needs before its agent starts (`npm ci`, copying an `.env`).
/// One per anchor of a space, edited in Space Settings › General, kept in
/// `<state dir>/projects/<space id>/setup/`, never in the repository.
///
/// Nirux types it before the agent command in the new worktree's terminal
/// (`command(script:…)`), only in worktrees it made for the user (New
/// Task…, the worktree skill, New Worktree), and once per worktree
/// (`claimFirstRun`): a request that reuses a worktree an agent works in
/// never runs it again there. It should still be idempotent (a worktree
/// made outside Nirux and opened later runs it once). A failure doesn't
/// stop the agent: Nirux says so in a notification.
enum SpaceSetupScript {
    static let folderName = "setup"
    static let maxFileBytes = 256 * 1024

    /// Where the anchor's script lives, whether or not it exists: named
    /// after the anchor, with a hash of its identity so two repositories
    /// with the same folder name don't share one. Nil for an unknown kind
    /// or a space id that isn't a plain name.
    static func url(spaceID: String, anchor: SpaceAnchor, stateDirectory: URL = Persistence.stateDirectory) -> URL? {
        guard let key = anchor.key,
              let folder = SpaceBrief.directory(spaceID: spaceID, stateDirectory: stateDirectory)
        else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let slug = String(String.UnicodeScalarView(anchor.name.unicodeScalars.filter { $0.isASCII && allowed.contains($0) }))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .prefix(40)
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let scripts = folder.appendingPathComponent(folderName, isDirectory: true)
        // Found by its hash: the anchor's name may differ from when it was
        // written (the repository added again from a renamed checkout).
        let suffix = hash + ".sh"
        if let existing = (try? FileManager.default.contentsOfDirectory(atPath: scripts.path))?
            .filter({ $0 == suffix || $0.hasSuffix("-" + suffix) }).min() {
            return scripts.appendingPathComponent(existing)
        }
        return scripts.appendingPathComponent((slug.isEmpty ? "" : "\(slug)-") + suffix)
    }

    /// The script's text; nil when there is none, or it can't be read as a
    /// small UTF-8 regular file.
    static func read(at url: URL) -> String? {
        guard case .data(let data) = BoardConfigStore.read(url, maxBytes: maxFileBytes) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A line that isn't blank or a comment: a script without one does
    /// nothing, so it isn't typed.
    static func hasCommands(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
    }

    /// The script a new worktree of `anchor` runs, if it has commands.
    static func scriptToRun(spaceID: String, anchor: SpaceAnchor, stateDirectory: URL = Persistence.stateDirectory) -> URL? {
        guard let url = url(spaceID: spaceID, anchor: anchor, stateDirectory: stateDirectory),
              let text = read(at: url), hasCommands(text)
        else { return nil }
        return url
    }

    /// Saves `text` as the script (0600, replaced atomically), or deletes
    /// the file when it has no command.
    static func save(_ text: String, to url: URL) throws {
        guard hasCommands(text) else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        let normalized = text.hasSuffix("\n") ? text : text + "\n"
        try SpaceDefaultsStore.writePrivately(Data(normalized.utf8), to: url)
    }

    /// What Space Settings shows for a repository without a script.
    static func template(anchorName: String) -> String {
        let name = anchorName.replacingOccurrences(of: "\n", with: " ")
        return """
        # Setup for new worktrees of \(name). Nirux runs it once per worktree it
        # makes for you, with /bin/sh -e in the worktree's folder, before the
        # agent starts: the first failing command stops it, and it reads no
        # input (a command asking a question gets no answer).
        # Keep it idempotent. If it fails, the agent still starts and Nirux
        # tells you. Lines starting with # are comments; a script with only
        # comments doesn't run. For example:
        # npm ci
        # cp "$(git rev-parse --path-format=absolute --git-common-dir)/../.env" .env

        """
    }

    /// The marker of a worktree whose setup ran, in its own git folder
    /// (`.git/worktrees/<name>`, which `git worktree remove` deletes).
    static let markerName = "nirux-setup-ran"

    /// True the first time it is asked for `worktree`, which it records:
    /// the script runs there then, never on a later request that reuses
    /// the worktree. False when git can't name the worktree's folder. Runs
    /// git: call it off the main thread.
    static func claimFirstRun(worktree: String) -> Bool {
        guard let gitDir = GitCommand.output(["rev-parse", "--absolute-git-dir"], cwd: worktree, timeout: 5)?
            .trimmingCharacters(in: .whitespacesAndNewlines), gitDir.hasPrefix("/")
        else { return false }
        let marker = URL(fileURLWithPath: gitDir).appendingPathComponent(markerName).path
        let descriptor = open(marker, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if descriptor >= 0 { close(descriptor) }
        return true
    }

    /// The line typed into a new worktree's terminal:
    /// `/bin/sh -e '<script>' </dev/null || '<Nirux>' --hook codex
    /// --setup-failed '<workspace id>'; <agent command>`, every shell Nirux
    /// supports reading it the same way (`;` runs the agent whatever the
    /// script did). `-e`: a failing command fails the script, not only its
    /// last line. No input: a command asking a question (`npx`, `pnpm`)
    /// gets an end of file instead of waiting in a terminal nobody looks
    /// at. `/bin/sh` by its path: no alias or function of the user's
    /// replaces it. The failure report is spelled as a hook so that an older Nirux
    /// at the same path (a rollback) takes it for a Codex payload it can't
    /// read and exits, instead of opening a second window on the same
    /// state. Without an executable (xctest), nothing reports the failure.
    static func command(script: String, executable: String?, workspaceID: String, then agentCommand: String?) -> String {
        var line = "/bin/sh " + quoted(script)
        if let executable {
            line += " || " + ([executable] + SetupFailureSignal.arguments(workspaceID: workspaceID)).map(quoted).joined(separator: " ")
        }
        if let agentCommand { line += "; " + agentCommand }
        return line
    }

    /// One single-quoted shell word, as `NiruxShellView.shellQuotedArgument`.
    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// `Nirux --hook codex --setup-failed <workspace id>`, run by the line a
/// setup script fails in (see SpaceSetupScript): tells the Nirux that typed
/// it, through a distributed notification naming its state directory, so
/// another Nirux (a debug build with its own state) ignores it.
enum SetupFailureSignal {
    static let flag = "--setup-failed"
    static let notificationName = Notification.Name("app.nirux.setupScriptFailed")

    static func arguments(workspaceID: String) -> [String] {
        ["--hook", "codex", flag, workspaceID]
    }

    /// The workspace id when `arguments` (the whole command line) is this
    /// signal, else nil.
    static func workspaceID(in arguments: [String]) -> String? {
        guard arguments.count >= 5, arguments[1] == "--hook", arguments[2] == "codex", arguments[3] == flag,
              isPlausibleWorkspaceID(arguments[4])
        else { return nil }
        return arguments[4]
    }

    /// Workspace ids are UUIDs; anything else is refused before it travels.
    static func isPlausibleWorkspaceID(_ id: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    /// The command-line mode: posts the signal and exits 0, so the line
    /// goes on to start the agent.
    static func run(workspaceID: String, stateDirectory: URL = Persistence.stateDirectory) -> Int32 {
        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: stateDirectory.standardizedFileURL.path,
            userInfo: ["workspaceID": workspaceID],
            deliverImmediately: true
        )
        FileHandle.standardError.write(Data("Nirux: the setup script failed; the agent starts anyway.\n".utf8))
        return 0
    }
}
