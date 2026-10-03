import Foundation

// MARK: - Base branch and pull request (section 7)

extension BranchReview {
    /// Runs the GitHub CLI. Injected so tests answer from fixtures: CI has
    /// no gh login.
    struct GitHubCLI: Sendable {
        struct Output: Sendable {
            let status: Int32
            let standardOutput: Data
            let standardError: String
        }

        /// Runs gh with these arguments in this folder; nil when it can't
        /// start or doesn't finish in time.
        let run: @Sendable (_ arguments: [String], _ directory: String) -> Output?

        /// The gh `PRDetect` finds; nil when it isn't installed.
        static func installed(timeout: TimeInterval = 30) -> GitHubCLI? {
            guard let path = PRDetect.installedGHPath() else { return nil }
            return GitHubCLI { arguments, directory in
                BoundedProcess.run(
                    executableURL: URL(fileURLWithPath: path),
                    arguments: arguments,
                    currentDirectoryURL: URL(fileURLWithPath: directory),
                    timeout: timeout,
                    captureStandardError: true
                ).map {
                    Output(
                        status: $0.terminationStatus,
                        standardOutput: $0.standardOutput,
                        standardError: String(decoding: $0.standardError, as: UTF8.self)
                    )
                }
            }
        }
    }

    /// The branch the review is based on; the merge base is read with HEAD.
    struct BaseBranch: Equatable, Sendable {
        /// "main".
        let name: String
        /// "refs/remotes/origin/main".
        let ref: String
    }

    struct BaseSelection: Equatable, Sendable {
        /// Nil when no candidate shares history with HEAD.
        let base: BaseBranch?
        let pullRequest: PullRequestLookup
        let fetchProblem: String?
    }

    /// The branch's own open pull request, then the merge base with its base
    /// branch; without one, with the remote's default branch, else `main`
    /// or `master`. Never `@{upstream}` (`GitCommand.branchBaseRef` tries it
    /// first): after `git push -u` with no pull request yet, it is the
    /// branch's own remote copy, and the page would show only unpushed
    /// commits.
    static func selectBase(root: String, branch: String, options: Options) -> BaseSelection {
        var fetchProblem: String?
        let lookup: PullRequestLookup
        if let known = options.knownPullRequest, known.branch == branch {
            lookup = known.lookup
            if options.fetchBase, let pullRequest = known.lookup.pullRequest {
                fetchProblem = fetch(baseBranch: pullRequest.baseRefName, root: root, options: options)
            }
        } else {
            lookup = lookUpPullRequest(branch: branch, root: root, options: options, fetchProblem: &fetchProblem)
        }

        var refs: [String] = []
        if let pullRequest = lookup.pullRequest {
            refs.append(remoteRef(pullRequest.baseRefName))
        }
        if let originHead = git(["symbolic-ref", "-q", "refs/remotes/origin/HEAD"], in: root, options: options),
           originHead.status == 0 {
            refs.append(originHead.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        refs += [remoteRef("main"), remoteRef("master"), "refs/heads/main", "refs/heads/master"]
        var tried: Set<String> = []
        for ref in refs where tried.insert(ref).inserted
            && git(["merge-base", "HEAD", ref], in: root, options: options)?.status == 0 {
            let name = ref.hasPrefix(remotePrefix)
                ? String(ref.dropFirst(remotePrefix.count))
                : String(ref.dropFirst("refs/heads/".count))
            return BaseSelection(base: BaseBranch(name: name, ref: ref), pullRequest: lookup, fetchProblem: fetchProblem)
        }
        return BaseSelection(base: nil, pullRequest: lookup, fetchProblem: fetchProblem)
    }

    private static let remotePrefix = "refs/remotes/origin/"

    private static func remoteRef(_ branch: String) -> String { remotePrefix + branch }

    /// Updates `refs/remotes/origin/<name>` and nothing else: no FETCH_HEAD,
    /// no tags, no submodules, no maintenance, no commit-graph, no prompt.
    /// Returns why it failed, if it did.
    static func fetch(baseBranch name: String, root: String, options: Options) -> String? {
        guard isPlainBranchName(name) else { return "The base branch name “\(name)” can't be fetched." }
        guard let result = git(
            ["-c", "fetch.writeCommitGraph=false", "fetch", "--quiet", "--no-auto-maintenance",
             "--no-write-fetch-head", "--no-tags", "--no-recurse-submodules", "--no-prune",
             "origin", "+refs/heads/\(name):\(remoteRef(name))"],
            in: root, options: options, environment: ["GIT_TERMINAL_PROMPT": "0"], timeout: options.fetchTimeout
        ) else { return "git fetch of \(name) didn't finish in \(Int(options.fetchTimeout)) s." }
        guard result.status == 0 else {
            return "git fetch of \(name) failed: \(firstLine(result.stderr) ?? "exit status \(result.status)")"
        }
        return nil
    }

    /// A name GitHub would give a branch, safe in a refspec. git checks
    /// the rest when it fetches.
    static func isPlainBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"),
              !name.hasSuffix(".lock"), !name.contains(".."), !name.contains("@{"), !name.contains("//")
        else { return false }
        let forbidden = Set("~^:?*[\\".unicodeScalars)
        return name.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value != 0x7F && !forbidden.contains($0) }
    }

