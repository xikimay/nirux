import Foundation

/// What the nightlies brought, one entry per pull request that landed on
/// main. The nightly publishes it next to the appcast; Nirux shows the
/// entries between the build it ran before and the one it runs or installs.
public struct Changelog: Codable, Equatable, Sendable {
    /// Newest build first; in a build, by kind, then by pull request.
    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case new, better, fixed, `internal`

        public var label: String {
            switch self {
            case .new: "New"
            case .better: "Better"
            case .fixed: "Fixed"
            case .internal: "Under the hood"
            }
        }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var pullRequest: Int
        public var title: String
        public var why: String?
        public var kind: Kind
        /// The nightly that shipped it, by its build number: the UTC minute
        /// it was built, as `CFBundleVersion` holds it (202611251854).
        public var build: Int

        public init(pullRequest: Int, title: String, why: String?, kind: Kind, build: Int) {
            self.pullRequest = pullRequest
            self.title = title
            self.why = why
            self.kind = kind
            self.build = build
        }
    }

    public static let keptDays = 90
    static let maxTitleLength = 200
    static let maxWhyLength = 300
    /// Branch types whose work nobody sees in the app.
    static let internalBranchTypes: Set<String> = ["test", "ci", "refactor", "chore", "dependabot"]
    /// Where the files the app ships from live.
    static let shippedFolders = ["Sources/", "NiruxCore/Sources/", "Resources/"]

    /// A label wins; otherwise a branch type or files outside the app make
    /// it internal, a `fix/` branch a fix, and anything else an improvement.
    public static func kind(branch: String, labels: Set<String>, paths: [String]) -> Kind {
        if labels.contains(Kind.internal.rawValue) { return .internal }
        if labels.contains(Kind.new.rawValue) { return .new }
        let type = branch.firstIndex(of: "/").map { String(branch[..<$0]) } ?? ""
        let shipsNothing = !paths.isEmpty && !paths.contains { path in shippedFolders.contains { path.hasPrefix($0) } }
        if internalBranchTypes.contains(type) || shipsNothing { return .internal }
        return type == "fix" ? .fixed : .better
    }

    /// The entries shipped after `previous` up to `current`.
    public func entries(after previous: Int, through current: Int) -> [Entry] {
        entries.filter { $0.build > previous && $0.build <= current }
    }

    /// The entries holding every word of `query` in their title, their Why
    /// or their "#number", ignoring case and accents.
    public func entries(matching query: String) -> [Entry] {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let text = "\(entry.title) \(entry.why ?? "") #\(entry.pullRequest)"
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// With `added` replacing the entries of the same pull requests, and
    /// without the builds before `oldest`.
    public func adding(_ added: [Entry], keepingBuildsFrom oldest: Int) -> Changelog {
        let replaced = Set(added.map(\.pullRequest))
        let kept = entries.filter { !replaced.contains($0.pullRequest) } + added
        return Changelog(entries: kept.filter { $0.build >= oldest }.sorted(by: Self.isOrderedBefore))
    }

    static func isOrderedBefore(_ a: Entry, _ b: Entry) -> Bool {
        if a.build != b.build { return a.build > b.build }
        if a.kind != b.kind { return Kind.allCases.firstIndex(of: a.kind)! < Kind.allCases.firstIndex(of: b.kind)! }
        return a.pullRequest < b.pullRequest
    }

    // MARK: - Builds

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// When the nightly numbered `build` was built; nil for a number that
    /// isn't a yyyyMMddHHmm minute.
    public static func date(ofBuild build: Int) -> Date? {
        let parts = DateComponents(
            year: build / 100_000_000, month: build / 1_000_000 % 100, day: build / 10_000 % 100,
            hour: build / 100 % 100, minute: build % 100
        )
        guard (1_000...9_999).contains(parts.year!), parts.isValidDate(in: utc) else { return nil }
        return utc.date(from: parts)
    }

    public static func build(at date: Date) -> Int {
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return [parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!].reduce(0) { $0 * 100 + $1 }
    }

    // MARK: - From GitHub

    private struct PullRequest: Decodable {
        struct Name: Decodable { let name: String }
        struct File: Decodable { let path: String }
        struct Commit: Decodable { let oid: String }
        let number: Int
        let title: String
        let body: String?
        let headRefName: String
        let labels: [Name]?
        let files: [File]?
        let mergeCommit: Commit?
    }

    /// The entries of the pull requests in `gh pr list --json
    /// number,title,body,headRefName,labels,files,mergeCommit` whose merge
    /// commit is one of `commits`. A merge train counts through the pull
    /// requests it carries, never itself. Nil when `data` isn't such a list.
    public static func entries(fromPullRequests data: Data, commits: Set<String>, build: Int) -> [Entry]? {
        guard let pulls = try? JSONDecoder().decode([PullRequest].self, from: data) else { return nil }
        return pulls.compactMap { pull in
            guard let merge = pull.mergeCommit?.oid, commits.contains(merge),
                  !pull.headRefName.hasPrefix(MergeTrain.branchPrefix)
            else { return nil }
            return Entry(
                pullRequest: pull.number,
                title: AgentText.clean(pull.title, maxLength: maxTitleLength) ?? "#\(pull.number)",
                why: PullRequestBody.why(pull.body ?? "", maxLength: maxWhyLength),
                kind: kind(branch: pull.headRefName, labels: Set((pull.labels ?? []).map(\.name)), paths: (pull.files ?? []).map(\.path)),
                build: build
            )
        }.sorted(by: isOrderedBefore)
    }

    /// A release body's list of what `build` brought, grouped, with the
    /// internal work folded.
    public func releaseNotes(build: Int) -> String {
        let shipped = entries.filter { $0.build == build }
        guard !shipped.isEmpty else { return "No pull request landed since the previous nightly." }
        return Kind.allCases.compactMap { kind -> String? in
            let lines = shipped.filter { $0.kind == kind }.map { "- \($0.title) (#\($0.pullRequest))" }
            guard !lines.isEmpty else { return nil }
            let list = lines.joined(separator: "\n")
            return kind == .internal
                ? "<details><summary>\(kind.label) (\(lines.count))</summary>\n\n\(list)\n\n</details>"
                : "### \(kind.label)\n\(list)"
        }.joined(separator: "\n\n")
    }
}
