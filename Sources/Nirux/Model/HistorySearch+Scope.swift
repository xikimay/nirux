import Darwin
import Foundation

// MARK: - Which conversations belong to the project

extension HistorySearch {
    /// A conversation the search may read.
    struct Transcript: Equatable, Sendable {
        let path: String
        /// Claude's session id: the file's name.
        let sessionID: String
        let modified: Date
        /// Where the session started, as its first lines say.
        let cwd: String?
        /// The space's session ledger's record of it, when it has one.
        let record: AgentSessionRecord?
    }

    /// The project's conversations: those Claude filed for a folder of the
    /// agent's repository, and those the space's session ledger lists.
    /// Claude files transcripts by the folder a session started in
    /// (`~/.claude/projects/<folder, every other character a "-">/`), a
    /// name that can't be read back, so each candidate's `cwd` is checked
    /// (`contains`). A folder belongs to the repository when it is
    /// - one of its checkouts: the main one, or a worktree git lists;
    /// - inside one, unless a folder in between holds another repository or
    ///   checkout (a `.git` folder or file). A checkout that is the home
    ///   folder, or above it, only counts for itself;
    /// - gone, named like the worktrees Nirux makes next to the main
    ///   checkout (`<main checkout>.<branch, "/" as "-">`), with the session
    ///   started on that branch: a worktree since removed. An existing
    ///   folder named so that git doesn't list is another repository, or
    ///   none.
    ///
    /// The ledger's sessions count whatever their folder, except in the
    /// default space, where workspaces land unless moved: there it only
    /// names the repository's sessions. It never adds repositories: a
    /// workspace moved to another space leaves lines behind in the old
    /// file until a rewrite.
    struct Scope: Equatable, Sendable {
        /// Checkouts: the main one and the worktrees.
        var roots: [String] = []
        /// The main checkout, for the worktrees since removed.
        var mainCheckouts: [String] = []
        /// The space's sessions.
        var records: [AgentSessionRecord] = []
        /// The ledger's sessions count whatever their folder.
        var includesLedgerSessions = false
        /// The home folder: a checkout there, or above, holds every project.
        var home = HistorySearch.standardized(FileManager.default.homeDirectoryForCurrentUser.path)

        /// `branch`: the one the session started on.
        func contains(_ cwd: String, branch: String?) -> Bool {
            let cwd = HistorySearch.standardized(cwd)
            for root in roots {
                if cwd == root { return true }
                if cwd.hasPrefix(root + "/"), !isAtOrAbove(root, home), !hasCheckoutBetween(root, cwd) { return true }
            }
            for main in mainCheckouts where cwd.hasPrefix(main + ".") {
                let rest = cwd.dropFirst(main.count + 1)
                let name = rest.firstIndex(of: "/").map { String(rest[..<$0]) } ?? String(rest)
                if !name.isEmpty, name == branch?.replacingOccurrences(of: "/", with: "-"),
                   !FileManager.default.fileExists(atPath: main + "." + name) {
                    return true
                }
            }
            return false
        }

        private func isAtOrAbove(_ path: String, _ other: String) -> Bool {
            path == "/" || other == path || other.hasPrefix(path + "/")
        }

        /// A `.git` in a folder below `root`, down to `cwd` included.
        private func hasCheckoutBetween(_ root: String, _ cwd: String) -> Bool {
            var folder = cwd
            while folder.count > root.count {
                if FileManager.default.fileExists(atPath: folder + "/.git") { return true }
                folder = (folder as NSString).deletingLastPathComponent
            }
            return false
        }
    }

    static let maxTranscripts = 1_000
    /// Of a transcript's start, read to find its `cwd`.
    static let maxHeadBytes = 4 * 1024 * 1024

    /// The scope of an agent working in `workingDirectory`, in the space
    /// `spaceID` (nil outside Nirux: its repository only).
    static func scope(
        workingDirectory: String, spaceID: String?, stateDirectory: URL, gitPath: String = "/usr/bin/git"
    ) -> Scope {
        var scope = Scope()
        if let spaceID {
            scope.records = ledgerRecords(spaceID: spaceID, stateDirectory: stateDirectory)
            scope.includesLedgerSessions = spaceID != WorkspaceProfile.defaultID
        }
        let worktrees = worktreePaths(in: workingDirectory, gitPath: gitPath)
        scope.roots = unique(worktrees.filter { $0.hasPrefix("/") }.map(standardized))
        // git lists the main worktree first.
        scope.mainCheckouts = worktrees.first.flatMap { $0.hasPrefix("/") && $0 != "/" ? [standardized($0)] : nil } ?? []
        return scope
    }