    // MARK: Pull request

    struct LookupFailure: Error, Equatable {
        let message: String
    }

    /// The newest open pull request that is the branch's own. With
    /// `fetchBase`, each candidate's base branch is fetched first: whether
    /// it is the branch's own depends on it.
    static func lookUpPullRequest(
        branch: String, root: String, options: Options, fetchProblem: inout String?
    ) -> PullRequestLookup {
        let candidates: [PullRequest]
        switch openPullRequests(branch: branch, root: root, options: options) {
        case .failure(let failure): return .unavailable(failure.message)
        case .success(let found): candidates = found
        }
        var fetched: Set<String> = []
        for candidate in candidates {
            if options.fetchBase, fetched.insert(candidate.baseRefName).inserted,
               let problem = fetch(baseBranch: candidate.baseRefName, root: root, options: options) {
                fetchProblem = problem
            }
            switch isOwnPullRequest(candidate, branch: branch, root: root, options: options) {
            case .success(true): return .found(candidate)
            case .success(false): continue
            case .failure(let failure): return .unavailable(failure.message)
            }
        }
        return .notFound
    }

    /// Open pull requests whose head is this branch of the repository it is
    /// pushed to, as `PRDetect` matches them; newest first. Without their
    /// commits: gh asks for each commit's authors, and 100 pull requests ×
    /// 100 commits × 100 authors is over GitHub's GraphQL limit of 500,000
    /// nodes, which fails the whole query.
    static func openPullRequests(
        branch: String, root: String, options: Options
    ) -> Result<[PullRequest], LookupFailure> {
        guard let gitHub = options.gitHub else {
            return .failure(LookupFailure(message: "The GitHub CLI (gh) isn't installed."))
        }
        guard let repository = headRepository(branch: branch, root: root, options: options) else {
            return .failure(LookupFailure(message: "\(branch) isn't pushed to GitHub."))
        }
        let fields = "number,title,body,url,baseRefName,headRefOid,isDraft,headRepository,headRepositoryOwner"
        guard let output = gitHub.run(
            ["pr", "list", "--head", branch, "--state", "open", "--json", fields, "--limit", "100"], root
        ) else {
            return .failure(LookupFailure(message: "gh didn't answer."))
        }
        guard output.status == 0 else {
            let reason = firstLine(output.standardError).map { ": \($0)" } ?? "."
            return .failure(LookupFailure(message: "gh couldn't list the pull requests\(reason)"))
        }
        guard let json = try? JSONSerialization.jsonObject(with: output.standardOutput) as? [[String: Any]] else {
            return .failure(LookupFailure(message: "gh printed pull requests Nirux can't read."))
        }
        return .success(
            json.compactMap { pullRequest(from: $0, headRepository: repository) }
                .sorted { $0.number > $1.number }
        )
    }

