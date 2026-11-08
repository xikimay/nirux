import Foundation

/// The repositories a space's board shows (docs/spaces.md, S12): one
/// section per git anchor, default first, each with its config from
/// board.json; folder anchors don't appear. A space without a repository
/// anchor (General, a space made before anchors) has one section, as before:
/// the file's one config, its repository found by remote.
///
/// Schema 1's one config (`.legacy`) goes to the anchor whose remotes name
/// its repository, else to the default repository anchor; only anchors
/// without a config of their own take it. Saving keeps schema 1 while the
/// file holds one config that rule gives back to the same anchor, so an
/// older Nirux keeps using it.
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
    static func legacyAnchor(for config: BoardConfig, entries: [Entry], context: Context) -> SpaceAnchor? {
        let taken = Set(entries.compactMap { entry -> String? in
            if case .anchor(let commonDir) = entry.slot { return commonDir }
            return nil
        })
        let free = repositoryAnchors(context.anchors).filter { anchor in
            commonDir(of: anchor).map { !taken.contains($0) } ?? false
        }
        if let repository = config.gitHubRepository,
           let named = free.first(where: { anchor in
               let remotes = commonDir(of: anchor).flatMap { context.remotes[$0] } ?? []
               return remotes.contains { $0.owner == repository.owner && $0.name == repository.name }
           }) {
            return named
        }
        return free.first
    }

    /// What to write when `config` is saved as `section`'s: the other
    /// configs as read, schema 1's own placed explicitly once another
    /// joins it, and schema 1 again when one config is left that the rule
    /// gives back to its anchor. While some anchor's remotes couldn't be
    /// read, nothing is placed for good: schema 1's config keeps no anchor.
    static func entries(saving config: BoardConfig, as section: Section, in entries: [Entry], context: Context) -> [Entry] {
        let isPlacing = context.unread.isEmpty
        let target: Slot = section.slot == .legacy && !isPlacing ? .legacy : section.commonDir.map { .anchor(commonDir: $0) } ?? .legacy
        var result = entries.map { entry -> Entry in
            // Placed where it shows now, before the new config changes that.
            guard isPlacing, entry.slot == .legacy,
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
        guard isPlacing, result.count == 1, case .anchor(let commonDir) = result[0].slot else { return result }
        let placed = legacyAnchor(for: config, entries: [], context: context)
        return placed.flatMap(Self.commonDir(of:)) == commonDir ? [Entry(slot: .legacy, config: config)] : result
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
