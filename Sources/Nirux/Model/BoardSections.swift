import Foundation

/// The repositories a space's board shows (docs/spaces.md, S12): one
/// section per git anchor, default first, each with its config from
/// board.json; folder anchors don't appear. A space without a repository
/// anchor (General, a space made before anchors) has one section, as before:
/// the file's one config, its repository found by remote.
///
/// Schema 1's one config (`.legacy`) goes to the anchor whose remotes name
/// its repository, else to the default repository anchor; only anchors
/// without a config of their own take it, and none when the anchor that
/// names it has its own. Saving keeps schema 1 while the file holds one
/// config, the default repository's, that rule gives back to it: an older
/// Nirux, which reads schema 1 as the default repository's, keeps using it.
enum BoardSections {
    typealias Slot = BoardConfigStore.Slot
    typealias Entry = BoardConfigStore.Entry

    struct Section: Equatable, Sendable {
        /// Where its config sits in the file, or will once saved.
        let slot: Slot
        /// Nil: the space has no repository anchor.
        let anchor: SpaceAnchor?
        /// Nil: not configured yet.
        let config: BoardConfig?

        /// Stable while the anchor stays: the board keeps what it read
        /// for it, and the queue line and settings name it.
        var id: String { anchor?.key ?? "legacy" }

        /// The anchor's name, "x-front"; nil without an anchor.
        var name: String? { anchor?.name }

        /// The anchor's common git dir.
        var commonDir: String? { anchor.flatMap(BoardSections.commonDir(of:)) }

        /// Where its worktrees are listed and its settings suggested: the
        /// main checkout, else (a bare repository) the git dir. Nil without
        /// an anchor.
        var checkoutFolder: String? { anchor?.folder ?? commonDir }
    }

    /// Each section's name, by id: the anchor's, with its folder when two
    /// share one ("app (~/a/app)").
    static func displayNames(_ sections: [Section]) -> [String: String] {
        let names = sections.map { $0.name ?? "Repository" }
        var result: [String: String] = [:]
        for (section, name) in zip(sections, names) {
            let isShared = names.filter { $0 == name }.count > 1
            let folder = section.checkoutFolder.map { ($0 as NSString).abbreviatingWithTildeInPath }
            result[section.id] = isShared && folder != nil ? "\(name) (\(folder ?? ""))" : name
        }
        return result
    }

    /// What placing the configs needs besides the file: the space's anchors
    /// and the GitHub repositories each repository anchor's remotes name.
    struct Context: Equatable, Sendable {
        var anchors: [SpaceAnchor] = []
        /// By common git dir.
        var remotes: [String: [GitHubRepository]] = [:]
        /// Repository anchors whose remotes git couldn't read (a volume not
        /// mounted, a timeout): placing schema 1's config may be wrong.
        var unread: Set<String> = []
        /// The `origin` of each repository anchor board.json has no config
        /// for, by common git dir (`readOrigins`).
        var origins: [String: Origin] = [:]
    }

    /// What a repository anchor's `origin` remote says. While board.json
    /// has no config for the anchor, its section shows that repository's
    /// pull requests read-only: nothing is saved, and its merge queue
    /// waits for Board Settings.
    enum Origin: Equatable, Sendable {
        /// On github.com: `owner/name` as the URL spells it, and the branch
        /// `origin/HEAD` points to, when it is known.
        case gitHub(repository: String, baseBranch: String?)
        /// No remote named origin.
        case missing
        /// origin points elsewhere than github.com: another host (an SSH
        /// alias too), or nil for a path.
        case notGitHub(host: String?)
        /// git couldn't read it: a volume not mounted, a timeout.
        case unread
    }

    /// The `origin` of each section's anchor that has no config of its
    /// own, by common git dir: its push URL, as Board Settings suggests it.
    /// Runs git, 10 s at most each: call it off the main thread.
    static func readOrigins(_ sections: [Section], tools: WorktreeCleanup.Tools = .installed) -> [String: Origin] {
        var origins: [String: Origin] = [:]
        for section in sections where section.config == nil {
            guard let commonDir = section.commonDir, origins[commonDir] == nil else { continue }
            let url = WorktreeCleanup.git(["remote", "get-url", "--push", "--", "origin"], in: commonDir, tools: tools, timeout: 10)
            switch url.status {
            case 0:
                guard let repository = BoardConfigSuggestions.repositoryName(remoteURL: url.stdout) else {
                    origins[commonDir] = .notGitHub(host: nil)
                    continue
                }
                let baseBranch = BoardConfigSuggestions.defaultBranch(of: "origin", at: commonDir, gitPath: tools.gitPath)
                origins[commonDir] = .gitHub(repository: repository, baseBranch: baseBranch)
            // git remote's own status for a remote that doesn't exist.
            case 2: origins[commonDir] = .missing
            default: origins[commonDir] = .unread
            }
        }
        return origins
    }