    static func pullRequest(from json: [String: Any], headRepository: GitHubRepository) -> PullRequest? {
        guard let number = json["number"] as? Int,
              let url = json["url"] as? String,
              let baseRefName = json["baseRefName"] as? String,
              let headRefOid = (json["headRefOid"] as? String)?.lowercased(),
              [40, 64].contains(headRefOid.count), headRefOid.allSatisfy(\.isHexDigit),
              let owner = (json["headRepositoryOwner"] as? [String: Any])?["login"] as? String,
              let name = (json["headRepository"] as? [String: Any])?["name"] as? String,
              GitHubRepository(repositoryURL: url, owner: owner, name: name) == headRepository
        else { return nil }
        return PullRequest(
            number: number,
            title: json["title"] as? String ?? "",
            body: json["body"] as? String ?? "",
            url: url,
            baseRefName: baseRefName,
            headRefOid: headRefOid,
            isDraft: json["isDraft"] as? Bool ?? false
        )
    }

    /// A pull request under a reused branch name isn't this branch's: its
    /// head must be in the branch's reflog (after a local rebase not pushed
    /// yet, none of its commits is in HEAD's history), or one of its commits
    /// in HEAD's history and not in its base's. The reflog is read first:
    /// it settles the usual case without asking gh for the commits.
    static func isOwnPullRequest(
        _ pullRequest: PullRequest, branch: String, root: String, options: Options
    ) -> Result<Bool, LookupFailure> {
        if reflog(of: branch, contains: pullRequest.headRefOid, root: root, options: options) == true {
            return .success(true)
        }
        guard let gitHub = options.gitHub,
              let output = gitHub.run(["pr", "view", pullRequest.url, "--json", "commits"], root)
        else { return .failure(LookupFailure(message: "gh didn't answer.")) }
        guard output.status == 0,
              let json = (try? JSONSerialization.jsonObject(with: output.standardOutput)) as? [String: Any],
              let commits = json["commits"] as? [[String: Any]]
        else {
            let reason = firstLine(output.standardError).map { ": \($0)" } ?? "."
            return .failure(LookupFailure(message: "gh couldn't read the commits of #\(pullRequest.number)\(reason)"))
        }
        let oids = Set(commits.compactMap { ($0["oid"] as? String)?.lowercased() })
        let baseRef = remoteRef(pullRequest.baseRefName)
        let hasBase = isPlainBranchName(pullRequest.baseRefName)
            && git(["rev-parse", "-q", "--verify", "\(baseRef)^{commit}"], in: root, options: options)?.status == 0
        let range = hasBase ? ["HEAD", "^\(baseRef)"] : ["HEAD"]
        guard let own = git(["rev-list", "--max-count=10000"] + range + ["--"], in: root, options: options),
              own.status == 0
        else { return .success(false) }
        return .success(!oids.isDisjoint(with: own.text.split(separator: "\n").map(String.init)))
    }

    /// HEAD against `other`: `git rev-list --left-right --count`.
    static func compare(head: String, with other: String, root: String, options: Options) -> HeadComparison? {
        guard let counted = git(["rev-list", "--left-right", "--count", "\(head)...\(other)", "--"], in: root, options: options),
              counted.status == 0
        else { return nil }
        let numbers = counted.text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard numbers.count == 2 else { return nil }
        return .counted(ahead: numbers[0], behind: numbers[1])
    }

    /// HEAD against the pull request's head, which may not be local.
    static func comparePullRequestHead(_ pullRequest: PullRequest, head: String, root: String, options: Options) -> HeadComparison? {
        guard git(["cat-file", "-e", "\(pullRequest.headRefOid)^{commit}"], in: root, options: options)?.status == 0
        else { return .notLocal }
        return compare(head: head, with: pullRequest.headRefOid, root: root, options: options)
    }

    /// The repository the branch is pushed to; `origin` for a branch pushed
    /// without an upstream, or not pushed yet.
    static func headRepository(branch: String, root: String, options: Options) -> GitHubRepository? {
        var remote = git(["for-each-ref", "--format=%(push:remotename)", "refs/heads/\(branch)"], in: root, options: options)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        if remote.isEmpty || remote == "." { remote = "origin" }
        guard let url = git(["remote", "get-url", "--push", "--", remote], in: root, options: options),
              url.status == 0
        else { return nil }
        return GitHubRepository(remoteURL: url.text)
    }
}
