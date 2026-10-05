import CryptoKit
import Foundation

// MARK: - Comments (sections 6.1 and 8)

extension BranchReview {
    /// The side of a row in the page's unified diff, as `@pierre/diffs`
    /// names it: a removed line is on `deletions`, an added line or a
    /// context line on `additions`.
    enum DiffSide: String, Equatable, Sendable {
        case deletions
        case additions
    }

    /// A row of a file's diff, where the page's gutter button and line
    /// selection point.
    struct DiffPosition: Equatable, Sendable {
        let side: DiffSide
        let line: Int
    }

    /// One row of a file's diff as the page shows it.
    struct DiffRow: Equatable, Sendable {
        enum Kind: String, Equatable, Sendable {
            case context
            case added
            case removed
        }

        let kind: Kind
        /// Where it is in the base's file and in the working tree's: both
        /// for a context line; for a removed line `new` is the line it
        /// comes before, and for an added line `old`.
        let old: Int
        let new: Int
        /// Cut as `CommentAnchor.cut` cuts it. A line that isn't UTF-8
        /// reads with U+FFFD where it isn't, and compares so.
        let text: String
        /// When `text` was cut, a hash of the whole line, so that a change
        /// past the cut tells.
        let digest: String?

        init(kind: Kind, old: Int, new: Int, text: String, digest: String? = nil) {
            self.kind = kind
            self.old = old
            self.new = new
            self.text = text
            self.digest = digest
        }

        /// The row of a line of `text`, cut, and hashed if it was.
        init(kind: Kind, old: Int, new: Int, line text: String) {
            let cut = CommentAnchor.cut(text)
            self.init(kind: kind, old: old, new: new, text: cut, digest: cut == text ? nil : Self.digest(of: text))
        }

        static func digest(of text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        }

        /// As the page numbers it.
        var line: Int { kind == .removed ? old : new }
        var side: DiffSide { kind == .removed ? .deletions : .additions }
        var position: DiffPosition { DiffPosition(side: side, line: line) }

        /// The same line, wherever it is.
        func reads(as other: DiffRow) -> Bool {
            kind == other.kind && text == other.text && digest == other.digest
        }
    }

    /// The rows of each hunk, in the order the page shows them. A "no
    /// newline" marker isn't a row.
    static func diffRows(of hunks: [Hunk]) -> [[DiffRow]] {
        hunks.map { hunk in
            var old = hunk.oldStart
            var new = hunk.newStart
            var rows: [DiffRow] = []
            for line in hunk.lines {
                switch line.kind {
                case .context:
                    rows.append(DiffRow(kind: .context, old: old, new: new, line: line.text))
                    old += 1
                    new += 1
                case .removed:
                    rows.append(DiffRow(kind: .removed, old: old, new: new, line: line.text))
                    old += 1
                case .added:
                    rows.append(DiffRow(kind: .added, old: old, new: new, line: line.text))
                    new += 1
                case .noNewlineMarker:
                    break
                }
            }
            return rows
        }
    }

    /// What a comment is about: a whole file, or rows of one hunk of its
    /// diff, with what is around them, which say whether they are still
    /// there (`place`). Not the file's patch hash: it leaves line numbers
    /// out, and a merge from the base moves lines without changing it.
    struct CommentAnchor: Equatable, Sendable {
        /// A longer range can't be commented: comment on the file instead.
        static let maxRows = 100
        /// A row's text is kept up to this many characters and bytes (a
        /// minified line can be megabytes, one character thousands of
        /// bytes), and an anchor's rows and context up to `maxBytes`: the
        /// review file holds 8 MB.
        static let maxRowCharacters = 1_000
        static let maxRowBytes = 4_000
        static let maxBytes = 32_000
        /// Rows kept above and below, which tell a line that moved from
        /// another with the same text.
        static let contextRows = 2

        let path: String
        /// In the page's order. Empty for a comment on the whole file.
        let rows: [DiffRow]
        /// The text of up to `contextRows` rows above and below, in the
        /// same hunk: nearest last above, nearest first below.
        let before: [String]
        let after: [String]
        /// When it was made, another run of the file's diff read as its
        /// rows and had all of its context too (copied code): its rank among
        /// the runs that read as its rows, and their number. Nothing else
        /// tells copies apart.
        let copy: CopyRank?

