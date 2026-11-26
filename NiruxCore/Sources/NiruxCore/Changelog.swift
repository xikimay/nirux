import Foundation

/// What the nightlies brought, one entry per pull request that landed on
/// main. The nightly publishes it next to the appcast; Nirux shows the
/// entries between the build it ran before and the one it runs or installs.
public struct Changelog: Codable, Equatable, Sendable {
    /// Newest build first; in a build, by kind, then by pull request.
    public var entries: [Entry]
    /// The commit of main the entries reach: the next nightly adds what
    /// landed after it, even when the nightly before it failed to.
    public var commit: String?

    public init(entries: [Entry] = [], commit: String? = nil) {
        self.entries = entries
        self.commit = commit
    }

    enum CodingKeys: String, CodingKey { case entries, commit }

    /// Leaves out the entries this version can't read, so a file a newer
    /// nightly wrote still opens.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([Readable<Entry>].self, forKey: .entries).compactMap(\.value)
        commit = try container.decodeIfPresent(String.self, forKey: .commit)
    }

    private struct Readable<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) {
            value = try? Value(from: decoder)
        }
    }

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case new, better, fixed, `internal`

        /// A kind added after this version reads as an improvement.
        public init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .better
        }

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
    /// What the app is built from.
    static let shippedPaths = ["Sources/", "NiruxCore/Sources/", "Resources/", "Package.swift", "Package.resolved", "NiruxCore/Package.swift", "scripts/bundle.sh"]

    /// A label named after a kind wins, `internal` first; otherwise a
    /// branch type or files outside the app make it internal, a `fix/`
    /// branch a fix, and anything else an improvement.
    public static func kind(branch: String, labels: Set<String>, paths: [String]) -> Kind {
        if let labelled = [Kind.internal, .new, .fixed, .better].first(where: { labels.contains($0.rawValue) }) { return labelled }
        let type = branch.firstIndex(of: "/").map { String(branch[..<$0]) } ?? ""
        let shipsNothing = !paths.isEmpty && !paths.contains { path in shippedPaths.contains { path.hasPrefix($0) } }
        if internalBranchTypes.contains(type) || shipsNothing { return .internal }
        return type == "fix" ? .fixed : .better
    }

    /// The entries shipped after `previous` up to `current`.
    public func entries(after previous: Int, through current: Int) -> [Entry] {
        entries.filter { $0.build > previous && $0.build <= current }
    }

    /// What a nightly brought, as a changelog shows it.
    public struct Nightly: Equatable, Sendable {
        public var build: Int
        public var entries: [Entry]

        public init(build: Int, entries: [Entry]) {
            self.build = build
            self.entries = entries
        }
    }

    /// The entries matching `query`, by nightly, newest first; the internal
    /// work only when asked.
    public func nightlies(matching query: String, includingInternal: Bool) -> [Nightly] {
        let shown = entries(matching: query).filter { includingInternal || $0.kind != .internal }
        return shown.reduce(into: [Nightly]()) { nightlies, entry in
            if nightlies.last?.build == entry.build {
                nightlies[nightlies.count - 1].entries.append(entry)
            } else {
                nightlies.append(Nightly(build: entry.build, entries: [entry]))
            }
        }
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
    public func adding(_ added: [Entry], through commit: String, keepingBuildsFrom oldest: Int) -> Changelog {
        let replaced = Set(added.map(\.pullRequest))
        let kept = entries.filter { !replaced.contains($0.pullRequest) } + added
        return Changelog(entries: kept.filter { $0.build >= oldest }.sorted(by: Self.isOrderedBefore), commit: commit)
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

    /// "Nov 25, 19:54" where the nightly was built at 18:54 UTC and the clock
    /// reads Paris time; "Build 42" for a number that isn't a minute.
    public static func name(ofBuild build: Int, in timeZone: TimeZone = .current) -> String {
        guard let date = date(ofBuild: build) else { return "Build \(build)" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
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
            let lines = shipped.filter { $0.kind == kind }.map { "- \(Self.literal($0.title)) (#\($0.pullRequest))" }
            guard !lines.isEmpty else { return nil }
            let list = lines.joined(separator: "\n")
            return kind == .internal
                ? "<details><summary>\(kind.label) (\(lines.count))</summary>\n\n\(list)\n\n</details>"
                : "### \(kind.label)\n\(list)"
        }.joined(separator: "\n\n")
    }

    /// A title GitHub shows as written, never as HTML.
    static func literal(_ title: String) -> String {
        title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