    /// The checkouts of the repository at `directory`, the main one first;
    /// none for a bare one, or when git can't say. The server's `GIT_*`
    /// variables don't reach git. Its stdin does (Claude's requests), which
    /// `git worktree list` never reads: giving git a stdin of its own
    /// starts a writer thread, whose closure traps in a release build here.
    static func worktreePaths(in directory: String, gitPath: String) -> [String] {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment.merge(GitDetect.readOnlyEnvironment) { $1 }
        guard let outcome = BoundedProcess.execute(
            executableURL: URL(fileURLWithPath: gitPath), arguments: ["worktree", "list", "--porcelain", "-z"],
            currentDirectoryURL: URL(fileURLWithPath: directory), environment: .replaced(environment), timeout: 5
        ), outcome.terminationStatus == 0, let output = String(bytes: outcome.standardOutput, encoding: .utf8)
        else { return [] }
        var paths: [String] = []
        var path: String?
        var isBare = false
        // One field per NUL, an empty one between worktrees.
        for field in output.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.isEmpty {
                if let path, !isBare { paths.append(path) }
                path = nil
                isBare = false
            } else if field.hasPrefix("worktree ") {
                path = String(field.dropFirst("worktree ".count))
            } else if field == "bare" {
                isBare = true
            }
        }
        if let path, !isBare { paths.append(path) }
        return paths
    }

    /// The space's Claude sessions, from its ledger file. Nothing when the
    /// file can't be read.
    static func ledgerRecords(spaceID: String, stateDirectory: URL) -> [AgentSessionRecord] {
        guard let url = AgentSessionLedger.fileURL(spaceID: spaceID, stateDirectory: stateDirectory),
              let data = readRegularFile(url.path, maxBytes: AgentSessionLedger.maxFileBytes)
        else { return [] }
        return AgentSessionLedger.parse(data).records.values.filter { $0.agent == .claude }
    }

    /// The project's transcripts, the most recently written first, at most
    /// `maxTranscripts`. The heads read to find each one's `cwd` count
    /// against `budget`.
    static func transcripts(
        in scope: Scope, claudeProjects: URL, budget: inout TranscriptSearch.Budget
    ) -> [Transcript] {
        let records = Dictionary(scope.records.map { ($0.sessionID, $0) }) { first, _ in first }
        var bySession: [String: Transcript] = [:]
        if scope.includesLedgerSessions {
            for record in scope.records {
                guard let path = record.transcriptPath, path.hasSuffix(".jsonl"),
                      let modified = regularFileModified(path) else { continue }
                bySession[record.sessionID] = Transcript(
                    path: path, sessionID: record.sessionID, modified: modified, cwd: record.cwd, record: record
                )
            }
        }
        let prefixes = Set((scope.roots + scope.mainCheckouts).map { String(claudeFolderName($0).prefix(200)) })
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: claudeProjects.path)) ?? []
        var candidates: [(path: String, sessionID: String, modified: Date)] = []
        for folder in folders where prefixes.contains(where: { isFolder(folder, filedUnder: $0) }) {
            let directory = claudeProjects.appendingPathComponent(folder).path
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where name.hasSuffix(".jsonl") {
                let sessionID = String(name.dropLast(".jsonl".count))
                let path = directory + "/" + name
                guard bySession[sessionID] == nil, let modified = regularFileModified(path) else { continue }
                candidates.append((path, sessionID, modified))
            }
        }
        candidates.sort { $0.modified != $1.modified ? $0.modified > $1.modified : $0.path < $1.path }
        // A session id in two folders: the most recently written wins.
        for candidate in candidates where bySession[candidate.sessionID] == nil {
            guard bySession.count < maxTranscripts, !budget.isSpent else { break }
            guard let start = sessionStart(ofTranscriptAt: candidate.path, budget: &budget),
                  scope.contains(start.cwd, branch: start.branch)
            else { continue }
            bySession[candidate.sessionID] = Transcript(
                path: candidate.path, sessionID: candidate.sessionID, modified: candidate.modified, cwd: start.cwd,
                record: records[candidate.sessionID]
            )
        }
        let sorted = bySession.values.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.path < $1.path }
        return Array(sorted.prefix(maxTranscripts))
    }

    /// The folder Claude files a session started in `path` under: every
    /// UTF-16 unit but an ASCII letter or digit becomes "-". Past 200
    /// characters Claude cuts the name and adds a hash.
    static func claudeFolderName(_ path: String) -> String {
        String(path.utf16.map { unit -> Character in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: Character(Unicode.Scalar(UInt8(unit)))
            default: "-"
            }
        })
    }

    /// The folder of a checkout (`prefix`), or of a folder inside it or
    /// named after it: each starts with the checkout's name, then a "-".
    private static func isFolder(_ folder: String, filedUnder prefix: String) -> Bool {
        folder == prefix || (folder.hasPrefix(prefix) && folder.dropFirst(prefix.count).first == "-")
    }

    /// The first `cwd` a line of the transcript gives, from its start, with
    /// the branch that line names.
    static func sessionStart(
        ofTranscriptAt path: String, budget: inout TranscriptSearch.Budget
    ) -> (cwd: String, branch: String?)? {
        let marker = Array("\"cwd\":\"".utf8)
        var found: (cwd: String, branch: String?)?
        _ = TranscriptSearch.readLines(
            transcriptAt: path, budget: &budget, isCancelled: { found != nil }, maxBytes: maxHeadBytes,
            chunkSize: 64 * 1024, fromStart: true,
            line: { bytes in
                guard found == nil, TranscriptSearch.contains(bytes, marker), let object = TranscriptSearch.object(bytes),
                      let cwd = object["cwd"] as? String, cwd.hasPrefix("/") else { return }
                found = (cwd, object["gitBranch"] as? String)
            }
        )
        return found
    }

    /// Symbolic links resolved when the folder exists (`/tmp` is
    /// `/private/tmp`, as Claude and git write it); no trailing "/".
    static func standardized(_ path: String) -> String {
        if let real = path.realPath { return real }
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    private static func regularFileModified(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
    }

    /// The file's bytes, if it is a regular file (not a link) of at most
    /// `maxBytes`.
    static func readRegularFile(_ path: String, maxBytes: Int) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) <= maxBytes else { return nil }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, Int(info.st_size)) }
        return count == Int(info.st_size) ? data : nil
    }
}