        var isFile: Bool { rows.isEmpty }

        static func file(_ path: String) -> CommentAnchor {
            CommentAnchor(path: path, rows: [], before: [], after: [])
        }

        init(path: String, rows: [DiffRow], before: [String], after: [String], copy: CopyRank? = nil) {
            self.path = path
            self.rows = rows
            self.before = before
            self.after = after
            self.copy = copy
        }

        /// The rows from `start` to `end`, in either order, of the hunk of
        /// `file`'s diff that holds both. Nil when either isn't a row of
        /// it, they are in different hunks, or the range is past
        /// `maxRows` or `maxBytes`.
        init?(file: FileChange, from start: DiffPosition, to end: DiffPosition) {
            let hunks = BranchReview.diffRows(of: file.hunks)
            for (index, rows) in hunks.enumerated() {
                guard let first = rows.firstIndex(where: { $0.position == start }),
                      let last = rows.firstIndex(where: { $0.position == end })
                else { continue }
                let range = min(first, last)...max(first, last)
                let made = Self.anchor(path: file.path, rows: rows, range: range)
                guard made.isStorable else { return nil }
                let runs = BranchReview.runs(of: made, in: hunks)
                let own = BranchReview.evidence(of: made, around: range, in: rows)
                let copies = runs.filter { run in
                    (run.hunk, run.range) != (index, range)
                        && BranchReview.evidence(of: made, around: run.range, in: hunks[run.hunk]).hits >= own.hits
                }
                let rank = runs.firstIndex { ($0.hunk, $0.range) == (index, range) }
                self.init(
                    path: made.path, rows: made.rows, before: made.before, after: made.after,
                    copy: copies.isEmpty ? nil : rank.map { CopyRank(index: $0, count: runs.count) }
                )
                return
            }
            return nil
        }

        /// `range` of a hunk's `rows`, with its context.
        static func anchor(path: String, rows: [DiffRow], range: ClosedRange<Int>, copy: CopyRank? = nil) -> CommentAnchor {
            CommentAnchor(
                path: path,
                rows: Array(rows[range]),
                before: rows[max(0, range.lowerBound - contextRows)..<range.lowerBound].map(\.text),
                after: rows[(range.upperBound + 1)..<min(rows.count, range.upperBound + 1 + contextRows)].map(\.text),
                copy: copy
            )
        }

        static func cut(_ text: String) -> String {
            BranchReview.cut(text, characters: maxRowCharacters, bytes: maxRowBytes)
        }

        /// What this build can write and read back.
        var isStorable: Bool {
            !path.isEmpty && rows.count <= Self.maxRows && rows.allSatisfy { $0.line > 0 && $0.old >= 0 && $0.new >= 0 }
                && (rows.map(\.text) + before + after).reduce(0) { $0 + $1.utf8.count } <= Self.maxBytes
        }

        /// Texts are cut again, so that a later build may keep more of
        /// them, and `maxRows` isn't asked, so that it may allow longer
        /// ranges. Context that isn't all text reads as none: a row left
        /// out would shift the others.
        init?(json: JSONValue) {
            guard let object = json.objectValue, let path = object["path"]?.stringValue, !path.isEmpty,
                  case .array(let values)? = object["rows"]
            else { return nil }
            var rows: [DiffRow] = []
            for value in values {
                guard let row = value.objectValue, let kind = row["kind"]?.stringValue.flatMap(DiffRow.Kind.init(rawValue:)),
                      let old = row["old"]?.intValue, let new = row["new"]?.intValue, old >= 0, new >= 0,
                      let text = row["text"]?.stringValue
                else { return nil }
                let read = DiffRow(kind: kind, old: old, new: new, text: Self.cut(text), digest: row["digest"]?.stringValue)
                guard read.line > 0 else { return nil }
                rows.append(read)
            }
            func texts(_ key: String) -> [String] {
                guard case .array(let values)? = object[key] else { return [] }
                let texts = values.compactMap(\.stringValue)
                return texts.count == values.count ? texts.map(Self.cut) : []
            }
            var copy: CopyRank?
            if let rank = object["copy"]?.objectValue {
                guard let index = rank["index"]?.intValue, let count = rank["count"]?.intValue, (0..<count).contains(index)
                else { return nil }
                copy = CopyRank(index: index, count: count)
            }
            self.init(
                path: path, rows: rows,
                before: Array(texts("before").suffix(Self.contextRows)), after: Array(texts("after").prefix(Self.contextRows)),
                copy: copy
            )
        }

