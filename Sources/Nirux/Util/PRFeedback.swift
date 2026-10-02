import Foundation

/// The feedback nobody has dealt with yet on a workspace's open pull
/// request (docs/pr-feedback-inbox.md): unresolved review threads, and
/// conversation comments newer than both the head commit and the author's
/// last reply. The author's own comments never count: agents post with
/// the user's `gh` account.
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
    static let query = """
    query($url: URI!) { resource(url: $url) { ... on PullRequest {
      author { login }
      commits(last: 1) { nodes { commit { committedDate } } }
      reviewThreads(first: 100) { nodes { isResolved isOutdated path line
        comments(first: 1) { nodes { author { __typename login } body url createdAt } } } }
      comments(last: 50) { nodes { author { __typename login } body url createdAt } }
      reviews(last: 50) { nodes { state author { __typename login } body url createdAt } }
    } } }
    """

    static func arguments(pullRequestURL: String) -> [String] {
        ["api", "graphql", "--hostname", "github.com", "-f", "query=\(query)", "-f", "url=\(pullRequestURL)"]
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
        guard let pullRequest = dig(try? JSONSerialization.jsonObject(with: data), "data", "resource"),
              let threads = dig(pullRequest, "reviewThreads", "nodes") as? [[String: Any]],
              let comments = dig(pullRequest, "comments", "nodes") as? [[String: Any]],
              let reviews = dig(pullRequest, "reviews", "nodes") as? [[String: Any]]
        else { return nil }
        let pullRequestAuthor = dig(pullRequest, "author", "login") as? String
        // A pending review is visible to its writer only, and not sent yet.
        let conversation = comments + reviews.filter { $0["state"] as? String != "PENDING" }
        let headCommittedAt = (dig(pullRequest, "commits", "nodes") as? [[String: Any]])?.last
            .flatMap { date(dig($0, "commit", "committedDate")) }
        let lastReply = conversation
            .filter { login(of: $0) == pullRequestAuthor }
            .compactMap { date($0["createdAt"]) }
            .max()
        let cutoff = [headCommittedAt, lastReply].compactMap { $0 }.max() ?? .distantPast

        let threadItems = threads.compactMap { thread -> PRFeedback.Item? in
            guard thread["isResolved"] as? Bool == false,
                  let first = (dig(thread, "comments", "nodes") as? [[String: Any]])?.first,
                  login(of: first) != pullRequestAuthor
            else { return nil }
            let path = thread["path"] as? String ?? ""
            return item(
                from: first,
                location: (thread["line"] as? Int).map { "\(path):\($0)" } ?? path,
                isOutdated: thread["isOutdated"] as? Bool ?? false
            )
        }
        let conversationItems = conversation.compactMap { node -> PRFeedback.Item? in
            guard login(of: node) != pullRequestAuthor,
                  let item = item(from: node, location: "comment", isOutdated: false),
                  !item.excerpt.isEmpty,
                  item.createdAt > cutoff
            else { return nil }
            return item
        }
        return PRFeedback(items: (threadItems + conversationItems).sorted { $0.createdAt > $1.createdAt })
    }

    static func addressPrompt(for pullRequest: PRInfo, botsOnly: Bool) -> String {
        let scope = botsOnly ? "the bots' unresolved review threads and new comments" : "the unresolved review threads and new comments"
        return "/receiving-code-review Address \(scope) on PR #\(pullRequest.number) (\(pullRequest.url))."
    }

    private static func item(from node: [String: Any], location: String, isOutdated: Bool) -> PRFeedback.Item? {
        guard let url = node["url"] as? String, let createdAt = date(node["createdAt"]) else { return nil }
        let body = node["body"] as? String ?? ""
        let excerpt = body.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return PRFeedback.Item(
            // A deleted account comes back as a null author.
            author: login(of: node) ?? "ghost",
            isBot: dig(node, "author", "__typename") as? String == "Bot",
            location: location,
            isOutdated: isOutdated,
            excerpt: String(excerpt.prefix(80)),
            url: url,
            createdAt: createdAt
        )
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
