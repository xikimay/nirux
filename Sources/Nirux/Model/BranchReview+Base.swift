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

    struct BaseSelection: Equatable, Sendable {
        /// Nil when no candidate shares history with HEAD.
        let base: Base?
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
        var fetched: Set<String> = []
        let lookup: PullRequestLookup
        switch openPullRequests(branch: branch, root: root, options: options) {
        case .failure(let failure):
            lookup = .unavailable(failure.message)
        case .success(let candidates):
            var found: PullRequest?
            for candidate in candidates {
                let baseName = candidate.pullRequest.baseRefName
                if options.fetchBase, fetched.insert(baseName).inserted,
                   let problem = fetch(baseBranch: baseName, root: root, options: options) {
                    fetchProblem = problem
                }
                if isOwnPullRequest(candidate, branch: branch, root: root, options: options) {
                    found = candidate.pullRequest
                    break
                }
            }
            lookup = found.map { .found($0) } ?? .notFound
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
        for ref in refs where tried.insert(ref).inserted {
            guard let mergeBase = git(["merge-base", "HEAD", ref], in: root, options: options), mergeBase.status == 0
            else { continue }
            let name = ref.hasPrefix(remotePrefix)
                ? String(ref.dropFirst(remotePrefix.count))
                : String(ref.dropFirst("refs/heads/".count))
            let base = Base(name: name, ref: ref, mergeBase: mergeBase.text.trimmingCharacters(in: .whitespacesAndNewlines))
            return BaseSelection(base: base, pullRequest: lookup, fetchProblem: fetchProblem)
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

    struct Candidate: Equatable, Sendable {
        let pullRequest: PullRequest
        let commitOids: Set<String>
    }

    struct LookupFailure: Error, Equatable {
        let message: String
    }

    /// Open pull requests whose head is this branch of the repository it is
    /// pushed to, as `PRDetect` matches them; newest first.
    static func openPullRequests(
        branch: String, root: String, options: Options
    ) -> Result<[Candidate], LookupFailure> {
        guard let gitHub = options.gitHub else {
            return .failure(LookupFailure(message: "The GitHub CLI (gh) isn't installed."))
        }
        guard let repository = headRepository(branch: branch, root: root, options: options) else {
            return .failure(LookupFailure(message: "\(branch) isn't pushed to GitHub."))
        }
        let fields = "number,title,body,url,baseRefName,headRefOid,isDraft,headRepository,headRepositoryOwner,commits"
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
            json.compactMap { candidate(from: $0, headRepository: repository) }
                .sorted { $0.pullRequest.number > $1.pullRequest.number }
        )
    }

    static func candidate(from json: [String: Any], headRepository: GitHubRepository) -> Candidate? {
        guard let number = json["number"] as? Int,
              let url = json["url"] as? String,
              let baseRefName = json["baseRefName"] as? String,
              let headRefOid = (json["headRefOid"] as? String)?.lowercased(),
              let owner = (json["headRepositoryOwner"] as? [String: Any])?["login"] as? String,
              let name = (json["headRepository"] as? [String: Any])?["name"] as? String,
              GitHubRepository(repositoryURL: url, owner: owner, name: name) == headRepository
        else { return nil }
        let commits = (json["commits"] as? [[String: Any]] ?? []).compactMap { ($0["oid"] as? String)?.lowercased() }
        return Candidate(
            pullRequest: PullRequest(
                number: number,
                title: json["title"] as? String ?? "",
                body: json["body"] as? String ?? "",
                url: url,
                baseRefName: baseRefName,
                headRefOid: headRefOid,
                isDraft: json["isDraft"] as? Bool ?? false
            ),
            commitOids: Set(commits)
        )
    }

    /// A pull request under a reused branch name isn't this branch's: one
    /// of its commits must be in HEAD's history and not in its base's, or
    /// its head in the branch's reflog (after a local rebase not pushed
    /// yet, none of its commits is in HEAD's history).
    static func isOwnPullRequest(_ candidate: Candidate, branch: String, root: String, options: Options) -> Bool {
        let baseRef = remoteRef(candidate.pullRequest.baseRefName)
        let hasBase = isPlainBranchName(candidate.pullRequest.baseRefName)
            && git(["rev-parse", "-q", "--verify", "\(baseRef)^{commit}"], in: root, options: options)?.status == 0
        let range = hasBase ? ["HEAD", "^\(baseRef)"] : ["HEAD"]
        if let own = git(["rev-list", "--max-count=10000"] + range + ["--"], in: root, options: options),
           own.status == 0,
           !candidate.commitOids.isDisjoint(with: own.text.split(separator: "\n").map(String.init)) {
            return true
        }
        guard let reflog = git(["log", "-g", "--format=%H", "refs/heads/\(branch)", "--"], in: root, options: options),
              reflog.status == 0
        else { return false }
        return reflog.text.split(separator: "\n").contains { $0 == candidate.pullRequest.headRefOid }
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
