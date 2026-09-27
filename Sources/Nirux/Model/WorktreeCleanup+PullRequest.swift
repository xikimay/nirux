import Foundation

// MARK: - Pull request

extension WorktreeCleanup {
    enum Ancestry: Equatable {
        case contained
        case notContained
        /// The commit isn't in the local repository.
        case unknownCommit
    }

    static func pullRequestLookup(
        branch: String, tip: String, worktree: Worktree, tools: Tools
    ) -> (pullRequest: PullRequest?, problems: [String]) {
        guard let ghPath = tools.ghPath else {
            return (nil, ["The GitHub CLI (gh) isn't installed: the pull request can't be checked."])
        }
        let repository: GitHubRepository
        switch headRepository(branch: branch, at: worktree.path, tools: tools) {
        case .success(let found): repository = found
        case .failure(let failure): return (nil, [failure.message])
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
            return (nil, ["gh couldn't list the pull requests of \(branch)\(reason)"])
        }
        let candidates = json.compactMap { pullRequest(from: $0, headRepository: repository) }
        return verdict(branch: branch, tip: tip, candidates: candidates) { headOid in
            ancestry(of: tip, in: headOid, at: worktree.path, tools: tools)
        }
    }

    /// Which pull request the branch belongs to, and why it can't be
    /// cleaned up if so. An open pull request blocks: the branch is still
    /// in use. Otherwise a merged one must contain the tip.
    static func verdict(
        branch: String,
        tip: String,
        candidates: [PullRequest],
        ancestry: (String) -> Ancestry
    ) -> (pullRequest: PullRequest?, problems: [String]) {
        let sorted = candidates.sorted { $0.number > $1.number }
        if let open = sorted.first(where: { $0.state == "OPEN" }) {
            return (open, ["Pull request #\(open.number) for \(branch) is still open."])
        }
        let merged = sorted.filter { $0.state == "MERGED" }
        guard let latest = merged.first else {
            if let closed = sorted.first {
                return (closed, ["Pull request #\(closed.number) was closed without being merged."])
            }
            return (nil, ["No pull request found for \(branch)."])
        }
        if let exact = merged.first(where: { $0.headOid == tip }) {
            return (exact, [])
        }
        var unknown: PullRequest?
        for pullRequest in merged {
            switch ancestry(pullRequest.headOid) {
            case .contained: return (pullRequest, [])
            case .unknownCommit: unknown = unknown ?? pullRequest
            case .notContained: continue
            }
        }
        if let unknown {
            return (unknown, [
                "The head of merged pull request #\(unknown.number) (\(short(unknown.headOid))) isn't in "
                    + "the local repository, so \(branch) can't be compared with it. A git fetch may bring it in."
            ])
        }
        return (latest, [
            "\(branch) has commits that aren't in merged pull request #\(latest.number) "
                + "(local \(short(tip)), merged head \(short(latest.headOid)))."
        ])
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
