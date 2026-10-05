import Foundation

// MARK: - Comments on the page (section 6.1)

extension BranchReview.Page {
    /// A comment, or the draft of a new one, as the page shows it: under
    /// its rows, or listed with its file when they aren't in the diff.
    struct Comment: Encodable, Equatable, Sendable {
        /// A row as `@pierre/diffs` numbers it: a removed line on
        /// "deletions" by its line in the base, an added or unchanged line
        /// on "additions" by its line in the working tree.
        struct Position: Encodable, Equatable, Sendable {
            let side: String
            let line: Int
        }

        /// A row of the excerpt a comment keeps when its rows aren't in
        /// the diff.
        struct Row: Encodable, Equatable, Sendable {
            let kind: String
            let line: Int
            let text: String
        }

        /// The draft that edits an unsent comment.
        struct Edit: Encodable, Equatable, Sendable {
            let id: String
            let text: String
        }

        let id: String
        /// "draft" (a new comment being written), "unsent" or "sent".
        let state: String
        let text: String
        /// The page's id of its file; nil when its file isn't in the diff.
        let file: Int?
        /// Where it was made, or last found.
        let path: String
        /// On the whole file, not on rows.
        let onFile: Bool
        /// "placed", "outdated", "fileGone", "unread" or "tooLarge"
        /// (`BranchReview.CommentPlacement`).
        let placement: String
        /// Placed on rows: the first and the last. It shows under `end`.
        /// Nil for a comment on the file.
        let start: Position?
        let end: Position?
        /// Not placed: its rows, as they were made or last found.
        let excerpt: [Row]?
        /// An unsent comment's edit under way, the latest typed.
        let edit: Edit?
        /// The head it was last sent at.
        let sentAt: String?
        /// When it was made or last changed, ISO 8601.
        let updated: String
    }
}

extension BranchReview {
    /// Where comments were placed in a set of files, by where they were
    /// made and last found: a review written again for a draft's text
    /// places only what it hadn't. A file read again forgets its own.
    final class PlacementCache {
        fileprivate var located: [PlacementKey: Located] = [:]

        init() {}

        /// Forgets the comments placed, or looked for, in the files at
        /// `paths`: their hunks changed.
        func forget(_ paths: Set<String>) {
            guard !paths.isEmpty else { return }
            located = located.filter { key, found in
                !paths.contains(found.path) && !paths.contains(key.anchor.path) && !paths.contains(key.moved?.path ?? key.anchor.path)
            }
        }

        /// The paths whose comments may be placed otherwise in `new` than
        /// in `old`: of the files that differ, came or went, and the paths
        /// they were renamed from.
        static func changedPaths(from old: [FileChange], to new: [FileChange]) -> Set<String> {
            let before = Dictionary(old.map { ($0.path, $0) }) { first, _ in first }
            let after = Dictionary(new.map { ($0.path, $0) }) { first, _ in first }
            var paths = Set<String>()
            for path in Set(before.keys).union(after.keys) where before[path] != after[path] {
                paths.insert(path)
                paths.formUnion([before[path]?.oldPath, after[path]?.oldPath].compactMap { $0 })
            }
            return paths
        }
    }

    fileprivate struct PlacementKey: Hashable {
        let anchor: CommentAnchor
        let moved: CommentAnchor?
    }

    /// The comments of `record`, and the drafts of new ones, as the page
    /// shows them, looked for in `files` (the snapshot's, its rows read
    /// since included: a file's id is its index). Comments by when they
    /// were made, drafts by when they were last typed in, the oldest first.
    static func pageComments(of record: Record, files: [FileChange], cache: PlacementCache = PlacementCache()) -> [Page.Comment] {
        let ids = Dictionary(files.enumerated().map { ($1.path, $0) }) { first, _ in first }
        // Each file's rows once, whatever the number of its comments.
        var rows: [String: [[DiffRow]]] = [:]
        func locate(_ anchor: CommentAnchor, _ moved: CommentAnchor?) -> Located {
            let key = PlacementKey(anchor: anchor, moved: moved)
            if let known = cache.located[key] { return known }
            let found = locateAnew(anchor, moved)
            cache.located[key] = found
            return found
        }
        func locateAnew(_ anchor: CommentAnchor, _ moved: CommentAnchor?) -> Located {
            guard let file = BranchReview.file(for: anchor, moved: moved, in: files) else {
                return Located(isInFiles: false, path: (moved ?? anchor).path, placement: .fileGone)
            }
            var fileRows: [[DiffRow]]?
            if file.omission == nil {
                fileRows = rows[file.path] ?? diffRows(of: file.hunks)
                rows[file.path] = fileRows
            }
            return Located(isInFiles: true, path: file.path, placement: place(anchor, moved: moved, in: file, rows: fileRows))
        }
        let edits = Dictionary(record.drafts.compactMap { draft in draft.editing.map { ($0, draft) } }) { _, latest in latest }
        var shown: [(sortKey: Date, comment: Page.Comment)] = []
        for comment in record.comments {
            let found = locate(comment.anchor, comment.moved)
            let edit = comment.sent == nil ? edits[comment.id].map { Page.Comment.Edit(id: $0.id, text: $0.text) } : nil
            shown.append((comment.created, pageComment(
                id: comment.id, state: comment.sent == nil ? "unsent" : "sent", text: comment.text, found: found,
                file: found.isInFiles ? ids[found.path] : nil,
                current: comment.current, edit: edit, sentAt: comment.sent.map { String($0.head.prefix(7)) },
                updated: comment.updated
            )))
        }
        for draft in record.drafts {
            guard draft.editing == nil, let anchor = draft.anchor else { continue }
            let found = locate(anchor, draft.moved)
            shown.append((draft.updated, pageComment(
                id: draft.id, state: "draft", text: draft.text, found: found, file: found.isInFiles ? ids[found.path] : nil,
                current: draft.moved ?? anchor, edit: nil,
                sentAt: nil, updated: draft.updated
            )))
        }
        return shown.enumerated().sorted { ($0.element.sortKey, $0.offset) < ($1.element.sortKey, $1.offset) }
            .map(\.element.comment)
    }

    /// Where a comment is: its file (by path, which a new read of the
    /// branch keeps; its id may change), and its placement there.
    fileprivate struct Located {
        let isInFiles: Bool
        let path: String
        let placement: CommentPlacement
    }

    private static func pageComment(
        id: String, state: String, text: String, found: Located, file: Int?,
        current: CommentAnchor, edit: Page.Comment.Edit?, sentAt: String?, updated: Date
    ) -> Page.Comment {
        let position = { (row: DiffRow) in Page.Comment.Position(side: row.side.rawValue, line: row.line) }
        var placed: CommentAnchor?
        if case .placed(let anchor) = found.placement { placed = anchor }
        return Page.Comment(
            id: id, state: state, text: text, file: file, path: placed?.path ?? found.path, onFile: current.isFile,
            placement: found.placement.key,
            start: placed?.rows.first.map(position), end: placed?.rows.last.map(position),
            excerpt: placed == nil && !current.isFile
                ? current.rows.map { Page.Comment.Row(kind: $0.kind.rawValue, line: $0.line, text: $0.text) } : nil,
            edit: edit, sentAt: sentAt, updated: updated.formatted(.iso8601)
        )
    }
}

extension BranchReview.CommentPlacement {
    /// As the page names it.
    var key: String {
        switch self {
        case .placed: return "placed"
        case .outdated: return "outdated"
        case .fileGone: return "fileGone"
        case .unread: return "unread"
        case .tooLarge: return "tooLarge"
        }
    }
}