        var json: JSONValue {
            var object: [String: JSONValue] = [
                "path": .string(path),
                "rows": .array(rows.map { row in
                    var fields: [String: JSONValue] = [
                        "kind": .string(row.kind.rawValue), "old": .int(Int64(row.old)), "new": .int(Int64(row.new)),
                        "text": .string(row.text)
                    ]
                    fields["digest"] = row.digest.map(JSONValue.string)
                    return .object(fields)
                }),
                "before": .array(before.map(JSONValue.string)),
                "after": .array(after.map(JSONValue.string))
            ]
            object["copy"] = copy.map { .object(["index": .int(Int64($0.index)), "count": .int(Int64($0.count))]) }
            return .object(object)
        }
    }

    /// A copy's rank among the runs of a file's diff that read the same.
    struct CopyRank: Equatable, Sendable {
        let index: Int
        let count: Int
    }

    /// When a comment last went to the agent (section 6.2).
    struct SentMark: Equatable, Sendable {
        let date: Date
        /// The head the page showed then.
        let head: String
    }

    /// A comment on a file or on rows of its diff (section 6.1): plain
    /// text, kept in the review file until the user deletes it.
    struct Comment: Equatable, Sendable {
        /// The page's text field stops here too.
        static let maxCharacters = 20_000
        static let maxBytes = 80_000

        let id: String
        /// Where it was made: never rewritten.
        let anchor: CommentAnchor
        /// Where it was last found, when not where it was made.
        var moved: CommentAnchor?
        var text: String
        let created: Date
        var updated: Date
        /// Set when it went to the agent: it can no longer be edited, only
        /// deleted.
        var sent: SentMark?

        init(
            id: String, anchor: CommentAnchor, moved: CommentAnchor? = nil, text: String, created: Date, updated: Date,
            sent: SentMark? = nil
        ) {
            self.id = id
            self.anchor = anchor
            self.moved = moved
            self.text = text
            self.created = created
            self.updated = updated
            self.sent = sent
        }

        /// Where to look for it now.
        var current: CommentAnchor { moved ?? anchor }

        /// Nil when malformed, a `sent` that isn't one included: such an
        /// entry is skipped, not shown as unsent.
        init?(id: String, json: JSONValue) {
            guard let object = json.objectValue, let anchor = object["anchor"].flatMap(CommentAnchor.init(json:)),
                  let text = object["text"]?.stringValue, let created = object["created"].flatMap(BranchReview.date(json:))
            else { return nil }
            var sent: SentMark?
            if let value = object["sent"], value != .null {
                guard let date = value.objectValue?["date"].flatMap(BranchReview.date(json:)),
                      let head = value.objectValue?["head"]?.stringValue
                else { return nil }
                sent = SentMark(date: date, head: head)
            }
            self.init(
                id: id, anchor: anchor, moved: object["moved"].flatMap(CommentAnchor.init(json:)), text: text, created: created,
                updated: object["updated"].flatMap(BranchReview.date(json:)) ?? created, sent: sent
            )
        }

        /// Over `existing`, the entry as the file holds it: `anchor` is
        /// never rewritten, `sent` keeps the keys it doesn't set, and the
        /// entry those it doesn't know. `moved` is rewritten whole.
        func json(over existing: JSONValue?) -> JSONValue {
            var object = existing?.objectValue ?? [:]
            if object["anchor"].flatMap(CommentAnchor.init(json:)) != anchor { object["anchor"] = anchor.json }
            object["moved"] = moved.map(\.json)
            object["text"] = .string(text)
            object["created"] = BranchReview.json(created)
            object["updated"] = BranchReview.json(updated)
            if let sent {
                var mark = object["sent"]?.objectValue ?? [:]
                mark["date"] = BranchReview.json(sent.date)
                mark["head"] = .string(sent.head)
                object["sent"] = .object(mark)
            } else {
                object["sent"] = nil
            }
            return .object(object)
        }

