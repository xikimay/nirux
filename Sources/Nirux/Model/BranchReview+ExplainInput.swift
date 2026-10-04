import Foundation

// MARK: - What Explain sends (section 4.3)

extension BranchReview {
    /// What one Explain run reads on its standard input: the author's texts
    /// (the pull request, the handover, the commits), the files, and the
    /// diff from the merge base with numbered hunks ("f3h1": the fourth
    /// file's second hunk).
    ///
    /// The author's texts are fenced between `<<<nonce` and `nonce>>>`
    /// lines, with a nonce the texts don't hold, so a pull request body
    /// can't fake the parts that follow it. Paths and hunk headers show
    /// their invisible characters as code points (`visible`), and diff
    /// lines their line separators, so neither can fake a line either.
    struct ExplainInput: Equatable, Sendable {
        let text: String
        /// Every file of the snapshot, by id ("f3"): ids are the same in
        /// every part.
        let files: [String: String]
        /// The ids the text lists, in its order: the ones the model can
        /// answer with.
        let listedFiles: [String]
        /// The hunks it sends, by id, to map the model's notes back. A
        /// withheld hunk isn't one: a note on it is dropped.
        let hunks: [String: HunkReference]
        /// The files whose diff it sends, with the hash of the patch sent:
        /// a diff read for the run may be newer than the snapshot's.
        let sentPatches: [String: String]
        /// The diff's size in `text`.
        let diffBytes: Int

        var sentPaths: Set<String> { Set(sentPatches.keys) }
    }

    /// A hunk, by its file and its index in the file's patch (as
    /// `filePatch` reads it): what notes are stored by, since a run's hunk
    /// ids live for that run only.
    struct HunkReference: Equatable, Sendable {
        let path: String
        let index: Int
    }

    struct ExplainRequest: Equatable, Sendable {
        /// Untracked files are sent by name only, unless the user asks.
        var includeUntracked = false
        /// The paths whose diff to send (the files whose patch changed
        /// since the last explanation); nil sends every file's.
        var only: Set<String>?
        /// The last explanation's overview, as context for a run that sends
        /// only what changed since.
        var previousOverview: String?
    }

    /// Why a file's diff isn't sent. The file is still named, with why.
    enum NotSent: Equatable, Sendable {
        case secretPath
        case folded(Fold)
        case untracked
        /// The snapshot didn't read it: the branch's diff is too large.
        case notRead
        /// Its patch is over `Options.maxFileDiffBytes`.
        case tooLarge
        /// Its patch alone is over one run's `maxExplainDiffBytes`.
        case overRunSize
        /// `filePatch` failed.
        case unreadable
        /// Not in `ExplainRequest.only`.
        case unchanged

        var label: String {
            switch self {
            case .secretPath: return "looks like a secret"
            case .folded(.lockfile): return "lockfile, folded"
            case .folded(.generated): return "generated, folded"
            case .folded(.pureRename): return "pure rename, folded"
            case .folded(.whitespaceOnly): return "whitespace only, folded"
            case .folded(.binary): return "binary"
            case .untracked: return "untracked: sent by name only"
            case .notRead: return "diff not read: the branch's diff is too large"
            case .tooLarge: return "diff too large to send"
            case .overRunSize: return "diff larger than one run takes"
            case .unreadable: return "diff couldn't be read"
            case .unchanged: return "unchanged since the last explanation"
            }
        }
    }

    /// One run sends at most this much diff. A larger branch is explained
    /// in several runs, whole groups packed together.
    static let maxExplainDiffBytes = 150_000
    /// The author's texts are cut past these, so that the whole input stays
    /// near 300 KB: the pull request, the handover, the commits, and the
    /// last overview.
    static let maxExplainTextBytes = 32_000
    static let maxExplainOverviewBytes = 16_000
    /// Past this many, the file lists show the files whose diff the run
    /// sends and others up to it, and count the rest by folder.
    static let maxExplainListedFiles = 300

