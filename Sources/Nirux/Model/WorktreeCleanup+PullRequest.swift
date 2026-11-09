import Foundation

// MARK: - Pull request

extension WorktreeCleanup {
    enum Ancestry: Equatable {
        case contained
        case notContained
        /// The commit isn't in the local repository.
        case unknownCommit
    }

    /// The branch's pull request, why it can't be cleaned up, and, when
    /// the only reason is that nothing was merged yet, that in a few words.
    typealias Verdict = (pullRequest: PullRequest?, problems: [String], notMerged: String?)

    static func pullRequestLookup(
        branch: String, tip: String, worktree: Worktree, tools: Tools
    ) -> Verdict {
        guard let ghPath = tools.ghPath else {
            return (nil, ["The GitHub CLI (gh) isn't installed: the pull request can't be checked."], nil)
        }
        let repository: GitHubRepository
        switch headRepository(branch: branch, at: worktree.path, tools: tools) {
        case .success(let found): repository = found
        case .failure(let failure): return (nil, [failure.message], nil)
        }
        let fields = "number,state,headRefOid,headRepositoryOwner,headRepository,url"
        let result = run(
            executable: ghPath,
            arguments: ["pr", "list", "--head=\(branch)", "--state", "all", "--json", fields, "--limit", "1000"],
            in: worktree.path, tools: tools
        )
        guard result.status == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]]
        else {
            let reason = firstLine(result.stderr).map { ": \($0)" } ?? ""
            return (nil, ["gh couldn't list the pull requests of \(branch)\(reason)"], nil)
        }
        let candidates = json.compactMap { pullRequest(from: $0, headRepository: repository) }
        if candidates.isEmpty, let problem = mergedElsewhere(json, branch: branch, tip: tip, repository: repository, worktree: worktree, tools: tools) {
            return (nil, [problem], nil)
        }
        return verdict(branch: branch, tip: tip, candidates: candidates) { headOid in
            ancestry(of: tip, in: headOid, at: worktree.path, tools: tools)
        }
    }

    /// Why a merged pull request from another repository may be this
    /// branch's, or nil. Only one from the same owner under another name
    /// (the repository was renamed and the remote still has the old name)
    /// or from a repository GitHub no longer names (deleted) can be: a
    /// fork's, another owner's, says nothing about this branch, even
    /// holding its tip (a branch without commits of its own is in any later
    /// work). Asked only when this repository has none; forks cost no git.
    static func mergedElsewhere(
        _ json: [[String: Any]], branch: String, tip: String, repository: GitHubRepository, worktree: Worktree, tools: Tools
    ) -> String? {
        let heads = json.compactMap { candidate -> String? in
            guard (candidate["state"] as? String)?.uppercased() == "MERGED",
                  let headOid = (candidate["headRefOid"] as? String)?.lowercased(), isObjectID(headOid)
            else { return nil }
            let owner = (candidate["headRepositoryOwner"] as? [String: Any])?["login"] as? String
            return owner != nil && owner?.lowercased() == repository.owner.lowercased() ? headOid : nil
        }
        let elsewhere = "another repository than \(repository.owner)/\(repository.name)"
        let renamed = "If the repository was renamed, update the remote's URL."
        for head in heads {
            switch head == tip ? .contained : ancestry(of: tip, in: head, at: worktree.path, tools: tools) {
            case .contained:
                return "A merged pull request for \(branch) holds its tip but comes from \(elsewhere). \(renamed)"
            case .unknownCommit:
                return "A merged pull request for \(branch) comes from \(elsewhere), and its head (\(short(head))) "
                    + "isn't in the local repository. A git fetch may bring it in. \(renamed)"
            case .notContained:
                continue
            }
        }
        return nil
    }

    /// Which pull request the branch belongs to, and why it can't be
    /// cleaned up if so. An open pull request blocks: the branch is still
    /// in use. Otherwise a merged one must contain the tip.
    static func verdict(
        branch: String,
        tip: String,
        candidates: [PullRequest],
        ancestry: (String) -> Ancestry
    ) -> Verdict {
        let sorted = candidates.sorted { $0.number > $1.number }
        if let open = sorted.first(where: { $0.state == "OPEN" }) {
            return (open, ["Pull request #\(open.number) for \(branch) is still open."], "PR #\(open.number) open")
        }
        let merged = sorted.filter { $0.state == "MERGED" }
        guard let latest = merged.first else {
            if let closed = sorted.first {
                return (
                    closed, ["Pull request #\(closed.number) was closed without being merged."],
                    "PR #\(closed.number) closed without merging"
                )
            }
            return (nil, ["No pull request found for \(branch)."], "no pull request")
        }
        if let exact = merged.first(where: { $0.headOid == tip }) {
            return (exact, [], nil)
        }
        var unknown: PullRequest?
        for pullRequest in merged {
            switch ancestry(pullRequest.headOid) {
            case .contained: return (pullRequest, [], nil)
            case .unknownCommit: unknown = unknown ?? pullRequest
            case .notContained: continue
            }
        }
        if let unknown {
            return (unknown, [
                "The head of merged pull request #\(unknown.number) (\(short(unknown.headOid))) isn't in "
                    + "the local repository, so \(branch) can't be compared with it. A git fetch may bring it in."
            ], nil)
        }
        return (latest, [
            "\(branch) has commits that aren't in merged pull request #\(latest.number) "
                + "(local \(short(tip)), merged head \(short(latest.headOid)))."
        ], nil)
    }

    static func pullRequest(from candidate: [String: Any], headRepository: GitHubRepository) -> PullRequest? {
        guard let number = candidate["number"] as? Int,
              let state = (candidate["state"] as? String)?.uppercased(),
              let headOid = candidate["headRefOid"] as? String, isObjectID(headOid),
              let url = candidate["url"] as? String,
              let owner = (candidate["headRepositoryOwner"] as? [String: Any])?["login"] as? String,
              let name = (candidate["headRepository"] as? [String: Any])?["name"] as? String,
              GitHubRepository(repositoryURL: url, owner: owner, name: name) == headRepository
        else { return nil }
        return PullRequest(number: number, state: state, headOid: headOid.lowercased(), url: url)
    }

    /// The repository the branch is pushed to, as PRDetect matches it; the
    /// `origin` remote for a branch pushed without an upstream.
    private static func headRepository(
        branch: String, at path: String, tools: Tools
    ) -> Result<GitHubRepository, ReadFailure> {
        let pushRemote = git(["for-each-ref", "--format=%(push:remotename)", "refs/heads/\(branch)"], in: path, tools: tools)
        guard pushRemote.status == 0 else {
            return .failure(ReadFailure(message:
                "git couldn't read where \(branch) is pushed: \(firstLine(pushRemote.stderr) ?? "unknown error")"))
        }
        var remote = pushRemote.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if remote.isEmpty || remote == "." { remote = "origin" }
        let url = git(["remote", "get-url", "--push", "--", remote], in: path, tools: tools)
        guard url.status == 0, let repository = GitHubRepository(remoteURL: url.stdout) else {
            return .failure(ReadFailure(message:
                "\(branch) isn't pushed to a GitHub remote (\(remote)): its pull request can't be looked up."))
        }
        return .success(repository)
    }

    private static func ancestry(of tip: String, in headOid: String, at path: String, tools: Tools) -> Ancestry {
        guard isObjectID(headOid),
              git(["cat-file", "-e", "\(headOid)^{commit}"], in: path, tools: tools).status == 0
        else { return .unknownCommit }
        switch git(["merge-base", "--is-ancestor", tip, headOid], in: path, tools: tools).status {
        case 0: return .contained
        case 1: return .notContained
        default: return .unknownCommit
        }
    }

    private static func isObjectID(_ value: String) -> Bool {
        [40, 64].contains(value.count) && value.allSatisfy(\.isHexDigit)
    }
}
