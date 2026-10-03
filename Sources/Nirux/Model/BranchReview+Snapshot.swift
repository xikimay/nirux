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
        /// An earlier snapshot's pull request (`Snapshot.knownPullRequest`),
        /// used as is instead of asking gh again while the worktree is on
        /// the same branch: for a refresh the worktree's watcher triggers,
        /// since the page never polls gh. The merge base is still read
        /// again.
        var knownPullRequest: KnownPullRequest?
        /// Added to every git run's environment.
        var environment: [String: String] = [:]
        var timeout: TimeInterval = 60
        var fetchTimeout: TimeInterval = 30
        /// A file's patch past this gets a placeholder, as the editor's
        /// stacked diff does (`EditorColumn.maxDiffCollectionFileBytes`).
        var maxFileDiffBytes = 400_000
        /// Past this for the files that keep their hunks, the page lists
        /// the files and loads a diff when its row opens.
        var maxInlineDiffBytes = 5_000_000
        /// Past this in total, the patch isn't read whole: the files with
        /// the most changed lines are left out, or, failing that, only
        /// paths and line counts are read.
        var maxDiffBytes = 64 << 20
        /// Untracked files past this many are listed without being read: a
        /// folder nobody ignored (node_modules) can hold tens of thousands.
        var maxUntrackedFilesRead = 1_000
    }

    /// Reads the branch checked out at `path`, from its merge base with the
    /// base branch to the working tree, untracked files included. Every git
    /// run is read-only; the only write is `options.fetchBase`'s fetch of
    /// one remote-tracking ref. The pull request and the base are settled
    /// first (gh and the fetch take a while); HEAD, the commits, the status
    /// and the diff are then read back to back, and again if HEAD moved
    /// meanwhile. If the worktree switched branch or started a rebase while
    /// gh answered, it starts over once.
    static func snapshot(at path: String, options: Options = Options()) -> Outcome {
        snapshot(at: path, options: options, restarts: 1)
    }

    private static func snapshot(at path: String, options: Options, restarts: Int) -> Outcome {
        guard let located = git(
            ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-path", "index", "--git-path", "objects"]
                + inProgressMarkers.flatMap { ["--git-path", $0.file] },
            in: path, options: options
        ) else { return .unavailable("git couldn't read \(path).") }
        let lines = located.text.split(separator: "\n").map(String.init)
        guard located.status == 0, lines.count == 3 + inProgressMarkers.count else {
            return .unavailable(firstLine(located.stderr) ?? "\(path) isn't in a git repository.")
        }
        let repository = Repository(root: lines[0], index: lines[1], objects: lines[2])
        let markers = zip(inProgressMarkers.map(\.operation), lines.dropFirst(3)).map { ($0, $1) }
        if let operation = operationInProgress(markers) { return .paused(operation) }

        let symbolicHead = git(["symbolic-ref", "-q", "HEAD"], in: repository.root, options: options)
        guard let headRef = symbolicHead.map({ $0.text.trimmingCharacters(in: .newlines) }),
              symbolicHead?.status == 0, headRef.hasPrefix("refs/heads/")
        else { return .unavailable("HEAD is detached: there is no branch to review.") }
        let branch = String(headRef.dropFirst("refs/heads/".count))
        guard git(["rev-parse", "-q", "--verify", "HEAD^{commit}"], in: repository.root, options: options)?.status == 0
        else { return .unavailable("\(branch) has no commits yet.") }

        let selection = selectBase(root: repository.root, branch: branch, options: options)
        guard let base = selection.base else {
            return .unavailable("No base branch shares history with \(branch) (tried origin/HEAD, main and master).")
        }
        let place = Place(repository: repository, headRef: headRef, branch: branch, markers: markers)
        for attempt in 1...2 {
            switch read(place, base: base, selection: selection, isLastAttempt: attempt == 2, options: options) {
            case .done(let outcome): return outcome
            case .moved: continue
            case .switched:
                guard restarts > 0 else { break }
                return snapshot(at: path, options: options, restarts: restarts - 1)
            }
        }
        return .unavailable("\(branch) kept moving while it was read. Refresh again.")
    }

    /// Where a snapshot reads: the worktree, its branch, and the files that
    /// say an operation is under way.
    private struct Place {
        let repository: Repository
        let headRef: String
        let branch: String
        let markers: [(Operation, String)]
    }

    private static func operationInProgress(_ markers: [(Operation, String)]) -> Operation? {
        markers.first { FileManager.default.fileExists(atPath: $0.1) }?.0
    }

    struct Repository: Equatable, Sendable {
        /// The worktree's top level.
        let root: String
        /// Its index and object folder, for the temporary index that
        /// untracked files are added to.
        let index: String
        let objects: String
    }

    private enum Read {
        case done(Outcome)
        /// HEAD moved, or a file vanished, while it was read.
        case moved
        /// The worktree is on another branch, or an operation started.
        case switched
    }

    private static func read(
        _ place: Place, base selected: BaseBranch, selection: BaseSelection, isLastAttempt: Bool, options: Options
    ) -> Read {
        let (repository, branch) = (place.repository, place.branch)
        let root = repository.root
        func isStillInPlace() -> Bool {
            git(["symbolic-ref", "-q", "HEAD"], in: root, options: options)?.text
                .trimmingCharacters(in: .newlines) == place.headRef && operationInProgress(place.markers) == nil
        }
        guard isStillInPlace() else { return .switched }
        guard let headRead = git(["rev-parse", "-q", "--verify", "HEAD^{commit}"], in: root, options: options),
              headRead.status == 0
        else { return .done(.unavailable("\(branch) has no commits yet.")) }
        let head = headRead.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mergeBaseRead = git(["merge-base", head, selected.ref], in: root, options: options),
              mergeBaseRead.status == 0
        else { return .done(.unavailable("\(branch) no longer shares history with \(selected.name).")) }
        let base = Base(
            name: selected.name, ref: selected.ref,
            mergeBase: mergeBaseRead.text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard let commits = commits(since: base.mergeBase, head: head, root: root, options: options) else {
            return .done(.unavailable("git log failed in \(root)."))
        }

        // `git status` compares contents without writing the index under
        // GIT_OPTIONAL_LOCKS=0, so a touched file isn't "not committed".
        guard let status = git(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames"], in: root, options: options
        ), status.status == 0 else {
            return .done(.unavailable("git status failed in \(root)."))
        }
        let statusEntries = statusEntries(status.stdout)
        if statusEntries.contains(where: { isUnmerged($0.code) }) { return .done(.paused(.conflicts)) }
        // Untracked handovers and local settings are Clean Up's disposable
        // files; committed ones are a mistake the review must show.
        let untracked = statusEntries
            .filter { $0.code == "??" && !$0.path.hasSuffix("/") && !isDisposable($0.path) }
            .map(\.path)
        let uncommitted = Set(statusEntries.filter { $0.code != "??" }.map(\.path))
        // After `git rm --cached`, a file is both deleted in the index and
        // untracked. One the base has: the commit will delete it, so it
        // stays out of the temporary index and reads as deleted. One the
        // branch added reads as added, like any untracked file.
        let stagedDeletions = Set(statusEntries.filter { $0.code.hasPrefix("D") }.map(\.path))
        let deletedFromBase = untracked.contains(where: stagedDeletions.contains)
            ? deletedFromIndex(since: base.mergeBase, root: root, options: options) : []

        let toRead = Array(readingOrder(untracked.filter { !deletedFromBase.contains($0) }).prefix(options.maxUntrackedFilesRead))
        var files: [FileChange]
        switch readChanges(
            repository, mergeBase: base.mergeBase, head: head, untracked: toRead, uncommitted: uncommitted,
            ignoresAttributes: untracked.contains(where: changesAttributes), canRetry: !isLastAttempt, options: options
        ) {
        case .read(let read): files = read
        case .vanished: return .moved
        case .failed(let reason): return .done(.unavailable(reason))
        }
        let readUntracked = Set(toRead)
        for index in files.indices {
            files[index].isUntracked = readUntracked.contains(files[index].path)
            files[index].isUncommitted = files[index].isUntracked || uncommitted.contains(files[index].path)
                || files[index].oldPath.map(uncommitted.contains) == true
        }
        // Past the read limit, or when the temporary index couldn't be
        // made: listed by name. A path the diff already has (an agent's
        // `git add` landed meanwhile) isn't listed twice.
        let listed = Set(files.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) })
        let unread = untracked.filter { !listed.contains($0) }
        let noise = unread.isEmpty ? nil : NoiseRules(
            root: root, paths: unread,
            ignoresAttributes: listed.contains(where: changesAttributes) || unread.contains(where: changesAttributes),
            options: options
        )
        for path in unread {
            var file = FileChange(path: path, status: .added)
            file.isUntracked = true
            file.isUncommitted = true
            file.omission = .notRead
            file.fold = noise?.fold(path: path)
            RiskRules.settle(&file)
            file.symbols = unreadSymbols(of: file)
            files.append(file)
        }
        addWorkflowSignals(to: &files, root: root)
        files.sort { $0.path < $1.path }
        let testsAgainstCode = testsAgainstCode(of: files, root: root, options: options)

        guard isStillInPlace() else { return .switched }
        guard git(["rev-parse", "-q", "--verify", "HEAD^{commit}"], in: root, options: options)?
            .text.trimmingCharacters(in: .whitespacesAndNewlines) == head
        else { return .moved }
        return .done(.snapshot(Snapshot(
            root: root, branch: branch, head: head, base: base,
            pullRequest: selection.pullRequest, fetchProblem: selection.fetchProblem,
            upstream: compare(head: head, with: "\(branch)@{upstream}", root: root, options: options),
            pullRequestHead: selection.pullRequest.pullRequest.flatMap {
                comparePullRequestHead($0, head: head, root: root, options: options)
            },
            hasUncommittedChanges: !uncommitted.isEmpty || !untracked.isEmpty,
            commits: commits, files: files, testsAgainstCode: testsAgainstCode
        )))
    }

    /// The paths `tree` has and the index doesn't: what a commit would
    /// delete. Listed by git rather than asked about one by one: a
    /// `git rm -r --cached .` leaves thousands of them.
    private static func deletedFromIndex(since tree: String, root: String, options: Options) -> Set<String> {
        guard let listed = git(
            diffConfig + ["diff", "--cached", "--name-only", "-z", "--no-renames", "--diff-filter=D", tree, "--"],
            in: root, options: options, maxOutputBytes: options.maxDiffBytes
        ), listed.status == 0
        else { return [] }
        return Set(listed.stdout.split(separator: 0).map(Patch.decoded))
    }

    /// Untracked files in the order they are read: those of the least
    /// crowded top-level folders first, so that a folder nobody ignored
    /// (node_modules) doesn't use up the read limit before the files an
    /// agent wrote.
    static func readingOrder(_ paths: [String]) -> [String] {
        func folder(_ path: String) -> Substring { path.split(separator: "/", maxSplits: 1).first ?? Substring(path) }
        let crowd = Dictionary(paths.map { (folder($0), 1) }, uniquingKeysWith: +)
        return paths.enumerated()
            .sorted { (crowd[folder($0.element)] ?? 0, $0.offset) < (crowd[folder($1.element)] ?? 0, $1.offset) }
            .map(\.element)
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
        guard let located = git(
            ["rev-parse", "--path-format=absolute", "--git-path", "index", "--git-path", "objects"],
            in: snapshot.root, options: options
        ), located.status == 0 else { return nil }
        let paths = located.text.split(separator: "\n").map(String.init)
        guard paths.count == 2 else { return nil }
        var literal = options
        literal.environment["GIT_LITERAL_PATHSPECS"] = "1"
        guard case .read(let files) = readChanges(
            Repository(root: snapshot.root, index: paths[0], objects: paths[1]),
            mergeBase: snapshot.base.mergeBase, head: snapshot.head,
            untracked: file.isUntracked ? [file.path] : [],
            uncommitted: file.isUncommitted ? Set([file.oldPath, file.path].compactMap { $0 }) : [],
            pathspec: [file.oldPath, file.path].compactMap { $0 }, inline: false,
            ignoresAttributes: snapshot.files.contains { changesAttributes($0.path) || $0.oldPath.map(changesAttributes) == true },
            canRetry: false, options: literal
        ), var found = files.first(where: { $0.path == file.path })
        else { return nil }
        found.isUntracked = file.isUntracked
        found.isUncommitted = file.isUncommitted
        var loaded = [found]
        addWorkflowSignals(to: &loaded, root: snapshot.root)
        return loaded[0]
    }

    // MARK: Reading the diff

    /// `git diff` refreshes, and rewrites, the index even under
    /// GIT_OPTIONAL_LOCKS=0, which fires the worktree's watcher; the other
    /// settings keep the user's git config from changing the output.
    static let diffConfig = [
        "-c", "diff.autoRefreshIndex=false", "-c", "core.quotePath=false", "-c", "diff.suppressBlankEmpty=false"
    ]
    /// What decides which files differ, and how: for every listing.
    static let diffSelection = [
        "--no-color", "--no-ext-diff", "--no-textconv", "-M", "-l1000", "--diff-algorithm=myers",
        "--indent-heuristic", "--submodule=short", "--no-relative"
    ]
    /// The patch's own format. Not for --numstat: -U3 adds the whole patch
    /// to its output.
    static let patchFormat = ["--src-prefix=a/", "--dst-prefix=b/", "-U3", "--inter-hunk-context=0", "--full-index"]

    enum Changes {
        case read([FileChange])
        /// An untracked file vanished before it could be added to the
        /// temporary index, or the worktree changed between two reads:
        /// read again.
        case vanished
        case failed(String)
    }

    /// The changes from `mergeBase` to the working tree. Untracked files go
    /// through git too: `add -N` into a copy of the index, with its own
    /// object folder, so they read exactly as git will show them once
    /// committed (attributes, line endings, modes, a moved file paired as
    /// a rename) and nothing is written to the repository.
    static func readChanges(
        _ repository: Repository, mergeBase: String, head: String, untracked: [String], uncommitted: Set<String>,
        pathspec: [String] = [], inline: Bool = true, ignoresAttributes: Bool = false, canRetry: Bool, options: Options
    ) -> Changes {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-review-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var reading = options
        if !untracked.isEmpty {
            switch intentToAdd(untracked, in: repository, scratch: scratch, options: options) {
            case .success(let environment): reading.environment.merge(environment) { _, added in added }
            case .failure(.vanished): if canRetry { return .vanished }
            case .failure(.failed): break
            }
        }
        let root = repository.root
        switch readDiff(
            root: root, mergeBase: mergeBase, pathspec: pathspec, inline: inline, ignoresAttributes: ignoresAttributes,
            options: reading
        ) {
        case .files(let files): return .read(files)
        case .inconsistent:
            if canRetry { return .vanished }
            return .failed("The worktree changed while it was read. Refresh again.")
        case .failed(let reason):
            // The temporary index may be what git trips on: read without
            // it; the untracked files are then listed by name.
            guard reading.environment != options.environment else { return .failed(reason) }
            return readChanges(
                repository, mergeBase: mergeBase, head: head, untracked: [], uncommitted: uncommitted,
                pathspec: pathspec, inline: inline, ignoresAttributes: ignoresAttributes, canRetry: canRetry, options: options
            )
        case .notRead(let entries):
            return readTooLarge(
                entries, root: root, mergeBase: mergeBase, head: head, pathspec: pathspec,
                uncommitted: uncommitted, inline: inline, ignoresAttributes: ignoresAttributes, options: reading
            )
        }
    }

    /// Bytes a changed line takes in a patch, roughly: it tells which files
    /// a placeholder would replace anyway.
    private static let bytesPerChangedLine = 40

    /// Exclusions go on git's command line, which `BoundedProcess` keeps
    /// under 4,096 arguments.
    private static let maxExcludedPaths = 2_000

    /// A diff too large to read whole: the files with the most changed
    /// lines are left out, more at each try (those past the per-file limit
    /// all go at the first), and the rest is read. Failing that, paths and
    /// line counts only.
    private static func readTooLarge(
        _ entries: [NameStatusEntry], root: String, mergeBase: String, head: String, pathspec: [String],
        uncommitted: Set<String>, inline: Bool, ignoresAttributes: Bool, options: Options
    ) -> Changes {
        guard let listed = listOnly(
            entries, root: root, mergeBase: mergeBase, head: head, pathspec: pathspec,
            uncommitted: uncommitted, ignoresAttributes: ignoresAttributes, options: options
        ) else { return .failed("git couldn't count the changes in \(root).") }
        // The others are read without the largest, which may be a
        // .gitattributes.
        let ignoresAttributes = ignoresAttributes
            || listed.contains { changesAttributes($0.path) || $0.oldPath.map(changesAttributes) == true }
        guard pathspec.isEmpty else { return .read(listed) }
        let largestFirst = listed.sorted { $0.additions + $0.deletions > $1.additions + $1.deletions }
        var leftOut = max(1, listed.count { $0.additions + $0.deletions > options.maxFileDiffBytes / bytesPerChangedLine })
        // A diff that timed out reads as too large too: the tries share one
        // timeout.
        let deadline = ProcessInfo.processInfo.systemUptime + options.timeout
        for _ in 0..<4 where leftOut < largestFirst.count && ProcessInfo.processInfo.systemUptime < deadline {
            let giant = Array(largestFirst.prefix(leftOut))
            // Exclusions alone stand for "everything else".
            let excluded = giant.flatMap { [$0.oldPath, $0.path].compactMap { $0 } }.map { ":(exclude,literal,top)\($0)" }
            guard excluded.count <= maxExcludedPaths else { break }
            switch readDiff(
                root: root, mergeBase: mergeBase, pathspec: excluded, inline: inline, ignoresAttributes: ignoresAttributes,
                options: options
            ) {
            case .files(let rest): return .read(rest + giant)
            case .notRead: leftOut *= 2
            case .inconsistent, .failed: return .read(listed)
            }
        }
        return .read(listed)
    }

    private enum IntentFailure: Error {
        case vanished
        case failed
    }

    /// Adds `paths` as intent-to-add to a copy of the index in `scratch`,
    /// whose objects go to `scratch` too; returns the environment that
    /// points git at them. The real object folder is an alternate through
    /// `info/alternates`: `GIT_ALTERNATE_OBJECT_DIRECTORIES` is split on
    /// ":", which a folder name may hold. Hooks don't run (writing an
    /// index fires `post-index-change`), and `--sparse` lets a sparse
    /// checkout add a path outside its cone.
    private static func intentToAdd(
        _ paths: [String], in repository: Repository, scratch: URL, options: Options
    ) -> Result<[String: String], IntentFailure> {
        let fileManager = FileManager.default
        let index = scratch.appendingPathComponent("index")
        let objects = scratch.appendingPathComponent("objects", isDirectory: true)
        let pathList = scratch.appendingPathComponent("paths")
        // A path gone since `git status` would fail the whole `add`.
        func allPresent() -> Bool {
            paths.allSatisfy { path in
                var info = stat()
                return lstat(repository.root + "/" + path, &info) == 0
            }
        }
        guard allPresent() else { return .failure(.vanished) }
        do {
            try fileManager.createDirectory(at: objects.appendingPathComponent("info"), withIntermediateDirectories: true)
            try Data((repository.objects + "\n").utf8).write(to: objects.appendingPathComponent("info/alternates"))
            try fileManager.copyItem(at: URL(fileURLWithPath: repository.index), to: index)
            var list = Data()
            for path in paths {
                list.append(Data(path.utf8))
                list.append(0)
            }
            try list.write(to: pathList)
        } catch {
            return .failure(.failed)
        }
        let environment = ["GIT_INDEX_FILE": index.path, "GIT_OBJECT_DIRECTORY": objects.path]
        guard let added = git(
            ["-c", "core.hooksPath=/dev/null", "-c", "core.splitIndex=false", "add", "-N", "--sparse",
             "--pathspec-from-file=\(pathList.path)", "--pathspec-file-nul"],
            in: repository.root, options: options,
            environment: environment.merging(["GIT_LITERAL_PATHSPECS": "1"]) { _, added in added }
        ) else { return .failure(.failed) }
        guard added.status == 0 else { return .failure(allPresent() ? .failed : .vanished) }
        return .success(environment)
    }

    enum DiffRead {
        case files([FileChange])
        /// The patch is over `maxDiffBytes`, or git didn't finish it in
        /// time: only the name-status list was read.
        case notRead([NameStatusEntry])
        /// The patch and the name-status list disagree: the worktree
        /// changed between the two reads.
        case inconsistent
        case failed(String)
    }

    /// The patch from `mergeBase` to the working tree, matched with the
    /// paths of `--name-status -z`, each file hashed, folded or not, with
    /// its signals. A file past `maxFileDiffBytes` keeps no hunks; with
    /// `inline`, neither does a folded file, nor any file when the
    /// unfolded ones add up to more than `maxInlineDiffBytes`. Parsed
    /// twice: once without keeping a line, to hash, fold, find signals and
    /// collect a Swift file's added lines, then only the sections that
    /// keep their hunks: a fold found in the lines (whitespace only)
    /// mustn't count toward the budget either. `ignoresAttributes`: see
    /// `NoiseRules`.
    static func readDiff(
        root: String, mergeBase: String, pathspec: [String], inline: Bool, ignoresAttributes: Bool = false,
        options: Options
    ) -> DiffRead {
        let diff = diffConfig + ["diff"] + diffSelection
        let names = git(
            diff + ["--name-status", "-z", mergeBase, "--"] + pathspec,
            in: root, options: options, maxOutputBytes: options.maxDiffBytes
        )
        guard let names, names.status == 0, let entries = Patch.nameStatus(names.stdout)
        else { return .failed(failure("git couldn't list the changes in \(root)", names)) }
        guard let patch = git(
            diff + patchFormat + [mergeBase, "--"] + pathspec,
            in: root, options: options, maxOutputBytes: options.maxDiffBytes
        ) else { return .notRead(entries) }
        guard patch.status == 0 else { return .failed(failure("git diff failed in \(root)", patch)) }
        let maxFileBytes = options.maxFileDiffBytes
        let data = patch.stdout
        let ranges = Patch.sectionRanges(of: data)
        let headers = ranges.map { Patch.header(data[$0]) }
        // What the patch has: --name-status also lists a file whose
        // timestamp alone changed.
        let changed = headers.flatMap { [$0?.oldPath, $0?.newPath].compactMap { $0 } }
        let noise = NoiseRules(
            root: root, paths: paths(of: entries),
            ignoresAttributes: ignoresAttributes || changed.contains(where: changesAttributes), options: options
        )
        // A deleted file's start is in its patch; the others' in the
        // worktree.
        var namedFolds: [String: Fold] = [:]
        var rangesByKey: [String: [Range<Data.Index>]] = [:]
        for (range, header) in zip(ranges, headers) {
            guard let header, let key = header.key else { continue }
            rangesByKey[key, default: []].append(range)
            guard namedFolds[key] == nil else { continue }
            namedFolds[key] = noise.fold(path: key) {
                header.newPath == nil
                    ? Patch.deletedFileStart(data[range]) : readPrefix(of: root + "/" + key, maxBytes: 2_048)
            }
        }
        guard let sections = Patch.sections(of: data, in: ranges, reading: { index in
            let key = headers[index]?.key
            let folded = key.flatMap { namedFolds[$0] } != nil
            return Patch.Reading(
                keepsLines: false,
                whitespace: folded ? nil : key.map(WhitespaceCheck.mode(for:)),
                findsRisks: !folded && key.map { PathGroup(path: $0) } != .docs,
                collectsAddedLines: !folded && key.map(isSwiftCode) == true
            )
        }) else {
            return .failed("git printed a diff Nirux can't read in \(root).")
        }
        guard var files = Patch.files(entries: entries, sections: sections) else { return .inconsistent }
        for index in files.indices {
            files[index].fold = namedFolds[files[index].path] ?? files[index].fold
            RiskRules.settle(&files[index])
        }
        // Whether a line is in a function's body takes the whole file: it
        // is read from the worktree, and checked against the patch.
        let addedLines = Dictionary(sections.compactMap { section in
            section.newPath.flatMap { path in section.addedLines.map { (path, $0) } }
        }, uniquingKeysWith: { first, _ in first })
        var budget = maxScannedBytes
        for index in files.indices where mayDeclareSymbols(files[index]) && files[index].additions > 0 {
            let path = files[index].path
            files[index].symbols = scanSymbols(at: root + "/" + path, added: addedLines[path], budget: &budget)
        }
        let inlineBytes = files.filter { $0.fold == nil && $0.patchBytes <= maxFileBytes }.map(\.patchBytes).reduce(0, +)
        let onDemand = inline && inlineBytes > options.maxInlineDiffBytes
        let linesOnly = Patch.Reading(keepsLines: true, whitespace: nil, findsRisks: false)
        // A binary, a pure rename or a mode change has no line to show.
        for index in files.indices where files[index].additions + files[index].deletions > 0 {
            if files[index].patchBytes > maxFileBytes {
                files[index].omission = .tooLarge
            } else if inline, onDemand || files[index].fold != nil {
                files[index].omission = .onDemand
            } else {
                let read = (rangesByKey[files[index].path] ?? []).compactMap { Patch.section(data[$0], reading: linesOnly) }
                files[index].hunks = read.flatMap(\.hunks)
            }
        }
        return .files(files)
    }

    /// Each entry's path, and its path before a rename.
    static func paths(of entries: [NameStatusEntry]) -> [String] {
        entries.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) }
    }

    /// Paths and line counts only, for a diff too large to read: no hunks,
    /// no hash. A file `--name-status` lists only for its timestamp is left
    /// out: it is neither in the commits nor in what `git status` lists.
    static func listOnly(
        _ entries: [NameStatusEntry], root: String, mergeBase: String, head: String, pathspec: [String],
        uncommitted: Set<String>, ignoresAttributes: Bool = false, options: Options
    ) -> [FileChange]? {
        let diff = diffConfig + ["diff"] + diffSelection
        guard let numbers = git(
                  diff + ["--numstat", "-z", mergeBase, "--"] + pathspec,
                  in: root, options: options, maxOutputBytes: options.maxDiffBytes
              ), numbers.status == 0,
              let committed = git(
                  diff + ["--name-only", "-z", mergeBase, head, "--"] + pathspec,
                  in: root, options: options, maxOutputBytes: options.maxDiffBytes
              ), committed.status == 0
        else { return nil }
        let counts = numstat(numbers.stdout)
        let changed = uncommitted.union(committed.stdout.split(separator: 0).map(Patch.decoded))
        // An intent-to-add untracked file reads "A"; a touched file stays
        // "M".
        let entries = entries.filter { !"ACDRT".contains($0.letter) ? changed.contains($0.path) : true }
        let noise = NoiseRules(
            root: root, paths: paths(of: entries),
            ignoresAttributes: ignoresAttributes || paths(of: entries).contains(where: changesAttributes), options: options
        )
        return entries.map { entry -> FileChange in
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
            switch counts[entry.path] {
            case .lines(let additions, let deletions)?:
                file.additions = additions
                file.deletions = deletions
            case .binary?:
                file.isBinary = true
            case nil:
                break
            }
            file.omission = .notRead
            // Never more than its patch would: its start isn't read (a
            // diff this large may list thousands), nor its modes, which a
            // pure rename or a binary's chmod keeps.
            file.fold = noise.fold(path: file.path)
            RiskRules.settle(&file)
            file.symbols = unreadSymbols(of: file)
            return file
        }
    }

    enum LineCount: Equatable {
        case lines(additions: Int, deletions: Int)
        /// numstat counts a binary file "-".
        case binary
    }

    /// `git diff --numstat -z`, by path (the new path for a rename).
    static func numstat(_ data: Data) -> [String: LineCount] {
        var counts: [String: LineCount] = [:]
        var fields = data.split(separator: 0, omittingEmptySubsequences: false)[...]
        while let field = fields.popFirst(), !field.isEmpty {
            let parts = Patch.decoded(field).split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            var path = String(parts[2])
            if path.isEmpty {
                // A rename: the old and new paths follow, NUL-terminated.
                _ = fields.popFirst()
                path = fields.popFirst().map(Patch.decoded) ?? ""
            }
            if let additions = Int(parts[0]), let deletions = Int(parts[1]) {
                counts[path] = .lines(additions: additions, deletions: deletions)
            } else {
                counts[path] = .binary
            }
        }
        return counts
    }

    // MARK: Commits

    /// The commits from `mergeBase` to `head`, newest first, at most 1,000.
    static func commits(since mergeBase: String, head: String, root: String, options: Options) -> [Commit]? {
        guard let log = git(
            ["log", "-z", "--no-show-signature", "--encoding=UTF-8", "--max-count=1000",
             "--format=%H %P%n%B", "\(mergeBase)..\(head)", "--"],
            in: root, options: options
        ), log.status == 0 else { return nil }
        let records = log.stdout.split(separator: 0).map(Patch.decoded)
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

    struct StatusEntry: Equatable {
        /// The two-letter XY code, e.g. " M", "??".
        let code: String
        let path: String
    }

    /// Parses `git status --porcelain=v1 -z --no-renames`, cutting each
    /// entry by bytes: a path starting with a combining accent would make
    /// one Character of it and the space before.
    static func statusEntries(_ data: Data) -> [StatusEntry] {
        data.split(separator: 0).compactMap { field in
            guard field.count > 3 else { return nil }
            return StatusEntry(code: Patch.decoded(field.prefix(2)), path: Patch.decoded(field.dropFirst(3)))
        }
    }

    /// `git status` codes of an unmerged path: DD, AU, UD, UA, DU, AA, UU.
    static func isUnmerged(_ code: String) -> Bool {
        code.contains("U") || code == "AA" || code == "DD"
    }

    /// The handovers and Claude Code's local settings: Clean Up treats an
    /// untracked copy as disposable, and the review leaves it out.
    static func isDisposable(_ path: String) -> Bool {
        WorktreeCleanup.disposablePaths.contains(path)
    }

    struct GitOutput {
        let status: Int32
        let stdout: Data
        let stderr: String

        /// Standard output, decoded lossily.
        var text: String { Patch.decoded(stdout) }
    }

    /// Runs git read-only. `GIT_DIFF_OPTS` would change the context lines
    /// whatever `-U3` says, so it is emptied.
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
                .merging(environment) { _, override in override }
                .merging(["GIT_DIFF_OPTS": ""]) { _, pinned in pinned },
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

    /// "What failed: git's first line of standard error."
    static func failure(_ what: String, _ output: GitOutput?) -> String {
        guard let output, let reason = firstLine(output.stderr) else { return what + "." }
        return "\(what): \(reason)"
    }
}