    /// The inputs of the runs that explain `snapshot`: one, or several when
    /// the diff is larger than one run takes, packing whole groups in the
    /// page's order (a large group in several runs of whole files). Empty
    /// when no diff is left to send. Left out: folded files, binaries,
    /// secret paths and, by default, untracked files' diffs; a hunk holding
    /// a key is replaced by "withheld: looks like a secret", and so is an
    /// author's text. `notInCopy` names the branch's files the run can't
    /// read in its copy (`ExplainCopy.leftOut`). `patch` reads a diff the
    /// snapshot left out to keep the page light (`filePatch`): it runs git,
    /// so call this off the main thread.
    static func explainInputs(
        for snapshot: Snapshot,
        handover: Handover?,
        request: ExplainRequest = ExplainRequest(),
        notInCopy: [ExplainCopy.Omitted] = [],
        nonce: String? = nil,
        patch: (FileChange) -> FileChange?
    ) -> [ExplainInput] {
        var notSent: [String: NotSent] = [:]
        var diffs: [String: (text: String, hunks: [String: HunkReference], patchHash: String)] = [:]
        let ids = Dictionary(snapshot.files.enumerated().map { ($1.path, "f\($0)") }, uniquingKeysWith: { first, _ in first })
        for file in snapshot.files {
            var read = file
            if notSentReason(file, request: request) == nil, file.omission == .onDemand {
                read = patch(file) ?? file
                if read.omission == .onDemand {
                    notSent[file.path] = .unreadable
                    continue
                }
            }
            // A diff read now is checked again: the worktree may have moved.
            if let reason = notSentReason(read, request: request) {
                notSent[file.path] = reason
                continue
            }
            let diff = explainDiff(of: read, id: ids[file.path] ?? "")
            guard diff.text.utf8.count <= maxExplainDiffBytes else {
                notSent[file.path] = .overRunSize
                continue
            }
            diffs[file.path] = (diff.text, diff.hunks, read.patchHash ?? "")
        }
        guard !diffs.isEmpty else { return [] }

        let parts = explainParts(snapshot.groups, sizes: diffs.mapValues { $0.text.utf8.count })
        let nonce = nonce ?? freshNonce(avoiding: authorTexts(snapshot, handover: handover, request: request))
        let authorText = explainAuthorTexts(snapshot, handover: handover, request: request, nonce: nonce)
        let fileIDs = Dictionary(ids.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return parts.enumerated().map { number, part in
            var text = explainHeader(snapshot, part: parts.count > 1 ? (number + 1, parts.count, part.titles) : nil)
            text += authorText
            let lists = explainFileLists(snapshot, ids: ids, notSent: notSent, notInCopy: notInCopy, sent: Set(part.paths))
            text += lists.text
            var diffText = ""
            var hunks: [String: HunkReference] = [:]
            var sentPatches: [String: String] = [:]
            for path in part.paths {
                guard let diff = diffs[path] else { continue }
                diffText += diff.text
                hunks.merge(diff.hunks) { first, _ in first }
                sentPatches[path] = diff.patchHash
            }
            text += "\n# Diff\n" + diffText
            return ExplainInput(
                text: text, files: fileIDs, listedFiles: lists.listed, hunks: hunks, sentPatches: sentPatches,
                diffBytes: diffText.utf8.count
            )
        }
    }

    private static func notSentReason(_ file: FileChange, request: ExplainRequest) -> NotSent? {
        if Secrets.isSecretPath(file.path) || file.oldPath.map(Secrets.isSecretPath) == true { return .secretPath }
        if let fold = file.fold { return .folded(fold) }
        if file.isBinary { return .folded(.binary) }
        if file.isUntracked, !request.includeUntracked { return .untracked }
        if let only = request.only, !only.contains(file.path) { return .unchanged }
        switch file.omission {
        case .notRead?: return .notRead
        case .tooLarge?: return .tooLarge
        case .onDemand?, nil: return nil
        }
    }

    /// A file's diff with its hunks numbered. A hunk holding a key, in its
    /// lines or in its header (git's funcname line, from above the hunk),
    /// is withheld, and isn't in the map.
    private static func explainDiff(of file: FileChange, id: String) -> (text: String, hunks: [String: HunkReference]) {
        var text = "## \(id) \(visible(file.path))"
        if let oldPath = file.oldPath { text += " (renamed from \(visible(oldPath)))" }
        text += "\n"
        var hunks: [String: HunkReference] = [:]
        for (index, hunk) in file.hunks.enumerated() {
            let hunkID = "\(id)h\(index)"
            let range = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
            if Secrets.containsKey(hunk.section) || hunk.lines.contains(where: { Secrets.containsKey($0.text) }) {
                text += "### \(hunkID) \(range)\nwithheld: looks like a secret\n"
                continue
            }
            text += "### \(hunkID) \(range)\(hunk.section.isEmpty ? "" : " " + visible(hunk.section))\n"
            for line in hunk.lines {
                switch line.kind {
                case .context: text += " " + lineVisible(line.text) + "\n"
                case .added: text += "+" + lineVisible(line.text) + "\n"
                case .removed: text += "-" + lineVisible(line.text) + "\n"
                case .noNewlineMarker: text += "\\ No newline at end of file\n"
                }
            }
            hunks[hunkID] = HunkReference(path: file.path, index: index)
        }
        return (text, hunks)
    }

    /// A diff line with what would break it in two as a code point: line
    /// and paragraph separators, next line, a carriage return before its
    /// end. The rest stays: it is the code under review.
    private static func lineVisible(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.contains(where: { [0x2028, 0x2029, 0x85, 0x0D].contains($0.value) }) else { return text }
        var result = ""
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            let next = scalars.index(after: index)
            let breaks = [0x2028, 0x2029, 0x85].contains(scalar.value) || (scalar.value == 0x0D && next < scalars.endIndex)
            if breaks {
                result += codePoint(scalar)
            } else {
                result.unicodeScalars.append(scalar)
            }
            index = next
        }
        return result
    }