        /// Cut at `maxCharacters` and `maxBytes`, then trimmed.
        static func normalized(_ text: String) -> String {
            cut(text).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static func cut(_ text: String) -> String {
            BranchReview.cut(text, characters: maxCharacters, bytes: maxBytes)
        }
    }

    /// The text of a comment being written, stored as it is typed: it
    /// outlives a Reload, the column closing and a crash. Only comments go
    /// to the agent, never drafts.
    struct Draft: Equatable, Sendable {
        let id: String
        /// Where a new comment goes, fixed when the draft is first saved;
        /// nil for an edit, which is where its comment is.
        let anchor: CommentAnchor?
        var moved: CommentAnchor?
        /// As typed, cut as a comment is.
        var text: String
        var updated: Date
        /// The unsent comment it edits; nil for a new comment.
        let editing: String?

        init(id: String, anchor: CommentAnchor?, moved: CommentAnchor? = nil, text: String, updated: Date, editing: String? = nil) {
            self.id = id
            self.anchor = editing == nil ? anchor : nil
            self.moved = editing == nil ? moved : nil
            self.text = text
            self.updated = updated
            self.editing = editing
        }

        /// Nil when malformed: a new comment's draft needs an anchor, and
        /// an edit's names its comment.
        init?(id: String, json: JSONValue) {
            guard let object = json.objectValue, let text = object["text"]?.stringValue,
                  let updated = object["updated"].flatMap(BranchReview.date(json:))
            else { return nil }
            var editing: String?
            if let value = object["editing"], value != .null {
                guard let name = value.stringValue, BranchReview.isCommentID(name) else { return nil }
                editing = name
            }
            let anchor = object["anchor"].flatMap(CommentAnchor.init(json:))
            guard anchor != nil || editing != nil else { return nil }
            self.init(
                id: id, anchor: anchor, moved: object["moved"].flatMap(CommentAnchor.init(json:)), text: text, updated: updated,
                editing: editing
            )
        }

        func json(over existing: JSONValue?) -> JSONValue {
            var object = existing?.objectValue ?? [:]
            if let anchor, object["anchor"].flatMap(CommentAnchor.init(json:)) != anchor { object["anchor"] = anchor.json }
            object["moved"] = moved.map(\.json)
            object["text"] = .string(text)
            object["updated"] = BranchReview.json(updated)
            object["editing"] = editing.map(JSONValue.string)
            return .object(object)
        }
    }

    /// What the page may name a comment or a draft by: letters, digits and
    /// "-", up to 64 (a UUID), since the name is a key of the review file.
    static func isCommentID(_ text: String) -> Bool {
        (1...64).contains(text.utf8.count)
            && text.utf8.allSatisfy { byte in
                (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                    || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-")
            }
    }

    /// `text` up to `characters` characters and `bytes` UTF-8 bytes,
    /// whichever comes first, never inside a character.
    static func cut(_ text: String, characters: Int, bytes: Int) -> String {
        // A character is a byte at least.
        if text.utf8.count <= min(characters, bytes) { return text }
        var end = text.startIndex
        var count = 0
        var size = 0
        while end < text.endIndex, count < characters {
            let next = text.index(after: end)
            let length = text.utf8.distance(from: end, to: next)
            guard size + length <= bytes else { break }
            size += length
            count += 1
            end = next
        }
        return String(text[..<end])
    }

    fileprivate static func date(json: JSONValue) -> Date? {
        json.stringValue.flatMap { try? Date($0, strategy: .iso8601) }
    }

    fileprivate static func json(_ date: Date) -> JSONValue {
        .string(date.formatted(.iso8601))
    }
}

// MARK: - In the review file

/// The page saves a draft as it is typed, a moment after the last key:
/// it sends a pending save before Comment, Save or Cancel, and the column
/// applies them in order. A save arriving after them would bring the draft
/// back. After a Send, an editor that was editing a sent comment goes on
/// as the new comment's draft `markSent` made of it.
extension BranchReview.Record {
    typealias Comment = BranchReview.Comment
    typealias Draft = BranchReview.Draft
    typealias CommentAnchor = BranchReview.CommentAnchor

