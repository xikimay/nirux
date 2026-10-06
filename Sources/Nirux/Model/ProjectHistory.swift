import Foundation

/// A project's history (docs/project-memory-tree.md): every turn of its
/// agent sessions, the messages that started it and the final reply, kept
/// word for word in an append-only journal. A later pass summarizes it into
/// a tree that new sessions see.
///
/// Off by default, per project: nothing is read or written for a project
/// until its `memory/enabled` file exists.
///
/// Files, under `<state dir>/projects/<space id>/memory/`:
/// - `enabled`: present while history is on;
/// - `log/YYYY-MM-DD.jsonl`: one message per line, in the file of the local
///   day it was written (`ProjectHistoryJournal`);
/// - `state.json`: where reading starts in transcripts that were already
///   running when history was turned on;
/// - `lock`: held by the one app that writes.
enum ProjectHistory {
    static let folderName = "memory"
    static let enabledFileName = "enabled"

    /// What a message is. Raw values are the journal's and the summaries'
    /// tags, so they never change.
    enum Kind: String, Codable, Sendable, CaseIterable {
        /// What the user typed.
        case user
        /// A message another session sent, or the prompt Nirux typed to
        /// launch the session: not the user's text.
        case peer
        /// A turn's final reply.
        case talk
        /// A memory written down before the history began.
        case note
    }

    /// One journal line.
    struct Message: Codable, Equatable, Sendable {
        /// The permanent id: 0, 1, 2… across the project's whole history.
        let i: Int
        let kind: Kind
        /// The branch of the session's checkout, when it had one.
        let branch: String?
        /// Who sent a `peer` message: another session's name, or "Nirux".
        let from: String?
        let text: String
        /// Bytes of `rendered`.
        let size: Int
        let date: Date
        /// The Claude session the message came from.
        let session: String?
        /// The transcript it was read from, its line there, and where its
        /// turn ended: offsets are derived from the log.
        let source: Source?

        struct Source: Codable, Equatable, Sendable {
            let path: String
            let uuid: String?
            /// On a turn's last message: where the turn ends.
            let end: UInt64?
        }

        /// How the compactor and the agents see it: `kind [branch]: text`,
        /// `peer [branch] from <sender>: text`.
        var rendered: String { Self.render(kind: kind, branch: branch, from: from, text: text) }

        static func render(kind: Kind, branch: String?, from: String?, text: String) -> String {
            var head = kind.rawValue
            if let branch, !branch.isEmpty { head += " [\(branch)]" }
            if kind == .peer, let from, !from.isEmpty { head += " from \(from)" }
            return "\(head): \(text)"
        }
    }

    /// A message read from a transcript, before the journal gives it an id.
    struct NewMessage: Equatable, Sendable {
        let kind: Kind
        let branch: String?
        var from: String?
        let text: String
        let date: Date
        let session: String?
        /// The transcript line's `uuid`.
        var uuid: String?

        func withText(_ text: String) -> NewMessage {
            NewMessage(kind: kind, branch: branch, from: from, text: text, date: date, session: session, uuid: uuid)
        }
    }

    /// Who sent Nirux's launch prompts and handovers.
    static let niruxSender = "Nirux"

    /// `<state dir>/projects/<space id>/memory/`, or nil for an id that
    /// isn't a plain name.
    static func folder(spaceID: String, stateDirectory: URL) -> URL? {
        SpaceBrief.directory(spaceID: spaceID, stateDirectory: stateDirectory)?
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// History is on for the project: its `enabled` file is a regular file.
    static func isEnabled(spaceID: String, stateDirectory: URL) -> Bool {
        guard let url = folder(spaceID: spaceID, stateDirectory: stateDirectory)?
            .appendingPathComponent(enabledFileName) else { return false }
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    /// The transcript a turn-end event may feed the journal from: the
    /// session ledger's path when it has one (the event must agree), named
    /// `<session id>.jsonl` in a folder of Claude's `projects` folder
    /// (`~/.claude/projects`, or `$CLAUDE_CONFIG_DIR/projects` when Nirux
    /// itself runs with that variable). A hook can be run by anything in the
    /// agent's shell, so a path it names is checked, never trusted.
    static func feedPath(
        eventPath: String?, recordPath: String?, sessionID: String, projectsFolders: [String] = claudeProjectsFolders
    ) -> String? {
        guard let path = recordPath ?? eventPath else { return nil }
        if let eventPath, eventPath != path { return nil }
        return isClaudeTranscript(path, sessionID: sessionID, projectsFolders: projectsFolders) ? path : nil
    }

    /// `<session id>.jsonl` in a folder of one of Claude's `projects`
    /// folders, not reached through a link or `..`.
    static func isClaudeTranscript(_ path: String, sessionID: String, projectsFolders: [String]) -> Bool {
        let url = URL(fileURLWithPath: path)
        let projects = url.deletingLastPathComponent().deletingLastPathComponent().path
        return url.lastPathComponent == "\(sessionID).jsonl" && !path.contains("/../") && !path.contains("/./")
            && projectsFolders.contains(projects) && !isSymbolicLink(url.deletingLastPathComponent().path)
    }

    /// A folder of Claude's `projects` folder must be one, not a link to
    /// somewhere else.
    private static func isSymbolicLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    /// Where Claude files transcripts, as Nirux can know it.
    static var claudeProjectsFolders: [String] {
        var folders = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects").path]
        if let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], config.hasPrefix("/") {
            folders.append(URL(fileURLWithPath: config).appendingPathComponent("projects").path)
        }
        return folders
    }

    /// When history was turned on: the date the `enabled` file holds, or
    /// its modification time for a file written by hand.
    static func enabledDate(spaceID: String, stateDirectory: URL) -> Date? {
        guard let url = folder(spaceID: spaceID, stateDirectory: stateDirectory)?.appendingPathComponent(enabledFileName)
        else { return nil }
        if let data = HistorySearch.readRegularFile(url.path, maxBytes: 256),
           let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) {
            return date
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }

    /// Writes `text` to `url` whole: a temporary file, then a rename. 0600.
    @discardableResult
    static func writeAtomically(_ text: String, to url: URL) -> Bool {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        let data = Data(text.utf8)
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) } == data.count && fsync(descriptor) == 0
        close(descriptor)
        guard written, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return true
    }

    /// The prompts Nirux types to launch an agent (`agentStartupPrompt`):
    /// written by Nirux for another session, so `peer`, not `user`.
    static func isLaunchPrompt(_ text: String) -> Bool {
        launchPrompts.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static let launchPrompts: Set<String> = {
        var prompts = Set<String>()
        for agent in [NiruxApp.WorkspaceAgent.claude, .codex] {
            for (handover, mission) in [(true, false), (true, true), (false, true)] {
                if let prompt = NiruxShellView.agentStartupPrompt(
                    agent: agent, deliveredHandover: handover, isMission: mission
                ) {
                    prompts.insert(prompt)
                }
            }
        }
        return prompts
    }()
}