    /// Runs of whole groups, in the page's order, each within one run's
    /// diff size; a group larger than that is cut into runs of whole files.
    private static func explainParts(
        _ groups: [FileGroup], sizes: [String: Int]
    ) -> [(titles: [String], paths: [String])] {
        var parts: [(titles: [String], paths: [String])] = []
        var current: (titles: [String], paths: [String]) = ([], [])
        var size = 0
        func close() {
            if !current.paths.isEmpty { parts.append(current) }
            current = ([], [])
            size = 0
        }
        for group in groups {
            let paths = group.paths.filter { sizes[$0] != nil }
            guard !paths.isEmpty else { continue }
            let groupSize = paths.reduce(0) { $0 + (sizes[$1] ?? 0) }
            if size + groupSize > maxExplainDiffBytes { close() }
            for path in paths {
                let fileSize = sizes[path] ?? 0
                if !current.paths.isEmpty, size + fileSize > maxExplainDiffBytes { close() }
                if current.titles.last != group.kind.title { current.titles.append(group.kind.title) }
                current.paths.append(path)
                size += fileSize
            }
        }
        close()
        return parts
    }

    private static func explainHeader(_ snapshot: Snapshot, part: (number: Int, count: Int, titles: [String])?) -> String {
        var text = "# Branch\n\(visible(snapshot.branch)) into \(visible(snapshot.base.name))\n"
        text += "head \(snapshot.head), merge base \(snapshot.base.mergeBase)\n"
        if let part {
            text += "This run sends part \(part.number) of \(part.count) of the diff: "
            text += part.titles.joined(separator: ", ")
            text += ". The other files are listed without their diff.\n"
        }
        return text
    }

    private static func authorTexts(_ snapshot: Snapshot, handover: Handover?, request: ExplainRequest) -> [String] {
        let pullRequest = snapshot.pullRequest.pullRequest
        return [pullRequest?.title, pullRequest?.body, handover?.text, request.previousOverview].compactMap { $0 }
            + snapshot.commits.flatMap { [$0.subject, $0.body] }
    }

    private static func explainAuthorTexts(
        _ snapshot: Snapshot, handover: Handover?, request: ExplainRequest, nonce: String
    ) -> String {
        func fenced(_ text: String, limit: Int = maxExplainTextBytes) -> String {
            let shown = Secrets.containsKey(text) ? "withheld: looks like a secret" : cut(text, at: limit)
            return "<<<\(nonce)\n" + shown + (shown.hasSuffix("\n") ? "" : "\n") + "\(nonce)>>>\n"
        }
        var text = ""
        if let pullRequest = snapshot.pullRequest.pullRequest {
            text += "\n# Pull request #\(pullRequest.number), as its author wrote it\n"
            text += fenced("Title: \(pullRequest.title)\n\n\(pullRequest.body)")
        }
        if let handover {
            text += "\n# Handover \(handover.name)\(handover.isCut ? " (beginning)" : ""), as its author wrote it\n"
            text += fenced(handover.text)
        }
        let commits = snapshot.commits.filter { !$0.isMergeFromBase }.reversed()
        if !commits.isEmpty {
            let merges = snapshot.commits.count - commits.count
            text += "\n# Commits, oldest first, as their author wrote them"
            text += merges > 0 ? " (\(count(merges, "merge")) from \(visible(snapshot.base.name)) left out)\n" : "\n"
            text += fenced(commits.map { commit in
                let message = commit.subject + (commit.body.isEmpty ? "" : "\n\n\(commit.body)")
                return "\(commit.oid.prefix(12)) " + (Secrets.containsKey(message) ? "withheld: looks like a secret" : message)
            }.joined(separator: "\n\n"))
        }
        if let overview = request.previousOverview {
            text += "\n# The last explanation's overview, for the files unchanged since\n"
            text += fenced(overview, limit: maxExplainOverviewBytes)
        }
        return text
    }