    /// Oldest first (to the second, then by id). Malformed entries are
    /// skipped, and kept in the file.
    var comments: [Comment] {
        entries("comments").compactMap { Comment(id: $0.key, json: $0.value) }
            .sorted { ($0.created, $0.id) < ($1.created, $1.id) }
    }

    /// Least recently typed in first. Leaves out an edit whose comment was
    /// sent or deleted: it can't be saved.
    var drafts: [Draft] {
        let editable = Set(comments.filter { $0.sent == nil }.map(\.id))
        return entries("drafts").compactMap { Draft(id: $0.key, json: $0.value) }
            .filter { draft in draft.editing.map(editable.contains) ?? true }
            .sorted { ($0.updated, $0.id) < ($1.updated, $1.id) }
    }

    func comment(id: String) -> Comment? {
        guard BranchReview.isCommentID(id) else { return nil }
        return fields["comments"]?.objectValue?[id].flatMap { Comment(id: id, json: $0) }
    }

    func draft(id: String) -> Draft? {
        guard BranchReview.isCommentID(id) else { return nil }
        return fields["drafts"]?.objectValue?[id].flatMap { Draft(id: id, json: $0) }
    }

    /// Stores what is typed: for a new comment at `anchor`, or for the
    /// unsent comment `editing`. A draft's anchor is fixed when it is
    /// first saved: the page sends where the user clicked each time, and
    /// the diff may have changed since. Empty text removes the draft.
    /// False, and nothing changes, for an id that isn't one or is a
    /// comment's, an anchor this build can't store, a draft saved before
    /// for something else, or a comment sent or deleted since.
    @discardableResult
    mutating func saveDraft(id: String, anchor: CommentAnchor, text: String, editing: String? = nil, at date: Date) -> Bool {
        guard BranchReview.isCommentID(id) else { return false }
        guard !text.isEmpty else {
            removeDraft(id: id)
            return true
        }
        guard fields["comments"]?.objectValue?[id] == nil else { return false }
        if let editing {
            guard let target = comment(id: editing), target.sent == nil else { return false }
        }
        let existing = fields["drafts"]?.objectValue?[id]
        var draft: Draft
        if let existing {
            guard let saved = Draft(id: id, json: existing), saved.editing == editing else { return false }
            draft = saved
        } else {
            guard editing != nil || anchor.isStorable else { return false }
            draft = Draft(id: id, anchor: anchor, text: "", updated: date, editing: editing)
        }
        let cut = Comment.cut(text)
        guard draft.text != cut else { return true }
        draft.text = cut
        draft.updated = date
        set("drafts", id, draft.json(over: existing))
        return true
    }

    mutating func removeDraft(id: String) {
        set("drafts", id, nil)
    }

    /// A new comment, trimmed: where its draft of the same id was fixed if
    /// it has one, at `anchor` otherwise; the draft goes. False, and
    /// nothing changes, when the text is empty, the id isn't one or is
    /// taken, its draft is an edit, or the anchor can't be stored.
    @discardableResult
    mutating func addComment(id: String, anchor: CommentAnchor, text: String, at date: Date) -> Bool {
        let text = Comment.normalized(text)
        guard BranchReview.isCommentID(id), !text.isEmpty, fields["comments"]?.objectValue?[id] == nil else { return false }
        var made = Comment(id: id, anchor: anchor, text: text, created: date, updated: date)
        if fields["drafts"]?.objectValue?[id] != nil {
            guard let draft = draft(id: id), let fixed = draft.anchor else { return false }
            made = Comment(id: id, anchor: fixed, moved: draft.moved, text: text, created: date, updated: date)
        }
        guard made.anchor.isStorable else { return false }
        set("comments", id, made.json(over: nil))
        removeDraft(id: id)
        return true
    }

