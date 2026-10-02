import CryptoKit
import Darwin
import Foundation

// MARK: - Snapshot (section 7)

extension BranchReview {
    struct Options: Sendable {
        var gitPath = "/usr/bin/git"
        /// Nil when gh isn't installed: the page works without the pull
        /// request, and says so.
        var gitHub: GitHubCLI? = .installed()
        /// Refresh fetches the pull request's base branch; opening the page
        /// doesn't.
        var fetchBase = false
        /// Added to every git run's environment.
        var environment: [String: String] = [:]
        var timeout: TimeInterval = 60
        var fetchTimeout: TimeInterval = 30
        /// A file's patch past this gets a placeholder, as the editor's
        /// stacked diff does (`EditorColumn.maxDiffCollectionFileBytes`).
        var maxFileDiffBytes = 400_000
        /// Past this in total, the page lists the files and loads a diff
        /// when its row opens.
        var maxInlineDiffBytes = 5_000_000
        /// Past this in total, the patch isn't read at all: only paths and
        /// line counts, so a vendored tree can't fill the memory.
        var maxDiffBytes = 64 << 20
    }

    /// Reads the branch checked out at `path`, from its merge base with the
    /// base branch to the working tree, untracked files included. Every git
    /// run is read-only (`GitDetect.readOnlyEnvironment`); the only write
    /// is `options.fetchBase`'s fetch of one remote-tracking ref.
    static func snapshot(at path: String, options: Options = Options()) -> Outcome {
        guard let located = git(
            ["rev-parse", "--path-format=absolute", "--show-toplevel", "--show-object-format"]
                + inProgressMarkers.flatMap { ["--git-path", $0.file] },
            in: path, options: options
        ) else { return .unavailable("git couldn't read \(path).") }
        let lines = located.text.split(separator: "\n").map(String.init)
        guard located.status == 0, lines.count == 2 + inProgressMarkers.count else {
            return .unavailable(firstLine(located.stderr) ?? "\(path) isn't in a git repository.")
        }
        let root = lines[0]
        let objectFormat = lines[1]
        for (marker, markerPath) in zip(inProgressMarkers, lines.dropFirst(2))
        where FileManager.default.fileExists(atPath: markerPath) {
            return .paused(marker.operation)
        }

        let symbolicHead = git(["symbolic-ref", "-q", "HEAD"], in: root, options: options)
        guard let headRef = symbolicHead.map({ $0.text.trimmingCharacters(in: .newlines) }),
              symbolicHead?.status == 0, headRef.hasPrefix("refs/heads/")
        else { return .unavailable("HEAD is detached: there is no branch to review.") }
        let branch = String(headRef.dropFirst("refs/heads/".count))
        guard let headRead = git(["rev-parse", "-q", "--verify", "HEAD^{commit}"], in: root, options: options),
              headRead.status == 0
        else { return .unavailable("\(branch) has no commits yet.") }
        let head = headRead.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // `git status` compares contents without writing the index under
        // GIT_OPTIONAL_LOCKS=0, so a touched file isn't "not committed".
        guard let status = git(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames"], in: root, options: options
        ), status.status == 0 else {
            return .unavailable("git status failed in \(root).")
        }
        let statusEntries = WorktreeCleanup.statusEntries(status.text)
        if statusEntries.contains(where: { isUnmerged($0.code) }) { return .paused(.conflicts) }
        let untracked = statusEntries
            .filter { $0.code == "??" && !$0.path.hasSuffix("/") && !isDisposable($0.path) }
            .map(\.path)
        let uncommitted = Set(statusEntries.filter { $0.code != "??" }.map(\.path))

        let selection = selectBase(root: root, branch: branch, options: options)
        guard let base = selection.base else {
            return .unavailable("No base branch shares history with \(branch) (tried origin/HEAD, main and master).")
        }
        guard let commits = commits(since: base.mergeBase, root: root, options: options) else {
            return .unavailable("git log failed in \(root).")
        }

        var diff = readDiff(root: root, mergeBase: base.mergeBase, pathspec: [], options: options)
        if case .inconsistent = diff {
            diff = readDiff(root: root, mergeBase: base.mergeBase, pathspec: [], options: options)
        }
        var files: [FileChange]
        var diffBytes: Int?
        switch diff {
        case .files(let parsed, let bytes):
            files = parsed
            diffBytes = bytes
        case .notRead:
            guard let listed = listOnly(root: root, mergeBase: base.mergeBase, options: options) else {
                return .unavailable("git couldn't list the changes of \(branch).")
            }
            files = listed
            diffBytes = nil
        case .inconsistent:
            return .unavailable("The worktree changed while it was read. Refresh again.")
        case .failed(let reason):
            return .unavailable(reason)
        }
        files.removeAll { isDisposable($0.path) }
        for index in files.indices {
            files[index].isUncommitted = uncommitted.contains(files[index].path)
                || files[index].oldPath.map(uncommitted.contains) == true
        }

        for path in untracked {
            let readLimit = diffBytes.map { max(0, options.maxDiffBytes - $0) } ?? 0
            guard let (file, bytes) = untrackedFile(
                path, root: root, objectFormat: objectFormat, readLimit: readLimit, options: options
            ) else { continue }
            files.append(file)
            diffBytes = diffBytes.map { $0 + bytes }
        }
        if diffBytes ?? 0 > options.maxInlineDiffBytes {
            for index in files.indices where files[index].omission == nil {
                files[index].hunks = []
                files[index].omission = .onDemand
            }
        }
        files.sort { $0.path < $1.path }

        return .snapshot(Snapshot(
            root: root, objectFormat: objectFormat, branch: branch, head: head, base: base,
            pullRequest: selection.pullRequest, fetchProblem: selection.fetchProblem,
            commits: commits, files: files, diffBytes: diffBytes
        ))
    }