    /// The files, those whose diff isn't sent with why, and the branch's
    /// files the run can't read in its copy. Past `maxExplainListedFiles`,
    /// the files this run sends and the first others are listed, and the
    /// rest counted by top folder.
    private static func explainFileLists(
        _ snapshot: Snapshot, ids: [String: String], notSent: [String: NotSent], notInCopy: [ExplainCopy.Omitted],
        sent: Set<String>
    ) -> (text: String, listed: [String]) {
        let room = max(0, maxExplainListedFiles - sent.count)
        var others = 0
        var listed = Set<String>()
        for file in snapshot.files where !sent.contains(file.path) {
            guard others < room else { break }
            listed.insert(file.path)
            others += 1
        }
        listed.formUnion(sent)
        var files = "\n# Files\n"
        var notSentText = ""
        var rest: [String: Int] = [:]
        var listedIDs: [String] = []
        for file in snapshot.files {
            guard listed.contains(file.path) else {
                let folder = file.path.split(separator: "/", maxSplits: 1).count > 1
                    ? String(file.path.split(separator: "/", maxSplits: 1)[0]) + "/" : "the top folder"
                rest[folder, default: 0] += 1
                continue
            }
            let id = ids[file.path] ?? ""
            listedIDs.append(id)
            var line = "\(id) \(visible(file.path)) · \(file.status.rawValue)"
            if let oldPath = file.oldPath { line += " from \(visible(oldPath))" }
            line += " · +\(file.additions) −\(file.deletions)"
            if file.isUncommitted { line += " · not committed" }
            files += line + "\n"
            if let reason = notSent[file.path] { notSentText += "\(id) \(visible(file.path)) · \(reason.label)\n" }
        }
        if !rest.isEmpty {
            let folders = rest.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            let named = folders.prefix(8).map { "\($0.value) in \(visible($0.key))" }
            let elsewhere = folders.dropFirst(8).reduce(0) { $0 + $1.value }
            files += "and \(count(rest.values.reduce(0, +), "more file")), not listed: " + named.joined(separator: ", ")
                + (elsewhere > 0 ? ", \(elsewhere) elsewhere" : "") + "\n"
        }
        let branchFiles = Set(snapshot.files.map(\.path))
        // A file already named under "Not sent" isn't named twice.
        let unreadable = notInCopy.filter {
            branchFiles.contains($0.path) && listed.contains($0.path) && notSent[$0.path] == nil
        }
        var text = files
        if !notSentText.isEmpty { text += "\n# Not sent\n" + notSentText }
        if !unreadable.isEmpty {
            text += "\n# Not in the folder you can read\n"
            text += unreadable.map { "\(ids[$0.path] ?? "") \(visible($0.path)) · \($0.reason.label)\n" }.joined()
        }
        return (text, listedIDs)
    }

    /// Cut past `limit` bytes, on a scalar: never inside a UTF-8
    /// sequence, whatever the text (a long run of combining marks).
    private static func cut(_ text: String, at limit: Int) -> String {
        let utf8 = text.utf8
        guard utf8.count > limit else { return text }
        var end = utf8.index(utf8.startIndex, offsetBy: limit)
        while end > utf8.startIndex, UTF8.isContinuation(utf8[end]) { end = utf8.index(before: end) }
        return String(decoding: utf8[..<end], as: UTF8.self) + "\n[cut at \(limit / 1_000) KB]"
    }

    private static func freshNonce(avoiding texts: [String]) -> String {
        while true {
            let nonce = "author-" + String(UInt64.random(in: 1...UInt64.max), radix: 16)
            if !texts.contains(where: { $0.contains(nonce) }) { return nonce }
        }
    }
}

extension BranchReview.ExplainCopy.LeftOut {
    /// Why the run can't read a file of the branch in its copy.
    var label: String {
        switch self {
        case .missing: return "not in the working tree"
        case .notRegularFile: return "a link or not a regular file"
        case .notText: return "binary"
        case .secretPath: return "looks like a secret"
        case .key: return "holds a key"
        case .instructions: return "instructions for an agent"
        case .hiddenFromGit: return "git hides its edits"
        case .filtered: return "stored through a git filter"
        case .tooLarge: return "too large"
        case .overTotal: return "past the copy's limit"
        case .unreadable: return "couldn't be read"
        case .notWritten: return "couldn't be copied"
        }
    }
}