    /// An unsent comment's new text, trimmed; the drafts that edit it go.
    /// False, and nothing changes, when the text is empty, or the comment
    /// was sent or deleted.
    @discardableResult
    mutating func editComment(id: String, text: String, at date: Date) -> Bool {
        let text = Comment.normalized(text)
        guard !text.isEmpty, var comment = comment(id: id), comment.sent == nil else { return false }
        if comment.text != text {
            comment.text = text
            comment.updated = date
            set("comments", id, comment.json(over: fields["comments"]?.objectValue?[id]))
        }
        removeDrafts(editing: id)
        return true
    }

    /// Sent or not, with the drafts that edit it.
    mutating func deleteComment(id: String) {
        set("comments", id, nil)
        removeDrafts(editing: id)
    }

    /// The comments went to the agent at `head` (again, for those sent
    /// before). An edit under way can no longer change one: it becomes
    /// the draft of a new comment where its comment is, so that nothing
    /// typed is lost; one that changed nothing goes. Returns the ids
    /// marked.
    @discardableResult
    mutating func markSent(ids: [String], head: String, at date: Date) -> [String] {
        var marked: [String] = []
        for id in ids where !marked.contains(id) {
            guard var comment = comment(id: id) else { continue }
            comment.sent = BranchReview.SentMark(date: date, head: head)
            set("comments", id, comment.json(over: fields["comments"]?.objectValue?[id]))
            marked.append(id)
            for (key, value) in entries("drafts") {
                guard let draft = Draft(id: key, json: value), draft.editing == id else { continue }
                guard Comment.normalized(draft.text) != comment.text else {
                    removeDraft(id: key)
                    continue
                }
                let unbound = Draft(id: key, anchor: comment.anchor, moved: comment.moved, text: draft.text, updated: draft.updated)
                set("drafts", key, unbound.json(over: value))
            }
        }
        return marked
    }

    /// Records where each comment, and each new comment's draft, is in
    /// `files` (the snapshot's) when that isn't where it was last found,
    /// so that it is looked for from there next time; where it was made
    /// stays. Outdated ones, and those whose file's hunks aren't read,
    /// stay as they are. A renamed file's comments follow it. True when
    /// any moved.
    @discardableResult
    mutating func reanchor(in files: [BranchReview.FileChange]) -> Bool {
        // Each file's rows once, whatever the number of its comments.
        var rows: [String: [[BranchReview.DiffRow]]] = [:]
        /// Nil when it stays as it is; `.some(nil)` back where it was made.
        func found(_ made: CommentAnchor, _ moved: CommentAnchor?) -> CommentAnchor?? {
            guard let file = BranchReview.file(for: made, moved: moved, in: files) else { return .none }
            let fileRows = rows[file.path] ?? BranchReview.diffRows(of: file.hunks)
            rows[file.path] = fileRows
            guard case .placed(let anchor) = BranchReview.place(made, moved: moved, in: file, rows: fileRows) else { return .none }
            return .some(anchor == made ? nil : anchor)
        }
        var changed = false
        for comment in comments {
            guard case .some(let moved) = found(comment.anchor, comment.moved), moved != comment.moved else { continue }
            var placed = comment
            placed.moved = moved
            set("comments", comment.id, placed.json(over: fields["comments"]?.objectValue?[comment.id]))
            changed = true
        }
        for draft in drafts {
            guard let made = draft.anchor, case .some(let moved) = found(made, draft.moved), moved != draft.moved else { continue }
            var placed = draft
            placed.moved = moved
            set("drafts", draft.id, placed.json(over: fields["drafts"]?.objectValue?[draft.id]))
            changed = true
        }
        return changed
    }

    private func entries(_ key: String) -> [(key: String, value: JSONValue)] {
        (fields[key]?.objectValue ?? [:]).filter { BranchReview.isCommentID($0.key) }.map { ($0.key, $0.value) }
    }

    private mutating func removeDrafts(editing id: String) {
        for (key, value) in entries("drafts") where Draft(id: key, json: value)?.editing == id {
            removeDraft(id: key)
        }
    }

    /// Sets, or removes, one entry of a top-level object; an object left
    /// empty goes.
    private mutating func set(_ key: String, _ id: String, _ value: JSONValue?) {
        var object = fields[key]?.objectValue ?? [:]
        guard object[id] != value else { return }
        object[id] = value
        fields[key] = object.isEmpty ? nil : .object(object)
    }
}
