import Foundation

/// Where a repository's pull requests live, whatever branch is checked
/// out: the GitHub repository gh takes as its base. What `gh repo
/// set-default` chose (`remote.<name>.gh-resolved`: that remote, or the
/// repository it names), else the first of upstream, github, origin, then
/// the others by name, as gh sorts them, whose fetch URL is on github.com
/// (or an SSH alias ssh resolves to it). The board's unsaved sections read it and Board Settings
/// suggests it, so saving as suggested keeps what the board showed; the
/// General tab of Space Settings names it.
enum GitHubBaseRemote {
    enum Read: Equatable, Sendable {
        /// `owner/name` as the URL spells it, and the remote it came from.
        case gitHub(repository: String, remote: String)
        /// The repository has no remote.
        case noRemote
        /// No remote is on github.com: the first one's host (nil for a
        /// path), which may be an SSH alias ssh doesn't resolve to it.
        case notGitHub(host: String?, remote: String)
        /// The folder is gone, or no longer in a git repository.
        case notARepository
        /// git, or ssh, didn't answer in time.
        case unread
    }

    /// Two git calls, plus ssh for an SSH host other than github.com (once
    /// it says yes, never again): never on the main thread.
    /// `resolveAlias` says whether an SSH host stands for github.com, nil
    /// when it couldn't tell; tests answer in its place.
    static func read(
        at folder: String,
        gitPath: String = "/usr/bin/git",
        resolveAlias: (String) -> Bool? = { SSHHostAlias.resolve($0) }
    ) -> Read {
        survey(at: folder, gitPath: gitPath, resolveAlias: resolveAlias).read
    }

    /// `read`, and the repository each remote's URL names (github.com, or
    /// an SSH host that may alias it), by lowercased `owner/name`, its
    /// remote as value: a repository saved from another remote than the
    /// base one still finds its checkout. No more processes than `read`.
    static func survey(
        at folder: String,
        gitPath: String = "/usr/bin/git",
        resolveAlias: (String) -> Bool? = { SSHHostAlias.resolve($0) }
    ) -> (read: Read, gitHubRemotes: [String: String]) {
        guard FileManager.default.fileExists(atPath: folder) else { return (.notARepository, [:]) }
        // In English whatever the locale: one of its messages is read below.
        let tools = WorktreeCleanup.Tools(gitPath: gitPath, environment: ["LC_ALL": "C"])
        // The URLs git fetches from: `insteadOf` applied, a remote's first.
        let listing = WorktreeCleanup.git(["remote", "-v"], in: folder, tools: tools, timeout: 10)
        guard listing.status == 0 else {
            // A config git can't read, or a repository of another user's,
            // is no answer: only this is "not a repository".
            return (listing.stderr.contains("not a git repository") ? .notARepository : .unread, [:])
        }
        // What `gh repo set-default` chose: "base", or another repository.
        let resolutions = WorktreeCleanup.git(
            ["config", "--local", "--get-regexp", #"^remote\..*\.gh-resolved$"#], in: folder, tools: tools, timeout: 10
        )
        // 1: none set.
        guard resolutions.status == 0 || resolutions.status == 1 else { return (.unread, [:]) }
        let remotes = Self.remotes(listing: listing.stdout, resolutions: resolutions.stdout)
        var gitHubRemotes: [String: String] = [:]
        for remote in remotes.reversed() {
            if let repository = BoardConfigSuggestions.repositoryName(remoteURL: remote.url) {
                gitHubRemotes[repository.lowercased()] = remote.name
            }
        }
        // An SSH remote on another host may be an alias of github.com
        // (`git@github-work:…`): indexed by owner/name, no ssh asked, as
        // only a repository the user saved is looked up here.
        for remote in remotes.reversed() where BoardConfigSuggestions.isSSH(remote.url) && false {
            if let repository = BoardConfigSuggestions.spelledOwnerAndName(remoteURL: remote.url),
               gitHubRemotes[repository.lowercased()] == nil {
                gitHubRemotes[repository.lowercased()] = remote.name
            }
        }
        guard let first = remotes.first else { return (.noRemote, gitHubRemotes) }
        for remote in remotes {
            switch Self.repository(of: remote.url, resolveAlias: resolveAlias) {
            // A repository gh-resolved names counts on a GitHub remote only,
            // as gh drops remotes on hosts it doesn't know first.
            case .some(.some(let repository)):
                let base = remote.resolvedRepository ?? repository
                gitHubRemotes[base.lowercased()] = remote.name
                return (.gitHub(repository: base, remote: remote.name), gitHubRemotes)
            case .some(.none): continue
            // Not knowing this one, a remote gh ranks lower can't stand in.
            case .none: return (.unread, gitHubRemotes)
            }
        }
        return (.notGitHub(host: GitHubRepository(remoteURL: first.url)?.host, remote: first.name), gitHubRemotes)
    }

    struct Remote: Equatable {
        let name: String
        let url: String
        /// Its `gh-resolved` value, if any.
        var resolution: String?

        /// The repository gh was told to use instead of the remote's URL.
        var resolvedRepository: String? {
            guard let resolution, resolution != "base", BoardConfig.isValidRepository(resolution) else { return nil }
            return resolution
        }
    }

    /// The remotes of `git remote -v` (their fetch URLs), in the order gh
    /// tries them: one with a `gh-resolved` value (from `git config
    /// --get-regexp` output), then upstream, github, origin, then the
    /// others by name.
    static func remotes(listing: String, resolutions: String) -> [Remote] {
        var urls: [String: String] = [:]
        for line in listing.split(separator: "\n") {
            // `name\turl (fetch)`, then ` [blob:none]` in a partial clone.
            guard let tab = line.firstIndex(of: "\t"),
                  let fetch = line.range(of: " (fetch)", range: tab..<line.endIndex),
                  fetch.upperBound == line.endIndex || line[fetch.upperBound...].hasPrefix(" [")
            else { continue }
            let name = String(line[..<tab])
            if urls[name] == nil { urls[name] = String(line[line.index(after: tab)..<fetch.lowerBound]) }
        }
        var resolved: [String: String] = [:]
        for line in resolutions.split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = line[..<space]
            guard key.hasPrefix("remote."), key.hasSuffix(".gh-resolved") else { continue }
            let name = String(key.dropFirst("remote.".count).dropLast(".gh-resolved".count))
            resolved[name] = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
        }
        let rank = { (name: String) -> Int in
            if resolved[name] != nil { return 4 }
            switch name.lowercased() {
            case "upstream": return 3
            case "github": return 2
            case "origin": return 1
            default: return 0
            }
        }
        return urls.map { Remote(name: $0.key, url: $0.value, resolution: resolved[$0.key]) }
            .sorted { (rank($0.name), $1.name) > (rank($1.name), $0.name) }
    }

    /// `owner/name` when `url` is a github.com repository; `.some(nil)`
    /// when it isn't; nil when ssh couldn't tell for an alias.
    private static func repository(of url: String, resolveAlias: (String) -> Bool?) -> String?? {
        guard let parsed = GitHubRepository(remoteURL: url) else { return .some(nil) }
        if parsed.host != "github.com" {
            guard BoardConfigSuggestions.isSSH(url) else { return .some(nil) }
            switch resolveAlias(parsed.host) {
            case nil: return nil
            case false?: return .some(nil)
            case true?: break
            }
        }
        return .some(BoardConfigSuggestions.spelledOwnerAndName(remoteURL: url))
    }
}
