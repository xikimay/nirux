import Foundation

/// The feedback nobody has dealt with yet on a workspace's open pull
/// request (docs/design/pr-feedback-inbox.md): unresolved review threads, and
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
        /// A review that approves.
        var isApproval = false
        /// A review thread whose last comment is ours: answered, waiting on
        /// its reviewer.
        var isAnswered = false

        var isThread: Bool { location != "comment" }
    }

    /// Newest first.
    let items: [Item]

    var humanCount: Int { items.filter { !$0.isBot }.count }
    var botCount: Int { items.filter(\.isBot).count }

    /// The counts, all a card shows of the feedback.
    struct Counts: Hashable, Sendable {
        let humans: Int
        let bots: Int
    }

    var counts: Counts? {
        items.isEmpty ? nil : Counts(humans: humanCount, bots: botCount)
    }

    /// Names the items given, so the agent addresses those and not
    /// whatever else the PR holds.
    static func addressPrompt(for pullRequest: PRInfo, items: [Item]) -> String {
        "/receiving-code-review Address this feedback on PR #\(pullRequest.number) (\(pullRequest.url)): "
            + items.map(\.url).joined(separator: " ")
    }
}

enum PRFeedbackReader {
    /// One call, 1 point of the GraphQL quota.
    private static let query = """
    query($url: URI!) { viewer { login } resource(url: $url) { ... on PullRequest {
      author { login }
      commits(last: 1) { nodes { commit { committedDate } } }
      reviewThreads(last: 100) { nodes { isResolved isOutdated path line comments(first: 1) { nodes {
        author { __typename login } authorAssociation isMinimized body url createdAt } }
        latest: comments(last: 1) { nodes { author { login } } } } }
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
        let host = URL(string: pullRequestURL)?.host ?? GitHub.host
        return ["api", "graphql", "--hostname", host, "-f", "query=\(query)", "-f", "url=\(pullRequestURL)"]
    }

    /// Nil when gh is missing, fails or answers something unreadable.
    static func fetchAsync(
        pullRequestURL: String,
        completion: @escaping @MainActor @Sendable (PRFeedback?) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let output = try? GitHub.CLI.run(.init(arguments(pullRequestURL: pullRequestURL))).flatMap(\.result).get()
            let read = output.flatMap(feedback(from:))
            DispatchQueue.main.async { completion(read) }
        }
    }

    static func feedback(from data: Data) -> PRFeedback? {
        let json = try? JSONSerialization.jsonObject(with: data)
        guard let pullRequest = GitHub.dig(json, "data", "resource"),
              let threads = GitHub.dig(pullRequest, "reviewThreads", "nodes") as? [[String: Any]],
              let comments = GitHub.dig(pullRequest, "comments", "nodes") as? [[String: Any]],
              let reviews = GitHub.dig(pullRequest, "reviews", "nodes") as? [[String: Any]]
        else { return nil }
        let ours = Set([GitHub.dig(pullRequest, "author", "login"), GitHub.dig(json, "data", "viewer", "login")].compactMap { $0 as? String })
        // A pending review is visible to its writer only, and not sent yet.
        let conversation = comments + reviews.filter { $0["state"] as? String != "PENDING" }
        let headCommittedAt = (GitHub.dig(pullRequest, "commits", "nodes") as? [[String: Any]])?.last
            .flatMap { date(GitHub.dig($0, "commit", "committedDate")) }
        // An inline reply comes wrapped in a review with an empty body: it
        // answers its thread, not the conversation.
        let lastReply = conversation
            .filter { login(of: $0).map(ours.contains) == true && !excerpt(of: $0).isEmpty }
            .compactMap { date($0["createdAt"]) }
            .max()
        let cutoff = [headCommittedAt, lastReply].compactMap { $0 }.max() ?? .distantPast

        let threadItems = threads.compactMap { thread -> PRFeedback.Item? in
            guard thread["isResolved"] as? Bool == false,
                  let first = (GitHub.dig(thread, "comments", "nodes") as? [[String: Any]])?.first,
                  counts(first, ours: ours)
            else { return nil }
            let path = thread["path"] as? String ?? ""
            var threadItem = item(
                from: first,
                location: (thread["line"] as? Int).map { "\(path):\($0)" } ?? path,
                isOutdated: thread["isOutdated"] as? Bool ?? false
            )
            let last = (GitHub.dig(thread, "latest", "nodes") as? [[String: Any]])?.last
            threadItem?.isAnswered = last.flatMap(login(of:)).map(ours.contains) == true
            return threadItem
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
            createdAt: createdAt,
            isApproval: node["state"] as? String == "APPROVED"
        )
    }

    private static func excerpt(of node: [String: Any]) -> String {
        let body = node["body"] as? String ?? ""
        return body.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    private static func isBot(_ node: [String: Any]) -> Bool {
        GitHub.dig(node, "author", "__typename") as? String == "Bot"
    }

    private static func login(of node: [String: Any]) -> String? {
        GitHub.dig(node, "author", "login") as? String
    }

    private static func date(_ value: Any?) -> Date? {
        (value as? String).flatMap { try? Date($0, strategy: .iso8601) }
    }
}