    /// `snapshot(at:options:)` on a background queue; `completion` runs on
    /// the main actor.
    static func loadSnapshot(
        at path: String,
        options: Options = Options(),
        completion: @escaping @MainActor @Sendable (Outcome) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = snapshot(at: path, options: options)
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// One file's diff, for a row opened when the snapshot left it out
    /// (`.onDemand`, `.notRead`), read again from the worktree. Its hash may
    /// differ from the snapshot's: the worktree moves. Nil when the file
    /// no longer differs from the base, or git fails.
    static func filePatch(_ file: FileChange, in snapshot: Snapshot, options: Options = Options()) -> FileChange? {
        if file.isUntracked {
            return untrackedFile(
                file.path, root: snapshot.root, objectFormat: snapshot.objectFormat,
                readLimit: options.maxDiffBytes, options: options
            )?.file
        }
        var literal = options
        literal.environment["GIT_LITERAL_PATHSPECS"] = "1"
        let pathspec = [file.oldPath, file.path].compactMap { $0 }
        guard case .files(let files, _) = readDiff(
            root: snapshot.root, mergeBase: snapshot.base.mergeBase, pathspec: pathspec, options: literal
        ), var found = files.first(where: { $0.path == file.path })
        else { return nil }
        found.isUncommitted = file.isUncommitted
        return found
    }

    // MARK: Reading the diff

    /// `git diff` refreshes, and rewrites, the index even under
    /// GIT_OPTIONAL_LOCKS=0, which fires the worktree's watcher; the other
    /// settings and options keep the user's git config from changing the
    /// patch or its hash.
    static let diffConfig = [
        "-c", "diff.autoRefreshIndex=false", "-c", "core.quotePath=false", "-c", "diff.suppressBlankEmpty=false"
    ]
    static let diffOptions = [
        "--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/",
        "-M", "-l1000", "-U3", "--inter-hunk-context=0", "--diff-algorithm=myers", "--indent-heuristic",
        "--submodule=short", "--no-relative", "--full-index"
    ]

    enum DiffRead {
        case files([FileChange], bytes: Int)
        /// Over `maxDiffBytes`, or git didn't finish in time.
        case notRead
        /// The patch and the name-status list disagree: the worktree
        /// changed between the two reads.
        case inconsistent
        case failed(String)
    }

    /// The patch from `mergeBase` to the working tree, matched with the
    /// paths of `--name-status -z`, each file hashed.
    static func readDiff(root: String, mergeBase: String, pathspec: [String], options: Options) -> DiffRead {
        let command = diffConfig + ["diff"] + diffOptions
        guard let names = git(command + ["--name-status", "-z", mergeBase, "--"] + pathspec, in: root, options: options),
              names.status == 0, let entries = Patch.nameStatus(names.stdout)
        else { return .failed("git couldn't list the changes in \(root).") }
        guard let patch = git(
            command + [mergeBase, "--"] + pathspec, in: root, options: options, maxOutputBytes: options.maxDiffBytes
        ) else { return .notRead }
        guard patch.status == 0, let sections = Patch.sections(of: patch.stdout) else {
            return .failed("git printed a diff Nirux can't read in \(root).")
        }
        guard var files = Patch.files(entries: entries, sections: sections) else { return .inconsistent }
        let bytesByPath = Dictionary(sections.compactMap { section in section.key.map { ($0, section.byteCount) } }) { $0 + $1 }
        for index in files.indices {
            files[index].patchHash = patchHash(of: files[index])
            if let bytes = bytesByPath[files[index].path], bytes > options.maxFileDiffBytes {
                files[index].hunks = []
                files[index].omission = .tooLarge(bytes: bytes)
            }
        }
        return .files(files, bytes: patch.stdout.count)
    }

    /// Paths and line counts only, for a diff too large to read: no hunks,
    /// no hash. A modified text file with no line changed is left out, as
    /// the patch would leave out a file whose timestamp alone changed; a
    /// mode change on its own goes with it.
    static func listOnly(root: String, mergeBase: String, options: Options) -> [FileChange]? {
        let command = diffConfig + ["diff"] + diffOptions
        guard let names = git(command + ["--name-status", "-z", mergeBase, "--"], in: root, options: options),
              names.status == 0, let entries = Patch.nameStatus(names.stdout),
              let numbers = git(command + ["--numstat", "-z", mergeBase, "--"], in: root, options: options),
              numbers.status == 0
        else { return nil }
        let counts = numstat(numbers.stdout)
        return entries.compactMap { entry -> FileChange? in
            let count = counts[entry.path]
            if entry.letter == "M", let count, count.additions == 0, count.deletions == 0 { return nil }
            var file = FileChange(path: entry.path, status: .modified)
            switch entry.letter {
            case "A", "C": file.status = .added
            case "D": file.status = .deleted
            case "R":
                file.status = .renamed
                file.oldPath = entry.oldPath
                file.similarity = entry.score
            case "T": file.status = .typeChanged
            default: break
            }
            file.isBinary = count == nil
            file.additions = count?.additions ?? 0
            file.deletions = count?.deletions ?? 0
            file.omission = .notRead
            return file
        }
    }

    /// `git diff --numstat -z`: added and deleted lines by path (the new
    /// path for a rename). Binary files, counted "-", are left out.
    static func numstat(_ data: Data) -> [String: (additions: Int, deletions: Int)] {
        var counts: [String: (additions: Int, deletions: Int)] = [:]
        var fields = data.split(separator: 0, omittingEmptySubsequences: false)[...]
        while let field = fields.popFirst(), !field.isEmpty {
            let parts = String(decoding: field, as: UTF8.self).split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            var path = String(parts[2])
            if path.isEmpty {
                // A rename: the old and new paths follow, NUL-terminated.
                _ = fields.popFirst()
                path = fields.popFirst().map { String(decoding: $0, as: UTF8.self) } ?? ""
            }
            if let additions = Int(parts[0]), let deletions = Int(parts[1]) {
                counts[path] = (additions, deletions)
            }
        }
        return counts
    }

    // MARK: Untracked files

    /// An untracked file read from disk as git would show it once added:
    /// the same lines, mode and binary rule, so its hash doesn't change
    /// when the agent commits it. Nil for anything but a regular file or a
    /// symlink. Past `readLimit`, it is listed without being read.
    static func untrackedFile(
        _ path: String, root: String, objectFormat: String, readLimit: Int, options: Options
    ) -> (file: FileChange, bytes: Int)? {
        let fullPath = root + "/" + path
        var info = stat()
        guard lstat(fullPath, &info) == 0 else { return nil }
        var file = FileChange(path: path, status: .added)
        file.isUntracked = true
        file.isUncommitted = true
        let content: Data
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            file.newMode = "120000"
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = readlink(fullPath, &buffer, buffer.count - 1)
            guard length >= 0 else { return nil }
            content = Data(buffer[..<length].map { UInt8(bitPattern: $0) })
        case S_IFREG:
            file.newMode = info.st_mode & S_IXUSR != 0 ? "100755" : "100644"
            guard Int(info.st_size) <= readLimit else {
                file.omission = .notRead
                return (file, Int(info.st_size))
            }
            switch BoardConfigStore.read(URL(fileURLWithPath: fullPath), maxBytes: readLimit) {
            case .data(let data):
                content = data
            case .tooLarge:
                file.omission = .notRead
                return (file, Int(info.st_size))
            case .missing, .notARegularFile, .unreadableBytes:
                return nil
            }
        default:
            return nil
        }
        // git's rule: a NUL in the first 8,000 bytes. A link's target is text.
        if file.newMode != "120000", content.prefix(8000).contains(0) {
            file.isBinary = true
            file.newObjectID = objectID(ofBlob: content, objectFormat: objectFormat)
        } else if !content.isEmpty {
            var lines = Patch.lines(content).map { Line(kind: .added, text: String($0)) }
            if content.last == UInt8(ascii: "\n") {
                lines.removeLast()
            } else {
                lines.append(Line(kind: .noNewlineMarker, text: ""))
            }
            let count = lines.count(where: { $0.kind == .added })
            file.hunks = [Hunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: count, section: "", lines: lines)]
        }
        Patch.countLines(&file)
        file.patchHash = patchHash(of: file)
        if content.count > options.maxFileDiffBytes {
            file.hunks = []
            file.omission = .tooLarge(bytes: content.count)
        }
        return (file, content.count)
    }

    /// The id git gives `content` as a blob, as the `index` line shows it.
    static func objectID(ofBlob content: Data, objectFormat: String) -> String {
        let header = Data("blob \(content.count)\0".utf8)
        if objectFormat == "sha256" {
            var hasher = SHA256()
            hasher.update(data: header)
            hasher.update(data: content)
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        var hasher = Insecure.SHA1()
        hasher.update(data: header)
        hasher.update(data: content)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Commits

    /// The commits from `mergeBase` to HEAD, newest first, at most 1,000.
    static func commits(since mergeBase: String, root: String, options: Options) -> [Commit]? {
        guard let log = git(
            ["log", "-z", "--no-show-signature", "--encoding=UTF-8", "--max-count=1000",
             "--format=%H %P%n%B", "\(mergeBase)..HEAD", "--"],
            in: root, options: options
        ), log.status == 0 else { return nil }
        let records = log.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        let parsed = records.compactMap { record -> (ids: [String], message: String)? in
            let parts = record.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let ids = parts.first?.split(separator: " ").map(String.init) ?? []
            guard !ids.isEmpty else { return nil }
            return (ids, parts.count > 1 ? String(parts[1]) : "")
        }
        let inRange = Set(parsed.map { $0.ids[0] })
        return parsed.map { ids, message in
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let split = trimmed.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            let parents = Array(ids.dropFirst())
            return Commit(
                oid: ids[0],
                parents: parents,
                subject: split.first.map(String.init) ?? "",
                body: split.count > 1 ? split[1].trimmingCharacters(in: .whitespacesAndNewlines) : "",
                isMergeFromBase: parents.count > 1 && parents.dropFirst().contains { !inRange.contains($0) }
            )
        }
    }

    // MARK: Helpers

    /// What `git rev-parse --git-path` names while an operation is under way.
    private static let inProgressMarkers: [(file: String, operation: Operation)] = [
        ("rebase-merge", .rebase), ("rebase-apply", .rebase), ("MERGE_HEAD", .merge),
        ("CHERRY_PICK_HEAD", .cherryPick), ("REVERT_HEAD", .revert)
    ]

    /// `git status` codes of an unmerged path: DD, AU, UD, UA, DU, AA, UU.
    static func isUnmerged(_ code: String) -> Bool {
        code.contains("U") || code == "AA" || code == "DD"
    }

    /// The handovers and Claude Code's local settings: Clean Up already
    /// treats them as disposable, and the review leaves them out.
    static func isDisposable(_ path: String) -> Bool {
        WorktreeCleanup.disposablePaths.contains(path)
    }

    struct GitOutput {
        let status: Int32
        let stdout: Data
        let stderr: String

        /// Standard output, decoded lossily.
        var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    static func git(
        _ arguments: [String],
        in directory: String,
        options: Options,
        environment: [String: String] = [:],
        timeout: TimeInterval? = nil,
        maxOutputBytes: Int? = nil
    ) -> GitOutput? {
        guard let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: options.gitPath),
            arguments: arguments,
            currentDirectoryURL: URL(fileURLWithPath: directory),
            environment: GitDetect.readOnlyEnvironment
                .merging(options.environment) { _, override in override }
                .merging(environment) { _, override in override },
            timeout: timeout ?? options.timeout,
            captureStandardError: true,
            maxStandardOutputBytes: maxOutputBytes
        ) else { return nil }
        return GitOutput(
            status: result.terminationStatus,
            stdout: result.standardOutput,
            stderr: String(decoding: result.standardError, as: UTF8.self)
        )
    }

    static func firstLine(_ text: String) -> String? {
        WorktreeCleanup.firstLine(text)
    }
}
