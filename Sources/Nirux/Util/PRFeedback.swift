import Foundation

/// The feedback nobody has dealt with yet on a workspace's open pull
/// request (docs/pr-feedback-inbox.md): unresolved review threads, and
/// conversation comments newer than both the head commit and our last
/// reply. "Our" is the PR's author and the `gh` user: agents post with
/// that account, so their comments never count.
struct PRFeedback: Hashable, Sendable {
    struct Item: Hashable, Sendable {
        let author: String
        let isBot: Bool
        /// `path:line` for a review thread, "comment" for the rest.
        let location: String
        let isOutdated: Bool
        /// First line of the body.
        let excerpt: String
        let url: String
        let createdAt: Date
    }

    /// Newest first.
    let items: [Item]

    var humanCount: Int { items.filter { !$0.isBot }.count }
    var botCount: Int { items.filter(\.isBot).count }

    /// The card line, "💬 2 · 🤖 3", humans first; either half hidden at
    /// zero, nil when both are.
    var summary: String? {
        let parts = [("💬", humanCount), ("🤖", botCount)]
            .filter { $0.1 > 0 }
            .map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum PRFeedbackReader {
    /// One call, 1 point of the GraphQL quota.
    private static let query = """
    query($url: URI!) { viewer { login } resource(url: $url) { ... on PullRequest {
      author { login }
      commits(last: 1) { nodes { commit { committedDate } } }
      reviewThreads(first: 100) { nodes { isResolved isOutdated path line comments(first: 1) { nodes {
        author { __typename login } authorAssociation isMinimized body url createdAt } } } }
      comments(last: 50) { nodes { author { __typename login } authorAssociation isMinimized body url createdAt } }
      reviews(last: 50) { nodes { state author { __typename login } authorAssociation isMinimized body url createdAt } }
    } } }
    """

    /// Anyone can comment on a public repository, and Address hands what
    /// counts to an agent: only people with a role on the repository, and
    /// apps someone installed there, count.
    private static let trustedAssociations: Set<String> = ["OWNER", "MEMBER", "COLLABORATOR"]

    /// The PR's own host: an Enterprise PR is never sent to github.com.
    static func arguments(pullRequestURL: String) -> [String] {
        let host = URL(string: pullRequestURL)?.host ?? "github.com"
        return ["api", "graphql", "--hostname", host, "-f", "query=\(query)", "-f", "url=\(pullRequestURL)"]
    }

    /// Nil when gh is missing, fails or answers something unreadable.
    static func fetchAsync(
        pullRequestURL: String,
        completion: @escaping @MainActor @Sendable (PRFeedback?) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let result = PRDetect.installedGHPath().flatMap {
                GitHubCLIBoardClient.runGH($0, arguments: arguments(pullRequestURL: pullRequestURL), timeout: 30)
            }
            let read = result.flatMap { $0.terminationStatus == 0 ? feedback(from: $0.standardOutput) : nil }
            DispatchQueue.main.async { completion(read) }
        }
    }

    static func feedback(from data: Data) -> PRFeedback? {
        let json = try? JSONSerialization.jsonObject(with: data)
        guard let pullRequest = dig(json, "data", "resource"),
              let threads = dig(pullRequest, "reviewThreads", "nodes") as? [[String: Any]],
              let comments = dig(pullRequest, "comments", "nodes") as? [[String: Any]],
              let reviews = dig(pullRequest, "reviews", "nodes") as? [[String: Any]]
        else { return nil }
        let ours = Set([dig(pullRequest, "author", "login"), dig(json, "data", "viewer", "login")].compactMap { $0 as? String })
        // A pending review is visible to its writer only, and not sent yet.
        let conversation = comments + reviews.filter { $0["state"] as? String != "PENDING" }
        let headCommittedAt = (dig(pullRequest, "commits", "nodes") as? [[String: Any]])?.last
            .flatMap { date(dig($0, "commit", "committedDate")) }
        // An inline reply comes wrapped in a review with an empty body: it
        // answers its thread, not the conversation.
        let lastReply = conversation
            .filter { login(of: $0).map(ours.contains) == true && !excerpt(of: $0).isEmpty }
            .compactMap { date($0["createdAt"]) }
            .max()
        let cutoff = [headCommittedAt, lastReply].compactMap { $0 }.max() ?? .distantPast

        let threadItems = threads.compactMap { thread -> PRFeedback.Item? in
            guard thread["isResolved"] as? Bool == false,
                  let first = (dig(thread, "comments", "nodes") as? [[String: Any]])?.first,
                  counts(first, ours: ours)
            else { return nil }
            let path = thread["path"] as? String ?? ""
            return item(
                from: first,
                location: (thread["line"] as? Int).map { "\(path):\($0)" } ?? path,
                isOutdated: thread["isOutdated"] as? Bool ?? false
            )
        }
        let conversationItems = conversation.compactMap { node -> PRFeedback.Item? in
            guard counts(node, ours: ours),
                  let item = item(from: node, location: "comment", isOutdated: false),
                  !item.excerpt.isEmpty,
                  item.createdAt > cutoff
            else { return nil }
            return item
        }
        return PRFeedback(items: (threadItems + conversationItems).sorted { $0.createdAt > $1.createdAt })
    }

    /// Not ours, not hidden by a maintainer, and from a bot or a role.
    private static func counts(_ node: [String: Any], ours: Set<String>) -> Bool {
        guard login(of: node).map(ours.contains) != true, node["isMinimized"] as? Bool != true else { return false }
        return isBot(node) || trustedAssociations.contains(node["authorAssociation"] as? String ?? "")
    }

    private static func item(from node: [String: Any], location: String, isOutdated: Bool) -> PRFeedback.Item? {
        guard let url = node["url"] as? String, let createdAt = date(node["createdAt"]) else { return nil }
        return PRFeedback.Item(
            // A deleted account comes back as a null author.
            author: login(of: node) ?? "ghost",
            isBot: isBot(node),
            location: location,
            isOutdated: isOutdated,
            excerpt: String(excerpt(of: node).prefix(80)),
            url: url,
            createdAt: createdAt
        )
    }

    private static func excerpt(of node: [String: Any]) -> String {
        let body = node["body"] as? String ?? ""
        return body.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    private static func isBot(_ node: [String: Any]) -> Bool {
        dig(node, "author", "__typename") as? String == "Bot"
    }

    private static func login(of node: [String: Any]) -> String? {
        dig(node, "author", "login") as? String
    }

    private static func date(_ value: Any?) -> Date? {
        (value as? String).flatMap { try? Date($0, strategy: .iso8601) }
    }

    private static func dig(_ json: Any?, _ path: String...) -> Any? {
        path.reduce(json) { value, key in (value as? [String: Any])?[key] }
    }
}