    /// The space's repository anchors, the default one first, then in the
    /// space's order.
    static func repositoryAnchors(_ anchors: [SpaceAnchor]) -> [SpaceAnchor] {
        let repositories = anchors.filter {
            if case .gitRepository = $0.kind { return true }
            return false
        }
        let defaultKey = (repositories.first { $0.isDefault } ?? repositories.first)?.key
        return repositories.filter { $0.key == defaultKey } + repositories.filter { $0.key != defaultKey }
    }

    static func sections(_ entries: [Entry], context: Context) -> [Section] {
        let anchors = repositoryAnchors(context.anchors)
        let legacy = entries.first { $0.slot == .legacy }?.config
        guard !anchors.isEmpty else {
            return [Section(slot: .legacy, anchor: nil, config: legacy)]
        }
        let owner = legacy.flatMap { legacyAnchor(for: $0, entries: entries, context: context) }
        return anchors.map { anchor in
            let commonDir = Self.commonDir(of: anchor) ?? ""
            if let own = entries.first(where: { $0.slot == .anchor(commonDir: commonDir) }) {
                return Section(slot: own.slot, anchor: anchor, config: own.config)
            }
            if anchor.key == owner?.key, let legacy {
                return Section(slot: .legacy, anchor: anchor, config: legacy)
            }
            return Section(slot: .anchor(commonDir: commonDir), anchor: anchor, config: nil)
        }
    }

    /// The anchor schema 1's config belongs to, among repository anchors
    /// without a config of their own: one whose remotes name its repository
    /// (the default first), else the default one, else the first free one.
    /// None when only anchors with a config of their own name it: it was
    /// theirs, and no other anchor's.
    static func legacyAnchor(for config: BoardConfig, entries: [Entry], context: Context) -> SpaceAnchor? {
        let taken = Set(entries.compactMap { entry -> String? in
            if case .anchor(let commonDir) = entry.slot { return commonDir }
            return nil
        })
        let anchors = repositoryAnchors(context.anchors)
        let isFree = { (anchor: SpaceAnchor) in commonDir(of: anchor).map { !taken.contains($0) } ?? false }
        let named = config.gitHubRepository.map { repository in
            anchors.filter { anchor in
                let remotes = commonDir(of: anchor).flatMap { context.remotes[$0] } ?? []
                return remotes.contains { $0.owner == repository.owner && $0.name == repository.name }
            }
        } ?? []
        if !named.isEmpty { return named.first(where: isFree) }
        return anchors.first(where: isFree)
    }

    /// What to write when `config` is saved as `section`'s: the other
    /// configs as read, schema 1's own placed explicitly once another
    /// joins it, and schema 1 again when one config is left that the rule
    /// gives back to its anchor; not while some anchor's remotes couldn't
    /// be read. Callers refuse to save schema 1's config then (Board
    /// Settings does): where it belongs rests on every anchor's remotes.
    static func entries(saving config: BoardConfig, as section: Section, in entries: [Entry], context: Context) -> [Entry] {
        let target: Slot = section.commonDir.map { .anchor(commonDir: $0) } ?? .legacy
        var result = entries.map { entry -> Entry in
            // Placed where it shows now, before the new config changes that.
            guard entry.slot == .legacy,
                  let anchor = legacyAnchor(for: entry.config, entries: entries, context: context),
                  let commonDir = commonDir(of: anchor)
            else { return entry }
            return Entry(slot: .anchor(commonDir: commonDir), config: entry.config)
        }
        if let index = result.firstIndex(where: { $0.slot == target }) {
            result[index].config = config
        } else {
            result.append(Entry(slot: target, config: config))
        }
        // Schema 1 only for the default repository, which is how an older
        // Nirux reads it (its tasks take the board's base branch there).
        guard context.unread.isEmpty, result.count == 1, case .anchor(let commonDir) = result[0].slot,
              let defaultRepository = repositoryAnchors(context.anchors).first,
              Self.commonDir(of: defaultRepository) == commonDir,
              legacyAnchor(for: config, entries: [], context: context)?.key == defaultRepository.key
        else { return result }
        return [Entry(slot: .legacy, config: config)]
    }

    static func commonDir(of anchor: SpaceAnchor) -> String? {
        guard case .gitRepository(let commonDir) = anchor.kind else { return nil }
        return commonDir
    }

    /// Each repository anchor's GitHub remotes (`git remote -v` in its git
    /// dir). Runs git: call it off the main thread.
    static func readContext(anchors: [SpaceAnchor], tools: WorktreeCleanup.Tools = .installed) -> Context {
        var context = Context(anchors: anchors)
        for anchor in repositoryAnchors(anchors) {
            guard let commonDir = commonDir(of: anchor) else { continue }
            let remotes = WorktreeCleanup.git(["remote", "-v"], in: commonDir, tools: tools)
            if remotes.status == 0 {
                context.remotes[commonDir] = ProjectBoard.parseRemotes(remotes.stdout)
            } else {
                context.unread.insert(commonDir)
            }
        }
        return context
    }
}
